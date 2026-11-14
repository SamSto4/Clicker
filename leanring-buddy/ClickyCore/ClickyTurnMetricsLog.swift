import Foundation

/// How a turn ended.
nonisolated enum ClickyTurnOutcome: String {
    case completed
    /// The user spoke again or pressed Escape, so this turn's work was thrown away.
    case cancelled
    case failed
}

/// The stages of one turn, in order. Used to mark where a failed or cancelled turn stopped.
nonisolated enum ClickyTurnStep: String {
    case screenCapture
    case promptAssembly
    case claudeRequest
    case textToSpeech
    /// The audio was playing. Only used to record that Escape cut the speech short.
    case speechPlayback
}

/// How the user's words reached Clicky: spoken through push-to-talk, or typed in the chat panel.
/// A typed turn has no speech and no key release, so its speech and key-release fields stay empty.
nonisolated enum ClickyTurnInputMode: String, Codable {
    case spoken
    case typed
}

/// How a proposed change ended (round 17). A fixed identifier, never a path.
nonisolated enum ClickyChangeOutcome: String, Equatable {
    case applied
    case cancelled
    case expired
    /// A file was no longer what it was when the change was proposed (or had unsaved edits), so
    /// nothing was written.
    case refusedChanged
}

/// What is known about one turn: durations, sizes and counts, never any content.
///
/// Privacy rule: this type holds only numbers, flags, enums and a sanitized model name. There is
/// deliberately no field that could hold the transcript, the reply, note text, window titles or
/// file paths, so none of them can reach the log by accident.
nonisolated struct ClickyTurnMetrics: Equatable {
    let turnStartedAt: Date
    var modelName: String
    var inputMode: ClickyTurnInputMode = .spoken
    var outcome: ClickyTurnOutcome = .completed
    /// The step that was running when a failed or cancelled turn stopped. Nil for completed turns.
    var unfinishedStep: ClickyTurnStep?

    var screenCount: Int?
    var totalImageBytes: Int?

    var screenshotCaptureMilliseconds: Int?
    var promptAssemblyMilliseconds: Int?
    /// Measured from the moment the request to Claude began until the first reply text arrived.
    var timeToFirstReplyTextMilliseconds: Int?
    /// Measured from the moment the request to Claude began until its reply finished (or failed).
    var claudeTotalMilliseconds: Int?
    /// Measured from the moment the speech request began until audio started playing. With early
    /// speech fetching this is the short wait left after the finisher decided the spoken text.
    var textToSpeechMilliseconds: Int?

    /// The three numbers the user feels, all counted from the moment the push-to-talk keys were
    /// released. They stay empty when the release moment was not recorded.
    /// Release until the final transcript was handed to the app (dictation finalisation).
    var keyReleaseToFinalTranscriptMilliseconds: Int?
    /// Release until the first piece of Claude's reply text arrived.
    var keyReleaseToFirstReplyTextMilliseconds: Int?
    /// Release until audio started playing.
    var keyReleaseToAudioStartMilliseconds: Int?
    /// How long the network took to return the speech audio that was played (the early fetch
    /// when one was used, otherwise the fetch of the final text).
    var textToSpeechFetchMilliseconds: Int?
    /// Whether audio fetched while Claude was still writing tags was used, and if not, why.
    var speechPrefetchOutcome: ClickySpeechPrefetchOutcome?
    /// True when the user pressed Escape to stop this turn (or its speech).
    var wasInterruptedByEscapeKey = false

    var tokenUsage = ClickyClaudeTokenUsage()

    // Round 17 (file editing), numbers and fixed identifiers only, never a path or file text. Left
    // out of a turn that never used the tools.
    /// Requests of the tool loop that ended in `tool_use` and were answered with tool results.
    var toolRoundTripCount: Int?
    /// Tool calls run in this turn.
    var toolCallCount: Int?
    /// Bytes of file text the `read_file` calls returned.
    var bytesRead: Int?
    /// Changes the turn queued for the user to confirm.
    var changesProposed: Int?
    var changeOutcome: ClickyChangeOutcome?
    /// One entry per request of the loop, in order. They show what the first user message (with the
    /// screenshots), replayed on every request, costs and whether the cache reads it.
    var roundTripInputTokens: [Int]?
    var roundTripCacheReadTokens: [Int]?
    var roundTripMilliseconds: [Int]?

    var spokenReplyCharacterCount: Int?
    var skillCount: Int?
    var noteCount: Int?
    var usedPointing: Bool?

    init(turnStartedAt: Date, modelName: String) {
        self.turnStartedAt = turnStartedAt
        self.modelName = modelName
    }

    // MARK: - Timing helpers

    /// A clock that never jumps backwards (unlike the wall clock), for measuring durations.
    static var currentUptimeSeconds: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    static func millisecondsBetween(startUptimeSeconds: TimeInterval, endUptimeSeconds: TimeInterval) -> Int {
        max(0, Int(((endUptimeSeconds - startUptimeSeconds) * 1000).rounded()))
    }

    static func millisecondsElapsed(sinceUptimeSeconds startUptimeSeconds: TimeInterval) -> Int {
        millisecondsBetween(startUptimeSeconds: startUptimeSeconds, endUptimeSeconds: currentUptimeSeconds)
    }

    /// Nil when the start moment was never recorded (for example the key release could not be
    /// seen), so a missing measurement is left out instead of being logged as a wrong number.
    static func millisecondsBetweenIfStartIsKnown(startUptimeSeconds: TimeInterval?, endUptimeSeconds: TimeInterval) -> Int? {
        guard let startUptimeSeconds else {
            return nil
        }
        return millisecondsBetween(startUptimeSeconds: startUptimeSeconds, endUptimeSeconds: endUptimeSeconds)
    }

    // MARK: - Output

    /// The model name is the only free-form string in a record, so it is reduced to a short
    /// identifier. Anything that does not look like a model id (for example text with spaces,
    /// such as a spoken sentence) is replaced with "unknown" instead of being logged.
    static let maximumModelNameLength = 64

    static func sanitizedModelName(_ rawModelName: String) -> String {
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let isShortIdentifier = !rawModelName.isEmpty
            && rawModelName.count <= maximumModelNameLength
            && rawModelName.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
        return isShortIdentifier ? rawModelName : "unknown"
    }

    /// One JSON object on one line, keys sorted so lines are easy to compare. Fields that were
    /// never measured are left out rather than written as zero.
    func makeJSONLine() -> String? {
        var jsonObject: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: turnStartedAt),
            "model": Self.sanitizedModelName(modelName),
            "inputMode": inputMode.rawValue,
            "outcome": outcome.rawValue
        ]

        if let unfinishedStep { jsonObject["unfinishedStep"] = unfinishedStep.rawValue }
        if let screenCount { jsonObject["screenCount"] = screenCount }
        if let totalImageBytes { jsonObject["totalImageBytes"] = totalImageBytes }

        if let screenshotCaptureMilliseconds { jsonObject["screenshotCaptureMs"] = screenshotCaptureMilliseconds }
        if let promptAssemblyMilliseconds { jsonObject["promptAssemblyMs"] = promptAssemblyMilliseconds }
        if let timeToFirstReplyTextMilliseconds { jsonObject["timeToFirstReplyTextMs"] = timeToFirstReplyTextMilliseconds }
        if let claudeTotalMilliseconds { jsonObject["claudeTotalMs"] = claudeTotalMilliseconds }
        if let textToSpeechMilliseconds { jsonObject["textToSpeechMs"] = textToSpeechMilliseconds }
        if let keyReleaseToFinalTranscriptMilliseconds { jsonObject["keyReleaseToFinalTranscriptMs"] = keyReleaseToFinalTranscriptMilliseconds }
        if let keyReleaseToFirstReplyTextMilliseconds { jsonObject["keyReleaseToFirstReplyTextMs"] = keyReleaseToFirstReplyTextMilliseconds }
        if let keyReleaseToAudioStartMilliseconds { jsonObject["keyReleaseToAudioStartMs"] = keyReleaseToAudioStartMilliseconds }
        if let textToSpeechFetchMilliseconds { jsonObject["textToSpeechFetchMs"] = textToSpeechFetchMilliseconds }
        if let speechPrefetchOutcome {
            jsonObject["speechPrefetchOutcome"] = speechPrefetchOutcome.rawValue
            jsonObject["usedPrefetchedSpeech"] = speechPrefetchOutcome == .used
        }
        if wasInterruptedByEscapeKey { jsonObject["interruptedByEscape"] = true }

        if let inputTokens = tokenUsage.inputTokens { jsonObject["inputTokens"] = inputTokens }
        if let outputTokens = tokenUsage.outputTokens { jsonObject["outputTokens"] = outputTokens }
        if let cacheCreationInputTokens = tokenUsage.cacheCreationInputTokens { jsonObject["cacheCreationInputTokens"] = cacheCreationInputTokens }
        if let cacheReadInputTokens = tokenUsage.cacheReadInputTokens { jsonObject["cacheReadInputTokens"] = cacheReadInputTokens }

        if let toolRoundTripCount { jsonObject["toolRoundTrips"] = toolRoundTripCount }
        if let toolCallCount { jsonObject["toolCalls"] = toolCallCount }
        if let bytesRead { jsonObject["bytesRead"] = bytesRead }
        if let changesProposed { jsonObject["changesProposed"] = changesProposed }
        if let changeOutcome { jsonObject["changeOutcome"] = changeOutcome.rawValue }
        if let roundTripInputTokens { jsonObject["roundTripInputTokens"] = roundTripInputTokens }
        if let roundTripCacheReadTokens { jsonObject["roundTripCacheReadTokens"] = roundTripCacheReadTokens }
        if let roundTripMilliseconds { jsonObject["roundTripMs"] = roundTripMilliseconds }

        if let spokenReplyCharacterCount { jsonObject["spokenReplyCharacterCount"] = spokenReplyCharacterCount }
        if let skillCount { jsonObject["skillCount"] = skillCount }
        if let noteCount { jsonObject["noteCount"] = noteCount }
        if let usedPointing { jsonObject["usedPointing"] = usedPointing }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: jsonData, encoding: .utf8)
    }

    /// One compact line for the Xcode console, so timings are visible while developing.
    func makeConsoleSummaryLine() -> String {
        func millisecondsText(_ milliseconds: Int?) -> String {
            milliseconds.map { "\($0)ms" } ?? "-"
        }
        func countText(_ count: Int?) -> String {
            count.map { String($0) } ?? "-"
        }

        var summaryLine = "⏱ turn \(outcome.rawValue)"
        if let unfinishedStep {
            summaryLine += " at \(unfinishedStep.rawValue)"
        }
        summaryLine += " | capture \(millisecondsText(screenshotCaptureMilliseconds))"
        summaryLine += " prompt \(millisecondsText(promptAssemblyMilliseconds))"
        summaryLine += " firstText \(millisecondsText(timeToFirstReplyTextMilliseconds))"
        summaryLine += " claude \(millisecondsText(claudeTotalMilliseconds))"
        summaryLine += " tts \(millisecondsText(textToSpeechMilliseconds))"
        summaryLine += " | from key release: transcript \(millisecondsText(keyReleaseToFinalTranscriptMilliseconds))"
        summaryLine += " firstText \(millisecondsText(keyReleaseToFirstReplyTextMilliseconds))"
        summaryLine += " audio \(millisecondsText(keyReleaseToAudioStartMilliseconds))"
        summaryLine += " | ttsFetch \(millisecondsText(textToSpeechFetchMilliseconds))"
        summaryLine += " prefetch \(speechPrefetchOutcome?.rawValue ?? "-")"
        if wasInterruptedByEscapeKey {
            summaryLine += " escape"
        }
        summaryLine += " | tokens in \(countText(tokenUsage.inputTokens))"
        summaryLine += " out \(countText(tokenUsage.outputTokens))"
        summaryLine += " cacheWrite \(countText(tokenUsage.cacheCreationInputTokens))"
        summaryLine += " cacheRead \(countText(tokenUsage.cacheReadInputTokens))"
        summaryLine += " | spoken \(countText(spokenReplyCharacterCount)) chars"
        summaryLine += " skills \(countText(skillCount))"
        summaryLine += " notes \(countText(noteCount))"
        summaryLine += " point \(usedPointing.map { $0 ? "yes" : "no" } ?? "-")"
        summaryLine += " | \(Self.sanitizedModelName(modelName)), \(countText(screenCount)) screen(s), \(countText(totalImageBytes)) image bytes"
        summaryLine += ", \(inputMode.rawValue)"
        if let toolCallCount {
            summaryLine += " | tools: \(countText(toolRoundTripCount)) round trips, \(toolCallCount) calls, \(countText(bytesRead)) bytes read, \(countText(changesProposed)) changes proposed"
            if let roundTripMilliseconds {
                summaryLine += ", per request \(roundTripMilliseconds.map { "\($0)ms" }.joined(separator: "/"))"
            }
        }
        if let changeOutcome {
            summaryLine += " | change \(changeOutcome.rawValue)"
        }
        return summaryLine
    }
}

