import Foundation

// Round 18 (Jarvis actions): follow-up listening. After a spoken reply Clicky listens for a few
// seconds for a follow-up, so the user does not have to hold the keys again. The decisions are pure:
// when the window may open, when speech has started and ended (from audio levels and explicit
// timestamps, no timers, like the dictation chord machine), what a transcript means, and the cap that
// keeps a TV in the room from becoming an endless chain of model calls. The audio side (the
// microphone and the recogniser) is `BuddyDictationManager`'s, wired up in `CompanionManager`.

// MARK: - The numbers

/// Every number follow-up listening works to. The level is `BuddyDictationManager.currentAudioPowerLevel`:
/// the root mean square of each microphone buffer times 10.2, held between 0 and 1, and smoothed so it
/// falls by a quarter or so per buffer (about 43 buffers a second). A quiet room reads about 0.01 to
/// 0.08, a person speaking at a normal distance about 0.3 to 1. The thresholds below sit between those
/// and are measured against the room's own floor, so a fan or a loud room moves them up.
nonisolated enum ClickyFollowUpListeningConstants {
    /// The window opens this long after the reply's audio ended, so the end of Clicky's own voice
    /// and its echo are over.
    static let secondsAfterReplyBeforeTheWindowOpens: TimeInterval = 0.3
    /// How long the room's noise floor is measured from the start of the window.
    static let noiseFloorMeasuringSeconds: TimeInterval = 0.3
    /// Speech starts when the level stays this far above the floor, and above `minimumSpeechLevel`,
    /// for `speechStartHoldSeconds` (a cough or a click is shorter).
    static let speechStartMarginAboveTheFloor = 0.12
    static let minimumSpeechLevel = 0.18
    static let speechStartHoldSeconds: TimeInterval = 0.15
    /// After speech started, the level counts as quiet when it is under the floor plus this.
    static let quietMarginAboveTheFloor = 0.07
    /// The words are over after this much quiet, or this long after speech started.
    static let endOfSpeechQuietSeconds: TimeInterval = 1.2
    static let maximumSpeechSeconds: TimeInterval = 20
    /// With no speech within this long of the window opening, it closes without a sound.
    static let noSpeechGiveUpSeconds: TimeInterval = 6
    /// A level this high during the floor measurement is the user already answering (people answer
    /// fast), not the room: the floor is then this fixed default so the answer still triggers.
    static let levelThatCountsAsSpeechWhileMeasuring = 0.25
    static let defaultNoiseFloor = 0.03
    /// The most the measured floor may be. Past it the room is too loud to hear speech in anyway.
    static let maximumMeasuredNoiseFloor = 0.6
    /// Follow-up turns in a row, with no key press and no typed message in between, before the
    /// window stops opening.
    static let maximumFollowUpTurnsInARow = 5
}

// MARK: - The state machine

nonisolated enum ClickyFollowUpListeningAction: Equatable {
    case keepListening
    /// The user finished speaking: stop the microphone and take the transcript, like a key release.
    case finishAndTranscribe
    /// Nothing was said: close the window with no sound and no line in the metrics.
    case giveUpSilently
}

