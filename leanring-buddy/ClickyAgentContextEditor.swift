//
//  ClickyAgentContextEditor.swift
//  leanring-buddy
//
//  The editor of the chat panel's "context" tab (round 21b): a multi-line text view where the user
//  writes standing context for Clicky. It is the chat field's own text view (`ClickyChatNSTextView`), so
//  plain-text paste, the editing shortcuts while Clicky is not the active app, input-method composition
//  and dictation (which arrives as Command + V) work here exactly as they do in "ask clicky…". Return
//  adds a line: nothing is sent from this tab.
//
//  The 2,000-character limit is applied here, in the delegate, with the pure rules of
//  `ClickyAgentContextEditLimit`: a typed character past the limit is refused, a paste or dictation is
//  cut to what fits, and text an input method commits is cut when it is committed. A hand-edited file
//  that is already longer is shown whole; it can shrink, never grow.
//
//  It is a SwiftUI view inside the panel's own hosting view. Nothing is added to an existing hosting
//  view by hand.
//

import AppKit
import SwiftUI

/// Lets the view model ask the editor for what only the text view can do (an undoable "clear") without
/// the view model knowing AppKit. The editor fills in `textView` when it is made.
final class ClickyAgentContextEditorConnection {
    weak var textView: ClickyChatNSTextView?

    /// Empties the editor through the text view's own undoable path, so Command + Z brings the words
    /// back (and the autosave then writes them again). Returns false when there is no editor on screen
    /// or it cannot be edited yet.
    @discardableResult
    func clearAllTextUndoably() -> Bool {
        guard let textView, textView.isEditable else { return false }
        let wholeTextRange = NSRange(location: 0, length: (textView.string as NSString).length)
        guard wholeTextRange.length > 0 else { return true }
        // Its own undo step, apart from the typing before it.
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: wholeTextRange, replacementString: "") else { return false }
        textView.replaceCharacters(in: wholeTextRange, with: "")
        textView.didChangeText()
        textView.breakUndoCoalescing()
        return true
    }
}

struct ClickyAgentContextEditor: NSViewRepresentable {
    /// The words the editor shows. Typing reports them through `onTextChange`; they come back from
    /// outside only when the file was read again (a hand edit, a launch).
    let text: String
    /// False until the store's first read of the file has come back, so the editor never writes over a
    /// file it has not read.
    let isEditable: Bool
    let connection: ClickyAgentContextEditorConnection
    /// Every committed change of the words (never while an input method is still composing).
    let onTextChange: (String) -> Void

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
        // The editor has a fixed height and scrolls inside, so the panel never changes height while
        // the user types (the round 15 class of window-size bugs cannot start here).
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        // The classic text system, built by hand as the chat field builds it.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = ClickyChatNSTextView(frame: .zero, textContainer: textContainer)
        textView.allowsMultipleLines = true
        textView.returnKeyInsertsANewLine = true
        textView.submitHandler = nil
        // The editor takes the keyboard when the tab opens, as the chat field does on the chat tab.
        textView.takesKeyboardWhenAddedToWindow = true
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
        textView.textContainerInset = NSSize(
            width: DS.ChatPanel.inputHorizontalPaddingInPoints,
            height: DS.ChatPanel.inputVerticalPaddingInPoints
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isEditable = isEditable
        textView.string = text
        textView.setAccessibilityLabel("standing context for clicky")

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.lastReportedCharacterCount = text.count
        connection.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        connection.textView = textView
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        // Typing already updated the words, so equal words are left alone (replacing them would move the
        // caret). Different words come from a new read of the file; the undo steps of the old words are
        // dropped with them, so Command + Z can never mix the two.
        if !textView.hasMarkedText() && textView.string != text {
            textView.string = text
            context.coordinator.lastReportedCharacterCount = text.count
            context.coordinator.editorUndoManager.removeAllActions()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClickyAgentContextEditor
        weak var textView: ClickyChatNSTextView?
        /// The editor's own undo steps. The chat field lives in the same window, and without this the
        /// two would share the window's undo manager, so Command + Z here could undo typing over there.
        let editorUndoManager = UndoManager()
        /// The character count of the words last reported, so text an input method commits past the
        /// limit can be told apart from a hand-edited file that was already longer.
        var lastReportedCharacterCount = 0

        init(_ parent: ClickyAgentContextEditor) {
            self.parent = parent
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            editorUndoManager
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // A change of attributes only.
            guard let replacementString else { return true }
            // While an input method composes text every change is allowed; the text is cut when it is
            // committed (see `textDidChange`).
            if textView.hasMarkedText() { return true }
            switch ClickyAgentContextEditLimit.decision(currentText: textView.string, affectedRange: affectedCharRange, replacementText: replacementString) {
            case .allow:
                return true
            case .refuse:
                return false
            case .replaceWith(let adjustedReplacementText):
                // A paste or a dictation cut to what fits, or a paste with Windows line breaks. It is put
                // in right after this call returns, through the text view's own path, so it is one undo
                // step and the caret ends after it, as after any paste.
                DispatchQueue.main.async { [weak textView] in
                    guard let textView else { return }
                    // Its own undo step, as a paste is: inserted text would otherwise be merged with
                    // the typing before it, and Command + Z would take both back.
                    textView.breakUndoCoalescing()
                    textView.insertText(adjustedReplacementText, replacementRange: affectedCharRange)
                    textView.breakUndoCoalescing()
                }
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Composing text is reported once it is committed.
            if textView.hasMarkedText() { return }
            if let rangeToCut = ClickyAgentContextEditLimit.overflowRangeToCut(
                text: textView.string,
                caretUTF16Location: textView.selectedRange().location,
                characterCountBeforeTheChange: lastReportedCharacterCount
            ) {
                // The cut is an edit of its own; it reports the words again when it is done.
                if textView.shouldChangeText(in: rangeToCut, replacementString: "") {
                    textView.replaceCharacters(in: rangeToCut, with: "")
                    textView.didChangeText()
                }
                return
            }
            lastReportedCharacterCount = textView.string.count
            parent.onTextChange(textView.string)
        }
    }
}
