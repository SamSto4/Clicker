import Foundation

/// The modifier keys the dictation shortcut cares about. Caps Lock, the numeric pad flag and the
/// help flag are deliberately not representable here: Caps Lock is a toggle and not a held key,
/// and if it counted, a Mac with Caps Lock on would never match "exactly fn + option".
nonisolated struct ClickyDictationModifierSet: OptionSet, Equatable {
    let rawValue: Int

    static let function = ClickyDictationModifierSet(rawValue: 1 << 0)
    static let option = ClickyDictationModifierSet(rawValue: 1 << 1)
    static let control = ClickyDictationModifierSet(rawValue: 1 << 2)
    static let shift = ClickyDictationModifierSet(rawValue: 1 << 3)
    static let command = ClickyDictationModifierSet(rawValue: 1 << 4)

    // The bit values below are the public CGEventFlags masks from CGEventTypes.h. They are written
    // out as numbers (instead of importing CoreGraphics) so this type stays Foundation-only and
    // the smoke program can test the Caps Lock filtering without AppKit.
    private static let cgEventFlagsShiftMask: UInt64 = 0x0002_0000
    private static let cgEventFlagsControlMask: UInt64 = 0x0004_0000
    private static let cgEventFlagsAlternateMask: UInt64 = 0x0008_0000
    private static let cgEventFlagsCommandMask: UInt64 = 0x0010_0000
    private static let cgEventFlagsSecondaryFunctionMask: UInt64 = 0x0080_0000

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Reads the held modifiers out of the raw flags of a CGEvent. Every other bit (Caps Lock,
    /// numeric pad, help, and the device-dependent left/right bits) is ignored on purpose.
    init(cgEventFlagsRawValue: UInt64) {
        var modifierSet = ClickyDictationModifierSet()
        if cgEventFlagsRawValue & Self.cgEventFlagsSecondaryFunctionMask != 0 { modifierSet.insert(.function) }
        if cgEventFlagsRawValue & Self.cgEventFlagsAlternateMask != 0 { modifierSet.insert(.option) }
        if cgEventFlagsRawValue & Self.cgEventFlagsControlMask != 0 { modifierSet.insert(.control) }
        if cgEventFlagsRawValue & Self.cgEventFlagsShiftMask != 0 { modifierSet.insert(.shift) }
        if cgEventFlagsRawValue & Self.cgEventFlagsCommandMask != 0 { modifierSet.insert(.command) }
        self = modifierSet
    }
}

/// Every timing of the dictation shortcut, in one place so it can be tuned without reading the
/// state machine.
nonisolated enum ClickyDictationChordTimings {
    /// How long a release is held back before it counts. Modifier keys chatter when a finger rolls
    /// off two keys, and a flicker must not end the dictation, so a release is only believed once
    /// the combination has stayed away this long. If the combination returns first, the release is
    /// forgotten.
    static let releaseBounceWindowSeconds: TimeInterval = 0.040

    /// A press shorter than this is a tap and not a deliberate hold. Too short to hold any speech,
    /// so it can only be the first half of a double-tap (or an accident).
    /// Raised from 0.25 s after real use: the user's taps were held about 0.3 to 0.45 s, so each
    /// one was treated as a short dictation and hands-free never locked.
    static let quickTapMaximumHoldSeconds: TimeInterval = 0.450

    /// After a quick tap is released, the second tap must start within this long, or the first one
    /// is treated as an accident and thrown away.
    /// Raised from 0.35 s for the same reason: a relaxed double-tap leaves a longer gap.
    static let secondTapMaximumGapSeconds: TimeInterval = 0.600
}

/// What the state machine asks the rest of the app to do.
nonisolated enum ClickyDictationChordAction: Equatable {
    /// The combination was pressed: start capturing the microphone now.
    case startCapturing(pressedAt: TimeInterval)

    /// A double-tap was recognised: keep capturing after the keys are released.
    case lockHandsFree

    /// Stop capturing and insert what was said. `releaseObservedAt` is when the keys were first
    /// seen released (or the stopping press, in hands-free), and not when the bounce window
    /// ended, because that first moment is the one the user feels.
    case finishAndInsert(releaseObservedAt: TimeInterval, wasHandsFree: Bool)

    /// A lone quick tap, or a short press used as part of another keyboard shortcut: stop
    /// capturing and insert nothing, silently.
    case discardWithoutInserting

    /// Escape was pressed while dictation was active: stop and insert nothing.
    case cancel
}

/// Recognises the dictation shortcut (hold fn + option; double-tap to lock hands-free) from a
/// stream of modifier changes, key presses and timestamps.
///
/// It is pure on purpose: it has no timers and reads no clock. The caller passes the time of every
/// event, and asks `pendingDeadlineUptimeSeconds` when it should call `advanceTime(to:)` next. That
/// is what makes every timing rule testable with explicit timestamps.
///
/// Rules:
/// - Only the exact set fn + option counts. fn + option + shift, ctrl + option and the like never
///   start dictation. A combination also cannot be started by sliding into it from another
///   (for example releasing shift while holding fn + option): all modifiers must have been
///   released since any other modifier was last held.
/// - A release is held back for the bounce window and forgotten if the combination returns.
/// - A press shorter than the quick-tap limit followed by a second quick press within the gap
///   locks hands-free. While locked, the next press stops and inserts, and the release that
///   follows that press is ignored.
/// - Any other key pressed during a short press or the gap after it rules out the double-tap, and
///   a short press that had another key pressed is discarded instead of inserted.
/// - Escape cancels. After Escape the keys still being held are ignored until they are released.
nonisolated struct ClickyDictationChordStateMachine {
    /// The only combination that dictates: exactly fn + option.
    static let dictationCombination: ClickyDictationModifierSet = [.function, .option]

    private enum State: Equatable {
        case idle
        /// The combination is down (first press). Capturing has started.
        case holdingFirstPress(pressedAt: TimeInterval, tapRuledOut: Bool)
        /// The combination just went away; waiting out the bounce window.
        case firstReleasePending(pressedAt: TimeInterval, releasedAt: TimeInterval, tapRuledOut: Bool)
        /// A quick tap ended. Capturing continues while waiting for the second tap.
        case awaitingSecondTap(firstTapReleasedAt: TimeInterval)
        case holdingSecondPress(pressedAt: TimeInterval, tapRuledOut: Bool)
        case secondReleasePending(pressedAt: TimeInterval, releasedAt: TimeInterval, tapRuledOut: Bool)
        /// Locked by a double-tap. The keys are up and capturing continues.
        case handsFreeLocked
        /// A press whose release must be ignored: the press that stopped hands-free, or keys still
        /// held after Escape.
        case ignoredPressHeld
        case ignoredPressReleasePending(releasedAt: TimeInterval)
    }

    private var state: State = .idle
    private var lastModifierSet = ClickyDictationModifierSet()
    /// True from the moment any modifier outside fn + option is held until all modifiers have been
    /// released. While true, a new press of the combination is not accepted.
    private var hasHeldOtherModifierSinceAllModifiersWereReleased = false

    // MARK: - Deadlines

    /// The time at which the caller should next call `advanceTime(to:)`, or nil when the machine
    /// is waiting for the next key event and not for a time.
    var pendingDeadlineUptimeSeconds: TimeInterval? {
        switch state {
        case .firstReleasePending(_, let releasedAt, _),
             .secondReleasePending(_, let releasedAt, _),
             .ignoredPressReleasePending(let releasedAt):
            return releasedAt + ClickyDictationChordTimings.releaseBounceWindowSeconds
        case .awaitingSecondTap(let firstTapReleasedAt):
            return firstTapReleasedAt + ClickyDictationChordTimings.secondTapMaximumGapSeconds
        default:
            return nil
        }
    }

    /// Lets time pass without a key event. Confirms releases whose bounce window has ended and
    /// expires a double-tap window nobody used. A deadline is still open at exactly its time (it
    /// counts as "within"), and is over only after it.
    mutating func advanceTime(to currentUptimeSeconds: TimeInterval) -> [ClickyDictationChordAction] {
        var actions: [ClickyDictationChordAction] = []
        // One deadline can lead straight into another (a confirmed quick tap opens the second-tap
        // window), and a late call must settle both, so keep going until nothing is due.
        while let actionsFromOneDeadline = settleOneDueDeadline(at: currentUptimeSeconds) {
            actions.append(contentsOf: actionsFromOneDeadline)
        }
        return actions
    }

    private mutating func settleOneDueDeadline(at currentUptimeSeconds: TimeInterval) -> [ClickyDictationChordAction]? {
        let releaseBounceWindowSeconds = ClickyDictationChordTimings.releaseBounceWindowSeconds
        let quickTapMaximumHoldSeconds = ClickyDictationChordTimings.quickTapMaximumHoldSeconds

        switch state {
        case .firstReleasePending(let pressedAt, let releasedAt, let tapRuledOut)
            where currentUptimeSeconds > releasedAt + releaseBounceWindowSeconds:
            let wasQuickTap = (releasedAt - pressedAt) < quickTapMaximumHoldSeconds
            if tapRuledOut {
                state = .idle
                return wasQuickTap
                    ? [.discardWithoutInserting]
                    : [.finishAndInsert(releaseObservedAt: releasedAt, wasHandsFree: false)]
            }
            if wasQuickTap {
                state = .awaitingSecondTap(firstTapReleasedAt: releasedAt)
                return []
            }
            state = .idle
            return [.finishAndInsert(releaseObservedAt: releasedAt, wasHandsFree: false)]

        case .awaitingSecondTap(let firstTapReleasedAt)
            where currentUptimeSeconds > firstTapReleasedAt + ClickyDictationChordTimings.secondTapMaximumGapSeconds:
            state = .idle
            return [.discardWithoutInserting]

        case .secondReleasePending(let pressedAt, let releasedAt, let tapRuledOut)
            where currentUptimeSeconds > releasedAt + releaseBounceWindowSeconds:
            let wasQuickTap = (releasedAt - pressedAt) < quickTapMaximumHoldSeconds
            if wasQuickTap && !tapRuledOut {
                state = .handsFreeLocked
                return [.lockHandsFree]
            }
            state = .idle
            return wasQuickTap
                ? [.discardWithoutInserting]
                : [.finishAndInsert(releaseObservedAt: releasedAt, wasHandsFree: false)]

        case .ignoredPressReleasePending(let releasedAt)
            where currentUptimeSeconds > releasedAt + releaseBounceWindowSeconds:
            state = .idle
            return []

        default:
            return nil
        }
    }

    // MARK: - Events

    /// Call for every flags-changed event with the modifiers now held.
    mutating func handleModifiersChanged(
        _ heldModifiers: ClickyDictationModifierSet,
        at currentUptimeSeconds: TimeInterval
    ) -> [ClickyDictationChordAction] {
        var actions = advanceTime(to: currentUptimeSeconds)

        lastModifierSet = heldModifiers
        if !heldModifiers.subtracting(Self.dictationCombination).isEmpty {
            hasHeldOtherModifierSinceAllModifiersWereReleased = true
        } else if heldModifiers.isEmpty {
            hasHeldOtherModifierSinceAllModifiersWereReleased = false
        }

        let combinationIsDown = heldModifiers == Self.dictationCombination
        let combinationMayBeginAPress = combinationIsDown && !hasHeldOtherModifierSinceAllModifiersWereReleased

        switch state {
        case .idle:
            if combinationMayBeginAPress {
                state = .holdingFirstPress(pressedAt: currentUptimeSeconds, tapRuledOut: false)
                actions.append(.startCapturing(pressedAt: currentUptimeSeconds))
            }

        case .holdingFirstPress(let pressedAt, let tapRuledOut):
            if !combinationIsDown {
                state = .firstReleasePending(pressedAt: pressedAt, releasedAt: currentUptimeSeconds, tapRuledOut: tapRuledOut)
            }

        case .firstReleasePending(let pressedAt, _, let tapRuledOut):
            // The combination came back inside the bounce window: it was only a flicker.
            if combinationIsDown {
                state = .holdingFirstPress(pressedAt: pressedAt, tapRuledOut: tapRuledOut)
            }

        case .awaitingSecondTap:
            if combinationMayBeginAPress {
                state = .holdingSecondPress(pressedAt: currentUptimeSeconds, tapRuledOut: false)
            }

        case .holdingSecondPress(let pressedAt, let tapRuledOut):
            if !combinationIsDown {
                state = .secondReleasePending(pressedAt: pressedAt, releasedAt: currentUptimeSeconds, tapRuledOut: tapRuledOut)
            }

        case .secondReleasePending(let pressedAt, _, let tapRuledOut):
            if combinationIsDown {
                state = .holdingSecondPress(pressedAt: pressedAt, tapRuledOut: tapRuledOut)
            }

        case .handsFreeLocked:
            // The next press stops hands-free dictation. Its release is ignored (see the state).
            if combinationMayBeginAPress {
                state = .ignoredPressHeld
                actions.append(.finishAndInsert(releaseObservedAt: currentUptimeSeconds, wasHandsFree: true))
            }

        case .ignoredPressHeld:
            if !combinationIsDown {
                state = .ignoredPressReleasePending(releasedAt: currentUptimeSeconds)
            }

        case .ignoredPressReleasePending:
            if combinationIsDown {
                state = .ignoredPressHeld
            }
        }

        return actions
    }

    /// Call for every key press that is not a modifier key and not Escape.
    mutating func handleNonModifierKeyDown(at currentUptimeSeconds: TimeInterval) -> [ClickyDictationChordAction] {
        var actions = advanceTime(to: currentUptimeSeconds)

        switch state {
        case .holdingFirstPress(let pressedAt, _):
            state = .holdingFirstPress(pressedAt: pressedAt, tapRuledOut: true)
        case .firstReleasePending(let pressedAt, let releasedAt, _):
            state = .firstReleasePending(pressedAt: pressedAt, releasedAt: releasedAt, tapRuledOut: true)
        case .awaitingSecondTap:
            // Typing between two taps means it was no double-tap.
            state = .idle
            actions.append(.discardWithoutInserting)
        case .holdingSecondPress(let pressedAt, _):
            state = .holdingSecondPress(pressedAt: pressedAt, tapRuledOut: true)
        case .secondReleasePending(let pressedAt, let releasedAt, _):
            state = .secondReleasePending(pressedAt: pressedAt, releasedAt: releasedAt, tapRuledOut: true)
        case .idle, .handsFreeLocked, .ignoredPressHeld, .ignoredPressReleasePending:
            break
        }

        return actions
    }

    /// Call when Escape is pressed.
    mutating func handleEscape(at currentUptimeSeconds: TimeInterval) -> [ClickyDictationChordAction] {
        var actions = advanceTime(to: currentUptimeSeconds)

        switch state {
        case .holdingFirstPress, .holdingSecondPress:
            // The keys are still down, so their release must not count as anything.
            state = .ignoredPressHeld
            actions.append(.cancel)
        case .firstReleasePending, .secondReleasePending, .awaitingSecondTap, .handsFreeLocked:
            state = .idle
            actions.append(.cancel)
        case .idle, .ignoredPressHeld, .ignoredPressReleasePending:
            break
        }

        return actions
    }

    /// For when the app ended the session by itself (microphone refused, recognition died) and
    /// the machine would otherwise stay in hands-free or in a hold. If the keys are still down,
    /// their release is ignored instead of starting something new.
    mutating func resetAfterSessionEndedByTheApp() {
        state = (lastModifierSet == Self.dictationCombination) ? .ignoredPressHeld : .idle
    }
}
