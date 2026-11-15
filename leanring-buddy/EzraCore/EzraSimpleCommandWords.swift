import Foundation

// Round 19 (Jarvis tuning): the one word list that decides whether a transcript is a plain command
// ("open safari", "set a timer for 10 minutes") and may skip the model's words (the skip gate) or the
// model altogether (quick commands). Everything else goes to the model. Apple Speech adds no
// punctuation, so a question or a second request cannot be seen from a question mark or a comma: it is
// seen from its words ("open safari is it up to date" is refused on "is"). The list is the orchestrator's
// amendment 1 to the round 19 brief, shared so the two features can never disagree. Foundation only.

nonisolated enum EzraSimpleCommandWords {
    /// At most this many words, after the polite prefix.
    static let maximumWordCount = 12

    /// Polite prefixes, at most one of which is taken off the front. The assistant's own name (and
    /// "hey" with it) counts too when the persona gives one.
    static let politePrefixes = ["please", "can you", "could you", "would you", "hey ezra", "ezra"]

    /// A transcript holding any of these words anywhere goes to the model: a joined or conditional
    /// request (the first line), a request for words rather than an action (the second), or a question
    /// (the third).
    static let refusedWords: Set<String> = [
        "and", "then", "also", "after", "before", "while", "but", "when", "if", "unless", "once", "until",
        "tell", "read", "show", "what", "how", "why", "where", "which", "who",
        "is", "are", "does", "do", "did", "was", "were", "should",
    ]

    /// Words that open a question, refused when they start what is left after the polite prefix
    /// ("please can you open safari", "will you open safari"). The amendment's "any other question
    /// opening refuses too"; the words that are refused anywhere are not repeated here.
    static let questionOpeningWords: Set<String> = [
        "can", "could", "would", "will", "shall", "may", "might", "must", "has", "have", "had", "am", "whose", "whom",
    ]

    /// The command as a plain lowercase line (one polite prefix and the end punctuation taken off, runs
    /// of spaces made one), or nil when the transcript must go to the model. A question mark refuses,
    /// except a trailing one after a polite prefix ("can you open safari?").
    static func plainCommandText(_ transcript: String, assistantName: String = "") -> String? {
        var text = EzraActionText.collapsedToOneLine(transcript.lowercased())
        // The end punctuation, remembering whether it held a question mark.
        var endedWithAQuestionMark = false
        while let lastCharacter = text.last, ".!?,;".contains(lastCharacter) {
            if lastCharacter == "?" { endedWithAQuestionMark = true }
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        guard !text.contains("?") else {
            return nil
        }

        let afterThePrefix = textAfterOnePolitePrefix(text, assistantName: assistantName)
        if endedWithAQuestionMark && afterThePrefix == nil {
            return nil
        }
        let commandText = (afterThePrefix ?? text).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        guard !commandText.isEmpty else {
            return nil
        }

        let words = commandText.split(separator: " ")
        guard words.count <= maximumWordCount else {
            return nil
        }
        let wordTokens = tokens(of: commandText)
        if wordTokens.contains(where: { refusedWords.contains($0) }) {
            return nil
        }
        if let firstToken = wordTokens.first, questionOpeningWords.contains(firstToken) {
            return nil
        }
        return commandText
    }

    /// The text after one polite prefix (which must end at a word boundary), or nil when it starts with
    /// none. The longer prefixes are tried first, so "hey ezra" is taken whole.
    static func textAfterOnePolitePrefix(_ text: String, assistantName: String) -> String? {
        var prefixes = politePrefixes
        let cleanedAssistantName = EzraActionText.normalizedForComparison(assistantName)
        if !cleanedAssistantName.isEmpty && cleanedAssistantName != EzraPersona.defaultAssistantName {
            prefixes.append("hey " + cleanedAssistantName)
            prefixes.append(cleanedAssistantName)
        }
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)
            guard rest.isEmpty || rest.first == " " || rest.first == "," else { continue }
            return String(rest).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }
        return nil
    }

    /// The words as letters and digits only: every other character splits ("what's" gives "what"
    /// and "s"), so a word cannot hide behind an apostrophe or a hyphen.
    static func tokens(of text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        return text.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }
}
