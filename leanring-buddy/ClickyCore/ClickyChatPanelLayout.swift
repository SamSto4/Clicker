// CoreGraphics only for CGRect and CGSize, the types AppKit gives screen frames in. No AppKit here.
import CoreGraphics
import Foundation

/// The sizes the chat panel is laid out with. The values live in the design system
/// (`DS.ChatPanel`); they are handed in here so the placement maths can be tested without the app.
nonisolated struct ClickyChatPanelMetrics: Equatable {
    let widthInPoints: Double
    /// The panel grows with its content up to this height.
    let maximumHeightInPoints: Double
    let gapBelowMenuBarInPoints: Double
    /// Under a notch the panel starts this far inside the notch, so the two join with no seam.
    let notchOverlapInPoints: Double
    let screenEdgeMarginInPoints: Double
}

nonisolated struct ClickyChatPanelPlacement: Equatable {
    /// Where the panel goes, in global AppKit coordinates (origin bottom-left, y grows upwards).
    let frame: CGRect
    /// True when the panel hangs from a notch: its top is then flat and black and joins the notch.
    let hangsFromNotch: Bool
}

/// Where the chat panel goes on a screen. It reuses the status pill's notch geometry: with a
/// notch it hangs from the notch, centred on it; without one it sits just below the menu bar,
/// centred on the screen. It is moved or narrowed as needed to stay inside the screen.
nonisolated enum ClickyChatPanelLayout {
    /// The panel's height for content of the given height: never more than the maximum, and never
    /// more than fits on the screen below the menu bar or notch.
    static func panelHeight(
        forContentHeightInPoints contentHeightInPoints: Double,
        screenGeometry: ClickyStatusPillScreenGeometry,
        metrics: ClickyChatPanelMetrics
    ) -> Double {
        let topEdgeInset = screenGeometry.hasNotch
            ? screenGeometry.safeAreaTopInsetInPoints - metrics.notchOverlapInPoints
            : max(0, screenGeometry.menuBarHeightInPoints) + metrics.gapBelowMenuBarInPoints
        let tallestPanelThatFits = Double(screenGeometry.screenFrame.height) - topEdgeInset - metrics.screenEdgeMarginInPoints
        return max(0, min(contentHeightInPoints, metrics.maximumHeightInPoints, tallestPanelThatFits)).rounded(.up)
    }

    static func placement(
        forContentHeightInPoints contentHeightInPoints: Double,
        screenGeometry: ClickyStatusPillScreenGeometry,
        metrics: ClickyChatPanelMetrics
    ) -> ClickyChatPanelPlacement {
        let screenFrame = screenGeometry.screenFrame
        let screenEdgeMargin = CGFloat(metrics.screenEdgeMarginInPoints)

        let widestPanelThatFits = max(0, screenFrame.width - 2 * screenEdgeMargin)
        let panelWidth = min(CGFloat(metrics.widthInPoints), widestPanelThatFits)
        let panelHeight = CGFloat(panelHeight(
            forContentHeightInPoints: contentHeightInPoints,
            screenGeometry: screenGeometry,
            metrics: metrics
        ))

        let wantedCenterX: CGFloat
        let wantedTopY: CGFloat
        if screenGeometry.hasNotch {
            wantedCenterX = CGFloat(ClickyStatusPillLayout.notchCenterX(for: screenGeometry))
            wantedTopY = screenFrame.maxY - CGFloat(screenGeometry.safeAreaTopInsetInPoints) + CGFloat(metrics.notchOverlapInPoints)
        } else {
            wantedCenterX = screenFrame.midX
            wantedTopY = screenFrame.maxY - CGFloat(max(0, screenGeometry.menuBarHeightInPoints)) - CGFloat(metrics.gapBelowMenuBarInPoints)
        }

        let smallestAllowedX = screenFrame.minX + screenEdgeMargin
        let largestAllowedX = max(smallestAllowedX, screenFrame.maxX - screenEdgeMargin - panelWidth)
        let panelOriginX = max(smallestAllowedX, min(wantedCenterX - panelWidth / 2, largestAllowedX))

        // AppKit measures upwards, so the panel's origin is its bottom edge.
        let highestAllowedOriginY = screenFrame.maxY - panelHeight
        let panelOriginY = max(screenFrame.minY, min(wantedTopY - panelHeight, highestAllowedOriginY))

        return ClickyChatPanelPlacement(
            frame: CGRect(x: panelOriginX.rounded(), y: panelOriginY.rounded(), width: panelWidth, height: panelHeight),
            hangsFromNotch: screenGeometry.hasNotch
        )
    }
}
