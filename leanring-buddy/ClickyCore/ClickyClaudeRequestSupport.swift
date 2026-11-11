import Foundation

/// Builds the `system` field of a Claude request as two blocks, so the API can cache the first one.
///
/// The static block (the base prompt) is the same on every turn, so it carries a cache breakpoint:
/// from the second turn on, the API reads it from its cache instead of processing it again. The
/// dynamic block (skills, the "right now" block, saved notes) changes between turns, so it comes
/// after the breakpoint and is never cached.
nonisolated enum ClickySystemPromptBlocks {
    /// Returns the exact `system` array to send. The static block comes first and carries
    /// `cache_control`; the dynamic block follows. A blank dynamic part sends only the static block.
    static func makeSystemBlocks(staticText: String, dynamicText: String) -> [[String: Any]] {
        var systemBlocks: [[String: Any]] = []

        // The API rejects empty or whitespace-only text blocks, so a blank part is left out
        // instead of being sent as an empty block.
        if !isBlank(staticText) {
            systemBlocks.append([
                "type": "text",
                "text": staticText,
                "cache_control": ["type": "ephemeral"]
            ])
        }
        if !isBlank(dynamicText) {
            systemBlocks.append([
                "type": "text",
                "text": dynamicText
            ])
        }
        return systemBlocks
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Token counts Claude reports for one request. A field is nil when the stream never reported it.
nonisolated struct ClickyClaudeTokenUsage: Equatable {
    /// Input tokens that were neither written to nor read from the cache.
    var inputTokens: Int?
    var outputTokens: Int?
    /// Input tokens written to the prompt cache on this request.
    var cacheCreationInputTokens: Int?
    /// Input tokens served from the prompt cache on this request.
    var cacheReadInputTokens: Int?
}

/// Reads token usage out of the server-sent events of a streaming Claude response.
///
/// `message_start` reports the input side (input, cache creation, cache read). `message_delta`
/// reports the running output token count; its last value is the total.
nonisolated struct ClickyClaudeStreamUsageAccumulator {
    private(set) var tokenUsage = ClickyClaudeTokenUsage()

    /// Pass every decoded event payload here. Events that carry no usage are ignored.
    mutating func consumeStreamEvent(_ eventPayload: [String: Any]) {
        guard let eventType = eventPayload["type"] as? String else { return }

        if eventType == "message_start",
           let messageObject = eventPayload["message"] as? [String: Any],
           let usageObject = messageObject["usage"] as? [String: Any] {
            tokenUsage.inputTokens = Self.tokenCount(named: "input_tokens", in: usageObject)
            tokenUsage.cacheCreationInputTokens = Self.tokenCount(named: "cache_creation_input_tokens", in: usageObject)
            tokenUsage.cacheReadInputTokens = Self.tokenCount(named: "cache_read_input_tokens", in: usageObject)
            // message_start carries a first output count (usually 1). It is replaced by the
            // real total from message_delta, but kept if the stream ends before any delta.
            tokenUsage.outputTokens = Self.tokenCount(named: "output_tokens", in: usageObject)
        }

        if eventType == "message_delta",
           let usageObject = eventPayload["usage"] as? [String: Any],
           let outputTokenCount = Self.tokenCount(named: "output_tokens", in: usageObject) {
            tokenUsage.outputTokens = outputTokenCount
        }
    }

    private static func tokenCount(named fieldName: String, in usageObject: [String: Any]) -> Int? {
        (usageObject[fieldName] as? NSNumber)?.intValue
    }
}
