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

import AppKit

@MainActor
final class ClickyFileEditingController {
    private(set) var ledger = ClickyFileChangeLedger()

    private let chatPanelViewModel: ClickyChatPanelViewModel
    private let chatPanelController: ClickyChatPanelController
    private let backupsRootDirectoryURL: URL

    private var expiryTask: Task<Void, Never>?
    private var isApplying = false

    init(
        chatPanelViewModel: ClickyChatPanelViewModel,
        chatPanelController: ClickyChatPanelController,
        backupsRootDirectoryURL: URL = ClickyChangeApplier.defaultBackupsRootDirectoryURL()
    ) {
        self.chatPanelViewModel = chatPanelViewModel
        self.chatPanelController = chatPanelController
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

    /// The changes waiting now, for the history line of the answer.
    var pendingChanges: [ClickyFileChange] {
        ledger.currentPendingChangeSet(at: Date())?.changes ?? []
    }

    // MARK: - A turn proposed changes

    var hasPendingChangeSet: Bool {
        ledger.currentPendingChangeSet(at: Date()) != nil
    }

    /// The turn's proposals become the pending set (a new one replaces any that was waiting), the
    /// card shows them, and the panel comes up with the keyboard so return and escape reach the card.
    func presentProposedChanges(_ changes: [ClickyFileChange]) {
        guard let changeSet = ledger.queue(changes, at: Date()) else { return }
        chatPanelViewModel.showPendingChangeCard(
            setIdentifier: changeSet.identifier,
            content: ClickyChangeCardContent.make(for: changeSet.changes)
        )
        chatPanelController.openTakingKeyboardForPendingChange()
        scheduleExpiry(of: changeSet)
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

    /// A folder was removed from the list: a change that waits inside it is dropped with it.
    func discardPendingChanges(insideFolderPath folderPath: String) {
        guard !isApplying, let changeSet = ledger.currentPendingChangeSet(at: Date()),
              changeSet.changes.contains(where: { $0.allowedFolderURL.path == folderPath }) else {
            return
        }
        _ = discardPendingChanges()
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
            case outcome(ClickyChangeApplyOutcome)
        }
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let backupsRootDirectoryURL = backupsRootDirectoryURL
        let applyResult: ApplyResult = await Task.detached(priority: .userInitiated) {
            // Read fresh now, not when the change was proposed: the user may have typed since.
            let frontmostDocumentAndTitle = ClickyChatProjectContextReader.readFrontmostDocumentPathAndWindowTitle(processIdentifier: frontmostProcessIdentifier)
            if ClickyUnsavedDocumentGuard.blocksApplying(
                changes: changeSet.changes,
                frontmostDocumentPath: frontmostDocumentAndTitle.documentPath,
                frontmostWindowTitle: frontmostDocumentAndTitle.windowTitle
            ) {
                return .unsavedEdits
            }
            return .outcome(ClickyChangeApplier.apply(
                changeSet: changeSet,
                backupsRootDirectoryURL: backupsRootDirectoryURL,
                now: Date()
            ))
        }.value

        switch applyResult {
        case .unsavedEdits:
            // The change stays pending: a second yes after saving the file applies it.
            chatPanelViewModel.showChangeCardStillWaiting(lineText: ClickyChangeAnswer.refusedBecauseOfUnsavedEdits.sentence)
            return .refusedBecauseOfUnsavedEdits
        case .outcome(.applied(let appliedRecord)):
            ledger.recordApplied(appliedRecord)
            expiryTask?.cancel()
            chatPanelViewModel.showChangeCardApplied()
            return .applied
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

    /// "undo that" (or the undo button): put the last applied set back, if it is within 30 minutes
    /// and nothing changed the files since.
    func undoLastAppliedChanges() async -> ClickyChangeAnswer {
        let now = Date()
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
            return .undone
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

// MARK: - What one turn needs

/// What a turn with file editing on needs, prepared off the main thread while the screenshot is
/// taken: the session that runs the tools (and keeps the changes proposed), the folders as the
/// prompt lists them, and the open document when it lies inside one of those folders.
struct ClickyPreparedFileEditing: @unchecked Sendable {
    let toolSession: ClickyFileToolTurnSession
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
