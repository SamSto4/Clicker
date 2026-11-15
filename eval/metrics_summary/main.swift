// Metrics summary (round 19, Jarvis tuning): reads a COPY of the app's turn log
// (`turn_metrics.jsonl`) and, optionally, of the follow-up log (`follow_up_metrics.jsonl`) and prints
// the tables the round 19 brief asks for: turns by request count, the waits and the cost by turn kind,
// per-request medians, the action kinds, the share of turns that called a tool (the number the cache
// breakpoint's default is judged by), and the follow-up windows by close reason and chain position.
//
// It is compiled with EzraCore, so the lines are read by the app's own parsers
// (`EzraUsageLogParser`, `EzraFollowUpMetricsParser`) and priced with the usage tab's table
// (`EzraModelPriceTable`). It never reads `~/Library/Logs/Ezra` itself: copy the files into a
// scratch folder first and pass their paths. It prints nothing but numbers and fixed identifiers (the
// logs hold nothing else).
//
// Build and run (from the repo root):
//   swiftc -O -o /tmp/metrics_summary eval/metrics_summary/main.swift leanring-buddy/EzraCore/*.swift
//   /tmp/metrics_summary <copy of turn_metrics.jsonl> [<copy of follow_up_metrics.jsonl>]

import Foundation

// MARK: - Arguments

let commandLineArguments = CommandLine.arguments
guard commandLineArguments.count >= 2 else {
    print("usage: metrics_summary <copy of turn_metrics.jsonl> [<copy of follow_up_metrics.jsonl>]")
    exit(2)
}

/// The app's own log folder. The summary refuses to read from it so the live logs are never opened
/// while the app may be writing them: the orchestrator copies them first.
/// Compared as written (standardized, no disk access), so a refused path is never even looked at.
let liveLogFolderPath = EzraTurnMetricsLog.defaultLogFileURL.deletingLastPathComponent().standardizedFileURL.path

func isInsideTheLiveLogFolder(_ fileURL: URL) -> Bool {
    fileURL.path == liveLogFolderPath || fileURL.path.hasPrefix(liveLogFolderPath + "/")
}

func logFileURL(fromArgument argument: String) -> URL {
    let standardizedURL = URL(fileURLWithPath: argument).standardizedFileURL
    // Checked twice: as written (before anything touches the disk), and with links resolved, so a link
    // in the scratch folder that points at a live log is refused too.
    if isInsideTheLiveLogFolder(standardizedURL) || isInsideTheLiveLogFolder(standardizedURL.resolvingSymlinksInPath()) {
        print("refused: that is the app's live log folder. copy the file somewhere else first.")
        exit(2)
    }
    return standardizedURL
}

let turnLogURL = logFileURL(fromArgument: commandLineArguments[1])
let followUpLogURL: URL? = commandLineArguments.count >= 3 ? logFileURL(fromArgument: commandLineArguments[2]) : nil

// MARK: - Small helpers

func median(_ values: [Int]) -> Int? {
    EzraUsageAggregator.median(of: values)
}

func medianDollars(_ values: [Decimal]) -> Decimal? {
    guard !values.isEmpty else { return nil }
    let sortedValues = values.sorted()
    let middleIndex = sortedValues.count / 2
    if sortedValues.count % 2 == 1 { return sortedValues[middleIndex] }
    return (sortedValues[middleIndex - 1] + sortedValues[middleIndex]) / 2
}

/// The value below which `fraction` of the sorted values lie (nearest rank).
func percentile(_ values: [Int], _ fraction: Double) -> Int? {
    guard !values.isEmpty else { return nil }
    let sortedValues = values.sorted()
    let rank = Int((fraction * Double(sortedValues.count)).rounded(.up))
    return sortedValues[min(max(rank, 1), sortedValues.count) - 1]
}

func text(_ number: Int?) -> String {
    number.map(String.init) ?? "-"
}

func dollarsText(_ dollars: Decimal?) -> String {
    guard let dollars else { return "-" }
    return "$" + EzraUsageText.dollarsText(dollars, decimalPlaces: 4)
}

func percentText(_ part: Int, of whole: Int) -> String {
    guard whole > 0 else { return "-" }
    return String(format: "%.1f%%", Double(part) * 100 / Double(whole))
}

