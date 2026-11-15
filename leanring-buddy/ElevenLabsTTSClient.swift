//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Fetches text-to-speech audio from ElevenLabs (through the Worker proxy) and plays it back
//  through the system audio output. Fetching and playing are separate steps so the audio for a
//  reply can be downloaded early and played only once the final spoken text is decided.
//

import AVFoundation
import Foundation

/// Speech audio that has been downloaded but not played, with how long the network took.
struct ElevenLabsFetchedSpeech {
    let audioData: Data
    let fetchMilliseconds: Int
    /// Round 20: the Worker answered with `X-Clicky-Voice-Fallback: 1`, so the audio is in its
    /// default voice, not the one asked for (that voice is no longer in the account).
    var usedDefaultVoiceAsFallback: Bool = false
}

@MainActor
final class ElevenLabsTTSClient {
    private let proxyURL: URL
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    /// Round 20: called just before Ezra's own speech starts playing, so a voice sample playing in
    /// the settings tab stops (the reply wins).
    var speechPlaybackWillStartHandler: (() -> Void)?

    /// Round 20: called with the voice id that was asked for when the Worker spoke with its default
    /// voice instead (the voice is no longer in the account). Nothing is spoken about it; the
    /// settings tab says so.
    var voiceFallbackHandler: ((String) -> Void)?

