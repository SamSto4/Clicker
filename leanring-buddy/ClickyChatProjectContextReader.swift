//
//  ClickyChatProjectContextReader.swift
//  leanring-buddy
//
//  Works out which project a new chat belongs to, from where the user was when it started: the
//  git repository of the frontmost window's document, else the document's folder, else (VS Code
//  family only) the folder named in the window title, else the app.
//
//  What is read from the other app: the window's document address (`AXDocument`), and for the
//  VS Code family only, the window's title. Never the document's contents, never any other text
//  on the screen. The answer only groups the chat list on this Mac; it is never sent to the model.
//
//  Since round 14 it also reads the title of the frontmost window on every turn
//  (`readFrontmostWindowTitle`). That title does go to the model (cleaned, in the "right now"
//  block) and is kept with each chat exchange, so Clicky can tell which screen the earlier
//  messages were about.
//

import AppKit
import ApplicationServices

enum ClickyChatProjectContextReader {
    /// A busy or hung app can take seconds to answer an Accessibility request. The answer only
    /// decides which group a chat is listed in, so it is not worth waiting long for.
    private nonisolated static let accessibilityMessagingTimeoutSeconds: Float = 0.25

    /// Reads the context of the app that was frontmost when the message was sent. Blocks for a
    /// short while at most, so it is called off the main thread. When the app gives no document
    /// (browsers, terminals, apps without Accessibility support) the project is simply the app.
    nonisolated static func readContext(
        processIdentifier: Int32?,
        applicationBundleIdentifier: String?,
        applicationName: String?
    ) -> ClickyChatProjectContext {
        var documentPath: String?
        var windowTitle: String?

        if let processIdentifier {
            let applicationElement = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(applicationElement, accessibilityMessagingTimeoutSeconds)

            if let frontmostWindowElement = copyFrontmostWindowElement(of: applicationElement) {
                AXUIElementSetMessagingTimeout(frontmostWindowElement, accessibilityMessagingTimeoutSeconds)
                documentPath = ClickyChatProjectResolver.documentPath(
                    fromAccessibilityDocumentValue: copyStringAttribute(kAXDocumentAttribute, from: frontmostWindowElement)
                )
                // The title is read only for the apps whose windows report no document but name
                // the open folder in the title. For every other app it is not read at all.
                if let applicationBundleIdentifier,
                   ClickyChatProjectResolver.vsCodeFamilyBundleIdentifiers.contains(applicationBundleIdentifier) {
                    windowTitle = copyStringAttribute(kAXTitleAttribute, from: frontmostWindowElement)
                }
            }
        }

        return ClickyChatProjectContext(
            documentPath: documentPath,
            windowTitle: windowTitle,
            applicationBundleIdentifier: applicationBundleIdentifier,
            applicationName: applicationName
        )
    }

    /// The title of the frontmost app's focused window, read every turn (not only when a chat
    /// starts) so Clicky can tell the model which screen it is looking at and notice when the
    /// screen changed between two questions. Only the title is read, never contents. Blocks for
    /// a short while at most (the same 0.25 s Accessibility timeout as above), so it is called
    /// off the main thread, alongside the screenshot. nil for an app without Accessibility
    /// support, an app with no window, a title that is not text, or a read that timed out.
    /// The title is text another program chose: it is cleaned by `ClickyWindowTitleText` before
    /// it is used anywhere.
    nonisolated static func readFrontmostWindowTitle(processIdentifier: Int32?) -> String? {
        guard let processIdentifier else { return nil }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, accessibilityMessagingTimeoutSeconds)
        guard let frontmostWindowElement = copyFrontmostWindowElement(of: applicationElement) else { return nil }
        AXUIElementSetMessagingTimeout(frontmostWindowElement, accessibilityMessagingTimeoutSeconds)
        return copyStringAttribute(kAXTitleAttribute, from: frontmostWindowElement)
    }

    /// The document address and the title of the frontmost app's focused window, read in one pass
    /// (round 17, file editing). The document tells Clicky which file the user has open (for relative
    /// paths and the "frontmost document" line), and the title says whether that file has unsaved
    /// edits when an apply is about to write to it. Only these two attributes are read, never
    /// contents, with the same 0.25 s Accessibility timeout as every other read here, so the caller
    /// runs it off the main thread. nil parts for an app without a document or title.
    nonisolated static func readFrontmostDocumentPathAndWindowTitle(processIdentifier: Int32?) -> (documentPath: String?, windowTitle: String?) {
        guard let processIdentifier else { return (nil, nil) }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, accessibilityMessagingTimeoutSeconds)
        guard let frontmostWindowElement = copyFrontmostWindowElement(of: applicationElement) else { return (nil, nil) }
        AXUIElementSetMessagingTimeout(frontmostWindowElement, accessibilityMessagingTimeoutSeconds)
        let documentPath = ClickyChatProjectResolver.documentPath(
            fromAccessibilityDocumentValue: copyStringAttribute(kAXDocumentAttribute, from: frontmostWindowElement)
        )
        return (documentPath, copyStringAttribute(kAXTitleAttribute, from: frontmostWindowElement))
    }

    /// The project for a context, with the walk up to a git root done on the real disk.
    nonisolated static func resolveProject(for context: ClickyChatProjectContext) -> ClickyChatProject {
        ClickyChatProjectResolver.resolve(context, fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        })
    }

    private nonisolated static func copyFrontmostWindowElement(of applicationElement: AXUIElement) -> AXUIElement? {
        for windowAttributeName in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var windowValue: CFTypeRef?
            let windowResult = AXUIElementCopyAttributeValue(applicationElement, windowAttributeName as CFString, &windowValue)
            if windowResult == .success, let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
                return (windowValue as! AXUIElement)
            }
        }
        return nil
    }

    private nonisolated static func copyStringAttribute(_ attributeName: String, from element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        let attributeResult = AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue)
        guard attributeResult == .success else { return nil }
        return attributeValue as? String
    }
}