/// Pads every column to the widest cell, so the tables line up in a terminal.
func printTable(_ rows: [[String]]) {
    guard let columnCount = rows.map(\.count).max() else { return }
    var columnWidths = Array(repeating: 0, count: columnCount)
    for row in rows {
        for (columnIndex, cell) in row.enumerated() {
            columnWidths[columnIndex] = max(columnWidths[columnIndex], cell.count)
        }
    }
    for row in rows {
        let paddedCells = row.enumerated().map { columnIndex, cell in
            cell.padding(toLength: columnWidths[columnIndex], withPad: " ", startingAt: 0)
        }
        print(paddedCells.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - The turn log

let turnLogLines = EzraUsageLogReader.lines(inFileAt: turnLogURL)
var turnRecords: [EzraUsageTurnRecord] = []
var skippedTurnLineCount = 0
for turnLogLine in turnLogLines {
    if let turnRecord = EzraUsageLogParser.parseTurnRecord(fromLine: turnLogLine) {
        turnRecords.append(turnRecord)
    } else {
        skippedTurnLineCount += 1
    }
}

/// How many requests a turn sent: 0 for a quick command, the loop's count for a tool-loop turn, 1 for
/// a plain turn with tokens, and nil for a turn that never got as far as a request.
func requestCount(of turnRecord: EzraUsageTurnRecord) -> Int? {
    if turnRecord.isQuickCommand { return 0 }
    if !turnRecord.roundTripMilliseconds.isEmpty { return turnRecord.roundTripMilliseconds.count }
    return turnRecord.hasAnyTokenCount ? 1 : nil
}

/// The kinds of turn the brief names, decided in this order.
enum TurnKind: String, CaseIterable {
    case noTool = "no tool"
    case actionAtOnce = "action at once"
    case actionQueued = "action queued"
    case fileTool = "file tool"
    case quickCommand = "quick command"
    case skippedFinalRequest = "skipped final request"
}

func turnKind(of turnRecord: EzraUsageTurnRecord) -> TurnKind {
    if turnRecord.isQuickCommand { return .quickCommand }
    if turnRecord.skippedFinalRequest { return .skippedFinalRequest }
    if turnRecord.actionKinds.contains(.openLinkQueued) || turnRecord.actionKinds.contains(.runShortcutQueued) { return .actionQueued }
    if !turnRecord.actionKinds.isEmpty { return .actionAtOnce }
    if (turnRecord.toolCallCount ?? 0) > 0 { return .fileTool }
    return .noTool
}

func estimatedDollars(of turnRecord: EzraUsageTurnRecord) -> Decimal? {
    if turnRecord.isQuickCommand { return 0 }
    guard turnRecord.hasAnyTokenCount else { return nil }
    return EzraModelPriceTable.estimatedCostInDollars(
        modelName: turnRecord.modelName,
        inputTokens: turnRecord.inputTokens ?? 0,
        outputTokens: turnRecord.outputTokens ?? 0,
        cacheWriteTokens: turnRecord.cacheCreationInputTokens ?? 0,
        cacheReadTokens: turnRecord.cacheReadInputTokens ?? 0
    )
}

print("turn metrics: \(turnRecords.count) lines read, \(skippedTurnLineCount) skipped")

print("\n== turns by request count")
var requestCountRows: [[String]] = [["requests", "turns", "share"]]
let requestCountBuckets: [(label: String, matches: (Int?) -> Bool)] = [
    ("0 (quick command)", { $0 == 0 }),
    ("1", { $0 == 1 }),
    ("2", { $0 == 2 }),
    ("3", { $0 == 3 }),
    ("4+", { ($0 ?? 0) >= 4 }),
    ("none (stopped before a request)", { $0 == nil }),
]
for bucket in requestCountBuckets {
    let turnCount = turnRecords.filter { bucket.matches(requestCount(of: $0)) }.count
    requestCountRows.append([bucket.label, String(turnCount), percentText(turnCount, of: turnRecords.count)])
}
printTable(requestCountRows)

print("\n== by turn kind (medians; cost at list prices)")
var turnKindRows: [[String]] = [["kind", "turns", "key release to audio ms", "first reply text ms", "cost"]]
for kind in TurnKind.allCases {
    let turnsOfKind = turnRecords.filter { turnKind(of: $0) == kind }
    turnKindRows.append([
        kind.rawValue,
        String(turnsOfKind.count),
        text(median(turnsOfKind.compactMap(\.keyReleaseToAudioStartMilliseconds))),
        text(median(turnsOfKind.compactMap(\.timeToFirstReplyTextMilliseconds))),
        dollarsText(medianDollars(turnsOfKind.compactMap(estimatedDollars(of:)))),
    ])
}
printTable(turnKindRows)

print("\n== per request index (medians over tool-loop turns)")
let longestLoop = turnRecords.map(\.roundTripMilliseconds.count).max() ?? 0
var requestIndexRows: [[String]] = [["request", "turns", "ms", "input tokens", "cache read", "cache write"]]
if longestLoop > 0 {
    for requestIndex in 0..<longestLoop {
        let turnsWithThisRequest = turnRecords.filter { $0.roundTripMilliseconds.count > requestIndex }
        func valuesAtIndex(_ values: (EzraUsageTurnRecord) -> [Int]) -> [Int] {
            turnsWithThisRequest.compactMap { turnRecord in
                let turnValues = values(turnRecord)
                return turnValues.count > requestIndex ? turnValues[requestIndex] : nil
            }
        }
        requestIndexRows.append([
            String(requestIndex + 1),
            String(turnsWithThisRequest.count),
            text(median(valuesAtIndex(\.roundTripMilliseconds))),
            text(median(valuesAtIndex(\.roundTripInputTokens))),
            text(median(valuesAtIndex(\.roundTripCacheReadTokens))),
            text(median(valuesAtIndex(\.roundTripCacheCreationTokens))),
        ])
    }
} else {
    requestIndexRows.append(["-", "0", "-", "-", "-", "-"])
}
printTable(requestIndexRows)

print("\n== action kinds")
var actionKindRows: [[String]] = [["kind", "count"]]
for actionKind in EzraActionKind.allCases {
    let kindCount = turnRecords.reduce(0) { runningCount, turnRecord in
        runningCount + turnRecord.actionKinds.filter { $0 == actionKind }.count
    }
    actionKindRows.append([actionKind.rawValue, String(kindCount)])
}
printTable(actionKindRows)

print("\n== tool use (the cache breakpoint's default is judged by these shares)")
let turnsThatCalledATool = turnRecords.filter { ($0.toolCallCount ?? 0) > 0 }.count
let turnsWithThreeOrMoreRequests = turnRecords.filter { (requestCount(of: $0) ?? 0) >= 3 }.count
let turnsThatRanCallsInParallel = turnRecords.filter { ($0.parallelToolCalls ?? 0) > 0 }.count
printTable([
    ["measure", "turns", "share"],
    ["any tool call", String(turnsThatCalledATool), percentText(turnsThatCalledATool, of: turnRecords.count)],
    ["3 or more requests", String(turnsWithThreeOrMoreRequests), percentText(turnsWithThreeOrMoreRequests, of: turnRecords.count)],
    ["calls run in parallel", String(turnsThatRanCallsInParallel), percentText(turnsThatRanCallsInParallel, of: turnRecords.count)],
    ["started by follow-up listening", String(turnRecords.filter(\.startedByFollowUpListening).count), percentText(turnRecords.filter(\.startedByFollowUpListening).count, of: turnRecords.count)],
    ["stopped by escape", String(turnRecords.filter(\.wasInterruptedByEscape).count), percentText(turnRecords.filter(\.wasInterruptedByEscape).count, of: turnRecords.count)],
])
let escapeDelays = turnRecords.compactMap(\.interruptedWithinMilliseconds)
print("escape after the reply began (ms): n \(escapeDelays.count), median \(text(median(escapeDelays))), p90 \(text(percentile(escapeDelays, 0.9)))")

// MARK: - The follow-up log

if let followUpLogURL {
    let followUpLines = EzraUsageLogReader.lines(inFileAt: followUpLogURL)
    let followUpRecords = followUpLines.compactMap { EzraFollowUpMetricsParser.parse(line: $0) }
    print("\nfollow-up metrics: \(followUpRecords.count) lines read, \(followUpLines.count - followUpRecords.count) skipped")

    print("\n== follow-up windows: close reason by chain position (6 = the window the cap kept shut)")
    let chainPositions = Array(Set(followUpRecords.map(\.chainPosition))).sorted()
    var closeReasonRows: [[String]] = [["close reason"] + chainPositions.map { "pos \($0)" } + ["all"]]
    for closeReason in EzraFollowUpCloseReason.allCases {
        let recordsWithReason = followUpRecords.filter { $0.closeReason == closeReason }
        var row = [closeReason.rawValue]
        for chainPosition in chainPositions {
            row.append(String(recordsWithReason.filter { $0.chainPosition == chainPosition }.count))
        }
        row.append(String(recordsWithReason.count))
        closeReasonRows.append(row)
    }
    printTable(closeReasonRows)

    print("\n== follow-up windows: distributions")
    func distributionRow(_ name: String, _ values: [Int]) -> [String] {
        [name, String(values.count), text(values.min()), text(median(values)), text(percentile(values, 0.9)), text(values.max())]
    }
    printTable([
        ["measure", "n", "min", "median", "p90", "max"],
        distributionRow("floor (per mille)", followUpRecords.compactMap(\.measuredFloorPerMille)),
        distributionRow("peak level (per mille)", followUpRecords.compactMap(\.peakLevelPerMille)),
        distributionRow("speech onset (ms after open)", followUpRecords.compactMap(\.millisecondsToSpeechStart)),
        distributionRow("speech length (ms)", followUpRecords.compactMap(\.speechMilliseconds)),
        distributionRow("window open (ms)", followUpRecords.compactMap(\.windowOpenMilliseconds)),
    ])
    print("\n== follow-up windows: speech onset by chain position (ms, median)")
    var onsetRows: [[String]] = [["chain position", "windows", "with speech", "median onset ms"]]
    for chainPosition in chainPositions {
        let windowsAtPosition = followUpRecords.filter { $0.chainPosition == chainPosition }
        let onsets = windowsAtPosition.compactMap(\.millisecondsToSpeechStart)
        onsetRows.append([String(chainPosition), String(windowsAtPosition.count), String(onsets.count), text(median(onsets))])
    }
    printTable(onsetRows)
    let joinedTurnIdentifiers = Set(turnRecords.compactMap(\.turnId))
    let sentToModel = followUpRecords.filter { $0.closeReason == .sentToModel }
    let sentAndJoined = sentToModel.filter { $0.turnId.map(joinedTurnIdentifiers.contains) ?? false }
    print("windows sent to the model whose turn line is in the turn log: \(sentAndJoined.count) of \(sentToModel.count)")
}
