import Foundation

/// The chats in memory and which one is active: the pure rules the chat panel and the turn
/// pipeline share. The app-side `ClickyChatSession` wraps one of these and does the file writes.
///
/// A value type on purpose: every rule (which chat a message goes to, what "continue" does to the
/// ten-minute boundary, what a late disk read may and may not bring back) is tested with explicit
/// dates and no disk.
nonisolated struct ClickyChatCollection: Equatable {
    /// Every chat known in this run, newest first.
    private(set) var chats: [ClickyChat] = []
    /// The chat the next message goes to, or nil when the next message starts a new chat.
    private(set) var activeChatID: UUID?
    /// When the active chat last had activity: its last message, or the moment the user chose to
    /// continue it. The ten-minute boundary counts from here and not from the chat's last
    /// message, because a chat the user deliberately reopened must take their next message
    /// however old its last message is.
    private(set) var activeChatLastActivityAt: Date?
    /// Chats the user deleted in this run. A disk read that was already under way when they were
    /// deleted must not bring them back.
    private(set) var chatIDsDeletedInThisRun: Set<UUID> = []

    init() {}

    // MARK: - Reading

    var activeChat: ClickyChat? {
        guard let activeChatID else { return nil }
        return chats.first { $0.id == activeChatID }
    }

    func chat(withID chatID: UUID) -> ClickyChat? {
        chats.first { $0.id == chatID }
    }

    /// True when a message sent at `messageStartedAt` would open a new chat: there is no active
    /// chat, or ten minutes have passed since its last activity.
    func messageWouldStartNewChat(at messageStartedAt: Date) -> Bool {
        guard activeChat != nil else { return true }
        return ClickyChatBoundary.shouldStartNewChat(lastMessageAt: activeChatLastActivityAt, now: messageStartedAt)
    }

    /// The chats shown in the list for this search, grouped by project.
    func projectGroups(matching searchQuery: String) -> [ClickyChatProjectGroup] {
        ClickyChatProjectGrouping.groups(of: ClickyChatSearch.chatsMatching(searchQuery, in: chats))
    }

    // MARK: - Changing

    /// Called when the panel opens: a chat that has been idle for ten minutes is over, so the
    /// panel shows an empty new chat instead of an old one the next message would not join. This
    /// only ends the stored chat; it does not touch the conversation history the model sees.
    mutating func endActiveChatIfIdleTooLong(at now: Date) {
        guard activeChatID != nil else { return }
        if messageWouldStartNewChat(at: now) {
            activeChatID = nil
            activeChatLastActivityAt = nil
        }
    }

    /// The user picked "new chat".
    mutating func startNewChatByUser() {
        activeChatID = nil
        activeChatLastActivityAt = nil
    }

    /// The user picked "continue" on a chat: it becomes the active chat, and its ten minutes
    /// start now. Returns the chat, or nil when there is no such chat.
    @discardableResult
    mutating func continueChat(withID chatID: UUID, at now: Date) -> ClickyChat? {
        guard let chatToContinue = chat(withID: chatID) else { return nil }
        activeChatID = chatToContinue.id
        activeChatLastActivityAt = now
        return chatToContinue
    }

    /// Adds a finished exchange to the active chat, or to a new chat when the message was the
    /// first of a chat (no active chat, or ten idle minutes had passed when it was sent).
    /// `messageStartedAt` is when the user sent the message; the exchange's own timestamp is when
    /// the reply finished. `projectForNewChat` is only used when a new chat starts. Returns the
    /// chat to write to disk.
    mutating func recordExchange(
        _ exchange: ClickyChatExchange,
        messageStartedAt: Date,
        projectForNewChat: ClickyChatProject
    ) -> ClickyChat {
        var chatAfterRecording: ClickyChat
        if !messageWouldStartNewChat(at: messageStartedAt), let activeChat {
            chatAfterRecording = activeChat
            chatAfterRecording.append(exchange)
        } else {
            chatAfterRecording = ClickyChat(createdAt: messageStartedAt, project: projectForNewChat)
            chatAfterRecording.append(exchange)
        }
        replaceOrInsert(chatAfterRecording)
        activeChatID = chatAfterRecording.id
        activeChatLastActivityAt = exchange.timestamp
        return chatAfterRecording
    }

    /// Flips the "keep" mark. Returns the changed chat to write to disk, or nil if there is no
    /// such chat.
    @discardableResult
    mutating func toggleKept(chatID: UUID) -> ClickyChat? {
        guard var chatToChange = chat(withID: chatID) else { return nil }
        chatToChange.isKept.toggle()
        replaceOrInsert(chatToChange)
        return chatToChange
    }

    /// Takes the chat out of memory. If it was the active chat, the next message starts a new one.
    mutating func delete(chatID: UUID) {
        chats.removeAll { $0.id == chatID }
        chatIDsDeletedInThisRun.insert(chatID)
        if activeChatID == chatID {
            activeChatID = nil
            activeChatLastActivityAt = nil
        }
    }

    /// Takes chats out of memory because retention deleted their files.
    mutating func removeChatsDeletedByRetention(withIDs removedChatIDs: [UUID]) {
        guard !removedChatIDs.isEmpty else { return }
        let removedChatIDSet = Set(removedChatIDs)
        chats.removeAll { removedChatIDSet.contains($0.id) }
        if let activeChatID, removedChatIDSet.contains(activeChatID) {
            self.activeChatID = nil
            activeChatLastActivityAt = nil
        }
    }

    /// Merges the chats a disk read found. A chat already in memory keeps its in-memory version
    /// (it may be newer than the file that was read), and a chat the user deleted since the read
    /// began stays deleted.
    mutating func mergeChatsReadFromDisk(_ chatsReadFromDisk: [ClickyChat]) {
        let chatIDsInMemory = Set(chats.map(\.id))
        for chatReadFromDisk in chatsReadFromDisk {
            if chatIDsInMemory.contains(chatReadFromDisk.id) { continue }
            if chatIDsDeletedInThisRun.contains(chatReadFromDisk.id) { continue }
            chats.append(chatReadFromDisk)
        }
        sortNewestFirst()
    }

    // MARK: - Private

    private mutating func replaceOrInsert(_ chatToStore: ClickyChat) {
        if let existingIndex = chats.firstIndex(where: { $0.id == chatToStore.id }) {
            chats[existingIndex] = chatToStore
        } else {
            chats.append(chatToStore)
        }
        sortNewestFirst()
    }

    private mutating func sortNewestFirst() {
        chats.sort { $0.updatedAt > $1.updatedAt }
    }
}
