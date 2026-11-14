//
//  ClickyFileEditingController.swift
//  leanring-buddy
//
//  The app's side of file editing (round 17): what is waiting for the user's answer, what was just
//  applied and can be undone, and what happens when the user answers. The decisions live in
//  ClickyCore (`ClickyFileChangeLedger`, `ClickyChangeApplier`, `ClickyUnsavedDocumentGuard`,
//  `ClickyChangeAnswer`); this controller connects them to the chat panel's change card and runs the
//  disk work off the main thread.
//
//  Nothing here touches a file before the user has answered. A turn only hands over the changes the
//  model proposed (`presentProposedChanges`); a file is written by `applyPendingChanges`, after
//  return or a spoken or typed yes.
//
//  Since round 18 (Jarvis actions) the waiting set can also hold a shortcut to run and links that are
//  not plain links to well-known sites. They wait on the same card, are confirmed by the same
//  answers, and run (through the action executor) only after the file changes were written, and only
//  if those were. A created reminder can be undone next to the last applied file set.
//

import AppKit

@MainActor
final class ClickyFileEditingController {
    private(set) var ledger = ClickyFileChangeLedger()

    private let chatPanelViewModel: ClickyChatPanelViewModel
    private let chatPanelController: ClickyChatPanelController
    private let backupsRootDirectoryURL: URL
    /// What runs a confirmed shortcut or link, and removes a reminder on "undo that".
    private let actionExecutor: ClickyActionExecutor

    private var expiryTask: Task<Void, Never>?
    private var isApplying = false

    /// What the actions of the set that was applied last did (round 18), for the history line of
    /// that answer. Read by the caller right after `applyPendingChanges` returns.
    private(set) var lastApplyActionResults: [ClickyActionRunResult] = []

    init(
        chatPanelViewModel: ClickyChatPanelViewModel,
        chatPanelController: ClickyChatPanelController,
        actionExecutor: ClickyActionExecutor,
        backupsRootDirectoryURL: URL = ClickyChangeApplier.defaultBackupsRootDirectoryURL()
    ) {
        self.chatPanelViewModel = chatPanelViewModel
        self.chatPanelController = chatPanelController
        self.actionExecutor = actionExecutor
        self.backupsRootDirectoryURL = backupsRootDirectoryURL
    }

    // MARK: - Launch

    /// Removes backups older than 30 days, and the oldest beyond 200 MB, off the main thread.
    func pruneOldBackupsInBackground() {
        let backupsRootDirectoryURL = backupsRootDirectoryURL
        Task.detached(priority: .utility) {
            let pruneResult = ClickyChangeApplier.pruneBackups(in: backupsRootDirectoryURL, now: Date())
            // Numbers only, never a path.
            print("🗂 backups pruned: removed \(pruneResult.removedFolderCount) folder(s), \(pruneResult.remainingByteCount) bytes left")
        }
    }

    // MARK: - Words that answer a change

    /// What the user's words mean to the changes right now (see `ClickyFileChangeLedger.decision`).
    /// Asking can move a set that waited too long to "expired", which is why it is not a pure read.
    func decision(forTranscript transcript: String) -> ClickyChangeVoiceDecision {
        ledger.decision(forTranscript: transcript, at: Date())
    }

    /// The file changes waiting now, for the history line of the answer.
    var pendingChanges: [ClickyFileChange] {
        ledger.currentPendingChangeSet(at: Date())?.changes ?? []
    }

    /// The links and shortcuts waiting now (round 18).
    var pendingActions: [ClickyPendingAction] {
        ledger.currentPendingChangeSet(at: Date())?.actions ?? []
    }

    /// One line per thing that waits, for the "waiting for the user's answer now" part of the prompt.
    var pendingDescriptions: [String] {
        guard let changeSet = ledger.currentPendingChangeSet(at: Date()) else { return [] }
        return ClickyPendingSetHistoryText.waitingDescriptions(changes: changeSet.changes, actions: changeSet.actions)
    }

    // MARK: - A turn proposed changes

    var hasPendingChangeSet: Bool {
        ledger.currentPendingChangeSet(at: Date()) != nil
    }

