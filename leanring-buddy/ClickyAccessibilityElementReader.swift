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
//  Call it off the main thread (a detached task). Each message to an app waits at most a quarter
//  second for one that does not answer: the hit test, then one read of the role, position and size
//  together. That is at most about half a second, and about three quarters when the hit test lands
//  on Clicky's own window and is asked again of the app the user was in (round 21 review: the role,
//  position and size used to be three reads, so the worst case was a whole second).
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

    /// The element under `globalTopLeftPoint`. The hit test asks the whole system first, because the
    /// window on top at the point may belong to another app than the frontmost one. When the answer
    /// is an element of Clicky itself (its click-through overlay covers every screen, and its chat
    /// panel or status pill may be at the point), the same point is asked again of the app the user
    /// was in when the turn started (`frontmostApplicationProcessIdentifier`), which can only answer
    /// with its own elements (round 21 review). The process is still reported with the facts, so the
    /// snap decision keeps refusing an element of Clicky's own whatever happened here.
    static func elementUnderPoint(globalTopLeftPoint: CGPoint, frontmostApplicationProcessIdentifier: pid_t?) -> ClickyAccessibilityElementReadResult {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let systemWideElement = AXUIElementCreateSystemWide()
        // Process-wide: Apple's header (AXUIElement.h) says a timeout set on the system-wide element
        // is the global timeout of this whole process, not of this one call. So from the first snap on,
        // every Accessibility call in Clicky that sets no timeout of its own waits a quarter second
        // instead of the default six. That is accepted: the system-wide hit test can only get a short
        // wait this way, and the other reads in Clicky (`ClickyChatProjectContextReader`,
        // `ClickyDictationTextInserter`) set this same quarter second on every element they ask anyway.
        AXUIElementSetMessagingTimeout(systemWideElement, messagingTimeoutSeconds)

        var hitTestOutcome = elementHit(in: systemWideElement, at: globalTopLeftPoint)
        if case .hit(_, let hitProcessIdentifier) = hitTestOutcome,
           hitProcessIdentifier == ownProcessIdentifier,
           let frontmostApplicationProcessIdentifier,
           frontmostApplicationProcessIdentifier != ownProcessIdentifier {
            let frontmostApplicationElement = AXUIElementCreateApplication(frontmostApplicationProcessIdentifier)
            AXUIElementSetMessagingTimeout(frontmostApplicationElement, messagingTimeoutSeconds)
            hitTestOutcome = elementHit(in: frontmostApplicationElement, at: globalTopLeftPoint)
        }

        switch hitTestOutcome {
        case .failed(let hitTestError):
            return hitTestError == .cannotComplete ? .timedOut : .noElement
        case .hit(let elementUnderPoint, let processIdentifier):
            return roleAndFrame(of: elementUnderPoint, processIdentifier: processIdentifier)
        }
    }

    private enum ElementHitOutcome {
        case hit(element: AXUIElement, processIdentifier: pid_t)
        case failed(AXError)
    }

    /// One hit test, asked of the system-wide element or of one app's element, with the process of
    /// the element found. The element reference carries its process, so `AXUIElementGetPid` sends no
    /// message to the app.
    private static func elementHit(in hitTestElement: AXUIElement, at globalTopLeftPoint: CGPoint) -> ElementHitOutcome {
        var elementUnderPoint: AXUIElement?
        let hitTestResult = AXUIElementCopyElementAtPosition(
            hitTestElement,
            Float(globalTopLeftPoint.x),
            Float(globalTopLeftPoint.y),
            &elementUnderPoint
        )
        guard hitTestResult == .success, let elementUnderPoint else {
            return .failed(hitTestResult == .success ? .noValue : hitTestResult)
        }
        var processIdentifier: pid_t = 0
        let processIdentifierResult = AXUIElementGetPid(elementUnderPoint, &processIdentifier)
        guard processIdentifierResult == .success else {
            return .failed(processIdentifierResult)
        }
        return .hit(element: elementUnderPoint, processIdentifier: processIdentifier)
    }

    /// The element's role, position and size, asked in one message (round 21 review: three reads were
    /// three round trips to the app, each up to the timeout). With the stop-on-error option the call
    /// fails as a whole when one of them cannot be read; a slot that still comes back holding an error
    /// value fails the type checks below.
    private static func roleAndFrame(of element: AXUIElement, processIdentifier: pid_t) -> ClickyAccessibilityElementReadResult {
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        let attributeNames = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var attributeValues: CFArray?
        let readResult = AXUIElementCopyMultipleAttributeValues(element, attributeNames, .stopOnError, &attributeValues)
        let attributeValueList = (attributeValues as? [AnyObject]) ?? []
        guard readResult == .success, attributeValueList.count == 3,
              let role = attributeValueList[0] as? String,
              let elementPosition = cgPoint(from: attributeValueList[1]),
              let elementSize = cgSize(from: attributeValueList[2]) else {
            let anAppDidNotAnswer = readResult == .cannotComplete
                || attributeValueList.contains { attributeValue in errorHeld(in: attributeValue) == .cannotComplete }
            return anAppDidNotAnswer ? .timedOut : .noElement
        }
        return .found(ClickyAccessibilityElementFacts(
            role: role,
            frameInGlobalTopLeftPoints: CGRect(origin: elementPosition, size: elementSize),
            processIdentifier: processIdentifier
        ))
    }

    private static func cgPoint(from attributeValue: AnyObject) -> CGPoint? {
        guard CFGetTypeID(attributeValue) == AXValueGetTypeID() else { return nil }
        let axValue = attributeValue as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func cgSize(from attributeValue: AnyObject) -> CGSize? {
        guard CFGetTypeID(attributeValue) == AXValueGetTypeID() else { return nil }
        let axValue = attributeValue as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// The error a slot holds when its attribute could not be read: the header says such a slot is an
    /// AXValue of the error type.
    private static func errorHeld(in attributeValue: AnyObject) -> AXError? {
        guard CFGetTypeID(attributeValue) == AXValueGetTypeID() else { return nil }
        let axValue = attributeValue as! AXValue
        // Read as the plain 32-bit number the error is, then made an AXError, so an error code this
        // SDK does not name cannot become an invalid value.
        var heldErrorCode: Int32 = 0
        guard AXValueGetType(axValue) == .axError, AXValueGetValue(axValue, .axError, &heldErrorCode) else { return nil }
        return AXError(rawValue: heldErrorCode)
    }
}
