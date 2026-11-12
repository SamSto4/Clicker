import Foundation

// The usage tab of the chat panel (round 15): reads the two local metrics logs
// (`turn_metrics.jsonl` and `dictation_metrics.jsonl`) and works out, for today and for this month,
// how many questions were asked, how fast they were answered, and how many tokens they used with an
// estimated price. Everything here is pure except `ClickyUsageLogReader`, which only reads files.
// Round 16 adds a third log, `memory_compaction_metrics.jsonl`, for the "memories" row.
//
// All the logs hold numbers and fixed identifiers only (no transcript, reply, note or memory
// text), so nothing read here can show the user's words.

// MARK: - Prices

/// US dollars per million tokens for one model.
nonisolated struct ClickyModelPrice: Equatable, Sendable {
    let inputDollarsPerMillionTokens: Decimal
    let outputDollarsPerMillionTokens: Decimal
    let cacheReadDollarsPerMillionTokens: Decimal
    /// The price of writing tokens to the 5-minute prompt cache, which is the cache Clicky uses.
    let cacheWriteDollarsPerMillionTokens: Decimal
}

/// The price table.
///
/// US dollars per million tokens, taken from Anthropic's model documentation as of November 2026.
/// Cache writes cost 1.25 times the input price (for the 5-minute cache the app uses).
///
///     model               input   output   cache read   cache write
///     claude-sonnet-5-5   $2      $10      $0.20        $2.50
///     claude-opus-5-5     $4      $20      $0.20        $5.00
///     claude-haiku-5-5    $0.10   $0.50    $0.01        $0.125
///
/// The Haiku prices are the ones for prompts of 100K tokens or fewer, which covers every prompt
/// Clicky sends (the dictation cleanup is a few hundred tokens).
///
/// A model that is not in this table has no price here, and the usage tab says "price unknown"
/// for it instead of guessing one. Today that includes the panel's Opus choice, `claude-opus-4-6`.
///
/// The numbers are `Decimal`, never `Double`, so a price such as $0.125 and a sum of many small
/// costs stay exact.
nonisolated enum ClickyModelPriceTable {
    static let pricesByModelName: [String: ClickyModelPrice] = [
        "claude-sonnet-5-5": ClickyModelPrice(
            inputDollarsPerMillionTokens: dollars("2"),
            outputDollarsPerMillionTokens: dollars("10"),
            cacheReadDollarsPerMillionTokens: dollars("0.20"),
            cacheWriteDollarsPerMillionTokens: dollars("2.50")
        ),
        "claude-opus-5-5": ClickyModelPrice(
            inputDollarsPerMillionTokens: dollars("4"),
            outputDollarsPerMillionTokens: dollars("20"),
            cacheReadDollarsPerMillionTokens: dollars("0.20"),
            cacheWriteDollarsPerMillionTokens: dollars("5.00")
        ),
        "claude-haiku-5-5": ClickyModelPrice(
            inputDollarsPerMillionTokens: dollars("0.10"),
            outputDollarsPerMillionTokens: dollars("0.50"),
            cacheReadDollarsPerMillionTokens: dollars("0.01"),
            cacheWriteDollarsPerMillionTokens: dollars("0.125")
        ),
    ]

    static func price(forModelName modelName: String) -> ClickyModelPrice? {
        pricesByModelName[modelName]
    }

    /// The estimated cost in US dollars, or nil when the model has no price in the table.
    static func estimatedCostInDollars(
        modelName: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheWriteTokens: Int,
        cacheReadTokens: Int
    ) -> Decimal? {
        guard let modelPrice = price(forModelName: modelName) else {
            return nil
        }
        let tokensPerMillion = Decimal(1_000_000)
        let inputCost = Decimal(inputTokens) * modelPrice.inputDollarsPerMillionTokens / tokensPerMillion
        let outputCost = Decimal(outputTokens) * modelPrice.outputDollarsPerMillionTokens / tokensPerMillion
        let cacheWriteCost = Decimal(cacheWriteTokens) * modelPrice.cacheWriteDollarsPerMillionTokens / tokensPerMillion
        let cacheReadCost = Decimal(cacheReadTokens) * modelPrice.cacheReadDollarsPerMillionTokens / tokensPerMillion
        return inputCost + outputCost + cacheWriteCost + cacheReadCost
    }

    /// `Decimal(floatLiteral:)` goes through `Double` and would make 0.20 slightly wrong, so the
    /// prices are written as text.
    private static func dollars(_ dollarsText: String) -> Decimal {
        Decimal(string: dollarsText, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }
}

// MARK: - Log records

/// One line of `turn_metrics.jsonl`, reduced to what the usage tab needs.
nonisolated struct ClickyUsageTurnRecord: Equatable, Sendable {
    let timestamp: Date
    let modelName: String
    let inputMode: ClickyTurnInputMode
    let outcome: ClickyTurnOutcome
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    /// Key release until the audio started (spoken turns only).
    let keyReleaseToAudioStartMilliseconds: Int?
    /// From the request to Claude until the first reply text arrived (what a typed turn waits).
    let timeToFirstReplyTextMilliseconds: Int?
    let spokenReplyCharacterCount: Int?
    /// True when audio started playing: only then did the reply cost voice characters. A reply that
    /// was only shown as text (typed, or "speak replies" off) carries `spokenReplyCharacterCount`
    /// as well, because the count is taken before the speech step, so the count alone is not enough.
    let audioStartedPlaying: Bool

    var hasAnyTokenCount: Bool {
        inputTokens != nil || outputTokens != nil || cacheCreationInputTokens != nil || cacheReadInputTokens != nil
    }
}

/// One line of `dictation_metrics.jsonl`.
nonisolated struct ClickyUsageDictationRecord: Equatable, Sendable {
    let timestamp: Date
    /// The cleanup's outcome identifier (`used`, `timeout`, `failed`, `rejectedLength`, `skipped`).
    let cleanupOutcome: String?
    /// The tokens of the cleanup request. Nil on lines written before round 15, and when the request
    /// gave no answer.
    let cleanupInputTokens: Int?
    let cleanupOutputTokens: Int?

    /// True when the cleanup request probably cost tokens that were not logged: it was made (the
    /// outcome says so) but no count came back or was recorded. A dictation whose cleanup was
    /// skipped made no request, so there is nothing unknown about it.
    var cleanupTokenCountIsUnknown: Bool {
        guard cleanupInputTokens == nil && cleanupOutputTokens == nil else {
            return false
        }
        switch cleanupOutcome {
        case ClickyDictationCleanupOutcome.used.rawValue,
             ClickyDictationCleanupOutcome.rejectedLength.rawValue,
             ClickyDictationCleanupOutcome.timeout.rawValue,
             ClickyDictationCleanupOutcome.failed.rawValue:
            return true
        default:
            return false
        }
    }
}

/// One line of `memory_compaction_metrics.jsonl` (round 16).
nonisolated struct ClickyUsageMemoryCompactionRecord: Equatable, Sendable {
    let timestamp: Date
    /// The outcome identifier (`completed`, `failed`, `skipped`).
    let outcome: String?
    let memoriesKept: Int
    /// The tokens of the request. Nil when no request was made or the answer had no usage report.
    let inputTokens: Int?
    let outputTokens: Int?
}

/// Reads one line of a log. A line that is not a JSON object, or has no readable timestamp, gives
/// nil and is skipped: a log cut short in the middle of its last line, or edited by hand, must
/// never stop the usage tab.
nonisolated enum ClickyUsageLogParser {
    static func parseTurnRecord(fromLine logLine: String) -> ClickyUsageTurnRecord? {
        guard let jsonObject = jsonObject(fromLine: logLine),
              (jsonObject["event"] as? String) != "dictation",
              // Round 16: a memory compaction line has its own file, but if one ever lands here it is
              // not a question.
              (jsonObject["event"] as? String) != "memoryCompaction",
              let timestamp = timestamp(from: jsonObject["timestamp"]) else {
            return nil
        }
        // Lines written before round 13 have no input mode, and every one of them was spoken.
        let inputMode = (jsonObject["inputMode"] as? String).flatMap(ClickyTurnInputMode.init(rawValue:)) ?? .spoken
        let outcome = (jsonObject["outcome"] as? String).flatMap(ClickyTurnOutcome.init(rawValue:)) ?? .completed
        return ClickyUsageTurnRecord(
            timestamp: timestamp,
            modelName: (jsonObject["model"] as? String) ?? "unknown",
            inputMode: inputMode,
            outcome: outcome,
            inputTokens: nonNegativeInteger(jsonObject["inputTokens"]),
            outputTokens: nonNegativeInteger(jsonObject["outputTokens"]),
            cacheCreationInputTokens: nonNegativeInteger(jsonObject["cacheCreationInputTokens"]),
            cacheReadInputTokens: nonNegativeInteger(jsonObject["cacheReadInputTokens"]),
            keyReleaseToAudioStartMilliseconds: nonNegativeInteger(jsonObject["keyReleaseToAudioStartMs"]),
            timeToFirstReplyTextMilliseconds: nonNegativeInteger(jsonObject["timeToFirstReplyTextMs"]),
            spokenReplyCharacterCount: nonNegativeInteger(jsonObject["spokenReplyCharacterCount"]),
            audioStartedPlaying: nonNegativeInteger(jsonObject["textToSpeechMs"]) != nil
        )
    }

    static func parseDictationRecord(fromLine logLine: String) -> ClickyUsageDictationRecord? {
        guard let jsonObject = jsonObject(fromLine: logLine),
              (jsonObject["event"] as? String) == "dictation",
              let timestamp = timestamp(from: jsonObject["timestamp"]) else {
            return nil
        }
        return ClickyUsageDictationRecord(
            timestamp: timestamp,
            cleanupOutcome: jsonObject["cleanupOutcome"] as? String,
            cleanupInputTokens: nonNegativeInteger(jsonObject["cleanupInputTokens"]),
            cleanupOutputTokens: nonNegativeInteger(jsonObject["cleanupOutputTokens"])
        )
    }

    static func parseMemoryCompactionRecord(fromLine logLine: String) -> ClickyUsageMemoryCompactionRecord? {
        guard let jsonObject = jsonObject(fromLine: logLine),
              (jsonObject["event"] as? String) == "memoryCompaction",
              let timestamp = timestamp(from: jsonObject["timestamp"]) else {
            return nil
        }
        return ClickyUsageMemoryCompactionRecord(
            timestamp: timestamp,
            outcome: jsonObject["outcome"] as? String,
            memoriesKept: nonNegativeInteger(jsonObject["memoriesKept"]) ?? 0,
            inputTokens: nonNegativeInteger(jsonObject["inputTokens"]),
            outputTokens: nonNegativeInteger(jsonObject["outputTokens"])
        )
    }

    private static func jsonObject(fromLine logLine: String) -> [String: Any]? {
        let trimmedLine = logLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("{"),
              let lineData = trimmedLine.data(using: .utf8),
              let parsedObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }
        return parsedObject
    }

    /// The logs write ISO 8601 dates ("2026-11-12T14:30:00Z"); a line with fractional seconds is
    /// read too.
    private static func timestamp(from timestampValue: Any?) -> Date? {
        guard let timestampText = timestampValue as? String else {
            return nil
        }
        let plainFormatter = ISO8601DateFormatter()
        if let plainDate = plainFormatter.date(from: timestampText) {
            return plainDate
        }
        let fractionalSecondsFormatter = ISO8601DateFormatter()
        fractionalSecondsFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalSecondsFormatter.date(from: timestampText)
    }

    /// A count or a duration. A negative number, a boolean, text or a number too large to be a
    /// real count is nil, so one bad field costs only itself.
    private static func nonNegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue >= 0, doubleValue < 1e15 else {
            return nil
        }
        return Int(doubleValue)
    }
}

