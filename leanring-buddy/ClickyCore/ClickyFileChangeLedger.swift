import Foundation

// Round 17 (file editing): what is waiting for the user's answer and what can still be undone.
// A pure value with an injected clock, so every expiry rule can be checked with explicit times.

nonisolated struct ClickyFileChangeLedger {
    /// The changes the last proposing turn queued, until they are applied, discarded, replaced or
    /// have waited ten minutes.
    private(set) var pendingChangeSet: ClickyPendingChangeSet?
    /// A set that waited too long, kept so a late "yes" can be answered honestly ("that change
    /// expired") instead of being sent to the model as an ordinary turn.
    private(set) var expiredChangeSet: ClickyPendingChangeSet?
    /// The last applied set, which "undo" brings back for 30 minutes.
    private(set) var lastAppliedRecord: ClickyAppliedChangeRecord?
    /// True once an ordinary turn (one that goes to the model) has started since the waiting set was
    /// proposed. A spoken or typed yes or no then no longer answers that set: it could be the answer
    /// to something else Clicky asked in between. Return and the card's buttons still answer it.
    private(set) var anOrdinaryTurnStartedSinceTheProposal = false
    /// Round 18: the reminders the last turn that created any added, which "undo that" removes for
    /// 30 minutes. It sits next to `lastAppliedRecord`, not inside it: they are separate things the
    /// user may undo, and "undo that" takes whichever is newer.
    private(set) var lastCreatedRemindersRecord: ClickyCreatedRemindersRecord?
    /// Round 18: the last confirmed set that held only actions (no file changes), so "undo that" right
    /// after it can say honestly that a shortcut cannot be undone instead of "there's nothing to undo".
    private(set) var lastActionOnlyApplication: ClickyActionOnlyApplicationRecord?

    init() {}

    /// A new proposal replaces the one that was waiting. A set may hold file changes, actions, or both.
    mutating func queue(_ changes: [ClickyFileChange], actions: [ClickyPendingAction] = [], at moment: Date) -> ClickyPendingChangeSet? {
        guard !changes.isEmpty || !actions.isEmpty else {
            return nil
        }
        let newChangeSet = ClickyPendingChangeSet(changes: changes, actions: actions, proposedAt: moment)
        pendingChangeSet = newChangeSet
        expiredChangeSet = nil
        anOrdinaryTurnStartedSinceTheProposal = false
        return newChangeSet
    }

    /// An ordinary turn started (the user's words go to the model). Called for every such turn; it
    /// only matters while a set waits or has just expired.
    mutating func noteAnOrdinaryTurnStarted() {
        anOrdinaryTurnStartedSinceTheProposal = true
    }

    /// The waiting set, or nil when none waits. A set past its ten minutes is moved to
    /// `expiredChangeSet` here, the first time anyone looks.
    mutating func currentPendingChangeSet(at moment: Date) -> ClickyPendingChangeSet? {
        if let pendingChangeSet, pendingChangeSet.isExpired(at: moment) {
            expiredChangeSet = pendingChangeSet
            self.pendingChangeSet = nil
        }
        return pendingChangeSet
    }

    /// Takes the expired set (once), for the "that change expired" answer.
    mutating func takeExpiredChangeSet() -> ClickyPendingChangeSet? {
        let expiredSet = expiredChangeSet
        expiredChangeSet = nil
        return expiredSet
    }

    /// The user said no (or pressed Escape): the waiting set is dropped and returned.
    @discardableResult
    mutating func discardPendingChangeSet() -> ClickyPendingChangeSet? {
        let discardedSet = pendingChangeSet
        pendingChangeSet = nil
        return discardedSet
    }

    mutating func recordApplied(_ record: ClickyAppliedChangeRecord) {
        pendingChangeSet = nil
        expiredChangeSet = nil
        lastAppliedRecord = record
    }

    /// The applied set that can still be undone, or nil after 30 minutes (or when nothing was applied).
    func undoableRecord(at moment: Date) -> ClickyAppliedChangeRecord? {
        guard let lastAppliedRecord, lastAppliedRecord.isUndoAvailable(at: moment) else {
            return nil
        }
        return lastAppliedRecord
    }

    mutating func clearUndoRecord() {
        lastAppliedRecord = nil
    }

    // MARK: - Round 18: actions in the set, and the reminder undo record

    /// A folder was removed in settings: only the file changes inside it are dropped, and the set's
    /// actions (a link or a shortcut has no folder) stay waiting. A set left with nothing in it is
    /// dropped. Returns true when the set is gone because of that.
    @discardableResult
    mutating func removeChanges(insideFolderPath folderPath: String) -> Bool {
        guard let pendingChangeSet else {
            return false
        }
        let reducedSet = pendingChangeSet.removingChanges(insideFolderPath: folderPath)
        if reducedSet.changes.count == pendingChangeSet.changes.count {
            return false
        }
        if reducedSet.isEmpty {
            self.pendingChangeSet = nil
            return true
        }
        self.pendingChangeSet = reducedSet
        return false
    }

    /// Actions were switched off in settings: the waiting set loses its actions and keeps its file
    /// changes. A set left with nothing in it is dropped. Returns true when the set is gone.
    @discardableResult
    mutating func removeActions() -> Bool {
        guard let pendingChangeSet, !pendingChangeSet.actions.isEmpty else {
            return false
        }
        let reducedSet = pendingChangeSet.removingActions()
        if reducedSet.isEmpty {
            self.pendingChangeSet = nil
            return true
        }
        self.pendingChangeSet = reducedSet
        return false
    }

    /// A confirmed set that held only actions: the set is done, and there is no file record to undo.
    mutating func recordAppliedActionsOnly(heldAShortcut: Bool, at moment: Date) {
        pendingChangeSet = nil
        expiredChangeSet = nil
        lastActionOnlyApplication = ClickyActionOnlyApplicationRecord(appliedAt: moment, heldAShortcut: heldAShortcut)
    }

    mutating func recordCreatedReminders(_ reminderIdentifiers: [String], at moment: Date) {
        guard !reminderIdentifiers.isEmpty else {
            return
        }
        lastCreatedRemindersRecord = ClickyCreatedRemindersRecord(reminderIdentifiers: reminderIdentifiers, createdAt: moment)
    }

    /// The reminders that "undo that" can still remove, or nil after 30 minutes.
    func undoableRemindersRecord(at moment: Date) -> ClickyCreatedRemindersRecord? {
        guard let lastCreatedRemindersRecord, lastCreatedRemindersRecord.isUndoAvailable(at: moment) else {
            return nil
        }
        return lastCreatedRemindersRecord
    }

    mutating func clearReminderUndoRecord() {
        lastCreatedRemindersRecord = nil
    }

    mutating func clearActionOnlyApplicationRecord() {
        lastActionOnlyApplication = nil
    }

    /// What "undo that" would act on right now: the newest of the last applied file set, the last
    /// created reminders and the last set that held only actions, within 30 minutes of each. nil when
    /// none is left to undo.
    func newestUndoTarget(at moment: Date) -> ClickyUndoTarget? {
        var candidates: [(target: ClickyUndoTarget, happenedAt: Date)] = []
        if let undoableFileRecord = undoableRecord(at: moment) {
            candidates.append((.files, undoableFileRecord.appliedAt))
        }
        if let undoableRemindersRecord = undoableRemindersRecord(at: moment) {
            candidates.append((.reminders, undoableRemindersRecord.createdAt))
        }
        if let lastActionOnlyApplication, lastActionOnlyApplication.isRecent(at: moment) {
            candidates.append((.actionThatCannotBeUndone, lastActionOnlyApplication.appliedAt))
        }
        // The newest wins; on a tie the later one in the list does (the reminder over the files).
        return candidates.max { first, second in first.happenedAt <= second.happenedAt }?.target
    }

    /// What the user's words (a whole transcript) mean right now: apply the waiting set, discard it,
    /// answer that it expired, undo the last set, or nothing (a normal turn). The words have to be
    /// exactly one of the confirmation phrases, and there has to be something for them to act on.
    /// A yes or no answers only a set proposed by the latest turn (see
    /// `anOrdinaryTurnStartedSinceTheProposal`).
    mutating func decision(forTranscript transcript: String, at moment: Date) -> ClickyChangeVoiceDecision {
        guard let intent = ClickyChangeConfirmationPhrases.intent(forTranscript: transcript) else {
            return .normalTurn
        }
        switch intent {
        case .confirm:
            if currentPendingChangeSet(at: moment) != nil {
                return anOrdinaryTurnStartedSinceTheProposal ? .normalTurn : .applyPendingChanges
            }
            if expiredChangeSet != nil && !anOrdinaryTurnStartedSinceTheProposal {
                return .tellThatTheChangeExpired
            }
            return .normalTurn
        case .cancel:
            if currentPendingChangeSet(at: moment) != nil && !anOrdinaryTurnStartedSinceTheProposal {
                return .discardPendingChanges
            }
            return .normalTurn
        case .undo:
            switch newestUndoTarget(at: moment) {
            case .files, .reminders:
                return .undoLastAppliedChanges
            case .actionThatCannotBeUndone:
                return .tellThatTheActionCannotBeUndone
            case nil:
                break
            }
            // Too late to undo, or nothing to undo: a plain answer, never a model call that might
            // claim it undid something.
            let somethingWasRecorded = lastAppliedRecord != nil || lastCreatedRemindersRecord != nil || lastActionOnlyApplication != nil
            return somethingWasRecorded || pendingChangeSet != nil || expiredChangeSet != nil ? .tellThatThereIsNothingToUndo : .normalTurn
        }
    }
}

