//
//  ClickyTimerController.swift
//  leanring-buddy
//
//  The timers Clicky is running (round 18, Jarvis actions). The rules (ids, labels, limits, which
//  timer a label means, what is listed in the prompt) are in `ClickyCore/ClickyTimerBoard.swift`;
//  this controller owns the one board of the run and sleeps until the next timer is due. What
//  happens when a timer ends (the sound, the notice, the line in the panel, the spoken sentence) is
//  `CompanionManager`'s to decide, through `timerDueHandler`, because it needs the status pill, the
//  chat panel and the voice.
//
//  Since round 19 the board is saved on every change (`ClickyTimerStore`, a small local file) and read
//  at launch: a timer that was running fires at its original end, and the ones that ended while Clicky
//  was quit are handed to `CompanionManager` to report.
//

import Foundation

@MainActor
final class ClickyTimerController {
    private var board = ClickyTimerBoard()
    private var wakeUpTask: Task<Void, Never>?
    /// Where the timers are saved; nil keeps them in memory only (as before round 19).
    private let store: ClickyTimerStore?
    /// Saves run in order, off the main thread.
    private let saveQueue = DispatchQueue(label: "com.clicky.timers-save", qos: .utility)

    init(store: ClickyTimerStore? = nil) {
        self.store = store
    }

    /// Called once for each timer that has ended, in the order they ended.
    var timerDueHandler: ((ClickyTimer) -> Void)?

    /// The timers that have not ended yet, for the prompt.
    var runningTimers: [ClickyTimer] {
        let now = Date()
        return board.timers.filter { $0.endsAt > now }
    }

    func startTimer(durationSeconds: Int, rawLabel: String?) -> ClickyTimerStartOutcome {
        let outcome = board.start(durationSeconds: durationSeconds, rawLabel: rawLabel, at: Date())
        if case .started = outcome {
            saveBoard()
            scheduleWakeUpForNextTimer()
        }
        return outcome
    }

    func cancelTimer(reference: String) -> ClickyTimerCancelOutcome {
        let outcome = board.cancel(reference: reference)
        if case .cancelled = outcome {
            saveBoard()
            scheduleWakeUpForNextTimer()
        }
        return outcome
    }

    /// Sleeps until the earliest timer ends. It wakes at least every ten seconds and looks at the
    /// wall clock again, so a Mac that slept through the end of a timer still sounds the alert as
    /// soon as it wakes instead of when a long sleep that did not count the night would end.
    private func scheduleWakeUpForNextTimer() {
        wakeUpTask?.cancel()
        wakeUpTask = nil
        guard board.nextDueDate() != nil else { return }

        wakeUpTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard let nextDueDate = self.board.nextDueDate() else { return }
                let secondsUntilDue = nextDueDate.timeIntervalSinceNow
                if secondsUntilDue <= 0 {
                    self.fireTimersThatAreDue()
                    continue
                }
                let secondsToSleep = min(secondsUntilDue, 10)
                try? await Task.sleep(nanoseconds: UInt64(secondsToSleep * 1_000_000_000))
            }
        }
    }

    private func fireTimersThatAreDue() {
        let dueTimers = board.removeDueTimers(at: Date())
        if !dueTimers.isEmpty {
            saveBoard()
        }
        for dueTimer in dueTimers {
            timerDueHandler?(dueTimer)
        }
    }

    // MARK: - Saved timers (round 19)

    /// Reads the timers the last run saved: a running one is armed again with its original end (no
    /// drift), and the ones that ended while Clicky was quit are taken off and returned, in the order
    /// they ended, for one combined notice. The id counter continues (amendment 5). Called once, at launch.
    func restoreSavedTimers(now: Date = Date()) -> [ClickyTimer] {
        guard let store, let savedState = store.load() else {
            return []
        }
        board = ClickyTimerBoard(restoring: savedState)
        let endedWhileAway = board.timersEndedWhileAway(now: now)
        _ = board.removeDueTimers(at: now)
        saveBoard()
        scheduleWakeUpForNextTimer()
        return endedWhileAway
    }

    /// Writes the board as it is now, in the background, in the order of the changes.
    private func saveBoard() {
        guard let store else { return }
        let stateToSave = board.savedState
        saveQueue.async {
            store.save(stateToSave)
        }
    }
}
