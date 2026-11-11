//
//  ClickyDictationController.swift
//  leanring-buddy
//
//  Runs one dictation at a time: hold fn + option, speak, release, and the cleaned-up words are
//  pasted into the text field the user was in. A double-tap locks hands-free dictation.
//
//  Privacy rules, all deliberate:
//  - Nothing is read from the text field or the screen. Only the frontmost app's process number and
//    whether the focused element is a secure (password) field are noted, never any text.
//  - Dictated words (raw or cleaned) are never saved to notes, the profile, conversation history,
//    the memory server or analytics, and never printed or logged. Metrics hold numbers and fixed
//    identifiers only.
//  - Every failure ends with the words on the clipboard and a short notice, never with silence.
//

import AppKit
import Combine
import Foundation

enum ClickyDictationPhase: Equatable {
    case idle
    /// The keys are held (or a quick tap is waiting to see whether a second tap follows) and the
    /// microphone is capturing.
    case holding
    /// Locked by a double-tap: the microphone keeps capturing with the keys up.
    case handsFreeLocked
    /// The keys came up: finishing the capture, getting the transcript, cleaning it, inserting it.
    case finishing
}

/// What the cursor overlay shows for dictation.
enum ClickyDictationOverlayState: Equatable {
    case hidden
    case listening
    case listeningHandsFree
    /// Finishing up: transcript, cleanup and insertion.
    case working
    /// A short sentence such as "copied. press command v to paste."
    case notice(String)
}

@MainActor
final class ClickyDictationController: ObservableObject {
    /// After the keys come up, the microphone keeps capturing this long. People let go of the
    /// keys a moment before they finish the last word, and the recogniser needs that tail.
    static let microphoneTailAfterReleaseSeconds: TimeInterval = 0.200

    /// How long to wait for the transcript after asking for it, before giving up with a notice.
    /// The dictation manager's own fallback fires at 1.8 seconds, so this is a safety margin.
    static let transcriptWatchdogSeconds: TimeInterval = 4.0

    /// A dictation is finished and inserted at this length even if the keys are still held or
    /// hands-free was never stopped, so the microphone can never be left open by accident.
    static let maximumDictationDurationSeconds: TimeInterval = 180

    @Published private(set) var phase: ClickyDictationPhase = .idle
    @Published private(set) var overlayState: ClickyDictationOverlayState = .hidden

    /// Set from the panel's "dictation" switch. A press while this is false does nothing.
    var isDictationEnabled = true

    private let dictationManager: BuddyDictationManager
    private let cleanupClient: ClickyDictationCleanupClient
    /// True while the ask-Clicky shortcut (or anything else) is using the microphone, so the two
    /// can never run at the same time.
    private let isAnotherFeatureUsingTheMicrophone: () -> Bool
    /// Called when a dictation starts: stop any spoken answer, show the cursor overlay.
    private let prepareApplicationForDictationStart: () -> Void
    /// Called when the app ends a dictation by itself, so the shortcut recogniser stops waiting
    /// for keys that no longer mean anything.
    private let resetShortcutRecogniserAfterAppEndedDictation: () -> Void

    /// Everything about the dictation in progress. A class so the asynchronous steps can update
    /// it. Replaced (and the old one orphaned) whenever a new dictation starts or the current one
    /// is cancelled; an orphaned session's steps check their token and do nothing.
    private final class DictationSession {
        let token = UUID()
        let startedAt = Date()
        let pressUptimeSeconds: TimeInterval
        let insertionTarget: ClickyDictationInsertionTarget
        /// The focused element's role and secure-field flag, read in the background at the press
        /// (an Accessibility call can block, so it is not made on the main thread).
        let focusedElementDetailsAtPress: Task<ClickyDictationFocusedElementDetails, Never>

        var captureStartTask: Task<Void, Never>?
        var finishingTask: Task<Void, Never>?
        var maximumDurationTask: Task<Void, Never>?
        var captureStartedUptimeSeconds: TimeInterval?
        var releaseObservedUptimeSeconds: TimeInterval?
        var wasHandsFree = false
        /// Set when the session ends (finished or cancelled), so its metrics are written once.
        var hasEnded = false

