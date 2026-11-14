//
//  ClickyMemoryCompactionClient.swift
//  leanring-buddy
//
//  Sends one finished chat (as text) to the Cloudflare Worker's /chat route to be compacted into a
//  few short memory lines, and returns the model's text or why there is none.
//
//  Privacy: the request carries only the chat's stored, redacted text and a fixed instruction
//  (see `ClickyMemoryCompaction.makeRequestBody`); nothing is printed or stored here. The Worker
//  token is read once by the caller and only ever put in the request header.
//

import Foundation

/// Not tied to the main actor on purpose: the quit path waits for this request on the main thread,
/// so the request must not need the main thread to make progress.
nonisolated final class ClickyMemoryCompactionClient: Sendable {
    private let chatURL: URL?
    private let appTokenHeaderName: String
    private let appToken: String
    private let session: URLSession

    init(workerBaseURL: String, appTokenHeaderName: String, appToken: String) {
        self.chatURL = workerBaseURL.isEmpty ? nil : URL(string: "\(workerBaseURL)/chat")
        self.appTokenHeaderName = appTokenHeaderName
        self.appToken = appToken

        // Nothing is cached or stored on disk. The whole request, not only the wait for more data,
        // is limited, so a stuck connection cannot hold a compaction run for ever.
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = ClickyMemoryCompaction.requestTimeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = ClickyMemoryCompaction.requestTimeoutSeconds + 0.5
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        self.session = URLSession(configuration: sessionConfiguration)
    }

    /// False when no Worker address is configured, in which case nothing is compacted (the chats
    /// stay pending).
    var isConfigured: Bool {
        chatURL != nil
    }

    /// Sends the request body and returns the model's text and token usage, or `.failed`. It never
    /// throws, because every failure has the same remedy: the chat stays pending and the next
    /// trigger tries again.
    func requestCompaction(withBodyData requestBodyData: Data, timeoutSeconds: TimeInterval) async -> ClickyMemoryModelResponse {
        guard let chatURL else {
            return .failed
        }
        var compactionRequest = URLRequest(
            url: chatURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutSeconds
        )
        compactionRequest.httpMethod = "POST"
        compactionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        compactionRequest.setValue(appToken, forHTTPHeaderField: appTokenHeaderName)
        compactionRequest.httpBody = requestBodyData

        do {
            let (responseData, response) = try await session.data(for: compactionRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let modelText = ClickyMemoryCompaction.extractModelText(fromResponseData: responseData) else {
                return .failed
            }
            return ClickyMemoryModelResponse(
                modelText: modelText,
                tokenUsage: ClickyMemoryCompaction.extractTokenUsage(fromResponseData: responseData)
            )
        } catch {
            return .failed
        }
    }
}
