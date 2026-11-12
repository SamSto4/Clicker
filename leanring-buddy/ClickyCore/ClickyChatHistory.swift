import Foundation

// The chat history behind the chat panel: what a chat is, how one is titled, when a new one
// starts, when an old one is deleted, how chats are searched and grouped, and how a secret is
// kept out of them. Everything here is pure; the files are read and written by `ClickyChatStore`.

/// One message from the user and Clicky's reply to it.
nonisolated struct ClickyChatExchange: Codable, Equatable {
    /// What the user said or typed, after redaction (see `ClickyChatRedaction`).
    let userText: String
    let inputMode: ClickyTurnInputMode
    /// Clicky's reply as shown in the panel: every tag removed, after redaction.
    let replyDisplayText: String
    /// The reply as the turn finisher returns it for the conversation history (tags such as
    /// [NOTE:...] and [DRAW:...] kept in canonical form), after redaction. Continuing a chat
    /// loads these, so the model sees the same history text it would have seen at the time.
    let replyHistoryText: String
    let timestamp: Date
    /// The app and window title the user was on when they sent the message (the title already
    /// cleaned and checked by `ClickyChatRedaction.redactedScreen`). nil for a chat file written
    /// before screens were recorded, and for a turn where the app was unknown. It is a `var` with
    /// a default so such an old file still decodes (a missing key reads as nil) and every caller
    /// that does not pass it compiles unchanged. Continuing a chat uses it to tell whether the
    /// screen changed since the last exchange.
    var screenOfExchange: ClickyScreenDescription? = nil
}

/// Where the user was when a chat started. The key groups chats; the display name is what the
/// panel shows for the group.
nonisolated struct ClickyChatProject: Codable, Equatable {
    let key: String
    let displayName: String

    /// For a chat whose origin could not be worked out at all.
    static let unknown = ClickyChatProject(key: "app:unknown", displayName: "other")
}

/// One chat: a run of exchanges that started in one place.
nonisolated struct ClickyChat: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let project: ClickyChatProject
    /// A kept chat is never deleted by retention.
    var isKept: Bool
    /// The first message, cut short. Never made by a model call.
    var title: String
    var exchanges: [ClickyChatExchange]

    init(
        id: UUID = UUID(),
        createdAt: Date,
        project: ClickyChatProject,
        isKept: Bool = false,
        exchanges: [ClickyChatExchange] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = exchanges.last?.timestamp ?? createdAt
        self.project = project
        self.isKept = isKept
        self.title = ClickyChatTitle.title(forFirstUserText: exchanges.first?.userText ?? "")
        self.exchanges = exchanges
    }

    /// When the last message was added, or when the chat was created if it has none yet.
    var lastMessageAt: Date {
        exchanges.last?.timestamp ?? createdAt
    }

    /// The first line of the newest reply, for the chat list. Empty for a chat without exchanges.
    var previewText: String {
        guard let newestExchange = exchanges.last else { return "" }
        let newestReplyFirstLine = newestExchange.replyDisplayText
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        return newestReplyFirstLine.trimmingCharacters(in: .whitespaces)
    }

    /// Adds an exchange, moves the "updated" time to it, and gives the chat its title if this is
    /// the first message.
    mutating func append(_ exchange: ClickyChatExchange) {
        exchanges.append(exchange)
        updatedAt = exchange.timestamp
        if exchanges.count == 1 {
            title = ClickyChatTitle.title(forFirstUserText: exchange.userText)
        }
    }
}

/// How a chat is named: its first message, on one line, cut to about sixty characters.
nonisolated enum ClickyChatTitle {
    static let maximumCharacterCount = 60
    static let untitledChatTitle = "new chat"

    static func title(forFirstUserText firstUserText: String) -> String {
        let singleLineText = firstUserText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !singleLineText.isEmpty else { return untitledChatTitle }
        guard singleLineText.count > maximumCharacterCount else { return singleLineText }
        // One character of the budget goes to the ellipsis, so the title never passes the limit.
        return String(singleLineText.prefix(maximumCharacterCount - 1)) + "…"
    }
}

/// When a message starts a new chat instead of continuing the active one.
///
/// Only time decides. The place the user is in is deliberately not an input: a chat's project is
/// where it started, and switching apps keeps the chat going, because a follow-up after switching
/// apps keeps its context with the model today. Cutting the chat (and with it the history the
/// model sees) on an app switch would change that.
nonisolated enum ClickyChatBoundary {
    /// After this long without a message the next message starts a new chat. Ten minutes is also
    /// the idle time after which `CompanionManager` saves the session summary to the long-term
    /// memory server; that timer only sends the summary. Clearing the conversation history the
    /// model sees is decided separately, by `idleBoundaryAlsoClearsConversationHistory` below.
    static let newChatAfterSecondsWithoutMessage: TimeInterval = 10 * 60

    /// Whether a new chat that starts because ten minutes passed also clears the conversation
    /// history the model sees. True (Sam's choice, 12 Nov 2026): after ten quiet minutes Clicky
    /// starts fresh, the same as the new chat in the panel. Before this, the history was only
    /// capped at ten exchanges for the life of the process, so an old conversation about an
    /// earlier screen could bleed into a new question ("my mistake, it looks like you aren't
    /// looking at an article now"). "Continue" on an old chat still brings its context back. Read
    /// in one place, at the start of a turn in `CompanionManager`.
    static let idleBoundaryAlsoClearsConversationHistory = true

    static func shouldStartNewChat(lastMessageAt: Date?, now: Date) -> Bool {
        guard let lastMessageAt else { return true }
        return now.timeIntervalSince(lastMessageAt) > newChatAfterSecondsWithoutMessage
    }
}

