// File editing eval (round 17): runs the app's own tool loop live through the Worker.
//
// Everything that decides what happens is the app's ClickyCore code, compiled in: the prompt
// (`ClickyPromptAssembler` with the "files you may change" section), the tools
// (`ClickyFileToolDefinitions`), the request body (`ClickyClaudeChatRequestBuilder`), the stream reader
// (`ClickyStreamedMessageAssembler`, which keeps every block as received, thinking signatures and the
// `caller` field included), the loop (`ClickyToolLoop`), the path policy and tools
// (`ClickyFileToolTurnSession`), the honesty rule (`ClickyFileEditingHonesty`) and the applier
// (`ClickyChangeApplier`). The only code of its own is the network send (the same request
// `ClaudeAPI.streamOneRequestOfToolLoop` makes) and the scoring.
//
// Every scenario runs on a new temporary folder seeded with its sample files: never a real project.
// Queued changes are applied there with the app's applier (backups in the same temporary folder),
// and the files are scored afterwards.
//
// Build and run (from the repo root):
//   swiftc -O -o /tmp/file_editing_runner eval/file_editing_runner/main.swift leanring-buddy/ClickyCore/*.swift
//   /tmp/file_editing_runner leanring-buddy/ClickyPrompts eval/fixtures eval/scenarios/files.json <results.json> [--runs N] [--only id,id]
//
// The Worker address and app token are read from the git-ignored
// leanring-buddy/ClickyWorkerSecrets.plist with PlistBuddy at run time; the token is never printed.

import Foundation

// MARK: - Arguments

let commandLineArguments = CommandLine.arguments
guard commandLineArguments.count >= 5 else {
    print("usage: file_editing_runner <promptsDirectory> <fixturesDirectory> <scenarios.json> <results.json> [--runs N] [--only id,id]")
    exit(2)
}
let promptsDirectoryURL = URL(fileURLWithPath: commandLineArguments[1], isDirectory: true)
let fixturesDirectoryURL = URL(fileURLWithPath: commandLineArguments[2], isDirectory: true)
let scenariosFileURL = URL(fileURLWithPath: commandLineArguments[3])
let resultsFileURL = URL(fileURLWithPath: commandLineArguments[4])
var runCountPerScenario = 1
var onlyScenarioIdentifiers: Set<String>? = nil
var argumentIndex = 5
while argumentIndex < commandLineArguments.count {
    if commandLineArguments[argumentIndex] == "--runs", argumentIndex + 1 < commandLineArguments.count {
        runCountPerScenario = Int(commandLineArguments[argumentIndex + 1]) ?? 1
        argumentIndex += 2
    } else if commandLineArguments[argumentIndex] == "--only", argumentIndex + 1 < commandLineArguments.count {
        onlyScenarioIdentifiers = Set(commandLineArguments[argumentIndex + 1].split(separator: ",").map(String.init))
        argumentIndex += 2
    } else {
        argumentIndex += 1
    }
}

// MARK: - Worker configuration (token never printed)

let workerSecretsPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("leanring-buddy/ClickyWorkerSecrets.plist").path