nonisolated enum ClickyChangeVoiceDecision: Equatable {
    /// Not a confirmation of anything that exists: the transcript goes to the model as usual.
    case normalTurn
    case applyPendingChanges
    case discardPendingChanges
    case tellThatTheChangeExpired
    case undoLastAppliedChanges
    case tellThatThereIsNothingToUndo
    /// Round 18: the newest thing to undo is a confirmed shortcut or link, which cannot be undone.
    case tellThatTheActionCannotBeUndone
}

/// What "undo that" acts on (round 18).
nonisolated enum ClickyUndoTarget: Equatable {
    case files
    case reminders
    case actionThatCannotBeUndone
}

/// The reminders a turn created, kept for 30 minutes so "undo that" can remove them.
nonisolated struct ClickyCreatedRemindersRecord: Equatable, Sendable {
    /// The `calendarItemIdentifier` of each reminder. No title is kept.
    let reminderIdentifiers: [String]
    let createdAt: Date

    func isUndoAvailable(at moment: Date) -> Bool {
        moment >= createdAt && moment < createdAt.addingTimeInterval(ClickyActionLimits.reminderUndoLifetimeSeconds)
    }
}

nonisolated struct ClickyActionOnlyApplicationRecord: Equatable, Sendable {
    let appliedAt: Date
    let heldAShortcut: Bool

    func isRecent(at moment: Date) -> Bool {
        moment >= appliedAt && moment < appliedAt.addingTimeInterval(ClickyFileEditingLimits.undoLifetimeSeconds)
    }
}
