import Foundation

/// What Ezra does about a turn that failed.
nonisolated enum EzraTurnFailureResponse: Equatable {
    /// Say this short sentence with the Mac's own voice and show it in the status pill.
    case speakSentence(String)
    /// The answer itself is fine and only the voice failed: say nothing (an error sentence would
    /// talk over a good answer) and show the answer as a notice in the status pill instead.
    case showReplyAsNoticeWithoutSpeaking
}

/// Chooses the honest sentence Ezra speaks when a turn fails.
///
/// Why this exists: every failure used to be spoken as "I'm all out of credits", which was wrong
/// for almost all of them (no network, a rejected app token, a rate limit, a missing screen
/// recording permission) and sent the user looking in the wrong place. The sentence now follows
/// from the step that failed and the error it failed with. Pure, so every case is tested.
nonisolated enum EzraTurnFailureMessage {
    static let cannotReachInternetSentence = "i can't reach the internet right now."
    static let appTokenRejectedSentence = "my app key was rejected. check the worker token."
    static let outOfCreditSentence = "the ai account is out of credit."
    static let rateLimitedSentence = "i'm being rate limited. try again in a moment."
    static let aiServiceProblemSentence = "the ai service had a problem. try again."
    static let screenCaptureFailedSentence = "i couldn't see your screen. check screen recording permission."
    /// Round 19: the Worker's daily spend cap was reached (Sam's decision of 14 Nov 2026: 600 chat
    /// requests and 60,000 speech characters a day). The Worker answers HTTP 429 with the body
    /// `{"error":{"type":"clicky_daily_cap","message":"daily cap reached"}}` and the header
    /// `X-Clicky-Cap: daily`; any other 429 is a rate limit.
    static let dailySpendingCapSentence = "i've hit today's spending cap."
    /// The error type and the header keep the app's name from before the rename to Ezra on purpose:
    /// they are part of the deployed Worker's contract (worker/src/dailyCap.ts sends exactly these).
    static let dailyCapErrorType = "clicky_daily_cap"
    static let dailyCapHeaderName = "X-Clicky-Cap"

    /// The keys under which `ClaudeAPI` and `ElevenLabsTTSClient` put a failed response's body and its
    /// `X-Clicky-Cap` header into the error they throw (round 19), so the cap can be told apart.
    static let responseBodyUserInfoKey = "EzraFailedResponseBody"
    static let dailyCapHeaderUserInfoKey = "EzraFailedResponseDailyCapHeader"

    /// True for the Worker's daily cap: an HTTP 429 that carries the `X-Clicky-Cap` header, or whose
    /// body says `"type":"clicky_daily_cap"` (read as JSON when it is JSON, else looked for as text).
    static func isDailySpendingCap(httpStatusCode: Int?, responseBody: String?, dailyCapHeaderValue: String?) -> Bool {
        guard httpStatusCode == 429 else {
            return false
        }
        if let dailyCapHeaderValue, !dailyCapHeaderValue.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        guard let responseBody, !responseBody.isEmpty else {
            return false
        }
        if let bodyObject = try? JSONSerialization.jsonObject(with: Data(responseBody.utf8)) as? [String: Any],
           let errorObject = bodyObject["error"] as? [String: Any] {
            return (errorObject["type"] as? String) == dailyCapErrorType
        }
        return responseBody.contains("\"\(dailyCapErrorType)\"")
    }

    /// Put in front of the reply text in the status pill when the voice failed.
    static let voiceUnavailableNoticePrefix = "voice unavailable"

    /// The error domains `ClaudeAPI` and `ElevenLabsTTSClient` use for a response with a failing
    /// HTTP status. Their error code is that status.
    private static let errorDomainsWhoseCodeIsAnHTTPStatus: Set<String> = ["ClaudeAPI", "ElevenLabsTTS"]

    /// URL loading error codes that mean the request never reached the Worker: no connection,
    /// timed out, host not found, cannot connect, connection lost, DNS failure, no secure
    /// connection, roaming off, data not allowed.
    private static let urlErrorCodesMeaningTheWorkerWasNotReached: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorSecureConnectionFailed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorDataNotAllowed,
    ]

    /// Words a provider uses when the account has no credit left. Anthropic, for example, answers
    /// HTTP 400 with "Your credit balance is too low", so the status alone does not show it.
    private static let billingMessageFragments = [
        "credit balance",
        "out of credit",
        "insufficient credit",
        "insufficient_quota",
        "quota exceeded",
        "billing",
        "payment required",
    ]

    /// The HTTP status inside an error thrown by the Claude or speech client, or nil when the
    /// error is not an HTTP failure (those clients use -1 for "no usable response").
    static func httpStatusCode(errorDomain: String, errorCode: Int) -> Int? {
        guard errorDomainsWhoseCodeIsAnHTTPStatus.contains(errorDomain), (100...599).contains(errorCode) else {
            return nil
        }
        return errorCode
    }

    /// - Parameters:
    ///   - failingStep: the step of the turn that was running when the error was thrown; nil when unknown.
    ///   - errorDomain: `NSError.domain` of the error.
    ///   - errorCode: `NSError.code` of the error.
    ///   - errorMessage: the error's description. Only searched for billing words; never spoken.
    ///   - responseBody, dailyCapHeaderValue: round 19, what the failed response carried (from the
    ///     error's `userInfo`), to tell the Worker's daily cap from a rate limit. Never spoken.
    static func response(
        failingStep: EzraTurnStep?,
        errorDomain: String,
        errorCode: Int,
        errorMessage: String,
        responseBody: String? = nil,
        dailyCapHeaderValue: String? = nil
    ) -> EzraTurnFailureResponse {
        // The answer was already written when the voice failed, whatever the reason (no network,
        // the speech service down, its own rate limit). The answer matters more than the reason.
        if failingStep == .textToSpeech || failingStep == .speechPlayback {
            return .showReplyAsNoticeWithoutSpeaking
        }

        if failingStep == .screenCapture {
            return .speakSentence(screenCaptureFailedSentence)
        }

        if errorDomain == NSURLErrorDomain, urlErrorCodesMeaningTheWorkerWasNotReached.contains(errorCode) {
            return .speakSentence(cannotReachInternetSentence)
        }

        let httpStatusCode = httpStatusCode(errorDomain: errorDomain, errorCode: errorCode)
        if httpStatusCode == 401 {
            return .speakSentence(appTokenRejectedSentence)
        }

        let lowercasedErrorMessage = errorMessage.lowercased()
        let errorMessageIsAboutBilling = billingMessageFragments.contains { lowercasedErrorMessage.contains($0) }
        if httpStatusCode == 402 || errorMessageIsAboutBilling {
            return .speakSentence(outOfCreditSentence)
        }

        if isDailySpendingCap(httpStatusCode: httpStatusCode, responseBody: responseBody, dailyCapHeaderValue: dailyCapHeaderValue) {
            return .speakSentence(dailySpendingCapSentence)
        }
        if httpStatusCode == 429 {
            return .speakSentence(rateLimitedSentence)
        }

        return .speakSentence(aiServiceProblemSentence)
    }

    /// What the status pill shows when the voice failed after a good reply. The pill cuts a notice
    /// that is too wide with an ellipsis, so a long reply shows its beginning.
    ///
    /// `dailyCapWasReached` (round 19): the speech request hit the Worker's daily cap, so the cap's
    /// words come between the prefix and the reply: "voice unavailable · i've hit today's spending
    /// cap. · <the reply>".
    static func voiceUnavailableNoticeText(forSpokenReplyText spokenReplyText: String, dailyCapWasReached: Bool = false) -> String {
        let prefix = dailyCapWasReached ? voiceUnavailableNoticePrefix + " · " + dailySpendingCapSentence : voiceUnavailableNoticePrefix
        let trimmedSpokenReplyText = spokenReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSpokenReplyText.isEmpty else {
            return prefix
        }
        return prefix + " · " + trimmedSpokenReplyText
    }

    /// How long a failure notice stays in the status pill: long enough to read it (about fifteen
    /// characters a second), never under five seconds and never over twelve.
    static func noticeDisplaySeconds(forNoticeText noticeText: String) -> Double {
        let secondsNeededToReadTheNotice = Double(noticeText.count) / 15.0
        return min(12.0, max(5.0, secondsNeededToReadTheNotice))
    }
}