    /// The turn's proposals become the pending set (a new one replaces any that was waiting), the
    /// card shows them, and the panel comes up with the keyboard so return and escape reach the card.
    /// A set may hold file changes, links and shortcuts to confirm, or both.
    func presentProposedChanges(_ changes: [ClickyFileChange], actions: [ClickyPendingAction] = []) {
        guard let changeSet = ledger.queue(changes, actions: actions, at: Date()) else { return }
        chatPanelViewModel.showPendingChangeCard(
            setIdentifier: changeSet.identifier,
            content: ClickyChangeCardContent.make(for: changeSet.changes, actions: changeSet.actions)
        )
        chatPanelController.openTakingKeyboardForPendingChange()
        scheduleExpiry(of: changeSet)
    }

    /// The reminders a turn created, kept so "undo that" can remove them for 30 minutes.
    func recordCreatedReminders(_ reminderIdentifiers: [String]) {
        ledger.recordCreatedReminders(reminderIdentifiers, at: Date())
    }

    private func scheduleExpiry(of changeSet: ClickyPendingChangeSet) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((ClickyFileEditingLimits.pendingChangeLifetimeSeconds + 0.5) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Asking the ledger is what moves an old set to "expired".
            guard self.ledger.currentPendingChangeSet(at: Date()) == nil,
                  self.chatPanelViewModel.changeCard?.setIdentifier == changeSet.identifier,
                  self.chatPanelViewModel.changeCard?.phase == .awaitingAnswer else {
                return
            }
            self.chatPanelViewModel.showChangeCardNotice(ClickyChangeAnswer.expired.sentence)
        }
    }

    // MARK: - Escape and ordinary turns

    /// An ordinary turn started: from now on a spoken or typed yes or no no longer answers the
    /// change that waits (see `ClickyFileChangeLedger.anOrdinaryTurnStartedSinceTheProposal`).
    func noteAnOrdinaryTurnStarted() {
        ledger.noteAnOrdinaryTurnStarted()
        chatPanelViewModel.showChangeCardNoLongerAcceptsSpokenAnswer()
    }

    /// Escape with nothing running: a waiting change is cancelled ("okay, i left it." in the
    /// panel, not spoken) and Escape is used up. False when nothing was waiting.
    func cancelPendingChangesBecauseEscapeWasPressed() -> Bool {
        discardPendingChanges() != nil
    }

    /// A folder was removed from the list: the file changes that wait inside it are dropped with it,
    /// so they can not be applied after the permission is gone. A link or a shortcut that waits in
    /// the same set has no folder and stays; a set left with nothing in it is dropped. Returns true
    /// when the whole set is gone.
    @discardableResult
    func discardPendingChanges(insideFolderPath folderPath: String) -> Bool {
        guard !isApplying, let changeSet = ledger.currentPendingChangeSet(at: Date()),
              changeSet.changes.contains(where: { $0.allowedFolderURL.path == folderPath }) else {
            return false
        }
        let theWholeSetIsGone = ledger.removeChanges(insideFolderPath: folderPath)
        if theWholeSetIsGone {
            expiryTask?.cancel()
            chatPanelViewModel.showChangeCardLeftAlone()
        } else if let reducedSet = ledger.currentPendingChangeSet(at: Date()) {
            chatPanelViewModel.refreshPendingChangeCard(
                content: ClickyChangeCardContent.make(for: reducedSet.changes, actions: reducedSet.actions)
            )
        }
        return theWholeSetIsGone
    }

    /// Actions were switched off in settings: a waiting link or shortcut is dropped, and the file
    /// changes of the same set stay. Returns true when the whole set is gone because of it.
    @discardableResult
    func discardPendingActionsBecauseActionsWereSwitchedOff() -> Bool {
        guard !isApplying, let changeSet = ledger.currentPendingChangeSet(at: Date()), !changeSet.actions.isEmpty else {
            return false
        }
        let theWholeSetIsGone = ledger.removeActions()
        if theWholeSetIsGone {
            expiryTask?.cancel()
            chatPanelViewModel.showChangeCardLeftAlone()
        } else if let reducedSet = ledger.currentPendingChangeSet(at: Date()) {
            chatPanelViewModel.refreshPendingChangeCard(
                content: ClickyChangeCardContent.make(for: reducedSet.changes, actions: reducedSet.actions)
            )
        }
        return theWholeSetIsGone
    }

    // MARK: - The user's answer

    /// No: the waiting change is dropped, and the card says "okay, i left it.". nil when none waited.
    func discardPendingChanges() -> ClickyChangeAnswer? {
        guard !isApplying, ledger.discardPendingChangeSet() != nil else {
            return nil
        }
        expiryTask?.cancel()
        chatPanelViewModel.showChangeCardLeftAlone()
        return .discarded
    }

    /// A late "yes": the change expired, so nothing is applied, and the card says so.
    func answerThatTheChangeExpired() -> ClickyChangeAnswer {
        _ = ledger.takeExpiredChangeSet()
        chatPanelViewModel.showChangeCardNotice(ClickyChangeAnswer.expired.sentence)
        return .expired
    }

    /// Yes (return, or the spoken or typed word): back up, write, and say what happened. The disk
    /// work and the Accessibility read for unsaved edits run off the main thread.
    func applyPendingChanges() async -> ClickyChangeAnswer? {
        guard !isApplying else { return nil }
        guard let changeSet = ledger.currentPendingChangeSet(at: Date()) else {
            return ledger.takeExpiredChangeSet() != nil ? answerThatTheChangeExpired() : nil
        }
        isApplying = true
        defer { isApplying = false }
        chatPanelViewModel.showChangeCardApplying()

        enum ApplyResult {
            case unsavedEdits
            case outcome(ClickySetApplyOutcome)
        }
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let backupsRootDirectoryURL = backupsRootDirectoryURL
        let actionExecutor = actionExecutor
        let applyResult: ApplyResult = await Task.detached(priority: .userInitiated) {
            // Read fresh now, not when the change was proposed: the user may have typed since. A set
            // of only actions has no file that could hold unsaved edits.
            if !changeSet.changes.isEmpty {
                let frontmostDocumentAndTitle = ClickyChatProjectContextReader.readFrontmostDocumentPathAndWindowTitle(processIdentifier: frontmostProcessIdentifier)
                if ClickyUnsavedDocumentGuard.blocksApplying(
                    changes: changeSet.changes,
                    frontmostDocumentPath: frontmostDocumentAndTitle.documentPath,
                    frontmostWindowTitle: frontmostDocumentAndTitle.windowTitle
                ) {
                    return .unsavedEdits
                }
            }
            return .outcome(await ClickySetApplier.apply(
                changeSet: changeSet,
                backupsRootDirectoryURL: backupsRootDirectoryURL,
                executor: actionExecutor,
                now: Date()
            ))
        }.value

        lastApplyActionResults = []
        switch applyResult {
        case .unsavedEdits:
            // The change stays pending: a second yes after saving the file applies it.
            chatPanelViewModel.showChangeCardStillWaiting(lineText: ClickyChangeAnswer.refusedBecauseOfUnsavedEdits.sentence)
            return .refusedBecauseOfUnsavedEdits
        case .outcome(.applied(let fileRecord, let actionResults)):
            lastApplyActionResults = actionResults
            // A shortcut that ran cannot be taken back, so a later "undo that" says so.
            let aShortcutRan = actionResults.contains { $0.action.isShortcut && $0.succeeded }
            if var fileRecord {
                fileRecord.heldAShortcutThatCannotBeUndone = aShortcutRan
                ledger.recordApplied(fileRecord)
            } else {
                ledger.recordAppliedActionsOnly(heldAShortcut: aShortcutRan, at: Date())
            }
            expiryTask?.cancel()
            chatPanelViewModel.showChangeCardApplied(actionResultLines: actionResults.map(\.lineText))
            let failedActionResults = actionResults.filter { !$0.succeeded }
            if failedActionResults.isEmpty {
                return .applied
            }
            // "done." is only said when nothing failed. The words say which part did not work, and
            // that the file changes (if there were any) went through.
            let failureSentences = failedActionResults.map { $0.action.isShortcut ? ClickyPendingActionRunner.shortcutFailedSentence : ClickyPendingActionRunner.linkFailedSentence }
            let sentence = (fileRecord != nil ? "the file changes are done. " : "") + failureSentences.joined(separator: " ")
            return .appliedButAnActionFailed(sentence: sentence)
        case .outcome(.refusedBecauseFileChanged):
            // The set is out of date for good: it is dropped, and the model has to propose again.
            ledger.discardPendingChangeSet()
            expiryTask?.cancel()
            chatPanelViewModel.showChangeCardNotice(ClickyChangeAnswer.refusedBecauseFileChanged.sentence)
            return .refusedBecauseFileChanged
        case .outcome(.failed(let failureReason)):
            // Whatever was written has been put back. The set stays pending so the user can try again.
            print("⚠️ Clicky could not apply a change: \(failureReason)")
            chatPanelViewModel.showChangeCardStillWaiting(lineText: ClickyChangeAnswer.failedToApply.sentence)
            return .failedToApply
        }
    }

    /// "undo that" (or the undo button): put back the newest thing that can be undone, if it is
    /// within 30 minutes: the last applied file set (when nothing changed the files since) or the
    /// reminders the last turn created. A shortcut or a link that was confirmed cannot be undone.
    func undoLastAppliedChanges() async -> ClickyChangeAnswer {
        let now = Date()
        guard let undoTarget = ledger.newestUndoTarget(at: now) else {
            let somethingWasRecorded = ledger.lastAppliedRecord != nil || ledger.lastCreatedRemindersRecord != nil
            return somethingWasRecorded ? .undoExpired : .nothingToUndo
        }

        switch undoTarget {
        case .actionThatCannotBeUndone:
            // Said once; the next "undo that" goes on to the older thing.
            let theSetRanAShortcut = ledger.lastActionOnlyApplication?.heldAShortcut ?? false
            ledger.clearActionOnlyApplicationRecord()
            return theSetRanAShortcut ? .actionCannotBeUndone : .openedLinkCannotBeUndone

        case .reminders:
            guard let remindersRecord = ledger.undoableRemindersRecord(at: now) else { return .undoExpired }
            var everyReminderWasRemoved = true
            for reminderIdentifier in remindersRecord.reminderIdentifiers {
                if !(await actionExecutor.removeReminder(withIdentifier: reminderIdentifier)) {
                    everyReminderWasRemoved = false
                }
            }
            guard everyReminderWasRemoved else {
                print("⚠️ Clicky could not remove a reminder it had added")
                return .undoFailed
            }
            ledger.clearReminderUndoRecord()
            return .undone

        case .files:
            guard let appliedRecord = ledger.undoableRecord(at: now) else {
                return ledger.lastAppliedRecord == nil ? .nothingToUndo : .undoExpired
            }
            let undoOutcome = await Task.detached(priority: .userInitiated) {
                ClickyChangeApplier.undo(record: appliedRecord, now: now)
            }.value

            let cardIsForThisSet = chatPanelViewModel.changeCard?.setIdentifier == appliedRecord.setIdentifier
            switch undoOutcome {
            case .undone:
                ledger.clearUndoRecord()
                if cardIsForThisSet { chatPanelViewModel.showChangeCardUndone() }
                // The files are back; a shortcut the same set ran stays done.
                return appliedRecord.heldAShortcutThatCannotBeUndone ? .undoneButTheShortcutCannotBe : .undone
            case .expired:
                return .undoExpired
            case .refusedBecauseFileChanged:
                if cardIsForThisSet { chatPanelViewModel.showChangeCardNotice(ClickyChangeAnswer.undoRefusedBecauseFileChanged.sentence) }
                return .undoRefusedBecauseFileChanged
            case .failed(let failureReason):
                print("⚠️ Clicky could not undo a change: \(failureReason)")
                return .undoFailed
            }
        }
    }
}

