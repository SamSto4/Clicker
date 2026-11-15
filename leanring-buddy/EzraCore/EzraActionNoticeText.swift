import Foundation

// Round 19 (Jarvis tuning): the short line the status pill shows the moment an action is done
// ("opened safari", "timer t1 pasta started"), before the model has written a word about it. Today the
// result of an action is first heard about three seconds after it happened; the notice makes the speed
// visible, and it still helps with "speak replies" off. Foundation only.
//
// Privacy: the notice shows an app name, a link, a file name or a timer label on screen for a few
// seconds. It is never logged (the pill never was).

nonisolated enum EzraActionNoticeText {
    /// A notice longer than this is cut, its last character an ellipsis.
    static let maximumCharacters = 60
    /// What a link or shortcut that waits on the change card shows.
    static let waitingForYesText = "waiting for your yes"
    /// How long the notice stays: until speech has had time to start, or longer when no spoken reply
    /// follows (a typed turn, or "speak replies" off).
    static let displaySecondsWhenAReplyFollows: TimeInterval = 3
    static let displaySecondsWhenNoReplyFollows: TimeInterval = 6

    static func displaySeconds(replyIsSpoken: Bool) -> TimeInterval {
        replyIsSpoken ? displaySecondsWhenAReplyFollows : displaySecondsWhenNoReplyFollows
    }

    /// The kind of action a successful action tool call was, read from the tool's name and its result
    /// (the result texts are the action session's own fixed sentences). Nil for an error, and for a
    /// tool that is not an action tool.
    static func kindOfSuccessfulResult(toolName: String, resultText: String, isError: Bool) -> EzraActionKind? {
        guard !isError, let actionToolName = EzraActionToolName(rawValue: toolName) else {
            return nil
        }
        switch actionToolName {
        case .openApp:
            return .openApp
        case .openURL:
            return resultText == EzraActionResultTexts.linkQueued ? .openLinkQueued : .openLink
        case .searchWeb:
            return .searchWeb
        case .openFile:
            return resultText.hasPrefix("showed ") ? .revealFile : .openFile
        case .setTimer:
            return .setTimer
        case .cancelTimer:
            return .cancelTimer
        case .createReminder:
            return .createReminder
        case .listReminders:
            return .listReminders
        case .listShortcuts:
            return .listShortcuts
        case .runShortcut:
            return .runShortcutQueued
        }
    }

    /// The notice for a successful action, or nil when there is nothing to show. A link or shortcut
    /// that waits says "waiting for your yes"; a lookup (the reminders or the shortcuts list) shows
    /// nothing, because what it found is the reply's to say; every other action shows the first
    /// sentence of its result without its full stop, quotes taken out, lowercase like every word
    /// Ezra shows, cut at 60 characters.
    static func notice(forResultText resultText: String, kind: EzraActionKind) -> String? {
        switch kind {
        case .openLinkQueued, .runShortcutQueued:
            return waitingForYesText
        case .listReminders, .listShortcuts:
            return nil
        case .openApp, .openLink, .searchWeb, .openFile, .revealFile, .setTimer, .cancelTimer, .createReminder:
            let firstSentence = Self.firstSentence(of: resultText)
                .replacingOccurrences(of: "\"", with: "")
                .lowercased()
            let collapsedSentence = EzraActionText.collapsedToOneLine(firstSentence)
            guard !collapsedSentence.isEmpty else {
                return nil
            }
            if collapsedSentence.count > maximumCharacters {
                return String(collapsedSentence.prefix(maximumCharacters - 1)) + "…"
            }
            return collapsedSentence
        }
    }

    /// The text up to the first full stop or colon that ends a sentence (followed by a space or the
    /// end), or the first line break. A full stop inside a word ("youtube.com", "3.5") does not end
    /// a sentence.
    static func firstSentence(of text: String) -> String {
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character == "\n" {
                return String(characters[..<index])
            }
            guard character == "." || character == ":" else { continue }
            let nextIndex = index + 1
            if nextIndex == characters.count || characters[nextIndex] == " " || characters[nextIndex] == "\n" {
                return String(characters[..<index])
            }
        }
        return text
    }
}
