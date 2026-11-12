import Foundation

/// How the insertion of one dictation ended. Logged by name in the dictation metrics.
nonisolated enum ClickyDictationInsertionOutcome: String {
    /// Command-V was sent to the app the user was typing in.
    case pasted
    /// A secure text field has focus (or secure keyboard input is on), so nothing was pasted.
    case clipboardSecureInput
    /// The user switched to another app while the dictation was being finished.
    case clipboardFocusChanged
    /// Clicky may not send keystrokes (the Accessibility permission is missing).
    case clipboardNoPermission
    /// The user pressed Escape, or started a newer dictation. Nothing was inserted or copied.
    case cancelled
    /// There was nothing to insert (no speech was heard).
    case empty
}

/// What the app knows at the moment the cleaned-up text is ready. No field holds any text from the
/// text field or the screen: only identities and yes/no answers.
nonisolated struct ClickyDictationInsertionContext {
    let textToInsert: String
    /// `IsSecureEventInputEnabled()`: some app (a password field, a terminal with secure keyboard
    /// entry) has switched on secure input for the whole session.
    let isSecureEventInputEnabled: Bool
    /// The focused element was a secure text field when the shortcut was pressed.
    let focusedElementWasSecureTextFieldAtPress: Bool
    /// The focused element is a secure text field right now (the user may have clicked into a
    /// password field while the dictation was being finished).
    let focusedElementIsSecureTextFieldNow: Bool
    /// The frontmost app when the shortcut was pressed, and now.
    let frontmostProcessIdentifierAtPress: Int32?
    let frontmostProcessIdentifierNow: Int32?
    let hasAccessibilityPermission: Bool
}

nonisolated enum ClickyDictationInsertionDecision: Equatable {
    /// Put the text on the clipboard, send command-V, then restore the clipboard.
    case pasteIntoFocusedApp
    /// Leave the text on the clipboard (never restore it) and tell the user.
    case leaveTextOnClipboard(because: ClickyDictationInsertionOutcome)
    case nothingToInsert
}

nonisolated enum ClickyDictationInsertion {
    /// How long the dictated text stays on the clipboard after command-V was sent, before the
    /// user's own clipboard is put back. The receiving app reads the clipboard when it handles the
    /// keystroke, so restoring too early would paste the old contents instead.
    static let clipboardRestoreDelaySeconds: TimeInterval = 0.300

    /// How long the overlay notice stays on screen after a clipboard fallback or an empty result.
    static let noticeDisplaySeconds: TimeInterval = 3.5

    /// Saving a clipboard holding more than this is not attempted, because reading it all could
    /// stall the app. The paste still happens; the dictated text is then left on the clipboard.
    static let maximumSavedClipboardBytes = 32 * 1024 * 1024

    /// The key code of "v" on a standard US keyboard, used when the current layout has no "v".
    static let fallbackPasteKeyCode: UInt16 = 9

    /// Stamped on the command-V events Clicky posts, so the keyboard event tap can recognise its
    /// own keystroke and not count it as the user pressing another key during a dictation.
    /// (The value spells "CLKY".)
    static let syntheticKeystrokeUserData: Int64 = 0x434C_4B59

    /// Order of the checks: nothing to say, secure fields, switched apps, then permission. Any
    /// refusal keeps the words on the clipboard.
    static func decide(_ context: ClickyDictationInsertionContext) -> ClickyDictationInsertionDecision {
        let trimmedText = context.textToInsert.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty {
            return .nothingToInsert
        }

        if context.isSecureEventInputEnabled
            || context.focusedElementWasSecureTextFieldAtPress
            || context.focusedElementIsSecureTextFieldNow {
            return .leaveTextOnClipboard(because: .clipboardSecureInput)
        }

        // Without a known frontmost app on both sides there is nothing to compare, and a paste
        // into an unknown target is the riskier choice.
        guard let frontmostProcessIdentifierAtPress = context.frontmostProcessIdentifierAtPress,
              let frontmostProcessIdentifierNow = context.frontmostProcessIdentifierNow,
              frontmostProcessIdentifierAtPress == frontmostProcessIdentifierNow else {
            return .leaveTextOnClipboard(because: .clipboardFocusChanged)
        }

        if !context.hasAccessibilityPermission {
            return .leaveTextOnClipboard(because: .clipboardNoPermission)
        }

        return .pasteIntoFocusedApp
    }

    /// The clipboard is put back only if nobody else wrote to it since our own write. If the
    /// change count moved, the user or another app copied something in the meantime, and putting
    /// the old contents back would destroy that newer copy.
    static func shouldRestoreSavedClipboard(
        changeCountAfterOurWrite: Int,
        changeCountNow: Int
    ) -> Bool {
        return changeCountAfterOurWrite == changeCountNow
    }

    /// Finds the key code that types `character` on the current keyboard layout, so command-V
    /// works on layouts where "v" is not in the US position. `characterForKeyCode` answers what an
    /// unmodified press of a key code types (nil when unknown). Falls back to the US key code.
    static func resolvePasteKeyCode(
        characterForKeyCode: (UInt16) -> String?,
        character: String = "v"
    ) -> UInt16 {
        return findKeyCode(typing: character, characterForKeyCode: characterForKeyCode) ?? fallbackPasteKeyCode
    }

    /// The lowest key code whose unmodified press types `character`, or nil if the layout has none
    /// (a Cyrillic or Arabic layout has no "v"). Separate from the fallback so the app can try a
    /// second layout before giving up.
    static func findKeyCode(
        typing character: String,
        characterForKeyCode: (UInt16) -> String?
    ) -> UInt16? {
        for keyCode in UInt16(0)..<UInt16(128) {
            if characterForKeyCode(keyCode)?.lowercased() == character {
                return keyCode
            }
        }
        return nil
    }

    /// The short sentence shown next to the cursor when the words were not pasted. Nil when no
    /// notice is needed (pasted, or the user cancelled).
    static func noticeText(for outcome: ClickyDictationInsertionOutcome) -> String? {
        switch outcome {
        case .pasted, .cancelled:
            return nil
        case .clipboardFocusChanged:
            return "copied. press command v to paste."
        case .clipboardSecureInput:
            return "copied, not pasted: secure field. press command v to paste."
        case .clipboardNoPermission:
            return "copied. turn on accessibility so i can paste for you."
        case .empty:
            return "didn't catch that."
        }
    }
}
