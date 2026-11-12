import Foundation

/// The timing of the chat panel shortcut (a clean tap of option + command).
nonisolated enum ClickyChatPanelTapTimings {
    /// The keys must come up within this long of going down, or it was a hold and not a tap.
    /// A hold is what someone does while reaching for the letter of an option + command
    /// shortcut, so a long press never opens the panel by accident.
    static let maximumTapHoldSeconds: TimeInterval = 0.400
}

/// What the chat panel tap recogniser asks the rest of the app to do.
nonisolated enum ClickyChatPanelTapAction: Equatable {
    /// A clean tap of option + command was recognised: open the chat panel, or close it if it is open.
    case togglePanel
}

/// Recognises a clean tap of option + command from the modifier changes and key presses of the
/// listen-only event tap, with the time of every event passed in by the caller.
///
/// It is pure on purpose, like `ClickyDictationChordStateMachine`: it has no timers and reads no
/// clock, so every rule is tested with explicit timestamps. It needs no deadline either: whether a
/// press was short enough is decided at the release, from the two timestamps.
///
/// Rules:
/// - Only the exact set option + command counts, reached from no modifiers held. A combination
///   cannot be slid into from another one (releasing shift while holding option + command does not
///   start a tap). Caps Lock is not in the modifier set at all, so it is ignored.
/// - The tap fires when the combination starts to come apart (either key up) within
///   `maximumTapHoldSeconds` of the press, as long as nothing else happened in between.
/// - Any other key pressed while the combination is held cancels the tap: option + command + Escape,
///   option + command + I and every other option + command shortcut of another app never open the
///   panel. So does another modifier joining (control, shift, fn).
/// - After a cancelled or fired tap, nothing happens until every modifier has been released.
nonisolated struct ClickyChatPanelTapStateMachine {
    /// The only combination that opens the panel: exactly option + command.
    static let panelCombination: ClickyDictationModifierSet = [.option, .command]

    private enum State: Equatable {
        case idle
        /// The combination is down and nothing else has happened since.
        case holdingCleanPress(pressedAt: TimeInterval)
        /// The tap fired or was cancelled; the keys still down must mean nothing until they are all up.
        case waitingForAllModifiersToBeReleased
    }

    private var state: State = .idle
    /// True from the moment any modifier outside option + command is held until all modifiers have
    /// been released. While true, a press of the combination does not start a tap.
    private var hasHeldOtherModifierSinceAllModifiersWereReleased = false

    /// Call for every flags-changed event with the modifiers now held.
    mutating func handleModifiersChanged(
        _ heldModifiers: ClickyDictationModifierSet,
        at currentUptimeSeconds: TimeInterval
    ) -> [ClickyChatPanelTapAction] {
        if !heldModifiers.subtracting(Self.panelCombination).isEmpty {
            hasHeldOtherModifierSinceAllModifiersWereReleased = true
        } else if heldModifiers.isEmpty {
            hasHeldOtherModifierSinceAllModifiersWereReleased = false
        }

        let combinationIsDown = heldModifiers == Self.panelCombination

        switch state {
        case .idle:
            if combinationIsDown && !hasHeldOtherModifierSinceAllModifiersWereReleased {
                state = .holdingCleanPress(pressedAt: currentUptimeSeconds)
            }
            return []

        case .holdingCleanPress(let pressedAt):
            if combinationIsDown {
                // A flags change that leaves the set as it was (for example Caps Lock) changes nothing.
                return []
            }
            let anotherModifierJoined = !heldModifiers.subtracting(Self.panelCombination).isEmpty
            if anotherModifierJoined {
                state = .waitingForAllModifiersToBeReleased
                return []
            }
            // One or both keys came up: the combination is coming apart cleanly.
            state = heldModifiers.isEmpty ? .idle : .waitingForAllModifiersToBeReleased
            let wasShortEnoughToBeATap = (currentUptimeSeconds - pressedAt) <= ClickyChatPanelTapTimings.maximumTapHoldSeconds
            return wasShortEnoughToBeATap ? [.togglePanel] : []

        case .waitingForAllModifiersToBeReleased:
            if heldModifiers.isEmpty {
                state = .idle
            }
            return []
        }
    }

    /// Call for every key press that is not a modifier key. Escape counts: option + command + Escape
    /// is another app's shortcut and must not open the panel.
    mutating func handleNonModifierKeyDown() -> [ClickyChatPanelTapAction] {
        if case .holdingCleanPress = state {
            state = .waitingForAllModifiersToBeReleased
        }
        return []
    }

    /// For when the event tap was off for a while and releases may have been missed: the machine
    /// is told what is held right now and forgets any press in progress, so a release it never saw
    /// cannot fire a tap later.
    mutating func resetToModifiersHeldNow(_ heldModifiers: ClickyDictationModifierSet) {
        hasHeldOtherModifierSinceAllModifiersWereReleased = !heldModifiers.subtracting(Self.panelCombination).isEmpty
        state = heldModifiers.isEmpty ? .idle : .waitingForAllModifiersToBeReleased
    }
}
