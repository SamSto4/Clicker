//
//  ClickyVoiceListClient.swift
//  leanring-buddy
//
//  Asks the Cloudflare Worker's /voices route (round 20, the voice picker) for the ElevenLabs voices
//  of Sam's account and the Worker's default voice, and returns them read by the tolerant
//  `ClickyVoiceList.decode`. The Worker holds the ElevenLabs key; the app only ever sees ids, names,
//  categories and labels (the Worker side is the orchestrator's PR).
//
//  Called only when the settings tab opens and on its "refresh" button, never at launch, and never in
//  the panel self test. Nothing is printed here: the caller prints a count at most, never a name or id.
//

import Foundation

/// Not tied to the main actor: the request and the decoding need nothing of it.
nonisolated final class ClickyVoiceListClient: Sendable {
    /// The whole request is limited to this long, so a stuck connection cannot keep the picker
    /// "loading" for ever.
    static let requestTimeoutSeconds: TimeInterval = 8

    private let voicesURL: URL?
    private let appTokenHeaderName: String
    private let appToken: String
    private let session: URLSession

    /// `sessionConfiguration` is only for the offline checks, which answer the request in-process.
    init(workerBaseURL: String, appTokenHeaderName: String, appToken: String, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.voicesURL = workerBaseURL.isEmpty ? nil : URL(string: "\(workerBaseURL)/voices")
        self.appTokenHeaderName = appTokenHeaderName
        self.appToken = appToken

        // Nothing is cached or stored by the session: the app keeps its own copy of the list.
        let configuration = sessionConfiguration ?? URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = Self.requestTimeoutSeconds + 0.5
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    /// False when no Worker address is configured; then no list can be fetched.
    var isConfigured: Bool {
        voicesURL != nil
    }

    /// POST /voices with the app token and an empty JSON object. Returns the list, or nil for any
    /// failure (no Worker address, offline, a timeout, a status other than 200, a body that is not a
    /// JSON object). It never throws, because every failure has the same remedy: the tab keeps the
    /// list it has and says it could not load a new one.
    func fetchVoiceList(now: Date = Date()) async -> ClickyVoiceList? {
        guard let voicesURL else {
            return nil
        }
        var voicesRequest = URLRequest(
            url: voicesURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeoutSeconds
        )
        voicesRequest.httpMethod = "POST"
        voicesRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        voicesRequest.setValue(appToken, forHTTPHeaderField: appTokenHeaderName)
        voicesRequest.httpBody = Data("{}".utf8)

        do {
            let (responseData, response) = try await session.data(for: voicesRequest)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            return ClickyVoiceList.decode(responseData, fetchedAt: now)
        } catch {
            return nil
        }
    }
}
