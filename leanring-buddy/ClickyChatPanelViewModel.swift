//
//  ClickyChatPanelViewModel.swift
//  leanring-buddy
//
//  Everything the chat panel's SwiftUI view shows and does, kept apart from `CompanionManager` so
//  the view can be built, previewed and rendered offscreen without the rest of the app. The
//  manager and the panel controller drive it through the closures below and through the methods
//  that start, stream and end a turn.
//

import Combine
import Foundation

/// Which of the panel's three screens is showing.
enum ClickyChatPanelScreen: Equatable {
    /// The text field and the current chat.
    case activeChat
    /// The search field and the chats grouped by project.
    case chatList
    /// An old chat opened to be read, with a button to continue it.
    case readOnlyChat(UUID)
}

@MainActor
final class ClickyChatPanelViewModel: ObservableObject {
    let session: ClickyChatSession

    // MARK: - What the panel shows

    @Published var screen: ClickyChatPanelScreen = .activeChat
    @Published var draftMessageText = ""
    @Published var searchQueryText = ""
    /// The row highlighted in the chat list by the arrow keys.
    @Published private(set) var selectedChatID: UUID?
    /// The chat whose row is asking "delete this chat?" in place. Nil when no row is.
    @Published private(set) var chatIDAwaitingDeleteConfirmation: UUID?

    /// The message being answered right now (typed or spoken) and the reply as far as it has come.
    @Published private(set) var pendingUserMessageText: String?
    @Published private(set) var pendingInputMode: ClickyTurnInputMode = .typed
    @Published private(set) var streamingReplyText = ""
    /// A short text error for a typed turn that failed ("i can't reach the internet right now.").
    /// Shown below the messages until the next message is sent.
    @Published private(set) var turnErrorText: String?
    /// Identifies the turn the pending message belongs to, so that a turn that was cancelled late
    /// cannot clear the display of the turn that replaced it.
    private(set) var pendingTurnIdentifier: UUID?

    /// What Clicky is doing right now, as the status pill would say it ("thinking", "listening",
    /// "speaking", "dictating"). Nil when idle. The panel shows it inline while it is open, and
    /// the pill is hidden.
    @Published var statusContent: ClickyStatusPillContent?

    /// True under a notch: the panel's top is flat and pure black there. Set by the controller.
    @Published var hangsFromNotch = true

    /// Each increase asks the focused field to take the keyboard.
    @Published private(set) var inputFocusRequestCount = 0

    /// The height the whole panel wants, reported by the view. The controller sizes the window to it.
    @Published private(set) var desiredPanelHeightInPoints: CGFloat = 120

    // MARK: - What the panel can ask for (set by the controller and the manager)

    /// A typed message was sent (Return).
    var sendTypedMessageHandler: ((String) -> Void)?
    /// The panel asked to be closed (the chats screen has no close button; Escape and a click
    /// outside close it, so this is used by the controller's own keys).
    var closePanelHandler: (() -> Void)?
    /// The user picked "new chat": cancel any turn in progress and clear the conversation history.
    var newChatChosenHandler: (() -> Void)?
    /// The user picked "continue" on a chat: load its last exchanges as the conversation history.
    var chatContinuedHandler: ((ClickyChat) -> Void)?

    private var sessionChangeObservation: AnyCancellable?

