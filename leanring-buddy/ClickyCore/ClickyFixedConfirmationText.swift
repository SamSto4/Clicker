import Foundation

// Round 19 (Jarvis tuning): the sentence Clicky says after one simple action done at once, when the
// turn ends without asking the model for words (the skip gate, `ClickyFinalRequestSkipDecision`) or
// without the model at all (a quick command). It is built from the tool's result, which is the action
// session's own fixed text, never from what the user said, so it can only say what really happened.
// The persona's style does not colour it (Sam's decision of 14 Nov 2026); the "call me" name is put
// before the full stop: "opened safari, sir." Lowercase, like every word Clicky says. Foundation only.

nonisolated enum ClickyFixedConfirmationText {
    /// A web search's words are cut to this many characters (at a word where it can).
    static let maximumSearchQueryCharacters = 60

    /// The sentence for one action's result, or nil when the result is not one this table speaks for
    /// (an action that needs the model's words, a result in an unexpected form, an empty one). With a
    /// "call me" name the name goes before the full stop.
    static func sentence(forKind kind: ClickyActionKind, resultText: String, persona: ClickyPersona) -> String? {
        guard let plainSentence = sentenceWithoutAddress(forKind: kind, resultText: resultText) else {
            return nil
        }
        let userAddress = ClickyActionText.collapsedToOneLine(persona.userAddress.lowercased())
        guard !userAddress.isEmpty else {
            return plainSentence
        }
        return String(plainSentence.dropLast()) + ", " + userAddress + "."
    }

    /// The table, without the form of address. Every sentence ends with one full stop.
    static func sentenceWithoutAddress(forKind kind: ClickyActionKind, resultText rawResultText: String) -> String? {
        let resultText = rawResultText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .openApp, .openLink:
            // "opened Safari." / "opened youtube.com." → "opened safari." / "opened youtube.com."
            guard resultText.hasPrefix("opened "), resultText.hasSuffix("."), !resultText.contains("\n") else { return nil }
            return finished(String(resultText.dropLast()))

        case .searchWeb:
            // `opened a google search for "best pizza in amsterdam".` → "searching for best pizza in amsterdam."
            let searchPrefix = "opened a google search for \""
            guard resultText.hasPrefix(searchPrefix), resultText.hasSuffix("\".") else { return nil }
            let query = String(resultText.dropFirst(searchPrefix.count).dropLast(2))
            let cutQuery = cutAtAWord(query, maximumCharacters: maximumSearchQueryCharacters)
            guard !cutQuery.isEmpty else { return nil }
            return finished("searching for " + cutQuery)

        case .openFile:
            // "opened Compose.swift at line 9 in Xcode." → "opened compose.swift at line 9."
            // "opened Compose.swift in Xcode." / "opened Compose.swift." → "opened compose.swift."
            // A result that says the line was left out needs the model's words.
            guard resultText.hasPrefix("opened "), resultText.hasSuffix("."), !resultText.contains("without the line") else { return nil }
            let opened = String(resultText.dropFirst("opened ".count).dropLast())
            if let lineRange = opened.range(of: " at line ") {
                let fileName = String(opened[..<lineRange.lowerBound])
                let afterLine = opened[lineRange.upperBound...]
                let lineNumber = afterLine.prefix { $0.isNumber }
                guard !fileName.isEmpty, !lineNumber.isEmpty else { return nil }
                return finished("opened \(fileName) at line \(lineNumber)")
            }
            let fileName = opened.range(of: " in ").map { String(opened[..<$0.lowerBound]) } ?? opened
            guard !fileName.isEmpty else { return nil }
            return finished("opened \(fileName)")

        case .revealFile:
            // "showed Compose.swift in finder." → "showing compose.swift in finder."
            guard resultText.hasPrefix("showed "), resultText.hasSuffix(" in finder.") else { return nil }
            let fileName = String(resultText.dropFirst("showed ".count).dropLast(" in finder.".count))
            guard !fileName.isEmpty else { return nil }
            return finished("showing \(fileName) in finder")

        case .setTimer:
            // `timer t1 "pasta" started: 10 minutes, ends at 15:42.` → "pasta timer set, 10 minutes."
            // `timer t1 started: 10 minutes, ends at 15:42.` → "timer set, 10 minutes."
            guard resultText.hasPrefix("timer "),
                  let startedRange = resultText.range(of: " started: "),
                  let endsRange = resultText.range(of: ", ends at ", range: startedRange.upperBound..<resultText.endIndex) else { return nil }
            let durationText = String(resultText[startedRange.upperBound..<endsRange.lowerBound])
            guard !durationText.isEmpty else { return nil }
            let timerDescription = String(resultText[resultText.index(resultText.startIndex, offsetBy: "timer ".count)..<startedRange.lowerBound])
            if let label = quotedLabel(in: timerDescription) {
                return finished("\(label) timer set, \(durationText)")
            }
            return finished("timer set, \(durationText)")

        case .cancelTimer:
            // `stopped timer t1 "pasta".` → "stopped the pasta timer."; `stopped timer t1.` → "stopped timer t1."
            guard resultText.hasPrefix("stopped timer "), resultText.hasSuffix(".") else { return nil }
            let timerDescription = String(resultText.dropFirst("stopped timer ".count).dropLast())
            if let label = quotedLabel(in: timerDescription) {
                return finished("stopped the \(label) timer")
            }
            guard !timerDescription.isEmpty, !timerDescription.contains(" ") else { return nil }
            return finished("stopped timer \(timerDescription)")

        case .openLinkQueued, .runShortcutQueued, .createReminder, .listReminders, .listShortcuts:
            // A link or shortcut that waits needs the ready sentence the honesty rule governs; a
            // reminder and the two lookups need words the result does not give.
            return nil
        }
    }

    /// The label between the double quotes of a timer description (`t1 "pasta"`), or nil.
    private static func quotedLabel(in timerDescription: String) -> String? {
        guard let openingQuote = timerDescription.firstIndex(of: "\""),
              let closingQuote = timerDescription.lastIndex(of: "\""),
              openingQuote < closingQuote else {
            return nil
        }
        let label = String(timerDescription[timerDescription.index(after: openingQuote)..<closingQuote])
        let cleanedLabel = ClickyActionText.collapsedToOneLine(label)
        return cleanedLabel.isEmpty ? nil : cleanedLabel
    }

    /// Lowercase, one line, one full stop at the end.
    private static func finished(_ sentenceWithoutStop: String) -> String {
        ClickyActionText.collapsedToOneLine(sentenceWithoutStop.lowercased()) + "."
    }

    /// The text cut to at most `maximumCharacters`, at the last space inside the limit when there is one.
    static func cutAtAWord(_ text: String, maximumCharacters: Int) -> String {
        let collapsedText = ClickyActionText.collapsedToOneLine(text)
        guard collapsedText.count > maximumCharacters else {
            return collapsedText
        }
        let prefix = String(collapsedText.prefix(maximumCharacters))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace])
        }
        return prefix
    }
}