nonisolated struct ClickyFollowUpListeningStateMachine {
    enum Phase: Equatable {
        case notStarted
        case measuringNoiseFloor
        case waitingForSpeech
        case speaking
        case finished
    }

    private(set) var phase = Phase.notStarted
    private(set) var noiseFloor = ClickyFollowUpListeningConstants.defaultNoiseFloor

    private var windowOpenedAt: TimeInterval = 0
    private var floorSampleSum = 0.0
    private var floorSampleCount = 0
    private var aboveSpeechThresholdSince: TimeInterval?
    /// When speech started (meaningful once `speechHasStarted`). Readable since round 19 for the
    /// follow-up log; the machine's decisions do not change.
    private(set) var speechStartedAt: TimeInterval = 0
    /// Round 19, for the follow-up log only: true once the floor was measured over the full
    /// measuring time (not when an immediate answer made it the fixed default), and once speech started.
    private(set) var floorWasMeasured = false
    private(set) var speechHasStarted = false
    private var lastLoudMomentAt: TimeInterval = 0
    private var latestLevel = 0.0
    /// True once the level dropped to quiet at any point after speech started. A person speaking
    /// pauses between phrases; a level that never dips is a loud room (a fan, a TV, music).
    private var hasSeenAQuietMomentWhileSpeaking = false

    init() {}

    /// The microphone is on: the window is open from `moment`.
    mutating func begin(at moment: TimeInterval) {
        self = ClickyFollowUpListeningStateMachine()
        phase = .measuringNoiseFloor
        windowOpenedAt = moment
    }

    /// One reading of the audio level, with the time it was read at.
    mutating func processAudioLevel(_ level: Double, at moment: TimeInterval) -> ClickyFollowUpListeningAction {
        latestLevel = level
        return advance(at: moment)
    }

    /// Time passing with no new reading (the readings may stop), so the timeouts still fire.
    mutating func processTimePassing(at moment: TimeInterval) -> ClickyFollowUpListeningAction {
        advance(at: moment)
    }

    private mutating func advance(at moment: TimeInterval) -> ClickyFollowUpListeningAction {
        switch phase {
        case .notStarted, .finished:
            return .keepListening

        case .measuringNoiseFloor:
            if latestLevel >= ClickyFollowUpListeningConstants.levelThatCountsAsSpeechWhileMeasuring {
                // Already answering: the floor is the fixed default, and this reading is judged as speech.
                noiseFloor = ClickyFollowUpListeningConstants.defaultNoiseFloor
                phase = .waitingForSpeech
                return advanceWhileWaitingForSpeech(at: moment)
            }
            floorSampleSum += latestLevel
            floorSampleCount += 1
            if moment - windowOpenedAt >= ClickyFollowUpListeningConstants.noiseFloorMeasuringSeconds {
                let measuredFloor = floorSampleSum / Double(max(1, floorSampleCount))
                noiseFloor = min(measuredFloor, ClickyFollowUpListeningConstants.maximumMeasuredNoiseFloor)
                floorWasMeasured = true
                phase = .waitingForSpeech
                return advanceWhileWaitingForSpeech(at: moment)
            }
            return giveUpIfNoSpeechCameInTime(at: moment)

        case .waitingForSpeech:
            return advanceWhileWaitingForSpeech(at: moment)

        case .speaking:
            if latestLevel > noiseFloor + ClickyFollowUpListeningConstants.quietMarginAboveTheFloor {
                lastLoudMomentAt = moment
            } else {
                hasSeenAQuietMomentWhileSpeaking = true
            }
            if moment - lastLoudMomentAt >= ClickyFollowUpListeningConstants.endOfSpeechQuietSeconds {
                phase = .finished
                return .finishAndTranscribe
            }
            if moment - speechStartedAt >= ClickyFollowUpListeningConstants.maximumSpeechSeconds {
                // Twenty seconds with no pause at all is not a person talking to Clicky. A room that
                // is louder than the "already answering" level looks like an immediate answer at
                // first and cannot be told from one, so it ends here, with no model call.
                phase = .finished
                return hasSeenAQuietMomentWhileSpeaking ? .finishAndTranscribe : .giveUpSilently
            }
            return .keepListening
        }
    }

    private mutating func advanceWhileWaitingForSpeech(at moment: TimeInterval) -> ClickyFollowUpListeningAction {
        let speechThreshold = max(
            noiseFloor + ClickyFollowUpListeningConstants.speechStartMarginAboveTheFloor,
            ClickyFollowUpListeningConstants.minimumSpeechLevel
        )
        if latestLevel > speechThreshold {
            if aboveSpeechThresholdSince == nil {
                aboveSpeechThresholdSince = moment
            }
            if let aboveSpeechThresholdSince, moment - aboveSpeechThresholdSince >= ClickyFollowUpListeningConstants.speechStartHoldSeconds {
                phase = .speaking
                speechStartedAt = aboveSpeechThresholdSince
                speechHasStarted = true
                lastLoudMomentAt = moment
                return .keepListening
            }
        } else {
            // A cough or a click that was too short: start counting again.
            aboveSpeechThresholdSince = nil
        }
        return giveUpIfNoSpeechCameInTime(at: moment)
    }

    private mutating func giveUpIfNoSpeechCameInTime(at moment: TimeInterval) -> ClickyFollowUpListeningAction {
        if moment - windowOpenedAt >= ClickyFollowUpListeningConstants.noSpeechGiveUpSeconds {
            phase = .finished
            return .giveUpSilently
        }
        return .keepListening
    }
}

