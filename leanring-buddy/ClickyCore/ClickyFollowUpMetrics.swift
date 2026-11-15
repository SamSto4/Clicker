import Foundation

// Round 19 (Jarvis tuning): one line of numbers per follow-up listening window, in its own local log
// (`~/Library/Logs/Clicky/follow_up_metrics.jsonl`). Round 18 chose the window's thresholds without
// data, and a window that closed without a sound wrote nothing, so a window that never heard the user,
// or one that fired on a TV, was invisible. This log records every window, whatever its outcome, so the
// thresholds can be tuned later from a week of real use. Nothing here changes how a window behaves.
//
// Privacy rule: a line holds numbers, one fixed close reason and a random turn identifier. The record
// type has no field that could hold a transcript, an app name, a label or any other text.

// MARK: - Why a window ended

/// Why a follow-up window closed (or, for `chainCap`, why none opened). The first nine are round 18's
/// reasons for closing a window before anything was heard to its end; the last four say what became of
/// words that were heard, and of a window the chain cap kept shut. A `String` enum shared by the app
/// and the log, so the log can only ever hold one of these words.
nonisolated enum ClickyFollowUpCloseReason: String, CaseIterable, Equatable, Sendable {
    case settingSwitchedOff
    case timerAlertAboutToSpeak
    case escape
    case askKeysPressed
    case dictationStarted
    case typedMessage
    case panelOpened
    case newTurnStarted
    case nothingWasSaid
    /// The words became a spoken turn.
    case sentToModel
    /// "thanks", "that's all", "stop" and the like: closed with no model call and no reply.
    case endPhrase
    /// Only "um", "uh" and the like were recognised.
    case fillerOnly
    /// No window opened: five follow-up turns in a row had happened (the round 18 cap).
    case chainCap

    /// What became of a window's final transcript, from round 18's decision about it. An empty
    /// transcript is "nothing was said"; one of only filler words is told apart from it.
    static func reason(forTranscriptDecision decision: ClickyFollowUpTranscriptDecision, transcript: String) -> ClickyFollowUpCloseReason {
        switch decision {
        case .sendToModel, .walkthroughNext, .walkthroughBack, .walkthroughRepeat:
            // Round 21: a walkthrough's step word becomes a turn too (or, after the last step, the
            // fixed "that was the last step."), so it is recorded the same way; the list of reasons
            // is unchanged.
            return .sentToModel
        case .endPhrase:
            return .endPhrase
        case .closeSilently:
            return ClickyChangeConfirmationPhrases.normalized(transcript).isEmpty ? .nothingWasSaid : .fillerOnly
        }
    }
}

// MARK: - The line

nonisolated struct ClickyFollowUpMetrics: Equatable {
    /// Written as `event` on every line, so a line that lands in another log is recognised.
    static let eventName = "followUpWindow"

    /// When the window closed (for `chainCap`: when it would have opened).
    let timestamp: Date
    let closeReason: ClickyFollowUpCloseReason
    /// 1 for the first window after a key press or a typed message, 2 for the window that follows one
    /// follow-up turn, and so on up to 5. A `chainCap` line carries 6: the window that did not open.
    let chainPosition: Int
    /// From the moment the microphone was on until the window closed.
    var windowOpenMilliseconds: Int?
    /// The room's noise floor, as level × 1000 (an integer). Absent when the measurement did not
    /// finish (the window closed first, or the user was already answering, which uses a fixed floor).
    var measuredFloorPerMille: Int?
    /// The highest level read in the window, × 1000.
    var peakLevelPerMille: Int?
    /// From the window opening until speech started. Absent when no speech started.
    var millisecondsToSpeechStart: Int?
    /// From the start of speech until its end was decided. Absent when it never ended in the window.
    var speechMilliseconds: Int?
    /// The identifier of the turn these words started (`sentToModel` only); the turn's own line
    /// carries the same one.
    var turnId: UUID?

    /// One JSON object on one line, keys sorted. Fields that were not measured are left out.
    func makeJSONLine() -> String? {
        var jsonObject: [String: Any] = [
            "event": Self.eventName,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "closeReason": closeReason.rawValue,
            "chainPosition": chainPosition,
        ]
        if let windowOpenMilliseconds { jsonObject["windowOpenMilliseconds"] = windowOpenMilliseconds }
        if let measuredFloorPerMille { jsonObject["measuredFloorPerMille"] = measuredFloorPerMille }
        if let peakLevelPerMille { jsonObject["peakLevelPerMille"] = peakLevelPerMille }
        if let millisecondsToSpeechStart { jsonObject["millisecondsToSpeechStart"] = millisecondsToSpeechStart }
        if let speechMilliseconds { jsonObject["speechMilliseconds"] = speechMilliseconds }
        if let turnId { jsonObject["turnId"] = turnId.uuidString }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: jsonData, encoding: .utf8)
    }

    /// A level of 0...1 as a whole number of thousandths.
    static func perMille(_ level: Double) -> Int {
        Int((min(max(level, 0), 1) * 1000).rounded())
    }
}

