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

    init() {}

    /// A new proposal replaces the one that was waiting.
    mutating func queue(_ changes: [ClickyFileChange], at moment: Date) -> ClickyPendingChangeSet? {
        guard !changes.isEmpty else {
            return nil
        }
        let newChangeSet = ClickyPendingChangeSet(changes: changes, proposedAt: moment)
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
            if undoableRecord(at: moment) != nil {
                return .undoLastAppliedChanges
            }
            // Too late to undo, or nothing to undo: a plain answer, never a model call that might
            // claim it undid something.
            return lastAppliedRecord != nil || pendingChangeSet != nil || expiredChangeSet != nil ? .tellThatThereIsNothingToUndo : .normalTurn
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
}