// MARK: - Summary

/// Tokens used with one model in one period.
nonisolated struct ClickyModelUsage: Equatable, Sendable {
    let modelName: String
    /// Requests whose tokens were logged.
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }

    /// Nil when the model is not in the price table ("price unknown").
    var estimatedCostInDollars: Decimal? {
        ClickyModelPriceTable.estimatedCostInDollars(
            modelName: modelName,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheWriteTokens: cacheWriteTokens,
            cacheReadTokens: cacheReadTokens
        )
    }
}

/// What the memory compaction used in one period (round 16): chats compacted, memories kept and
/// the tokens of the requests, costed at the price of the model that makes them (Haiku).
nonisolated struct ClickyMemoryCompactionUsage: Equatable, Sendable {
    /// Attempts that finished: the model answered and the lines were stored (possibly none).
    var compactionCount = 0
    var memoriesKeptCount = 0
    var inputTokens = 0
    var outputTokens = 0

    var hasAnything: Bool {
        compactionCount > 0 || inputTokens > 0 || outputTokens > 0
    }

    /// Nil only if the model were missing from the price table.
    var estimatedCostInDollars: Decimal? {
        ClickyModelPriceTable.estimatedCostInDollars(
            modelName: ClickyMemoryCompaction.modelName,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheWriteTokens: 0,
            cacheReadTokens: 0
        )
    }
}

