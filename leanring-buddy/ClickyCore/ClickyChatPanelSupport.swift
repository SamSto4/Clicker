import Foundation

// Small pure rules the chat panel needs: how a chat's age is written in the list, how the arrow
// keys move through the list, how the double delivery of one Escape key press is handled, and
// how a continued chat becomes the conversation history the model sees.

/// How old a chat is, in the few words the chat list shows next to it.
nonisolated enum ClickyChatTimeText {
    /// "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago", then a date such as "nov 3"
    /// (with the year when it is not this year). Lowercase, like every other word Clicky shows.
    static func text(for chatTime: Date, now: Date, calendar: Calendar = .current) -> String {
        let secondsAgo = now.timeIntervalSince(chatTime)
        // A time in the future (a clock that moved) reads as "just now" too.
        if secondsAgo < 60 { return "just now" }
        if secondsAgo < 60 * 60 { return "\(Int(secondsAgo / 60)) min ago" }
        if calendar.isDate(chatTime, inSameDayAs: now) {
            return "\(Int(secondsAgo / (60 * 60))) h ago"
        }

        // Whole calendar days, so 23:30 yesterday is "yesterday" at 09:00 even though it is only
        // nine and a half hours ago.
        let wholeDaysAgo = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: chatTime),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if wholeDaysAgo <= 1 { return "yesterday" }
        if wholeDaysAgo < 7 { return "\(wholeDaysAgo) days ago" }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        let isInTheSameYear = calendar.component(.year, from: chatTime) == calendar.component(.year, from: now)
        dateFormatter.dateFormat = isInTheSameYear ? "MMM d" : "MMM d yyyy"
        return dateFormatter.string(from: chatTime).lowercased()
    }
}

/// Moving the highlighted row of the chat list with the up and down arrow keys.
nonisolated enum ClickyChatListNavigation {
    enum Direction {
        case up
        case down
    }

    /// The row to highlight after an arrow key. With nothing highlighted, down picks the first row
    /// and up the last. At either end the highlight stays where it is (it does not wrap round).
    static func selectedChatID(
        afterMoving direction: Direction,
        from currentSelectedChatID: UUID?,
        orderedChatIDs: [UUID]
    ) -> UUID? {
        guard !orderedChatIDs.isEmpty else { return nil }
        guard let currentSelectedChatID, let currentIndex = orderedChatIDs.firstIndex(of: currentSelectedChatID) else {
            return direction == .down ? orderedChatIDs.first : orderedChatIDs.last
        }
        switch direction {
        case .up:
            return orderedChatIDs[max(0, currentIndex - 1)]
        case .down:
            return orderedChatIDs[min(orderedChatIDs.count - 1, currentIndex + 1)]
        }
    }

    /// After the list changes (a search, a delete), keep the highlighted row if it is still shown;
    /// otherwise highlight the first row, or nothing when the list is empty.
    static func selectedChatIDAfterListChanged(
        currentSelectedChatID: UUID?,
        orderedChatIDs: [UUID]
    ) -> UUID? {
        if let currentSelectedChatID, orderedChatIDs.contains(currentSelectedChatID) {
            return currentSelectedChatID
        }
        return orderedChatIDs.first
    }
}

/// One press of Escape reaches Clicky twice while the chat panel is open: once from the global
/// key tap and once as a key event of the panel itself. Whichever arrives first decides (stop
/// the running turn, or close the panel); the second, a few milliseconds later, must do nothing,
/// or a single press would first cancel the turn and then also close the panel.
nonisolated struct ClickyChatPanelEscapeDeduplicator {
    /// The two deliveries of one key press are a few milliseconds apart; a second press by a
    /// person is never this quick.
    static let secondsDuringWhichASecondDeliveryIsTheSamePress: TimeInterval = 0.25

    private var lastHandledUptimeSeconds: TimeInterval?

    /// Returns true when this Escape should be handled, and remembers the time.
    mutating func shouldHandleEscape(atUptimeSeconds uptimeSeconds: TimeInterval) -> Bool {
        if let lastHandledUptimeSeconds,
           uptimeSeconds - lastHandledUptimeSeconds < Self.secondsDuringWhichASecondDeliveryIsTheSamePress,
           uptimeSeconds >= lastHandledUptimeSeconds {
            return false
        }
        lastHandledUptimeSeconds = uptimeSeconds
        return true
    }
}

/// One exchange of the conversation history the model sees: what the user said, Clicky's reply as
/// written for the history, and the screen the user was on (nil when it is not known).
typealias ClickyConversationHistoryEntry = (
    userTranscript: String,
    assistantResponse: String,
    screenOfExchange: ClickyScreenDescription?
)

/// Turns a chat the user continues into the conversation history the model sees: its last
/// exchanges, the same cap the live conversation uses.
nonisolated enum ClickyConversationHistoryLoader {
    /// The cap on the conversation history: only the last ten exchanges are kept and sent.
    static let maximumConversationHistoryExchangeCount = 10

    /// The history text of each exchange (the reply with its [NOTE:], [PROFILE:] and draw tags in
    /// canonical form, as the model saw it at the time). An exchange stored with the placeholder
    /// for a secret loads as that placeholder: the secret itself was never written. The screen of
    /// each exchange comes along; a chat saved before screens were recorded has none, which is
    /// "unknown" and never produces the "another screen" note.
    static func conversationHistoryEntries(
        from chat: ClickyChat,
        maximumExchangeCount: Int = maximumConversationHistoryExchangeCount
    ) -> [ClickyConversationHistoryEntry] {
        chat.exchanges
            .suffix(max(0, maximumExchangeCount))
            .map { exchange in
                (
                    userTranscript: exchange.userText,
                    assistantResponse: exchange.replyHistoryText,
                    screenOfExchange: exchange.screenOfExchange
                )
            }
    }
}
