import Foundation

// The memory tab of the chat panel (round 15): what it lists (the profile's facts and the daily
// notes), how it reads them without ever waiting on `~/Documents` on the main thread, how it
// cuts exactly one line out of a file, where the panel's data lives (and how a self test is kept
// away from the real folders), and the sample data the self test shows.
//
// This adds no way to save anything and changes nothing about how memory is saved or injected.

// MARK: - Lines with their line breaks

/// One line of a text file together with its own line break.
nonisolated struct EzraMemoryFileLine: Equatable, Sendable {
    /// The line without its line break.
    let text: String
    /// "\n", "\r\n" or another break `Character.isNewline` knows; empty for a last line that has none.
    let lineBreak: String
}

/// Splits a file into lines without losing anything, so that one line can be cut out and the
/// rest written back exactly as it was.
nonisolated enum EzraMemoryFileLines {
    /// The lines of the file, each with the break that ended it. Joining `text + lineBreak` of
    /// every line gives the file back, byte for byte. A file that ends with a line break has no
    /// extra empty line after it. A "\r\n" is one break (it is one `Character` in Swift), the same
    /// way `EzraProfileStore` has always split its file, so line numbers agree.
    static func lines(of fileContents: String) -> [EzraMemoryFileLine] {
        var fileLines: [EzraMemoryFileLine] = []
        var currentLineText = ""
        for character in fileContents {
            if character.isNewline {
                fileLines.append(EzraMemoryFileLine(text: currentLineText, lineBreak: String(character)))
                currentLineText = ""
            } else {
                currentLineText.append(character)
            }
        }
        if !currentLineText.isEmpty {
            fileLines.append(EzraMemoryFileLine(text: currentLineText, lineBreak: ""))
        }
        return fileLines
    }

    /// The file without one line and that line's own break. Every other line keeps its own break.
    static func fileContents(from fileLines: [EzraMemoryFileLine], removingLineAt lineIndexToRemove: Int) -> String {
        var fileContents = ""
        for (lineIndex, fileLine) in fileLines.enumerated() where lineIndex != lineIndexToRemove {
            fileContents += fileLine.text
            fileContents += fileLine.lineBreak
        }
        return fileContents
    }
}

// MARK: - What the tab lists

nonisolated struct EzraMemoryPanelContents: Equatable, Sendable {
    /// The most notes the tab lists (the newest). A long-used notes folder can hold thousands, and
    /// the tab is a place to look and tidy up, not to page through a year.
    static let maximumNotesListed = 200

    /// The profile's facts in file order, so the newest is last (as `EzraProfileStore` reads them).
    var profileFacts: [EzraProfileFactEntry]
    /// The notes, newest first, at most `maximumNotesListed`.
    var notes: [EzraNoteEntry]
    /// How many notes there are in all, so the tab can say when it lists only the newest.
    var totalNoteCount: Int
    /// The memories Ezra kept from earlier chats (round 16), newest first. All of them are listed:
    /// there are never more than 300, and each is one short line.
    var memories: [EzraMemory] = []

    static let empty = EzraMemoryPanelContents(profileFacts: [], notes: [], totalNoteCount: 0)

    var isEmpty: Bool {
        profileFacts.isEmpty && totalNoteCount == 0 && memories.isEmpty
    }

    /// The contents with one row taken out, so the row disappears the moment it is deleted and the
    /// real answer from the disk replaces this when it arrives.
    func removingRow(withIdentifier rowIdentifier: String) -> EzraMemoryPanelContents {
        var contentsWithoutRow = self
        contentsWithoutRow.profileFacts.removeAll { $0.identifier == rowIdentifier }
        contentsWithoutRow.memories.removeAll { $0.rowIdentifier == rowIdentifier }
        let noteCountBefore = contentsWithoutRow.notes.count
        contentsWithoutRow.notes.removeAll { $0.identifier == rowIdentifier }
        if contentsWithoutRow.notes.count < noteCountBefore {
            contentsWithoutRow.totalNoteCount = max(0, totalNoteCount - 1)
        }
        return contentsWithoutRow
    }
}

