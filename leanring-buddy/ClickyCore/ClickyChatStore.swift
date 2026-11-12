import Foundation

/// The chats on disk: one JSON file per chat in one folder, written atomically and read
/// tolerantly. Nothing here throws out of a read: a missing, unreadable or corrupt file is
/// skipped, so one bad file can never take the panel down.
///
/// The folder is `~/Library/Application Support/Clicky/Chats` by default: outside iCloud and
/// outside the protected Documents folder, which stalled turns before. Tests and the self test
/// pass their own temporary folder; the real folder is never used by them.
nonisolated struct ClickyChatStore {
    let chatsDirectoryURL: URL

    static let chatFileExtension = "json"
    /// The self test and tests point the app at a folder of their own with this variable.
    static let directoryOverrideEnvironmentVariable = "CLICKY_CHAT_STORE_DIRECTORY"

    static var defaultChatsDirectoryURL: URL {
        let applicationSupportDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportDirectoryURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("Chats", isDirectory: true)
    }

    /// The folder the app should use: the override from the environment when set, else the default.
    static func chatsDirectoryURL(fromEnvironment environment: [String: String]) -> URL {
        if let overridePath = environment[directoryOverrideEnvironmentVariable], !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }
        return defaultChatsDirectoryURL
    }

    /// The self tests are switched on by this variable set to "1".
    static let panelSelfTestEnvironmentVariable = "CLICKY_PANEL_SELF_TEST"

    /// The folder this run of the app uses. An ordinary run uses the override or the default (see
    /// above). A self test run never reaches the real folder: it uses the override when one is
    /// given and otherwise a new folder in the temporary directory, so sample chats can neither
    /// mix with the user's chats nor be written among them.
    static func chatsDirectoryURLForRun(
        environment: [String: String],
        temporaryDirectoryURL: URL,
        uniqueFolderNameForSelfTest: String
    ) -> URL {
        let overridePath = environment[directoryOverrideEnvironmentVariable] ?? ""
        if environment[panelSelfTestEnvironmentVariable] == "1" && overridePath.isEmpty {
            return temporaryDirectoryURL.appendingPathComponent(uniqueFolderNameForSelfTest, isDirectory: true)
        }
        return chatsDirectoryURL(fromEnvironment: environment)
    }

    init(chatsDirectoryURL: URL) {
        self.chatsDirectoryURL = chatsDirectoryURL
    }

    // MARK: - Encoding

    /// Dates as ISO 8601 text and keys in order, so a chat file can be read by eye and by a later
    /// compaction step.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode(_ chat: ClickyChat) throws -> Data {
        try makeEncoder().encode(chat)
    }

    /// nil for anything that is not a complete chat.
    static func decodeChat(from data: Data) -> ClickyChat? {
        try? makeDecoder().decode(ClickyChat.self, from: data)
    }

    func fileURL(forChatWithID chatID: UUID) -> URL {
        chatsDirectoryURL.appendingPathComponent(chatID.uuidString).appendingPathExtension(Self.chatFileExtension)
    }

    // MARK: - Reading

    /// Every readable chat in the folder, newest first. A folder that does not exist yet gives an
    /// empty list. Files that are not chats are skipped.
    func loadAllChats() -> [ClickyChat] {
        let fileManager = FileManager.default
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: chatsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let chats = fileURLs
            .filter { $0.pathExtension == Self.chatFileExtension }
            .compactMap { fileURL -> ClickyChat? in
                guard let fileData = try? Data(contentsOf: fileURL) else { return nil }
                return Self.decodeChat(from: fileData)
            }
        return chats.sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadChat(withID chatID: UUID) -> ClickyChat? {
        guard let fileData = try? Data(contentsOf: fileURL(forChatWithID: chatID)) else { return nil }
        return Self.decodeChat(from: fileData)
    }

    // MARK: - Writing

    /// Writes the chat to its file, creating the folder on first use. The write is atomic (a
    /// temporary file renamed into place), so a crash mid-write leaves the previous file whole.
    /// Returns a description of the failure instead of throwing, so the caller can log it and
    /// carry on.
    @discardableResult
    func save(_ chat: ClickyChat) -> String? {
        do {
            try FileManager.default.createDirectory(at: chatsDirectoryURL, withIntermediateDirectories: true)
            let chatData = try Self.encode(chat)
            try chatData.write(to: fileURL(forChatWithID: chat.id), options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Removes the chat's file. A file that is already gone is not an error.
    @discardableResult
    func deleteChat(withID chatID: UUID) -> String? {
        let chatFileURL = fileURL(forChatWithID: chatID)
        guard FileManager.default.fileExists(atPath: chatFileURL.path) else { return nil }
        do {
            try FileManager.default.removeItem(at: chatFileURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Retention

    /// Deletes every chat that is past its ninety days and not kept. Returns the ids removed.
    @discardableResult
    func deleteChatsPastRetention(now: Date) -> [UUID] {
        var removedChatIDs: [UUID] = []
        for chat in loadAllChats() where ClickyChatRetention.isDueForDeletion(chat, now: now) {
            if deleteChat(withID: chat.id) == nil {
                removedChatIDs.append(chat.id)
            }
        }
        return removedChatIDs
    }
}
