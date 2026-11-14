import Foundation

// Round 18 (Jarvis actions): the timers Clicky is running. A pure value with an injected clock, so
// ids, labels, limits, cancelling by label, the due-time bookkeeping and the prompt lines can all be
// checked with explicit times. The app's `ClickyTimerController` owns one board, wakes up when a timer
// is due, and plays the alert. Since round 19 the board's state is saved (`ClickyTimerStore`) on every
// change and read at launch, so a timer survives a restart: a running one fires at its original end,
// and one that ended while Clicky was quit is reported then.

nonisolated struct ClickyTimer: Equatable, Sendable, Codable {
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

    // MARK: - Saved state (round 19)

    /// What is saved: the timers and the number the next id gets (amendment 5: an id is never used
    /// twice, even after a restart, so after t2 was cancelled the next timer is t3).
    var savedState: ClickyTimerBoardState {
        ClickyTimerBoardState(timers: timers, nextTimerNumber: nextTimerNumber)
    }

    /// The board a saved state describes. Anything that does not look like a timer this board made is
    /// left out (an id that is not "t" and a number, a length out of range, an end that is not its
    /// start plus its length, a second timer with an id already seen); labels are cleaned again; at
    /// most `ClickyActionLimits.maximumRunningTimers` are kept, the soonest to end. The next number is
    /// past every id kept and never lower than the one saved.
    init(restoring savedState: ClickyTimerBoardState) {
        var seenIdentifiers = Set<String>()
        var restoredTimers: [ClickyTimer] = []
        for savedTimer in savedState.timers {
            guard let timerNumber = Self.timerNumber(ofIdentifier: savedTimer.identifier),
                  timerNumber >= 1,
                  savedTimer.durationSeconds >= ClickyActionLimits.minimumTimerSeconds,
                  savedTimer.durationSeconds <= ClickyActionLimits.maximumTimerSeconds,
                  abs(savedTimer.endsAt.timeIntervalSince(savedTimer.startedAt) - TimeInterval(savedTimer.durationSeconds)) < 1,
                  seenIdentifiers.insert(savedTimer.identifier).inserted else {
                continue
            }
            restoredTimers.append(ClickyTimer(
                identifier: savedTimer.identifier,
                label: Self.cleanedLabel(savedTimer.label),
                durationSeconds: savedTimer.durationSeconds,
                startedAt: savedTimer.startedAt,
                endsAt: savedTimer.endsAt
            ))
        }
        restoredTimers.sort { $0.endsAt < $1.endsAt }
        timers = Array(restoredTimers.prefix(ClickyActionLimits.maximumRunningTimers))
        let highestNumberKept = timers.compactMap { Self.timerNumber(ofIdentifier: $0.identifier) }.max() ?? 0
        nextTimerNumber = max(savedState.nextTimerNumber, highestNumberKept + 1, 1)
    }

    /// 7 for "t7"; nil for anything else.
    static func timerNumber(ofIdentifier identifier: String) -> Int? {
        guard identifier.hasPrefix("t"), identifier.count >= 2 else { return nil }
        let digits = identifier.dropFirst()
        guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// The timers that ended before `moment` (at a launch: while Clicky was quit), in the order they ended.
    func timersEndedWhileAway(now moment: Date) -> [ClickyTimer] {
        timers.filter { $0.endsAt <= moment }.sorted { $0.endsAt < $1.endsAt }
    }

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

// MARK: - Timers that ended while Clicky was quit (round 19)

/// The saved form of a board: its timers and the next id number.
nonisolated struct ClickyTimerBoardState: Codable, Equatable, Sendable {
    var timers: [ClickyTimer]
    var nextTimerNumber: Int
}

extension ClickyTimerBoard {
    /// A timer that ended while Clicky was quit is spoken about at launch only when it ended less than
    /// this long ago (Sam's decision of 14 Nov 2026); otherwise it is only shown.
    static let endedWhileAwaySpokenWithinSeconds: TimeInterval = 10 * 60

    /// The timers of the list that ended less than ten minutes before `moment`.
    static func timersEndedRecently(_ endedTimers: [ClickyTimer], now moment: Date) -> [ClickyTimer] {
        endedTimers.filter { moment.timeIntervalSince($0.endsAt) < endedWhileAwaySpokenWithinSeconds }
    }

    /// "pasta timer", "pasta and tea timers", "pasta, tea and eggs timers", "timer", "2 timers",
    /// "pasta timer and 1 more": the timers of one notice, named by their labels (amendment 8: one
    /// combined notice for all of them).
    static func combinedTimerNames(for endedTimers: [ClickyTimer]) -> String {
        let labels = endedTimers.compactMap(\.label)
        let unlabelledCount = endedTimers.count - labels.count
        guard !labels.isEmpty else {
            return unlabelledCount == 1 ? "timer" : "\(unlabelledCount) timers"
        }
        let joinedLabels: String
        if labels.count == 1 {
            joinedLabels = labels[0]
        } else {
            joinedLabels = labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        }
        let namedText = joinedLabels + (labels.count == 1 ? " timer" : " timers")
        return unlabelledCount == 0 ? namedText : namedText + " and \(unlabelledCount) more"
    }

    /// The notice: "pasta timer ended while i was off", "pasta and tea timers ended while i was off".
    static func endedWhileAwayNoticeText(for endedTimers: [ClickyTimer]) -> String {
        "\(combinedTimerNames(for: endedTimers)) ended while i was off"
    }

    /// The sentence: "your pasta timer ended while i was off.", "your pasta and tea timers ended while
    /// i was off.", "your timer ended while i was off.".
    static func endedWhileAwaySentence(for endedTimers: [ClickyTimer]) -> String {
        "your \(combinedTimerNames(for: endedTimers)) ended while i was off."
    }
}

/// Saves and reads the timers (round 19): `timers.json` in `~/Library/Application Support/Clicky/Timers`,
/// local only. Written atomically on every change, read tolerantly at launch: a missing or unreadable
/// file is no timers. The ids, labels and times are the only things in it.
nonisolated struct ClickyTimerStore: Sendable {
    static let timersFileName = "timers.json"
    /// Honoured only in a self test, like the memories folder: an ordinary run always uses the real one.
    static let directoryOverrideEnvironmentVariable = "CLICKY_TIMERS_DIRECTORY"
    static let drawingSelfTestEnvironmentVariable = "CLICKY_DRAW_SELF_TEST"

    let timersDirectoryURL: URL

    init(timersDirectoryURL: URL) {
        self.timersDirectoryURL = timersDirectoryURL
    }

    var timersFileURL: URL {
        timersDirectoryURL.appendingPathComponent(Self.timersFileName)
    }

    static var defaultTimersDirectoryURL: URL {
        let applicationSupportDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportDirectoryURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("Timers", isDirectory: true)
    }

    /// The folder this run uses: the real one, except in a self test (the panel's or the drawing's),
    /// which gets `CLICKY_TIMERS_DIRECTORY` when given and otherwise a new temporary folder.
    static func directoryURLForRun(environment: [String: String], temporaryDirectoryURL: URL, uniqueFolderNameForSelfTest: String) -> URL {
        let isSelfTest = environment[ClickyChatStore.panelSelfTestEnvironmentVariable] == "1" || environment[drawingSelfTestEnvironmentVariable] == "1"
        guard isSelfTest else {
            return defaultTimersDirectoryURL
        }
        if let overridePath = environment[directoryOverrideEnvironmentVariable], !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }
        return temporaryDirectoryURL.appendingPathComponent(uniqueFolderNameForSelfTest, isDirectory: true)
    }

    /// The saved state, or nil when there is none or it cannot be read. Dates are read with or
    /// without fractional seconds.
    func load() -> ClickyTimerBoardState? {
        guard let fileData = try? Data(contentsOf: timersFileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let dateText = try dateDecoder.singleValueContainer().decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: dateText) ?? ISO8601DateFormatter().date(from: dateText) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: try dateDecoder.singleValueContainer(), debugDescription: "not an ISO 8601 date")
        }
        return try? decoder.decode(ClickyTimerBoardState.self, from: fileData)
    }

    /// Writes the state atomically (pretty-printed, sorted keys, ISO dates with milliseconds, so a
    /// restored timer ends when it was meant to, not up to a second early). False when it could not.
    @discardableResult
    func save(_ state: ClickyTimerBoardState) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, dateEncoder in
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = dateEncoder.singleValueContainer()
            try container.encode(fractionalFormatter.string(from: date))
        }
        do {
            try FileManager.default.createDirectory(at: timersDirectoryURL, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: timersFileURL, options: .atomic)
            return true
        } catch {
            return false
        }
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