    init(session: ClickyChatSession) {
        self.session = session
        // The views read the session's chats through this object, so a change of the chats must
        // redraw them.
        sessionChangeObservation = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Reading

    /// The chat the transcript shows: the active chat, or the old chat being read.
    var displayedChat: ClickyChat? {
        switch screen {
        case .activeChat:
            return session.collection.activeChat
        case .readOnlyChat(let chatID):
            return session.collection.chat(withID: chatID)
        case .chatList:
            return nil
        }
    }

    var visibleProjectGroups: [ClickyChatProjectGroup] {
        session.collection.projectGroups(matching: searchQueryText)
    }

    /// The listed chats in the order they appear, for the arrow keys.
    var orderedVisibleChatIDs: [UUID] {
        visibleProjectGroups.flatMap { $0.chats.map(\.id) }
    }

    var isSearching: Bool {
        !searchQueryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isTurnInProgress: Bool {
        pendingTurnIdentifier != nil
    }

    // MARK: - Opening

    /// Called as the panel opens: back to the current chat, with a chat that has been idle for
    /// ten minutes ended (so the panel shows an empty new chat, which is what the next message
    /// would start anyway), and the text field ready to type in.
    func panelWillOpen(now: Date = Date()) {
        // Picks up chat files that appeared since the last read (in the background).
        session.reloadChatsFromDiskInBackground()
        session.endActiveChatIfIdleTooLong(at: now)
        screen = .activeChat
        searchQueryText = ""
        chatIDAwaitingDeleteConfirmation = nil
        requestInputFocus()
    }

    func requestInputFocus() {
        inputFocusRequestCount += 1
    }

    // MARK: - Sending

    func sendDraftMessage() {
        let messageText = draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageText.isEmpty else { return }
        draftMessageText = ""
        sendTypedMessageHandler?(messageText)
    }

    // MARK: - Screens

    func showActiveChat() {
        screen = .activeChat
        chatIDAwaitingDeleteConfirmation = nil
        requestInputFocus()
    }

    func showChatList() {
        screen = .chatList
        chatIDAwaitingDeleteConfirmation = nil
        selectedChatID = ClickyChatListNavigation.selectedChatIDAfterListChanged(
            currentSelectedChatID: selectedChatID,
            orderedChatIDs: orderedVisibleChatIDs
        )
    }

    func toggleChatList() {
        if screen == .chatList {
            showActiveChat()
        } else {
            showChatList()
        }
    }

    func openChatToRead(chatID: UUID) {
        guard session.collection.chat(withID: chatID) != nil else { return }
        chatIDAwaitingDeleteConfirmation = nil
        screen = .readOnlyChat(chatID)
    }

    /// Makes the chat the active one, so a follow-up has its context, and goes to it.
    func continueChat(chatID: UUID) {
        guard let chatToContinue = session.continueChat(withID: chatID) else { return }
        chatContinuedHandler?(chatToContinue)
        clearPendingExchangeDisplay()
        turnErrorText = nil
        screen = .activeChat
        chatIDAwaitingDeleteConfirmation = nil
        requestInputFocus()
    }

    func startNewChat() {
        session.startNewChatByUser()
        newChatChosenHandler?()
        clearPendingExchangeDisplay()
        turnErrorText = nil
        screen = .activeChat
        chatIDAwaitingDeleteConfirmation = nil
        requestInputFocus()
    }

    // MARK: - Keep and delete

    func toggleKept(chatID: UUID) {
        session.toggleKept(chatID: chatID)
    }

    /// The first click on delete: the row asks "delete this chat?" in place. Nothing is deleted yet.
    func askToConfirmDeleting(chatID: UUID) {
        chatIDAwaitingDeleteConfirmation = chatID
    }

    func cancelDeleteConfirmation() {
        chatIDAwaitingDeleteConfirmation = nil
    }

    /// The second click, on the confirmation: the chat and its file are deleted. If it was being
    /// read, the panel goes back to the list.
    func confirmDeleting(chatID: UUID) {
        guard chatIDAwaitingDeleteConfirmation == chatID else { return }
        chatIDAwaitingDeleteConfirmation = nil
        let orderedChatIDsBeforeDeleting = orderedVisibleChatIDs
        session.delete(chatID: chatID)
        if case .readOnlyChat(let readChatID) = screen, readChatID == chatID {
            screen = .chatList
        }
        // The highlight moves to the row that took the deleted row's place.
        if selectedChatID == chatID, let deletedIndex = orderedChatIDsBeforeDeleting.firstIndex(of: chatID) {
            let remainingChatIDs = orderedVisibleChatIDs
            selectedChatID = remainingChatIDs.isEmpty ? nil : remainingChatIDs[min(deletedIndex, remainingChatIDs.count - 1)]
        }
    }

    // MARK: - Arrow keys in the list

    func moveSelection(_ direction: ClickyChatListNavigation.Direction) {
        selectedChatID = ClickyChatListNavigation.selectedChatID(
            afterMoving: direction,
            from: selectedChatID,
            orderedChatIDs: orderedVisibleChatIDs
        )
        chatIDAwaitingDeleteConfirmation = nil
    }

    func openSelectedChatToRead() {
        guard let selectedChatID else { return }
        openChatToRead(chatID: selectedChatID)
    }

    /// Called when the list changes under the highlight (a search was typed, a chat was deleted).
    func reconcileSelectionWithVisibleChats() {
        selectedChatID = ClickyChatListNavigation.selectedChatIDAfterListChanged(
            currentSelectedChatID: selectedChatID,
            orderedChatIDs: orderedVisibleChatIDs
        )
    }

    // MARK: - A turn in progress

    /// A message was sent (typed, or spoken while the panel is open): show it at once, before the
    /// reply, in the chat the panel is showing.
    func beginPendingExchange(turnIdentifier: UUID, userText: String, inputMode: ClickyTurnInputMode) {
        pendingTurnIdentifier = turnIdentifier
        pendingUserMessageText = userText
        pendingInputMode = inputMode
        streamingReplyText = ""
        turnErrorText = nil
        // A typed message is sent from the current chat's own field, so the panel is showing that
        // chat. A spoken one can arrive while the user is browsing the list or reading an old
        // chat; it is not allowed to pull the panel away from that, and shows in the current chat
        // when the user goes back to it.
        if inputMode == .typed && screen != .activeChat {
            screen = .activeChat
        }
    }

    /// The reply so far, with its tags already removed. A turn that has been replaced is ignored.
    func updateStreamingReply(_ replyTextSoFar: String, turnIdentifier: UUID) {
        guard pendingTurnIdentifier == turnIdentifier else { return }
        streamingReplyText = replyTextSoFar
    }

    /// The turn finished and its exchange is now in the chat, so the pending message goes away.
    func finishPendingExchange(turnIdentifier: UUID) {
        guard pendingTurnIdentifier == turnIdentifier else { return }
        clearPendingExchangeDisplay()
    }

    /// The turn failed: the message stays visible and the error is shown under it.
    func failPendingExchange(turnIdentifier: UUID, errorText: String) {
        guard pendingTurnIdentifier == turnIdentifier else { return }
        turnErrorText = errorText
        pendingTurnIdentifier = nil
        streamingReplyText = ""
    }

    /// The turn was cancelled (Escape, a newer message, the ask keys): its pending message goes.
    func cancelPendingExchange(turnIdentifier: UUID) {
        guard pendingTurnIdentifier == turnIdentifier else { return }
        clearPendingExchangeDisplay()
    }

    private func clearPendingExchangeDisplay() {
        pendingTurnIdentifier = nil
        pendingUserMessageText = nil
        streamingReplyText = ""
    }

    // MARK: - Size

    func updateDesiredPanelHeight(_ desiredHeightInPoints: CGFloat) {
        guard desiredHeightInPoints.isFinite, abs(desiredHeightInPoints - desiredPanelHeightInPoints) >= 0.5 else { return }
        desiredPanelHeightInPoints = desiredHeightInPoints
    }
}