/// How the tab writes a note's time. Lowercase, like every other word Ezra shows.
nonisolated enum EzraMemoryPanelText {
    /// "today 14:30", "yesterday 09:12", "9 nov 14:30", or with the year when it is not this year
    /// ("9 nov 2025 14:30"). A note with no time of day (typed by hand) shows the date alone.
    static func noteDateText(savedAt: Date, hasTimeOfDay: Bool, now: Date, calendar: Calendar = .current) -> String {
        let dateText: String
        if calendar.isDate(savedAt, inSameDayAs: now) {
            dateText = "today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(savedAt, inSameDayAs: yesterday) {
            dateText = "yesterday"
        } else {
            let isInTheSameYear = calendar.component(.year, from: savedAt) == calendar.component(.year, from: now)
            dateText = formatted(savedAt, dateFormat: isInTheSameYear ? "d MMM" : "d MMM yyyy", calendar: calendar).lowercased()
        }
        guard hasTimeOfDay else {
            return dateText
        }
        return dateText + " " + formatted(savedAt, dateFormat: "HH:mm", calendar: calendar)
    }

    private static func formatted(_ date: Date, dateFormat: String, calendar: Calendar) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = dateFormat
        return dateFormatter.string(from: date)
    }
}

// MARK: - Reading and removing, off the main thread

/// Reads the notes folder for the tab and removes one row. Every function here touches the disk,
/// so the panel only ever calls them from a background task.
///
/// Why two ways to read: `~/Documents` is iCloud-backed on this Mac, and reading it has stalled for
/// 3 to 6 seconds before. `contentsFromCacheWithoutReadingDisk` answers at once from the copy the
/// app already keeps (`EzraMemoryFileSnapshotCache`), so the tab shows something immediately,
/// and `contentsAfterRefreshingFromDisk` then re-reads the folder, which is the slow part, and
/// replaces it. A folder the cache is not switched on for (every test folder) has no copy and is
/// always read from disk.
nonisolated enum EzraMemoryPanelLoader {
    /// The contents of a notes folder given as file name to text. Pure.
    static func contents(fromMarkdownFileContentsByFileName markdownFileContentsByFileName: [String: String]) -> EzraMemoryPanelContents {
        let profileFacts = markdownFileContentsByFileName[EzraProfileStore.profileFileName]
            .map { EzraProfileStore.factEntries(fromFileContents: $0) } ?? []

        // Newest first: by time, and for notes with the same time the later line first.
        let allNotesNewestFirst = EzraNoteStore.noteEntries(fromMarkdownFileContentsByFileName: markdownFileContentsByFileName)
            .sorted { firstNote, secondNote in
                if firstNote.savedAt != secondNote.savedAt {
                    return firstNote.savedAt > secondNote.savedAt
                }
                if firstNote.sourceFileName != secondNote.sourceFileName {
                    return firstNote.sourceFileName > secondNote.sourceFileName
                }
                return firstNote.lineIndexInFile > secondNote.lineIndexInFile
            }
        return EzraMemoryPanelContents(
            profileFacts: profileFacts,
            notes: Array(allNotesNewestFirst.prefix(EzraMemoryPanelContents.maximumNotesListed)),
            totalNoteCount: allNotesNewestFirst.count
        )
    }

    /// The in-memory copy of the folder, or nil when the cache has none. Never touches the notes
    /// folder. The memories (round 16) are not in that folder or in that cache: they are one small
    /// file in Application Support (outside iCloud), read here when `memoriesDirectoryURL` is given.
    static func contentsFromCacheWithoutReadingDisk(notesDirectoryURL: URL, memoriesDirectoryURL: URL? = nil) -> EzraMemoryPanelContents? {
        guard let cachedMarkdownFileContentsByFileName = EzraMemoryFileSnapshotCache.shared
            .cachedMarkdownFileContentsByFileName(inDirectory: notesDirectoryURL) else {
            return nil
        }
        var contentsFromCache = contents(fromMarkdownFileContentsByFileName: cachedMarkdownFileContentsByFileName)
        contentsFromCache.memories = memoriesNewestFirst(inDirectory: memoriesDirectoryURL)
        return contentsFromCache
    }

    /// Re-reads the folder (this refreshes the cache for a cached folder) and returns what it holds.
    static func contentsAfterRefreshingFromDisk(notesDirectoryURL: URL, memoriesDirectoryURL: URL? = nil) -> EzraMemoryPanelContents {
        EzraMemoryFileSnapshotCache.shared.refresh(directory: notesDirectoryURL)
        let markdownFileContentsByFileName = EzraMemoryFileSnapshotCache.shared
            .cachedMarkdownFileContentsByFileName(inDirectory: notesDirectoryURL)
            ?? EzraMemoryFileSnapshotCache.readMarkdownFilesFromDisk(inDirectory: notesDirectoryURL)
        var contentsFromDisk = contents(fromMarkdownFileContentsByFileName: markdownFileContentsByFileName)
        contentsFromDisk.memories = memoriesNewestFirst(inDirectory: memoriesDirectoryURL)
        return contentsFromDisk
    }

    /// The memories of a folder, newest first. No folder given, or none yet, is no memories.
    private static func memoriesNewestFirst(inDirectory memoriesDirectoryURL: URL?) -> [EzraMemory] {
        guard let memoriesDirectoryURL else {
            return []
        }
        return EzraMemoryStore(memoriesDirectoryURL: memoriesDirectoryURL).loadMemoriesNewestFirst()
    }

    /// Removes exactly the one memory with this id (the memory tab's delete).
    static func removeMemory(_ memory: EzraMemory, memoriesDirectoryURL: URL) -> EzraMemoryRemovalResult {
        EzraMemoryStore(memoriesDirectoryURL: memoriesDirectoryURL).removeMemory(withID: memory.id)
    }

    static func removeProfileFact(_ profileFactEntry: EzraProfileFactEntry, notesDirectoryURL: URL) -> EzraMemoryRemovalResult {
        EzraProfileStore(profileDirectoryURL: notesDirectoryURL).removeFact(
            atLineIndex: profileFactEntry.lineIndexInFile,
            expectingFactText: profileFactEntry.factText
        )
    }

    static func removeNote(_ noteEntry: EzraNoteEntry, notesDirectoryURL: URL) -> EzraMemoryRemovalResult {
        EzraNoteStore(notesDirectoryURL: notesDirectoryURL).removeNote(
            inFileNamed: noteEntry.sourceFileName,
            atLineIndex: noteEntry.lineIndexInFile,
            expectingNoteText: noteEntry.text
        )
    }
}

