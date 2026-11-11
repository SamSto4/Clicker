//
//  ClickyDrawingMarkLayerBuilder.swift
//  leanring-buddy
//
//  Turns one drawing mark into Core Animation layers: wobbly ink strokes that are revealed along
//  their length, label pills, and sticky note cards. All movement is Core Animation; nothing here
//  is redrawn per frame by SwiftUI.
//

import AppKit
import QuartzCore
import SwiftUI

@MainActor
enum ClickyDrawingMarkLayerBuilder {

    // MARK: - Look (our own design; every value is listed here so it can be tuned in one place)

    /// The first pass of the pen is the bold line; the second pass is thinner and fainter, so
    /// where the two do not line up the stroke looks gone over by hand.
    static let firstPassInkLineWidthInPoints: CGFloat = 3.5
    static let secondPassInkLineWidthInPoints: CGFloat = 2.25
    static let firstPassInkOpacity: Float = 0.95
    static let secondPassInkOpacity: Float = 0.6

    /// Each pass of the highlighter is this see-through, so text under the band stays readable
    /// and the overlap of the two passes is a little stronger, like a real marker.
    /// Raised from 0.22 after real use: two passes at 0.22 were nearly invisible over a white page,
    /// because a window layer cannot multiply-blend with the app underneath as real marker ink does.
    static let highlighterOpacityPerPass: Float = 0.36

    /// The second pass starts this far into the pen time, so it visibly follows the first.
    static let secondPassStartShareOfPenTime: Double = 0.12

    /// A soft dark shadow under the ink keeps a warm stroke visible on a warm or white page.
    static let inkShadowOpacity: Float = 0.35
    static let inkShadowRadiusInPoints: CGFloat = 2
    static let inkShadowVerticalOffsetInPoints: CGFloat = 1

    /// Room left around a mark's strokes inside its layer, for the line width and the shadow.
    static let inkLayerPaddingInPoints: CGFloat = 10

    static let labelFontSizeInPoints: CGFloat = 13
    static let labelHorizontalPaddingInPoints: CGFloat = 10
    static let labelVerticalPaddingInPoints: CGFloat = 5
    static let labelBorderWidthInPoints: CGFloat = 1.5
    static let labelBackgroundOpacity: CGFloat = 0.94

    static let stickyNoteWidthInPoints: CGFloat = 200
    static let stickyNotePaddingInPoints: CGFloat = 12
    static let stickyNoteFontSizeInPoints: CGFloat = 13
    static let stickyNoteCornerRadiusInPoints: CGFloat = 3
    /// A sticky note sits slightly crooked, as if stuck on by hand. The tilt is between minus and
    /// plus this many degrees, decided by the mark's seed so it never changes for a given note.
    static let stickyNoteMaximumTiltInDegrees: Double = 3
    static let stickyNoteShadowOpacity: Float = 0.3
    static let stickyNoteShadowRadiusInPoints: CGFloat = 7
    static let stickyNoteShadowVerticalOffsetInPoints: CGFloat = 3

    /// Labels and sticky notes are kept this far inside the screen edge so they are never cut off.
    static let textMarkScreenEdgeMarginInPoints: CGFloat = 6

    /// A label or sticky note grows from this scale to full size while it fades in.
    static let textMarkAppearStartScale: CGFloat = 0.9

    /// Core Animation layers accept extra values by key. Each stroke layer remembers when, as a
    /// share of the pen time, its reveal starts and ends.
    private static let revealStartShareLayerKey = "clickyRevealStartShareOfPenTime"
    private static let revealEndShareLayerKey = "clickyRevealEndShareOfPenTime"
    private static let penRevealAnimationKey = "clickyPenReveal"

    // MARK: - Building

