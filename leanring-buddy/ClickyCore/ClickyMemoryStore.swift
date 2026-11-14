import Foundation

// Memories from earlier chats (round 16). When a chat ends, Clicky compacts it into zero to three
// short lines (see `ClickyMemoryCompaction`); the lines are kept here, outside iCloud, and the
// relevant ones are put into a later turn's prompt (see `ClickyMemorySelection`).
//
// Everything in this file is pure Foundation: the model of one memory, and the store that keeps
// them in one small JSON file. No method throws out of a read, and nothing here talks to the
// network.

/// One memory: a short line Clicky kept from a chat.
nonisolated struct ClickyMemory: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    /// One line, at most `ClickyMemoryStore.maximumMemoryTextCharacterCount` characters.
    let text: String
    /// The day of the chat the line came from: the time of the last exchange that was compacted,
    /// not the moment the compaction ran. A retry hours later must not move "the demo is on
    /// friday" to another week, and the prompt shows this date next to the line.
    let createdAt: Date
    /// The chat the line came from. That chat may be gone (the user deleted it, or its 90 days
    /// passed): memories outlive the chats on purpose.
    let sourceChatID: UUID?

    /// The identifier the memory tab uses for the row, so it cannot collide with the identifiers of
    /// profile facts and notes ("profile.md#3", "2026-11-10.md#4").
    var rowIdentifier: String {
        "memory-\(id.uuidString)"
    }
}

/// What adding memories to the store ended with.
nonisolated enum ClickyMemoryAddResult: Equatable, Sendable {
    /// The memories that were written, and how many of the oldest memories were dropped to stay
    /// within the limit.
    case added(memories: [ClickyMemory], droppedOldestCount: Int)
    case failed(errorDescription: String)
}