// MARK: - Where the panel's data lives

/// The folders the memory and usage tabs read: the notes folder (profile.md and the daily
/// notes), the folder of the metrics logs and, since round 16, the folder of the memories.
nonisolated struct EzraPanelDataLocations: Equatable, Sendable {
    let notesDirectoryURL: URL
    let metricsDirectoryURL: URL
    /// The memories folder. Nil means "no memories folder": the tab lists no memories and the
    /// folder is never touched. The callers that predate memories pass nothing and get nil, so none
    /// of them can reach the user's real memories by accident.
    let memoriesDirectoryURL: URL?
    /// The voices folder of the settings tab's voice picker (round 20): the kept voice list and the
    /// cached samples. Nil, like `memoriesDirectoryURL`, for every caller that predates it, so none
    /// of them can reach the real folder by accident.
    let voicesDirectoryURL: URL?
    /// The folder of the standing context (round 21b): `context.md`. Nil, like the two above, for every
    /// caller that predates it.
    let contextDirectoryURL: URL?

    init(notesDirectoryURL: URL, metricsDirectoryURL: URL, memoriesDirectoryURL: URL? = nil, voicesDirectoryURL: URL? = nil, contextDirectoryURL: URL? = nil) {
        self.notesDirectoryURL = notesDirectoryURL
        self.metricsDirectoryURL = metricsDirectoryURL
        self.memoriesDirectoryURL = memoriesDirectoryURL
        self.voicesDirectoryURL = voicesDirectoryURL
        self.contextDirectoryURL = contextDirectoryURL
    }

    static let notesDirectoryOverrideEnvironmentVariable = "EZRA_NOTES_DIRECTORY"
    static let metricsDirectoryOverrideEnvironmentVariable = "EZRA_METRICS_DIRECTORY"

    /// The user's real folders.
    static var real: EzraPanelDataLocations {
        EzraPanelDataLocations(
            notesDirectoryURL: EzraNoteStore.defaultNotesDirectoryURL,
            metricsDirectoryURL: EzraTurnMetricsLog.defaultLogFileURL.deletingLastPathComponent(),
            memoriesDirectoryURL: EzraMemoryStore.defaultMemoriesDirectoryURL,
            voicesDirectoryURL: EzraVoiceListCache.defaultVoicesDirectoryURL,
            contextDirectoryURL: EzraAgentContextStore.defaultDirectoryURL
        )
    }

    /// The folders for this run of the app.
    ///
    /// In a normal run these are always the real folders, and the two override variables are
    /// ignored. They are honoured only when the panel self test is on (`EZRA_PANEL_SELF_TEST=1`),
    /// so a stray variable can never point the memory tab's delete at somewhere unexpected. A self
    /// test run with no override gets a new folder in the temporary directory, because the self
    /// test writes sample facts, notes and metrics there: the real folders are never its fallback.
    static func forRun(
        environment: [String: String],
        temporaryDirectoryURL: URL,
        uniqueFolderNameSuffix: String
    ) -> EzraPanelDataLocations {
        guard environment[EzraChatStore.panelSelfTestEnvironmentVariable] == "1" else {
            return real
        }
        func directoryURL(overrideVariable: String, folderNamePrefix: String) -> URL {
            if let overridePath = environment[overrideVariable], !overridePath.isEmpty {
                return URL(fileURLWithPath: overridePath, isDirectory: true)
            }
            return temporaryDirectoryURL.appendingPathComponent(folderNamePrefix + uniqueFolderNameSuffix, isDirectory: true)
        }
        return EzraPanelDataLocations(
            notesDirectoryURL: directoryURL(
                overrideVariable: notesDirectoryOverrideEnvironmentVariable,
                folderNamePrefix: "ezra-panel-self-test-notes-"
            ),
            metricsDirectoryURL: directoryURL(
                overrideVariable: metricsDirectoryOverrideEnvironmentVariable,
                folderNamePrefix: "ezra-panel-self-test-logs-"
            ),
            // The memories folder has its own rule, shared with the store itself.
            memoriesDirectoryURL: EzraMemoryStore.directoryURLForRun(
                environment: environment,
                temporaryDirectoryURL: temporaryDirectoryURL,
                uniqueFolderNameForSelfTest: "ezra-panel-self-test-memories-" + uniqueFolderNameSuffix
            ),
            // Round 20: a self test's voice list and samples live in a new temporary folder (there is
            // no override variable), and the self test never asks the Worker for the list.
            voicesDirectoryURL: temporaryDirectoryURL.appendingPathComponent("ezra-panel-self-test-voices-" + uniqueFolderNameSuffix, isDirectory: true),
            // Round 21b: the context folder has its own rule too, shared with its store
            // (`EZRA_CONTEXT_DIRECTORY`, honoured only in a self test).
            contextDirectoryURL: EzraAgentContextStore.directoryURLForRun(
                environment: environment,
                temporaryDirectoryURL: temporaryDirectoryURL,
                uniqueFolderNameForSelfTest: EzraAgentContextStore.selfTestFolderNamePrefix + uniqueFolderNameSuffix
            )
        )
    }

    /// True when any of the folders is one of the user's real ones.
    var touchesARealFolder: Bool {
        let realLocations = Self.real
        let notesOrMetricsAreReal = notesDirectoryURL.standardizedFileURL.path == realLocations.notesDirectoryURL.standardizedFileURL.path
            || metricsDirectoryURL.standardizedFileURL.path == realLocations.metricsDirectoryURL.standardizedFileURL.path
        let memoriesAreReal: Bool = {
            guard let memoriesDirectoryURL, let realMemoriesDirectoryURL = realLocations.memoriesDirectoryURL else { return false }
            return memoriesDirectoryURL.standardizedFileURL.path == realMemoriesDirectoryURL.standardizedFileURL.path
        }()
        let voicesAreReal: Bool = {
            guard let voicesDirectoryURL, let realVoicesDirectoryURL = realLocations.voicesDirectoryURL else { return false }
            return voicesDirectoryURL.standardizedFileURL.path == realVoicesDirectoryURL.standardizedFileURL.path
        }()
        let contextIsReal: Bool = {
            guard let contextDirectoryURL, let realContextDirectoryURL = realLocations.contextDirectoryURL else { return false }
            return contextDirectoryURL.standardizedFileURL.path == realContextDirectoryURL.standardizedFileURL.path
        }()
        return notesOrMetricsAreReal || memoriesAreReal || voicesAreReal || contextIsReal
    }
}

