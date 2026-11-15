import CoreGraphics
import Foundation

// Round 21 (explaining on screen): sharper pointing. The model names a place in a scaled-down
// screenshot, so on a small button its point often lands a few points beside it. When the
// Accessibility element under that point is a small control (a button, a field, a tab), the blue
// cursor flies to the element's centre instead. These are the pure rules; the read itself is
// `ClickyAccessibilityElementReader` (app), which takes only the element's role, frame and process.

/// What happened to a `[POINT:]` target. Fixed identifiers only: this is all the metrics line holds.
nonisolated enum ClickyPointSnapOutcome: String, CaseIterable, Equatable, Sendable {
    /// The point moved to the centre of the element under it.
    case snapped
    /// No element answered at the point (or its frame could not be read).
    case noElement
    /// The element is larger than a control (a list, a text area, a web page section).
    case elementTooLarge
    /// The point is not on the element (beyond the tolerance), or the centre is too far to move to.
    case pointOutsideElement
    /// The element belongs to Clicky itself (its own overlay or panel). Rare since the reader skips
    /// Clicky's windows and asks only the app under them.
    case ownWindow
    /// The element is a container (a window, a group, a scroll area...), whose centre means nothing.
    case roleNotSnappable
    /// Clicky has no Accessibility permission, so nothing was read.
    case noPermission
    /// The app under the point did not answer in time.
    case timedOut
    /// The read was not tried (no display to convert the point for).
    case notAttempted
}

nonisolated enum ClickyPointSnapDecision: Equatable {
    case snapped(to: CGPoint, distance: Double)
    case notSnapped(reason: ClickyPointSnapOutcome)
}

nonisolated enum ClickyPointSnap {
    /// A control is at most this big. Anything larger (a list, an editor, a page) has no single
    /// place to click, so its centre would be a worse target than the model's own point.
    static let maximumSnappableElementSize = CGSize(width: 200, height: 80)
    /// The model's point may be this far outside the element's frame and still count as on it.
    static let pointTolerancePoints: Double = 6
    /// The cursor never moves further than this from where the model pointed.
    static let maximumSnapDistancePoints: Double = 60

    /// The roles of containers. Their frame is a region, not a thing to click.
    static let rolesThatAreNotSnappable: Set<String> = [
        "AXWindow", "AXApplication", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXWebArea", "AXLayoutArea",
        "AXToolbar", "AXTabGroup", "AXOutline", "AXTable", "AXList", "AXSheet", "AXDrawer", "AXUnknown",
    ]

    /// The label, icon or cell inside a control. Its own frame is only the words or the picture (a
    /// line of text can be 190 points wide), so the reader snaps to the control around it instead
    /// (`controlRolesALeafMaySnapTo`); with no such control it is not snapped at all.
    static let leafRolesThatSnapOnlyThroughAControlParent: Set<String> = ["AXStaticText", "AXImage", "AXCell"]

    /// The controls a label, icon or cell may hand the snap to.
    static let controlRolesALeafMaySnapTo: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXMenuBarItem", "AXPopUpButton",
        "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXComboBox",
    ]

    /// Whether the cursor should fly to the centre of the element under the model's point. All
    /// geometry is in display points from the display's top-left corner.
    static func decide(
        modelPointInDisplayPoints: CGPoint,
        elementFrameInDisplayPoints: CGRect,
        elementRole: String,
        elementBelongsToClicky: Bool
    ) -> ClickyPointSnapDecision {
        if elementBelongsToClicky {
            return .notSnapped(reason: .ownWindow)
        }
        let trimmedRole = elementRole.trimmingCharacters(in: .whitespacesAndNewlines)
        // A label, icon or cell reaches here only when the reader found no control around it.
        if trimmedRole.isEmpty
            || rolesThatAreNotSnappable.contains(trimmedRole)
            || leafRolesThatSnapOnlyThroughAControlParent.contains(trimmedRole) {
            return .notSnapped(reason: .roleNotSnappable)
        }
        // The size as stored (CGRect's own width and height are always made positive), so a frame
        // of no size, or of a negative or impossible one, is caught here.
        let elementWidth = Double(elementFrameInDisplayPoints.size.width)
        let elementHeight = Double(elementFrameInDisplayPoints.size.height)
        guard elementWidth.isFinite, elementHeight.isFinite, elementWidth > 0, elementHeight > 0,
              Double(elementFrameInDisplayPoints.origin.x).isFinite, Double(elementFrameInDisplayPoints.origin.y).isFinite else {
            return .notSnapped(reason: .noElement)
        }
        if elementWidth > Double(maximumSnappableElementSize.width) || elementHeight > Double(maximumSnappableElementSize.height) {
            return .notSnapped(reason: .elementTooLarge)
        }
        // On the element, or within the tolerance of any of its four edges (the edges included).
        let modelX = Double(modelPointInDisplayPoints.x)
        let modelY = Double(modelPointInDisplayPoints.y)
        let pointIsOnTheElement = modelX >= Double(elementFrameInDisplayPoints.minX) - pointTolerancePoints
            && modelX <= Double(elementFrameInDisplayPoints.maxX) + pointTolerancePoints
            && modelY >= Double(elementFrameInDisplayPoints.minY) - pointTolerancePoints
            && modelY <= Double(elementFrameInDisplayPoints.maxY) + pointTolerancePoints
        guard pointIsOnTheElement else {
            return .notSnapped(reason: .pointOutsideElement)
        }
        let elementCentre = CGPoint(x: elementFrameInDisplayPoints.midX, y: elementFrameInDisplayPoints.midY)
        let moveDistance = Double(hypot(elementCentre.x - modelPointInDisplayPoints.x, elementCentre.y - modelPointInDisplayPoints.y))
        guard moveDistance <= maximumSnapDistancePoints else {
            return .notSnapped(reason: .pointOutsideElement)
        }
        return .snapped(to: elementCentre, distance: moveDistance)
    }
}

/// Converting between a display's own points (from its top-left corner, as the screenshot mapping
/// gives them) and Accessibility's global points (from the top-left corner of the primary display,
/// y growing downwards). AppKit's display frames start at the primary display's bottom-left corner
/// with y growing upwards, so the top edge of a display is `primaryScreenHeight - displayFrame.maxY`
/// in Accessibility's space.
nonisolated enum ClickyAccessibilityCoordinates {
    static func globalTopLeftPoint(forDisplayLocalPoint displayLocalPoint: CGPoint, displayFrame: CGRect, primaryScreenHeight: Double) -> CGPoint {
        CGPoint(
            x: Double(displayFrame.origin.x) + Double(displayLocalPoint.x),
            y: primaryScreenHeight - Double(displayFrame.maxY) + Double(displayLocalPoint.y)
        )
    }

    static func displayLocalPoint(forGlobalTopLeftPoint globalTopLeftPoint: CGPoint, displayFrame: CGRect, primaryScreenHeight: Double) -> CGPoint {
        CGPoint(
            x: Double(globalTopLeftPoint.x) - Double(displayFrame.origin.x),
            y: Double(globalTopLeftPoint.y) - (primaryScreenHeight - Double(displayFrame.maxY))
        )
    }

    static func displayLocalFrame(forGlobalTopLeftFrame globalTopLeftFrame: CGRect, displayFrame: CGRect, primaryScreenHeight: Double) -> CGRect {
        CGRect(
            origin: displayLocalPoint(forGlobalTopLeftPoint: globalTopLeftFrame.origin, displayFrame: displayFrame, primaryScreenHeight: primaryScreenHeight),
            size: globalTopLeftFrame.size
        )
    }
}
