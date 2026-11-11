import Foundation

/// What happened when a fact was offered to the profile.
nonisolated enum ClickyProfileSaveResult: Equatable {
    /// The fact was written. `replacedFactTexts` lists older facts about the same subject that it replaced.
    case saved(factText: String, replacedFactTexts: [String])
    /// The profile already holds a fact with the same words, so nothing was written.
    case alreadyKnown(factText: String)
    case rejectedBecauseEmpty
    /// The profile already holds the hard limit of facts. Nothing is dropped to make room: the
    /// user has to forget something first.
    case rejectedBecauseProfileIsFull
    /// The file could not be read or written. Nothing is thrown, so a profile problem can never break a turn.
    case failed(errorDescription: String)
}

/// The profile is one small markdown file, `profile.md`, with one bullet per lasting fact or
/// preference about the user ("call me sam", "uses vs code as their editor"). Unlike a daily note
/// it is sent with every turn, so what is injected is capped hard: the newest 20 facts, within
/// 1,000 characters. The file itself keeps every line (up to a hard limit of 100 facts), because
/// the lines are the user's: saving never deletes one to make room.
///
/// Plain markdown lets the user read and hand-edit it, and deleting the file forgets everything.
/// No method here throws. A missing file is an empty profile, an unreadable file reads as empty,
/// and a failed write comes back as a value the caller can speak about.
nonisolated struct ClickyProfileStore {
    static let profileFileName = "profile.md"
    static let maximumFactCharacterCount = 200

    /// How many facts are injected into the prompt each turn (the newest ones).
    static let maximumFactCount = 20
    static let maximumInjectedCharacterCount = 1000

    /// How many facts the file may hold. Past this, saving is refused instead of dropping old lines.
    static let maximumStoredFactCount = 100

    /// Each injected fact costs its text plus a "- " bullet and a newline, so the 1,000 character
    /// budget covers the whole rendered list and not only the words in it.
    static let injectedLineOverheadCharacterCount = 3

    private static let newProfileFileHeadingLine = "# Clicky profile"

    let profileDirectoryURL: URL

    /// The profile sits next to the daily notes. The notes reader only opens files named like a
    /// date, so it never mistakes profile.md for a note.
    static var defaultProfileDirectoryURL: URL {
        ClickyNoteStore.defaultNotesDirectoryURL
    }

    var profileFileURL: URL {
        profileDirectoryURL.appendingPathComponent(Self.profileFileName)
    }

    /// A fact is one line. Newlines become spaces, a leading bullet is removed, and an over-long
    /// fact is cut rather than rejected.
    static func normalizedSingleLineFactText(_ rawFactText: String) -> String {
        let singleLineText = rawFactText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let textWithoutBullet = removingLeadingBulletMarker(from: singleLineText)
        return String(textWithoutBullet.prefix(maximumFactCharacterCount))
            .trimmingCharacters(in: .whitespaces)
    }

    /// True when two facts say the same thing, ignoring case, repeated spaces and final punctuation.
    static func factTextsAreEquivalent(_ firstFactText: String, _ secondFactText: String) -> Bool {
        comparisonText(for: firstFactText) == comparisonText(for: secondFactText)
    }

    /// The "same subject" test used to replace outdated facts: both facts fill the same slot of
    /// the user, such as the editor or the name (see `ClickyProfileSlots`). A fact that fills no
    /// slot never replaces anything, so unsure cases keep both facts and the newer line wins by order.
    static func factsShareASubject(_ firstFactText: String, _ secondFactText: String) -> Bool {
        ClickyProfileSlots.factsFillTheSameSlot(firstFactText, secondFactText)
    }

    /// True when saving `newFactText` should remove `olderFactText`: the new fact fills the older
    /// fact's slot (or slots), is not worded as an addition or a qualified statement, and does not
    /// carry a strength word. See `ClickyProfileSlots.newFactReplacesOlderFact`.
    static func newFactReplacesOlderFact(newFactText: String, olderFactText: String) -> Bool {
        ClickyProfileSlots.newFactReplacesOlderFact(newFactText: newFactText, olderFactText: olderFactText)
    }

    // MARK: - Reading

    /// Every fact in the file, oldest first. A missing or unreadable file gives no facts.
    func loadFactTexts() -> [String] {
        switch readFileLines() {
        case .readable(let fileLines, _):
            return fileLines.compactMap(\.factText)
        case .unreadable:
            return []
        }
    }

    /// The facts to send this turn: the newest ones that fit both the fact-count cap and the
    /// character budget, returned oldest first so a later line reads as the newer one. The file is
    /// never changed, so a hand-edited file longer than the budget keeps all its lines.
    func factTextsWithinInjectionBudget() -> [String] {
        var newestFirstSelectedFactTexts: [String] = []
        var accumulatedCharacterCount = 0

        for factText in loadFactTexts().reversed() {
            // A hand-edited line longer than a saved fact may be is cut, so one huge line cannot
            // use the whole budget or push every other fact out.
            let injectedFactText = Self.normalizedSingleLineFactText(factText)
            guard !injectedFactText.isEmpty else {
                continue
            }
            let injectedLineCharacterCount = injectedFactText.count + Self.injectedLineOverheadCharacterCount
            guard newestFirstSelectedFactTexts.count < Self.maximumFactCount,
                  accumulatedCharacterCount + injectedLineCharacterCount <= Self.maximumInjectedCharacterCount else {
                break
            }
            newestFirstSelectedFactTexts.append(injectedFactText)
            accumulatedCharacterCount += injectedLineCharacterCount
        }
        return newestFirstSelectedFactTexts.reversed()
    }

    // MARK: - Saving

    /// Adds one fact to the end of the file.
    /// - A fact with the same words as a saved one is not written again.
    /// - Older facts in the same slot (the editor, the name, ...) are removed first, so a new editor
    ///   replaces the old editor. Facts in no shared slot stay, and the newer one wins by order.
    /// - Nothing else is ever dropped. At 100 facts the save is refused instead.
    /// Headings, comments and blank lines in a hand-edited file are kept.
    func saveFact(text rawFactText: String) -> ClickyProfileSaveResult {
        let normalizedFactText = Self.normalizedSingleLineFactText(rawFactText)
        guard !normalizedFactText.isEmpty else {
            return .rejectedBecauseEmpty
        }

        // A read failure on an existing file must stop the save. Treating it as empty would
        // overwrite the user's profile.
        let existingFileLines: [ProfileFileLine]
        switch readFileLines() {
        case .unreadable(let errorDescription):
            return .failed(errorDescription: errorDescription)
        case .readable(let fileLines, let fileExisted):
            existingFileLines = fileExisted ? fileLines : Self.linesForNewProfileFile()
        }

        if let alreadySavedFactText = existingFileLines.compactMap(\.factText).first(where: {
            Self.factTextsAreEquivalent($0, normalizedFactText)
        }) {
            return .alreadyKnown(factText: alreadySavedFactText)
        }

        var updatedFileLines = existingFileLines
        var replacedFactTexts: [String] = []
        updatedFileLines.removeAll { fileLine in
            guard let existingFactText = fileLine.factText,
                  Self.newFactReplacesOlderFact(newFactText: normalizedFactText, olderFactText: existingFactText) else {
                return false
            }
            replacedFactTexts.append(existingFactText)
            return true
        }

        // A replacement frees the slot it takes, so only a save that adds a line can hit the limit.
        let factCountAfterReplacements = updatedFileLines.filter { $0.factText != nil }.count
        guard factCountAfterReplacements < Self.maximumStoredFactCount else {
            return .rejectedBecauseProfileIsFull
        }

        Self.removeTrailingBlankLinesAfterLastFact(from: &updatedFileLines)
        updatedFileLines.append(ProfileFileLine(rawLineText: "- \(normalizedFactText)", factText: normalizedFactText))

        if let writeErrorDescription = writeFileLines(updatedFileLines) {
            return .failed(errorDescription: writeErrorDescription)
        }
        return .saved(factText: normalizedFactText, replacedFactTexts: replacedFactTexts)
    }

    // MARK: - Forgetting

    /// Removes at most ONE fact: the single fact the user's words point at.
    /// - A target that names a slot ("my editor", "my name", "that i use vim") finds the fact in
    ///   that slot. If the target also names something specific ("vim"), the fact must mention it,
    ///   so "forget that i use emacs" never removes the vim fact.
    /// - Otherwise the fact must share key words with the target (see `ClickyMemoryKeyWords.bestMatch`).
    /// - If two or more facts match equally well nothing is removed and the result is `.ambiguous`,
    ///   so Clicky can ask which one instead of guessing.
    func removeFacts(matchingForgetTarget forgetTargetText: String) -> ClickyMemoryRemovalResult {
        removeFacts { savedFactTexts in
            Self.selectionOfFact(forForgetTarget: forgetTargetText, among: savedFactTexts)
        }
    }

    /// Removes the facts whose words equal one of the given texts. Used for "forget that" right
    /// after a fact was saved, where the exact saved text is known.
    func removeFacts(withExactTexts exactFactTexts: [String]) -> ClickyMemoryRemovalResult {
        removeFacts { savedFactTexts in
            let matchingFactIndexes = Set(savedFactTexts.indices.filter { savedFactIndex in
                exactFactTexts.contains { Self.factTextsAreEquivalent($0, savedFactTexts[savedFactIndex]) }
            })
            return matchingFactIndexes.isEmpty ? .noFact : .facts(matchingFactIndexes)
        }
    }

    /// Removes the facts that name a value the user said they no longer use ("i no longer use vim"
    /// removes "i use vim"). Only facts that fill a slot qualify, and each must share a specific
    /// key word with the value, so "i stopped using tabs" cannot remove an unrelated fact.
    func removeSlotFacts(namingValue valueText: String) -> ClickyMemoryRemovalResult {
        // "tabs" and "spaces" are generic words for matching a forget request, but they are exactly
        // the values of the indentation slot, so here they count.
        let indentationValueWords: Set<String> = ["tab", "space", "indent", "indentation"]
        let valueSpecificKeyWords = ClickyMemoryKeyWords.keyWords(in: valueText)
            .filter { !ClickyMemoryKeyWords.isGenericKeyWord($0) || indentationValueWords.contains($0) }
        guard !valueSpecificKeyWords.isEmpty else {
            return .noMatch
        }
        return removeFacts { savedFactTexts in
            let matchingFactIndexes = Set(savedFactTexts.indices.filter { savedFactIndex in
                let savedFactText = savedFactTexts[savedFactIndex]
                return !ClickyProfileSlots.slots(forFactText: savedFactText).isEmpty
                    && !ClickyMemoryKeyWords.keyWords(in: savedFactText).isDisjoint(with: valueSpecificKeyWords)
            })
            return matchingFactIndexes.isEmpty ? .noFact : .facts(matchingFactIndexes)
        }
    }

    /// Removes the most recently added fact.
    func removeNewestFact() -> ClickyMemoryRemovalResult {
        removeFacts { savedFactTexts in
            savedFactTexts.isEmpty ? .noFact : .facts([savedFactTexts.count - 1])
        }
    }

    /// Which saved facts a removal should delete.
    private enum FactSelection {
        case noFact
        case facts(Set<Int>)
        case ambiguous(candidateCount: Int)
    }

    private static func selectionOfFact(forForgetTarget forgetTargetText: String, among savedFactTexts: [String]) -> FactSelection {
        var targetSlots = ClickyProfileSlots.slots(forForgetTarget: forgetTargetText)
        if targetSlots.isEmpty {
            targetSlots = ClickyProfileSlots.slots(forFactText: forgetTargetText)
        }

        if !targetSlots.isEmpty {
            var candidateFactIndexes = savedFactTexts.indices.filter { savedFactIndex in
                !ClickyProfileSlots.slots(forFactText: savedFactTexts[savedFactIndex]).isDisjoint(with: targetSlots)
            }
            // "forget that i use emacs" names something specific, and the fact must mention it.
            // "forget my editor" names only the slot, so any fact in the slot qualifies.
            let targetSpecificKeyWords = ClickyMemoryKeyWords.keyWords(in: forgetTargetText)
                .filter { !ClickyMemoryKeyWords.isGenericKeyWord($0) }
            if !targetSpecificKeyWords.isEmpty {
                candidateFactIndexes = candidateFactIndexes.filter { candidateFactIndex in
                    !ClickyMemoryKeyWords.keyWords(in: savedFactTexts[candidateFactIndex]).isDisjoint(with: targetSpecificKeyWords)
                }
            }
            switch candidateFactIndexes.count {
            case 0:
                return .noFact
            case 1:
                return .facts([candidateFactIndexes[0]])
            default:
                return .ambiguous(candidateCount: candidateFactIndexes.count)
            }
        }

        switch ClickyMemoryKeyWords.bestMatch(forTargetText: forgetTargetText, in: savedFactTexts) {
        case .none:
            return .noFact
        case .single(let matchingFactIndex):
            return .facts([matchingFactIndex])
        case .tie(let tiedFactIndexes):
            return .ambiguous(candidateCount: tiedFactIndexes.count)
        }
    }

    /// Shared removal: `selectFactsToRemove` receives the facts oldest first and says which to
    /// remove. Lines that are not facts (headings, blank lines) are left alone.
    private func removeFacts(selectFactsToRemove: ([String]) -> FactSelection) -> ClickyMemoryRemovalResult {
        let existingFileLines: [ProfileFileLine]
        switch readFileLines() {
        case .unreadable(let errorDescription):
            return .failed(errorDescription: errorDescription)
        case .readable(let fileLines, _):
            existingFileLines = fileLines
        }

        let factLineIndexes = existingFileLines.indices.filter { existingFileLines[$0].factText != nil }
        let savedFactTexts = factLineIndexes.compactMap { existingFileLines[$0].factText }
        let factIndexesToRemove: Set<Int>
        switch selectFactsToRemove(savedFactTexts) {
        case .noFact:
            return .noMatch
        case .ambiguous(let candidateCount):
            return .ambiguous(matchCount: candidateCount)
        case .facts(let selectedFactIndexes):
            factIndexesToRemove = selectedFactIndexes
        }

        let lineIndexesToRemove = Set(factIndexesToRemove.compactMap { factIndex in
            factLineIndexes.indices.contains(factIndex) ? factLineIndexes[factIndex] : nil
        })
        let removedFactTexts = lineIndexesToRemove.sorted().compactMap { existingFileLines[$0].factText }
        let remainingFileLines = existingFileLines.enumerated()
            .filter { !lineIndexesToRemove.contains($0.offset) }
            .map(\.element)

        if let writeErrorDescription = writeFileLines(remainingFileLines) {
            return .failed(errorDescription: writeErrorDescription)
        }
        return .removed(removedTexts: removedFactTexts)
    }

    // MARK: - File lines

    /// One line of the file. `factText` is nil for headings, blank lines and anything with no
    /// letters or digits, so those lines are kept as they are when the file is rewritten.
    private struct ProfileFileLine {
        let rawLineText: String
        let factText: String?
    }

    private enum ProfileFileReadResult {
        /// `fileExisted` is false for a profile that has not been created yet.
        case readable(fileLines: [ProfileFileLine], fileExisted: Bool)
        case unreadable(errorDescription: String)
    }

    private func readFileLines() -> ProfileFileReadResult {
        guard FileManager.default.fileExists(atPath: profileFileURL.path) else {
            return .readable(fileLines: [], fileExisted: false)
        }
        do {
            let fileContents = try String(contentsOf: profileFileURL, encoding: .utf8)
            // Splitting on Character.isNewline keeps "\r\n" as one line break.
            let rawLineTexts = fileContents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            let fileLines = rawLineTexts.map { rawLineText in
                ProfileFileLine(rawLineText: rawLineText, factText: Self.factText(fromRawLine: rawLineText))
            }
            return .readable(fileLines: fileLines, fileExisted: true)
        } catch {
            return .unreadable(errorDescription: error.localizedDescription)
        }
    }

    /// Writes the whole file in one atomic replace, so a crash or a full disk cannot leave a
    /// half-written profile. Returns the error text on failure and nil on success.
    private func writeFileLines(_ fileLines: [ProfileFileLine]) -> String? {
        do {
            try FileManager.default.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)
            var rawLineTexts = fileLines.map(\.rawLineText)
            while let lastRawLineText = rawLineTexts.last, lastRawLineText.trimmingCharacters(in: .whitespaces).isEmpty {
                rawLineTexts.removeLast()
            }
            let fileContents = rawLineTexts.joined(separator: "\n") + "\n"
            try fileContents.write(to: profileFileURL, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func linesForNewProfileFile() -> [ProfileFileLine] {
        [
            ProfileFileLine(rawLineText: newProfileFileHeadingLine, factText: nil),
            ProfileFileLine(rawLineText: "", factText: nil),
        ]
    }

    /// Keeps bullets together: blank lines after the last fact are dropped before a new fact is
    /// appended. Blank lines after a heading stay, so a new file reads "# Clicky profile", a blank
    /// line, then the first bullet.
    private static func removeTrailingBlankLinesAfterLastFact(from fileLines: inout [ProfileFileLine]) {
        guard let lastNonBlankFileLine = fileLines.last(where: { !$0.rawLineText.trimmingCharacters(in: .whitespaces).isEmpty }),
              lastNonBlankFileLine.factText != nil else {
            return
        }
        while let lastFileLine = fileLines.last, lastFileLine.rawLineText.trimmingCharacters(in: .whitespaces).isEmpty {
            fileLines.removeLast()
        }
    }

    /// Reads one line of a possibly hand-edited file. Headings ("# ..."), HTML comments, blank
    /// lines and labels ending in a colon ("A few things about me:") are not facts. Any other line
    /// with a letter or digit is a fact, so a line typed without a bullet still counts. A leading
    /// "- ", "* " or "+ " is removed.
    private static func factText(fromRawLine rawLineText: String) -> String? {
        let trimmedLineText = rawLineText.trimmingCharacters(in: .whitespaces)
        if trimmedLineText.isEmpty || trimmedLineText.hasPrefix("#") || trimmedLineText.hasPrefix("<!--") {
            return nil
        }
        let lineTextWithoutBullet = removingLeadingBulletMarker(from: trimmedLineText)
        guard lineTextWithoutBullet.contains(where: { $0.isLetter || $0.isNumber }),
              !lineTextWithoutBullet.hasSuffix(":") else {
            return nil
        }
        return lineTextWithoutBullet
    }

    private static func removingLeadingBulletMarker(from lineText: String) -> String {
        for bulletMarker in ["- ", "* ", "+ ", "• "] where lineText.hasPrefix(bulletMarker) {
            return String(lineText.dropFirst(bulletMarker.count)).trimmingCharacters(in: .whitespaces)
        }
        return lineText
    }

    private static func comparisonText(for factText: String) -> String {
        let singleSpacedText = factText
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return singleSpacedText.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))
    }
}
