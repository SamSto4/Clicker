import Foundation

/// One saved note, as read back from a daily notes file.
nonisolated struct ClickyNote: Equatable, Hashable {
    /// Minute-level timestamp in the user's local time zone.
    let savedAt: Date
    let text: String
    /// File the note lives in, such as "2026-11-10.md", so logs can say where a note was found.
    let sourceFileName: String
}

nonisolated enum ClickyNoteStoreError: Error {
    case noteTextIsEmpty
}

/// Notes are plain markdown files, one per local day, in ~/Documents/Clicky Notes.
/// Plain files let the user read and hand-edit their notes in any editor.
nonisolated struct ClickyNoteStore {
    static let maximumNoteTextCharacterCount = 400

    /// Limits for notes injected into the prompt. Every note is sent to Claude on every turn,
    /// so these caps keep latency and cost bounded as the notes grow.
    static let maximumRelevantNoteCount = 8
    static let maximumRelevantNotesCharacterCount = 1500
    static let maximumFullRecallNoteCount = 20
    static let maximumFullRecallNotesCharacterCount = 3000

    /// When the whole store fits this small budget, every note is sent instead of a lexical pick.
    /// Word matching misses paraphrases ("doctor" for "dentist"), and the model matches meaning
    /// far better than a prefix check, so a small store is cheaper to send whole than to rank.
    static let maximumWholeStoreNoteCount = 15
    static let maximumWholeStoreNotesCharacterCount = 1500

    /// The most recent notes are always included so that "my dentist" still works when the
    /// transcript shares no words with the note.
    static let recencyWindowInDays = 14
    static let alwaysIncludedRecentNoteCount = 3

    /// Words shorter than this, or in the stopword list, never count as a match.
    static let minimumMatchTokenCharacterCount = 3
    /// Matching on a 5-character prefix lets "dentist" match "dentists" without a stemmer.
    static let matchTokenPrefixLength = 5
    static let matchStopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "what", "when", "where", "which", "who", "how",
        "did", "does", "do", "you", "your", "are", "was", "were", "have", "has", "had", "not", "but",
        "from", "about", "remember", "note", "notes", "told", "said", "tell", "know", "just", "can",
        "could", "would", "should", "will", "make", "want", "need", "please", "clicky", "hey", "there",
        "they", "them", "their", "its", "into", "out", "all", "any",
    ]

    let notesDirectoryURL: URL

    static var defaultNotesDirectoryURL: URL {
        let documentsDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        return documentsDirectoryURL.appendingPathComponent("Clicky Notes", isDirectory: true)
    }

    /// Notes are one line each. Newlines from dictation or a tag that spans lines become spaces,
    /// and an over-long note is cut rather than rejected.
    static func normalizedSingleLineNoteText(_ rawNoteText: String) -> String {
        let trimmedLineTexts = rawNoteText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let singleLineText = trimmedLineTexts.joined(separator: " ")
        return String(singleLineText.prefix(maximumNoteTextCharacterCount))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Appends one note to today's file. A note with the same words as a note already saved in the
    /// same minute is treated as a repeat and returns the existing note without writing again.
    @discardableResult
    func saveNote(text: String, savedAt: Date = Date()) throws -> ClickyNote {
        let normalizedNoteText = Self.normalizedSingleLineNoteText(text)
        guard !normalizedNoteText.isEmpty else {
            throw ClickyNoteStoreError.noteTextIsEmpty
        }

        let minuteTruncatedSavedAt = Self.minuteTruncated(savedAt)
        let dayFileName = Self.dayFileName(for: minuteTruncatedSavedAt)
        let dayFileURL = notesDirectoryURL.appendingPathComponent(dayFileName)
        let dayStartDate = Calendar.current.startOfDay(for: minuteTruncatedSavedAt)

        try FileManager.default.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)

        // A read failure on an existing file must throw. Treating it as empty would overwrite the
        // user's notes for that day.
        var existingFileContents: String
        if FileManager.default.fileExists(atPath: dayFileURL.path) {
            existingFileContents = try String(contentsOf: dayFileURL, encoding: .utf8)
        } else {
            existingFileContents = "# Clicky notes \(Self.formattedDate(minuteTruncatedSavedAt, dateFormat: "yyyy-MM-dd"))\n\n"
        }

        let notesAlreadySavedInSameMinute = Self.parseNotes(
            fromFileContents: existingFileContents,
            dayStartDate: dayStartDate,
            fileName: dayFileName
        ).filter { existingNote in
            Self.minuteTruncated(existingNote.savedAt) == minuteTruncatedSavedAt
        }
        if let duplicateNote = notesAlreadySavedInSameMinute.first(where: { existingNote in
            existingNote.text.lowercased() == normalizedNoteText.lowercased()
        }) {
            return duplicateNote
        }

        if !existingFileContents.isEmpty && !existingFileContents.hasSuffix("\n") {
            existingFileContents += "\n"
        }
        let minuteText = Self.formattedDate(minuteTruncatedSavedAt, dateFormat: "HH:mm")
        let newLineText = "- \(minuteText) — \(normalizedNoteText)\n"
        try (existingFileContents + newLineText).write(to: dayFileURL, atomically: true, encoding: .utf8)
        ClickyMemoryFileSnapshotCache.shared.refresh(directory: notesDirectoryURL)

        return ClickyNote(savedAt: minuteTruncatedSavedAt, text: normalizedNoteText, sourceFileName: dayFileName)
    }

    /// Reads every daily file in oldest-to-newest order. A missing folder or an unreadable file
    /// yields no notes instead of an error, because a notes problem must never block an answer.
    /// `preferringCachedFiles` is true only for the read that builds a turn's prompt: it then uses
    /// the in-memory copy of the folder when there is one, so the turn never waits for the disk.
    /// Saving and removing always read from disk.
    func loadAllNotes(preferringCachedFiles: Bool = false) -> [ClickyNote] {
        let cachedMarkdownFileContentsByFileName = preferringCachedFiles
            ? ClickyMemoryFileSnapshotCache.shared.cachedMarkdownFileContentsByFileName(inDirectory: notesDirectoryURL)
            : nil
        let markdownFileContentsByFileName = cachedMarkdownFileContentsByFileName
            ?? ClickyMemoryFileSnapshotCache.readMarkdownFilesFromDisk(inDirectory: notesDirectoryURL)

        var loadedNotes: [ClickyNote] = []
        // Files are named yyyy-MM-dd.md, so sorting by file name sorts by day.
        for fileName in markdownFileContentsByFileName.keys.sorted() {
            guard let dayStartDate = Self.dayStartDate(fromFileName: fileName),
                  let fileContents = markdownFileContentsByFileName[fileName] else {
                continue
            }
            loadedNotes += Self.parseNotes(
                fromFileContents: fileContents,
                dayStartDate: dayStartDate,
                fileName: fileName
            )
        }
        return loadedNotes
    }

    /// Picks the notes to inject for one turn.
    /// - Full recall (the user asked what you remember): the newest notes, up to a higher cap.
    /// - Small store (the whole store fits the whole-store budget): every note, newest first, so
    ///   the model can match paraphrases itself.
    /// - Otherwise: notes sharing words with the transcript, best match first, plus the newest
    ///   recent notes so that a note is never lost just because the words differ.
    func notesRelevant(toTranscript userTranscript: String, wantsFullRecall: Bool, now: Date = Date()) -> [ClickyNote] {
        let allNotes = loadAllNotes(preferringCachedFiles: true)
        guard !allNotes.isEmpty else {
            return []
        }

        let newestFirstNotes = allNotes.sorted { $0.savedAt > $1.savedAt }

        if wantsFullRecall {
            return Self.notesWithinLimits(
                newestFirstNotes,
                maximumNoteCount: Self.maximumFullRecallNoteCount,
                maximumCharacterCount: Self.maximumFullRecallNotesCharacterCount
            )
        }

        let allNotesTotalCharacterCount = allNotes.reduce(0) { runningTotalCharacterCount, note in
            runningTotalCharacterCount + note.text.count
        }
        let wholeStoreFitsSmallBudget = allNotes.count <= Self.maximumWholeStoreNoteCount
            && allNotesTotalCharacterCount <= Self.maximumWholeStoreNotesCharacterCount
        if wholeStoreFitsSmallBudget {
            return newestFirstNotes
        }

        let transcriptPrefixes = Set(Self.matchTokens(in: userTranscript).map(Self.matchPrefix))
        let recencyCutoffDate = now.addingTimeInterval(-Double(Self.recencyWindowInDays) * 86_400)
        let recentNotes = Array(
            allNotes
                .filter { $0.savedAt >= recencyCutoffDate }
                .sorted { $0.savedAt > $1.savedAt }
                .prefix(Self.alwaysIncludedRecentNoteCount)
        )

        let matchedNotesRankedByScore: [ClickyNote] = allNotes
            .compactMap { note -> (note: ClickyNote, score: Double)? in
                let matchedPrefixCount = Set(Self.matchTokens(in: note.text).map(Self.matchPrefix))
                    .intersection(transcriptPrefixes)
                    .count
                guard matchedPrefixCount > 0 else {
                    return nil
                }
                // Each matched word is worth far more than any recency bonus, so recency only
                // breaks ties between notes that match equally well.
                let ageInDays = max(0, now.timeIntervalSince(note.savedAt)) / 86_400
                let recencyBonus = max(0, 1 - ageInDays / 30) * 2
                return (note, Double(matchedPrefixCount) * 10 + recencyBonus)
            }
            .sorted { firstScoredNote, secondScoredNote in
                if firstScoredNote.score != secondScoredNote.score {
                    return firstScoredNote.score > secondScoredNote.score
                }
                return firstScoredNote.note.savedAt > secondScoredNote.note.savedAt
            }
            .map(\.note)
            .filter { note in !recentNotes.contains(note) }

        let matchedNoteBudget = max(0, Self.maximumRelevantNoteCount - recentNotes.count)
        let relevantNotes = Array(matchedNotesRankedByScore.prefix(matchedNoteBudget)) + recentNotes
        return Self.notesWithinLimits(
            relevantNotes,
            maximumNoteCount: Self.maximumRelevantNoteCount,
            maximumCharacterCount: Self.maximumRelevantNotesCharacterCount
        )
    }

    // MARK: - Forgetting

    /// Removes the one note the user's words point at, from whichever daily file holds it.
    /// A match on a single generic word ("name") is too weak to delete a note, and if two notes
    /// match equally well nothing is removed and the result is `.ambiguous`.
    func removeNotes(matchingForgetTarget forgetTargetText: String) -> ClickyMemoryRemovalResult {
        removeNotes { savedNotes in
            switch ClickyMemoryKeyWords.bestMatch(forTargetText: forgetTargetText, in: savedNotes.map(\.text)) {
            case .none:
                return .noNote
            case .single(let matchingNoteIndex):
                return .notes([matchingNoteIndex])
            case .tie(let tiedNoteIndexes):
                return .ambiguous(candidateCount: tiedNoteIndexes.count)
            }
        }
    }

    /// Removes every note whose words equal one of the given texts. Used for "forget that" right
    /// after a note was saved, where the exact saved text is known.
    func removeNotes(withExactTexts exactNoteTexts: [String]) -> ClickyMemoryRemovalResult {
        let lowercasedExactNoteTexts = Set(exactNoteTexts.map { $0.lowercased() })
        return removeNotes { savedNotes in
            let matchingNoteIndexes = Set(savedNotes.indices.filter { savedNoteIndex in
                lowercasedExactNoteTexts.contains(savedNotes[savedNoteIndex].text.lowercased())
            })
            return matchingNoteIndexes.isEmpty ? .noNote : .notes(matchingNoteIndexes)
        }
    }

    /// Which saved notes a removal should delete.
    private enum NoteSelection {
        case noNote
        case notes(Set<Int>)
        case ambiguous(candidateCount: Int)
    }

    /// Shared removal: `selectNotesToRemove` receives every note oldest first and says which to
    /// remove. Only the lines of those notes are dropped from their files; headings, blank lines
    /// and the other notes stay exactly as they were.
    private func removeNotes(selectNotesToRemove: ([ClickyNote]) -> NoteSelection) -> ClickyMemoryRemovalResult {
        let allNotes = loadAllNotes()
        let noteIndexesToRemove: Set<Int>
        switch selectNotesToRemove(allNotes) {
        case .noNote:
            return .noMatch
        case .ambiguous(let candidateCount):
            return .ambiguous(matchCount: candidateCount)
        case .notes(let selectedNoteIndexes):
            noteIndexesToRemove = selectedNoteIndexes
        }

        var lowercasedTextsToRemoveByFileName: [String: Set<String>] = [:]
        var removedNoteTexts: [String] = []
        for noteIndex in noteIndexesToRemove.sorted() where allNotes.indices.contains(noteIndex) {
            let noteToRemove = allNotes[noteIndex]
            lowercasedTextsToRemoveByFileName[noteToRemove.sourceFileName, default: []].insert(noteToRemove.text.lowercased())
            removedNoteTexts.append(noteToRemove.text)
        }

        let timePrefixRegex = Self.makeTimePrefixRegex()
        for (fileName, lowercasedTextsToRemove) in lowercasedTextsToRemoveByFileName {
            let dayFileURL = notesDirectoryURL.appendingPathComponent(fileName)
            guard let dayStartDate = Self.dayStartDate(fromFileName: fileName) else {
                continue
            }
            do {
                let fileContents = try String(contentsOf: dayFileURL, encoding: .utf8)
                let remainingRawLines = fileContents.components(separatedBy: .newlines).filter { rawLine in
                    guard let parsedNote = Self.parseNote(
                        fromRawLine: rawLine,
                        timePrefixRegex: timePrefixRegex,
                        dayStartDate: dayStartDate,
                        fileName: fileName
                    ) else {
                        return true
                    }
                    return !lowercasedTextsToRemove.contains(parsedNote.text.lowercased())
                }
                // Atomic, so a failed write leaves the day's notes as they were.
                try remainingRawLines.joined(separator: "\n").write(to: dayFileURL, atomically: true, encoding: .utf8)
                ClickyMemoryFileSnapshotCache.shared.refresh(directory: notesDirectoryURL)
            } catch {
                return .failed(errorDescription: error.localizedDescription)
            }
        }
        return .removed(removedTexts: removedNoteTexts)
    }

    // MARK: - Parsing

    /// Reads note lines from a daily file. Headings and blank lines are skipped. Any other line is
    /// a note, so hand-typed notes work. A leading "- " or "* " is removed. A leading "HH:mm — "
    /// sets the time, and without it the note gets the start of its day.
    private static func parseNotes(fromFileContents fileContents: String, dayStartDate: Date, fileName: String) -> [ClickyNote] {
        let timePrefixRegex = makeTimePrefixRegex()
        return fileContents.components(separatedBy: .newlines).compactMap { rawLine in
            parseNote(fromRawLine: rawLine, timePrefixRegex: timePrefixRegex, dayStartDate: dayStartDate, fileName: fileName)
        }
    }

    /// Matches the time prefix this store writes, "HH:mm — text", and tolerates a hyphen or en dash.
    private static func makeTimePrefixRegex() -> NSRegularExpression {
        try! NSRegularExpression(pattern: "^(\\d{1,2}):(\\d{2})\\s+[—–-]\\s+(.+)$")
    }

    /// Reads one line of a daily file. Returns nil for headings, blank lines and empty notes.
    private static func parseNote(fromRawLine rawLine: String, timePrefixRegex: NSRegularExpression, dayStartDate: Date, fileName: String) -> ClickyNote? {
        var lineText = rawLine.trimmingCharacters(in: .whitespaces)
        if lineText.isEmpty || lineText.hasPrefix("#") {
            return nil
        }
        if lineText.hasPrefix("- ") || lineText.hasPrefix("* ") {
            lineText = String(lineText.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        var savedAt = dayStartDate
        var noteText = lineText
        if let timePrefixMatch = timePrefixRegex.firstMatch(in: lineText, range: NSRange(lineText.startIndex..., in: lineText)),
           let hourText = Range(timePrefixMatch.range(at: 1), in: lineText).map({ String(lineText[$0]) }),
           let minuteText = Range(timePrefixMatch.range(at: 2), in: lineText).map({ String(lineText[$0]) }),
           let remainingText = Range(timePrefixMatch.range(at: 3), in: lineText).map({ String(lineText[$0]) }),
           let hour = Int(hourText), let minute = Int(minuteText), hour < 24, minute < 60 {
            savedAt = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: dayStartDate) ?? dayStartDate
            noteText = remainingText.trimmingCharacters(in: .whitespaces)
        }

        guard !noteText.isEmpty else {
            return nil
        }
        return ClickyNote(savedAt: savedAt, text: noteText, sourceFileName: fileName)
    }

    private static func dayStartDate(fromFileName fileName: String) -> Date? {
        let dayNameWithoutExtension = (fileName as NSString).deletingPathExtension
        let dayNameShape = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
        guard dayNameShape.firstMatch(in: dayNameWithoutExtension, range: NSRange(dayNameWithoutExtension.startIndex..., in: dayNameWithoutExtension)) != nil else {
            return nil
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        guard let parsedDayDate = dayFormatter.date(from: dayNameWithoutExtension) else {
            return nil
        }
        return Calendar.current.startOfDay(for: parsedDayDate)
    }

    // MARK: - Retrieval helpers

    /// Lowercased words that could carry meaning, with stopwords and very short words removed.
    private static func matchTokens(in text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                token.count >= minimumMatchTokenCharacterCount && !matchStopWords.contains(token)
            }
    }

    private static func matchPrefix(_ token: String) -> String {
        String(token.prefix(matchTokenPrefixLength))
    }

    /// Takes notes in the order given until either cap would be exceeded.
    private static func notesWithinLimits(_ orderedNotes: [ClickyNote], maximumNoteCount: Int, maximumCharacterCount: Int) -> [ClickyNote] {
        var selectedNotes: [ClickyNote] = []
        var accumulatedCharacterCount = 0
        for candidateNote in orderedNotes {
            guard selectedNotes.count < maximumNoteCount else {
                break
            }
            guard accumulatedCharacterCount + candidateNote.text.count <= maximumCharacterCount else {
                break
            }
            selectedNotes.append(candidateNote)
            accumulatedCharacterCount += candidateNote.text.count
        }
        return selectedNotes
    }

    // MARK: - Date formatting

    /// Formats in the user's local time zone. The file name and the "HH:mm" line prefix must agree
    /// with the day the note was saved in, so this is never UTC.
    static func formattedDate(_ date: Date, dateFormat: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }

    static func dayFileName(for date: Date) -> String {
        "\(formattedDate(date, dateFormat: "yyyy-MM-dd")).md"
    }

    /// Notes are stored to the minute, so comparisons and round trips use the truncated time.
    static func minuteTruncated(_ date: Date) -> Date {
        let minuteComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return Calendar.current.date(from: minuteComponents) ?? date
    }
}