// MARK: - What one open window measured

/// The numbers of one open window, collected tick by tick next to the state machine (which decides;
/// this only watches). It lives on the app's side while the window is open, so a window closed by
/// Escape, a key press or a new turn can still write what it had measured.
nonisolated struct ClickyFollowUpWindowMeasurement: Equatable {
    let windowOpenedAtUptimeSeconds: TimeInterval
    let chainPosition: Int
    private(set) var peakLevel = 0.0
    private(set) var measuredFloor: Double?
    private(set) var speechStartedAtUptimeSeconds: TimeInterval?
    private(set) var speechEndedAtUptimeSeconds: TimeInterval?

    init(windowOpenedAtUptimeSeconds: TimeInterval, chainPosition: Int) {
        self.windowOpenedAtUptimeSeconds = windowOpenedAtUptimeSeconds
        self.chainPosition = chainPosition
    }

    /// One reading of the level, after the state machine has processed it.
    mutating func noteReading(level: Double, stateMachine: ClickyFollowUpListeningStateMachine) {
        peakLevel = max(peakLevel, level)
        if measuredFloor == nil, stateMachine.floorWasMeasured {
            measuredFloor = stateMachine.noiseFloor
        }
        if speechStartedAtUptimeSeconds == nil, stateMachine.speechHasStarted {
            speechStartedAtUptimeSeconds = stateMachine.speechStartedAt
        }
    }

    /// The end of speech was decided (the words are being transcribed, or a room that never paused
    /// was given up on). Only the first end counts.
    mutating func noteEndOfSpeech(at moment: TimeInterval) {
        guard speechStartedAtUptimeSeconds != nil, speechEndedAtUptimeSeconds == nil else { return }
        speechEndedAtUptimeSeconds = moment
    }

    func metrics(
        closeReason: ClickyFollowUpCloseReason,
        closedAtUptimeSeconds: TimeInterval,
        closedAt: Date,
        turnId: UUID? = nil
    ) -> ClickyFollowUpMetrics {
        var metrics = ClickyFollowUpMetrics(timestamp: closedAt, closeReason: closeReason, chainPosition: chainPosition)
        metrics.windowOpenMilliseconds = Self.milliseconds(from: windowOpenedAtUptimeSeconds, to: closedAtUptimeSeconds)
        metrics.measuredFloorPerMille = measuredFloor.map(ClickyFollowUpMetrics.perMille)
        metrics.peakLevelPerMille = ClickyFollowUpMetrics.perMille(peakLevel)
        if let speechStartedAtUptimeSeconds {
            metrics.millisecondsToSpeechStart = Self.milliseconds(from: windowOpenedAtUptimeSeconds, to: speechStartedAtUptimeSeconds)
            if let speechEndedAtUptimeSeconds {
                metrics.speechMilliseconds = Self.milliseconds(from: speechStartedAtUptimeSeconds, to: speechEndedAtUptimeSeconds)
            }
        }
        metrics.turnId = turnId
        return metrics
    }

    private static func milliseconds(from startUptimeSeconds: TimeInterval, to endUptimeSeconds: TimeInterval) -> Int {
        max(0, Int(((endUptimeSeconds - startUptimeSeconds) * 1000).rounded()))
    }
}