// MARK: - The cap on follow-up turns in a row

nonisolated struct ClickyFollowUpTurnCounter: Equatable {
    private(set) var followUpTurnsInARow = 0

    init() {}

    /// False once five follow-up turns happened with no key press and no typed message in between.
    var windowMayOpen: Bool {
        followUpTurnsInARow < ClickyFollowUpListeningConstants.maximumFollowUpTurnsInARow
    }

    /// A follow-up transcript went to the model.
    mutating func recordFollowUpTurn() {
        followUpTurnsInARow += 1
    }

    /// The user pressed the ask keys or typed a message: the user is in charge again.
    mutating func recordTheUserTookOver() {
        followUpTurnsInARow = 0
    }
}

// MARK: - When the window may open

nonisolated enum ClickyFollowUpWindowGate {
    /// All of these have to hold. A waiting change card does not prevent it: a follow-up "yes" works.
    static func mayOpen(
        isEnabled: Bool,
        turnWasSpoken: Bool,
        replyWasSpokenToTheEnd: Bool,
        dictationIsRunning: Bool,
        askKeysAreHeld: Bool,
        chatTextFieldIsFirstResponder: Bool,
        aTimerAlertIsSpeaking: Bool,
        aWindowIsAlreadyOpen: Bool,
        counter: ClickyFollowUpTurnCounter
    ) -> Bool {
        isEnabled
            && turnWasSpoken
            && replyWasSpokenToTheEnd
            && !dictationIsRunning
            && !askKeysAreHeld
            && !chatTextFieldIsFirstResponder
            && !aTimerAlertIsSpeaking
            && !aWindowIsAlreadyOpen
            && counter.windowMayOpen
    }
}

// MARK: - What the transcript means

nonisolated enum ClickyFollowUpTranscriptDecision: Equatable {
    /// Nothing, or only "um": the window closes with no sound and no model call.
    case closeSilently
    /// "thanks", "that's all", "never mind": the window closes with no model call and no reply.
    case endPhrase
    /// Anything else: a normal spoken turn.
    case sendToModel

    static let endPhrases: Set<String> = [
        "thanks", "thank you", "that's all", "never mind", "stop", "goodbye", "ok thanks",
    ]
    static let fillerWords: Set<String> = [
        "um", "uh", "hmm", "hm", "mm", "mmm", "mhm", "uhh", "umm", "er", "erm", "ah", "eh",
    ]

    static func decide(forTranscript transcript: String) -> ClickyFollowUpTranscriptDecision {
        let normalizedTranscript = ClickyChangeConfirmationPhrases.normalized(transcript)
        if normalizedTranscript.isEmpty {
            return .closeSilently
        }
        if endPhrases.contains(normalizedTranscript) {
            return .endPhrase
        }
        let wordCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "'"))
        let words = normalizedTranscript.components(separatedBy: wordCharacters.inverted).filter { !$0.isEmpty }
        if words.isEmpty || words.allSatisfy({ fillerWords.contains($0) }) {
            return .closeSilently
        }
        return .sendToModel
    }
}
