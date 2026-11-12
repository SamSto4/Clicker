import Foundation

// Round 17 (file editing): which spoken or typed words confirm, cancel or undo a change without a
// model call, and the honesty rule that keeps Clicky from claiming a change is done. Foundation only.

// MARK: - Confirming, cancelling, undoing

nonisolated enum ClickyChangeVoiceIntent: Equatable {
    case confirm
    case cancel
    case undo
}

nonisolated enum ClickyChangeConfirmationPhrases {
    static let confirmPhrases: Set<String> = ["yes", "yeah", "yep", "apply it", "do it", "go ahead", "confirm"]
    static let cancelPhrases: Set<String> = ["no", "cancel", "don't", "dont"]
    static let undoPhrases: Set<String> = ["undo that", "undo"]

    /// What the whole transcript means, or nil when it is anything else. The transcript must be
    /// exactly one of the phrases (case, spacing and the punctuation around it do not matter), so
    /// "yes but make it blue" is a normal turn and never applies a change. That is the safe
    /// failure: a missed confirmation costs one more word, a wrong one writes a file.
    static func intent(forTranscript transcript: String) -> ClickyChangeVoiceIntent? {
        let normalizedTranscript = normalized(transcript)
        if confirmPhrases.contains(normalizedTranscript) {
            return .confirm
        }
        if cancelPhrases.contains(normalizedTranscript) {
            return .cancel
        }
        if undoPhrases.contains(normalizedTranscript) {
            return .undo
        }
        return nil
    }

    /// Lowercase, curly apostrophes made straight, the spaces and punctuation at both ends taken
    /// off, and runs of spaces made one.
    static func normalized(_ transcript: String) -> String {
        let straightened = transcript
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        let punctuationAndSpace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:\"\u{201C}\u{201D}…"))
        let trimmed = straightened.trimmingCharacters(in: punctuationAndSpace)
        return trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// The sentences Clicky says (or shows) about changes, fixed so what is said is always what happened.
nonisolated enum ClickyChangeSpokenSentences {
    static let applied = "done."
    static let discarded = "okay, i left it."
    static let expired = "that change expired, so i didn't apply it. ask me again."
    static let fileChangedSinceProposal = "the file changed since, so i didn't apply it."
    static let saveTheFileFirst = "save the file first, then say yes again."
    static let nothingToUndo = "there's nothing to undo."
    static let undone = "undone."
    static let undoExpired = "that was too long ago to undo."
    static let undoRefusedBecauseFileChanged = "the file changed since, so i didn't undo it."
    static let couldNotApply = "i couldn't apply that."
    static let couldNotUndo = "i couldn't undo that."
    /// The tool loop ran out of requests with the model still asking for tools: there is no answer to say.
    static let ranOutOfSteps = "i ran out of steps on that one. ask me again, a bit narrower."
    /// A reply that was cut at the output limit or declined while it held a tool call.
    static let replyWasCutOff = "that reply got cut off before it was done. nothing was changed. try again."
}

/// What happened to a change when the user answered (or tried to), as the one sentence that is said
/// or shown, and the outcome identifier the turn's metrics line records.
nonisolated enum ClickyChangeAnswer: Equatable {
    case applied
    case discarded
    case expired
    /// A file is no longer what it was when the change was proposed. Nothing was written.
    case refusedBecauseFileChanged
    /// The file is open in the frontmost window with unsaved edits. Nothing was written, and the
    /// change stays pending so a second "yes" after saving applies it.
    case refusedBecauseOfUnsavedEdits
    case failedToApply
    case undone
    case undoExpired
    case undoRefusedBecauseFileChanged
    case undoFailed
    case nothingToUndo

    var sentence: String {
        switch self {
        case .applied: return ClickyChangeSpokenSentences.applied
        case .discarded: return ClickyChangeSpokenSentences.discarded
        case .expired: return ClickyChangeSpokenSentences.expired
        case .refusedBecauseFileChanged: return ClickyChangeSpokenSentences.fileChangedSinceProposal
        case .refusedBecauseOfUnsavedEdits: return ClickyChangeSpokenSentences.saveTheFileFirst
        case .failedToApply: return ClickyChangeSpokenSentences.couldNotApply
        case .undone: return ClickyChangeSpokenSentences.undone
        case .undoExpired: return ClickyChangeSpokenSentences.undoExpired
        case .undoRefusedBecauseFileChanged: return ClickyChangeSpokenSentences.undoRefusedBecauseFileChanged
        case .undoFailed: return ClickyChangeSpokenSentences.couldNotUndo
        case .nothingToUndo: return ClickyChangeSpokenSentences.nothingToUndo
        }
    }

    /// The outcome a metrics line records for it (nil for the undo answers, which are not one).
    var metricsOutcome: ClickyChangeOutcome? {
        switch self {
        case .applied: return .applied
        case .discarded: return .cancelled
        case .expired: return .expired
        case .refusedBecauseFileChanged, .refusedBecauseOfUnsavedEdits: return .refusedChanged
        case .failedToApply, .undone, .undoExpired, .undoRefusedBecauseFileChanged, .undoFailed, .nothingToUndo: return nil
        }
    }
}

