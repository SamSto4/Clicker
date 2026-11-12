import Foundation

// The memory tab of the chat panel (round 15): what it lists (the profile's facts and the daily
// notes), how it reads them without ever waiting on `~/Documents` on the main thread, how it
// cuts exactly one line out of a file, where the panel's data lives (and how a self test is kept
// away from the real folders), and the sample data the self test shows.
//
// This adds no way to save anything and changes nothing about how memory is saved or injected.

// MARK: - Lines with their line breaks

/// One line of a text file together with its own line break.
nonisolated struct ClickyMemoryFileLine: Equatable, Sendable {
    /// The line without its line break.
    let text: String
    /// "\n", "\r\n" or another break `Character.isNewline` knows; empty for a last line that has none.
    let lineBreak: String
}

/// Splits a file into lines without losing anything, so that one line can be cut out and the
/// rest written back exactly as it was.
nonisolated enum ClickyMemoryFileLines {
    /// The lines of the file, each with the break that ended it. Joining `text + lineBreak` of
    /// every line gives the file back, byte for byte. A file that ends with a line break has no
    /// extra empty line after it. A "\r\n" is one break (it is one `Character` in Swift), the same
    /// way `ClickyProfileStore` has always split its file, so line numbers agree.
    static func lines(of fileContents: String) -> [ClickyMemoryFileLine] {
        var fileLines: [ClickyMemoryFileLine] = []
        var currentLineText = ""
        for character in fileContents {
            if character.isNewline {
                fileLines.append(ClickyMemoryFileLine(text: currentLineText, lineBreak: String(character)))
                currentLineText = ""
            } else {
                currentLineText.append(character)
            }
        }
        if !currentLineText.isEmpty {
            fileLines.append(ClickyMemoryFileLine(text: currentLineText, lineBreak: ""))
        }
        return fileLines
    }

    /// The file without one line and that line's own break. Every other line keeps its own break.
    static func fileContents(from fileLines: [ClickyMemoryFileLine], removingLineAt lineIndexToRemove: Int) -> String {
        var fileContents = ""
        for (lineIndex, fileLine) in fileLines.enumerated() where lineIndex != lineIndexToRemove {
            fileContents += fileLine.text
            fileContents += fileLine.lineBreak
        }
        return fileContents
    }
}

// MARK: - What the tab lists

nonisolated struct ClickyMemoryPanelContents: Equatable, Sendable {
    /// The most notes the tab lists (the newest). A long-used notes folder can hold thousands, and
    /// the tab is a place to look and tidy up, not to page through a year.
    static let maximumNotesListed = 200

    /// The profile's facts in file order, so the newest is last (as `ClickyProfileStore` reads them).
    var profileFacts: [ClickyProfileFactEntry]
    /// The notes, newest first, at most `maximumNotesListed`.
    var notes: [ClickyNoteEntry]
    /// How many notes there are in all, so the tab can say when it lists only the newest.
    var totalNoteCount: Int

    static let empty = ClickyMemoryPanelContents(profileFacts: [], notes: [], totalNoteCount: 0)

    var isEmpty: Bool {
        profileFacts.isEmpty && totalNoteCount == 0
    }

    /// The contents with one row taken out, so the row disappears the moment it is deleted and the
    /// real answer from the disk replaces this when it arrives.
    func removingRow(withIdentifier rowIdentifier: String) -> ClickyMemoryPanelContents {
        var contentsWithoutRow = self
        contentsWithoutRow.profileFacts.removeAll { $0.identifier == rowIdentifier }
        let noteCountBefore = contentsWithoutRow.notes.count
        contentsWithoutRow.notes.removeAll { $0.identifier == rowIdentifier }
        if contentsWithoutRow.notes.count < noteCountBefore {
            contentsWithoutRow.totalNoteCount = max(0, totalNoteCount - 1)
        }
        return contentsWithoutRow
    }
}

