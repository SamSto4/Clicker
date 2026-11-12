//
//  ClickyChatTextInput.swift
//  leanring-buddy
//
//  The text field of the chat panel. SwiftUI's own TextField cannot be told that Return sends and
//  Shift + Return adds a line, so this wraps a plain NSTextView. It is an ordinary focused text
//  view, which is what lets dictation (fn + option, which pastes) and the system's own text
//  services (spelling, emoji, input methods) work in it.
//
//  It is used as a SwiftUI view inside the panel's own hosting view. Nothing is ever added to an
//  existing hosting view by hand.
//

import AppKit
import SwiftUI

/// A text view that sends on Return and adds a line on Shift + Return (or Option + Return).
final class ClickyChatNSTextView: NSTextView {
    /// False for the search field: it is one line and Return only submits.
    var allowsMultipleLines = true
    var submitHandler: (() -> Void)?

    /// Takes the keyboard as soon as it is part of a window, so opening the panel (or switching
    /// to the search field) lets the user type at once.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76
        // While an input method is composing text (marked text), Return belongs to the input method.
        if isReturnKey && !hasMarkedText() {
            let isNewLineKeyHeld = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option)
            if isNewLineKeyHeld {
                if allowsMultipleLines {
                    insertNewline(nil)
                }
                return
            }
            submitHandler?()
            return
        }
        super.keyDown(with: event)
    }

    /// Pasted text (and dictated text, which arrives as a paste) keeps no fonts or colours of its
    /// source, so the field looks the same whatever was copied.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// The panel takes the keyboard without making Clicky the active app. Clicky is a menu bar app,
    /// and the standard editing shortcuts normally reach a text view through the app's Edit menu,
    /// which is not guaranteed to answer while the app is inactive. So this field handles them
    /// itself. Dictation depends on it: a dictation into the panel arrives as Command + V.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        // Caps Lock must not stop Command + V from pasting.
        let modifierFlagsWithoutCapsLock = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        let typedCharacter = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if modifierFlagsWithoutCapsLock == [.command] {
            switch typedCharacter {
            case "v":
                paste(nil)
                return true
            case "c":
                copy(nil)
                return true
            case "x":
                cut(nil)
                return true
            case "a":
                selectAll(nil)
                return true
            case "z":
                undoManager?.undo()
                return true
            default:
                break
            }
        }
        if modifierFlagsWithoutCapsLock == [.command, .shift] && typedCharacter == "z" {
            undoManager?.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct ClickyChatTextInput: NSViewRepresentable {
    @Binding var text: String
    let allowsMultipleLines: Bool
    /// Changes each time the field should take the keyboard (the panel opened, or the user came
    /// back from the chat list).
    let focusRequestCount: Int
    let onSubmit: () -> Void
    /// The height the text needs: one line at least, and at most `maximumVisibleLineCount` lines.
    let maximumVisibleLineCount: Int
    let onNeededHeightChange: (CGFloat) -> Void

    static var font: NSFont {
        NSFont.systemFont(ofSize: DS.ChatPanel.inputFontSizeInPoints)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        // The classic text system is built by hand: the height the text needs is measured through
        // the layout manager, which a default (newer) text view would otherwise have to switch to.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(textContainer)
        let textView = ClickyChatNSTextView(frame: .zero, textContainer: textContainer)
        textView.allowsMultipleLines = allowsMultipleLines
        textView.submitHandler = onSubmit
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Self.font
        textView.textColor = NSColor(DS.Colors.chatPanelPrimaryText)
        textView.insertionPointColor = NSColor(DS.Colors.accentText)
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.lastHandledFocusRequestCount = focusRequestCount

        // The wanted height depends on the width, which is only known once the view is laid out.
        textView.postsFrameChangedNotifications = true
        context.coordinator.frameChangeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.reportNeededHeight()
        }
        DispatchQueue.main.async {
            context.coordinator.reportNeededHeight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.submitHandler = onSubmit

        // The text is set from outside when the draft is cleared after sending. Typing already
        // updates the binding, so equal text is left alone (replacing it would move the caret).
        if textView.string != text {
            textView.string = text
            DispatchQueue.main.async {
                context.coordinator.reportNeededHeight()
            }
        }

        if context.coordinator.lastHandledFocusRequestCount != focusRequestCount {
            context.coordinator.lastHandledFocusRequestCount = focusRequestCount
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let frameChangeObserver = coordinator.frameChangeObserver {
            NotificationCenter.default.removeObserver(frameChangeObserver)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClickyChatTextInput
        weak var textView: ClickyChatNSTextView?
        var lastHandledFocusRequestCount = 0
        var frameChangeObserver: NSObjectProtocol?
        private var lastReportedNeededHeight: CGFloat = -1

        init(_ parent: ClickyChatTextInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            reportNeededHeight()
        }

        /// Tells SwiftUI how tall the text is, between one line and the line limit.
        func reportNeededHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let oneLineHeight = ceil(layoutManager.defaultLineHeight(for: ClickyChatTextInput.font))
            let textHeight = ceil(layoutManager.usedRect(for: textContainer).height)
            let neededHeight = min(
                max(textHeight, oneLineHeight),
                oneLineHeight * CGFloat(max(1, parent.maximumVisibleLineCount))
            )
            guard neededHeight != lastReportedNeededHeight else { return }
            lastReportedNeededHeight = neededHeight
            parent.onNeededHeightChange(neededHeight)
        }
    }
}