// MARK: - Sample data for the self test and the offscreen pictures

/// Facts, notes and metrics lines for the panel self test and the offscreen pictures, written into
/// temporary folders only.
nonisolated enum EzraPanelSelfTestSamples {
    static let sampleProfileFileContents = """
    # Ezra profile

    - call me sam
    - uses xcode as their editor
    - prefers short answers
    - writes swift mostly

    """

    /// Writes the samples into `locations` unless a folder already holds files (a prepared test
    /// folder is left as it is) or one of them is a real folder of the user (never written).
    /// Returns what it wrote.
    @discardableResult
    static func writeSamples(into locations: EzraPanelDataLocations, now: Date = Date()) -> (wroteNotes: Bool, wroteMetrics: Bool) {
        guard !locations.touchesARealFolder else {
            return (false, false)
        }
        var wroteNotes = false
        if directoryHasNoFiles(locations.notesDirectoryURL) {
            writeSampleNotes(into: locations.notesDirectoryURL, now: now)
            wroteNotes = true
        }
        var wroteMetrics = false
        if directoryHasNoFiles(locations.metricsDirectoryURL) {
            writeSampleMetrics(into: locations.metricsDirectoryURL, now: now)
            wroteMetrics = true
        }
        return (wroteNotes, wroteMetrics)
    }

    /// Writes sample memories (round 16) into the memories folder when it is empty and neither it
    /// nor any other folder of `locations` is a real one. Separate from `writeSamples`, whose
    /// two-value result stays as it was. Returns whether it wrote.
    @discardableResult
    static func writeSampleMemories(into locations: EzraPanelDataLocations, now: Date = Date()) -> Bool {
        guard !locations.touchesARealFolder,
              let memoriesDirectoryURL = locations.memoriesDirectoryURL,
              directoryHasNoFiles(memoriesDirectoryURL) else {
            return false
        }
        let memoryStore = EzraMemoryStore(memoriesDirectoryURL: memoriesDirectoryURL)
        let secondsPerHour: TimeInterval = 3_600
        // Oldest first, so the newest is saved last and listed first.
        let sampleMemories: [(text: String, hoursAgo: Double)] = [
            ("renew the car insurance by the end of march", 24 * 21),
            ("ezra's worker is called clicky-proxy", 24 * 6),
            ("chose a local mcp server for google, not the hosted one", 24 * 2 + 5),
            ("the kb connects demo is on friday", 26),
            ("follow up with priya about the invoice template", 3),
        ]
        for sampleMemory in sampleMemories {
            memoryStore.addMemories(
                texts: [sampleMemory.text],
                sourceChatID: nil,
                createdAt: now.addingTimeInterval(-sampleMemory.hoursAgo * secondsPerHour)
            )
        }
        return true
    }

    /// The fake id of the sample voice that stands for the Worker's default in the self test and the
    /// offscreen pictures. Every sample id is made up and starts with "sample-voice-".
    static let sampleWorkerDefaultVoiceID = "sample-voice-harbor"

    /// Six made-up voices for the panel self test and the offscreen pictures (round 20): two of the
    /// account's own (cloned and generated) and four premade ones, one of which stands for the
    /// Worker's default. No real voice id or name of any account. Their describing label is
    /// "descriptive", the key the account's own voices carry.
    static let sampleVoiceList = EzraVoiceList(
        voices: [
            EzraVoice(id: "sample-voice-studio-me", name: "my studio voice", category: "cloned", labels: ["accent": "dutch", "descriptive": "warm"]),
            EzraVoice(id: "sample-voice-night-reader", name: "night reader", category: "generated", labels: ["gender": "female", "age": "middle aged", "descriptive": "soft"]),
            EzraVoice(id: "sample-voice-juniper", name: "Juniper", category: "premade", labels: ["accent": "american", "gender": "female", "age": "young", "descriptive": "calm"]),
            EzraVoice(id: sampleWorkerDefaultVoiceID, name: "Harbor", category: "premade", labels: ["accent": "british", "gender": "male", "age": "middle aged", "descriptive": "steady"]),
            EzraVoice(id: "sample-voice-maple", name: "Maple", category: "premade", labels: ["accent": "australian", "gender": "female", "descriptive": "bright"]),
            EzraVoice(id: "sample-voice-quill", name: "Quill", category: "premade", labels: ["accent": "american", "gender": "male", "age": "old", "descriptive": "deep"]),
        ],
        defaultVoiceID: sampleWorkerDefaultVoiceID,
        fetchedAt: Date(timeIntervalSince1970: 1_794_700_000)
    )

    /// Writes the six sample voices as the kept voice list (round 20), so the settings tab shows a
    /// list without asking the Worker. Only into an empty voices folder, and never when any folder
    /// of `locations` is a real one. Returns whether it wrote.
    @discardableResult
    static func writeSampleVoices(into locations: EzraPanelDataLocations, now: Date = Date()) -> Bool {
        guard !locations.touchesARealFolder,
              let voicesDirectoryURL = locations.voicesDirectoryURL,
              directoryHasNoFiles(voicesDirectoryURL) else {
            return false
        }
        var sampleVoiceListFetchedNow = sampleVoiceList
        sampleVoiceListFetchedNow.fetchedAt = now
        return EzraVoiceListCache.saveVoiceList(sampleVoiceListFetchedNow, toVoicesDirectory: voicesDirectoryURL)
    }

    /// A made-up standing context (round 21b) of about 300 characters. Its fourth line holds a sample key
    /// shape (made up, never a real key), so the context tab shows its warning next to the count.
    static let sampleContextText = """
    i'm sam. i build ezra, a mac menu bar assistant in swift, and kb connects, a receptionist service.
    answer in one short sentence unless i ask for detail.
    my worker is called clicky-proxy and runs on cloudflare.
    sample key for the self test: sk-sample-0000000000000000
    i use xcode and the terminal every day.
    """

    /// Writes the sample context as `context.md` through the store's own save (round 21b), only into an
    /// empty context folder, and never when any folder of `locations` is a real one. Returns whether it
    /// wrote.
    @discardableResult
    static func writeSampleContext(into locations: EzraPanelDataLocations) -> Bool {
        guard !locations.touchesARealFolder,
              let contextDirectoryURL = locations.contextDirectoryURL,
              directoryHasNoFiles(contextDirectoryURL) else {
            return false
        }
        let sampleContextStore = EzraAgentContextStore(directoryURL: contextDirectoryURL)
        sampleContextStore.setCurrentText(sampleContextText)
        sampleContextStore.flushPendingSaveNow()
        return FileManager.default.fileExists(atPath: sampleContextStore.fileURL.path)
    }

    private static func directoryHasNoFiles(_ directoryURL: URL) -> Bool {
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return fileNames.isEmpty
    }

    private static func writeSampleNotes(into notesDirectoryURL: URL, now: Date) {
        try? FileManager.default.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)
        try? sampleProfileFileContents.write(
            to: notesDirectoryURL.appendingPathComponent(EzraProfileStore.profileFileName),
            atomically: true,
            encoding: .utf8
        )
        let noteStore = EzraNoteStore(notesDirectoryURL: notesDirectoryURL)
        let secondsPerHour: TimeInterval = 3_600
        let sampleNotes: [(text: String, hoursAgo: Double)] = [
            ("the dentist is on friday at 3", 0.4),
            ("parking spot is on level 2, near the lift", 5),
            ("mum's birthday is on the 24th", 28),
            ("the build server is called atlas", 24 * 9 + 2),
            ("renew the car insurance in march", 24 * 45),
        ]
        for sampleNote in sampleNotes {
            _ = try? noteStore.saveNote(text: sampleNote.text, savedAt: now.addingTimeInterval(-sampleNote.hoursAgo * secondsPerHour))
        }
    }

    private static func writeSampleMetrics(into metricsDirectoryURL: URL, now: Date) {
        let turnLogFileURL = metricsDirectoryURL.appendingPathComponent(EzraUsageLogReader.turnLogFileName)
        let dictationLogFileURL = metricsDirectoryURL.appendingPathComponent(EzraUsageLogReader.dictationLogFileName)
        let secondsPerHour: TimeInterval = 3_600

        func appendTurn(
            hoursAgo: Double,
            modelName: String = "claude-sonnet-5-5",
            inputMode: EzraTurnInputMode = .spoken,
            outcome: EzraTurnOutcome = .completed,
            inputTokens: Int,
            outputTokens: Int,
            cacheReadTokens: Int,
            cacheWriteTokens: Int,
            firstWordMilliseconds: Int?,
            firstReplyTextMilliseconds: Int,
            spokenCharacters: Int
        ) {
            var turnMetrics = EzraTurnMetrics(turnStartedAt: now.addingTimeInterval(-hoursAgo * secondsPerHour), modelName: modelName)
            turnMetrics.inputMode = inputMode
            turnMetrics.outcome = outcome
            turnMetrics.timeToFirstReplyTextMilliseconds = firstReplyTextMilliseconds
            turnMetrics.tokenUsage = EzraClaudeTokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationInputTokens: cacheWriteTokens,
                cacheReadInputTokens: cacheReadTokens
            )
            turnMetrics.spokenReplyCharacterCount = spokenCharacters
            if let firstWordMilliseconds {
                turnMetrics.keyReleaseToAudioStartMilliseconds = firstWordMilliseconds
                turnMetrics.textToSpeechMilliseconds = 180
            }
            if outcome == .failed {
                turnMetrics.unfinishedStep = .claudeRequest
            }
            if let turnLine = turnMetrics.makeJSONLine() {
                EzraTurnMetricsLog.appendLine(turnLine, to: turnLogFileURL)
            }
        }

        // Earlier this month and last month, oldest first (the log is written oldest first).
        appendTurn(hoursAgo: 24 * 40, inputTokens: 900, outputTokens: 60, cacheReadTokens: 5_000, cacheWriteTokens: 0, firstWordMilliseconds: 1_900, firstReplyTextMilliseconds: 800, spokenCharacters: 110)
        appendTurn(hoursAgo: 24 * 12, inputTokens: 1_100, outputTokens: 70, cacheReadTokens: 5_000, cacheWriteTokens: 0, firstWordMilliseconds: 1_700, firstReplyTextMilliseconds: 760, spokenCharacters: 130)
        appendTurn(hoursAgo: 24 * 9, modelName: "claude-opus-4-6", inputTokens: 1_300, outputTokens: 90, cacheReadTokens: 0, cacheWriteTokens: 5_200, firstWordMilliseconds: 2_600, firstReplyTextMilliseconds: 1_400, spokenCharacters: 160)
        appendTurn(hoursAgo: 24 * 6, inputTokens: 1_250, outputTokens: 80, cacheReadTokens: 5_000, cacheWriteTokens: 0, firstWordMilliseconds: 1_500, firstReplyTextMilliseconds: 700, spokenCharacters: 120)
        appendTurn(hoursAgo: 24 * 4, inputMode: .typed, inputTokens: 1_400, outputTokens: 120, cacheReadTokens: 5_000, cacheWriteTokens: 0, firstWordMilliseconds: nil, firstReplyTextMilliseconds: 900, spokenCharacters: 240)
        appendTurn(hoursAgo: 24 * 3, outcome: .failed, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, firstWordMilliseconds: nil, firstReplyTextMilliseconds: 0, spokenCharacters: 0)
        // Today.
        appendTurn(hoursAgo: 6, inputTokens: 1_200, outputTokens: 75, cacheReadTokens: 5_000, cacheWriteTokens: 0, firstWordMilliseconds: 1_400, firstReplyTextMilliseconds: 640, spokenCharacters: 118)
        appendTurn(hoursAgo: 3, inputTokens: 1_350, outputTokens: 95, cacheReadTokens: 5_000, cacheWriteTokens: 0, firstWordMilliseconds: 1_600, firstReplyTextMilliseconds: 720, spokenCharacters: 142)
        appendTurn(hoursAgo: 1, inputMode: .typed, inputTokens: 1_500, outputTokens: 130, cacheReadTokens: 5_000, cacheWriteTokens: 0, firstWordMilliseconds: nil, firstReplyTextMilliseconds: 880, spokenCharacters: 260)
        appendTurn(hoursAgo: 0.2, inputTokens: 1_280, outputTokens: 85, cacheReadTokens: 5_000, cacheWriteTokens: 0, firstWordMilliseconds: 1_300, firstReplyTextMilliseconds: 610, spokenCharacters: 105)

        func appendDictation(hoursAgo: Double, cleanupOutcome: EzraDictationCleanupOutcome, cleanupInputTokens: Int?, cleanupOutputTokens: Int?) {
            var dictationMetrics = EzraDictationMetrics(
                startedAt: now.addingTimeInterval(-hoursAgo * secondsPerHour),
                insertionOutcome: .pasted,
                wasHandsFree: false
            )
            dictationMetrics.audioSeconds = 6.4
            dictationMetrics.cleanupOutcome = cleanupOutcome
            dictationMetrics.cleanupInputTokens = cleanupInputTokens
            dictationMetrics.cleanupOutputTokens = cleanupOutputTokens
            if let dictationLine = dictationMetrics.makeJSONLine() {
                EzraTurnMetricsLog.appendLine(dictationLine, to: dictationLogFileURL)
            }
        }
        // An older dictation from before the cleanup tokens were logged, then newer ones with them.
        appendDictation(hoursAgo: 24 * 8, cleanupOutcome: .used, cleanupInputTokens: nil, cleanupOutputTokens: nil)
        appendDictation(hoursAgo: 24 * 2, cleanupOutcome: .used, cleanupInputTokens: 410, cleanupOutputTokens: 52)
        appendDictation(hoursAgo: 5, cleanupOutcome: .used, cleanupInputTokens: 395, cleanupOutputTokens: 44)
        appendDictation(hoursAgo: 2, cleanupOutcome: .skipped, cleanupInputTokens: nil, cleanupOutputTokens: nil)

        // Round 16: the memory compaction log, for the usage tab's "memories" row. Three chats compacted
        // (two this month before today, one today), one attempt that failed and one skipped.
        let memoryCompactionLogFileURL = metricsDirectoryURL.appendingPathComponent(EzraUsageLogReader.memoryCompactionLogFileName)
        func appendMemoryCompaction(
            hoursAgo: Double,
            outcome: EzraMemoryCompactionMetricsOutcome,
            exchangeCount: Int,
            memoriesKept: Int,
            inputTokens: Int?,
            outputTokens: Int?
        ) {
            let memoryCompactionMetrics = EzraMemoryCompactionMetrics(
                timestamp: now.addingTimeInterval(-hoursAgo * secondsPerHour),
                trigger: .idleTimer,
                outcome: outcome,
                exchangeCount: exchangeCount,
                memoriesKept: memoriesKept,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                durationMilliseconds: outcome == .skipped ? nil : 1_100
            )
            if let memoryCompactionLine = memoryCompactionMetrics.makeJSONLine() {
                EzraTurnMetricsLog.appendLine(memoryCompactionLine, to: memoryCompactionLogFileURL)
            }
        }
        appendMemoryCompaction(hoursAgo: 24 * 9, outcome: .completed, exchangeCount: 4, memoriesKept: 2, inputTokens: 1_180, outputTokens: 64)
        appendMemoryCompaction(hoursAgo: 24 * 3, outcome: .completed, exchangeCount: 7, memoriesKept: 1, inputTokens: 2_050, outputTokens: 31)
        appendMemoryCompaction(hoursAgo: 24 * 2, outcome: .skipped, exchangeCount: 1, memoriesKept: 0, inputTokens: nil, outputTokens: nil)
        appendMemoryCompaction(hoursAgo: 30, outcome: .failed, exchangeCount: 3, memoriesKept: 0, inputTokens: nil, outputTokens: nil)
        appendMemoryCompaction(hoursAgo: 4, outcome: .completed, exchangeCount: 3, memoriesKept: 2, inputTokens: 1_460, outputTokens: 47)
    }
}
