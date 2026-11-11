//
//  ClickyDictationTextInserter.swift
//  leanring-buddy
//
//  Puts dictated text into whatever text field the user was typing in, by placing it on the
//  clipboard, sending command-V to that app, and then putting the user's own clipboard back.
//  Reads no text from the text field or the screen: the only things asked of the Accessibility
//  API are the focused element's role and whether it is a secure (password) field.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What the Accessibility API says about the focused element. Never any text from it.
nonisolated struct ClickyDictationFocusedElementDetails: Sendable {
    let role: String?
    let isSecureTextField: Bool

    /// Used when the focused element could not be read (the app exposes no accessibility
    /// information, or did not answer in time). Unknown is not treated as secure: secure fields
    /// report themselves clearly, and many ordinary apps (browsers, Electron apps) sometimes
    /// answer nothing for a normal field.
    static let unreadable = ClickyDictationFocusedElementDetails(role: nil, isSecureTextField: false)
}

/// The app the user was typing in when they pressed the dictation shortcut.
nonisolated struct ClickyDictationInsertionTarget: Sendable {
    let frontmostProcessIdentifier: Int32?
}

enum ClickyDictationTextInserter {
    /// A busy or hung app can take seconds to answer an Accessibility request. The answer is only
    /// a hint, so it is not worth waiting long for.
    private nonisolated static let accessibilityMessagingTimeoutSeconds: Float = 0.25

    /// A clipboard type used by clipboard history tools to mean "do not keep this". It is a
    /// public community convention (nspasteboard.org), not part of the Apple API; tools that do
    /// not know it simply ignore it. It keeps dictated words out of clipboard histories.
    private static let transientClipboardTypeIdentifier = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// The restore of the user's clipboard that is still waiting for its delay to pass. A new
    /// insertion first lets it finish, so it can never save our own dictated text as "the user's
    /// clipboard".
    private static var pendingClipboardRestoreTask: Task<Void, Never>?

    // MARK: - Capturing the target