/// How the tab writes a note's time. Lowercase, like every other word Clicky shows.
nonisolated enum ClickyMemoryPanelText {
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
/// app already keeps (`ClickyMemoryFileSnapshotCache`), so the tab shows something immediately,
/// and `contentsAfterRefreshingFromDisk` then re-reads the folder, which is the slow part, and
/// replaces it. A folder the cache is not switched on for (every test folder) has no copy and is
/// always read from disk.
nonisolated enum ClickyMemoryPanelLoader {
    /// The contents of a notes folder given as file name to text. Pure.
    static func contents(fromMarkdownFileContentsByFileName markdownFileContentsByFileName: [String: String]) -> ClickyMemoryPanelContents {
        let profileFacts = markdownFileContentsByFileName[ClickyProfileStore.profileFileName]
            .map { ClickyProfileStore.factEntries(fromFileContents: $0) } ?? []

        // Newest first: by time, and for notes with the same time the later line first.
        let allNotesNewestFirst = ClickyNoteStore.noteEntries(fromMarkdownFileContentsByFileName: markdownFileContentsByFileName)
            .sorted { firstNote, secondNote in
                if firstNote.savedAt != secondNote.savedAt {
                    return firstNote.savedAt > secondNote.savedAt
                }
                if firstNote.sourceFileName != secondNote.sourceFileName {
                    return firstNote.sourceFileName > secondNote.sourceFileName
                }
                return firstNote.lineIndexInFile > secondNote.lineIndexInFile
            }
        return ClickyMemoryPanelContents(
            profileFacts: profileFacts,
            notes: Array(allNotesNewestFirst.prefix(ClickyMemoryPanelContents.maximumNotesListed)),
            totalNoteCount: allNotesNewestFirst.count
        )
    }

    /// The in-memory copy of the folder, or nil when the cache has none. Never touches the disk.
    static func contentsFromCacheWithoutReadingDisk(notesDirectoryURL: URL) -> ClickyMemoryPanelContents? {
        guard let cachedMarkdownFileContentsByFileName = ClickyMemoryFileSnapshotCache.shared
            .cachedMarkdownFileContentsByFileName(inDirectory: notesDirectoryURL) else {
            return nil
        }
        return contents(fromMarkdownFileContentsByFileName: cachedMarkdownFileContentsByFileName)
    }

    /// Re-reads the folder (this refreshes the cache for a cached folder) and returns what it holds.
    static func contentsAfterRefreshingFromDisk(notesDirectoryURL: URL) -> ClickyMemoryPanelContents {
        ClickyMemoryFileSnapshotCache.shared.refresh(directory: notesDirectoryURL)
        let markdownFileContentsByFileName = ClickyMemoryFileSnapshotCache.shared
            .cachedMarkdownFileContentsByFileName(inDirectory: notesDirectoryURL)
            ?? ClickyMemoryFileSnapshotCache.readMarkdownFilesFromDisk(inDirectory: notesDirectoryURL)
        return contents(fromMarkdownFileContentsByFileName: markdownFileContentsByFileName)
    }

    static func removeProfileFact(_ profileFactEntry: ClickyProfileFactEntry, notesDirectoryURL: URL) -> ClickyMemoryRemovalResult {
        ClickyProfileStore(profileDirectoryURL: notesDirectoryURL).removeFact(
            atLineIndex: profileFactEntry.lineIndexInFile,
            expectingFactText: profileFactEntry.factText
        )
    }

    static func removeNote(_ noteEntry: ClickyNoteEntry, notesDirectoryURL: URL) -> ClickyMemoryRemovalResult {
        ClickyNoteStore(notesDirectoryURL: notesDirectoryURL).removeNote(
            inFileNamed: noteEntry.sourceFileName,
            atLineIndex: noteEntry.lineIndexInFile,
            expectingNoteText: noteEntry.text
        )
    }
}

// MARK: - Where the panel's data lives

/// The two folders the memory and usage tabs read: the notes folder (profile.md and the daily
/// notes) and the folder of the two metrics logs.
nonisolated struct ClickyPanelDataLocations: Equatable, Sendable {
    let notesDirectoryURL: URL
    let metricsDirectoryURL: URL

    static let notesDirectoryOverrideEnvironmentVariable = "CLICKY_NOTES_DIRECTORY"
    static let metricsDirectoryOverrideEnvironmentVariable = "CLICKY_METRICS_DIRECTORY"

    /// The user's real folders.
    static var real: ClickyPanelDataLocations {
        ClickyPanelDataLocations(
            notesDirectoryURL: ClickyNoteStore.defaultNotesDirectoryURL,
            metricsDirectoryURL: ClickyTurnMetricsLog.defaultLogFileURL.deletingLastPathComponent()
        )
    }

    /// The folders for this run of the app.
    ///
    /// In a normal run these are always the real folders, and the two override variables are
    /// ignored. They are honoured only when the panel self test is on (`CLICKY_PANEL_SELF_TEST=1`),
    /// so a stray variable can never point the memory tab's delete at somewhere unexpected. A self
    /// test run with no override gets a new folder in the temporary directory, because the self
    /// test writes sample facts, notes and metrics there: the real folders are never its fallback.
    static func forRun(
        environment: [String: String],
        temporaryDirectoryURL: URL,
        uniqueFolderNameSuffix: String
    ) -> ClickyPanelDataLocations {
        guard environment[ClickyChatStore.panelSelfTestEnvironmentVariable] == "1" else {
            return real
        }
        func directoryURL(overrideVariable: String, folderNamePrefix: String) -> URL {
            if let overridePath = environment[overrideVariable], !overridePath.isEmpty {
                return URL(fileURLWithPath: overridePath, isDirectory: true)
            }
            return temporaryDirectoryURL.appendingPathComponent(folderNamePrefix + uniqueFolderNameSuffix, isDirectory: true)
        }
        return ClickyPanelDataLocations(
            notesDirectoryURL: directoryURL(
                overrideVariable: notesDirectoryOverrideEnvironmentVariable,
                folderNamePrefix: "clicky-panel-self-test-notes-"
            ),
            metricsDirectoryURL: directoryURL(
                overrideVariable: metricsDirectoryOverrideEnvironmentVariable,
                folderNamePrefix: "clicky-panel-self-test-logs-"
            )
        )
    }

    /// True when either folder is one of the user's real ones.
    var touchesARealFolder: Bool {
        let realLocations = Self.real
        return notesDirectoryURL.standardizedFileURL.path == realLocations.notesDirectoryURL.standardizedFileURL.path
            || metricsDirectoryURL.standardizedFileURL.path == realLocations.metricsDirectoryURL.standardizedFileURL.path
    }
}

// MARK: - Sample data for the self test and the offscreen pictures

/// Facts, notes and metrics lines for the panel self test and the offscreen pictures, written into
/// temporary folders only.
nonisolated enum ClickyPanelSelfTestSamples {
    static let sampleProfileFileContents = """
    # Clicky profile

    - call me sam
    - uses xcode as their editor
    - prefers short answers
    - writes swift mostly

    """

    /// Writes the samples into `locations` unless a folder already holds files (a prepared test
    /// folder is left as it is) or one of them is a real folder of the user (never written).
    /// Returns what it wrote.
    @discardableResult
    static func writeSamples(into locations: ClickyPanelDataLocations, now: Date = Date()) -> (wroteNotes: Bool, wroteMetrics: Bool) {
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

    private static func directoryHasNoFiles(_ directoryURL: URL) -> Bool {
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return fileNames.isEmpty
    }

    private static func writeSampleNotes(into notesDirectoryURL: URL, now: Date) {
        try? FileManager.default.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)
        try? sampleProfileFileContents.write(
            to: notesDirectoryURL.appendingPathComponent(ClickyProfileStore.profileFileName),
            atomically: true,
            encoding: .utf8
        )
        let noteStore = ClickyNoteStore(notesDirectoryURL: notesDirectoryURL)
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
        let turnLogFileURL = metricsDirectoryURL.appendingPathComponent(ClickyUsageLogReader.turnLogFileName)
        let dictationLogFileURL = metricsDirectoryURL.appendingPathComponent(ClickyUsageLogReader.dictationLogFileName)
        let secondsPerHour: TimeInterval = 3_600

        func appendTurn(
            hoursAgo: Double,
            modelName: String = "claude-sonnet-5-5",
            inputMode: ClickyTurnInputMode = .spoken,
            outcome: ClickyTurnOutcome = .completed,
            inputTokens: Int,
            outputTokens: Int,
            cacheReadTokens: Int,
            cacheWriteTokens: Int,
            firstWordMilliseconds: Int?,
            firstReplyTextMilliseconds: Int,
            spokenCharacters: Int
        ) {
            var turnMetrics = ClickyTurnMetrics(turnStartedAt: now.addingTimeInterval(-hoursAgo * secondsPerHour), modelName: modelName)
            turnMetrics.inputMode = inputMode
            turnMetrics.outcome = outcome
            turnMetrics.timeToFirstReplyTextMilliseconds = firstReplyTextMilliseconds
            turnMetrics.tokenUsage = ClickyClaudeTokenUsage(
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
                ClickyTurnMetricsLog.appendLine(turnLine, to: turnLogFileURL)
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

        func appendDictation(hoursAgo: Double, cleanupOutcome: ClickyDictationCleanupOutcome, cleanupInputTokens: Int?, cleanupOutputTokens: Int?) {
            var dictationMetrics = ClickyDictationMetrics(
                startedAt: now.addingTimeInterval(-hoursAgo * secondsPerHour),
                insertionOutcome: .pasted,
                wasHandsFree: false
            )
            dictationMetrics.audioSeconds = 6.4
            dictationMetrics.cleanupOutcome = cleanupOutcome
            dictationMetrics.cleanupInputTokens = cleanupInputTokens
            dictationMetrics.cleanupOutputTokens = cleanupOutputTokens
            if let dictationLine = dictationMetrics.makeJSONLine() {
                ClickyTurnMetricsLog.appendLine(dictationLine, to: dictationLogFileURL)
            }
        }
        // An older dictation from before the cleanup tokens were logged, then newer ones with them.
        appendDictation(hoursAgo: 24 * 8, cleanupOutcome: .used, cleanupInputTokens: nil, cleanupOutputTokens: nil)
        appendDictation(hoursAgo: 24 * 2, cleanupOutcome: .used, cleanupInputTokens: 410, cleanupOutputTokens: 52)
        appendDictation(hoursAgo: 5, cleanupOutcome: .used, cleanupInputTokens: 395, cleanupOutputTokens: 44)
        appendDictation(hoursAgo: 2, cleanupOutcome: .skipped, cleanupInputTokens: nil, cleanupOutputTokens: nil)
    }
}