/// How long a chat is kept: ninety days after its last message, unless the user marked it "keep".
nonisolated enum ClickyChatRetention {
    static let retentionDays = 90
    static let retentionSeconds: TimeInterval = TimeInterval(retentionDays) * 24 * 60 * 60
    /// Retention runs at launch and then this often.
    static let runEverySeconds: TimeInterval = 6 * 60 * 60

    static func isDueForDeletion(_ chat: ClickyChat, now: Date) -> Bool {
        guard !chat.isKept else { return false }
        return now.timeIntervalSince(chat.lastMessageAt) > retentionSeconds
    }
}

/// The search field of the chat list: a chat matches when its title or any message holds the
/// words, whatever their case or accents. An empty search matches every chat.
nonisolated enum ClickyChatSearch {
    static func matches(_ chat: ClickyChat, query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }
        let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if chat.title.range(of: trimmedQuery, options: searchOptions) != nil { return true }
        return chat.exchanges.contains { exchange in
            exchange.userText.range(of: trimmedQuery, options: searchOptions) != nil
                || exchange.replyDisplayText.range(of: trimmedQuery, options: searchOptions) != nil
        }
    }

    static func chatsMatching(_ query: String, in chats: [ClickyChat]) -> [ClickyChat] {
        chats.filter { matches($0, query: query) }
    }
}

/// Chats grouped by the project they started in, newest group first and newest chat first
/// within a group.
nonisolated struct ClickyChatProjectGroup: Equatable, Identifiable {
    let project: ClickyChatProject
    let chats: [ClickyChat]

    var id: String { project.key }
}

nonisolated enum ClickyChatProjectGrouping {
    static func groups(of chats: [ClickyChat]) -> [ClickyChatProjectGroup] {
        var chatsByProjectKey: [String: [ClickyChat]] = [:]
        for chat in chats {
            chatsByProjectKey[chat.project.key, default: []].append(chat)
        }
        return chatsByProjectKey
            .map { projectKey, chatsOfProject -> ClickyChatProjectGroup in
                let chatsNewestFirst = chatsOfProject.sorted { $0.updatedAt > $1.updatedAt }
                // The newest chat's display name is used, so a renamed folder shows its newer name.
                let project = chatsNewestFirst.first?.project ?? ClickyChatProject(key: projectKey, displayName: projectKey)
                return ClickyChatProjectGroup(project: project, chats: chatsNewestFirst)
            }
            .sorted { groupA, groupB in
                let newestA = groupA.chats.first?.updatedAt ?? .distantPast
                let newestB = groupB.chats.first?.updatedAt ?? .distantPast
                if newestA != newestB { return newestA > newestB }
                return groupA.project.displayName < groupB.project.displayName
            }
    }
}

/// Chat history is a save path, so the rule that secrets are never saved applies to it: a user
/// text or reply that `ClickySecretDetector` flags is stored as a fixed placeholder. The
/// detector refuses on a value, not on a topic, so Clicky's honest answer about a saved password
/// ("your office wifi password is in your notes, but i won't read it out loud.") is kept as it is.
nonisolated enum ClickyChatRedaction {
    static let redactedTextPlaceholder = "[removed: looked like a secret]"

    static func redacted(_ text: String) -> String {
        ClickySecretDetector.textLooksLikeASecret(text) ? redactedTextPlaceholder : text
    }

    /// The screen a chat file may hold. A window title is text another program chose and can hold
    /// a secret ("Notes — wifi password is hunter2"), and chat files are a save path, so a title
    /// that looks like a secret is dropped and only the app name is kept.
    static func redactedScreen(_ screenDescription: ClickyScreenDescription?) -> ClickyScreenDescription? {
        guard let screenDescription else { return nil }
        guard let windowTitle = screenDescription.windowTitle, ClickySecretDetector.textLooksLikeASecret(windowTitle) else {
            return screenDescription
        }
        return ClickyScreenDescription(applicationName: screenDescription.applicationName, windowTitle: nil)
    }

    /// An exchange with every text passed through the secret check.
    static func redactedExchange(
        userText: String,
        inputMode: ClickyTurnInputMode,
        replyDisplayText: String,
        replyHistoryText: String,
        timestamp: Date,
        screenOfExchange: ClickyScreenDescription? = nil
    ) -> ClickyChatExchange {
        ClickyChatExchange(
            userText: redacted(userText),
            inputMode: inputMode,
            replyDisplayText: redacted(replyDisplayText),
            replyHistoryText: redacted(replyHistoryText),
            timestamp: timestamp,
            screenOfExchange: redactedScreen(screenOfExchange)
        )
    }
}
