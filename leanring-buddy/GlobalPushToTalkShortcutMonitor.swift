//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Sends once each time Escape is pressed anywhere in the system (key repeat from holding the
    /// key is ignored). The tap is listen-only, so Escape still reaches whichever app has focus;
    /// the subscriber decides whether Clicky has anything to interrupt.
    let escapeKeyPressedPublisher = PassthroughSubject<Void, Never>()

    /// What the dictation shortcut (hold fn + option, double-tap to lock) asks for. It is worked
    /// out from the same event tap as the ask shortcut, so no second tap is needed. The two
    /// shortcuts cannot match at once: dictation is exactly fn + option and asking needs control.
    let dictationChordActionPublisher = PassthroughSubject<ClickyDictationChordAction, Never>()

    /// When the push-to-talk keys were last released, on the same clock as
    /// `ClickyTurnMetrics.currentUptimeSeconds`. It is taken here, where the release is first
    /// seen, so the delay before the transcript and reply is measured from the real key release
    /// and not from a later hop to another queue. Cleared on the next press, so a release from an
    /// earlier utterance is never mistaken for this one's.
    private(set) var lastShortcutReleaseUptimeSeconds: TimeInterval?

    private static let escapeKeyCode: UInt16 = 53

    /// The dictation chord's timers are scheduled this long after their exact deadline. The
    /// machine treats a deadline as still open at exactly its time, and the dispatch clock and the
    /// uptime clock can disagree by a millisecond, so waking up a little late avoids a wake-up
    /// that finds nothing due and has to be scheduled again.
    private static let dictationChordWakeUpSlackSeconds: TimeInterval = 0.002

    private var dictationChordStateMachine = ClickyDictationChordStateMachine()
    private var dictationChordWakeUpWorkItem: DispatchWorkItem?

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        // Without the tap the keys can no longer be watched, so a dictation in progress cannot
        // be ended by its release. Escape's rule (stop and insert nothing) is the safe ending.
        publishDictationChordActions(dictationChordStateMachine.handleEscape(at: ClickyTurnMetrics.currentUptimeSeconds))
        dictationChordStateMachine = ClickyDictationChordStateMachine()
        rescheduleDictationChordWakeUp()

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            // Key releases that happened while the tap was off were never seen, so the dictation
            // chord may be waiting for a release that already happened. Ask the system which
            // modifiers are held right now and let the chord catch up.
            let modifiersHeldNow = ClickyDictationModifierSet(
                cgEventFlagsRawValue: CGEventSource.flagsState(.combinedSessionState).rawValue
            )
            publishDictationChordActions(
                dictationChordStateMachine.handleModifiersChanged(modifiersHeldNow, at: ClickyTurnMetrics.currentUptimeSeconds)
            )
            rescheduleDictationChordWakeUp()
            return Unmanaged.passUnretained(event)
        }

        // The command-V that Clicky posts to paste dictated text passes through this tap too. It
        // is not the user pressing a key, so it must not count as "another key during a hold".
        if event.getIntegerValueField(.eventSourceUserData) == ClickyDictationInsertion.syntheticKeystrokeUserData {
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        let isFirstKeyDownOfEscape = eventType == .keyDown
            && eventKeyCode == Self.escapeKeyCode
            && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        if isFirstKeyDownOfEscape {
            escapeKeyPressedPublisher.send()
        }

        feedDictationChord(eventType: eventType, eventKeyCode: eventKeyCode, event: event)

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            lastShortcutReleaseUptimeSeconds = nil
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            lastShortcutReleaseUptimeSeconds = ClickyTurnMetrics.currentUptimeSeconds
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Dictation chord (fn + option)

    /// Hands one tap event to the dictation chord. The timestamps come from the same uptime clock
    /// as the metrics, taken here where the event is first seen.
    private func feedDictationChord(eventType: CGEventType, eventKeyCode: UInt16, event: CGEvent) {
        let currentUptimeSeconds = ClickyTurnMetrics.currentUptimeSeconds

        switch eventType {
        case .flagsChanged:
            let modifiersHeldNow = ClickyDictationModifierSet(cgEventFlagsRawValue: event.flags.rawValue)
            publishDictationChordActions(
                dictationChordStateMachine.handleModifiersChanged(modifiersHeldNow, at: currentUptimeSeconds)
            )
        case .keyDown:
            if eventKeyCode == Self.escapeKeyCode {
                // Key repeat of Escape would only repeat a cancel that already happened.
                guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
                publishDictationChordActions(dictationChordStateMachine.handleEscape(at: currentUptimeSeconds))
            } else {
                publishDictationChordActions(dictationChordStateMachine.handleNonModifierKeyDown(at: currentUptimeSeconds))
            }
        default:
            return
        }

        rescheduleDictationChordWakeUp()
    }

    private func publishDictationChordActions(_ dictationChordActions: [ClickyDictationChordAction]) {
        for dictationChordAction in dictationChordActions {
            dictationChordActionPublisher.send(dictationChordAction)
        }
    }

    /// The chord has no timers of its own. After every event this schedules one wake-up for the
    /// moment it next needs to be told the time (the end of a release's bounce window, or of the
    /// double-tap gap), replacing the previous one.
    private func rescheduleDictationChordWakeUp() {
        dictationChordWakeUpWorkItem?.cancel()
        dictationChordWakeUpWorkItem = nil

        guard let pendingDeadlineUptimeSeconds = dictationChordStateMachine.pendingDeadlineUptimeSeconds else { return }

        let secondsUntilDeadline = max(0, pendingDeadlineUptimeSeconds - ClickyTurnMetrics.currentUptimeSeconds)
        let wakeUpWorkItem = DispatchWorkItem { [weak self] in
            self?.wakeUpDictationChord()
        }
        dictationChordWakeUpWorkItem = wakeUpWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + secondsUntilDeadline + Self.dictationChordWakeUpSlackSeconds,
            execute: wakeUpWorkItem
        )
    }

    private func wakeUpDictationChord() {
        publishDictationChordActions(
            dictationChordStateMachine.advanceTime(to: ClickyTurnMetrics.currentUptimeSeconds)
        )
        // If the deadline has still not quite passed, this schedules another short wait.
        rescheduleDictationChordWakeUp()
    }

    /// Called when the app ended a dictation by itself (the microphone was refused, recognition
    /// stopped) while the keys may still be held, so the chord does not wait for a release or a
    /// press that no longer means anything.
    func resetDictationChordAfterDictationEndedByTheApp() {
        dictationChordStateMachine.resetAfterSessionEndedByTheApp()
        rescheduleDictationChordWakeUp()
    }
}
