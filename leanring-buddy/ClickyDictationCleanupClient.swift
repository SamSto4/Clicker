//
//  ClickyDictationCleanupClient.swift
//  leanring-buddy
//
//  Sends one dictated transcript to the Cloudflare Worker's /chat route to be tidied up
//  (punctuation, capitals, filler words) and returns the answer or why there is none.
//
//  Privacy: the request carries only the spoken transcript and a fixed instruction. The transcript
//  is never printed or stored here.
//

import Foundation

final class ClickyDictationCleanupClient {
    private let chatURL: URL?
    private let session: URLSession
    private let systemPromptText: String

    /// The last time anything went over this client's connection. The connection is warmed up
    /// before a dictation only when it has probably gone cold since.
    private var lastConnectionActivityDate: Date?
    private static let connectionConsideredColdAfterSeconds: TimeInterval = 30

    init(
        workerBaseURL: String = ClickyWorkerConfiguration.workerBaseURL,
        promptsDirectoryURL: URL? = ClickyPromptAssembler.promptsDirectoryURL(in: .main)
    ) {
        self.chatURL = workerBaseURL.isEmpty ? nil : URL(string: "\(workerBaseURL)/chat")
        self.systemPromptText = ClickyDictationCleanup.loadSystemPromptText(promptsDirectoryURL: promptsDirectoryURL)

        // The Worker answers this non-streaming request in one piece, so the request timeout is
        // effectively the whole wait. Nothing is cached or stored on disk.
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = ClickyDictationCleanup.requestTimeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = ClickyDictationCleanup.requestTimeoutSeconds + 0.5
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        self.session = URLSession(configuration: sessionConfiguration)
    }

    /// False when no Worker address is configured, in which case cleanup is skipped.
    var isConfigured: Bool {
        chatURL != nil
    }

    /// Opens the network connection to the Worker before it is needed. A dictation takes longer
    /// than a connection setup, so doing this when the keys go down hides the setup time from the
    /// wait after the keys come up. It carries no data and its answer is ignored.
    func warmUpConnectionIfItHasGoneCold() {
        guard let chatURL else { return }
        if let lastConnectionActivityDate,
           Date().timeIntervalSince(lastConnectionActivityDate) < Self.connectionConsideredColdAfterSeconds {
            return
        }
        lastConnectionActivityDate = Date()

        guard var warmUpURLComponents = URLComponents(url: chatURL, resolvingAgainstBaseURL: false) else { return }
        warmUpURLComponents.path = "/"
        warmUpURLComponents.query = nil
        guard let warmUpURL = warmUpURLComponents.url else { return }

        var warmUpRequest = URLRequest(url: warmUpURL)
        warmUpRequest.httpMethod = "HEAD"
        warmUpRequest.timeoutInterval = 5
        session.dataTask(with: warmUpRequest) { _, _, _ in }.resume()
    }

    /// Asks the model to clean up `rawTranscript`. Always returns within the cleanup time limit:
    /// the answer, `.timedOut`, or `.failed`. It never throws, because every failure has the same
    /// remedy (insert the raw transcript).
    func requestCleanedText(forRawTranscript rawTranscript: String) async -> ClickyDictationCleanupModelResult {
        guard let chatURL else { return .failed }

        let requestBody = ClickyDictationCleanup.makeRequestBody(
            rawTranscript: rawTranscript,
            systemPromptText: systemPromptText
        )
        guard let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return .failed
        }

        var cleanupRequest = URLRequest(
            url: chatURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: ClickyDictationCleanup.requestTimeoutSeconds
        )
        cleanupRequest.httpMethod = "POST"
        cleanupRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.addAppTokenHeader(to: &cleanupRequest)
        cleanupRequest.httpBody = requestBodyData

        lastConnectionActivityDate = Date()
        let urlSessionForRequest = session
        let timeoutNanoseconds = UInt64(ClickyDictationCleanup.requestTimeoutSeconds * 1_000_000_000)

        // The request and a stopwatch race each other, so the 2.5 second limit holds even if the
        // network layer would keep waiting. Whichever finishes first decides, and the other is
        // cancelled.
        return await withTaskGroup(of: ClickyDictationCleanupModelResult.self) { raceGroup in
            raceGroup.addTask {
                await Self.performRequest(cleanupRequest, using: urlSessionForRequest)
            }
            raceGroup.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            }
            let firstFinishedResult = await raceGroup.next() ?? .failed
            raceGroup.cancelAll()
            return firstFinishedResult
        }
    }

    private nonisolated static func performRequest(
        _ cleanupRequest: URLRequest,
        using session: URLSession
    ) async -> ClickyDictationCleanupModelResult {
        do {
            let (responseData, response) = try await session.data(for: cleanupRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let cleanedText = ClickyDictationCleanup.extractText(fromResponseData: responseData) else {
                return .failed
            }
            return .text(cleanedText)
        } catch let urlError as URLError where urlError.code == .timedOut {
            return .timedOut
        } catch {
            return .failed
        }
    }
}