    /// `sessionConfiguration` is only for the offline checks, which answer the requests in-process.
    init(proxyURL: String, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = sessionConfiguration ?? URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    /// `voiceSettings` is the voice and speed to speak with (round 20).
    func speakText(_ text: String, voiceSettings: EzraVoiceSettings) async throws {
        let fetchedSpeech = try await fetchSpeechAudio(for: text, voiceSettings: voiceSettings)

        try Task.checkCancellation()

        try playSpeechAudio(fetchedSpeech.audioData)
    }

    /// Downloads the audio for `text` without playing it. Nothing is heard until the caller passes
    /// the audio to `playSpeechAudio`, which is what lets the audio be fetched while the final
    /// spoken text is still being decided. Throws on network errors and when cancelled.
    ///
    /// Round 20: every spoken word goes through here, so the chosen voice and speed apply to all of
    /// them. With nothing chosen and the normal speed the body is today's (see
    /// `EzraTextToSpeechRequestBody.make`); a chosen voice adds `voice_id` and a speed adds
    /// `voice_settings.speed`.
    func fetchSpeechAudio(for text: String, voiceSettings: EzraVoiceSettings) async throws -> ElevenLabsFetchedSpeech {
        let fetchStartedUptimeSeconds = EzraTurnMetrics.currentUptimeSeconds

        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        EzraWorkerConfiguration.addAppTokenHeader(to: &request)

        let body = EzraTextToSpeechRequestBody.make(text: text, voiceSettings: voiceSettings)

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            // Round 19: the body and the Worker's cap header travel with the error (see ClaudeAPI).
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [
                              NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)",
                              EzraTurnFailureMessage.responseBodyUserInfoKey: errorBody,
                              EzraTurnFailureMessage.dailyCapHeaderUserInfoKey: httpResponse.value(forHTTPHeaderField: EzraTurnFailureMessage.dailyCapHeaderName) ?? "",
                          ])
        }

        // Round 20: the Worker spoke with its default voice because the voice asked for is not in
        // the account (or its id was malformed). The audio is still good; the settings tab is told,
        // and only when a voice was actually asked for.
        let usedDefaultVoiceAsFallback = EzraTextToSpeechRequestBody.responseUsedDefaultVoiceAsFallback(
            fallbackHeaderValue: httpResponse.value(forHTTPHeaderField: EzraTextToSpeechRequestBody.voiceFallbackHeaderName)
        )
        if usedDefaultVoiceAsFallback, let requestedVoiceID = voiceSettings.voiceIDToSend {
            voiceFallbackHandler?(requestedVoiceID)
        }

        return ElevenLabsFetchedSpeech(
            audioData: data,
            fetchMilliseconds: EzraTurnMetrics.millisecondsElapsed(sinceUptimeSeconds: fetchStartedUptimeSeconds),
            usedDefaultVoiceAsFallback: usedDefaultVoiceAsFallback
        )
    }

    /// Starts playing audio returned by `fetchSpeechAudio`. Returns as soon as playback has begun.
    func playSpeechAudio(_ audioData: Data) throws {
        let player = try AVAudioPlayer(data: audioData)
        // Round 20: Ezra's own speech wins over a voice sample in the settings tab.
        speechPlaybackWillStartHandler?()
        self.audioPlayer = player
        player.play()
        print("🔊 ElevenLabs TTS: playing \(audioData.count / 1024)KB audio")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// How long the audio that is playing (or was last played) lasts, in seconds. nil when there
    /// is none. The drawing schedule uses it to place each mark at its moment in the speech.
    var currentSpeechAudioDurationSeconds: TimeInterval? {
        audioPlayer?.duration
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}

/// Fetches the speech for a reply early, while Claude is still writing the reply's tags.
///
/// The words before the first tag are the whole spoken answer and cannot change, but the stream
/// keeps going for the tags (and `EzraTurnFinisher` only decides the final spoken text after the
/// stream ends). This starts downloading the audio for those words straight away, so it is
/// usually ready by the time the finisher is done. Nothing here ever plays audio: the caller plays
/// only what `speechAudioForFinalSpokenText` returns, after the finisher has decided.
///
/// One instance belongs to one turn.
@MainActor
final class ElevenLabsSpeechPrefetch {
    /// The text the early fetch was made for. Nil until an early fetch has started.
    private(set) var prefetchedSpokenText: String?

    /// Round 20: the voice and speed of this turn, read once when the turn began. Every fetch this
    /// object makes (the early one, a fixed sentence, the final one) uses this same value, so a
    /// change in the settings tab mid-turn can never give early audio in one voice and a final fetch
    /// in another; the change applies from the next turn.
    let voiceSettingsForThisTurn: EzraVoiceSettings

    private var pendingFetch: Task<ElevenLabsFetchedSpeech, Error>?
    private var hasLookedPastTheFirstReplyTag = false
    private var outcomeWhenNothingWasFetched: EzraSpeechPrefetchOutcome = .notStarted

    init(voiceSettings voiceSettingsForThisTurn: EzraVoiceSettings) {
        self.voiceSettingsForThisTurn = voiceSettingsForThisTurn
    }

    /// Called with the reply text received so far, on every chunk. Does nothing until the first
    /// reply tag has opened, then starts the early fetch once. A failure to start is silent: the
    /// turn simply takes the normal path.
    func startIfFirstReplyTagHasOpened(accumulatedReplyText: String, userTranscript: String, ttsClient: ElevenLabsTTSClient) {
        guard !hasLookedPastTheFirstReplyTag else { return }
        guard case .spokenTextIsComplete(let spokenTextBeforeFirstTag) = EzraSpeechPrefetch.replyTextBeforeFirstTag(in: accumulatedReplyText) else {
            return
        }
        hasLookedPastTheFirstReplyTag = true

        // A reply that begins with a tag has no words before it to fetch.
        guard !spokenTextBeforeFirstTag.isEmpty else { return }

        guard EzraSpeechPrefetch.transcriptAllowsSpeechPrefetch(userTranscript) else {
            outcomeWhenNothingWasFetched = .skippedForMemoryRequest
            return
        }

        prefetchedSpokenText = spokenTextBeforeFirstTag
        let voiceSettingsForThisFetch = voiceSettingsForThisTurn
        pendingFetch = Task {
            try await ttsClient.fetchSpeechAudio(for: spokenTextBeforeFirstTag, voiceSettings: voiceSettingsForThisFetch)
        }
    }

    /// Round 19: starts fetching the audio of a fixed sentence the moment it is known (the turn
    /// ended after one simple action, so there is no reply stream to wait for). It is played, like any
    /// early fetch, only if the final spoken text is exactly this sentence. The transcript gate is the
    /// same as for the words before a reply tag, so a memory turn never sends text early.
    func startFetchingFixedSentence(_ fixedSentence: String, userTranscript: String, ttsClient: ElevenLabsTTSClient) {
        hasLookedPastTheFirstReplyTag = true
        guard !fixedSentence.isEmpty else { return }
        guard EzraSpeechPrefetch.transcriptAllowsSpeechPrefetch(userTranscript) else {
            outcomeWhenNothingWasFetched = .skippedForMemoryRequest
            return
        }
        pendingFetch?.cancel()
        prefetchedSpokenText = fixedSentence
        let voiceSettingsForThisFetch = voiceSettingsForThisTurn
        pendingFetch = Task {
            try await ttsClient.fetchSpeechAudio(for: fixedSentence, voiceSettings: voiceSettingsForThisFetch)
        }
    }

    /// Cancels the early fetch if it is still running. Safe to call at any time, any number of
    /// times, including after the audio has already been used.
    func cancel() {
        pendingFetch?.cancel()
    }

    /// The outcome to record when the early audio is not played: it was made for different text
    /// than the final spoken text (or the final spoken text is empty), or no early fetch happened.
    var outcomeWhenPrefetchedAudioIsNotUsed: EzraSpeechPrefetchOutcome {
        pendingFetch == nil ? outcomeWhenNothingWasFetched : .textChanged
    }

    /// Returns the audio for `finalSpokenText`, the text `EzraTurnFinisher` decided on.
    /// - If the early fetch was made for exactly this text, its audio is used (waiting for it if
    ///   it is still downloading). If that fetch failed, the failure is silent and the final text
    ///   is fetched the normal way.
    /// - In every other case the early fetch is cancelled and thrown away, and the final text is
    ///   fetched. Early audio for any other text is never returned.
    /// Throws when cancelled, or when the normal fetch fails.
    func speechAudioForFinalSpokenText(
        _ finalSpokenText: String,
        ttsClient: ElevenLabsTTSClient
    ) async throws -> (fetchedSpeech: ElevenLabsFetchedSpeech, prefetchOutcome: EzraSpeechPrefetchOutcome) {
        guard EzraSpeechPrefetch.prefetchedAudioMatchesFinalSpokenText(
            prefetchedSpokenText: prefetchedSpokenText,
            finalSpokenText: finalSpokenText
        ), let pendingFetch else {
            let outcome = outcomeWhenPrefetchedAudioIsNotUsed
            cancel()
            let fetchedSpeech = try await ttsClient.fetchSpeechAudio(for: finalSpokenText, voiceSettings: voiceSettingsForThisTurn)
            return (fetchedSpeech, outcome)
        }

        do {
            // The early fetch is its own task, so a cancelled turn would otherwise keep waiting
            // for it. This makes cancelling the turn cancel the early fetch too.
            let fetchedSpeech = try await withTaskCancellationHandler {
                try await pendingFetch.value
            } onCancel: {
                pendingFetch.cancel()
            }
            return (fetchedSpeech, .used)
        } catch {
            // A cancelled turn is not a failed fetch; let the cancellation through.
            try Task.checkCancellation()
            let fetchedSpeech = try await ttsClient.fetchSpeechAudio(for: finalSpokenText, voiceSettings: voiceSettingsForThisTurn)
            return (fetchedSpeech, .failed)
        }
    }
}
