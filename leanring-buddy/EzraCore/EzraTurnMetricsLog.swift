import Foundation

/// How a turn ended.
nonisolated enum EzraTurnOutcome: String {
    case completed
    /// The user spoke again or pressed Escape, so this turn's work was thrown away.
    case cancelled
    case failed
}

/// The stages of one turn, in order. Used to mark where a failed or cancelled turn stopped.
nonisolated enum EzraTurnStep: String {
    case screenCapture
    case promptAssembly
    case claudeRequest
    case textToSpeech
    /// The audio was playing. Only used to record that Escape cut the speech short.
    case speechPlayback
}

/// How the user's words reached Ezra: spoken through push-to-talk, or typed in the chat panel.
/// A typed turn has no speech and no key release, so its speech and key-release fields stay empty.
nonisolated enum EzraTurnInputMode: String, Codable {
    case spoken
    case typed
}

/// How a proposed change ended (round 17). A fixed identifier, never a path.
nonisolated enum EzraChangeOutcome: String, Equatable {
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
nonisolated struct EzraTurnMetrics: Equatable {
    let turnStartedAt: Date
    var modelName: String
    var inputMode: EzraTurnInputMode = .spoken
    var outcome: EzraTurnOutcome = .completed
    /// The step that was running when a failed or cancelled turn stopped. Nil for completed turns.
    var unfinishedStep: EzraTurnStep?

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
    var speechPrefetchOutcome: EzraSpeechPrefetchOutcome?
    /// True when the user pressed Escape to stop this turn (or its speech).
    var wasInterruptedByEscapeKey = false

    var tokenUsage = EzraClaudeTokenUsage()

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
    var changeOutcome: EzraChangeOutcome?
    /// One entry per request of the loop, in order. They show what the first user message (with the
    /// screenshots), replayed on every request, costs and whether the cache reads it.
    var roundTripInputTokens: [Int]?
    var roundTripCacheReadTokens: [Int]?
    var roundTripMilliseconds: [Int]?

    // Round 18 (Jarvis actions), a count, an array of an enum of fixed identifiers and a flag. There is
    // deliberately no field that could hold an app name, link, search words, path, timer label,
    // reminder title or shortcut name.
    /// Action tool calls made in this turn, including refused and failed ones.
    var actionToolCallCount: Int?
    /// One entry per action that happened or was queued, in order.
    var actionKinds: [EzraActionKind]?
    /// True when the user's words came from the follow-up listening window, not a key press or typing.
    var startedByFollowUpListening = false

    // Round 19 (Jarvis tuning), numbers, flags and one random identifier. Each is left out of the
    // line until it is set, so a line of a turn that did none of these is what it was in round 18.
    /// One entry per request of the loop: the tokens the request wrote to the prompt cache. With the
    /// cache breakpoint after the first tool call, request 2 writes and the later requests read.
    var roundTripCacheCreationTokens: [Int]?
    /// True when the loop ended after one simple action done at once, without a request for words:
    /// the fixed confirmation was spoken instead.
    var skippedFinalRequest: Bool?
    /// True for a quick command: the words were carried out on this Mac with no model call at all.
    var localFastPath: Bool?
    /// Tool calls of one reply that were run together as a group.
    var parallelToolCalls: Int?
    /// A random identifier of this turn (never derived from anything the user said), so the line of
    /// the follow-up window that started a turn can be joined with the turn's own line. A `UUID`, not
    /// text, so the "no free-form string" rule of this type stays structural.
    var turnId: UUID?
    /// How soon Escape came after the reply began: counted from the reply's first audio, or from its
    /// first text when no audio had started yet. Nil when Escape did not stop this turn, or stopped it
    /// before any reply had begun. The proxy for a follow-up window that fired on noise.
    var interruptedWithinMilliseconds: Int?

    var spokenReplyCharacterCount: Int?
    var skillCount: Int?
    var noteCount: Int?
    var usedPointing: Bool?

    // Round 21 (explaining on screen), numbers, flags and one enum of fixed identifiers. Each is left
    // out of the line until it is set, so a line of a turn that did none of these is what it was in
    // round 20. There is deliberately no field that could hold an element's role or title, a plan
    // line or a transcript.
    /// The characters of the skill bodies this turn's prompt carried (0 when none was selected), so
    /// the trade of moving the formats out of the cached base prompt can be measured.
    var skillCharacterCount: Int?
    /// True when the reply drew a spotlight (written only when true).
    var spotlightDrawn: Bool?
    /// On a walkthrough step turn: the step the reply gave (k of `[STEP:k of n]`) and the step count
    /// (n), set when the walkthrough took the step (it began, moved, or was repeated).
    var walkthroughStep: Int?
    var walkthroughStepCount: Int?
    /// What became of the reply's `[POINT:]` target: one of `EzraPointSnapOutcome`'s fixed words
    /// (an enum, so no role or title can be written by accident). nil when the reply did not point.
    var pointSnapOutcome: EzraPointSnapOutcome?
    /// How far the snap moved the point, in whole display points (0 when it did not move it).
    var pointSnapDistancePoints: Int?

    // Round 21b (standing context), two numbers. Each is written only when it is set and greater than
    // zero, so a line of a turn with no context is what it was in round 21. There is deliberately no
    // field that could hold a word of the context or a line of it.
    /// The characters of the user's standing context that reached the prompt (hidden lines removed, cut
    /// to 2,000).
    var contextCharacterCount: Int?
    /// The lines of the context that were hidden from the model because they hold a credential shape.
    var contextHiddenLineCount: Int?

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

    /// The model name a quick command's line carries (round 19): no model was asked, and the usage
    /// tab lists these turns under "quick commands" with no tokens and no price.
    static let quickCommandsModelName = "quick-commands"

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
        if let actionToolCallCount { jsonObject["actionToolCalls"] = actionToolCallCount }
        if let actionKinds { jsonObject["actionKinds"] = actionKinds.map(\.rawValue) }
        if startedByFollowUpListening { jsonObject["startedByFollowUpListening"] = true }
        if let roundTripCacheCreationTokens { jsonObject["roundTripCacheCreationTokens"] = roundTripCacheCreationTokens }
        if let skippedFinalRequest { jsonObject["skippedFinalRequest"] = skippedFinalRequest }
        if let localFastPath { jsonObject["localFastPath"] = localFastPath }
        if let parallelToolCalls { jsonObject["parallelToolCalls"] = parallelToolCalls }
        if let turnId { jsonObject["turnId"] = turnId.uuidString }
        if let interruptedWithinMilliseconds { jsonObject["interruptedWithinMilliseconds"] = interruptedWithinMilliseconds }

        if let spokenReplyCharacterCount { jsonObject["spokenReplyCharacterCount"] = spokenReplyCharacterCount }
        if let skillCount { jsonObject["skillCount"] = skillCount }
        if let noteCount { jsonObject["noteCount"] = noteCount }
        if let usedPointing { jsonObject["usedPointing"] = usedPointing }
        if let skillCharacterCount { jsonObject["skillCharacterCount"] = skillCharacterCount }
        if let spotlightDrawn { jsonObject["spotlightDrawn"] = spotlightDrawn }
        if let walkthroughStep { jsonObject["walkthroughStep"] = walkthroughStep }
        if let walkthroughStepCount { jsonObject["walkthroughStepCount"] = walkthroughStepCount }
        if let pointSnapOutcome { jsonObject["pointSnapOutcome"] = pointSnapOutcome.rawValue }
        if let pointSnapDistancePoints { jsonObject["pointSnapDistancePoints"] = pointSnapDistancePoints }
        // Round 21b: written only when greater than zero, so a turn with no context keeps round 21's line.
        if let contextCharacterCount, contextCharacterCount > 0 { jsonObject["contextCharacterCount"] = contextCharacterCount }
        if let contextHiddenLineCount, contextHiddenLineCount > 0 { jsonObject["contextHiddenLineCount"] = contextHiddenLineCount }

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
        // Round 21: the skill text this turn carried, so an ordinary question can be seen to carry none.
        summaryLine += " skillCharacterCount \(countText(skillCharacterCount))"
        summaryLine += " notes \(countText(noteCount))"
        // Round 21b: the context's character count, only when a context was sent. A number, never a word of it.
        if let contextCharacterCount, contextCharacterCount > 0 {
            summaryLine += " ctx=\(contextCharacterCount)"
        }
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
        if let actionToolCallCount {
            // Counts and fixed identifiers only, never a name, link or label.
            summaryLine += " | actions: \(actionToolCallCount) calls, kinds \((actionKinds ?? []).map(\.rawValue).joined(separator: "/"))"
        }
        if startedByFollowUpListening {
            summaryLine += " | follow-up"
        }
        if let walkthroughStep, let walkthroughStepCount {
            summaryLine += " | walkthrough step \(walkthroughStep) of \(walkthroughStepCount)"
        }
        if let pointSnapOutcome {
            // Round 21: the fixed outcome word and the distance only, never the element's role.
            summaryLine += " | snap \(pointSnapOutcome.rawValue)" + (pointSnapDistancePoints.map { " \($0)pt" } ?? "")
        }
        if localFastPath == true {
            summaryLine += " | quick command"
        }
        if skippedFinalRequest == true {
            summaryLine += " | final request skipped"
        }
        if let parallelToolCalls {
            summaryLine += " | \(parallelToolCalls) calls in parallel"
        }
        if let interruptedWithinMilliseconds {
            summaryLine += " | escape after \(interruptedWithinMilliseconds)ms"
        }
        return summaryLine
    }
}

