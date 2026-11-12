//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//

import Foundation

/// What a streaming request returns: the reply, how long it took, and the token counts Claude reported.
struct ClaudeStreamingResult {
    let text: String
    let duration: TimeInterval
    /// Input, output, cache-creation and cache-read token counts. A count is nil if the stream never reported it.
    let tokenUsage: ClickyClaudeTokenUsage
}

/// Claude API helper with streaming for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "claude-sonnet-5-5") {
        self.apiURL = URL(string: proxyURL)!
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.addAppTokenHeader(to: &request)
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/v1/messages` avoids extra endpoint-specific noise.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a vision request to Claude with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    /// The system prompt goes out as one plain string (used by the onboarding demo).
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let streamingResult = try await streamReply(
            images: images,
            systemPromptValue: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
        return (text: streamingResult.text, duration: streamingResult.duration)
    }

    /// Same streaming request, but the system prompt is sent as two blocks so Anthropic can cache
    /// the first. `staticSystemPrompt` must be identical on every turn (it carries the cache
    /// breakpoint); `dynamicSystemPrompt` holds everything that changes per turn and follows it.
    /// Also returns the token counts Claude reported, including cache creation and cache reads.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        staticSystemPrompt: String,
        dynamicSystemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> ClaudeStreamingResult {
        return try await streamReply(
            images: images,
            systemPromptValue: ClickySystemPromptBlocks.makeSystemBlocks(
                staticText: staticSystemPrompt,
                dynamicText: dynamicSystemPrompt
            ),
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
    }

    /// Does the actual streaming request for both public entry points. `systemPromptValue` is
    /// either a String or an array of system blocks; both are valid values for the API's `system` field.
    private func streamReply(
        images: [(data: Data, label: String)],
        systemPromptValue: Any,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> ClaudeStreamingResult {
        let startTime = Date()

        var request = makeAPIRequest()

        // Build messages array
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
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
        messages.append(["role": "user", "content": contentBlocks])

        // Low effort and hidden thinking off are added by one shared function; the reasons and
        // the measurements are at `ClickyClaudeRequestSettings`.
        let body = ClickyClaudeRequestSettings.addingSpokenReplySettings(to: [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPromptValue,
            "messages": messages
        ])

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse SSE stream — each event is "data: {json}\n\n"
        var accumulatedResponseText = ""
        var streamUsageAccumulator = ClickyClaudeStreamUsageAccumulator()

        for try await line in byteStream.lines {
            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // End of stream marker
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            // message_start and message_delta events report token usage (input and cache
            // counts first, output count at the end); other events are ignored by the accumulator.
            streamUsageAccumulator.consumeStreamEvent(eventPayload)

            // We care about content_block_delta events that contain text chunks
            if eventType == "content_block_delta",
               let delta = eventPayload["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let textChunk = delta["text"] as? String {
                accumulatedResponseText += textChunk
                // Send the accumulated text so far to the UI for progressive rendering
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return ClaudeStreamingResult(
            text: accumulatedResponseText,
            duration: duration,
            tokenUsage: streamUsageAccumulator.tokenUsage
        )
    }

    /// What the tool loop reports while a reply streams in, so the turn can show progress and stop
    /// the early speech fetch. Both cases name the request of the loop they belong to (1 is the first).
    enum ToolLoopProgress {
        /// All the text of this request's reply so far. In a request that ends with a tool call this is a
        /// progress note ("i'll open your notes file"), not the answer.
        case replyTextChanged(accumulatedText: String, requestNumber: Int)
        /// A `tool_use` block started, so the text of this request was a progress note.
        case toolUseStarted(toolName: String, requestNumber: Int)
    }

    /// The same streaming chat request as `analyzeImageStreaming`, with the file tools added and the
    /// loop that answers the model's tool calls (`ClickyToolLoop`) around it. Each request carries
    /// the same two system blocks and the same tools; only messages are added at the end. The
    /// session runs the tools and keeps the changes the model proposed.
    func analyzeImageStreamingWithFileTools(
        images: [(data: Data, label: String)],
        staticSystemPrompt: String,
        dynamicSystemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        toolSession: ClickyFileToolTurnSession,
        onProgress: @MainActor @Sendable (ToolLoopProgress) -> Void
    ) async throws -> ClickyToolLoopResult {
        let systemBlocks = ClickySystemPromptBlocks.makeSystemBlocks(
            staticText: staticSystemPrompt,
            dynamicText: dynamicSystemPrompt
        )
        let tools = ClickyFileToolDefinitions.toolsArray()
        let baseMessages = ClickyClaudeChatRequestBuilder.messages(
            conversationHistory: conversationHistory,
            currentUserContentBlocks: ClickyClaudeChatRequestBuilder.currentUserContentBlocks(images: images, userPrompt: userPrompt)
        )
        let modelForThisTurn = model
        return try await ClickyToolLoop.run(
            baseMessages: baseMessages,
            buildRequestBody: { messagesSoFar in
                ClickyClaudeChatRequestBuilder.streamingRequestBody(
                    model: modelForThisTurn,
                    systemPromptValue: systemBlocks,
                    messages: messagesSoFar,
                    tools: tools
                )
            },
            executeToolCall: { toolName, toolInput in
                // The file work (reading, listing, checking a proposal) runs off the main thread.
                await Task.detached(priority: .userInitiated) {
                    toolSession.execute(toolName: toolName, input: toolInput)
                }.value
            },
            sendRequest: { requestBody, requestNumber in
                try await self.streamOneRequestOfToolLoop(
                    requestBody: requestBody,
                    requestNumber: requestNumber,
                    imageCount: images.count,
                    onProgress: onProgress
                )
            }
        )
    }

    /// Sends one request of the tool loop and reads its stream into content blocks kept as received
    /// (`ClickyStreamedMessageAssembler`).
    private func streamOneRequestOfToolLoop(
        requestBody: [String: Any],
        requestNumber: Int,
        imageCount: Int,
        onProgress: @MainActor @Sendable (ToolLoopProgress) -> Void
    ) async throws -> ClickyStreamedMessage {
        let startTime = Date()
        var request = makeAPIRequest()
        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming request \(requestNumber) (file tools): \(String(format: "%.1f", payloadMB))MB, \(imageCount) image(s)")

        let (byteStream, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var messageAssembler = ClickyStreamedMessageAssembler()
        for try await line in byteStream.lines {
            guard let eventPayload = ClickyServerSentEventLine.eventPayload(fromLine: line) else { continue }
            for notification in messageAssembler.consume(eventPayload) {
                switch notification {
                case .textChanged(let accumulatedText):
                    await onProgress(.replyTextChanged(accumulatedText: accumulatedText, requestNumber: requestNumber))
                case .toolUseBlockStarted(let toolName):
                    await onProgress(.toolUseStarted(toolName: toolName, requestNumber: requestNumber))
                case .thinkingBlockStarted:
                    break
                }
            }
        }

        var streamedMessage = messageAssembler.finishedMessage()
        streamedMessage.durationSeconds = Date().timeIntervalSince(startTime)
        // An error event in the middle of a stream (such as "overloaded") is a failed request.
        if let streamErrorMessage = streamedMessage.streamErrorMessage {
            throw NSError(
                domain: "ClaudeAPI",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "API stream error: \(streamErrorMessage)"]
            )
        }
        return streamedMessage
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
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
        messages.append(["role": "user", "content": contentBlocks])

        // Same two settings as the streaming request: low effort and hidden thinking off.
        let body = ClickyClaudeRequestSettings.addingSpokenReplySettings(to: [
            "model": model,
            "max_tokens": 256,
            "system": systemPrompt,
            "messages": messages
        ])

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ClaudeAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
