//
//  EzraVoiceSamplePlayer.swift
//  leanring-buddy
//
//  Plays a voice's sample in the settings tab's voice picker (round 20): Ezra's own fixed sentence
//  ("hi, i'm ezra. this is how i sound.") in that voice at the current speed, fetched through the
//  same /tts request every reply uses, so what Sam hears is what he will get. Each voice and speed is
//  fetched once and kept as a small mp3 in ~/Library/Application Support/Ezra/Voices/Samples (a
//  temporary folder in a self test); at most 40 are kept, the oldest go first.
//
//  It has its own audio player, apart from `ElevenLabsTTSClient`'s, so a sample never counts as
//  Ezra speaking (the pill's "speaking", `isPlaying`, the drawing's audio length). Starting a sample
//  stops the one before; Ezra's own speech stops a sample (the reply wins); Escape stops a sample.
//

import AVFoundation
import Foundation

/// What plays a sample's audio. The app uses `EzraAVAudioSamplePlayback`; the offline checks use a
/// fake that never makes a sound.
@MainActor
protocol EzraVoiceSampleAudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    /// Starts playing. False when it could not start.
    func play() -> Bool
    func stop()
}

/// The real playback: an `AVAudioPlayer` of its own.
@MainActor
final class EzraAVAudioSamplePlayback: EzraVoiceSampleAudioPlaying {
    private let audioPlayer: AVAudioPlayer

    init(sampleAudio: Data) throws {
        audioPlayer = try AVAudioPlayer(data: sampleAudio)
    }

    var isPlaying: Bool {
        audioPlayer.isPlaying
    }

    func play() -> Bool {
        audioPlayer.play()
    }

    func stop() {
        audioPlayer.stop()
    }
}

@MainActor
final class EzraVoiceSamplePlayer {
    /// Fetches the sample sentence with these voice settings (the app: `ElevenLabsTTSClient.fetchSpeechAudio`).
    typealias SampleAudioFetcher = @MainActor (EzraVoiceSettings) async throws -> ElevenLabsFetchedSpeech
    /// Makes the playback for a sample's audio.
    typealias SampleAudioPlaybackMaker = @MainActor (Data) throws -> EzraVoiceSampleAudioPlaying

    /// What the sample buttons show. Every change is passed to `playbackStateChangedHandler`.
    private(set) var playbackState: EzraVoiceSamplePlaybackState = .idle {
        didSet {
            if playbackState != oldValue {
                playbackStateChangedHandler?(playbackState)
            }
        }
    }

    var playbackStateChangedHandler: ((EzraVoiceSamplePlaybackState) -> Void)?
    /// A sample could not be fetched (offline, the Worker refused). The tab says so.
    var sampleFetchFailedHandler: (() -> Void)?

    /// How often the player is asked whether the sample has finished (it publishes nothing when it
    /// ends, as for Ezra's own speech).
    static let playbackEndCheckIntervalNanoseconds: UInt64 = 100_000_000

    private let samplesDirectoryURL: URL?
    private let fetchSampleAudio: SampleAudioFetcher
    private let makeSampleAudioPlayback: SampleAudioPlaybackMaker

    private var currentPlayback: EzraVoiceSampleAudioPlaying?
    private var sampleTask: Task<Void, Never>?
    /// Counts every start and stop, so the work of a sample that was stopped or replaced does nothing
    /// when it comes back.
    private var sampleGeneration = 0

    /// `samplesDirectoryURL` nil means no sample is kept on disk (each one is fetched).
    /// `makeSampleAudioPlayback` nil means the real `AVAudioPlayer`; the offline checks pass a fake.
    init(
        samplesDirectoryURL: URL?,
        fetchSampleAudio: @escaping SampleAudioFetcher,
        makeSampleAudioPlayback: SampleAudioPlaybackMaker? = nil
    ) {
        self.samplesDirectoryURL = samplesDirectoryURL
        self.fetchSampleAudio = fetchSampleAudio
        self.makeSampleAudioPlayback = makeSampleAudioPlayback ?? { sampleAudio in
            try EzraAVAudioSamplePlayback(sampleAudio: sampleAudio)
        }
    }

    /// Whether a sample is loading or playing.
    var isActive: Bool {
        playbackState != .idle
    }