/// Everything the usage tab shows for one period (today, or this month).
nonisolated struct ClickyUsagePeriodSummary: Equatable, Sendable {
    /// Every turn counts as a question asked, whether it finished, failed or was cancelled.
    var questionCount = 0
    var spokenQuestionCount = 0
    var typedQuestionCount = 0
    var failedQuestionCount = 0
    var dictationCount = 0

    /// The median wait from releasing the ask keys to the first spoken word, over the spoken turns
    /// that have the number. Nil when there are none.
    var medianMillisecondsFromKeyReleaseToFirstSpokenWord: Int?
    var spokenTurnsMeasuredCount = 0
    /// The median wait to the first reply text of typed turns.
    var medianMillisecondsToFirstReplyTextOfTypedTurns: Int?
    var typedTurnsMeasuredCount = 0

    /// The characters of replies whose audio started playing.
    var voiceCharactersSpoken = 0

    /// Tokens per model, the model with the most tokens first.
    var modelUsages: [ClickyModelUsage] = []
    /// Dictations whose cleanup request probably used tokens that were never logged (older lines).
    var dictationsWithUnknownTokenCountsCount = 0
    /// The memory compaction's own row (round 16). Its tokens are not in `modelUsages`, so they are
    /// never counted twice.
    var memoryCompaction = ClickyMemoryCompactionUsage()

    /// The sum of the estimated costs of the models that have a price, in US dollars. Models
    /// without a price are not in it (`modelUsagesWithoutPriceCount` says how many).
    var estimatedCostInDollarsOfPricedModels: Decimal {
        modelUsages.reduce(Decimal(0)) { runningTotal, modelUsage in
            runningTotal + (modelUsage.estimatedCostInDollars ?? 0)
        }
    }

    var modelUsagesWithoutPriceCount: Int {
        modelUsages.filter { $0.estimatedCostInDollars == nil }.count
    }

    /// The names of the models that have no price in the table, in the order they are listed.
    var modelsWithoutPriceNames: [String] {
        modelUsages.filter { $0.estimatedCostInDollars == nil }.map(\.modelName)
    }
}