    static func captureInsertionTarget() -> ClickyDictationInsertionTarget {
        ClickyDictationInsertionTarget(
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }

    /// Reads the focused element's role and whether it is a secure text field. Safe to call from
    /// a background thread; it blocks for at most the messaging timeout.
    nonisolated static func readFocusedElementDetails(
        forProcessIdentifier processIdentifier: Int32
    ) -> ClickyDictationFocusedElementDetails {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, accessibilityMessagingTimeoutSeconds)

        var focusedElementValue: CFTypeRef?
        let focusedElementResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedElementResult == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return .unreadable
        }
        let focusedElement = focusedElementValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focusedElement, accessibilityMessagingTimeoutSeconds)

        let role = copyStringAttribute(kAXRoleAttribute, from: focusedElement)
        let subrole = copyStringAttribute(kAXSubroleAttribute, from: focusedElement)
        return ClickyDictationFocusedElementDetails(
            role: role,
            isSecureTextField: subrole == (kAXSecureTextFieldSubrole as String)
        )
    }

    private nonisolated static func copyStringAttribute(_ attributeName: String, from element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        let attributeResult = AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue)
        guard attributeResult == .success else { return nil }
        return attributeValue as? String
    }

    // MARK: - Inserting

    /// Pastes `textToInsert` into the app the user was typing in, or leaves it on the clipboard
    /// when pasting would not be safe. Returns what happened. `isInsertionStillWanted` is asked
    /// once, before anything is changed, so a dictation cancelled in the meantime inserts and
    /// copies nothing. `onPasteKeystrokePosted` is called at the moment command-V is sent, so the
    /// caller can time the user-visible delay without waiting for the clipboard to be restored.
    static func insert(
        textToInsert: String,
        target: ClickyDictationInsertionTarget,
        focusedElementWasSecureTextFieldAtPress: Bool,
        isInsertionStillWanted: () -> Bool,
        onPasteKeystrokePosted: () -> Void
    ) async -> ClickyDictationInsertionOutcome {
        let frontmostProcessIdentifierNow = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var focusedElementIsSecureTextFieldNow = false
        if let frontmostProcessIdentifierNow {
            // The Accessibility call can block, so it runs off the main thread.
            let focusedElementDetailsNow = await Task.detached(priority: .userInitiated) {
                readFocusedElementDetails(forProcessIdentifier: frontmostProcessIdentifierNow)
            }.value
            focusedElementIsSecureTextFieldNow = focusedElementDetailsNow.isSecureTextField
        }

        // Escape or a newer dictation may have arrived while the Accessibility answer was awaited.
        // Nothing has touched the clipboard yet, so stopping here leaves everything as it was.
        guard isInsertionStillWanted() else {
            return .cancelled
        }

        let insertionDecision = ClickyDictationInsertion.decide(
            ClickyDictationInsertionContext(
                textToInsert: textToInsert,
                isSecureEventInputEnabled: IsSecureEventInputEnabled(),
                focusedElementWasSecureTextFieldAtPress: focusedElementWasSecureTextFieldAtPress,
                focusedElementIsSecureTextFieldNow: focusedElementIsSecureTextFieldNow,
                frontmostProcessIdentifierAtPress: target.frontmostProcessIdentifier,
                frontmostProcessIdentifierNow: frontmostProcessIdentifierNow,
                hasAccessibilityPermission: WindowPositionManager.hasAccessibilityPermission()
            )
        )

        switch insertionDecision {
        case .nothingToInsert:
            return .empty

        case .leaveTextOnClipboard(let refusalOutcome):
            // The words are never lost: they wait on the clipboard for the user to paste, and the
            // clipboard is deliberately not restored.
            await finishPendingClipboardRestore()
            _ = writeDictatedTextToClipboard(textToInsert)
            return refusalOutcome

        case .pasteIntoFocusedApp:
            guard let frontmostProcessIdentifierNow else {
                _ = writeDictatedTextToClipboard(textToInsert)
                return .clipboardFocusChanged
            }
            return await pasteTextAndRestoreClipboard(
                textToInsert: textToInsert,
                targetProcessIdentifier: frontmostProcessIdentifierNow,
                onPasteKeystrokePosted: onPasteKeystrokePosted
            )
        }
    }

    private static func pasteTextAndRestoreClipboard(
        textToInsert: String,
        targetProcessIdentifier: Int32,
        onPasteKeystrokePosted: () -> Void
    ) async -> ClickyDictationInsertionOutcome {
        await finishPendingClipboardRestore()

        let generalPasteboard = NSPasteboard.general
        // Nil when the clipboard is too large to copy safely. The paste still goes ahead, and
        // the dictated text then stays on the clipboard because there is nothing to restore.
        let savedClipboardSnapshot = SavedClipboardSnapshot.capture(
            from: generalPasteboard,
            maximumTotalBytes: ClickyDictationInsertion.maximumSavedClipboardBytes
        )

        guard writeDictatedTextToClipboard(textToInsert) else {
            // The clipboard refused the write (practically never happens), so nothing can be
            // pasted or copied. Put the user's clipboard back untouched. The outcome list has no
            // entry for this; the permission one at least tells the user it did not work, and
            // it is better than silence.
            savedClipboardSnapshot?.restore(to: generalPasteboard)
            return .clipboardNoPermission
        }
        let clipboardChangeCountAfterOurWrite = generalPasteboard.changeCount

        guard postPasteKeystroke(toProcessIdentifier: targetProcessIdentifier) else {
            // The words stay on the clipboard (no restore) so the user can paste them by hand.
            return .clipboardNoPermission
        }
        onPasteKeystrokePosted()

        if let savedClipboardSnapshot {
            pendingClipboardRestoreTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(ClickyDictationInsertion.clipboardRestoreDelaySeconds * 1_000_000_000))
                // Only put the user's clipboard back if nobody else copied something meanwhile;
                // otherwise this would overwrite their newer copy with the old one.
                if ClickyDictationInsertion.shouldRestoreSavedClipboard(
                    changeCountAfterOurWrite: clipboardChangeCountAfterOurWrite,
                    changeCountNow: generalPasteboard.changeCount
                ) {
                    savedClipboardSnapshot.restore(to: generalPasteboard)
                }
            }
        }
        return .pasted
    }

    private static func finishPendingClipboardRestore() async {
        await pendingClipboardRestoreTask?.value
        pendingClipboardRestoreTask = nil
    }

    // MARK: - Clipboard

    private static func writeDictatedTextToClipboard(_ textToInsert: String) -> Bool {
        let generalPasteboard = NSPasteboard.general
        let dictatedTextItem = NSPasteboardItem()
        dictatedTextItem.setString(textToInsert, forType: .string)
        dictatedTextItem.setData(Data(), forType: transientClipboardTypeIdentifier)

        generalPasteboard.clearContents()
        if generalPasteboard.writeObjects([dictatedTextItem]) {
            return true
        }
        return generalPasteboard.setString(textToInsert, forType: .string)
    }

    /// Every item on the clipboard with every type it holds, so an image, a file list or rich text
    /// comes back exactly as it was and not only its plain-text form.
    private struct SavedClipboardSnapshot {
        let itemsWithTypeData: [[(type: NSPasteboard.PasteboardType, data: Data)]]

        static func capture(from pasteboard: NSPasteboard, maximumTotalBytes: Int) -> SavedClipboardSnapshot? {
            var totalBytes = 0
            var itemsWithTypeData: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []

            for pasteboardItem in pasteboard.pasteboardItems ?? [] {
                var typeDataPairsOfItem: [(type: NSPasteboard.PasteboardType, data: Data)] = []
                for pasteboardType in pasteboardItem.types {
                    guard let typeData = pasteboardItem.data(forType: pasteboardType) else { continue }
                    totalBytes += typeData.count
                    if totalBytes > maximumTotalBytes {
                        return nil
                    }
                    typeDataPairsOfItem.append((type: pasteboardType, data: typeData))
                }
                itemsWithTypeData.append(typeDataPairsOfItem)
            }
            return SavedClipboardSnapshot(itemsWithTypeData: itemsWithTypeData)
        }

        func restore(to pasteboard: NSPasteboard) {
            let restoredItems = itemsWithTypeData.map { typeDataPairsOfItem -> NSPasteboardItem in
                let restoredItem = NSPasteboardItem()
                for typeDataPair in typeDataPairsOfItem {
                    restoredItem.setData(typeDataPair.data, forType: typeDataPair.type)
                }
                return restoredItem
            }
            pasteboard.clearContents()
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    // MARK: - Keystroke

    /// Sends command-V to one process. The command flag is set explicitly on the events, so
    /// modifier keys the user may still be holding (the dictation shortcut's option key) cannot
    /// turn it into some other shortcut.
    private static func postPasteKeystroke(toProcessIdentifier targetProcessIdentifier: Int32) -> Bool {
        let pasteKeyCode = CGKeyCode(currentPasteKeyCode())
        let privateEventSource = CGEventSource(stateID: .privateState)

        guard let keyDownEvent = CGEvent(keyboardEventSource: privateEventSource, virtualKey: pasteKeyCode, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: privateEventSource, virtualKey: pasteKeyCode, keyDown: false) else {
            return false
        }

        for pasteKeystrokeEvent in [keyDownEvent, keyUpEvent] {
            pasteKeystrokeEvent.flags = .maskCommand
            pasteKeystrokeEvent.setIntegerValueField(
                .eventSourceUserData,
                value: ClickyDictationInsertion.syntheticKeystrokeUserData
            )
            pasteKeystrokeEvent.postToPid(targetProcessIdentifier)
        }
        return true
    }

    /// The key code that types "v" on the keyboard layout in use, so command-V also works on
    /// layouts where "v" is not where it is on a US keyboard. A layout without a Latin "v"
    /// (Cyrillic, Arabic) is answered by the ASCII-capable layout macOS itself uses for
    /// shortcuts; if that finds nothing either, the US key code is used.
    private static func currentPasteKeyCode() -> UInt16 {
        let keyboardLayoutSources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        ]

        for keyboardLayoutSource in keyboardLayoutSources.compactMap({ $0 }) {
            guard let layoutDataPointer = TISGetInputSourceProperty(keyboardLayoutSource, kTISPropertyUnicodeKeyLayoutData) else {
                continue
            }
            let keyboardLayoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue()
            if let keyCode = ClickyDictationInsertion.findKeyCode(
                typing: "v",
                characterForKeyCode: { keyCode in
                    characterTypedByUnmodifiedKeyPress(keyCode: keyCode, keyboardLayoutData: keyboardLayoutData)
                }
            ) {
                return keyCode
            }
        }
        return ClickyDictationInsertion.fallbackPasteKeyCode
    }

    private static func characterTypedByUnmodifiedKeyPress(keyCode: UInt16, keyboardLayoutData: CFData) -> String? {
        guard let keyboardLayoutBytes = CFDataGetBytePtr(keyboardLayoutData) else { return nil }
        let keyboardLayoutPointer = UnsafeRawPointer(keyboardLayoutBytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var typedCharacters = [UniChar](repeating: 0, count: 4)
        var typedCharacterCount = 0
        let translationStatus = UCKeyTranslate(
            keyboardLayoutPointer,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            typedCharacters.count,
            &typedCharacterCount,
            &typedCharacters
        )
        guard translationStatus == noErr, typedCharacterCount > 0 else { return nil }
        return String(utf16CodeUnits: typedCharacters, count: typedCharacterCount)
    }
}
