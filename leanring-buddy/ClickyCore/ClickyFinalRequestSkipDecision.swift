import Foundation

// Round 19 (Jarvis tuning), candidate A: after one simple action done at once, the turn ends without
// the second request, which only turned the tool's result into a sentence. Measured on 14 Nov 2026 an
// action turn was two requests, 4.7 s and $0.0117; the second request was the whole second half of
// the time and about half of the cost. The fixed confirmation (`ClickyFixedConfirmationText`) is said
// instead. Anything that needs reasoning still goes back to the model: an error, close names, a link or
// shortcut that waits, a reminder, a lookup, a file tool, two calls, or words that are more than a plain
// command. Foundation only.

nonisolated enum ClickyFinalRequestSkipDecision {
    /// The kinds of action whose result a fixed sentence can say. `openLinkQueued` and
    /// `runShortcutQueued` never skip (the ready sentence the honesty rule governs must be said), nor
    /// do `createReminder`, `listReminders` and `listShortcuts` (their replies need words the result
    /// does not give).
    static let kindsThatMaySkip: Set<ClickyActionKind> = [.openApp, .openLink, .searchWeb, .openFile, .revealFile, .setTimer, .cancelTimer]

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
        let toolResults: [ClickyFileToolResult]
        /// What the turn's action session recorded (one entry per action that happened or was queued).
        let recordedActionKinds: [ClickyActionKind]
        /// File tool calls made in this turn.
        let fileToolCallCount: Int
        let transcript: String
        /// The persona's assistant name, so "hey jarvis" counts as a polite prefix.
        let assistantName: String
    }

    /// True only when all of these hold: it is the turn's first request; the reply stopped for a tool
    /// call and holds exactly one `tool_use`, with valid input, naming an action tool; its result is
    /// not an error; the action session recorded exactly one action, of a kind in `kindsThatMaySkip`;
    /// no file tool was called in this turn; the fixed sentence can be built from the result; and the
    /// transcript is a plain command by the shared word rules (`ClickySimpleCommandWords`: at most 12
    /// words, no joining, conditional or question word, no question mark but a trailing one after a
    /// polite prefix).
    static func shouldSkip(_ facts: Facts) -> Bool {
        guard facts.requestNumber == 1,
              facts.stopReason == "tool_use",
              facts.toolUseNames.count == 1,
              facts.everyToolInputWasValidJSON,
              let toolName = facts.toolUseNames.first,
              ClickyActionToolName(rawValue: toolName) != nil,
              facts.toolResults.count == 1,
              let toolResult = facts.toolResults.first,
              !toolResult.isError,
              facts.recordedActionKinds.count == 1,
              let recordedKind = facts.recordedActionKinds.first,
              kindsThatMaySkip.contains(recordedKind),
              facts.fileToolCallCount == 0 else {
            return false
        }
        guard ClickyFixedConfirmationText.sentenceWithoutAddress(forKind: recordedKind, resultText: toolResult.text) != nil else {
            return false
        }
        return ClickySimpleCommandWords.plainCommandText(facts.transcript, assistantName: facts.assistantName) != nil
    }

    /// The gate for a reply the loop has just answered, with the turn's sessions.
    static func shouldSkip(
        replyMessage: ClickyStreamedMessage,
        requestNumber: Int,
        toolResults: [ClickyFileToolResult],
        actionSession: ClickyActionToolTurnSession,
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
            assistantName: assistantName
        ))
    }
}