        /// The speech recogniser's answer, kept until the finishing steps want it.
        var deliveredResult: BuddyTextInsertionDictationResult?
        var resultContinuation: CheckedContinuation<BuddyTextInsertionDictationResult?, Never>?

        init(
            pressUptimeSeconds: TimeInterval,
            insertionTarget: ClickyDictationInsertionTarget,
            focusedElementDetailsAtPress: Task<ClickyDictationFocusedElementDetails, Never>
        ) {
            self.pressUptimeSeconds = pressUptimeSeconds
            self.insertionTarget = insertionTarget
            self.focusedElementDetailsAtPress = focusedElementDetailsAtPress
        }
    }

    private var currentSession: DictationSession?
    private var noticeClearTask: Task<Void, Never>?

    init(
        dictationManager: BuddyDictationManager,
        cleanupClient: ClickyDictationCleanupClient,
        isAnotherFeatureUsingTheMicrophone: @escaping () -> Bool,
        prepareApplicationForDictationStart: @escaping () -> Void,
        resetShortcutRecogniserAfterAppEndedDictation: @escaping () -> Void
    ) {
        self.dictationManager = dictationManager
        self.cleanupClient = cleanupClient
        self.isAnotherFeatureUsingTheMicrophone = isAnotherFeatureUsingTheMicrophone
        self.prepareApplicationForDictationStart = prepareApplicationForDictationStart
        self.resetShortcutRecogniserAfterAppEndedDictation = resetShortcutRecogniserAfterAppEndedDictation
    }

    // MARK: - From the shortcut

    func handleChordAction(_ chordAction: ClickyDictationChordAction) {
        switch chordAction {
        case .startCapturing(let pressedAt):
            beginSession(pressedAtUptimeSeconds: pressedAt)
        case .lockHandsFree:
            lockHandsFree()
        case .finishAndInsert(let releaseObservedAt, let wasHandsFree):
            beginFinishing(releaseObservedUptimeSeconds: releaseObservedAt, wasHandsFree: wasHandsFree)
        case .discardWithoutInserting:
            endSessionWithoutMetrics()
        case .cancel:
            cancelSessionAndRecordMetrics()
        }
    }

    /// Escape: stops whatever dictation step is running and inserts nothing. Returns whether there
    /// was a dictation to cancel, so the caller knows Escape was used up by it.
    func cancelBecauseEscapeWasPressed() -> Bool {
        guard phase != .idle else { return false }
        cancelSessionAndRecordMetrics()
        return true
    }

    /// For when the app is quitting or the user switched dictation off: stops everything and
    /// writes nothing.
    func cancelEverythingWithoutMetrics() {
        endSessionWithoutMetrics()
        noticeClearTask?.cancel()
        overlayState = .hidden
    }

    // MARK: - Starting