// MARK: - What one turn needs

/// What a turn with file editing on needs, prepared off the main thread while the screenshot is
/// taken: the session that runs the tools (and keeps the changes proposed), the folders as the
/// prompt lists them, and the open document when it lies inside one of those folders.
nonisolated struct ClickyPreparedFileEditing: @unchecked Sendable {
    let toolSession: ClickyFileToolTurnSession
    /// The same policy the file tools use, so `open_file` (round 18) opens only what they may read.
    let pathPolicy: ClickyFilePathPolicy
    let editableFolders: [ClickyEditableFolderDescription]
    let frontmostDocument: ClickyFrontmostDocumentDescription?

    /// Reads the frontmost window's document through Accessibility (0.25 s timeout) and builds the
    /// path policy. Blocks briefly, so it runs off the main thread.
    nonisolated static func prepare(editableFolderPaths: [String], frontmostProcessIdentifier: Int32?) -> ClickyPreparedFileEditing {
        let frontmostDocumentPath = ClickyChatProjectContextReader.readFrontmostDocumentPathAndWindowTitle(
            processIdentifier: frontmostProcessIdentifier
        ).documentPath
        let pathPolicy = ClickyFilePathPolicy(
            allowedFolderPaths: editableFolderPaths,
            homeDirectoryPath: NSHomeDirectory(),
            frontmostDocumentPath: frontmostDocumentPath
        )
        return ClickyPreparedFileEditing(
            toolSession: ClickyFileToolTurnSession(policy: pathPolicy),
            pathPolicy: pathPolicy,
            editableFolders: pathPolicy.allowedFolderURLs.map { allowedFolderURL in
                ClickyEditableFolderDescription(
                    name: ClickyEditableFolders.displayName(forFolderPath: allowedFolderURL.path),
                    path: allowedFolderURL.path
                )
            },
            frontmostDocument: ClickyFileEditingPromptSection.frontmostDocumentDescription(documentPath: frontmostDocumentPath, policy: pathPolicy)
        )
    }
}