    /// A row's sample button: stops the row's sample when it is loading or playing, and plays it
    /// otherwise (stopping any other sample first).
    /// - `voiceIDToSend`: the voice the request asks for; nil for the Worker's default voice.
    /// - `sampleCacheVoiceID`: the id the file is kept under (the default's own id when known).
    func toggleSample(rowIdentifier: String, voiceIDToSend: String?, sampleCacheVoiceID: String, speedPercent: Int) {
        if playbackState.rowIdentifier == rowIdentifier {
            stop()
            return
        }
        play(rowIdentifier: rowIdentifier, voiceIDToSend: voiceIDToSend, sampleCacheVoiceID: sampleCacheVoiceID, speedPercent: speedPercent)
    }

    /// Plays a row's sample: from the disk when it was kept, otherwise fetched, kept and pruned first.
    func play(rowIdentifier: String, voiceIDToSend: String?, sampleCacheVoiceID: String, speedPercent: Int) {
        stop()
        sampleGeneration += 1
        let generationOfThisSample = sampleGeneration
        playbackState = .loading(rowIdentifier: rowIdentifier)

        let speedStepPercent = EzraVoiceSettings.speedStep(forPercent: speedPercent)
        let sampleVoiceSettings = EzraVoiceSettings(chosenVoiceID: voiceIDToSend, chosenVoiceName: nil, speedPercent: speedStepPercent)
        let sampleFileName = EzraVoiceSample.cacheFileName(
            voiceID: sampleCacheVoiceID,
            speedPercent: speedStepPercent,
            modelID: EzraTextToSpeechRequestBody.modelID
        )
        let samplesDirectoryURL = samplesDirectoryURL

        sampleTask = Task { @MainActor [weak self] in
            // The disk work runs off the main thread.
            var sampleAudio: Data?
            if let samplesDirectoryURL {
                sampleAudio = await Task.detached(priority: .userInitiated) {
                    EzraVoiceSampleCache.cachedSampleAudio(fileName: sampleFileName, inDirectory: samplesDirectoryURL)
                }.value
            }
            guard let self, self.sampleGeneration == generationOfThisSample, !Task.isCancelled else { return }

            if sampleAudio == nil {
                do {
                    let fetchedSample = try await self.fetchSampleAudio(sampleVoiceSettings)
                    guard self.sampleGeneration == generationOfThisSample, !Task.isCancelled else { return }
                    // The Worker spoke with its default voice: this voice is gone from the account.
                    // Playing it (or keeping it under this voice's name) would mislead, so it is
                    // dropped; the tab says so through the speech client's fallback handler.
                    if fetchedSample.usedDefaultVoiceAsFallback && voiceIDToSend != nil {
                        self.playbackState = .idle
                        return
                    }
                    sampleAudio = fetchedSample.audioData
                    if let samplesDirectoryURL {
                        let fetchedAudio = fetchedSample.audioData
                        Task.detached(priority: .utility) {
                            EzraVoiceSampleCache.storeSampleAudio(fetchedAudio, fileName: sampleFileName, inDirectory: samplesDirectoryURL)
                            EzraVoiceSampleCache.pruneSamples(inDirectory: samplesDirectoryURL)
                        }
                    }
                } catch {
                    guard self.sampleGeneration == generationOfThisSample, !Task.isCancelled else { return }
                    self.playbackState = .idle
                    self.sampleFetchFailedHandler?()
                    return
                }
            }
            guard let sampleAudio, self.sampleGeneration == generationOfThisSample, !Task.isCancelled else { return }

            guard let playback = try? self.makeSampleAudioPlayback(sampleAudio), playback.play() else {
                self.playbackState = .idle
                return
            }
            self.currentPlayback = playback
            self.playbackState = .playing(rowIdentifier: rowIdentifier)
            while playback.isPlaying, self.sampleGeneration == generationOfThisSample, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.playbackEndCheckIntervalNanoseconds)
            }
            guard self.sampleGeneration == generationOfThisSample else { return }
            self.currentPlayback = nil
            self.playbackState = .idle
        }
    }

    /// Stops a sample that is loading or playing (a new sample, Ezra's own speech, Escape, the stop
    /// button). Safe to call at any time.
    func stop() {
        sampleGeneration += 1
        sampleTask?.cancel()
        sampleTask = nil
        currentPlayback?.stop()
        currentPlayback = nil
        playbackState = .idle
    }
}
