import Foundation

// Round 18 (Jarvis actions): the timers Clicky is running. A pure value with an injected clock, so
// ids, labels, limits, cancelling by label, the due-time bookkeeping and the prompt lines can all be
// checked with explicit times. The app's `ClickyTimerController` owns one board, wakes up when a timer
// is due, and plays the alert. Timers live only while Clicky runs; they are not saved.

nonisolated struct ClickyTimer: Equatable, Sendable {
    /// "t1", "t2", ... never reused in a run.
    let identifier: String
    /// One line of at most 30 characters with no brackets, or nil when none was given.
    let label: String?
    let durationSeconds: Int
    let startedAt: Date
    let endsAt: Date

    /// `t1 "pasta"`, or `t1` for a timer with no label.
    var shortDescription: String {
        guard let label else {
            return identifier
        }
        return "\(identifier) \"\(label)\""
    }
}

nonisolated enum ClickyClockText {
    /// "15:42" in the given time zone, 24-hour.
    static func hourAndMinute(of date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "7 min 12 s", "45 s", "1 h 5 min": the time left, rounded up to the second. Zero parts are left
    /// out, and the seconds are left out from an hour on.
    static func remainingText(secondsLeft rawSecondsLeft: TimeInterval) -> String {
        let secondsLeft = max(0, Int(rawSecondsLeft.rounded(.up)))
        let hours = secondsLeft / 3600
        let minutes = (secondsLeft % 3600) / 60
        let seconds = secondsLeft % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if seconds > 0 && hours == 0 { parts.append("\(seconds) s") }
        return parts.isEmpty ? "0 s" : parts.joined(separator: " ")
    }
}

nonisolated enum ClickyTimerStartOutcome: Equatable, Sendable {
    case started(ClickyTimer)
    case refusedBecauseTooManyTimersRun
    case refusedBecauseTheDurationIsOutOfRange
}

nonisolated enum ClickyTimerCancelOutcome: Equatable, Sendable {
    case cancelled(ClickyTimer)
    case notFound
    case ambiguous([ClickyTimer])
}

nonisolated struct ClickyTimerBoard: Equatable, Sendable {
    /// The timers that have not gone off yet, oldest first.
    private(set) var timers: [ClickyTimer] = []
    private var nextTimerNumber = 1

    init() {}

    /// One line, at most 30 characters, no square brackets, no straight double quotes; nil when
    /// nothing is left of it.
    static func cleanedLabel(_ rawLabel: String?) -> String? {
        guard let rawLabel else {
            return nil
        }
        let cleanedText = ClickyActionText.oneLine(rawLabel, maximumCharacters: ClickyActionLimits.maximumTimerLabelCharacters)
        return cleanedText.isEmpty ? nil : cleanedText
    }

    mutating func start(durationSeconds: Int, rawLabel: String?, at moment: Date) -> ClickyTimerStartOutcome {
        guard durationSeconds >= ClickyActionLimits.minimumTimerSeconds, durationSeconds <= ClickyActionLimits.maximumTimerSeconds else {
            return .refusedBecauseTheDurationIsOutOfRange
        }
        guard timers.count < ClickyActionLimits.maximumRunningTimers else {
            return .refusedBecauseTooManyTimersRun
        }
        let newTimer = ClickyTimer(
            identifier: "t\(nextTimerNumber)",
            label: Self.cleanedLabel(rawLabel),
            durationSeconds: durationSeconds,
            startedAt: moment,
            endsAt: moment.addingTimeInterval(TimeInterval(durationSeconds))
        )
        nextTimerNumber += 1
        timers.append(newTimer)
        return .started(newTimer)
    }

    /// Stops a timer by its id ("t1"), or by a label: an exact label first, then a label that
    /// contains the words, when only one timer matches.
    mutating func cancel(reference rawReference: String) -> ClickyTimerCancelOutcome {
        let reference = ClickyActionText.normalizedForComparison(rawReference)
        guard !reference.isEmpty else {
            return .notFound
        }
        if let timerWithThatIdentifier = timers.first(where: { $0.identifier == reference }) {
            remove(timerWithThatIdentifier)
            return .cancelled(timerWithThatIdentifier)
        }
        let exactLabelMatches = timers.filter { timer in
            timer.label.map { ClickyActionText.normalizedForComparison($0) == reference } ?? false
        }
        if exactLabelMatches.count == 1 {
            remove(exactLabelMatches[0])
            return .cancelled(exactLabelMatches[0])
        }
        if exactLabelMatches.count > 1 {
            return .ambiguous(exactLabelMatches)
        }
        let containingLabelMatches = timers.filter { timer in
            guard let label = timer.label else { return false }
            let normalizedLabel = ClickyActionText.normalizedForComparison(label)
            return normalizedLabel.contains(reference) || reference.contains(normalizedLabel)
        }
        if containingLabelMatches.count == 1 {
            remove(containingLabelMatches[0])
            return .cancelled(containingLabelMatches[0])
        }
        if containingLabelMatches.count > 1 {
            return .ambiguous(containingLabelMatches)
        }
        return .notFound
    }

    /// Takes the timers that are due (their end is now or past) off the board and returns them, in
    /// the order they end.
    mutating func removeDueTimers(at moment: Date) -> [ClickyTimer] {
        let dueTimers = timers.filter { $0.endsAt <= moment }.sorted { $0.endsAt < $1.endsAt }
        timers.removeAll { $0.endsAt <= moment }
        return dueTimers
    }

    /// When the next timer ends, or nil when none runs. The controller sleeps until then.
    func nextDueDate() -> Date? {
        timers.map(\.endsAt).min()
    }

    private mutating func remove(_ timer: ClickyTimer) {
        timers.removeAll { $0.identifier == timer.identifier }
    }

    /// "timers running:" and one line per timer, or nil when none runs (the section is then absent).
    func promptSectionText(at moment: Date, timeZone: TimeZone) -> String? {
        let runningTimers = timers.filter { $0.endsAt > moment }
        return Self.promptSectionText(for: runningTimers, at: moment, timeZone: timeZone)
    }

    static func promptSectionText(for runningTimers: [ClickyTimer], at moment: Date, timeZone: TimeZone) -> String? {
        guard !runningTimers.isEmpty else {
            return nil
        }
        var lines = ["timers running:"]
        for timer in runningTimers {
            let nameText = timer.label.map { "\(timer.identifier) \"\($0)\"" } ?? timer.identifier
            let remainingText = ClickyClockText.remainingText(secondsLeft: timer.endsAt.timeIntervalSince(moment))
            let endsText = ClickyClockText.hourAndMinute(of: timer.endsAt, timeZone: timeZone)
            lines.append("- \(nameText): \(remainingText) left (ends \(endsText)).")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - What the alert says

    /// The notice and the spoken sentence when a timer ends: "pasta timer done" / "timer done", and
    /// "your pasta timer is done." / "your timer is done.".
    static func noticeText(for timer: ClickyTimer) -> String {
        guard let label = timer.label else {
            return "timer done"
        }
        return "\(label) timer done"
    }

    static func spokenSentence(for timer: ClickyTimer) -> String {
        guard let label = timer.label else {
            return "your timer is done."
        }
        return "your \(label) timer is done."
    }
}

// MARK: - The result texts of the two timer tools

nonisolated enum ClickyTimerResultTexts {
    /// `timer t1 "pasta" started: 10 minutes, ends at 15:42.`
    static func started(_ timer: ClickyTimer, timeZone: TimeZone) -> String {
        "timer \(timer.shortDescription) started: \(ClickyActionText.durationText(seconds: timer.durationSeconds)), ends at \(ClickyClockText.hourAndMinute(of: timer.endsAt, timeZone: timeZone))."
    }

    /// `stopped timer t1 "pasta".`
    static func stopped(_ timer: ClickyTimer) -> String {
        "stopped timer \(timer.shortDescription)."
    }
}
