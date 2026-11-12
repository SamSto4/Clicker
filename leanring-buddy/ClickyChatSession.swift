//
//  ClickyChatSession.swift
//  leanring-buddy
//
//  The chats of this run and their files. It wraps the pure `ClickyChatCollection` (which chat a
//  message goes to, continue, keep, delete) and does the one thing the pure code cannot: write
//  and read the chat files, off the main thread, in order.
//
//  Privacy: a chat holds text only (no screenshots, no audio), every text goes through the secret
//  check before it is written (`ClickyChatRedaction`), and the files live in
//  ~/Library/Application Support/Clicky/Chats, outside iCloud. Nothing here sends anything anywhere.
//

import Combine
import Foundation

@MainActor
final class ClickyChatSession: ObservableObject {
    /// The chats in memory and which one is active. Views read it; only this class changes it.
    @Published private(set) var collection = ClickyChatCollection()

    private let store: ClickyChatStore

    /// Every read, write and delete of a chat file runs on this one queue, so they happen in the
    /// order they were asked for: a delete can never be overtaken by an older save of the same
    /// chat, and a read sees every write before it.
    private let storeQueue = DispatchQueue(label: "com.clicky.chat-store", qos: .utility)

    private var retentionTask: Task<Void, Never>?

    init(store: ClickyChatStore) {
        self.store = store
    }

    /// The store for this run of the app. See `ClickyChatStore.chatsDirectoryURLForRun`: a self
    /// test run never uses the user's real folder.
    static func makeStoreForCurrentRun(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClickyChatStore {
        ClickyChatStore(
            chatsDirectoryURL: ClickyChatStore.chatsDirectoryURLForRun(
                environment: environment,
                temporaryDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                uniqueFolderNameForSelfTest: "clicky-panel-self-test-chats-\(UUID().uuidString)"
            )
        )
    }

    // MARK: - Reading

    /// Reads the chat files in the background and adds what it finds to the chats in memory. Called
    /// at launch and each time the panel opens, so a chat file added by hand shows up too.
    func reloadChatsFromDiskInBackground() {
        let store = self.store
        storeQueue.async { [weak self] in
            let chatsReadFromDisk = store.loadAllChats()
            Task { @MainActor [weak self] in
                self?.collection.mergeChatsReadFromDisk(chatsReadFromDisk)
            }
        }
    }

    // MARK: - Which chat

    func messageWouldStartNewChat(at messageStartedAt: Date) -> Bool {
        collection.messageWouldStartNewChat(at: messageStartedAt)
    }

    func endActiveChatIfIdleTooLong(at now: Date) {
        collection.endActiveChatIfIdleTooLong(at: now)
    }

    func startNewChatByUser() {
        collection.startNewChatByUser()
    }

    @discardableResult
    func continueChat(withID chatID: UUID, at now: Date = Date()) -> ClickyChat? {
        collection.continueChat(withID: chatID, at: now)
    }

    // MARK: - Recording

    /// Stores one finished exchange (a spoken or a typed message and Clicky's reply) in the active
    /// chat, or in a new chat when the message was the first of one. Every text is passed through
    /// the secret check first; a text that looks like a secret is stored as a fixed placeholder.
    func recordExchange(
        userText: String,
        inputMode: ClickyTurnInputMode,
        replyDisplayText: String,
        replyHistoryText: String,
        messageStartedAt: Date,
        replyFinishedAt: Date = Date(),
        projectForNewChat: ClickyChatProject,
        screenOfExchange: ClickyScreenDescription? = nil
    ) {
        let redactedExchange = ClickyChatRedaction.redactedExchange(
            userText: userText,
            inputMode: inputMode,
            replyDisplayText: replyDisplayText,
            replyHistoryText: replyHistoryText,
            timestamp: replyFinishedAt,
            screenOfExchange: screenOfExchange
        )
        let chatToWrite = collection.recordExchange(
            redactedExchange,
            messageStartedAt: messageStartedAt,
            projectForNewChat: projectForNewChat
        )
        writeInBackground(chatToWrite)
    }

    // MARK: - Keep and delete

    func toggleKept(chatID: UUID) {
        guard let chatToWrite = collection.toggleKept(chatID: chatID) else { return }
        writeInBackground(chatToWrite)
    }

    func delete(chatID: UUID) {
        collection.delete(chatID: chatID)
        let store = self.store
        storeQueue.async {
            if let errorDescription = store.deleteChat(withID: chatID) {
                print("⚠️ Clicky chat delete failed: \(errorDescription)")
            }
        }
    }

    // MARK: - Retention

    /// Deletes chats ninety days after their last message unless they are kept: now, and then
    /// every six hours for as long as the app runs.
    func startRetentionSchedule() {
        retentionTask?.cancel()
        retentionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.deleteChatsPastRetentionInBackground()
                try? await Task.sleep(nanoseconds: UInt64(ClickyChatRetention.runEverySeconds * 1_000_000_000))
            }
        }
    }

    func stopRetentionSchedule() {
        retentionTask?.cancel()
        retentionTask = nil
    }

    func deleteChatsPastRetentionInBackground(now: Date = Date()) {
        let store = self.store
        storeQueue.async { [weak self] in
            let removedChatIDs = store.deleteChatsPastRetention(now: now)
            guard !removedChatIDs.isEmpty else { return }
            // A count only, never a title or a message.
            print("🗂 Clicky chats: retention removed \(removedChatIDs.count) chat(s)")
            Task { @MainActor [weak self] in
                self?.collection.removeChatsDeletedByRetention(withIDs: removedChatIDs)
            }
        }
    }

    // MARK: - Private

    private func writeInBackground(_ chatToWrite: ClickyChat) {
        let store = self.store
        storeQueue.async {
            if let errorDescription = store.save(chatToWrite) {
                print("⚠️ Clicky chat save failed: \(errorDescription)")
            }
        }
    }
}
