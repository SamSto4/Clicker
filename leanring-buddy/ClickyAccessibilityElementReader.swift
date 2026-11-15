//
//  ClickyAccessibilityElementReader.swift
//  leanring-buddy
//
//  Round 21 (explaining on screen): asks Accessibility which element is under a point on the screen,
//  so `ClickyPointSnap` can move the blue cursor to the centre of a small button the model pointed
//  just beside. What is read from the other app: the element's role, its frame (position and size)
//  and the process it belongs to, of that one element. Never its title, value, children or any
//  other text. The role is only used for the snap decision; the metrics line holds the outcome word.
//
//  Call it off the main thread (a detached task): each read waits at most a quarter second for an
//  app that does not answer.
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

    static func elementUnderPoint(globalTopLeftPoint: CGPoint) -> ClickyAccessibilityElementReadResult {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, messagingTimeoutSeconds)
        var elementUnderPoint: AXUIElement?
        let hitTestResult = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(globalTopLeftPoint.x),
            Float(globalTopLeftPoint.y),
            &elementUnderPoint
        )
        guard hitTestResult == .success, let elementUnderPoint else {
            return hitTestResult == .cannotComplete ? .timedOut : .noElement
        }
        AXUIElementSetMessagingTimeout(elementUnderPoint, messagingTimeoutSeconds)

        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(elementUnderPoint, kAXRoleAttribute as CFString, &roleValue)
        guard roleResult == .success, let role = roleValue as? String else {
            return roleResult == .cannotComplete ? .timedOut : .noElement
        }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(elementUnderPoint, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(elementUnderPoint, kAXSizeAttribute as CFString, &sizeValue)
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

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(elementUnderPoint, &processIdentifier) == .success else {
            return .noElement
        }
        return .found(ClickyAccessibilityElementFacts(
            role: role,
            frameInGlobalTopLeftPoints: CGRect(origin: elementPosition, size: elementSize),
            processIdentifier: processIdentifier
        ))
    }
}
