import Foundation

// Round 17 (file editing): the request body of a chat turn, the reading of a streamed reply into
// content blocks kept exactly as received, and the tool loop that answers `tool_use` blocks until
// the model gives its final answer. Foundation only, and no network: the app passes the loop a
// closure that sends one request, and the checks pass one that replays recorded events.
//
// Two rules decide how blocks are handled (both measured on 12 Nov 2026, see the round 17 brief):
// - Every block is kept as the JSON object the API sent, and goes back unchanged. The API checks the
//   `signature` of a thinking block, and a `tool_use` block carries a `caller` field the documentation
//   does not mention. Nothing is ever rebuilt from parsed fields.
// - The system prompt, the tools and every earlier message stay exactly as they were from one request
//   of the loop to the next; a request only adds messages at the end.

// MARK: - The request body

nonisolated enum EzraClaudeChatRequestBuilder {
    /// The streaming chat request without tools: 1024 output tokens.
    static let maximumOutputTokensWithoutTools = 1024

    /// Detects the MIME type of image data by inspecting the first bytes. Screen captures from
    /// ScreenCaptureKit are JPEG, but pasted images are PNG, and the API rejects a declared type that
    /// does not match the data.
    static func imageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG, which is what screen captures use.
        return "image/jpeg"
    }

    /// The content of the current user message: every labeled image, then the user's words.
    /// `cacheControlOnLastBlock` (round 19) puts a cache breakpoint on the last block, the user's words,
    /// so the tools, both system blocks, the history and the screenshots are cached together. It is
    /// never put on an image block. Without it the blocks are exactly what they were.
    static func currentUserContentBlocks(
        images: [(data: Data, label: String)],
        userPrompt: String,
        cacheControlOnLastBlock: Bool = false
    ) -> [[String: Any]] {
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": imageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        return cacheControlOnLastBlock ? addingCacheBreakpointToLastBlock(of: contentBlocks) : contentBlocks
    }

    /// The cache breakpoint (round 19): the key the API reads, the same value the static system block
    /// carries (a 5-minute cache).
    static let cacheBreakpointValue: [String: String] = ["type": "ephemeral"]

    /// The same blocks with `cache_control` added to the last one, when it is a text block. Nothing
    /// else about any block changes, so the bytes the API compares stay the same apart from the key.
    /// An image as the last block (which the app never sends) or no blocks at all are left as they are.
    static func addingCacheBreakpointToLastBlock(of contentBlocks: [[String: Any]]) -> [[String: Any]] {
        guard var lastBlock = contentBlocks.last, (lastBlock["type"] as? String) == "text" else {
            return contentBlocks
        }
        lastBlock["cache_control"] = cacheBreakpointValue
        var blocksWithBreakpoint = contentBlocks
        blocksWithBreakpoint[blocksWithBreakpoint.count - 1] = lastBlock
        return blocksWithBreakpoint
    }

    /// The conversation so far as plain text exchanges, then the current user message.
    static func messages(
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        currentUserContentBlocks: [[String: Any]]
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }
        messages.append(["role": "user", "content": currentUserContentBlocks])
        return messages
    }

    /// The body of a streaming chat request, with the spoken-reply settings added. With `tools` nil
    /// or empty it is exactly the body the app sent before round 17 (no `tools` field, 1024 output
    /// tokens). With tools it also carries them, and `max_tokens` is 8000 because the content of a
    /// new file can be long. There is never a `tool_choice`: forcing a tool is a 400 on Sonnet 5.5.
    static func streamingRequestBody(
        model: String,
        systemPromptValue: Any,
        messages: [[String: Any]],
        tools: [[String: Any]]?
    ) -> [String: Any] {
        var requestBody: [String: Any] = [
            "model": model,
            "max_tokens": maximumOutputTokensWithoutTools,
            "stream": true,
            "system": systemPromptValue,
            "messages": messages
        ]
        if let tools, !tools.isEmpty {
            requestBody["tools"] = tools
            requestBody["max_tokens"] = EzraFileEditingLimits.maximumOutputTokensWithTools
        }
        return EzraClaudeRequestSettings.addingSpokenReplySettings(to: requestBody)
    }
}