/// The memories on disk: one small JSON file in `~/Library/Application Support/Clicky/Memories`,
/// outside iCloud and outside the protected Documents folder (which stalled turns before).
///
/// - Written atomically (a temporary file renamed into place), so a crash leaves the old file whole.
/// - Read tolerantly: a missing or corrupt file is no memories, and one bad entry costs only itself.
/// - At most `maximumMemoryCount` memories; the oldest are dropped past that.
/// - Memories outlive the 90-day retention of chats.
nonisolated struct ClickyMemoryStore: Sendable {
    let memoriesDirectoryURL: URL

    static let memoriesFileName = "memories.json"
    /// Where an unreadable file is moved to before a new one is written, so nothing a person put
    /// there is ever overwritten.
    static let unreadableFileName = "memories.unreadable.json"
    static let maximumMemoryCount = 300
    static let maximumMemoryTextCharacterCount = 160

    /// The self test points the app at a folder of its own with this variable. It is honoured only
    /// when the panel self test is switched on (see `directoryURLForRun`).
    static let directoryOverrideEnvironmentVariable = "CLICKY_MEMORIES_DIRECTORY"

    /// Compaction and the memory tab both change the file by reading it, changing the list and
    /// writing it back. One lock around that whole step keeps a delete in the panel and a
    /// compaction that finishes at the same moment from undoing each other.
    private static let readModifyWriteLock = NSLock()

    static var defaultMemoriesDirectoryURL: URL {
        let applicationSupportDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportDirectoryURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("Memories", isDirectory: true)
    }

    /// The folder this run of the app uses. An ordinary run always uses the real folder: the
    /// override variable is ignored, so a stray variable can never point the memory tab's delete or
    /// the compaction somewhere unexpected. Only with the panel self test on
    /// (`CLICKY_PANEL_SELF_TEST=1`) is the override honoured, and a self test with no override gets
    /// a new folder in the temporary directory: the real folder is never its fallback.
    static func directoryURLForRun(
        environment: [String: String],
        temporaryDirectoryURL: URL,
        uniqueFolderNameForSelfTest: String
    ) -> URL {
        guard environment[ClickyChatStore.panelSelfTestEnvironmentVariable] == "1" else {
            return defaultMemoriesDirectoryURL
        }
        if let overridePath = environment[directoryOverrideEnvironmentVariable], !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }
        return temporaryDirectoryURL.appendingPathComponent(uniqueFolderNameForSelfTest, isDirectory: true)
    }

    init(memoriesDirectoryURL: URL) {
        self.memoriesDirectoryURL = memoriesDirectoryURL
    }

    var memoriesFileURL: URL {
        memoriesDirectoryURL.appendingPathComponent(Self.memoriesFileName)
    }

    // MARK: - Text

    /// One line of at most 160 characters: line breaks and runs of spaces become single spaces, and
    /// an over-long line is cut (never rejected). Every path that writes a memory goes through here,
    /// so the limit holds whatever produced the text.
    static func normalizedMemoryText(_ rawMemoryText: String) -> String {
        let singleLineText = rawMemoryText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(singleLineText.prefix(maximumMemoryTextCharacterCount))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Reading

    /// Every memory in the order they were stored (oldest first). A missing or unreadable file is
    /// no memories.
    func loadMemories() -> [ClickyMemory] {
        guard let fileData = try? Data(contentsOf: memoriesFileURL) else {
            return []
        }
        return Self.parseMemoriesFile(fileData).memories
    }

    /// The memories as the memory tab lists them: newest first by date, and the lines that came
    /// from one compaction (they share a date) in the order they were written.
    func loadMemoriesNewestFirst() -> [ClickyMemory] {
        Self.sortedNewestFirst(loadMemories())
    }

    static func sortedNewestFirst(_ memories: [ClickyMemory]) -> [ClickyMemory] {
        memories.enumerated()
            .sorted { firstEntry, secondEntry in
                if firstEntry.element.createdAt != secondEntry.element.createdAt {
                    return firstEntry.element.createdAt > secondEntry.element.createdAt
                }
                return firstEntry.offset < secondEntry.offset
            }
            .map(\.element)
    }

    // MARK: - Tolerant decoding

    /// Reads the file's bytes. `fileWasUnreadable` is true when there are bytes but they are not a
    /// memories file at all (not JSON, or JSON that is neither an object nor a list); the store
    /// then moves the file aside before writing instead of overwriting it. An empty file, an
    /// object without a list and a list of garbage are just no memories.
    ///
    /// Accepted shapes: `{"memories": [ ... ]}` (what the store writes) and a bare list. An entry
    /// is kept when it has a UUID `id`, non-blank `text` and an ISO 8601 `createdAt`; `sourceChatID`
    /// is optional; unknown keys are ignored; the text is normalised and cut to 160 characters.
    /// Entries with a repeated id keep the first.
    static func parseMemoriesFile(_ fileData: Data) -> (memories: [ClickyMemory], fileWasUnreadable: Bool) {
        let hasOnlyWhitespace = String(decoding: fileData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasOnlyWhitespace {
            return ([], false)
        }
        guard let parsedJSON = try? JSONSerialization.jsonObject(with: fileData) else {
            return ([], true)
        }
        let entryObjects: [Any]
        if let topLevelObject = parsedJSON as? [String: Any] {
            entryObjects = (topLevelObject["memories"] as? [Any]) ?? []
        } else if let topLevelList = parsedJSON as? [Any] {
            entryObjects = topLevelList
        } else {
            return ([], true)
        }

        var memories: [ClickyMemory] = []
        var seenIdentifiers = Set<UUID>()
        for entryObject in entryObjects {
            guard let memory = memory(fromJSONObject: entryObject), seenIdentifiers.insert(memory.id).inserted else {
                continue
            }
            memories.append(memory)
        }
        return (memories, false)
    }

    private static func memory(fromJSONObject jsonObject: Any) -> ClickyMemory? {
        guard let entry = jsonObject as? [String: Any],
              let identifierText = entry["id"] as? String,
              let identifier = UUID(uuidString: identifierText),
              let rawText = entry["text"] as? String,
              let createdAtText = entry["createdAt"] as? String,
              let createdAt = date(fromISO8601Text: createdAtText) else {
            return nil
        }
        let text = normalizedMemoryText(rawText)
        guard !text.isEmpty else {
            return nil
        }
        let sourceChatID = (entry["sourceChatID"] as? String).flatMap { UUID(uuidString: $0) }
        return ClickyMemory(id: identifier, text: text, createdAt: createdAt, sourceChatID: sourceChatID)
    }

    private static func date(fromISO8601Text dateText: String) -> Date? {
        if let plainDate = ISO8601DateFormatter().date(from: dateText) {
            return plainDate
        }
        let fractionalSecondsFormatter = ISO8601DateFormatter()
        fractionalSecondsFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalSecondsFormatter.date(from: dateText)
    }

    // MARK: - Encoding

    private struct MemoriesFile: Codable {
        let formatVersion: Int
        let memories: [ClickyMemory]
    }

    /// Dates as ISO 8601 text and keys in order, so the file can be read by eye.
    static func encodeMemories(_ memories: [ClickyMemory]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(MemoriesFile(formatVersion: 1, memories: memories))
    }

    // MARK: - Adding

    /// Appends the texts as new memories that share `createdAt` and `sourceChatID`. Each text is
    /// normalised (one line, at most 160 characters) and a blank one is skipped. When the store then
    /// holds more than 300 memories, the oldest are dropped.
    ///
    /// Returns a description of the failure instead of throwing, so the caller can leave the chat
    /// pending and carry on.
    @discardableResult
    func addMemories(texts memoryTexts: [String], sourceChatID: UUID?, createdAt: Date) -> ClickyMemoryAddResult {
        let normalizedTexts = memoryTexts.map(Self.normalizedMemoryText).filter { !$0.isEmpty }
        guard !normalizedTexts.isEmpty else {
            return .added(memories: [], droppedOldestCount: 0)
        }

        Self.readModifyWriteLock.lock()
        defer { Self.readModifyWriteLock.unlock() }
        do {
            let existingMemories = try readMemoriesForModification()
            let newMemories = normalizedTexts.map { normalizedText in
                ClickyMemory(id: UUID(), text: normalizedText, createdAt: createdAt, sourceChatID: sourceChatID)
            }
            let allMemories = existingMemories + newMemories
            let memoriesToKeep = Self.droppingOldestMemories(from: allMemories, keeping: Self.maximumMemoryCount)
            try write(memoriesToKeep)
            let identifiersKept = Set(memoriesToKeep.map(\.id))
            return .added(
                memories: newMemories.filter { identifiersKept.contains($0.id) },
                droppedOldestCount: allMemories.count - memoriesToKeep.count
            )
        } catch {
            return .failed(errorDescription: error.localizedDescription)
        }
    }

    /// The memories in their stored order without the oldest ones past `limit`. "Oldest" is by date,
    /// and among equal dates the one stored first.
    static func droppingOldestMemories(from memories: [ClickyMemory], keeping limit: Int) -> [ClickyMemory] {
        guard memories.count > limit else {
            return memories
        }
        let offsetsOfOldestFirst = memories.enumerated()
            .sorted { firstEntry, secondEntry in
                if firstEntry.element.createdAt != secondEntry.element.createdAt {
                    return firstEntry.element.createdAt < secondEntry.element.createdAt
                }
                return firstEntry.offset < secondEntry.offset
            }
            .map(\.offset)
        let offsetsToDrop = Set(offsetsOfOldestFirst.prefix(memories.count - limit))
        return memories.enumerated().filter { !offsetsToDrop.contains($0.offset) }.map(\.element)
    }

    // MARK: - Removing

    /// Removes exactly the one memory with this id (the memory tab's delete). Every other memory
    /// stays as it was. An id that is not in the file removes nothing and answers `.noMatch`.
    func removeMemory(withID memoryID: UUID) -> ClickyMemoryRemovalResult {
        Self.readModifyWriteLock.lock()
        defer { Self.readModifyWriteLock.unlock() }
        do {
            let existingMemories = try readMemoriesForModification()
            guard let memoryToRemove = existingMemories.first(where: { $0.id == memoryID }) else {
                return .noMatch
            }
            try write(existingMemories.filter { $0.id != memoryID })
            return .removed(removedTexts: [memoryToRemove.text])
        } catch {
            return .failed(errorDescription: error.localizedDescription)
        }
    }

    // MARK: - Private

    /// The memories to change. A missing file is none. A file that cannot be read at all throws
    /// (changing it from an empty list would erase what it holds). A file that is not a memories
    /// file is moved to `memories.unreadable.json` first, so a new file can be written without
    /// destroying it.
    private func readMemoriesForModification() throws -> [ClickyMemory] {
        guard FileManager.default.fileExists(atPath: memoriesFileURL.path) else {
            return []
        }
        let fileData = try Data(contentsOf: memoriesFileURL)
        let parsedFile = Self.parseMemoriesFile(fileData)
        if parsedFile.fileWasUnreadable {
            let unreadableFileURL = memoriesDirectoryURL.appendingPathComponent(Self.unreadableFileName)
            try? FileManager.default.removeItem(at: unreadableFileURL)
            try FileManager.default.moveItem(at: memoriesFileURL, to: unreadableFileURL)
        }
        return parsedFile.memories
    }

    private func write(_ memories: [ClickyMemory]) throws {
        try FileManager.default.createDirectory(at: memoriesDirectoryURL, withIntermediateDirectories: true)
        try Self.encodeMemories(memories).write(to: memoriesFileURL, options: .atomic)
    }
}