// MARK: - The log

/// Appends one line per window to `follow_up_metrics.jsonl`, next to the turn log, with the turn log's
/// owner-only file and newest-500-lines rotation. Nothing here throws or blocks.
nonisolated enum ClickyFollowUpMetricsLog {
    static var defaultLogFileURL: URL {
        ClickyTurnMetricsLog.defaultLogFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("follow_up_metrics.jsonl")
    }

    private static let backgroundWriteQueue = DispatchQueue(label: "com.clicky.follow-up-metrics-log", qos: .utility)

    /// What the app calls once per window. Returns at once; the write happens in the background.
    static func recordInBackground(_ followUpMetrics: ClickyFollowUpMetrics, to logFileURL: URL = defaultLogFileURL) {
        guard let jsonLine = followUpMetrics.makeJSONLine() else { return }
        backgroundWriteQueue.async {
            ClickyTurnMetricsLog.appendLine(jsonLine, to: logFileURL)
        }
    }

    /// Same as `recordInBackground` but writes on the calling thread, so tests can wait for it.
    @discardableResult
    static func record(_ followUpMetrics: ClickyFollowUpMetrics, to logFileURL: URL = defaultLogFileURL) -> Bool {
        guard let jsonLine = followUpMetrics.makeJSONLine() else { return false }
        return ClickyTurnMetricsLog.appendLine(jsonLine, to: logFileURL)
    }
}

// MARK: - Reading the log back

/// Reads one line of the follow-up log (for the metrics summary). A line that is not a follow-up line,
/// has no readable timestamp or an unknown close reason gives nil; a bad number costs only itself.
nonisolated enum ClickyFollowUpMetricsParser {
    static func parse(line logLine: String) -> ClickyFollowUpMetrics? {
        let trimmedLine = logLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("{"),
              let parsedObject = try? JSONSerialization.jsonObject(with: Data(trimmedLine.utf8)) as? [String: Any],
              (parsedObject["event"] as? String) == ClickyFollowUpMetrics.eventName,
              let timestampText = parsedObject["timestamp"] as? String,
              let timestamp = ISO8601DateFormatter().date(from: timestampText),
              let closeReason = (parsedObject["closeReason"] as? String).flatMap(ClickyFollowUpCloseReason.init(rawValue:)),
              let chainPosition = wholeNumber(parsedObject["chainPosition"]) else {
            return nil
        }
        var metrics = ClickyFollowUpMetrics(timestamp: timestamp, closeReason: closeReason, chainPosition: chainPosition)
        metrics.windowOpenMilliseconds = wholeNumber(parsedObject["windowOpenMilliseconds"])
        metrics.measuredFloorPerMille = wholeNumber(parsedObject["measuredFloorPerMille"])
        metrics.peakLevelPerMille = wholeNumber(parsedObject["peakLevelPerMille"])
        metrics.millisecondsToSpeechStart = wholeNumber(parsedObject["millisecondsToSpeechStart"])
        metrics.speechMilliseconds = wholeNumber(parsedObject["speechMilliseconds"])
        metrics.turnId = (parsedObject["turnId"] as? String).flatMap(UUID.init(uuidString:))
        return metrics
    }

    /// A non-negative whole number; a boolean, text or a negative number is nil.
    private static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue >= 0, doubleValue < 1e12 else {
            return nil
        }
        return Int(doubleValue)
    }
}
