import CoreGraphics
import Foundation

// Round 21 review: a spotlight lays a shade over the whole display. The overlay that holds it sits
// above Clicky's own chat panel and status pill (the overlay is at the screen saver level, those
// two at the status bar level), so the shade darkened them too: a typed "spotlight the run button"
// put the reply under it. Their frames are now cut out of the shade as extra holes. These are the
// pure parts (Foundation and CoreGraphics only): where those windows are on one display, and the
// shade's path. The layer itself is built by `ClickyDrawingMarkLayerBuilder.makeSpotlightLayer`.

nonisolated enum ClickySpotlightShade {
    /// The frames of Clicky's own windows on one display, measured from the display's top-left
    /// corner (the way a mark's shape is given), each clipped to the display. The window frames are
    /// AppKit's global frames (from the primary display's bottom-left corner, y growing upwards), as
    /// `NSWindow.frame` and the display frames are. A window on another display, or one of no size,
    /// gives nothing.
    static func cutOutFramesFromTopLeft(forWindowFramesInGlobalPoints windowFramesInGlobalPoints: [CGRect], displayFrame: CGRect) -> [CGRect] {
        windowFramesInGlobalPoints.compactMap { windowFrame in
            let partOfTheWindowOnTheDisplay = windowFrame.intersection(displayFrame)
            guard !partOfTheWindowOnTheDisplay.isNull,
                  partOfTheWindowOnTheDisplay.width > 0,
                  partOfTheWindowOnTheDisplay.height > 0 else {
                return nil
            }
            return CGRect(
                x: partOfTheWindowOnTheDisplay.minX - displayFrame.minX,
                y: displayFrame.maxY - partOfTheWindowOnTheDisplay.maxY,
                width: partOfTheWindowOnTheDisplay.width,
                height: partOfTheWindowOnTheDisplay.height
            )
        }
    }

    /// The spotlight's circle in the spotlight layer's own coordinates. The layer is the size of the
    /// display and its y grows upwards, while the centre is measured from the display's top-left
    /// corner.
    static func holeFrameInLayer(center: ClickyDrawingPoint, radius: Double, displaySizeInPoints: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(center.x - radius),
            y: displaySizeInPoints.height - CGFloat(center.y + radius),
            width: CGFloat(2 * radius),
            height: CGFloat(2 * radius)
        )
    }

    /// The shade's path in the layer's own coordinates, to be filled with the even-odd rule: the
    /// display's rectangle with the circle as a second subpath (so the circle is a hole), and the
    /// cut-outs (from the display's top-left corner) as extra holes. With no cut-out it is exactly the
    /// two subpaths round 21 drew.
    ///
    /// A cut-out is added only where it lies outside the circle, and cut-outs that overlap are joined
    /// first. With the even-odd rule a place inside two holes is covered three times, which fills it
    /// again: a panel over part of the circle would otherwise have shown a dark patch exactly where
    /// the light is. (The joining and subtracting use CoreGraphics' path operations, macOS 14 and
    /// later; the app needs 14.2.)
    static func shadePath(displaySizeInPoints: CGSize, center: ClickyDrawingPoint, radius: Double, cutOutFramesFromTopLeft: [CGRect]) -> CGPath {
        let holeFrame = holeFrameInLayer(center: center, radius: radius, displaySizeInPoints: displaySizeInPoints)
        let shadePath = CGMutablePath()
        shadePath.addRect(CGRect(origin: .zero, size: displaySizeInPoints))
        shadePath.addEllipse(in: holeFrame)

        let cutOutFramesInLayer = cutOutFramesFromTopLeft
            .filter { cutOutFrame in !cutOutFrame.isNull && cutOutFrame.width > 0 && cutOutFrame.height > 0 }
            .map { cutOutFrame in
                CGRect(
                    x: cutOutFrame.minX,
                    y: displaySizeInPoints.height - cutOutFrame.maxY,
                    width: cutOutFrame.width,
                    height: cutOutFrame.height
                )
            }
        guard let firstCutOutFrame = cutOutFramesInLayer.first else {
            return shadePath
        }
        var joinedCutOuts = CGPath(rect: firstCutOutFrame, transform: nil)
        for cutOutFrame in cutOutFramesInLayer.dropFirst() {
            joinedCutOuts = joinedCutOuts.union(CGPath(rect: cutOutFrame, transform: nil))
        }
        let cutOutsOutsideTheCircle = joinedCutOuts.subtracting(CGPath(ellipseIn: holeFrame, transform: nil))
        shadePath.addPath(cutOutsOutsideTheCircle)
        return shadePath
    }
}