/// What a turn's tools need (round 18): the file tools when a folder is set, the action tools while
/// actions are on, and the one session that runs the calls of both. nil when both are off, and the
/// turn is then the plain request it always was.
nonisolated struct ClickyPreparedTurnTools: @unchecked Sendable {
    let toolSession: ClickyTurnToolSession
    /// The file editing part (folders, open document, file tools), nil with no folder set.
    let fileEditing: ClickyPreparedFileEditing?
    /// The action part, nil while actions are off.
    let actionSession: ClickyActionToolTurnSession?

    /// Builds what the turn needs, off the main thread: with a folder set the open document is read
    /// (Accessibility, 0.25 s timeout); with only actions nothing is read at all.
    nonisolated static func prepare(
        editableFolderPaths: [String],
        actionsAreEnabled: Bool,
        actionExecutor: ClickyActionExecutor,
        frontmostProcessIdentifier: Int32?
    ) -> ClickyPreparedTurnTools? {
        guard !editableFolderPaths.isEmpty || actionsAreEnabled else {
            return nil
        }
        let fileEditing = editableFolderPaths.isEmpty
            ? nil
            : ClickyPreparedFileEditing.prepare(editableFolderPaths: editableFolderPaths, frontmostProcessIdentifier: frontmostProcessIdentifier)
        let actionSession = actionsAreEnabled
            ? ClickyActionToolTurnSession(executor: actionExecutor, pathPolicy: fileEditing?.pathPolicy)
            : nil
        return ClickyPreparedTurnTools(
            toolSession: ClickyTurnToolSession(fileSession: fileEditing?.toolSession, actionSession: actionSession),
            fileEditing: fileEditing,
            actionSession: actionSession
        )
    }
}

/// Set by the tool loop's progress callback (which cannot change a local variable) when the model
/// starts a tool call, so the rest of the turn knows a tool was used and that the early speech
/// fetch must not run. Never reset within a turn.
final class ClickyToolUseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHasUsedATool = false
    private var storedLatestRequestText = ""

    var hasUsedATool: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedHasUsedATool
    }

    func markToolUsed() {
        lock.lock(); storedHasUsedATool = true; lock.unlock()
    }

    /// The text of the request that is streaming now, so that when a tool call starts it can be shown as a working note.
    var latestRequestText: String {
        get { lock.lock(); defer { lock.unlock() }; return storedLatestRequestText }
        set { lock.lock(); storedLatestRequestText = newValue; lock.unlock() }
    }
}
