//
//  ClickyAccessibilityElementReader.swift
//  leanring-buddy
//
//  Round 21 (explaining on screen): asks Accessibility which element is under a point on the screen,
//  so `ClickyPointSnap` can move the blue cursor to the centre of a small button the model pointed
//  just beside. What is read from the other app: the element's role, its frame (position and size)
//  and the process it belongs to, of that one element (and, for a piece of text, an image or a cell,
//  the role and frame of its parent). Never its title, value, children or any other text. The role
//  is only used for the snap decision; the metrics line holds the outcome word.
//
//  Clicky's own windows (the full-screen cursor overlay, the chat panel, the status pill) lie on top
//  of every other app. A hit test on the system-wide element could answer with one of them, and then
//  pointing would never snap. So the app under the point is found first from the window list,
//  skipping every window Clicky owns, and only that app is asked (`AXUIElementCopyElementAtPosition`
//  on its application element, which hit-tests that app's windows alone).
//
//  Call it off the main thread (a detached task): each read waits at most a quarter second for an
//  app that does not answer. The timeout is set on each element read, never on the system-wide
//  element, because that would change the timeout of every Accessibility read in the process.
//

import AppKit
import ApplicationServices

/// The facts of the element under a point: its role, its frame in Accessibility's global
/// coordinates (points from the top-left corner of the primary display, y growing downwards), and
/// the process it belongs to.
nonisolated struct ClickyAccessibilityElementFacts: Equatable, Sendable {
    let role: String
    let frameInGlobalTopLeftPoints: CGRect
    let processIdentifier: pid_t
}

nonisolated enum ClickyAccessibilityElementReadResult: Equatable, Sendable {
    case found(ClickyAccessibilityElementFacts)
    /// Nothing answered at the point, or its role or frame could not be read.
    case noElement
    /// The app under the point did not answer within the timeout.
    case timedOut
}

nonisolated enum ClickyAccessibilityElementReader {
    /// The same short wait every other Accessibility read in Clicky uses.
    static let messagingTimeoutSeconds: Float = 0.25

    /// A window this transparent cannot be what the user sees at the point (an invisible overlay
    /// of another app), so the window under it is used instead.
    static let minimumVisibleWindowAlpha: Double = 0.01

    static func elementUnderPoint(globalTopLeftPoint: CGPoint) -> ClickyAccessibilityElementReadResult {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let appProcessIdentifier = processIdentifierOfTopmostWindowNotOwnedByClicky(
            containingGlobalTopLeftPoint: globalTopLeftPoint,
            ownProcessIdentifier: ownProcessIdentifier
        ) else {
            return .noElement
        }

        let applicationElement = AXUIElementCreateApplication(appProcessIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeoutSeconds)
        var elementUnderPoint: AXUIElement?
        let hitTestResult = AXUIElementCopyElementAtPosition(
            applicationElement,
            Float(globalTopLeftPoint.x),
            Float(globalTopLeftPoint.y),
            &elementUnderPoint
        )
        guard hitTestResult == .success, let elementUnderPoint else {
            return hitTestResult == .cannotComplete ? .timedOut : .noElement
        }

        // The process first: it costs no message to the other app, and an element of Clicky's own
        // needs nothing more read (the decision refuses it before looking at the role or frame).
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(elementUnderPoint, &processIdentifier) == .success else {
            return .noElement
        }
        if processIdentifier == ownProcessIdentifier {
            return .found(ClickyAccessibilityElementFacts(role: "AXUnknown", frameInGlobalTopLeftPoints: .zero, processIdentifier: processIdentifier))
        }

        let roleReadResult = readRole(of: elementUnderPoint)
        guard let elementRole = roleReadResult.role else {
            return roleReadResult.timedOut ? .timedOut : .noElement
        }

        // The deepest element under a point is often the label or icon inside a button or link.
        // Its own frame is only the words or the picture (a long line of text can pass the size
        // limit and pull the cursor far from the word the model meant), so the snap uses the
        // control around it, and refuses when there is none.
        var elementToMeasure = elementUnderPoint
        var roleToDecideOn = elementRole
        if ClickyPointSnap.leafRolesThatSnapOnlyThroughAControlParent.contains(elementRole),
           let parentElement = readParent(of: elementUnderPoint) {
            let parentRoleReadResult = readRole(of: parentElement)
            if let parentRole = parentRoleReadResult.role,
               ClickyPointSnap.controlRolesALeafMaySnapTo.contains(parentRole) {
                elementToMeasure = parentElement
                roleToDecideOn = parentRole
            }
        }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(elementToMeasure, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(elementToMeasure, kAXSizeAttribute as CFString, &sizeValue)
        guard positionResult == .success, sizeResult == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return positionResult == .cannotComplete || sizeResult == .cannotComplete ? .timedOut : .noElement
        }
        var elementPosition = CGPoint.zero
        var elementSize = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &elementPosition),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &elementSize) else {
            return .noElement
        }

        return .found(ClickyAccessibilityElementFacts(
            role: roleToDecideOn,
            frameInGlobalTopLeftPoints: CGRect(origin: elementPosition, size: elementSize),
            processIdentifier: processIdentifier
        ))
    }

    /// The process of the frontmost on-screen window that contains the point and is not Clicky's.
    /// The window list is front to back and uses the same coordinates as Accessibility (points from
    /// the top-left corner of the primary display). Only window bounds, owner process and alpha are
    /// read, never window titles.
    private static func processIdentifierOfTopmostWindowNotOwnedByClicky(
        containingGlobalTopLeftPoint globalTopLeftPoint: CGPoint,
        ownProcessIdentifier: pid_t
    ) -> pid_t? {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for windowInfo in windowInfoList {
            guard let ownerProcessIdentifier = (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerProcessIdentifier != ownProcessIdentifier else {
                continue
            }
            let windowAlpha = (windowInfo[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard windowAlpha >= minimumVisibleWindowAlpha else {
                continue
            }
            guard let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let windowBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  windowBounds.contains(globalTopLeftPoint) else {
                continue
            }
            return ownerProcessIdentifier
        }
        return nil
    }

    private static func readRole(of element: AXUIElement) -> (role: String?, timedOut: Bool) {
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        guard roleResult == .success, let role = roleValue as? String else {
            return (nil, roleResult == .cannotComplete)
        }
        return (role, false)
    }

    private static func readParent(of element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
              let parentValue,
              CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let parentElement = parentValue as! AXUIElement
        AXUIElementSetMessagingTimeout(parentElement, messagingTimeoutSeconds)
        return parentElement
    }
}