/// Remembers when the first piece of reply text arrived from Claude.
///
/// It is a class (not a local variable) because the text callback is a `@Sendable` closure, which
/// cannot mutate a captured local. Keeping the moment here also means a turn that fails after
/// some text arrived still knows its time to first text.
nonisolated final class ClickyReplyTextArrivalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFirstReplyTextArrivalUptimeSeconds: TimeInterval?

    /// Safe to call on every chunk: only the first call is remembered.
    func markReplyTextArrived() {
        lock.lock()
        defer { lock.unlock() }
        if storedFirstReplyTextArrivalUptimeSeconds == nil {
            storedFirstReplyTextArrivalUptimeSeconds = ClickyTurnMetrics.currentUptimeSeconds
        }
    }

    var firstReplyTextArrivalUptimeSeconds: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return storedFirstReplyTextArrivalUptimeSeconds
    }
}

/// Appends one JSON line per turn to a local file so speed and token use can be inspected later.
/// Nothing here ever throws or blocks a turn: every failure is swallowed, because losing a
/// metrics line is always better than disturbing a spoken answer.
nonisolated enum ClickyTurnMetricsLog {
    /// After a rotation, only this many of the newest lines are kept.
    static let newestLineCountToKeep = 500
    /// The file is rewritten only once it grows past this many lines, so most turns just append.
    static let lineCountThatTriggersRotation = 600

    static var defaultLogFileURL: URL {
        let libraryDirectoryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return libraryDirectoryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("turn_metrics.jsonl")
    }

    /// File work runs on its own low-priority queue so the main thread never waits on disk.
    private static let backgroundWriteQueue = DispatchQueue(label: "com.clicky.turn-metrics-log", qos: .utility)

    /// What the app calls once per turn. Returns immediately; the write happens in the background.
    static func recordInBackground(_ turnMetrics: ClickyTurnMetrics, to logFileURL: URL = defaultLogFileURL) {
        guard let jsonLine = turnMetrics.makeJSONLine() else { return }
        backgroundWriteQueue.async {
            appendLine(jsonLine, to: logFileURL)
        }
    }

    /// Same as `recordInBackground` but writes on the calling thread. Returns whether the line was
    /// written, so tests can wait for the result; the app ignores it.
    @discardableResult
    static func record(_ turnMetrics: ClickyTurnMetrics, to logFileURL: URL = defaultLogFileURL) -> Bool {
        guard let jsonLine = turnMetrics.makeJSONLine() else { return false }
        return appendLine(jsonLine, to: logFileURL)
    }

    /// Not private so the dictation metrics log (`ClickyDictationMetricsLog`) reuses the same
    /// owner-only file creation and newest-500-lines rotation for its own file.
    @discardableResult
    static func appendLine(_ jsonLine: String, to logFileURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                // Owner-only access: the file is harmless, but there is no reason to share it.
                FileManager.default.createFile(
                    atPath: logFileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }

            let logFileHandle = try FileHandle(forWritingTo: logFileURL)
            defer { try? logFileHandle.close() }
            try logFileHandle.seekToEnd()
            try logFileHandle.write(contentsOf: Data((jsonLine + "\n").utf8))

            rewriteKeepingNewestLinesIfFileIsTooLong(at: logFileURL)
            return true
        } catch {
            return false
        }
    }

    /// Keeps the file small without touching it on every turn: once it passes
    /// `lineCountThatTriggersRotation` lines, it is rewritten with only the newest
    /// `newestLineCountToKeep`. The gap between the two numbers means a rewrite happens
    /// only about once every 100 turns.
    private static func rewriteKeepingNewestLinesIfFileIsTooLong(at logFileURL: URL) {
        guard let existingFileData = try? Data(contentsOf: logFileURL) else { return }
        let existingLines = String(decoding: existingFileData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard existingLines.count > lineCountThatTriggersRotation else { return }

        let rewrittenFileText = existingLines.suffix(newestLineCountToKeep).joined(separator: "\n") + "\n"
        do {
            try rewrittenFileText.write(to: logFileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
        } catch {
            // The long file stays as it is; the next turn tries again.
        }
    }
}
