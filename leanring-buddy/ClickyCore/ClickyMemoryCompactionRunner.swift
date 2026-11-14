import Foundation

// One compaction run and its metrics (round 16).
//
// `ClickyMemoryCompactionRunner` does the work for one chat in one step, with the network request
// passed in as a closure: decide what is new, build the request, read the answer, validate it, and
// store what is left. It changes no chat itself. It returns what happened, and the app marks the
// chat as covered only when the outcome says so, which is what makes a failed run still pending.

// MARK: - Metrics

/// How one compaction attempt ended, as a fixed identifier for the metrics.
nonisolated enum ClickyMemoryCompactionMetricsOutcome: String, Sendable {
    /// The model answered and the lines (possibly none) were stored. The chat is covered.
    case completed
    /// The request or the store failed. The chat stays pending.
    case failed
    /// The new exchange was too short, so no request was made. The chat is covered.
    case skipped
}

/// What is known about one compaction attempt: a trigger, an outcome, counts and durations.
///
/// Privacy rule, as strict as the dictation metrics: this type has no field that could hold a chat's
/// words, a memory's words, a chat's id or any part of them. Every value is a number or one of the
/// fixed identifiers, so no text can be added by accident.
nonisolated struct ClickyMemoryCompactionMetrics: Equatable, Sendable {
    let timestamp: Date
    let trigger: ClickyMemoryCompactionTrigger
    let outcome: ClickyMemoryCompactionMetricsOutcome
    /// How many exchanges the attempt covered.
    let exchangeCount: Int
    let memoriesKept: Int
    /// Nil when no request was made, and when the answer carried no usage report.
    let inputTokens: Int?
    let outputTokens: Int?
    let durationMilliseconds: Int?

    /// One JSON object on one line, keys sorted. Values that are unknown are left out.
    func makeJSONLine() -> String? {
        var jsonObject: [String: Any] = [
            "event": "memoryCompaction",
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "trigger": trigger.rawValue,
            "outcome": outcome.rawValue,
            "exchangeCount": exchangeCount,
            "memoriesKept": memoriesKept
        ]
        if let inputTokens { jsonObject["inputTokens"] = inputTokens }
        if let outputTokens { jsonObject["outputTokens"] = outputTokens }
        if let durationMilliseconds { jsonObject["durationMs"] = durationMilliseconds }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: jsonData, encoding: .utf8)
    }

    /// One compact line for the Xcode console. Numbers and identifiers only.
    func makeConsoleSummaryLine() -> String {
        var summaryLine = "🧠 memory compaction \(outcome.rawValue) (\(trigger.rawValue))"
        summaryLine += " | exchanges \(exchangeCount) | kept \(memoriesKept)"
        if let inputTokens, let outputTokens {
            summaryLine += " | tokens in \(inputTokens) out \(outputTokens)"
        }
        if let durationMilliseconds {
            summaryLine += " | \(durationMilliseconds)ms"
        }
        return summaryLine
    }
}

/// Appends one JSON line per compaction attempt to its own local file,
/// `memory_compaction_metrics.jsonl`, next to the other metrics logs. A separate file because the
/// lines have their own shape and the turn log is read by other tools (and so the usage tab can
/// never count one of these lines as a question). Failures are swallowed.
nonisolated enum ClickyMemoryCompactionMetricsLog {
    static var defaultLogFileURL: URL {
        ClickyTurnMetricsLog.defaultLogFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("memory_compaction_metrics.jsonl")
    }

    private static let backgroundWriteQueue = DispatchQueue(label: "com.clicky.memory-compaction-metrics-log", qos: .utility)

    /// What the app calls once per attempt. Returns at once; the write happens in the background.
    static func recordInBackground(_ metrics: ClickyMemoryCompactionMetrics, to logFileURL: URL = defaultLogFileURL) {
        guard let jsonLine = metrics.makeJSONLine() else { return }
        backgroundWriteQueue.async {
            ClickyTurnMetricsLog.appendLine(jsonLine, to: logFileURL)
        }
    }

    /// Same as `recordInBackground` but writes on the calling thread, so the quit path and tests can
    /// wait for it.
    @discardableResult
    static func record(_ metrics: ClickyMemoryCompactionMetrics, to logFileURL: URL = defaultLogFileURL) -> Bool {
        guard let jsonLine = metrics.makeJSONLine() else { return false }
        return ClickyTurnMetricsLog.appendLine(jsonLine, to: logFileURL)
    }
}

// MARK: - The run

/// What the request came back with: the model's text, or nil when there was none (offline, a
/// timeout, an error status, a reply that is not a Messages reply), and the tokens when reported.
nonisolated struct ClickyMemoryModelResponse: Equatable, Sendable {
    let modelText: String?
    let tokenUsage: ClickyMemoryCompactionTokenUsage?

    static let failed = ClickyMemoryModelResponse(modelText: nil, tokenUsage: nil)
}

/// What one run for one chat ended with. The app marks the chat as covered for `.completed` and
/// `.skippedAsTooShort` only; for `.failed` the chat is left as it was and stays pending.
nonisolated enum ClickyMemoryCompactionOutcome: Equatable, Sendable {
    case nothingNew
    case skippedAsTooShort(coveringExchangeCount: Int)
    case completed(coveringExchangeCount: Int, keptMemories: [ClickyMemory])
    case failed
}

nonisolated struct ClickyMemoryCompactionBatchResult: Equatable, Sendable {
    let outcome: ClickyMemoryCompactionOutcome
    /// Nil when nothing was new (no attempt happened, so nothing is logged).
    let metrics: ClickyMemoryCompactionMetrics?
}