/// Remembers when the first piece of reply text arrived from Claude.
///
/// It is a class (not a local variable) because the text callback is a `@Sendable` closure, which
/// cannot mutate a captured local. Keeping the moment here also means a turn that fails after
/// some text arrived still knows its time to first text.
nonisolated final class EzraReplyTextArrivalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFirstReplyTextArrivalUptimeSeconds: TimeInterval?

    /// Safe to call on every chunk: only the first call is remembered.
    func markReplyTextArrived() {
        lock.lock()
        defer { lock.unlock() }
        if storedFirstReplyTextArrivalUptimeSeconds == nil {
            storedFirstReplyTextArrivalUptimeSeconds = EzraTurnMetrics.currentUptimeSeconds
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
nonisolated enum EzraTurnMetricsLog {
    /// After a rotation, only this many of the newest lines are kept.
    static let newestLineCountToKeep = 500
    /// The file is rewritten only once it grows past this many lines, so most turns just append.
    static let lineCountThatTriggersRotation = 600

    static var defaultLogFileURL: URL {
        let libraryDirectoryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return libraryDirectoryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Ezra", isDirectory: true)
            .appendingPathComponent("turn_metrics.jsonl")
    }

    /// File work runs on its own low-priority queue so the main thread never waits on disk.
    private static let backgroundWriteQueue = DispatchQueue(label: "com.ezra.turn-metrics-log", qos: .utility)

    /// What the app calls once per turn. Returns immediately; the write happens in the background.
    static func recordInBackground(_ turnMetrics: EzraTurnMetrics, to logFileURL: URL = defaultLogFileURL) {
        guard let jsonLine = turnMetrics.makeJSONLine() else { return }
        backgroundWriteQueue.async {
            appendLine(jsonLine, to: logFileURL)
        }
    }

    /// Same as `recordInBackground` but writes on the calling thread. Returns whether the line was
    /// written, so tests can wait for the result; the app ignores it.
    @discardableResult
    static func record(_ turnMetrics: EzraTurnMetrics, to logFileURL: URL = defaultLogFileURL) -> Bool {
        guard let jsonLine = turnMetrics.makeJSONLine() else { return false }
        return appendLine(jsonLine, to: logFileURL)
    }

    /// Not private so the dictation metrics log (`EzraDictationMetricsLog`) reuses the same
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
