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

/// Which of the panel's screens is showing. Five tabs: the chat tab shows `activeChat`, the chats
/// tab shows `chatList` (and `readOnlyChat` when one is opened), and memory, usage and settings
/// each have a screen of their own.
enum ClickyChatPanelScreen: Equatable {
    /// The text field and the current chat.
    case activeChat
    /// The search field and the chats grouped by project.
    case chatList
    /// An old chat opened to be read, with a button to continue it.
    case readOnlyChat(UUID)
    /// The profile facts and the notes, each with a delete.
    case memory
    /// Questions, speed, tokens and estimated cost from the local metrics logs.
    case usage
    /// The settings, the voice options, the shortcuts and the permissions.
    case settings

    /// False for the three tabs with nothing under the tab bar, which then need less room below it.
    var hasRowUnderTabBar: Bool {
        switch self {
        case .activeChat, .chatList, .readOnlyChat: return true
        case .memory, .usage, .settings: return false
        }
    }
}

/// What the change card of the chat tab shows (round 17, file editing).
struct ClickyChangeCardState: Equatable {
    enum Phase: Equatable {
        /// Waiting for return (apply) or escape (cancel), or a spoken yes or no.
        case awaitingAnswer
        /// Writing the files (a moment).
        case applying
        /// Applied; the card offers undo for 30 minutes.
        case applied
        /// Cancelled: "okay, i left it."
        case leftAlone
        case undone
        /// Something that is not an answer to the change (it expired). Shows the sentence alone.
        case notice
    }

    let setIdentifier: UUID
    let content: ClickyChangeCardContent
    var phase: Phase
    /// A line under the title: why the change has not been applied yet ("save the file first, then
    /// say yes again."), or the sentence of a notice.
    var lineText: String?
    /// False once another ordinary turn has started: a spoken or typed yes or no then goes to the
    /// model (see `ClickyFileChangeLedger`), so the card stops offering it. Return and the buttons stay.
    var acceptsSpokenAnswer = true
}

/// One folder of the settings tab's "files" section.
struct ClickyEditableFolderRow: Equatable, Identifiable {
    let path: String
    let name: String
    /// The path with the home folder written as "~".
    let shortenedPath: String

    var id: String { path }
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
    /// A progress note of the model while it works with files (round 17), shown small and grey. Not
    /// the reply: it is never spoken and never saved in the chat.
    @Published private(set) var workingNoteText: String?
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

    // MARK: - The memory, usage and settings tabs (round 15)

    /// The folders the memory and usage tabs read. The user's real ones, except in a self test
    /// (see `ClickyPanelDataLocations.forRun`). Set by the manager before the panel opens.
    var panelDataLocations = ClickyPanelDataLocations.real

    /// What the memory tab lists. Nil until the first read has come back.
    @Published private(set) var memoryContents: ClickyMemoryPanelContents?
    /// The row (a profile fact or a note) that is asking "delete this?" in place. Nil when none is.
    @Published private(set) var memoryRowAwaitingDeleteConfirmation: String?
    /// A short line under the list when a delete could not be done.
    @Published private(set) var memoryErrorText: String?
    /// Counts every read and removal, so a slow read that was started earlier cannot put back a row
    /// that has been deleted since.
    private var memoryLoadGeneration = 0

    /// What the usage tab shows. Nil until the first read has come back.
    @Published private(set) var usageSummary: ClickyUsageSummary?
    private var usageLoadGeneration = 0

    /// The settings as the settings tab shows them. The manager keeps this in step with its own
    /// state (the same state the menu bar panel's switches change), in both directions.
    @Published private(set) var panelSettings = ClickyPanelSettingsSnapshot.defaults
    @Published private(set) var permissionStatuses: [ClickyPermissionStatus] = []

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
    /// The user changed a setting. The manager stores it exactly as the menu bar panel's switches do.
    var panelSettingChangedHandler: ((ClickyPanelSettingChange) -> Void)?
    /// The user pressed "open settings" on a permission.
    var openPermissionSettingsHandler: ((ClickyPermissionKind) -> Void)?
    /// The user pressed "open notes folder". Given the folder the memory tab reads.
    var openNotesFolderHandler: ((URL) -> Void)?