nonisolated enum ClickyMemoryCompactionRunner {
    /// Compacts the next batch of the chat's new exchanges (see `ClickyMemoryCompactionPlanner`).
    ///
    /// - `sendRequestBody` makes the one request to the Worker with the JSON bytes it is given and
    ///   answers with the model's text (or `.failed`). It must never throw.
    /// - `loadProfileFactTexts` is asked once, before the request: the newest facts go into the
    ///   request's `<known>` list and the validator drops a line that repeats one. The app passes
    ///   a reader that prefers its in-memory copy, because the profile is in ~/Documents (iCloud)
    ///   and reading it from disk has stalled for seconds.
    /// - Memories are stored with the date of the chat's last compacted exchange and the chat's id.
    ///
    /// A failed request, an unwritable store or a request body that cannot be encoded gives
    /// `.failed`, so the chat stays pending. A model that answers NONE, nonsense or only secrets is a
    /// success with no memories: asking again would give the same answer.
    static func compactNextBatch(
        of chat: ClickyChat,
        trigger: ClickyMemoryCompactionTrigger,
        systemPromptText: String,
        memoryStore: ClickyMemoryStore,
        loadProfileFactTexts: @Sendable () -> [String],
        sendRequestBody: @Sendable (Data) async -> ClickyMemoryModelResponse,
        now: Date = Date()
    ) async -> ClickyMemoryCompactionBatchResult {
        switch ClickyMemoryCompactionPlanner.decision(for: chat) {
        case .nothingNew:
            return ClickyMemoryCompactionBatchResult(outcome: .nothingNew, metrics: nil)

        case .skippedAsTooShort(let coveringExchangeCount):
            let metrics = ClickyMemoryCompactionMetrics(
                timestamp: now,
                trigger: trigger,
                outcome: .skipped,
                exchangeCount: 1,
                memoriesKept: 0,
                inputTokens: nil,
                outputTokens: nil,
                durationMilliseconds: nil
            )
            return ClickyMemoryCompactionBatchResult(
                outcome: .skippedAsTooShort(coveringExchangeCount: coveringExchangeCount),
                metrics: metrics
            )

        case .compact(let exchanges, let coveringExchangeCount):
            func failedResult(tokenUsage: ClickyMemoryCompactionTokenUsage?, durationMilliseconds: Int?) -> ClickyMemoryCompactionBatchResult {
                ClickyMemoryCompactionBatchResult(
                    outcome: .failed,
                    metrics: ClickyMemoryCompactionMetrics(
                        timestamp: now,
                        trigger: trigger,
                        outcome: .failed,
                        exchangeCount: exchanges.count,
                        memoriesKept: 0,
                        inputTokens: tokenUsage?.inputTokens,
                        outputTokens: tokenUsage?.outputTokens,
                        durationMilliseconds: durationMilliseconds
                    )
                )
            }

            // What Clicky already knows is read before the request: it goes into the request (so
            // the model does not write it again in other words) and the validator checks the answer
            // against it afterwards.
            let existingProfileFactTexts = loadProfileFactTexts()
            let knownTexts = ClickyMemoryCompaction.knownTexts(
                profileFactTexts: existingProfileFactTexts,
                memories: memoryStore.loadMemories(),
                forExchanges: exchanges,
                now: now
            )
            let requestBody = ClickyMemoryCompaction.makeRequestBody(
                forExchanges: exchanges,
                knownTexts: knownTexts,
                systemPromptText: systemPromptText
            )
            guard let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
                return failedResult(tokenUsage: nil, durationMilliseconds: nil)
            }

            let requestStartedUptimeSeconds = ProcessInfo.processInfo.systemUptime
            let modelResponse = await sendRequestBody(requestBodyData)
            let durationMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - requestStartedUptimeSeconds) * 1_000).rounded())

            guard let modelText = modelResponse.modelText else {
                return failedResult(tokenUsage: modelResponse.tokenUsage, durationMilliseconds: durationMilliseconds)
            }

            // The memories are read again: one may have been deleted in the panel meanwhile.
            let validationResult = ClickyMemoryOutputValidator.validate(
                modelOutput: modelText,
                existingMemoryTexts: memoryStore.loadMemories().map(\.text),
                existingProfileFactTexts: existingProfileFactTexts
            )
            // The lines share the day of the chat they came from, and the chat's id.
            let memoriesCreatedAt = exchanges.last?.timestamp ?? now
            switch memoryStore.addMemories(texts: validationResult.keptTexts, sourceChatID: chat.id, createdAt: memoriesCreatedAt) {
            case .failed:
                return failedResult(tokenUsage: modelResponse.tokenUsage, durationMilliseconds: durationMilliseconds)
            case .added(let addedMemories, _):
                return ClickyMemoryCompactionBatchResult(
                    outcome: .completed(coveringExchangeCount: coveringExchangeCount, keptMemories: addedMemories),
                    metrics: ClickyMemoryCompactionMetrics(
                        timestamp: now,
                        trigger: trigger,
                        outcome: .completed,
                        exchangeCount: exchanges.count,
                        memoriesKept: addedMemories.count,
                        inputTokens: modelResponse.tokenUsage?.inputTokens,
                        outputTokens: modelResponse.tokenUsage?.outputTokens,
                        durationMilliseconds: durationMilliseconds
                    )
                )
            }
        }
    }
}