// MARK: - The honesty rule

nonisolated enum ClickyFileEditingHonesty {
    /// Replaces a sentence that claims a change is done while it is only queued.
    static let readyToApplySentence = "it's ready. press return or say yes to apply it."
    /// Replaces a sentence that claims a file was changed when nothing was queued.
    static let nothingChangedSentence = "i didn't change anything."

    /// Words that, in a sentence, claim something was done.
    private static let claimWords: Set<String> = [
        "done", "changed", "updated", "fixed", "deleted", "created", "saved",
        "renamed", "edited", "applied", "removed", "replaced", "written", "wrote",
        "finished", "completed",
    ]
    /// Words that make a sentence about a change that is waiting, not one that happened.
    private static let waitingWords: Set<String> = [
        "ready", "confirm", "return", "yes", "apply", "pending", "queued",
        "proposed", "draft", "drafted", "prepared", "waiting",
    ]
    /// Words of a sentence that is a question, a plan or an offer, not a claim.
    private static let modalWords: Set<String> = ["will", "would", "can", "could", "should", "shall", "if", "want", "wanna", "let"]
    private static let negationWords: Set<String> = ["not", "never", "no", "without", "didn't", "haven't", "hasn't", "couldn't", "can't", "won't", "wasn't", "isn't", "nothing"]
    /// A claim about a file needs one of these (or a turn that used the file tools).
    private static let fileWords: Set<String> = [
        "file", "files", "folder", "code", "line", "lines", "script", "function",
        "class", "method", "document", "config", "readme",
    ]
    /// Words with which a sentence tells the user how to confirm.
    private static let confirmationInstructionWords: Set<String> = ["ready", "confirm", "return", "yes"]
    /// The spoken text with every sentence that claims a change is done put right.
    ///
    /// - With changes queued: a sentence that says it is done, changed, updated, fixed, deleted,
    ///   created or saved, and not that it is ready or to be confirmed, is replaced by "it's ready.
    ///   press return or say yes to apply it." (once), and the sentence is added at the end when
    ///   nothing in the reply tells the user how to confirm.
    /// - With nothing queued: a sentence that claims a file was changed is replaced by "i didn't
    ///   change anything." A bare "done" counts as such a claim only when the turn used the file
    ///   tools, so a memory confirmation ("saved.") in an ordinary turn is left alone.
    static func honestSpokenText(_ spokenText: String, queuedChangeCount: Int, usedFileTools: Bool) -> String {
        let sentences = splitIntoSentences(removingChangeHistoryLines(from: spokenText))

        if queuedChangeCount > 0 {
            // A claiming sentence is dropped. When no other sentence says how to confirm, the ready
            // sentence takes the first claim's place (or comes at the end), once: a reply that
            // already says "it's ready, say yes." does not get it a second time.
            let otherSentencesTellHowToConfirm = sentences.contains { sentence in
                !claimsDoneWhileOnlyQueued(sentence) && !words(in: sentence).isDisjoint(with: confirmationInstructionWords)
            }
            var keptSentences: [String] = []
            var hasInsertedReadySentence = otherSentencesTellHowToConfirm
            for sentence in sentences {
                if claimsDoneWhileOnlyQueued(sentence) {
                    if !hasInsertedReadySentence {
                        keptSentences.append(readyToApplySentence)
                        hasInsertedReadySentence = true
                    }
                } else {
                    keptSentences.append(sentence)
                }
            }
            if !hasInsertedReadySentence {
                keptSentences.append(readyToApplySentence)
            }
            return keptSentences.joined(separator: " ")
        }

        var keptSentences: [String] = []
        var hasInsertedNothingChangedSentence = false
        for sentence in sentences {
            if claimsAFileWasChanged(sentence, usedFileTools: usedFileTools) {
                if !hasInsertedNothingChangedSentence {
                    keptSentences.append(nothingChangedSentence)
                    hasInsertedNothingChangedSentence = true
                }
            } else {
                keptSentences.append(sentence)
            }
        }
        return keptSentences.joined(separator: " ")
    }

    /// Takes the app's own history lines ("[proposed: edit Foo.swift: ...]", "[applied: ...]", "[not
    /// applied: ...]") out of words the model wrote. They are in its conversation history so it knows
    /// what is pending, which can teach it to write one itself; one must never be read aloud.
    static func removingChangeHistoryLines(from text: String) -> String {
        var remainingText = text
        for lineStart in ["[proposed:", "[applied:", "[not applied:"] {
            while let startRange = remainingText.range(of: lineStart, options: [.caseInsensitive]) {
                let endIndex = remainingText[startRange.upperBound...].firstIndex(of: "]").map { remainingText.index(after: $0) } ?? remainingText.endIndex
                remainingText.removeSubrange(startRange.lowerBound..<endIndex)
            }
        }
        return remainingText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The history text of a turn whose spoken words the honesty rule changed: the new words, then
    /// whatever the finisher added after its own spoken words (the `[NOTE:]` and `[PROFILE:]` tags of
    /// facts that were really saved). Unchanged words keep the finisher's history text as it is.
    static func historyText(
        honestSpokenText: String,
        originalSpokenText: String,
        finisherHistoryText: String
    ) -> String {
        guard honestSpokenText != originalSpokenText else {
            return finisherHistoryText
        }
        var textAfterTheOriginalWords = ""
        if finisherHistoryText.hasPrefix(originalSpokenText) {
            textAfterTheOriginalWords = String(finisherHistoryText.dropFirst(originalSpokenText.count))
        }
        return honestSpokenText + textAfterTheOriginalWords
    }

    // MARK: - Reading a sentence

    private static func claimsDoneWhileOnlyQueued(_ sentence: String) -> Bool {
        let sentenceWords = words(in: sentence)
        guard !sentence.hasSuffix("?"),
              !sentenceWords.isDisjoint(with: claimWords),
              sentenceWords.isDisjoint(with: waitingWords),
              sentenceWords.isDisjoint(with: modalWords),
              sentenceWords.isDisjoint(with: negationWords) else {
            return false
        }
        return true
    }

    /// Words that make Clicky the one who did it ("i changed", "we renamed").
    private static let firstPersonWords: Set<String> = ["i", "i've", "ive", "we", "we've"]
    /// A sentence this short with a claim word is a claim by Clicky ("done.", "all done.", "fixed it.").
    private static let shortClaimMaximumWordCount = 3

    /// With nothing queued, only Clicky's own claim is put right: a sentence about what the code, a
    /// commit or someone else did ("the last commit changed the parser.", "the readme was updated
    /// last week.") is an answer, not a claim. A claim is a first-person sentence ("i changed the
    /// label.") or, after the file tools were used, a very short one ("done."). Without file tools
    /// the first-person sentence must also name a file, so a memory confirmation ("i saved that.")
    /// in an ordinary turn is left alone.
    private static func claimsAFileWasChanged(_ sentence: String, usedFileTools: Bool) -> Bool {
        let sentenceWords = words(in: sentence)
        guard !sentence.hasSuffix("?"),
              !sentenceWords.isDisjoint(with: claimWords),
              sentenceWords.isDisjoint(with: modalWords),
              sentenceWords.isDisjoint(with: negationWords) else {
            return false
        }
        let isFirstPersonClaim = !sentenceWords.isDisjoint(with: firstPersonWords)
        if usedFileTools {
            return isFirstPersonClaim || wordCount(of: sentence) <= shortClaimMaximumWordCount
        }
        return isFirstPersonClaim && !sentenceWords.isDisjoint(with: fileWords)
    }

    /// The number of words in a sentence, repeated words counted each time.
    private static func wordCount(of sentence: String) -> Int {
        let wordCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "'\u{2019}"))
        return sentence.components(separatedBy: wordCharacters.inverted).filter { !$0.isEmpty }.count
    }

    /// The lowercase words of a sentence, apostrophes kept ("didn't").
    private static func words(in sentence: String) -> Set<String> {
        let straightened = sentence.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let wordCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "'"))
        let sentenceWords = straightened
            .components(separatedBy: wordCharacters.inverted)
            .filter { !$0.isEmpty }
        return Set(sentenceWords)
    }

    /// Splits at ".", "!" and "?" that end a sentence (followed by a space or the end), and at line
    /// breaks. Each sentence keeps its own end mark, and the spaces between sentences are dropped.
    static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var currentSentence = ""
        let characters = Array(text)
        for (characterIndex, character) in characters.enumerated() {
            if character == "\n" {
                appendTrimmed(currentSentence, to: &sentences)
                currentSentence = ""
                continue
            }
            currentSentence.append(character)
            let isEndMark = character == "." || character == "!" || character == "?"
            let nextCharacter: Character? = characterIndex + 1 < characters.count ? characters[characterIndex + 1] : nil
            if isEndMark && (nextCharacter == nil || nextCharacter == " " || nextCharacter == "\n") {
                appendTrimmed(currentSentence, to: &sentences)
                currentSentence = ""
            }
        }
        appendTrimmed(currentSentence, to: &sentences)
        return sentences
    }

    private static func appendTrimmed(_ sentence: String, to sentences: inout [String]) {
        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSentence.isEmpty {
            sentences.append(trimmedSentence)
        }
    }
}