// MARK: - Server-sent events

nonisolated enum EzraServerSentEventLine {
    /// The JSON payload of a "data: {...}" line, or nil for any other line (event names, blank
    /// lines, comments, the "[DONE]" marker, or JSON that does not parse into an object).
    static func eventPayload(fromLine line: String) -> [String: Any]? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonString = String(line.dropFirst(6))
        guard jsonString != "[DONE]",
              let jsonData = jsonString.data(using: .utf8),
              let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        return eventPayload
    }
}

// MARK: - One streamed reply

/// A `tool_use` block of a finished reply.
nonisolated struct EzraToolUseBlock {
    let identifier: String
    let name: String
    let input: [String: Any]
    /// False when the streamed input did not parse as a JSON object; `rawInputText` then holds what arrived.
    let inputWasValidJSON: Bool
    let rawInputText: String
}

/// A reply read from its stream: the content blocks exactly as received, why it stopped, the token
/// counts, and an error the stream carried, if any.
nonisolated struct EzraStreamedMessage {
    let contentBlocks: [[String: Any]]
    let stopReason: String?
    let tokenUsage: EzraClaudeTokenUsage
    let streamErrorMessage: String?
    /// The blocks that are `tool_use`, in order, with their input read.
    let toolUseBlocks: [EzraToolUseBlock]
    /// How many seconds the request took. Set by the sender; 0 in a message that was only assembled.
    var durationSeconds: TimeInterval = 0

    /// The text of the reply: every `text` block, joined in order. Thinking and tool blocks are not text.
    var text: String {
        contentBlocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }
}

nonisolated enum EzraStreamedMessageNotification: Equatable {
    /// More reply text arrived; carries all the text of this reply so far.
    case textChanged(accumulatedText: String)
    case toolUseBlockStarted(toolName: String)
    case thinkingBlockStarted
}

