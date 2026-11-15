//
//  EzraWorkerConfiguration.swift
//  leanring-buddy
//
//  Reads the Cloudflare Worker address and the shared app token from
//  ClickyWorkerSecrets.plist. That file is git-ignored so your Worker URL
//  and token never end up in the repository. Copy
//  ClickyWorkerSecrets.example.plist (at the repo root) into the
//  leanring-buddy folder as ClickyWorkerSecrets.plist and fill it in.
//

import Foundation

enum EzraWorkerConfiguration {
    /// Header the Worker checks on every request. Must match
    /// APP_TOKEN_HEADER_NAME in worker/src/index.ts. It keeps the app's name from before the
    /// rename to Ezra on purpose: it is part of the deployed Worker's contract, and Sam's running
    /// Worker answers 401 to a request without exactly this header.
    static let appTokenHeaderName = "X-Clicky-App-Token"

    /// The secrets file keeps its name from before the rename to Ezra, so the git-ignored file on
    /// Sam's Mac (the Worker address and token) never has to move or be renamed.
    private static let secretsFileName = "ClickyWorkerSecrets"
    private static let workerBaseURLKey = "WorkerBaseURL"
    private static let workerAppTokenKey = "WorkerAppToken"

    private static let secretsDictionary: NSDictionary? = {
        guard let secretsFilePath = Bundle.main.path(forResource: secretsFileName, ofType: "plist") else {
            print("⚠️ Ezra: \(secretsFileName).plist is missing from the app bundle. Copy ClickyWorkerSecrets.example.plist into leanring-buddy/ as \(secretsFileName).plist and fill in your Worker URL and app token.")
            return nil
        }
        return NSDictionary(contentsOfFile: secretsFilePath)
    }()

    private static func trimmedSecretValue(forKey key: String) -> String {
        let rawValue = secretsDictionary?[key] as? String ?? ""
        return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Base URL of your deployed Worker, with no trailing slash,
    /// e.g. https://clicky-proxy.your-name.workers.dev
    static var workerBaseURL: String {
        var baseURL = trimmedSecretValue(forKey: workerBaseURLKey)
        while baseURL.hasSuffix("/") {
            baseURL.removeLast()
        }
        if baseURL.isEmpty {
            print("⚠️ Ezra: \(workerBaseURLKey) is empty in \(secretsFileName).plist; requests to the Worker will fail.")
        }
        return baseURL
    }

    /// Shared token the Worker requires in the X-Clicky-App-Token header.
    /// Must match the CLICKY_APP_TOKEN secret set with wrangler.
    static var workerAppToken: String {
        let appToken = trimmedSecretValue(forKey: workerAppTokenKey)
        if appToken.isEmpty {
            print("⚠️ Ezra: \(workerAppTokenKey) is empty in \(secretsFileName).plist; the Worker will answer 401 Unauthorized.")
        }
        return appToken
    }

    /// Adds the app token header to a request bound for the Worker.
    static func addAppTokenHeader(to workerRequest: inout URLRequest) {
        workerRequest.setValue(workerAppToken, forHTTPHeaderField: appTokenHeaderName)
    }
}
