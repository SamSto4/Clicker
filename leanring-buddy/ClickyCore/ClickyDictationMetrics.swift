import Foundation

/// What is known about one dictation: durations, a flag and fixed outcome identifiers.
///
/// Privacy rule, stricter than the turn metrics: dictated words are the user's own text going into
/// another app, so this type has no field that could hold the transcript, the cleaned text, any
/// part of either, or even their lengths, and nothing about the app or the text field. Every
/// value is a number, a flag or one of the outcome enums.
nonisolated struct ClickyDictationMetrics: Equatable {
    let startedAt: Date

    /// How long the microphone was capturing, from the start of capture until it was stopped.
    var audioSeconds: Double?
    /// From the keys being released until the final transcript was ready.
    var releaseToTranscriptMilliseconds: Int?
    /// How long the cleanup request took (or waited before timing out). Nil when none was made.
    var cleanupMilliseconds: Int?
    /// From the keys being released until the text was pasted or placed on the clipboard.
    var releaseToInsertMilliseconds: Int?
    /// Nil when the dictation ended before the cleanup step was reached.
    var cleanupOutcome: ClickyDictationCleanupOutcome?
    /// The tokens the cleanup request used, as numbers only (this type keeps no text). Nil when no
    /// request was made, when it gave no answer, and on every line written before round 15, which
    /// the usage tab counts as unknown.
    var cleanupInputTokens: Int?
    var cleanupOutputTokens: Int?
    var insertionOutcome: ClickyDictationInsertionOutcome
    var wasHandsFree: Bool

    init(startedAt: Date, insertionOutcome: ClickyDictationInsertionOutcome, wasHandsFree: Bool) {
        self.startedAt = startedAt
        self.insertionOutcome = insertionOutcome
        self.wasHandsFree = wasHandsFree
    }

    /// One JSON object on one line, keys sorted. Steps that were never reached are left out.
    func makeJSONLine() -> String? {
        var jsonObject: [String: Any] = [
            "event": "dictation",
            "timestamp": ISO8601DateFormatter().string(from: startedAt),
            "insertionOutcome": insertionOutcome.rawValue,
            "handsFree": wasHandsFree
        ]

        if let audioSeconds { jsonObject["audioSeconds"] = (audioSeconds * 10).rounded() / 10 }
        if let releaseToTranscriptMilliseconds { jsonObject["releaseToTranscriptMs"] = releaseToTranscriptMilliseconds }
        if let cleanupMilliseconds { jsonObject["cleanupMs"] = cleanupMilliseconds }
        if let releaseToInsertMilliseconds { jsonObject["releaseToInsertMs"] = releaseToInsertMilliseconds }
        if let cleanupOutcome { jsonObject["cleanupOutcome"] = cleanupOutcome.rawValue }
        if let cleanupInputTokens { jsonObject["cleanupInputTokens"] = cleanupInputTokens }
        if let cleanupOutputTokens { jsonObject["cleanupOutputTokens"] = cleanupOutputTokens }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: jsonData, encoding: .utf8)
    }

    /// One compact line for the Xcode console. Numbers and identifiers only.
    func makeConsoleSummaryLine() -> String {
        func millisecondsText(_ milliseconds: Int?) -> String {
            milliseconds.map { "\($0)ms" } ?? "-"
        }

        var summaryLine = "⏱ dictation \(insertionOutcome.rawValue)"
        summaryLine += " | audio \(audioSeconds.map { String(format: "%.1fs", $0) } ?? "-")"
        summaryLine += " | from key release: transcript \(millisecondsText(releaseToTranscriptMilliseconds))"
        summaryLine += " insert \(millisecondsText(releaseToInsertMilliseconds))"
        summaryLine += " | cleanup \(cleanupOutcome?.rawValue ?? "-") \(millisecondsText(cleanupMilliseconds))"
        summaryLine += wasHandsFree ? " | hands-free" : ""
        return summaryLine
    }
}

/// Appends one JSON line per dictation to its own local file, `dictation_metrics.jsonl`, next to the
/// turn metrics. It is a separate file because its lines have a different shape and the turn
/// metrics file is read by other tools. Failures are swallowed: a lost metrics line must never
/// disturb a dictation.
nonisolated enum ClickyDictationMetricsLog {
    static var defaultLogFileURL: URL {
        ClickyTurnMetricsLog.defaultLogFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("dictation_metrics.jsonl")
    }

    private static let backgroundWriteQueue = DispatchQueue(label: "com.clicky.dictation-metrics-log", qos: .utility)

    /// What the app calls once per dictation. Returns at once; the write happens in the background.
    static func recordInBackground(_ dictationMetrics: ClickyDictationMetrics, to logFileURL: URL = defaultLogFileURL) {
        guard let jsonLine = dictationMetrics.makeJSONLine() else { return }
        backgroundWriteQueue.async {
            ClickyTurnMetricsLog.appendLine(jsonLine, to: logFileURL)
        }
    }

    /// Same as `recordInBackground` but writes on the calling thread, so tests can wait for it.
    @discardableResult
    static func record(_ dictationMetrics: ClickyDictationMetrics, to logFileURL: URL = defaultLogFileURL) -> Bool {
        guard let jsonLine = dictationMetrics.makeJSONLine() else { return false }
        return ClickyTurnMetricsLog.appendLine(jsonLine, to: logFileURL)
    }
}