func readWorkerSecretsValue(_ key: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
    process.arguments = ["-c", "Print :\(key)", workerSecretsPlistPath]
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()
    do { try process.run() } catch { return "" }
    process.waitUntilExit()
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    return (String(data: outputData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

let workerBaseURLText = readWorkerSecretsValue("WorkerBaseURL").replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
let workerAppToken = readWorkerSecretsValue("WorkerAppToken")
guard !workerBaseURLText.isEmpty, !workerAppToken.isEmpty, let workerChatURL = URL(string: workerBaseURLText + "/chat") else {
    print("WorkerBaseURL or WorkerAppToken is missing in ClickyWorkerSecrets.plist")
    exit(2)
}

// MARK: - Scenarios

struct ScenarioFile {
    let path: String
    let content: String
}

struct ExpectedChange {
    let action: String
    /// The folder the change is in (its name); the scenario's first folder when not given.
    let folder: String?
    let path: String
    let contains: [String]
    let notContains: [String]
}

struct Scenario {
    let identifier: String
    let screenshotFileName: String
    let applicationName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let editableFolderNames: [String]
    let frontmostDocument: String?
    let files: [ScenarioFile]
    let history: [(user: String, assistant: String)]
    /// Changes an earlier turn proposed that still wait (as the app names them in the prompt).
    let pendingChangeDescriptions: [String]
    let userPrompt: String
    let expectationKind: String
    let expectedChanges: [ExpectedChange]
    let maximumToolCalls: Int?
    let forbiddenActions: [String]
    let unchangedFiles: [String]
    /// Files (root-relative) that must still hold these texts after whatever was applied.
    let filesMustContain: [String: [String]]
}

/// A made-up key in the shape the secret rules catch, put where a scenario writes {{FAKE_PROVIDER_KEY}}.
/// It is made at run time so no key-shaped text is ever committed (a host's secret scanning would
/// flag it).
let fakeProviderKey: String = {
    let keyCharacters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    return "sk-ant-api03-" + String((0..<90).map { _ in keyCharacters.randomElement()! })
}()

func loadScenarios() -> [Scenario] {
    guard let rawScenariosText = try? String(contentsOf: scenariosFileURL, encoding: .utf8),
          let scenariosData = rawScenariosText.replacingOccurrences(of: "{{FAKE_PROVIDER_KEY}}", with: fakeProviderKey).data(using: .utf8),
          let scenariosRoot = try? JSONSerialization.jsonObject(with: scenariosData) as? [String: Any],
          let scenarioObjects = scenariosRoot["scenarios"] as? [[String: Any]] else {
        print("could not read \(scenariosFileURL.path)")
        exit(2)
    }
    return scenarioObjects.map { scenarioObject in
        let expectObject = scenarioObject["expect"] as? [String: Any] ?? [:]
        return Scenario(
            identifier: scenarioObject["id"] as? String ?? "?",
            screenshotFileName: scenarioObject["screenshot"] as? String ?? "vscode_main.jpg",
            applicationName: scenarioObject["appName"] as? String,
            bundleIdentifier: scenarioObject["bundleIdentifier"] as? String,
            windowTitle: scenarioObject["windowTitle"] as? String,
            editableFolderNames: scenarioObject["editableFolders"] as? [String] ?? ["project"],
            frontmostDocument: scenarioObject["frontmostDocument"] as? String,
            files: (scenarioObject["files"] as? [[String: String]] ?? []).map { ScenarioFile(path: $0["path"] ?? "", content: $0["content"] ?? "") },
            history: (scenarioObject["history"] as? [[String: String]] ?? []).map { ($0["user"] ?? "", $0["assistant"] ?? "") },
            pendingChangeDescriptions: scenarioObject["pendingChanges"] as? [String] ?? [],
            userPrompt: scenarioObject["userPrompt"] as? String ?? "",
            expectationKind: expectObject["kind"] as? String ?? "noChange",
            expectedChanges: (expectObject["changes"] as? [[String: Any]] ?? []).map {
                ExpectedChange(
                    action: $0["action"] as? String ?? "",
                    folder: $0["folder"] as? String,
                    path: $0["path"] as? String ?? "",
                    contains: $0["contains"] as? [String] ?? [],
                    notContains: $0["notContains"] as? [String] ?? []
                )
            },
            maximumToolCalls: expectObject["maxToolCalls"] as? Int,
            forbiddenActions: expectObject["forbiddenActions"] as? [String] ?? [],
            unchangedFiles: expectObject["unchangedFiles"] as? [String] ?? [],
            filesMustContain: expectObject["filesMustContain"] as? [String: [String]] ?? [:]
        )
    }
}

// MARK: - One request of the loop, as ClaudeAPI.streamOneRequestOfToolLoop sends it

struct WorkerRequestFailure: Error {
    let description: String
}

let workerSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 120
    return URLSession(configuration: configuration)
}()

func sendOneRequest(requestBody: [String: Any]) async throws -> ClickyStreamedMessage {
    let startTime = Date()
    var request = URLRequest(url: workerChatURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(workerAppToken, forHTTPHeaderField: "X-Clicky-App-Token")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

    var lastError: Error?
    for attemptNumber in 1...3 {
        do {
            let (byteStream, response) = try await workerSession.bytes(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode) else {
                var errorBodyLines: [String] = []
                for try await line in byteStream.lines { errorBodyLines.append(line) }
                let errorBody = errorBodyLines.joined(separator: "\n").replacingOccurrences(of: workerAppToken, with: "[token]")
                // 5xx and 429 are retried; any other status is the request's own fault and is reported.
                if statusCode >= 500 || statusCode == 429, attemptNumber < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attemptNumber) * 2_000_000_000)
                    continue
                }
                throw WorkerRequestFailure(description: "HTTP \(statusCode): \(errorBody.prefix(400))")
            }
            var messageAssembler = ClickyStreamedMessageAssembler()
            for try await line in byteStream.lines {
                guard let eventPayload = ClickyServerSentEventLine.eventPayload(fromLine: line) else { continue }
                messageAssembler.consume(eventPayload)
            }
            var streamedMessage = messageAssembler.finishedMessage()
            streamedMessage.durationSeconds = Date().timeIntervalSince(startTime)
            if let streamErrorMessage = streamedMessage.streamErrorMessage {
                throw WorkerRequestFailure(description: "stream error: \(streamErrorMessage)")
            }
            return streamedMessage
        } catch let failure as WorkerRequestFailure {
            throw failure
        } catch {
            lastError = error
            if attemptNumber < 3 {
                try await Task.sleep(nanoseconds: UInt64(attemptNumber) * 2_000_000_000)
            }
        }
    }
    throw WorkerRequestFailure(description: "network: \(lastError.map { String(describing: type(of: $0)) } ?? "unknown")")
}