    // MARK: - File editing (round 17)

    /// The change waiting for the user's answer (or its result), shown under the messages of the chat tab.
    @Published private(set) var changeCard: ClickyChangeCardState?
    /// The folders Clicky may edit, for the settings tab's "files" section. Mirrored from the app.
    @Published private(set) var editableFolderRows: [ClickyEditableFolderRow] = []
    /// Why a folder was not added ("your whole home folder is too much..."). Cleared on the next try.
    @Published private(set) var editableFolderMessage: String?
    /// The folder row that is asking "remove this?" in place. Nil when none is.
    @Published private(set) var editableFolderAwaitingRemovalConfirmation: String?

    /// Return on the card, or "apply" on it: write the pending change.
    var applyPendingChangeHandler: (() -> Void)?
    /// Escape on the card, or "cancel" on it.
    var cancelPendingChangeHandler: (() -> Void)?
    var undoAppliedChangeHandler: (() -> Void)?
    /// "add folder…": the manager opens the folder picker.
    var addEditableFolderHandler: (() -> Void)?
    var removeEditableFolderHandler: ((String) -> Void)?

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
        case .chatList, .memory, .usage, .settings:
            return nil
        }
    }

    /// The tab that is lit in the header.
    var selectedTab: ClickyChatPanelTab {
        switch screen {
        case .activeChat: return .chat
        case .chatList, .readOnlyChat: return .chats
        case .memory: return .memory
        case .usage: return .usage
        case .settings: return .settings
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
    ///
    /// `requestsKeyboardFocus` is false when the panel opens only to show a reply that is not
    /// spoken (it is shown without taking the keyboard from the app the user is in).
    func panelWillOpen(now: Date = Date(), requestsKeyboardFocus: Bool = true) {
        // Picks up chat files that appeared since the last read (in the background).
        session.reloadChatsFromDiskInBackground()
        session.endActiveChatIfIdleTooLong(at: now)
        screen = .activeChat
        searchQueryText = ""
        chatIDAwaitingDeleteConfirmation = nil
        memoryRowAwaitingDeleteConfirmation = nil
        folderRemovalConfirmationDidEnd()
        // A change waiting for an answer takes the keyboard (return and escape act on the card),
        // so the text field must not.
        if requestsKeyboardFocus && !isChangeCardAwaitingAnswer {
            requestInputFocus()
        }
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
        leaveChatScreens()
        if !isChangeCardAwaitingAnswer {
            requestInputFocus()
        }
    }

    func showChatList() {
        screen = .chatList
        leaveChatScreens()
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

    /// A click on a tab of the header.
    func selectTab(_ tab: ClickyChatPanelTab) {
        switch tab {
        case .chat: showActiveChat()
        case .chats: showChatList()
        case .memory: showMemory()
        case .usage: showUsage()
        case .settings: showSettings()
        }
    }

    func showSettings() {
        leaveChatScreens()
        screen = .settings
    }

    /// What every screen of the chat tabs holds that must not survive a move to another tab.
    private func leaveChatScreens() {
        chatIDAwaitingDeleteConfirmation = nil
        memoryRowAwaitingDeleteConfirmation = nil
        folderRemovalConfirmationDidEnd()
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
    ///
    /// `replyIsOnlyShownAsText` is true for a voice turn whose reply is not spoken ("speak replies"
    /// is off): the panel is then the only place the reply appears, so it comes to the chat tab
    /// even if the user was on another one.
    func beginPendingExchange(
        turnIdentifier: UUID,
        userText: String,
        inputMode: ClickyTurnInputMode,
        replyIsOnlyShownAsText: Bool = false
    ) {
        pendingTurnIdentifier = turnIdentifier
        pendingUserMessageText = userText
        pendingInputMode = inputMode
        streamingReplyText = ""
        workingNoteText = nil
        turnErrorText = nil
        // A typed message is sent from the current chat's own field, so the panel is showing that
        // chat. A spoken one can arrive while the user is browsing the list, reading an old chat
        // or in the memory, usage or settings tab; it is not allowed to pull the panel away from
        // that, and shows in the current chat when the user goes back to it.
        // A spoken one whose reply is not spoken has no other place to be read, so that one does
        // come to the chat.
        if (inputMode == .typed || replyIsOnlyShownAsText) && screen != .activeChat {
            screen = .activeChat
        }
    }

    /// The reply so far, with its tags already removed. A turn that has been replaced is ignored.
    func updateStreamingReply(_ replyTextSoFar: String, turnIdentifier: UUID) {
        guard pendingTurnIdentifier == turnIdentifier else { return }
        streamingReplyText = replyTextSoFar
        // Words of the real reply have started: the working line has done its job.
        if !replyTextSoFar.isEmpty {
            workingNoteText = nil
        }
    }

    /// The model started a tool call (round 17), so the text it wrote before it was a progress note
    /// ("i'll open your notes file and check."), not the answer. It moves from the reply to a small
    /// grey working line. With no words before the call, the line says what is going on.
    func showWorkingNote(_ progressNoteText: String, turnIdentifier: UUID) {
        guard pendingTurnIdentifier == turnIdentifier else { return }
        streamingReplyText = ""
        let trimmedNoteText = progressNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        workingNoteText = trimmedNoteText.isEmpty ? "looking at your files…" : trimmedNoteText
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
        workingNoteText = nil
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
        workingNoteText = nil
    }

    // MARK: - Memory tab

    /// Opens the memory tab and reads the notes folder. All reading and writing happens on a
    /// background task: the notes folder is in ~/Documents, which is iCloud-backed on this Mac and
    /// has stalled for seconds before.
    func showMemory() {
        leaveChatScreens()
        screen = .memory
        memoryErrorText = nil
        refreshMemoryContentsInBackground()
    }

    /// Reads the folder again. The copy the app already keeps in memory is shown first when there
    /// is one (it never waits for the disk), then the folder is read for real and replaces it.
    func refreshMemoryContentsInBackground() {
        memoryLoadGeneration += 1
        let loadGeneration = memoryLoadGeneration
        let notesDirectoryURL = panelDataLocations.notesDirectoryURL
        let memoriesDirectoryURL = panelDataLocations.memoriesDirectoryURL
        Task.detached(priority: .utility) { [weak self] in
            if let contentsFromCache = ClickyMemoryPanelLoader.contentsFromCacheWithoutReadingDisk(notesDirectoryURL: notesDirectoryURL, memoriesDirectoryURL: memoriesDirectoryURL) {
                await self?.applyLoadedMemoryContents(contentsFromCache, loadGeneration: loadGeneration)
            }
            let contentsFromDisk = ClickyMemoryPanelLoader.contentsAfterRefreshingFromDisk(notesDirectoryURL: notesDirectoryURL, memoriesDirectoryURL: memoriesDirectoryURL)
            await self?.applyLoadedMemoryContents(contentsFromDisk, loadGeneration: loadGeneration)
        }
    }

    private func applyLoadedMemoryContents(_ loadedContents: ClickyMemoryPanelContents, loadGeneration: Int) {
        guard loadGeneration == memoryLoadGeneration else { return }
        memoryContents = loadedContents
    }

    /// The first click on a row's delete: the row asks "delete this?" in place. Nothing is deleted yet.
    func askToConfirmDeletingMemoryRow(rowIdentifier: String) {
        memoryRowAwaitingDeleteConfirmation = rowIdentifier
        memoryErrorText = nil
    }

    func cancelMemoryDeleteConfirmation() {
        memoryRowAwaitingDeleteConfirmation = nil
    }

    /// The second click, on the confirmation: exactly this fact's line is cut out of profile.md.
    func confirmDeletingProfileFact(_ profileFactEntry: ClickyProfileFactEntry) {
        guard memoryRowAwaitingDeleteConfirmation == profileFactEntry.identifier else { return }
        removeMemoryRowInBackground(rowIdentifier: profileFactEntry.identifier) { notesDirectoryURL in
            ClickyMemoryPanelLoader.removeProfileFact(profileFactEntry, notesDirectoryURL: notesDirectoryURL)
        }
    }

    /// The second click, on the confirmation: exactly this note's line is cut out of its daily file.
    func confirmDeletingNote(_ noteEntry: ClickyNoteEntry) {
        guard memoryRowAwaitingDeleteConfirmation == noteEntry.identifier else { return }
        removeMemoryRowInBackground(rowIdentifier: noteEntry.identifier) { notesDirectoryURL in
            ClickyMemoryPanelLoader.removeNote(noteEntry, notesDirectoryURL: notesDirectoryURL)
        }
    }

    /// The second click, on the confirmation: exactly this memory (by its id) is removed from the
    /// memories file. Every other memory stays.
    func confirmDeletingMemory(_ memory: ClickyMemory) {
        guard memoryRowAwaitingDeleteConfirmation == memory.rowIdentifier,
              let memoriesDirectoryURL = panelDataLocations.memoriesDirectoryURL else {
            return
        }
        removeMemoryRowInBackground(rowIdentifier: memory.rowIdentifier) { _ in
            ClickyMemoryPanelLoader.removeMemory(memory, memoriesDirectoryURL: memoriesDirectoryURL)
        }
    }

    /// The row goes from the list at once, the removal and a fresh read run in the background, and
    /// what the disk says then replaces the list (so a delete that could not be done brings the row back).
    private func removeMemoryRowInBackground(
        rowIdentifier: String,
        removal: @escaping @Sendable (URL) -> ClickyMemoryRemovalResult
    ) {
        memoryRowAwaitingDeleteConfirmation = nil
        memoryErrorText = nil
        if let memoryContents {
            self.memoryContents = memoryContents.removingRow(withIdentifier: rowIdentifier)
        }
        memoryLoadGeneration += 1
        let loadGeneration = memoryLoadGeneration
        let notesDirectoryURL = panelDataLocations.notesDirectoryURL
        let memoriesDirectoryURL = panelDataLocations.memoriesDirectoryURL
        Task.detached(priority: .userInitiated) { [weak self] in
            let removalResult = removal(notesDirectoryURL)
            let contentsFromDisk = ClickyMemoryPanelLoader.contentsAfterRefreshingFromDisk(notesDirectoryURL: notesDirectoryURL, memoriesDirectoryURL: memoriesDirectoryURL)
            await self?.finishMemoryRowRemoval(removalResult: removalResult, contentsFromDisk: contentsFromDisk, loadGeneration: loadGeneration)
        }
    }

    private func finishMemoryRowRemoval(
        removalResult: ClickyMemoryRemovalResult,
        contentsFromDisk: ClickyMemoryPanelContents,
        loadGeneration: Int
    ) {
        switch removalResult {
        case .removed:
            break
        case .noMatch, .ambiguous:
            // The file changed since the list was read (or the line is gone). Nothing was written.
            memoryErrorText = "that changed on disk, so nothing was deleted. the list is up to date now."
        case .failed:
            memoryErrorText = "couldn't delete that."
        }
        applyLoadedMemoryContents(contentsFromDisk, loadGeneration: loadGeneration)
    }

    func openNotesFolder() {
        openNotesFolderHandler?(panelDataLocations.notesDirectoryURL)
    }

    // MARK: - Usage tab

    /// Opens the usage tab and reads the two metrics logs on a background task.
    func showUsage() {
        leaveChatScreens()
        screen = .usage
        refreshUsageSummaryInBackground()
    }

    func refreshUsageSummaryInBackground() {
        usageLoadGeneration += 1
        let loadGeneration = usageLoadGeneration
        let metricsDirectoryURL = panelDataLocations.metricsDirectoryURL
        Task.detached(priority: .utility) { [weak self] in
            let loadedSummary = ClickyUsageLogReader.loadSummary(metricsDirectoryURL: metricsDirectoryURL, now: Date())
            await self?.applyLoadedUsageSummary(loadedSummary, loadGeneration: loadGeneration)
        }
    }

    private func applyLoadedUsageSummary(_ loadedSummary: ClickyUsageSummary, loadGeneration: Int) {
        guard loadGeneration == usageLoadGeneration else { return }
        usageSummary = loadedSummary
    }

    // MARK: - Settings tab

    /// A setting was changed in the settings tab. The tab shows the new value at once, and the
    /// manager (through the handler) stores it and applies it, exactly as the menu bar panel does.
    func applyPanelSettingChange(_ change: ClickyPanelSettingChange) {
        panelSettings = panelSettings.applying(change)
        panelSettingChangedHandler?(change)
    }

    /// The manager's own state, mirrored in. Called when it changes anywhere, including in the menu
    /// bar panel, so both places always show the same thing.
    func mirrorPanelSettings(_ settingsOfTheApp: ClickyPanelSettingsSnapshot) {
        guard panelSettings != settingsOfTheApp else { return }
        panelSettings = settingsOfTheApp
    }

    func mirrorPermissionStatuses(_ statusesOfTheApp: [ClickyPermissionStatus]) {
        guard permissionStatuses != statusesOfTheApp else { return }
        permissionStatuses = statusesOfTheApp
    }

    func isPermissionGranted(_ permissionKind: ClickyPermissionKind) -> Bool {
        permissionStatuses.first { $0.kind == permissionKind }?.isGranted ?? false
    }

    func openPermissionSettings(for permissionKind: ClickyPermissionKind) {
        openPermissionSettingsHandler?(permissionKind)
    }

    // MARK: - The change card (round 17)

    var isChangeCardAwaitingAnswer: Bool {
        changeCard?.phase == .awaitingAnswer
    }

    /// When the card last started waiting for an answer, in seconds of system uptime (the clock of
    /// `NSEvent.timestamp`).
    private(set) var changeCardAwaitingSinceUptimeSeconds: TimeInterval = 0
    /// A Return this soon after the card appeared is ignored. The card takes the keyboard from the
    /// app the user was in, so a Return they were already typing there must not apply a change
    /// they have not seen.
    static let returnKeyIgnoredAfterCardAppearsSeconds: TimeInterval = 0.7

    /// A turn queued changes: the card shows the diff and waits for return, escape, a yes or a no.
    func showPendingChangeCard(setIdentifier: UUID, content: ClickyChangeCardContent) {
        changeCardAwaitingSinceUptimeSeconds = ProcessInfo.processInfo.systemUptime
        changeCard = ClickyChangeCardState(setIdentifier: setIdentifier, content: content, phase: .awaitingAnswer, lineText: nil)
        // The card takes the keyboard from the text field; see `ClickyChatPanelController`.
        screen = .activeChat
    }

    func showChangeCardApplying() {
        guard var card = changeCard else { return }
        card.phase = .applying
        card.lineText = nil
        changeCard = card
    }

    /// The change was refused for now but stays pending (unsaved edits): the card says why.
    func showChangeCardStillWaiting(lineText: String) {
        guard var card = changeCard else { return }
        card.phase = .awaitingAnswer
        card.lineText = lineText
        changeCard = card
    }

    func showChangeCardApplied() {
        guard var card = changeCard else { return }
        card.phase = .applied
        card.lineText = ClickyChangeSpokenSentences.applied
        changeCard = card
    }

    func showChangeCardLeftAlone() {
        guard var card = changeCard else { return }
        card.phase = .leftAlone
        card.lineText = ClickyChangeSpokenSentences.discarded
        changeCard = card
    }

    func showChangeCardUndone() {
        guard var card = changeCard else { return }
        card.phase = .undone
        card.lineText = ClickyChangeSpokenSentences.undone
        changeCard = card
    }

    /// An answer that is only words (the change expired, the file changed): the card shrinks to the sentence.
    func showChangeCardNotice(_ noticeText: String) {
        guard var card = changeCard else { return }
        card.phase = .notice
        card.lineText = noticeText
        changeCard = card
    }

    /// Another ordinary turn started while the card waits: it stops offering "or say yes or no".
    func showChangeCardNoLongerAcceptsSpokenAnswer() {
        guard var card = changeCard, card.phase == .awaitingAnswer, card.acceptsSpokenAnswer else { return }
        card.acceptsSpokenAnswer = false
        changeCard = card
    }

    /// The card goes away (a newer change replaced it, or the chat was left).
    func dismissChangeCard() {
        changeCard = nil
    }

    func requestApplyPendingChange() {
        guard isChangeCardAwaitingAnswer else { return }
        applyPendingChangeHandler?()
    }

    /// Return (or keypad Enter) on the card: applies the change unless the key came within
    /// `returnKeyIgnoredAfterCardAppearsSeconds` of the card appearing.
    func requestApplyPendingChangeFromReturnKey(keyPressedAtUptimeSeconds: TimeInterval) {
        let secondsSinceCardAppeared = keyPressedAtUptimeSeconds - changeCardAwaitingSinceUptimeSeconds
        guard secondsSinceCardAppeared >= Self.returnKeyIgnoredAfterCardAppearsSeconds else {
            print("⏎ Clicky: Return ignored, the change card appeared \(Int(secondsSinceCardAppeared * 1000)) ms ago")
            return
        }
        requestApplyPendingChange()
    }

    func requestCancelPendingChange() {
        guard isChangeCardAwaitingAnswer else { return }
        cancelPendingChangeHandler?()
    }

    func requestUndoAppliedChange() {
        guard changeCard?.phase == .applied else { return }
        undoAppliedChangeHandler?()
    }

    // MARK: - The folders Clicky may edit (round 17)

    /// The app's list of folders, mirrored in (it is stored in `UserDefaults` by the manager).
    func mirrorEditableFolderPaths(_ folderPaths: [String], homeDirectoryPath: String) {
        let rows = folderPaths.map { folderPath in
            ClickyEditableFolderRow(
                path: folderPath,
                name: ClickyEditableFolders.displayName(forFolderPath: folderPath),
                shortenedPath: ClickyEditableFolders.shortenedPath(folderPath, homeDirectoryPath: homeDirectoryPath)
            )
        }
        guard rows != editableFolderRows else { return }
        editableFolderRows = rows
        if let editableFolderAwaitingRemovalConfirmation, !rows.contains(where: { $0.path == editableFolderAwaitingRemovalConfirmation }) {
            self.editableFolderAwaitingRemovalConfirmation = nil
        }
    }

    func requestAddingEditableFolder() {
        editableFolderMessage = nil
        addEditableFolderHandler?()
    }

    func showEditableFolderMessage(_ messageText: String?) {
        editableFolderMessage = messageText
    }

    /// The first click on a folder's remove: the row asks "remove this?" in place. Nothing is removed yet.
    func askToConfirmRemovingEditableFolder(path: String) {
        editableFolderAwaitingRemovalConfirmation = path
        editableFolderMessage = nil
    }

    func cancelEditableFolderRemovalConfirmation() {
        editableFolderAwaitingRemovalConfirmation = nil
    }

    /// The second click, on the confirmation.
    func confirmRemovingEditableFolder(path: String) {
        guard editableFolderAwaitingRemovalConfirmation == path else { return }
        editableFolderAwaitingRemovalConfirmation = nil
        removeEditableFolderHandler?(path)
    }

    private func folderRemovalConfirmationDidEnd() {
        editableFolderAwaitingRemovalConfirmation = nil
    }

    // MARK: - Size

    func updateDesiredPanelHeight(_ desiredHeightInPoints: CGFloat) {
        guard desiredHeightInPoints.isFinite, abs(desiredHeightInPoints - desiredPanelHeightInPoints) >= 0.5 else { return }
        desiredPanelHeightInPoints = desiredHeightInPoints
    }
}