nonisolated struct ClickyUsageSummary: Equatable, Sendable {
    let today: ClickyUsagePeriodSummary
    let thisMonth: ClickyUsagePeriodSummary
    let startOfMonth: Date
    /// The date of the oldest line the turn log still holds. The log keeps only its newest 500
    /// lines, so a busy month can be partly gone.
    let oldestTurnLineDate: Date?
    let oldestDictationLineDate: Date?
    /// Set when the turn log's oldest line is on a later day than the first of the month: the
    /// month's figures then count only from that day on, and the tab says "since <date>". Nil when
    /// the log reaches back to the first of the month (or further), and when it is empty.
    let turnLogMonthFiguresStartDate: Date?
    /// The same for the dictation log, which is kept short in the same way.
    let dictationLogMonthFiguresStartDate: Date?
    /// Lines that could not be read and were skipped.
    let skippedTurnLineCount: Int
    let skippedDictationLineCount: Int
}

nonisolated enum ClickyUsageAggregator {
    /// Reads both logs' lines and sums them up. `now` and `calendar` are passed in so the day and
    /// the month are the user's local ones and a test can pick its own.
    static func summarize(
        turnLogLines: [String],
        dictationLogLines: [String],
        memoryCompactionLogLines: [String] = [],
        now: Date,
        calendar: Calendar = .current
    ) -> ClickyUsageSummary {
        var turnRecords: [ClickyUsageTurnRecord] = []
        var skippedTurnLineCount = 0
        for turnLogLine in turnLogLines where !turnLogLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let turnRecord = ClickyUsageLogParser.parseTurnRecord(fromLine: turnLogLine) {
                turnRecords.append(turnRecord)
            } else {
                skippedTurnLineCount += 1
            }
        }

        var dictationRecords: [ClickyUsageDictationRecord] = []
        var skippedDictationLineCount = 0
        for dictationLogLine in dictationLogLines where !dictationLogLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let dictationRecord = ClickyUsageLogParser.parseDictationRecord(fromLine: dictationLogLine) {
                dictationRecords.append(dictationRecord)
            } else {
                skippedDictationLineCount += 1
            }
        }

        // Lines of the memory compaction log that cannot be read are skipped without a word: the log
        // only feeds one row.
        let memoryCompactionRecords = memoryCompactionLogLines.compactMap { memoryCompactionLogLine in
            ClickyUsageLogParser.parseMemoryCompactionRecord(fromLine: memoryCompactionLogLine)
        }

        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let oldestTurnLineDate = turnRecords.map(\.timestamp).min()
        let oldestDictationLineDate = dictationRecords.map(\.timestamp).min()
        return ClickyUsageSummary(
            today: periodSummary(
                turnRecords: turnRecords.filter { calendar.isDate($0.timestamp, inSameDayAs: now) },
                dictationRecords: dictationRecords.filter { calendar.isDate($0.timestamp, inSameDayAs: now) },
                memoryCompactionRecords: memoryCompactionRecords.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
            ),
            thisMonth: periodSummary(
                turnRecords: turnRecords.filter { calendar.isDate($0.timestamp, equalTo: now, toGranularity: .month) },
                dictationRecords: dictationRecords.filter { calendar.isDate($0.timestamp, equalTo: now, toGranularity: .month) },
                memoryCompactionRecords: memoryCompactionRecords.filter { calendar.isDate($0.timestamp, equalTo: now, toGranularity: .month) }
            ),
            startOfMonth: startOfMonth,
            oldestTurnLineDate: oldestTurnLineDate,
            oldestDictationLineDate: oldestDictationLineDate,
            turnLogMonthFiguresStartDate: monthFiguresStartDate(oldestLineDate: oldestTurnLineDate, startOfMonth: startOfMonth, calendar: calendar),
            dictationLogMonthFiguresStartDate: monthFiguresStartDate(oldestLineDate: oldestDictationLineDate, startOfMonth: startOfMonth, calendar: calendar),
            skippedTurnLineCount: skippedTurnLineCount,
            skippedDictationLineCount: skippedDictationLineCount
        )
    }

    /// The oldest line's date when it is on a later day than the first of the month, else nil.
    private static func monthFiguresStartDate(oldestLineDate: Date?, startOfMonth: Date, calendar: Calendar) -> Date? {
        guard let oldestLineDate, calendar.startOfDay(for: oldestLineDate) > startOfMonth else {
            return nil
        }
        return oldestLineDate
    }

    static func periodSummary(
        turnRecords: [ClickyUsageTurnRecord],
        dictationRecords: [ClickyUsageDictationRecord],
        memoryCompactionRecords: [ClickyUsageMemoryCompactionRecord] = []
    ) -> ClickyUsagePeriodSummary {
        var periodSummary = ClickyUsagePeriodSummary()
        var tokenTotalsByModelName: [String: ClickyModelUsage] = [:]

        func addTokens(
            modelName: String,
            inputTokens: Int,
            outputTokens: Int,
            cacheWriteTokens: Int,
            cacheReadTokens: Int
        ) {
            let existingUsage = tokenTotalsByModelName[modelName]
            tokenTotalsByModelName[modelName] = ClickyModelUsage(
                modelName: modelName,
                requestCount: (existingUsage?.requestCount ?? 0) + 1,
                inputTokens: (existingUsage?.inputTokens ?? 0) + inputTokens,
                outputTokens: (existingUsage?.outputTokens ?? 0) + outputTokens,
                cacheWriteTokens: (existingUsage?.cacheWriteTokens ?? 0) + cacheWriteTokens,
                cacheReadTokens: (existingUsage?.cacheReadTokens ?? 0) + cacheReadTokens
            )
        }

        var millisecondsToFirstSpokenWord: [Int] = []
        var millisecondsToFirstReplyTextOfTypedTurns: [Int] = []

        for turnRecord in turnRecords {
            periodSummary.questionCount += 1
            if turnRecord.outcome == .failed {
                periodSummary.failedQuestionCount += 1
            }
            switch turnRecord.inputMode {
            case .spoken:
                periodSummary.spokenQuestionCount += 1
                if let keyReleaseToAudioStartMilliseconds = turnRecord.keyReleaseToAudioStartMilliseconds {
                    millisecondsToFirstSpokenWord.append(keyReleaseToAudioStartMilliseconds)
                }
            case .typed:
                periodSummary.typedQuestionCount += 1
                if let timeToFirstReplyTextMilliseconds = turnRecord.timeToFirstReplyTextMilliseconds {
                    millisecondsToFirstReplyTextOfTypedTurns.append(timeToFirstReplyTextMilliseconds)
                }
            }
            if turnRecord.audioStartedPlaying {
                periodSummary.voiceCharactersSpoken += turnRecord.spokenReplyCharacterCount ?? 0
            }
            // A missing count is zero tokens, not an unknown: the request that never started (a
            // failed screenshot) or never got that far used none.
            if turnRecord.hasAnyTokenCount {
                addTokens(
                    modelName: turnRecord.modelName,
                    inputTokens: turnRecord.inputTokens ?? 0,
                    outputTokens: turnRecord.outputTokens ?? 0,
                    cacheWriteTokens: turnRecord.cacheCreationInputTokens ?? 0,
                    cacheReadTokens: turnRecord.cacheReadInputTokens ?? 0
                )
            }
        }

        for dictationRecord in dictationRecords {
            periodSummary.dictationCount += 1
            if dictationRecord.cleanupInputTokens != nil || dictationRecord.cleanupOutputTokens != nil {
                // The cleanup request always goes to the same model, which is not written on the line.
                addTokens(
                    modelName: ClickyDictationCleanup.modelName,
                    inputTokens: dictationRecord.cleanupInputTokens ?? 0,
                    outputTokens: dictationRecord.cleanupOutputTokens ?? 0,
                    cacheWriteTokens: 0,
                    cacheReadTokens: 0
                )
            } else if dictationRecord.cleanupTokenCountIsUnknown {
                periodSummary.dictationsWithUnknownTokenCountsCount += 1
            }
        }

        for memoryCompactionRecord in memoryCompactionRecords {
            if memoryCompactionRecord.outcome == ClickyMemoryCompactionMetricsOutcome.completed.rawValue {
                periodSummary.memoryCompaction.compactionCount += 1
                periodSummary.memoryCompaction.memoriesKeptCount += memoryCompactionRecord.memoriesKept
            }
            // A request whose answer could not be stored still used tokens, so they count either way.
            periodSummary.memoryCompaction.inputTokens += memoryCompactionRecord.inputTokens ?? 0
            periodSummary.memoryCompaction.outputTokens += memoryCompactionRecord.outputTokens ?? 0
        }

        periodSummary.medianMillisecondsFromKeyReleaseToFirstSpokenWord = median(of: millisecondsToFirstSpokenWord)
        periodSummary.spokenTurnsMeasuredCount = millisecondsToFirstSpokenWord.count
        periodSummary.medianMillisecondsToFirstReplyTextOfTypedTurns = median(of: millisecondsToFirstReplyTextOfTypedTurns)
        periodSummary.typedTurnsMeasuredCount = millisecondsToFirstReplyTextOfTypedTurns.count
        periodSummary.modelUsages = tokenTotalsByModelName.values.sorted { firstUsage, secondUsage in
            if firstUsage.totalTokens != secondUsage.totalTokens {
                return firstUsage.totalTokens > secondUsage.totalTokens
            }
            return firstUsage.modelName < secondUsage.modelName
        }
        return periodSummary
    }

    /// The middle value of the sorted numbers. With an even count it is the mean of the two middle
    /// ones, rounded to the nearest millisecond with halves rounded up ([100, 201] gives 151).
    /// Nil when there are no numbers.
    static func median(of values: [Int]) -> Int? {
        guard !values.isEmpty else {
            return nil
        }
        let sortedValues = values.sorted()
        let middleIndex = sortedValues.count / 2
        if sortedValues.count % 2 == 1 {
            return sortedValues[middleIndex]
        }
        let sumOfTwoMiddleValues = sortedValues[middleIndex - 1] + sortedValues[middleIndex]
        return (sumOfTwoMiddleValues + 1) / 2
    }
}