/// Builds a reply from the events of its stream (`message_start`, `content_block_start`,
/// `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`, `error`). Every block
/// starts as the object the API sent in `content_block_start` and only has the streamed parts added
/// (text, thinking, the signature, the input of a tool call), so fields this code does not know stay.
nonisolated struct EzraStreamedMessageAssembler {
    private var blocksByIndex: [Int: [String: Any]] = [:]
    private var partialInputJSONByIndex: [Int: String] = [:]
    private var invalidInputTextByIndex: [Int: String] = [:]
    private var usageAccumulator = EzraClaudeStreamUsageAccumulator()
    private var stopReason: String?
    private var streamErrorMessage: String?

    init() {}

    @discardableResult
    mutating func consume(_ eventPayload: [String: Any]) -> [EzraStreamedMessageNotification] {
        guard let eventType = eventPayload["type"] as? String else { return [] }
        usageAccumulator.consumeStreamEvent(eventPayload)

        switch eventType {
        case "content_block_start":
            return consumeBlockStart(eventPayload)
        case "content_block_delta":
            return consumeBlockDelta(eventPayload)
        case "content_block_stop":
            consumeBlockStop(eventPayload)
            return []
        case "message_delta":
            if let delta = eventPayload["delta"] as? [String: Any], let reportedStopReason = delta["stop_reason"] as? String {
                stopReason = reportedStopReason
            }
            return []
        case "error":
            let errorObject = eventPayload["error"] as? [String: Any]
            let message = (errorObject?["message"] as? String) ?? "the stream reported an error"
            let errorType = (errorObject?["type"] as? String).map { "\($0): " } ?? ""
            streamErrorMessage = errorType + message
            return []
        default:
            return []
        }
    }

    private mutating func consumeBlockStart(_ eventPayload: [String: Any]) -> [EzraStreamedMessageNotification] {
        guard let blockIndex = (eventPayload["index"] as? NSNumber)?.intValue,
              let startingBlock = eventPayload["content_block"] as? [String: Any] else {
            return []
        }
        blocksByIndex[blockIndex] = startingBlock
        switch startingBlock["type"] as? String {
        case "tool_use":
            return [.toolUseBlockStarted(toolName: (startingBlock["name"] as? String) ?? "")]
        case "thinking", "redacted_thinking":
            return [.thinkingBlockStarted]
        default:
            return []
        }
    }

    private mutating func consumeBlockDelta(_ eventPayload: [String: Any]) -> [EzraStreamedMessageNotification] {
        guard let blockIndex = (eventPayload["index"] as? NSNumber)?.intValue,
              var block = blocksByIndex[blockIndex],
              let delta = eventPayload["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String else {
            return []
        }
        var notifications: [EzraStreamedMessageNotification] = []
        switch deltaType {
        case "text_delta":
            if let textChunk = delta["text"] as? String {
                block["text"] = ((block["text"] as? String) ?? "") + textChunk
                blocksByIndex[blockIndex] = block
                notifications.append(.textChanged(accumulatedText: accumulatedText()))
            }
        case "thinking_delta":
            if let thinkingChunk = delta["thinking"] as? String {
                block["thinking"] = ((block["thinking"] as? String) ?? "") + thinkingChunk
                blocksByIndex[blockIndex] = block
            }
        case "signature_delta":
            if let signatureChunk = delta["signature"] as? String {
                block["signature"] = ((block["signature"] as? String) ?? "") + signatureChunk
                blocksByIndex[blockIndex] = block
            }
        case "input_json_delta":
            if let partialJSONChunk = delta["partial_json"] as? String {
                partialInputJSONByIndex[blockIndex, default: ""] += partialJSONChunk
            }
        case "citations_delta":
            if let citation = delta["citation"] {
                var citations = (block["citations"] as? [Any]) ?? []
                citations.append(citation)
                block["citations"] = citations
                blocksByIndex[blockIndex] = block
            }
        default:
            // A delta type this code does not know changes nothing; the block keeps what it has.
            break
        }
        return notifications
    }

    private mutating func consumeBlockStop(_ eventPayload: [String: Any]) {
        guard let blockIndex = (eventPayload["index"] as? NSNumber)?.intValue else { return }
        applyStreamedInput(toBlockAt: blockIndex)
    }

    /// The `input` of a tool call is the parsed text of its `input_json_delta` chunks put together.
    /// No chunks means the empty object the block started with. Text that is not a JSON object is
    /// remembered so the loop can hand it back to the model as an error.
    private mutating func applyStreamedInput(toBlockAt blockIndex: Int) {
        guard var block = blocksByIndex[blockIndex],
              let blockType = block["type"] as? String, blockType.hasSuffix("tool_use"),
              let streamedInputText = partialInputJSONByIndex[blockIndex] else {
            return
        }
        partialInputJSONByIndex[blockIndex] = nil
        if streamedInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        if let parsedInput = try? JSONSerialization.jsonObject(with: Data(streamedInputText.utf8)) as? [String: Any] {
            block["input"] = parsedInput
        } else {
            block["input"] = [String: Any]()
            invalidInputTextByIndex[blockIndex] = streamedInputText
        }
        blocksByIndex[blockIndex] = block
    }

    private func accumulatedText() -> String {
        blocksByIndex.keys.sorted().compactMap { blockIndex -> String? in
            guard let block = blocksByIndex[blockIndex], (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    /// The reply as far as the stream went. A block that never got its `content_block_stop` is
    /// finished here, so a stream that ends early still gives what arrived.
    mutating func finishedMessage() -> EzraStreamedMessage {
        for blockIndex in Array(partialInputJSONByIndex.keys) {
            applyStreamedInput(toBlockAt: blockIndex)
        }
        let sortedBlockIndexes = blocksByIndex.keys.sorted()
        let contentBlocks = sortedBlockIndexes.compactMap { blocksByIndex[$0] }
        var toolUseBlocks: [EzraToolUseBlock] = []
        for blockIndex in sortedBlockIndexes {
            guard let block = blocksByIndex[blockIndex], (block["type"] as? String) == "tool_use" else { continue }
            toolUseBlocks.append(EzraToolUseBlock(
                identifier: (block["id"] as? String) ?? "",
                name: (block["name"] as? String) ?? "",
                input: (block["input"] as? [String: Any]) ?? [:],
                inputWasValidJSON: invalidInputTextByIndex[blockIndex] == nil,
                rawInputText: invalidInputTextByIndex[blockIndex] ?? ""
            ))
        }
        return EzraStreamedMessage(
            contentBlocks: contentBlocks,
            stopReason: stopReason,
            tokenUsage: usageAccumulator.tokenUsage,
            streamErrorMessage: streamErrorMessage,
            toolUseBlocks: toolUseBlocks
        )
    }
}

// MARK: - The loop

nonisolated struct EzraToolLoopRequestStats: Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
    var milliseconds: Int
}

nonisolated struct EzraToolLoopResult {
    /// The last reply of the loop. Its text is the only text that is spoken.
    let finalMessage: EzraStreamedMessage
    let requestCount: Int
    /// Requests that ended in `tool_use` and were answered with tool results.
    let toolRoundTripCount: Int
    /// One entry per request, in order: input and cache tokens and how long it took, so a later
    /// round can decide whether a cache breakpoint on the first user message is worth it.
    let requestStats: [EzraToolLoopRequestStats]
    /// The sum over all requests (what the usage tab prices).
    let totalTokenUsage: EzraClaudeTokenUsage
    /// The model still asked for tools when the last request the loop may send had been answered.
    let endedBecauseOfRequestLimit: Bool
    /// The last reply was cut at the output limit or declined, so its tool calls were not run.
    let endedBecauseTheReplyWasCutOrDeclined: Bool
    /// Round 19: the reply's tool calls were run and the loop ended there, without sending their
    /// results back for words (`shouldStopAfterRequest` said so). The caller says a fixed sentence;
    /// the last reply's text, a progress note, is never used. A `var` with a default, so every way
    /// of making a result that predates it still works.
    var endedBecauseTheFinalRequestWasSkipped = false
    /// Round 19: tool calls that ran together in a group (at-once actions of one reply), over the turn.
    var parallelToolCallCount = 0
}

/// What the loop knows right after it has run one reply's tool calls (round 19), for the decision to
/// end the turn there: the request number, the reply (its stop reason and tool calls) and the results,
/// in the order of the calls.
nonisolated struct EzraToolLoopRoundSummary {
    let requestNumber: Int
    let replyMessage: EzraStreamedMessage
    let toolResults: [EzraFileToolResult]
}

extension EzraToolLoopResult {
    /// The text the turn goes on with: the last reply's text, or, when the loop ended without a
    /// reply (out of requests, or a reply cut off or declined while it held a tool call), a fixed
    /// honest sentence. The progress note that came with an unanswered tool call is never used.
    var replyTextToFinish: String {
        if endedBecauseTheFinalRequestWasSkipped {
            // The caller has the fixed sentence; the text before the tool call was a progress note.
            return ""
        }
        if endedBecauseOfRequestLimit {
            return EzraChangeSpokenSentences.ranOutOfSteps
        }
        if endedBecauseTheReplyWasCutOrDeclined {
            return EzraChangeSpokenSentences.replyWasCutOff
        }
        return finalMessage.text
    }
}

nonisolated enum EzraToolLoop {
    /// Added to the user message of the last request the loop may send, so the model answers
    /// instead of asking for another tool.
    static let lastRoundHintText = "that was the last tool round allowed in this turn. answer now in one short sentence and do not call another tool."

    /// What the model sees when a tool call's input was not valid JSON.
    static func invalidInputResultText(rawInputText: String) -> String {
        let escapedObject = (try? JSONSerialization.data(withJSONObject: ["INVALID_JSON": rawInputText]))
            .flatMap { String(data: $0, encoding: .utf8) }
        return escapedObject ?? "{\"INVALID_JSON\": \"\"}"
    }

    /// One `tool_result` block. `is_error` is only present when the call failed.
    static func toolResultBlock(toolUseIdentifier: String, resultText: String, isError: Bool) -> [String: Any] {
        var toolResultBlock: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": toolUseIdentifier,
            "content": resultText
        ]
        if isError {
            toolResultBlock["is_error"] = true
        }
        return toolResultBlock
    }

    /// Runs the loop. `sendRequest` sends one request body and returns the reply read from its
    /// stream; it may throw (a failed request or a cancelled turn). `executeToolCall` runs one tool
    /// call (name and input) and returns its result; it is a closure so the app can run the file
    /// work off the main thread (an async function that is not isolated runs on its caller's actor
    /// in the app's build settings, and the main thread must never wait on ~/Documents). The loop
    /// sends at most `EzraFileEditingLimits.maximumRequestsPerTurn` requests. It returns as soon
    /// as a reply does not ask for tools.
    ///
    /// `cacheFirstUserMessageFromRequest` (round 19): from that request number on, the current turn's
    /// user message (the one with the screenshots, the last of `baseMessages`; never the first message
    /// of a conversation with history) carries a cache breakpoint on its last block, so a later request
    /// reads from the cache what an earlier one wrote. The key is added once, before that request, and
    /// stays, so every later request only adds messages at the end. Nil (the default) never adds it,
    /// and every request is exactly what it was in round 18.
    ///
    /// `shouldStopAfterRequest` (round 19) is asked right after a reply's tool calls have run; true ends
    /// the loop there with `endedBecauseTheFinalRequestWasSkipped`, and the results are not sent back.
    /// The default never stops, which is round 18's loop.
    ///
    /// `leadingToolCallsThatMayRunTogether` and `executeToolCallInGroup` (round 19, E): how many of a
    /// reply's calls, from the first, may run at the same time, and how to run one of them. Two or more
    /// run in a task group; their input goes in as JSON `Data` (a `[String: Any]` is not `Sendable`), the
    /// results are put back in the calls' order, and the calls after the group run one by one as
    /// before. The defaults run every call one by one, which is round 18's loop.
    static func run(
        baseMessages: [[String: Any]],
        buildRequestBody: ([[String: Any]]) -> [String: Any],
        executeToolCall: (String, [String: Any]) async -> EzraFileToolResult,
        sendRequest: ([String: Any], Int) async throws -> EzraStreamedMessage,
        cacheFirstUserMessageFromRequest: Int? = nil,
        shouldStopAfterRequest: (EzraToolLoopRoundSummary) -> Bool = { _ in false },
        leadingToolCallsThatMayRunTogether: ([EzraToolUseBlock]) -> Int = { _ in 0 },
        executeToolCallInGroup: (@Sendable (String, Data) async -> EzraFileToolResult)? = nil
    ) async throws -> EzraToolLoopResult {
        var messages = baseMessages
        var requestStats: [EzraToolLoopRequestStats] = []
        var totalTokenUsage = EzraClaudeTokenUsage()
        var toolRoundTripCount = 0
        var parallelToolCallCount = 0
        let maximumRequestCount = EzraFileEditingLimits.maximumRequestsPerTurn
        // The current turn's user message is the last base message; the history pairs come before it.
        let currentTurnUserMessageIndex = baseMessages.count - 1
        var currentTurnUserMessageCarriesTheBreakpoint = false

        var lastMessage: EzraStreamedMessage?
        for requestNumber in 1...maximumRequestCount {
            try Task.checkCancellation()

            if let cacheFirstUserMessageFromRequest,
               requestNumber >= cacheFirstUserMessageFromRequest,
               !currentTurnUserMessageCarriesTheBreakpoint,
               currentTurnUserMessageIndex >= 0,
               (messages[currentTurnUserMessageIndex]["role"] as? String) == "user",
               let currentTurnContentBlocks = messages[currentTurnUserMessageIndex]["content"] as? [[String: Any]] {
                messages[currentTurnUserMessageIndex]["content"] = EzraClaudeChatRequestBuilder.addingCacheBreakpointToLastBlock(of: currentTurnContentBlocks)
                currentTurnUserMessageCarriesTheBreakpoint = true
            }

            let requestBody = buildRequestBody(messages)
            let replyMessage = try await sendRequest(requestBody, requestNumber)
            try Task.checkCancellation()
            lastMessage = replyMessage

            requestStats.append(EzraToolLoopRequestStats(
                inputTokens: replyMessage.tokenUsage.inputTokens,
                outputTokens: replyMessage.tokenUsage.outputTokens,
                cacheCreationInputTokens: replyMessage.tokenUsage.cacheCreationInputTokens,
                cacheReadInputTokens: replyMessage.tokenUsage.cacheReadInputTokens,
                milliseconds: max(0, Int((replyMessage.durationSeconds * 1000).rounded()))
            ))
            totalTokenUsage = adding(replyMessage.tokenUsage, to: totalTokenUsage)

            guard replyMessage.stopReason == "tool_use", !replyMessage.toolUseBlocks.isEmpty else {
                // An answer, or a reply cut at the output limit or declined. A cut reply may hold a
                // half-written tool call, which is never run.
                let wasCutOrDeclined = !replyMessage.toolUseBlocks.isEmpty
                var answerResult = EzraToolLoopResult(
                    finalMessage: replyMessage,
                    requestCount: requestNumber,
                    toolRoundTripCount: toolRoundTripCount,
                    requestStats: requestStats,
                    totalTokenUsage: totalTokenUsage,
                    endedBecauseOfRequestLimit: false,
                    endedBecauseTheReplyWasCutOrDeclined: wasCutOrDeclined
                )
                answerResult.parallelToolCallCount = parallelToolCallCount
                return answerResult
            }
            if requestNumber == maximumRequestCount {
                break
            }

            // The assistant message goes back with every block exactly as received (thinking blocks
            // with their signature included), then one user message answers every tool call.
            messages.append(["role": "assistant", "content": replyMessage.contentBlocks])
            var userContentBlocks: [[String: Any]] = []
            var toolResultsInOrder: [EzraFileToolResult] = []
            // Round 19 (E): the leading calls that may run together run first, in a group; their
            // results wait here, by position, until their turn comes in the loop below.
            var resultsOfTheGroupByIndex: [Int: EzraFileToolResult] = [:]
            if let executeToolCallInGroup {
                let groupSize = min(leadingToolCallsThatMayRunTogether(replyMessage.toolUseBlocks), replyMessage.toolUseBlocks.count)
                if groupSize >= 2 {
                    let groupCalls: [(index: Int, toolName: String, inputData: Data)] = replyMessage.toolUseBlocks.prefix(groupSize).enumerated().map { index, toolUseBlock in
                        (index, toolUseBlock.name, (try? JSONSerialization.data(withJSONObject: toolUseBlock.input)) ?? Data("{}".utf8))
                    }
                    resultsOfTheGroupByIndex = await withTaskGroup(of: (Int, EzraFileToolResult).self) { group in
                        for groupCall in groupCalls {
                            group.addTask {
                                (groupCall.index, await executeToolCallInGroup(groupCall.toolName, groupCall.inputData))
                            }
                        }
                        var collectedResults: [Int: EzraFileToolResult] = [:]
                        for await (index, toolResult) in group {
                            collectedResults[index] = toolResult
                        }
                        return collectedResults
                    }
                    parallelToolCallCount += groupSize
                }
            }
            for (toolUseIndex, toolUseBlock) in replyMessage.toolUseBlocks.enumerated() {
                if let resultOfTheGroup = resultsOfTheGroupByIndex[toolUseIndex] {
                    toolResultsInOrder.append(resultOfTheGroup)
                    userContentBlocks.append(toolResultBlock(
                        toolUseIdentifier: toolUseBlock.identifier,
                        resultText: resultOfTheGroup.text,
                        isError: resultOfTheGroup.isError
                    ))
                    continue
                }
                if !toolUseBlock.inputWasValidJSON {
                    let invalidInputResult = EzraFileToolResult.failure(invalidInputResultText(rawInputText: toolUseBlock.rawInputText))
                    toolResultsInOrder.append(invalidInputResult)
                    userContentBlocks.append(toolResultBlock(
                        toolUseIdentifier: toolUseBlock.identifier,
                        resultText: invalidInputResult.text,
                        isError: true
                    ))
                    continue
                }
                let toolResult = await executeToolCall(toolUseBlock.name, toolUseBlock.input)
                toolResultsInOrder.append(toolResult)
                userContentBlocks.append(toolResultBlock(
                    toolUseIdentifier: toolUseBlock.identifier,
                    resultText: toolResult.text,
                    isError: toolResult.isError
                ))
            }
            // Round 19: the turn may end here, with the action done and a fixed sentence to say.
            if shouldStopAfterRequest(EzraToolLoopRoundSummary(requestNumber: requestNumber, replyMessage: replyMessage, toolResults: toolResultsInOrder)) {
                var skippedResult = EzraToolLoopResult(
                    finalMessage: replyMessage,
                    requestCount: requestNumber,
                    toolRoundTripCount: toolRoundTripCount,
                    requestStats: requestStats,
                    totalTokenUsage: totalTokenUsage,
                    endedBecauseOfRequestLimit: false,
                    endedBecauseTheReplyWasCutOrDeclined: false
                )
                skippedResult.endedBecauseTheFinalRequestWasSkipped = true
                skippedResult.parallelToolCallCount = parallelToolCallCount
                return skippedResult
            }
            if requestNumber + 1 == maximumRequestCount {
                userContentBlocks.append(["type": "text", "text": lastRoundHintText])
            }
            messages.append(["role": "user", "content": userContentBlocks])
            toolRoundTripCount += 1
        }

        // The last request the loop may send still asked for tools: there is no reply to give.
        var limitResult = EzraToolLoopResult(
            finalMessage: lastMessage!,
            requestCount: maximumRequestCount,
            toolRoundTripCount: toolRoundTripCount,
            requestStats: requestStats,
            totalTokenUsage: totalTokenUsage,
            endedBecauseOfRequestLimit: true,
            endedBecauseTheReplyWasCutOrDeclined: false
        )
        limitResult.parallelToolCallCount = parallelToolCallCount
        return limitResult
    }

    private static func adding(_ usage: EzraClaudeTokenUsage, to total: EzraClaudeTokenUsage) -> EzraClaudeTokenUsage {
        func sum(_ first: Int?, _ second: Int?) -> Int? {
            if first == nil && second == nil { return nil }
            return (first ?? 0) + (second ?? 0)
        }
        return EzraClaudeTokenUsage(
            inputTokens: sum(total.inputTokens, usage.inputTokens),
            outputTokens: sum(total.outputTokens, usage.outputTokens),
            cacheCreationInputTokens: sum(total.cacheCreationInputTokens, usage.cacheCreationInputTokens),
            cacheReadInputTokens: sum(total.cacheReadInputTokens, usage.cacheReadInputTokens)
        )
    }
}
