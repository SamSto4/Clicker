//
//  ClickerMemoryClient.swift
//  leanring-buddy
//
//  Gives Clicker long-term memory by talking to the memory server
//  (memory_server.py in the K.I.T-Agent repo), a small Python service that
//  runs on this Mac at http://127.0.0.1:8765. The server keeps facts about
//  the user in memory.json and short summaries of past sessions in ChromaDB.
//
//  Every call fails soft: if the memory server is not running, the calls
//  return nothing and Clicker keeps working exactly as before, just without
//  long-term memory.
//

import Foundation

final class ClickerMemoryClient: Sendable {
    /// Where memory_server.py listens. 127.0.0.1 means "this Mac only".
    static let memoryServerBaseURL = URL(string: "http://127.0.0.1:8765")!

    /// Fetching context sits on the path between the user speaking and Claude
    /// answering, so it gets a short timeout: a slow memory must never make
    /// Clicker feel slow. The other calls run in the background and include a
    /// Claude call on the server side, so they get much longer timeouts.
    private static let memoryContextTimeoutInSeconds: TimeInterval = 3
    private static let backgroundMemoryWriteTimeoutInSeconds: TimeInterval = 60
    private static let sessionSummaryBeforeQuitTimeoutInSeconds: TimeInterval = 2

    private let memoryServerURLSession: URLSession

    init() {
        let memoryServerSessionConfiguration = URLSessionConfiguration.ephemeral
        memoryServerSessionConfiguration.timeoutIntervalForResource = Self.backgroundMemoryWriteTimeoutInSeconds
        memoryServerURLSession = URLSession(configuration: memoryServerSessionConfiguration)
    }

    /// Returns the text to add to Claude's system prompt: the saved facts about
    /// the user plus a related past session, if one is similar enough.
    /// Returns nil when the memory server is not reachable.
    func fetchMemoryContextForSystemPrompt(userTranscript: String) async -> String? {
        let contextResponse = await postJSONToMemoryServer(
            path: "/context",
            requestBody: ["message": userTranscript],
            timeoutInSeconds: Self.memoryContextTimeoutInSeconds
        )
        return contextResponse?["prompt"] as? String
    }

    /// Lets the memory server pick out facts worth remembering from what the
    /// user said. Only the user's own words are sent here, never screenshots
    /// or text read off the screen, so a web page or document can't plant
    /// false "facts" in Clicker's memory (memory poisoning).
    func learnFactsFromUserTranscript(userTranscript: String) async {
        let learnResponse = await postJSONToMemoryServer(
            path: "/learn",
            requestBody: ["message": userTranscript],
            timeoutInSeconds: Self.backgroundMemoryWriteTimeoutInSeconds
        )
        if let learnedFacts = learnResponse?["learned"] as? [String: Any], !learnedFacts.isEmpty {
            print("🧠 Memory: learned \(learnedFacts.keys.sorted().joined(separator: ", "))")
        }
    }

    /// Saves a short summary of these exchanges as a past session, so a later
    /// session about the same topic can recall it.
    func saveSessionSummary(conversationExchanges: [(userTranscript: String, assistantResponse: String)]) async {
        guard let sessionSummaryRequest = makeSessionSummaryRequest(
            conversationExchanges: conversationExchanges,
            timeoutInSeconds: Self.backgroundMemoryWriteTimeoutInSeconds
        ) else { return }

        do {
            _ = try await memoryServerURLSession.data(for: sessionSummaryRequest)
            print("🧠 Memory: saved a summary of \(conversationExchanges.count) exchanges")
        } catch {
            print("🧠 Memory: could not save the session summary (\(error.localizedDescription))")
        }
    }

    /// Used while the app quits, when there is no time to wait for an async
    /// task. It waits at most two seconds: long enough for the request to
    /// reach the server, which then finishes the summary on its own.
    func saveSessionSummaryBeforeQuitting(conversationExchanges: [(userTranscript: String, assistantResponse: String)]) {
        guard let sessionSummaryRequest = makeSessionSummaryRequest(
            conversationExchanges: conversationExchanges,
            timeoutInSeconds: Self.sessionSummaryBeforeQuitTimeoutInSeconds
        ) else { return }

        let requestDeliveredSemaphore = DispatchSemaphore(value: 0)
        let sessionSummaryTask = memoryServerURLSession.dataTask(with: sessionSummaryRequest) { _, _, _ in
            requestDeliveredSemaphore.signal()
        }
        sessionSummaryTask.resume()
        _ = requestDeliveredSemaphore.wait(timeout: .now() + Self.sessionSummaryBeforeQuitTimeoutInSeconds)
    }

    // MARK: - Private helpers

    private func makeSessionSummaryRequest(
        conversationExchanges: [(userTranscript: String, assistantResponse: String)],
        timeoutInSeconds: TimeInterval
    ) -> URLRequest? {
        guard !conversationExchanges.isEmpty else { return nil }

        // The server expects the same message format as remember_me.py:
        // [{"role": "user", "content": ...}, {"role": "assistant", "content": ...}, ...]
        var historyMessages: [[String: String]] = []
        for conversationExchange in conversationExchanges {
            historyMessages.append(["role": "user", "content": conversationExchange.userTranscript])
            historyMessages.append(["role": "assistant", "content": conversationExchange.assistantResponse])
        }

        return makeJSONRequest(
            path: "/end_session",
            requestBody: ["history": historyMessages],
            timeoutInSeconds: timeoutInSeconds
        )
    }

    private func makeJSONRequest(path: String, requestBody: [String: Any], timeoutInSeconds: TimeInterval) -> URLRequest? {
        guard let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }

        var request = URLRequest(url: Self.memoryServerBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBodyData
        request.timeoutInterval = timeoutInSeconds
        return request
    }

    /// Sends a JSON request and returns the JSON answer, or nil if the server
    /// is not running, answers with an error, or takes longer than the timeout.
    private func postJSONToMemoryServer(path: String, requestBody: [String: Any], timeoutInSeconds: TimeInterval) async -> [String: Any]? {
        guard let request = makeJSONRequest(path: path, requestBody: requestBody, timeoutInSeconds: timeoutInSeconds) else {
            return nil
        }

        do {
            let (responseData, response) = try await memoryServerURLSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("🧠 Memory: \(path) answered with an error")
                return nil
            }
            return try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        } catch {
            print("🧠 Memory: \(path) unavailable (\(error.localizedDescription)). Is memory_server.py running?")
            return nil
        }
    }
}
