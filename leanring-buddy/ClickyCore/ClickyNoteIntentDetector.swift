import Foundation

/// Decides, from the user's words alone, whether they asked to save a note or to recall notes.
/// Claude's [NOTE:] tags are only honored when this detector sees save language, so a model
/// mistake cannot create a note the user never asked for.
nonisolated enum ClickyNoteIntentDetector {
    /// Optional lead-ins before the save phrase, such as "hey clicky, please ...".
    private static let optionalLeadInPattern = "^\\W*(?:(?:hey|hi|ok|okay)[,\\s]+)?(?:clicky[,\\s]+)?(?:(?:please|can you|could you|will you|would you)[,\\s]+)?"

    /// Phrases that start a save request. They must come at the start of the transcript, so a
    /// question such as "do you remember when we talked about X" is never treated as a save.
    private static let explicitSavePhrasePattern = "(?:remember\\s+(?:that|this)\\b|remember\\s*:|(?:take|make)\\s+a\\s+note\\s+(?:that|of)\\b|(?:take|make)\\s+a\\s+note\\s*:|note\\s+(?:that|to\\s+self)\\b|note\\s*:|write\\s+(?:(?:that|this|it)\\s+)?down\\b|jot\\s+(?:(?:that|this|it)\\s+)?down\\b|save\\s+a\\s+note\\b|don['’]?t\\s+forget\\b|keep\\s+in\\s+mind\\s+that\\b)"

    /// Loose save language anywhere in the transcript. This only gates Claude's tags, so it can be
    /// generous: a false positive still needs Claude to have written a tag.
    private static let looseSavingIntentPattern = "\\b(?:remember|notes?|write\\s+(?:(?:that|this|it)\\s+)?down|jot|save|remind|don['’]?t\\s+forget|keep\\s+in\\s+mind|log|add\\s+to\\s+my\\s+notes)\\b"

    /// Phrases that ask for everything saved, which loads the larger set of notes.
    private static let recallRequestPattern = "\\b(?:my\\s+notes|what\\s+did\\s+i\\s+(?:tell|say)|what\\s+do\\s+you\\s+remember|remind\\s+me|did\\s+i\\s+say)\\b"

    /// Returns the note text the user dictated after a save phrase, such as "my dentist is friday at 3"
    /// for "remember that my dentist is friday at 3". Returns nil when there is no save phrase, or when
    /// nothing follows it (for example "remember this", which needs Claude to read the screen).
    static func explicitSaveRequestNoteText(in userTranscript: String) -> String? {
        let fullPattern = optionalLeadInPattern + explicitSavePhrasePattern
        guard let savePhraseRegex = try? NSRegularExpression(pattern: fullPattern, options: [.caseInsensitive]) else {
            return nil
        }
        let transcriptRange = NSRange(userTranscript.startIndex..., in: userTranscript)
        guard let savePhraseMatch = savePhraseRegex.firstMatch(in: userTranscript, options: [.anchored], range: transcriptRange),
              let noteTextStartIndex = Range(savePhraseMatch.range, in: userTranscript)?.upperBound else {
            return nil
        }

        let remainderAfterSavePhrase = String(userTranscript[noteTextStartIndex...])
        // Strip the punctuation that usually separates the phrase from the content, such as
        // "remember: ..." or "write this down, ...".
        let trimmedRemainderText = remainderAfterSavePhrase.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n,:;-–—"))
        let normalizedNoteText = ClickyNoteStore.normalizedSingleLineNoteText(trimmedRemainderText)
        return normalizedNoteText.isEmpty ? nil : normalizedNoteText
    }

    /// True when the user opens with a save command, such as "remember my wifi password is ..." or
    /// "write this down: ...", even if no note text can be pulled out of it. The turn finisher uses
    /// this to say "i won't keep that" when such a command carries a secret and the model wrote no tag.
    static func transcriptStartsWithSaveCommand(_ userTranscript: String) -> Bool {
        let saveCommandPattern = optionalLeadInPattern + "(?:remember|memorize|note|save|store|write\\s+(?:(?:that|this|it)\\s+)?down|jot\\s+(?:(?:that|this|it)\\s+)?down|take\\s+a\\s+note|make\\s+a\\s+note|add\\s+to\\s+my\\s+notes|don['’]?t\\s+forget)\\b"
        guard let saveCommandRegex = try? NSRegularExpression(pattern: saveCommandPattern, options: [.caseInsensitive]) else {
            return false
        }
        let transcriptRange = NSRange(userTranscript.startIndex..., in: userTranscript)
        return saveCommandRegex.firstMatch(in: userTranscript, options: [.anchored], range: transcriptRange) != nil
    }

    static func transcriptMentionsSavingIntent(_ userTranscript: String) -> Bool {
        containsMatch(of: looseSavingIntentPattern, in: userTranscript)
    }

    static func transcriptAsksToRecallNotes(_ userTranscript: String) -> Bool {
        containsMatch(of: recallRequestPattern, in: userTranscript)
    }

    private static func containsMatch(of pattern: String, in text: String) -> Bool {
        guard let patternRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        return patternRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
