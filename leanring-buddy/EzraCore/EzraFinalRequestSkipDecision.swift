import Foundation

// Round 19 (Jarvis tuning), candidate A: after one simple action done at once, the turn ends without
// the second request, which only turned the tool's result into a sentence. Measured on 14 Nov 2026 an
// action turn was two requests, 4.7 s and $0.0117; the second request was the whole second half of
// the time and about half of the cost. The fixed confirmation (`EzraFixedConfirmationText`) is said
// instead. Anything that needs reasoning still goes back to the model: an error, close names, a link or
// shortcut that waits, a reminder, a lookup, a file tool, two calls, or words that are more than a plain
// command. The round 19 review added the last check: every word of the command must be accounted for
// by the action itself, because "open slack summarize my inbox" passed the shared word rules and the
// user heard only "opened slack." Not skipping is always safe: the model then says the words.
// Foundation only.

nonisolated enum EzraFinalRequestSkipDecision {
    /// The kinds of action whose result a fixed sentence can say. `openLinkQueued` and
    /// `runShortcutQueued` never skip (the ready sentence the honesty rule governs must be said), nor
    /// do `createReminder`, `listReminders` and `listShortcuts` (their replies need words the result
    /// does not give).
    static let kindsThatMaySkip: Set<EzraActionKind> = [.openApp, .openLink, .searchWeb, .openFile, .revealFile, .setTimer, .cancelTimer]

    /// Round 19 review: the words of a plain command that ask for the action itself, and the small words
    /// around them. Every other word of the command must be found in the tool call's input (the app's
    /// name, the link, the search words, the path), or the user asked for more than the action did. The
    /// orchestrator's fixed list; a word missing from it only means the model says the words.
    static let commandWordsTheActionAccountsFor: Set<String> = [
        "open", "launch", "start", "switch", "go", "to", "show", "search", "google", "look", "up", "web",
        "internet", "for", "set", "a", "an", "the", "my", "me", "please", "now", "app", "application",
        "site", "website", "page", "repo", "repository", "file", "folder", "in", "finder", "on", "at", "called",
        // Added after the tester's re-run: everyday ways to say "open" ("pull up youtube", "fire up
        // xcode", "bring up safari", "boot up slack", "run xcode", "hop into safari", "pop open notes"),
        // "reveal" (reveal ... in finder) and "line" (open ... at line 9, whose number is in the input).
        "pull", "fire", "bring", "boot", "run", "hop", "pop", "into", "line", "reveal",
    ]

    /// What the gate looks at, as plain values.
    struct Facts: Equatable {
        /// The request of the loop whose reply holds the tool calls (counting from 1).
        let requestNumber: Int
        let stopReason: String?
        /// The names of the reply's `tool_use` blocks, in order.
        let toolUseNames: [String]
        /// False when a tool call's input was not valid JSON.
        let everyToolInputWasValidJSON: Bool
        /// The results of those calls, in order.
        let toolResults: [EzraFileToolResult]
        /// What the turn's action session recorded (one entry per action that happened or was queued).
        let recordedActionKinds: [EzraActionKind]
        /// File tool calls made in this turn.
        let fileToolCallCount: Int
        let transcript: String
        /// The persona's assistant name, so "hey jarvis" counts as a polite prefix.
        let assistantName: String
        /// Round 19 review: the input of the reply's one tool call as texts (`inputValueTexts(of:)`): its
        /// string values, and its numbers written as text, ordered by key. Empty when the reply holds
        /// no call or several (which never skip anyway). A `var` with a default so the facts can still
        /// be made without it; then no word can be accounted for by the input, and only a timer's
        /// grammar can let the turn skip.
        var toolInputValueTexts: [String] = []
    }

    /// True only when all of these hold: it is the turn's first request; the reply stopped for a tool
    /// call and holds exactly one `tool_use`, with valid input, naming an action tool; its result is
    /// not an error; the action session recorded exactly one action, of a kind in `kindsThatMaySkip`;
    /// no file tool was called in this turn; the fixed sentence can be built from the result; the
    /// transcript is a plain command by the shared word rules (`EzraSimpleCommandWords`: at most 12
    /// words, no joining, conditional or question word, no question mark but a trailing one after a
    /// polite prefix); and every word of that command is accounted for by the action
    /// (`actionAccountsForEveryWord`).
    static func shouldSkip(_ facts: Facts) -> Bool {
        guard facts.requestNumber == 1,
              facts.stopReason == "tool_use",
              facts.toolUseNames.count == 1,
              facts.everyToolInputWasValidJSON,
              let toolName = facts.toolUseNames.first,
              let actionToolName = EzraActionToolName(rawValue: toolName),
              facts.toolResults.count == 1,
              let toolResult = facts.toolResults.first,
              !toolResult.isError,
              facts.recordedActionKinds.count == 1,
              let recordedKind = facts.recordedActionKinds.first,
              kindsThatMaySkip.contains(recordedKind),
              facts.fileToolCallCount == 0 else {
            return false
        }
        guard EzraFixedConfirmationText.sentenceWithoutAddress(forKind: recordedKind, resultText: toolResult.text) != nil else {
            return false
        }
        guard let plainCommandText = EzraSimpleCommandWords.plainCommandText(facts.transcript, assistantName: facts.assistantName) else {
            return false
        }
        return actionAccountsForEveryWord(
            ofPlainCommand: plainCommandText,
            actionToolName: actionToolName,
            toolInputValueTexts: facts.toolInputValueTexts
        )
    }

    /// Round 19 review: true when the action accounts for every word of the plain command. The words
    /// are `EzraSimpleCommandWords.tokens(of:)`; the command words in `commandWordsTheActionAccountsFor`
    /// are dropped, and each word left must be a word of the tool call's input, split the same way
    /// ("youtube.com" gives youtube and com, "samsto4/clicker" gives samsto4 and clicker). So "open
    /// safari" or "launch chrome" (Google Chrome) skip, and "open safari check the weather" does not.
    /// A command with no word left ("open the app") is accounted for: the fixed sentence still names
    /// what was opened. A timer's words are not in its input ("10 minutes" is 600 seconds; a cancel may
    /// name the timer by its id), so the closed timer grammar of quick commands reads the command instead.
    static func actionAccountsForEveryWord(
        ofPlainCommand plainCommandText: String,
        actionToolName: EzraActionToolName,
        toolInputValueTexts: [String]
    ) -> Bool {
        switch actionToolName {
        case .setTimer:
            return EzraQuickCommandParser.timerToSet(commandText: plainCommandText) != nil
        case .cancelTimer:
            // "stop the timer", "cancel the timer", "stop the <label> timer", "cancel the <label> timer".
            return EzraQuickCommandParser.labelPartOfAStopTimerCommand(commandText: plainCommandText) != nil
        default:
            let wordsOfTheInput = Set(toolInputValueTexts.flatMap { EzraSimpleCommandWords.tokens(of: $0) })
            let wordsLeftToAccountFor = EzraSimpleCommandWords.tokens(of: plainCommandText)
                .filter { !commandWordsTheActionAccountsFor.contains($0) }
            if wordsLeftToAccountFor.allSatisfy({ wordsOfTheInput.contains($0) }) {
                return true
            }
            // An app named by a known alias ("vs code", "system preferences"): the model writes the
            // app's full name in the input, so the alias's words are not in it, but the alias names
            // exactly that app.
            guard actionToolName == .openApp,
                  let aliasTarget = EzraAppNameMatcher.aliases[wordsLeftToAccountFor.joined(separator: " ")] else {
                return false
            }
            return toolInputValueTexts.contains { EzraActionText.normalizedForComparison($0) == aliasTarget }
        }
    }

    /// A tool call's input as the texts the gate compares words with: every string value, and every
    /// number written as text ("9" for a line), ordered by key. True and false (which JSON gives as a
    /// number too) and nested values are left out: they are no words the user could have said.
    static func inputValueTexts(of toolInput: [String: Any]) -> [String] {
        toolInput.sorted { $0.key < $1.key }.compactMap { (_, value) -> String? in
            if let text = value as? String {
                return text
            }
            if let number = value as? NSNumber {
                return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.stringValue
            }
            return nil
        }
    }

    /// The gate for a reply the loop has just answered, with the turn's sessions.
    static func shouldSkip(
        replyMessage: EzraStreamedMessage,
        requestNumber: Int,
        toolResults: [EzraFileToolResult],
        actionSession: EzraActionToolTurnSession,
        fileToolCallCount: Int,
        transcript: String,
        assistantName: String
    ) -> Bool {
        shouldSkip(Facts(
            requestNumber: requestNumber,
            stopReason: replyMessage.stopReason,
            toolUseNames: replyMessage.toolUseBlocks.map(\.name),
            everyToolInputWasValidJSON: replyMessage.toolUseBlocks.allSatisfy(\.inputWasValidJSON),
            toolResults: toolResults,
            recordedActionKinds: actionSession.actionKinds,
            fileToolCallCount: fileToolCallCount,
            transcript: transcript,
            assistantName: assistantName,
            toolInputValueTexts: replyMessage.toolUseBlocks.count == 1 ? inputValueTexts(of: replyMessage.toolUseBlocks[0].input) : []
        ))
    }
}