// MARK: - Reading the files

/// Reads the two logs from a folder. Only this type touches the disk; it never writes, and a missing
/// or unreadable file is an empty log.
nonisolated enum ClickyUsageLogReader {
    static var turnLogFileName: String {
        ClickyTurnMetricsLog.defaultLogFileURL.lastPathComponent
    }

    static var dictationLogFileName: String {
        ClickyDictationMetricsLog.defaultLogFileURL.lastPathComponent
    }

    static var memoryCompactionLogFileName: String {
        ClickyMemoryCompactionMetricsLog.defaultLogFileURL.lastPathComponent
    }

    static func lines(inFileAt logFileURL: URL) -> [String] {
        guard let logFileData = try? Data(contentsOf: logFileURL) else {
            return []
        }
        return String(decoding: logFileData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    static func loadSummary(
        metricsDirectoryURL: URL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ClickyUsageSummary {
        ClickyUsageAggregator.summarize(
            turnLogLines: lines(inFileAt: metricsDirectoryURL.appendingPathComponent(turnLogFileName)),
            dictationLogLines: lines(inFileAt: metricsDirectoryURL.appendingPathComponent(dictationLogFileName)),
            memoryCompactionLogLines: lines(inFileAt: metricsDirectoryURL.appendingPathComponent(memoryCompactionLogFileName)),
            now: now,
            calendar: calendar
        )
    }
}

// MARK: - Words

/// How the usage tab writes its numbers. Lowercase, like every other word Clicky shows.
nonisolated enum ClickyUsageText {
    /// "842", "12.3k", "123k", "2.4M". A trailing ".0" is left out.
    static func compactTokenCountText(_ count: Int) -> String {
        if count < 1_000 {
            return String(count)
        }
        if count < 1_000_000 {
            let thousands = Double(count) / 1_000
            let thousandsText = thousands < 100 ? String(format: "%.1f", thousands) : String(format: "%.0f", thousands)
            // 999,950 rounds to "1000.0": that is a million, not a thousand thousands.
            if thousandsText.hasPrefix("1000") {
                return "1M"
            }
            return withoutTrailingPointZero(thousandsText) + "k"
        }
        let millions = Double(count) / 1_000_000
        let millionsText = millions < 100 ? String(format: "%.1f", millions) : String(format: "%.0f", millions)
        return withoutTrailingPointZero(millionsText) + "M"
    }

    /// "1,240": a whole number with thousands separators, for the voice characters.
    static func separatedCountText(_ count: Int) -> String {
        let countFormatter = NumberFormatter()
        countFormatter.numberStyle = .decimal
        countFormatter.locale = Locale(identifier: "en_US_POSIX")
        countFormatter.groupingSeparator = ","
        countFormatter.usesGroupingSeparator = true
        return countFormatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    /// "820 ms", "1.4 s", or a dash when there is no number.
    static func durationText(milliseconds: Int?) -> String {
        guard let milliseconds else {
            return "–"
        }
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        return String(format: "%.1f s", Double(milliseconds) / 1_000)
    }

    /// "est. $0.034" under a dollar (three decimals, rounded half up), "est. $1.27" from a dollar
    /// up (cents), "est. <$0.001" for a few tokens, and "price unknown" when the model has no
    /// price in the table. Every amount says "est." because it is worked out from list prices.
    static func estimatedCostText(dollars: Decimal?) -> String {
        guard let dollars else {
            return "price unknown"
        }
        if dollars > 0 && dollars < Decimal(string: "0.0005", locale: Locale(identifier: "en_US_POSIX"))! {
            return "est. <$0.001"
        }
        // 0.9996 rounds to 1.000 at three places, which should read as "$1.00", so the choice of
        // places is made on the rounded amount.
        var unroundedDollars = dollars
        var dollarsRoundedToThousandths = Decimal()
        NSDecimalRound(&dollarsRoundedToThousandths, &unroundedDollars, 3, .plain)
        let decimalPlaces = dollarsRoundedToThousandths < 1 ? 3 : 2
        return "est. $" + dollarsText(dollars, decimalPlaces: decimalPlaces)
    }

    /// The dollars rounded half up to the given decimal places, as text with exactly that many.
    static func dollarsText(_ dollars: Decimal, decimalPlaces: Int) -> String {
        var unroundedDollars = dollars
        var roundedDollars = Decimal()
        NSDecimalRound(&roundedDollars, &unroundedDollars, decimalPlaces, .plain)
        let dollarsFormatter = NumberFormatter()
        dollarsFormatter.numberStyle = .decimal
        dollarsFormatter.locale = Locale(identifier: "en_US_POSIX")
        dollarsFormatter.usesGroupingSeparator = false
        dollarsFormatter.minimumFractionDigits = decimalPlaces
        dollarsFormatter.maximumFractionDigits = decimalPlaces
        return dollarsFormatter.string(from: NSDecimalNumber(decimal: roundedDollars)) ?? "\(roundedDollars)"
    }

    /// "since 8 nov": where a log that is shorter than the month starts.
    static func sinceDateText(_ date: Date, calendar: Calendar = .current) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "d MMM"
        return "since " + dateFormatter.string(from: date).lowercased()
    }

    private static func withoutTrailingPointZero(_ numberText: String) -> String {
        numberText.hasSuffix(".0") ? String(numberText.dropLast(2)) : numberText
    }
}