    private func beginSession(pressedAtUptimeSeconds: TimeInterval) {
        guard isDictationEnabled else {
            resetShortcutRecogniserAfterAppEndedDictation()
            return
        }
        // A newer press wins over older work (see the session type), so a press while the
        // previous dictation is still being finished abandons that one.
        if phase != .idle {
            cancelSessionAndRecordMetrics()
        }
        guard !isAnotherFeatureUsingTheMicrophone() else {
            print("🎙️ Dictation: shortcut ignored because ask-Clicky is using the microphone")
            resetShortcutRecogniserAfterAppEndedDictation()
            return
        }

        noticeClearTask?.cancel()

        let insertionTarget = ClickyDictationTextInserter.captureInsertionTarget()
        let focusedElementDetailsTask = Task.detached(priority: .userInitiated) { () -> ClickyDictationFocusedElementDetails in
            guard let frontmostProcessIdentifier = insertionTarget.frontmostProcessIdentifier else {
                return .unreadable
            }
            return ClickyDictationTextInserter.readFocusedElementDetails(forProcessIdentifier: frontmostProcessIdentifier)
        }
        let session = DictationSession(
            pressUptimeSeconds: pressedAtUptimeSeconds,
            insertionTarget: insertionTarget,
            focusedElementDetailsAtPress: focusedElementDetailsTask
        )
        currentSession = session
        phase = .holding
        overlayState = .listening

        prepareApplicationForDictationStart()
        cleanupClient.warmUpConnectionIfItHasGoneCold()

        let sessionToken = session.token
        session.captureStartTask = Task { [weak self] in
            guard let self else { return }
            await self.dictationManager.startTextInsertionDictation(onResult: { [weak self] result in
                self?.handleResultFromDictationManager(result, forSessionWithToken: sessionToken)
            })
            guard self.isCurrentSession(withToken: sessionToken) else { return }

            if self.dictationManager.isRecordingForTextInsertion {
                session.captureStartedUptimeSeconds = ClickyTurnMetrics.currentUptimeSeconds
            } else {
                self.endSessionBecauseCaptureCouldNotStart(session)
            }
        }

        session.maximumDurationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumDictationDurationSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isCurrentSession(withToken: sessionToken) else { return }
            self.resetShortcutRecogniserAfterAppEndedDictation()
            self.beginFinishing(releaseObservedUptimeSeconds: ClickyTurnMetrics.currentUptimeSeconds, wasHandsFree: session.wasHandsFree)
        }
    }

    private func lockHandsFree() {
        guard let session = currentSession, phase == .holding else { return }
        session.wasHandsFree = true
        phase = .handsFreeLocked
        overlayState = .listeningHandsFree
    }

    private func endSessionBecauseCaptureCouldNotStart(_ session: DictationSession) {
        let noticeText: String
        switch dictationManager.currentPermissionProblem {
        case .microphoneAccessDenied:
            noticeText = "microphone access is off. turn it on in system settings."
        case .speechRecognitionDenied:
            noticeText = "speech recognition is off. turn it on in system settings."
        case nil:
            noticeText = "couldn't start dictation. try again."
        }
        resetShortcutRecogniserAfterAppEndedDictation()
        endSession(
            session,
            insertionOutcome: .cancelled,
            cleanupOutcome: nil,
            noticeText: noticeText,
            shouldRecordMetrics: true
        )
    }

    // MARK: - Finishing

    private func beginFinishing(releaseObservedUptimeSeconds: TimeInterval, wasHandsFree: Bool) {
        guard let session = currentSession, phase == .holding || phase == .handsFreeLocked else { return }

        session.releaseObservedUptimeSeconds = releaseObservedUptimeSeconds
        session.wasHandsFree = session.wasHandsFree || wasHandsFree
        session.maximumDurationTask?.cancel()
        phase = .finishing
        overlayState = .working

        session.finishingTask = Task { [weak self] in
            await self?.runFinishingSteps(of: session)
        }
    }

    /// Capture tail, transcript, cleanup, insertion. Every await is followed by a check that this
    /// session is still the current one, so Escape or a newer press makes the rest do nothing.
    private func runFinishingSteps(of session: DictationSession) async {
        let sessionToken = session.token
        let releaseObservedUptimeSeconds = session.releaseObservedUptimeSeconds ?? ClickyTurnMetrics.currentUptimeSeconds

        // The microphone may still be starting if the keys were released very quickly.
        await session.captureStartTask?.value
        guard isCurrentSession(withToken: sessionToken) else { return }

        try? await Task.sleep(nanoseconds: UInt64(Self.microphoneTailAfterReleaseSeconds * 1_000_000_000))
        guard isCurrentSession(withToken: sessionToken) else { return }

        let captureStoppedUptimeSeconds = ClickyTurnMetrics.currentUptimeSeconds
        var dictationMetrics = ClickyDictationMetrics(
            startedAt: session.startedAt,
            insertionOutcome: .cancelled,
            wasHandsFree: session.wasHandsFree
        )
        dictationMetrics.audioSeconds = captureStoppedUptimeSeconds - (session.captureStartedUptimeSeconds ?? session.pressUptimeSeconds)

        if session.deliveredResult == nil {
            dictationManager.stopTextInsertionDictationAndRequestFinalTranscript()
        }

        // The dictation manager always answers within about two seconds of the stop request. This
        // watchdog is only for the case where it somehow never does, so that a dictation can
        // never be stuck in "finishing" and block the next one.
        let transcriptWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.transcriptWatchdogSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleResultFromDictationManager(.failed, forSessionWithToken: sessionToken)
        }
        let transcriptResultOrNil = await waitForTranscriptResult(of: session)
        transcriptWatchdogTask.cancel()
        guard let transcriptResult = transcriptResultOrNil,
              isCurrentSession(withToken: sessionToken) else {
            return
        }
        dictationMetrics.releaseToTranscriptMilliseconds = ClickyTurnMetrics.millisecondsElapsed(
            sinceUptimeSeconds: releaseObservedUptimeSeconds
        )

        let rawTranscript: String
        switch transcriptResult {
        case .finalTranscript(let transcriptText):
            rawTranscript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failed:
            endSession(
                session,
                insertionOutcome: .empty,
                cleanupOutcome: nil,
                noticeText: "couldn't transcribe that. try again.",
                shouldRecordMetrics: true,
                metrics: dictationMetrics
            )
            return
        }
        guard !rawTranscript.isEmpty else {
            endSession(
                session,
                insertionOutcome: .empty,
                cleanupOutcome: nil,
                noticeText: ClickyDictationInsertion.noticeText(for: .empty),
                shouldRecordMetrics: true,
                metrics: dictationMetrics
            )
            return
        }

        // Cleanup: one short request, with the raw words as the answer to every kind of failure.
        let textToInsert: String
        if ClickyDictationCleanup.shouldSkipCleanupRequest(rawTranscript: rawTranscript) || !cleanupClient.isConfigured {
            textToInsert = rawTranscript
            dictationMetrics.cleanupOutcome = .skipped
        } else {
            let cleanupStartedUptimeSeconds = ClickyTurnMetrics.currentUptimeSeconds
            let cleanupModelResult = await cleanupClient.requestCleanedText(forRawTranscript: rawTranscript)
            guard isCurrentSession(withToken: sessionToken) else { return }
            dictationMetrics.cleanupMilliseconds = ClickyTurnMetrics.millisecondsElapsed(sinceUptimeSeconds: cleanupStartedUptimeSeconds)

            let resolvedCleanup = ClickyDictationCleanup.resolveTextToInsert(
                rawTranscript: rawTranscript,
                modelResult: cleanupModelResult
            )
            textToInsert = resolvedCleanup.textToInsert
            dictationMetrics.cleanupOutcome = resolvedCleanup.outcome
        }

        // Insertion.
        let focusedElementDetailsAtPress = await session.focusedElementDetailsAtPress.value
        guard isCurrentSession(withToken: sessionToken) else { return }

        var pasteKeystrokePostedUptimeSeconds: TimeInterval?
        let insertionOutcome = await ClickyDictationTextInserter.insert(
            textToInsert: textToInsert,
            target: session.insertionTarget,
            focusedElementWasSecureTextFieldAtPress: focusedElementDetailsAtPress.isSecureTextField,
            isInsertionStillWanted: { [weak self] in
                self?.isCurrentSession(withToken: sessionToken) ?? false
            },
            onPasteKeystrokePosted: {
                pasteKeystrokePostedUptimeSeconds = ClickyTurnMetrics.currentUptimeSeconds
            }
        )
        guard isCurrentSession(withToken: sessionToken) else { return }

        // For a refusal there was no keystroke: the delay is then until the words reached the clipboard.
        dictationMetrics.releaseToInsertMilliseconds = ClickyTurnMetrics.millisecondsBetween(
            startUptimeSeconds: releaseObservedUptimeSeconds,
            endUptimeSeconds: pasteKeystrokePostedUptimeSeconds ?? ClickyTurnMetrics.currentUptimeSeconds
        )
        endSession(
            session,
            insertionOutcome: insertionOutcome,
            cleanupOutcome: dictationMetrics.cleanupOutcome,
            noticeText: ClickyDictationInsertion.noticeText(for: insertionOutcome),
            shouldRecordMetrics: true,
            metrics: dictationMetrics
        )
    }

    /// Waits for the recogniser's answer. Returns nil if the session was cancelled while waiting.
    private func waitForTranscriptResult(of session: DictationSession) async -> BuddyTextInsertionDictationResult? {
        if let alreadyDeliveredResult = session.deliveredResult {
            return alreadyDeliveredResult
        }
        return await withCheckedContinuation { continuation in
            session.resultContinuation = continuation
        }
    }

    /// The speech recogniser's answer arrived. Normally that is the reply to the stop request. If it
    /// arrives while the keys are still down (the recogniser ended early), the dictation is
    /// finished at once with the words recognised so far, so nothing said is lost.
    private func handleResultFromDictationManager(_ result: BuddyTextInsertionDictationResult, forSessionWithToken sessionToken: UUID) {
        guard let session = currentSession, session.token == sessionToken else { return }

        session.deliveredResult = result
        if let waitingContinuation = session.resultContinuation {
            session.resultContinuation = nil
            waitingContinuation.resume(returning: result)
        }

        if phase == .holding || phase == .handsFreeLocked {
            resetShortcutRecogniserAfterAppEndedDictation()
            beginFinishing(releaseObservedUptimeSeconds: ClickyTurnMetrics.currentUptimeSeconds, wasHandsFree: session.wasHandsFree)
        }
    }

    // MARK: - Ending

    private func isCurrentSession(withToken sessionToken: UUID) -> Bool {
        currentSession?.token == sessionToken
    }

    /// Ends a session that ran its course: writes its metrics line and shows the notice, if any.
    private func endSession(
        _ session: DictationSession,
        insertionOutcome: ClickyDictationInsertionOutcome,
        cleanupOutcome: ClickyDictationCleanupOutcome?,
        noticeText: String?,
        shouldRecordMetrics: Bool,
        metrics: ClickyDictationMetrics? = nil
    ) {
        guard !session.hasEnded else { return }
        session.hasEnded = true
        stopWorkOfEndedSession(session)

        if shouldRecordMetrics {
            var dictationMetrics = metrics ?? ClickyDictationMetrics(
                startedAt: session.startedAt,
                insertionOutcome: insertionOutcome,
                wasHandsFree: session.wasHandsFree
            )
            dictationMetrics.insertionOutcome = insertionOutcome
            dictationMetrics.cleanupOutcome = cleanupOutcome ?? dictationMetrics.cleanupOutcome
            // Numbers and identifiers only: never any of the words.
            print(dictationMetrics.makeConsoleSummaryLine())
            ClickyDictationMetricsLog.recordInBackground(dictationMetrics)
        }

        if currentSession === session {
            currentSession = nil
        }
        phase = .idle
        if let noticeText {
            showNotice(noticeText)
        } else {
            overlayState = .hidden
        }
    }

    /// Escape, a newer press, or the end of the app: the session's work is dropped and nothing is
    /// inserted or copied.
    private func cancelSessionAndRecordMetrics() {
        guard let session = currentSession else { return }
        endSession(
            session,
            insertionOutcome: .cancelled,
            cleanupOutcome: nil,
            noticeText: nil,
            shouldRecordMetrics: true
        )
    }

    /// A lone quick tap, or no dictation at all: stops silently and writes nothing, because it
    /// was never a dictation.
    private func endSessionWithoutMetrics() {
        guard let session = currentSession else { return }
        endSession(
            session,
            insertionOutcome: .cancelled,
            cleanupOutcome: nil,
            noticeText: nil,
            shouldRecordMetrics: false
        )
    }

    private func stopWorkOfEndedSession(_ session: DictationSession) {
        session.captureStartTask?.cancel()
        session.finishingTask?.cancel()
        session.maximumDurationTask?.cancel()
        session.focusedElementDetailsAtPress.cancel()
        if let waitingContinuation = session.resultContinuation {
            session.resultContinuation = nil
            waitingContinuation.resume(returning: nil)
        }
        // Idempotent: does nothing when the microphone is not running for this session. An ended
        // session leaves nothing on the microphone or the recogniser.
        if currentSession === session {
            dictationManager.cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func showNotice(_ noticeText: String) {
        overlayState = .notice(noticeText)
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ClickyDictationInsertion.noticeDisplaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if case .notice = self.overlayState, self.phase == .idle {
                self.overlayState = .hidden
            }
        }
    }
}