    /// Builds the layer for one mark. `shapeInDisplayPoints` is the mark's shape already mapped to
    /// the display (points, origin top-left, like the screenshot). Core Animation on the Mac
    /// measures from the bottom-left corner, so every position is turned over here, once, using
    /// the display's height. The returned layer is placed for a surface that covers the display.
    static func makeMarkLayer(
        forMarkNumber markNumber: Int,
        shapeInDisplayPoints: ClickyDrawingShape,
        displaySizeInPoints: CGSize,
        backingScaleFactor: CGFloat
    ) -> CALayer {
        let wobbleSeed = ClickyHandDrawnPathGenerator.seed(forMarkNumber: markNumber)

        // Building layers must not start Core Animation's automatic fade-ins: the reveal is the
        // only animation a new mark should have.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch shapeInDisplayPoints {
        case .label(let topLeftCorner, let text):
            return makeLabelLayer(
                text: text,
                topLeftCorner: topLeftCorner,
                displaySizeInPoints: displaySizeInPoints,
                backingScaleFactor: backingScaleFactor
            )
        case .stickyNote(let topLeftCorner, let text):
            return makeStickyNoteLayer(
                text: text,
                topLeftCorner: topLeftCorner,
                wobbleSeed: wobbleSeed,
                displaySizeInPoints: displaySizeInPoints,
                backingScaleFactor: backingScaleFactor
            )
        case .arrow, .circle, .box, .underline, .highlight:
            let handDrawnStrokes = ClickyHandDrawnPathGenerator.strokes(
                forShapeInDisplayPoints: shapeInDisplayPoints,
                seed: wobbleSeed
            )
            return makeInkLayer(for: handDrawnStrokes, displaySizeInPoints: displaySizeInPoints, backingScaleFactor: backingScaleFactor)
        }
    }

    /// One layer just large enough for the strokes (so its shadow is cheap to draw), holding one
    /// shape layer per stroke.
    private static func makeInkLayer(for handDrawnStrokes: [ClickyHandDrawnStroke], displaySizeInPoints: CGSize, backingScaleFactor: CGFloat) -> CALayer {
        let markLayer = CALayer()

        let allStrokePoints = handDrawnStrokes.flatMap(\.points)
        guard let firstStrokePoint = allStrokePoints.first else {
            return markLayer
        }

        var smallestX = firstStrokePoint.x
        var largestX = firstStrokePoint.x
        var smallestY = firstStrokePoint.y
        var largestY = firstStrokePoint.y
        for strokePoint in allStrokePoints {
            smallestX = min(smallestX, strokePoint.x)
            largestX = max(largestX, strokePoint.x)
            smallestY = min(smallestY, strokePoint.y)
            largestY = max(largestY, strokePoint.y)
        }

        let widestHighlighterBandWidth = handDrawnStrokes.compactMap(\.highlighterBandWidthInPoints).max() ?? 0
        let isHighlighterMark = widestHighlighterBandWidth > 0
        let paddingAroundStrokes = inkLayerPaddingInPoints + CGFloat(widestHighlighterBandWidth) / 2
        let markFrameFromTopLeft = CGRect(
            x: CGFloat(smallestX) - paddingAroundStrokes,
            y: CGFloat(smallestY) - paddingAroundStrokes,
            width: CGFloat(largestX - smallestX) + 2 * paddingAroundStrokes,
            height: CGFloat(largestY - smallestY) + 2 * paddingAroundStrokes
        )
        markLayer.frame = frameFromBottomLeft(forFrameFromTopLeft: markFrameFromTopLeft, displaySizeInPoints: displaySizeInPoints)

        // A highlighter is see-through, so a shadow under it would only muddy the text.
        if !isHighlighterMark {
            markLayer.shadowColor = NSColor.black.cgColor
            markLayer.shadowOpacity = inkShadowOpacity
            markLayer.shadowRadius = inkShadowRadiusInPoints
            // Negative is downwards, because the layer's own coordinates grow upwards.
            markLayer.shadowOffset = CGSize(width: 0, height: -inkShadowVerticalOffsetInPoints)
        }

        // The parts of a mark are drawn one after the other (an arrow's shaft, then its head).
        // Each part gets a share of the pen time in proportion to its length.
        let firstPassStrokes = handDrawnStrokes.filter { $0.passIndex == 0 }
        let totalFirstPassLength = max(1, firstPassStrokes.reduce(0) { $0 + $1.lengthInPoints })
        var partStartShareOfPenTimeByPartIndex: [Int: Double] = [:]
        var partShareOfPenTimeByPartIndex: [Int: Double] = [:]
        var shareOfPenTimeUsedSoFar = 0.0
        for firstPassStroke in firstPassStrokes.sorted(by: { $0.partIndex < $1.partIndex }) {
            let partShareOfPenTime = firstPassStroke.lengthInPoints / totalFirstPassLength
            partStartShareOfPenTimeByPartIndex[firstPassStroke.partIndex] = shareOfPenTimeUsedSoFar
            partShareOfPenTimeByPartIndex[firstPassStroke.partIndex] = partShareOfPenTime
            shareOfPenTimeUsedSoFar += partShareOfPenTime
        }

        for handDrawnStroke in handDrawnStrokes {
            let strokeLayer = CAShapeLayer()
            strokeLayer.frame = markLayer.bounds
            strokeLayer.path = smoothPath(through: handDrawnStroke.points, insideMarkFrameFromTopLeft: markFrameFromTopLeft)
            strokeLayer.fillColor = nil
            // These layers are not managed by AppKit, so they do not pick up the screen's scale
            // by themselves. Without it the strokes would be drawn at half resolution on a
            // Retina display and look soft.
            strokeLayer.contentsScale = backingScaleFactor
            strokeLayer.lineCap = .round
            strokeLayer.lineJoin = .round

            let isSecondPass = handDrawnStroke.passIndex > 0
            if let highlighterBandWidthInPoints = handDrawnStroke.highlighterBandWidthInPoints {
                strokeLayer.strokeColor = NSColor(DS.Colors.overlayDrawingHighlighter).cgColor
                strokeLayer.lineWidth = CGFloat(highlighterBandWidthInPoints)
                strokeLayer.opacity = highlighterOpacityPerPass
            } else {
                strokeLayer.strokeColor = NSColor(DS.Colors.overlayDrawingInk).cgColor
                strokeLayer.lineWidth = isSecondPass ? secondPassInkLineWidthInPoints : firstPassInkLineWidthInPoints
                strokeLayer.opacity = isSecondPass ? secondPassInkOpacity : firstPassInkOpacity
            }

            let partStartShareOfPenTime = partStartShareOfPenTimeByPartIndex[handDrawnStroke.partIndex] ?? 0
            let partShareOfPenTime = partShareOfPenTimeByPartIndex[handDrawnStroke.partIndex] ?? 1
            let revealStartShareOfPenTime = partStartShareOfPenTime
                + (isSecondPass ? secondPassStartShareOfPenTime * partShareOfPenTime : 0)
            let revealEndShareOfPenTime = partStartShareOfPenTime + partShareOfPenTime
            strokeLayer.setValue(revealStartShareOfPenTime, forKey: revealStartShareLayerKey)
            strokeLayer.setValue(revealEndShareOfPenTime, forKey: revealEndShareLayerKey)

            markLayer.addSublayer(strokeLayer)
        }

        return markLayer
    }

    private static func makeLabelLayer(
        text: String,
        topLeftCorner: ClickyDrawingPoint,
        displaySizeInPoints: CGSize,
        backingScaleFactor: CGFloat
    ) -> CALayer {
        let attributedLabelText = NSAttributedString(string: text, attributes: [
            .font: roundedSystemFont(ofSize: labelFontSizeInPoints, weight: .semibold),
            .foregroundColor: NSColor(DS.Colors.overlayDrawingLabelText),
        ])
        let measuredTextSize = attributedLabelText.size()
        let textSize = CGSize(width: ceil(measuredTextSize.width), height: ceil(measuredTextSize.height))
        let pillSize = CGSize(
            width: textSize.width + 2 * labelHorizontalPaddingInPoints,
            height: textSize.height + 2 * labelVerticalPaddingInPoints
        )

        // The pill has its own dark background and an ink-coloured edge, so the words can be read
        // on any page and still clearly belong to the drawing.
        let pillLayer = CALayer()
        pillLayer.frame = frameFromBottomLeft(
            forFrameFromTopLeft: CGRect(
                origin: originKeptOnScreen(for: pillSize, wantedTopLeftCorner: topLeftCorner, displaySizeInPoints: displaySizeInPoints),
                size: pillSize
            ),
            displaySizeInPoints: displaySizeInPoints
        )
        pillLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingLabelBackground).withAlphaComponent(labelBackgroundOpacity).cgColor
        pillLayer.cornerRadius = pillSize.height / 2
        pillLayer.borderColor = NSColor(DS.Colors.overlayDrawingInk).cgColor
        pillLayer.borderWidth = labelBorderWidthInPoints

        let textLayer = CATextLayer()
        textLayer.string = attributedLabelText
        textLayer.frame = CGRect(
            x: labelHorizontalPaddingInPoints,
            y: labelVerticalPaddingInPoints,
            width: textSize.width,
            height: textSize.height
        )
        // Without the screen's scale the text would be drawn at one pixel per point and look blurry.
        textLayer.contentsScale = backingScaleFactor
        pillLayer.addSublayer(textLayer)

        return pillLayer
    }

    private static func makeStickyNoteLayer(
        text: String,
        topLeftCorner: ClickyDrawingPoint,
        wobbleSeed: UInt64,
        displaySizeInPoints: CGSize,
        backingScaleFactor: CGFloat
    ) -> CALayer {
        let attributedNoteText = NSAttributedString(string: text, attributes: [
            .font: roundedSystemFont(ofSize: stickyNoteFontSizeInPoints, weight: .medium),
            .foregroundColor: NSColor(DS.Colors.overlayDrawingStickyNoteText),
        ])
        let textWidth = stickyNoteWidthInPoints - 2 * stickyNotePaddingInPoints
        let measuredTextRect = attributedNoteText.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textHeight = ceil(measuredTextRect.height)
        let cardSize = CGSize(width: stickyNoteWidthInPoints, height: textHeight + 2 * stickyNotePaddingInPoints)

        let cardLayer = CALayer()
        cardLayer.frame = frameFromBottomLeft(
            forFrameFromTopLeft: CGRect(
                origin: originKeptOnScreen(for: cardSize, wantedTopLeftCorner: topLeftCorner, displaySizeInPoints: displaySizeInPoints),
                size: cardSize
            ),
            displaySizeInPoints: displaySizeInPoints
        )
        cardLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingStickyNotePaper).cgColor
        cardLayer.cornerRadius = stickyNoteCornerRadiusInPoints
        cardLayer.shadowColor = NSColor.black.cgColor
        cardLayer.shadowOpacity = stickyNoteShadowOpacity
        cardLayer.shadowRadius = stickyNoteShadowRadiusInPoints
        cardLayer.shadowOffset = CGSize(width: 0, height: -stickyNoteShadowVerticalOffsetInPoints)

        // The tilt comes from the mark's own seed, so a note keeps its tilt for as long as it lives.
        var tiltRandomNumberGenerator = ClickyDeterministicRandomNumberGenerator(seed: wobbleSeed)
        let tiltInDegrees = tiltRandomNumberGenerator.nextValue(
            between: -stickyNoteMaximumTiltInDegrees,
            and: stickyNoteMaximumTiltInDegrees
        )
        cardLayer.transform = CATransform3DMakeRotation(CGFloat(tiltInDegrees * Double.pi / 180), 0, 0, 1)

        let textLayer = CATextLayer()
        textLayer.string = attributedNoteText
        textLayer.isWrapped = true
        textLayer.alignmentMode = .left
        textLayer.frame = CGRect(
            x: stickyNotePaddingInPoints,
            y: stickyNotePaddingInPoints,
            width: textWidth,
            height: textHeight
        )
        textLayer.contentsScale = backingScaleFactor
        cardLayer.addSublayer(textLayer)

        return cardLayer
    }

    // MARK: - Animating

    /// Starts the appearance of a mark that has just been added to the screen: ink is revealed
    /// along each stroke as if the pen were moving; a label or sticky note fades and grows in.
    /// The layer must already be in the layer tree, because the start times are on its clock.
    static func animateAppearance(of markLayer: CALayer, penDurationSeconds: Double) {
        let strokeLayers = (markLayer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }

        guard !strokeLayers.isEmpty else {
            let fadeInAnimation = CABasicAnimation(keyPath: "opacity")
            fadeInAnimation.fromValue = 0
            fadeInAnimation.toValue = markLayer.opacity
            let growAnimation = CABasicAnimation(keyPath: "transform.scale")
            growAnimation.fromValue = textMarkAppearStartScale
            growAnimation.toValue = 1
            let appearAnimationGroup = CAAnimationGroup()
            appearAnimationGroup.animations = [fadeInAnimation, growAnimation]
            appearAnimationGroup.duration = penDurationSeconds
            appearAnimationGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
            markLayer.add(appearAnimationGroup, forKey: penRevealAnimationKey)
            return
        }

        for strokeLayer in strokeLayers {
            let revealStartShareOfPenTime = (strokeLayer.value(forKey: revealStartShareLayerKey) as? Double) ?? 0
            let revealEndShareOfPenTime = (strokeLayer.value(forKey: revealEndShareLayerKey) as? Double) ?? 1

            let penRevealAnimation = CABasicAnimation(keyPath: "strokeEnd")
            penRevealAnimation.fromValue = 0
            penRevealAnimation.toValue = 1
            penRevealAnimation.beginTime = strokeLayer.convertTime(CACurrentMediaTime(), from: nil)
                + revealStartShareOfPenTime * penDurationSeconds
            penRevealAnimation.duration = max(0.05, (revealEndShareOfPenTime - revealStartShareOfPenTime) * penDurationSeconds)
            // "backwards" keeps the stroke invisible until its own start time, so the head of an
            // arrow does not show before the shaft has reached it.
            penRevealAnimation.fillMode = .backwards
            penRevealAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            strokeLayer.add(penRevealAnimation, forKey: penRevealAnimationKey)
        }
    }

    /// Fades a mark out and takes its layer off the screen when the fade is done.
    static func fadeOutAndRemove(_ markLayer: CALayer, fadeOutSeconds: Double) {
        guard fadeOutSeconds > 0 else {
            markLayer.removeAllAnimations()
            markLayer.removeFromSuperlayer()
            return
        }

        // Start from what is on screen right now, which may be the middle of another animation.
        let opacityOnScreenNow = markLayer.presentation()?.opacity ?? markLayer.opacity

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            markLayer.removeFromSuperlayer()
        }
        let fadeOutAnimation = CABasicAnimation(keyPath: "opacity")
        fadeOutAnimation.fromValue = opacityOnScreenNow
        fadeOutAnimation.toValue = 0
        fadeOutAnimation.duration = fadeOutSeconds
        fadeOutAnimation.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.setDisableActions(true)
        markLayer.opacity = 0
        markLayer.add(fadeOutAnimation, forKey: "clickyFadeOut")
        CATransaction.commit()
    }

    // MARK: - Helpers

    /// A smooth path through the points: each point becomes the control point of a curve between
    /// the midpoints on either side of it, which rounds off the small kinks between samples.
    ///
    /// The stroke points are display points from the top-left corner. They are moved into the mark
    /// layer's own coordinates, which start at the layer's bottom-left corner.
    private static func smoothPath(through strokePoints: [ClickyDrawingPoint], insideMarkFrameFromTopLeft markFrameFromTopLeft: CGRect) -> CGPath {
        let path = CGMutablePath()
        let layerPoints = strokePoints.map { strokePoint in
            CGPoint(
                x: CGFloat(strokePoint.x) - markFrameFromTopLeft.minX,
                y: markFrameFromTopLeft.maxY - CGFloat(strokePoint.y)
            )
        }
        guard let firstLayerPoint = layerPoints.first else {
            return path
        }
        path.move(to: firstLayerPoint)
        guard layerPoints.count > 2 else {
            for laterLayerPoint in layerPoints.dropFirst() {
                path.addLine(to: laterLayerPoint)
            }
            return path
        }

        for pointIndex in 1..<(layerPoints.count - 1) {
            let controlPoint = layerPoints[pointIndex]
            let nextLayerPoint = layerPoints[pointIndex + 1]
            let midpointToNextPoint = CGPoint(
                x: (controlPoint.x + nextLayerPoint.x) / 2,
                y: (controlPoint.y + nextLayerPoint.y) / 2
            )
            path.addQuadCurve(to: midpointToNextPoint, control: controlPoint)
        }
        if let lastLayerPoint = layerPoints.last {
            path.addLine(to: lastLayerPoint)
        }
        return path
    }

    /// The same rectangle measured from the display's bottom-left corner, which is how Core
    /// Animation places layers on the Mac.
    private static func frameFromBottomLeft(forFrameFromTopLeft frameFromTopLeft: CGRect, displaySizeInPoints: CGSize) -> CGRect {
        CGRect(
            x: frameFromTopLeft.minX,
            y: displaySizeInPoints.height - frameFromTopLeft.maxY,
            width: frameFromTopLeft.width,
            height: frameFromTopLeft.height
        )
    }

    /// The system font in its rounded design: friendly, and nothing has to be bundled.
    private static func roundedSystemFont(ofSize fontSize: CGFloat, weight: NSFont.Weight) -> NSFont {
        let systemFont = NSFont.systemFont(ofSize: fontSize, weight: weight)
        guard let roundedFontDescriptor = systemFont.fontDescriptor.withDesign(.rounded) else {
            return systemFont
        }
        return NSFont(descriptor: roundedFontDescriptor, size: fontSize) ?? systemFont
    }

    /// Where to put a label or sticky note so all of it is on the screen: at the position that
    /// was asked for when it fits, otherwise moved in from the right or bottom edge.
    private static func originKeptOnScreen(
        for markSize: CGSize,
        wantedTopLeftCorner: ClickyDrawingPoint,
        displaySizeInPoints: CGSize
    ) -> CGPoint {
        let largestAllowedX = displaySizeInPoints.width - markSize.width - textMarkScreenEdgeMarginInPoints
        let largestAllowedY = displaySizeInPoints.height - markSize.height - textMarkScreenEdgeMarginInPoints
        return CGPoint(
            x: max(textMarkScreenEdgeMarginInPoints, min(CGFloat(wantedTopLeftCorner.x), largestAllowedX)),
            y: max(textMarkScreenEdgeMarginInPoints, min(CGFloat(wantedTopLeftCorner.y), largestAllowedY))
        )
    }
}