// MARK: - One run of one scenario

struct ScenarioRunRecord {
    var fields: [String: Any] = [:]
    var failures: [String] = []
}

func readText(_ fileURL: URL) -> String? {
    guard let fileData = try? Data(contentsOf: fileURL) else { return nil }
    return String(data: fileData, encoding: .utf8)
}

/// A rough price at list prices for Sonnet 5.5 (dollars per million tokens: input 2, output 10, cache
/// read 0.20, cache write 2.50), the table the app's usage tab uses.
func estimatedDollars(_ usage: ClickyClaudeTokenUsage) -> Double {
    let inputDollars = Double(usage.inputTokens ?? 0) * 2.0 / 1_000_000
    let outputDollars = Double(usage.outputTokens ?? 0) * 10.0 / 1_000_000
    let cacheReadDollars = Double(usage.cacheReadInputTokens ?? 0) * 0.20 / 1_000_000
    let cacheWriteDollars = Double(usage.cacheCreationInputTokens ?? 0) * 2.50 / 1_000_000
    return inputDollars + outputDollars + cacheReadDollars + cacheWriteDollars
}

func runScenario(_ scenario: Scenario, runNumber: Int) async -> ScenarioRunRecord {
    var record = ScenarioRunRecord()
    record.fields["id"] = scenario.identifier
    record.fields["run"] = runNumber

    // A new temporary root: the folders the user "chose", a home folder, and an empty notes folder.
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("clicky-files-eval-\(scenario.identifier)-\(runNumber)-\(UUID().uuidString.prefix(6))", isDirectory: true)
    let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
    let notesURL = rootURL.appendingPathComponent("notes", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    for folderURL in [homeURL, notesURL] + scenario.editableFolderNames.map({ rootURL.appendingPathComponent($0, isDirectory: true) }) {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }
    for scenarioFile in scenario.files {
        let fileURL = rootURL.appendingPathComponent(scenarioFile.path)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(scenarioFile.content.utf8).write(to: fileURL)
    }
    let originalFileTexts = Dictionary(uniqueKeysWithValues: scenario.files.map { ($0.path, $0.content) })

    // The policy and the turn context exactly as `ClickyPreparedFileEditing.prepare` builds them.
    let editableFolderPaths = scenario.editableFolderNames.map { rootURL.appendingPathComponent($0, isDirectory: true).path }
    let frontmostDocumentPath = scenario.frontmostDocument.map { rootURL.appendingPathComponent($0).path }
    let pathPolicy = ClickyFilePathPolicy(allowedFolderPaths: editableFolderPaths, homeDirectoryPath: homeURL.path, frontmostDocumentPath: frontmostDocumentPath)
    var turnContext = ClickyTurnContext(
        userTranscript: scenario.userPrompt,
        frontmostApplicationBundleIdentifier: scenario.bundleIdentifier,
        frontmostApplicationName: scenario.applicationName,
        screenCount: 1,
        currentDate: Date(),
        frontmostWindowTitle: scenario.windowTitle
    )
    turnContext.editableFolders = pathPolicy.allowedFolderURLs.map {
        ClickyEditableFolderDescription(name: ClickyEditableFolders.displayName(forFolderPath: $0.path), path: $0.path)
    }
    turnContext.frontmostDocumentInEditableFolder = ClickyFileEditingPromptSection.frontmostDocumentDescription(documentPath: frontmostDocumentPath, policy: pathPolicy)
    turnContext.pendingChangeDescriptions = scenario.pendingChangeDescriptions
    let preparedPrompt = ClickyPromptAssembler.prepareSystemPrompt(
        for: turnContext,
        promptsDirectoryURL: promptsDirectoryURL,
        noteStore: ClickyNoteStore(notesDirectoryURL: notesURL),
        profileStore: ClickyProfileStore(profileDirectoryURL: notesURL)
    )

    // The request pieces exactly as `ClaudeAPI.analyzeImageStreamingWithFileTools` builds them.
    guard let screenshotData = try? Data(contentsOf: fixturesDirectoryURL.appendingPathComponent(scenario.screenshotFileName)) else {
        record.failures.append("missing screenshot \(scenario.screenshotFileName)")
        return record
    }
    let screenLabel = "user's screen (cursor is here) (image dimensions: 1280x800 pixels; center is at 640,400)"
    let systemBlocks = ClickySystemPromptBlocks.makeSystemBlocks(staticText: preparedPrompt.staticSystemPromptText, dynamicText: preparedPrompt.dynamicSystemPromptText)
    let tools = ClickyFileToolDefinitions.toolsArray()
    let baseMessages = ClickyClaudeChatRequestBuilder.messages(
        conversationHistory: scenario.history.map { (userPlaceholder: $0.user, assistantResponse: $0.assistant) },
        currentUserContentBlocks: ClickyClaudeChatRequestBuilder.currentUserContentBlocks(images: [(data: screenshotData, label: screenLabel)], userPrompt: scenario.userPrompt)
    )
    let toolSession = ClickyFileToolTurnSession(policy: pathPolicy)
    var toolCallLog: [[String: Any]] = []
    // The block types of every reply of the loop, in order ("thinking" blocks are replayed with their signature).
    var blockTypesPerRequest: [[String]] = []

    let turnStart = Date()
    let loopResult: ClickyToolLoopResult
    do {
        loopResult = try await ClickyToolLoop.run(
            baseMessages: baseMessages,
            buildRequestBody: { messagesSoFar in
                ClickyClaudeChatRequestBuilder.streamingRequestBody(model: "claude-sonnet-5-5", systemPromptValue: systemBlocks, messages: messagesSoFar, tools: tools)
            },
            executeToolCall: { toolName, toolInput in
                let toolResult = toolSession.execute(toolName: toolName, input: toolInput)
                var loggedInput = toolInput
                for longField in ["old_text", "new_text", "content"] {
                    if let longText = loggedInput[longField] as? String, longText.count > 160 {
                        loggedInput[longField] = String(longText.prefix(160)) + "…"
                    }
                }
                toolCallLog.append(["tool": toolName, "input": loggedInput, "isError": toolResult.isError, "result": String(toolResult.text.prefix(200))])
                return toolResult
            },
            sendRequest: { requestBody, _ in
                let streamedMessage = try await sendOneRequest(requestBody: requestBody)
                blockTypesPerRequest.append(streamedMessage.contentBlocks.compactMap { $0["type"] as? String })
                return streamedMessage
            }
        )
    } catch let failure as WorkerRequestFailure {
        record.failures.append("request failed: \(failure.description)")
        record.fields["toolCalls"] = toolCallLog
        return record
    } catch {
        record.failures.append("loop failed: \(error)")
        return record
    }
    let turnMilliseconds = Int(Date().timeIntervalSince(turnStart) * 1000)

    // What the user would hear: tags removed, then the honesty rule (as CompanionManager does).
    let rawReplyText = loopResult.replyTextToFinish
    let parsedSpokenText = ClickyReplyTagParser.parse(rawReplyText).spokenText
    let queuedChanges = toolSession.queuedChanges
    let honestText = ClickyFileEditingHonesty.honestSpokenText(parsedSpokenText, queuedChangeCount: queuedChanges.count, usedFileTools: toolSession.toolCallCount > 0)

    // Thinking blocks seen in any reply of the loop (they are replayed with their signature).
    record.fields["requestCount"] = loopResult.requestCount
    record.fields["toolRoundTrips"] = loopResult.toolRoundTripCount
    record.fields["toolCallCount"] = toolSession.toolCallCount
    record.fields["toolCalls"] = toolCallLog
    record.fields["perRequestMilliseconds"] = loopResult.requestStats.map(\.milliseconds)
    record.fields["perRequestInputTokens"] = loopResult.requestStats.map { $0.inputTokens ?? 0 }
    record.fields["perRequestCacheReadTokens"] = loopResult.requestStats.map { $0.cacheReadInputTokens ?? 0 }
    record.fields["perRequestCacheWriteTokens"] = loopResult.requestStats.map { $0.cacheCreationInputTokens ?? 0 }
    record.fields["perRequestOutputTokens"] = loopResult.requestStats.map { $0.outputTokens ?? 0 }
    record.fields["turnMilliseconds"] = turnMilliseconds
    record.fields["estimatedDollars"] = estimatedDollars(loopResult.totalTokenUsage)
    record.fields["finalStopReason"] = loopResult.finalMessage.stopReason ?? "none"
    record.fields["blockTypesPerRequest"] = blockTypesPerRequest
    record.fields["rawReplyText"] = rawReplyText
    record.fields["spokenText"] = honestText
    record.fields["honestyRuleChangedWords"] = honestText != parsedSpokenText
    record.fields["queuedChanges"] = queuedChanges.map { ["action": $0.action.rawValue, "path": $0.relativePath, "summary": $0.summary] }

    if loopResult.endedBecauseOfRequestLimit { record.failures.append("ran out of requests") }
    if loopResult.endedBecauseTheReplyWasCutOrDeclined { record.failures.append("the reply was cut off or declined") }
    if honestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { record.failures.append("nothing to say") }
    if let maximumToolCalls = scenario.maximumToolCalls, toolSession.toolCallCount > maximumToolCalls {
        record.failures.append("used \(toolSession.toolCallCount) tool calls, at most \(maximumToolCalls) expected")
    }
    for forbiddenAction in scenario.forbiddenActions where queuedChanges.contains(where: { $0.action.rawValue == forbiddenAction }) {
        record.failures.append("proposed a forbidden \(forbiddenAction)")
    }

    // Apply what was queued, with the app's applier, in the temporary folder, and score the files.
    if !queuedChanges.isEmpty {
        let applyOutcome = ClickyChangeApplier.apply(
            changeSet: ClickyPendingChangeSet(changes: queuedChanges, proposedAt: Date()),
            backupsRootDirectoryURL: rootURL.appendingPathComponent("backups", isDirectory: true),
            now: Date()
        )
        switch applyOutcome {
        case .applied: record.fields["applied"] = true
        case .refusedBecauseFileChanged: record.failures.append("the applier refused: file changed")
        case .failed(let reason): record.failures.append("the applier failed: \(reason)")
        }
    }

    switch scenario.expectationKind {
    case "any":
        // Either answer is fine; only the files that must keep their text are checked below.
        break
    case "noChange":
        if !queuedChanges.isEmpty { record.failures.append("proposed \(queuedChanges.count) change(s), none expected") }
    case "change":
        let queuedSummaries = queuedChanges.map { "\($0.action.rawValue) \($0.allowedFolderURL.lastPathComponent)/\($0.relativePath)" }.sorted()
        let expectedSummaries = scenario.expectedChanges.map { "\($0.action) \($0.folder ?? scenario.editableFolderNames[0])/\($0.path)" }
        // Several edits of one file count as one expected edit.
        if Set(queuedSummaries) != Set(expectedSummaries) {
            record.failures.append("queued \(queuedSummaries), expected \(expectedSummaries.sorted())")
        }
        for expectedChange in scenario.expectedChanges {
            let folderURL = rootURL.appendingPathComponent(expectedChange.folder ?? scenario.editableFolderNames[0], isDirectory: true)
            let fileURL = folderURL.appendingPathComponent(expectedChange.path)
            if expectedChange.action == "delete" {
                if FileManager.default.fileExists(atPath: fileURL.path) { record.failures.append("\(expectedChange.path) still exists") }
                continue
            }
            guard let fileText = readText(fileURL) else {
                record.failures.append("\(expectedChange.path) is missing after applying")
                continue
            }
            for requiredText in expectedChange.contains where !fileText.contains(requiredText) {
                record.failures.append("\(expectedChange.path) lacks \"\(requiredText)\"")
            }
            for forbiddenText in expectedChange.notContains where fileText.contains(forbiddenText) {
                record.failures.append("\(expectedChange.path) still has \"\(forbiddenText)\"")
            }
        }
    default:
        record.failures.append("unknown expectation kind \(scenario.expectationKind)")
    }
    for (mustContainPath, requiredTexts) in scenario.filesMustContain {
        let fileText = readText(rootURL.appendingPathComponent(mustContainPath)) ?? ""
        for requiredText in requiredTexts where !fileText.contains(requiredText) {
            record.failures.append("\(mustContainPath) lost \"\(requiredText.prefix(24))…\"")
        }
    }
    for unchangedPath in scenario.unchangedFiles {
        let fileText = readText(rootURL.appendingPathComponent(unchangedPath))
        if fileText != originalFileTexts[unchangedPath] {
            record.failures.append("\(unchangedPath) changed but must not")
        }
    }
    return record
}

// MARK: - Main

let allScenarios = loadScenarios().filter { onlyScenarioIdentifiers?.contains($0.identifier) ?? true }
var allRecords: [[String: Any]] = []
var passedRunCount = 0
var totalRunCount = 0
var totalDollars = 0.0
var turnMillisecondsList: [Int] = []

for scenario in allScenarios {
    for runNumber in 1...runCountPerScenario {
        let record = await runScenario(scenario, runNumber: runNumber)
        totalRunCount += 1
        var recordFields = record.fields
        recordFields["failures"] = record.failures
        recordFields["passed"] = record.failures.isEmpty
        if record.failures.isEmpty { passedRunCount += 1 }
        totalDollars += recordFields["estimatedDollars"] as? Double ?? 0
        if let turnMilliseconds = recordFields["turnMilliseconds"] as? Int { turnMillisecondsList.append(turnMilliseconds) }
        allRecords.append(recordFields)
        let toolNames = ((recordFields["toolCalls"] as? [[String: Any]]) ?? []).compactMap { $0["tool"] as? String }.joined(separator: ",")
        let spokenText = (recordFields["spokenText"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
        print("\(record.failures.isEmpty ? "PASS" : "FAIL") \(scenario.identifier) #\(runNumber) | requests \(recordFields["requestCount"] ?? "-") | tools [\(toolNames)] | \(recordFields["turnMilliseconds"] ?? "-") ms | \(String(format: "$%.4f", recordFields["estimatedDollars"] as? Double ?? 0)) | \"\(spokenText.prefix(140))\"")
        for failure in record.failures { print("    - \(failure)") }
    }
}

let sortedTurnMilliseconds = turnMillisecondsList.sorted()
let medianTurnMilliseconds = sortedTurnMilliseconds.isEmpty ? 0 : sortedTurnMilliseconds[sortedTurnMilliseconds.count / 2]
print("\n\(passedRunCount) of \(totalRunCount) runs passed | median turn \(medianTurnMilliseconds) ms | about \(String(format: "$%.3f", totalDollars)) in all")
let resultsObject: [String: Any] = [
    "passedRunCount": passedRunCount,
    "totalRunCount": totalRunCount,
    "medianTurnMilliseconds": medianTurnMilliseconds,
    "estimatedDollars": totalDollars,
    "records": allRecords,
]
if let resultsData = try? JSONSerialization.data(withJSONObject: resultsObject, options: [.prettyPrinted, .sortedKeys]) {
    try? resultsData.write(to: resultsFileURL)
}
