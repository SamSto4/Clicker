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
