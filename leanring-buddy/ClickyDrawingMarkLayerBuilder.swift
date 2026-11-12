//
//  ClickyDrawingMarkLayerBuilder.swift
//  leanring-buddy
//
//  Turns one drawing mark into Core Animation layers: wobbly ink strokes that are revealed along
//  their length with a small pen tip leading them, label pills, and sticky note cards in a
//  handwriting typeface. All movement is Core Animation; nothing here is redrawn per frame by SwiftUI.
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

    /// The pen tip that leads a stroke: filled with the stroke's own colour, with a thin light
    /// edge so it stands out from the line it has just drawn. Its shape and lean are in
    /// `ClickyDrawingPenPath`.
    static let penTipEdgeLineWidthInPoints: CGFloat = 1.25
    /// The pen lifts off the page (fades) this fast once the last stroke of its mark is done.
    static let penTipFadeOutSeconds: Double = 0.15

    static let labelHorizontalPaddingInPoints: CGFloat = 10
    static let labelVerticalPaddingInPoints: CGFloat = 5
    static let labelBorderWidthInPoints: CGFloat = 1.5
    static let labelBackgroundOpacity: CGFloat = 0.94

    static let stickyNoteWidthInPoints: CGFloat = 200
    static let stickyNotePaddingInPoints: CGFloat = 12
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
    /// The mark layer remembers its pen tip layer and the legs of the pen's journey (each a path
    /// with its start and end share of the pen time), so the appearance animation can move the
    /// pen without building the strokes a second time.
    private static let penTipLayerKey = "clickyPenTipLayer"
    private static let penTipJourneyLegsKey = "clickyPenTipJourneyLegs"
    private static let penTipMoveAnimationKey = "clickyPenTipMove"
    private static let penTipVisibilityAnimationKey = "clickyPenTipVisibility"

    /// One leg of the pen's journey, ready for Core Animation: the path is in the mark layer's
    /// own coordinates. A class so it can be stored on a layer by key.
    private final class PenTipJourneyLeg: NSObject {
        let pathInMarkLayer: CGPath
        let startShareOfPenTime: Double
        let endShareOfPenTime: Double

        init(pathInMarkLayer: CGPath, startShareOfPenTime: Double, endShareOfPenTime: Double) {
            self.pathInMarkLayer = pathInMarkLayer
            self.startShareOfPenTime = startShareOfPenTime
            self.endShareOfPenTime = endShareOfPenTime
        }
    }

    /// How the ink of a mark looks. Marks on the screen use `screenMarkInkLook`; the small boxes
    /// and arrows on an explanation card and the leader line of a callout pass a finer one.
    struct InkLook {
        var firstPassLineWidthInPoints: CGFloat
        var secondPassLineWidthInPoints: CGFloat
        /// The soft dark shadow that keeps ink visible on any page. Ink on the card's own paper
        /// does not need it.
        var castsShadow: Bool
        var inkColor: CGColor
        /// Parts of the mark drawn in another colour than `inkColor`, by part index.
        var inkColorsByPartIndex: [Int: CGColor] = [:]
        /// The colour of the pen tip that leads the strokes.
        var penTipFillColor: CGColor
    }

    static var screenMarkInkLook: InkLook {
        InkLook(
            firstPassLineWidthInPoints: firstPassInkLineWidthInPoints,
            secondPassLineWidthInPoints: secondPassInkLineWidthInPoints,
            castsShadow: true,
            inkColor: NSColor(DS.Colors.overlayDrawingInk).cgColor,
            penTipFillColor: NSColor(DS.Colors.overlayDrawingInk).cgColor
        )
    }

    // MARK: - Handwriting typeface for drawn text

    /// The typeface chosen for labels and sticky notes on this Mac, looked up once: the first
    /// handwriting-style face that is installed (see `ClickyDrawingHandwritingFontChoice`), or
    /// nil when there is none and the rounded system font is used. Nothing is bundled.
    static let handwritingFontChoice: ClickyDrawingHandwritingFontChoice? = {
        ClickyDrawingHandwritingFontChoice.firstAvailableChoice { fontFamilyName in
            NSFontManager.shared.availableMembers(ofFontFamily: fontFamilyName)?.isEmpty == false
        }
    }()

    /// The name of the typeface drawn text uses on this Mac, for the console and the reports.
    static var drawnTextFontDescription: String {
        handwritingFontChoice?.fontFamilyName ?? "rounded system font (no handwriting typeface installed)"
    }

    static var labelFont: NSFont {
        drawnTextFont(
            handwritingFontSizeInPoints: handwritingFontChoice?.labelFontSizeInPoints,
            fallbackSystemFontWeight: .semibold
        )
    }

    static var stickyNoteFont: NSFont {
        drawnTextFont(
            handwritingFontSizeInPoints: handwritingFontChoice?.stickyNoteFontSizeInPoints,
            fallbackSystemFontWeight: .medium
        )
    }

    private static func drawnTextFont(handwritingFontSizeInPoints: Double?, fallbackSystemFontWeight: NSFont.Weight) -> NSFont {
        let fallbackFont = roundedSystemFont(
            ofSize: CGFloat(ClickyDrawingHandwritingFontChoice.fallbackSystemFontSizeInPoints),
            weight: fallbackSystemFontWeight
        )
        guard let handwritingFontChoice, let handwritingFontSizeInPoints else {
            return fallbackFont
        }
        // Weight 5 is the font manager's "regular". A family that only ships a bold face (Bradley
        // Hand) answers with that face, which is the one wanted: it stays readable at small sizes.
        return NSFontManager.shared.font(
            withFamily: handwritingFontChoice.fontFamilyName,
            traits: [],
            weight: 5,
            size: CGFloat(handwritingFontSizeInPoints)
        ) ?? fallbackFont
    }

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
        case .callout, .explanationCard, .scene:
            // The app decides where these go, so they need more than a shape to be built. The
            // overlay controller builds them with `ClickyExplanationCardLayerBuilder` (and a 3D
            // scene as a `ClickyScenePanelView`, which is a view and not a layer).
            return CALayer()
        }
    }

    /// One layer just large enough for the strokes (so its shadow is cheap to draw), holding one
    /// shape layer per stroke.
    ///
    /// The strokes' points are measured from the top-left corner of an area `displaySizeInPoints`
    /// large (the display for a mark on the screen), and the layer is placed for a parent layer
    /// that covers that area.
    static func makeInkLayer(
        for handDrawnStrokes: [ClickyHandDrawnStroke],
        displaySizeInPoints: CGSize,
        backingScaleFactor: CGFloat,
        inkLook customInkLook: InkLook? = nil
    ) -> CALayer {
        // nil means the look of a mark on the screen. (A default value in the parameter list
        // cannot read a main-actor property, so it is filled in here.)
        let inkLook = customInkLook ?? screenMarkInkLook
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
        if !isHighlighterMark && inkLook.castsShadow {
            markLayer.shadowColor = NSColor.black.cgColor
            markLayer.shadowOpacity = inkShadowOpacity
            markLayer.shadowRadius = inkShadowRadiusInPoints
            // Negative is downwards, because the layer's own coordinates grow upwards.
            markLayer.shadowOffset = CGSize(width: 0, height: -inkShadowVerticalOffsetInPoints)
        }

        // The parts of a mark are drawn one after the other (an arrow's shaft, then its head).
        // Each part gets a share of the pen time in proportion to its length. The pen tip uses
        // the same shares, so it stays on the end of the line being revealed.
        let timeSharesByPartIndex = ClickyDrawingPenPath.timeSharesByPartIndex(forStrokes: handDrawnStrokes)

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
                strokeLayer.strokeColor = inkLook.inkColorsByPartIndex[handDrawnStroke.partIndex] ?? inkLook.inkColor
                strokeLayer.lineWidth = isSecondPass ? inkLook.secondPassLineWidthInPoints : inkLook.firstPassLineWidthInPoints
                strokeLayer.opacity = isSecondPass ? secondPassInkOpacity : firstPassInkOpacity
            }

            let partTimeShares = timeSharesByPartIndex[handDrawnStroke.partIndex] ?? (startShareOfPenTime: 0, endShareOfPenTime: 1)
            let partShareOfPenTime = partTimeShares.endShareOfPenTime - partTimeShares.startShareOfPenTime
            let revealStartShareOfPenTime = partTimeShares.startShareOfPenTime
                + (isSecondPass ? secondPassStartShareOfPenTime * partShareOfPenTime : 0)
            let revealEndShareOfPenTime = partTimeShares.endShareOfPenTime
            strokeLayer.setValue(revealStartShareOfPenTime, forKey: revealStartShareLayerKey)
            strokeLayer.setValue(revealEndShareOfPenTime, forKey: revealEndShareLayerKey)

            markLayer.addSublayer(strokeLayer)
        }

        addPenTip(
            to: markLayer,
            following: ClickyDrawingPenPath.parts(forStrokes: handDrawnStrokes),
            markFrameFromTopLeft: markFrameFromTopLeft,
            penTipFillColor: isHighlighterMark
                ? NSColor(DS.Colors.overlayDrawingHighlighter).cgColor
                : inkLook.penTipFillColor,
            backingScaleFactor: backingScaleFactor
        )

        return markLayer
    }

    /// Adds the pen tip that leads the strokes of a mark while they are revealed. It is one small
    /// layer on top of the strokes, invisible until `animateAppearance` moves it along the legs
    /// of its journey, and invisible again once the mark is drawn.
    private static func addPenTip(
        to markLayer: CALayer,
        following penPathParts: [ClickyDrawingPenPathPart],
        markFrameFromTopLeft: CGRect,
        penTipFillColor: CGColor,
        backingScaleFactor: CGFloat
    ) {
        let penTipJourneyLegs = penPathParts.map { penPathPart in
            PenTipJourneyLeg(
                // The very same smooth path the first pass of the stroke is drawn with, so the
                // tip travels on the ink and not beside it.
                pathInMarkLayer: smoothPath(through: penPathPart.points, insideMarkFrameFromTopLeft: markFrameFromTopLeft),
                startShareOfPenTime: penPathPart.startShareOfPenTime,
                endShareOfPenTime: penPathPart.endShareOfPenTime
            )
        }
        guard let lastPenTipJourneyLeg = penTipJourneyLegs.last else {
            return
        }

        // A plain layer of no size whose position is the point of the nib. The nib is drawn by a
        // shape layer inside it. Keeping the shape one level down means the code that looks for a
        // mark's stroke layers (the shape layers directly inside the mark layer) never mistakes
        // the pen for a stroke.
        let penTipLayer = CALayer()
        penTipLayer.bounds = .zero
        penTipLayer.position = lastPenTipJourneyLeg.pathInMarkLayer.currentPoint
        // Hidden unless the appearance animation is showing it.
        penTipLayer.opacity = 0

        let nibOutlinePath = CGMutablePath()
        for (outlinePointIndex, nibOutlinePoint) in ClickyDrawingPenPath.nibOutlinePoints().enumerated() {
            // The outline is given with y growing downwards; a layer's y grows upwards.
            let nibOutlinePointInLayer = CGPoint(x: CGFloat(nibOutlinePoint.x), y: -CGFloat(nibOutlinePoint.y))
            if outlinePointIndex == 0 {
                nibOutlinePath.move(to: nibOutlinePointInLayer)
            } else {
                nibOutlinePath.addLine(to: nibOutlinePointInLayer)
            }
        }
        nibOutlinePath.closeSubpath()

        let nibShapeLayer = CAShapeLayer()
        nibShapeLayer.path = nibOutlinePath
        nibShapeLayer.fillColor = penTipFillColor
        nibShapeLayer.strokeColor = NSColor(DS.Colors.overlayDrawingPenEdge).cgColor
        nibShapeLayer.lineWidth = penTipEdgeLineWidthInPoints
        nibShapeLayer.lineJoin = .round
        nibShapeLayer.contentsScale = backingScaleFactor
        penTipLayer.addSublayer(nibShapeLayer)

        markLayer.addSublayer(penTipLayer)
        markLayer.setValue(penTipLayer, forKey: penTipLayerKey)
        markLayer.setValue(penTipJourneyLegs, forKey: penTipJourneyLegsKey)
    }

    private static func makeLabelLayer(
        text: String,
        topLeftCorner: ClickyDrawingPoint,
        displaySizeInPoints: CGSize,
        backingScaleFactor: CGFloat
    ) -> CALayer {
        let attributedLabelText = NSAttributedString(string: text, attributes: [
            .font: labelFont,
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
            .font: stickyNoteFont,
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

        animatePenTip(of: markLayer, penDurationSeconds: penDurationSeconds)
    }

    /// Moves the pen tip along the legs of its journey in step with the strokes being revealed,
    /// then lets it fade.
    private static func animatePenTip(of markLayer: CALayer, penDurationSeconds: Double) {
        guard let penTipLayer = markLayer.value(forKey: penTipLayerKey) as? CALayer,
              let penTipJourneyLegs = markLayer.value(forKey: penTipJourneyLegsKey) as? [PenTipJourneyLeg],
              !penTipJourneyLegs.isEmpty else {
            return
        }

        // One movement per leg, each with the start time, duration and easing of the stroke
        // reveal it follows. "Paced" moves the tip at an even speed along the path's length,
        // which is how `strokeEnd` uncovers a stroke, so with the same easing the tip stays on
        // the end of the line. The legs are grouped so they share one clock.
        var legMoveAnimations: [CAAnimation] = []
        var latestLegEndSeconds = 0.0
        for penTipJourneyLeg in penTipJourneyLegs {
            let legMoveAnimation = CAKeyframeAnimation(keyPath: "position")
            legMoveAnimation.path = penTipJourneyLeg.pathInMarkLayer
            legMoveAnimation.calculationMode = .paced
            legMoveAnimation.beginTime = penTipJourneyLeg.startShareOfPenTime * penDurationSeconds
            legMoveAnimation.duration = max(
                0.05,
                (penTipJourneyLeg.endShareOfPenTime - penTipJourneyLeg.startShareOfPenTime) * penDurationSeconds
            )
            legMoveAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // "forwards" keeps the tip at the end of a leg until the next leg takes over, so it
            // never jumps back to its resting place for a frame in between.
            legMoveAnimation.fillMode = .forwards
            legMoveAnimations.append(legMoveAnimation)
            latestLegEndSeconds = max(latestLegEndSeconds, legMoveAnimation.beginTime + legMoveAnimation.duration)
        }

        let secondsPenTipIsOnScreen = latestLegEndSeconds + penTipFadeOutSeconds
        let animationStartTime = penTipLayer.convertTime(CACurrentMediaTime(), from: nil)

        let penTipMoveAnimationGroup = CAAnimationGroup()
        penTipMoveAnimationGroup.animations = legMoveAnimations
        penTipMoveAnimationGroup.beginTime = animationStartTime
        penTipMoveAnimationGroup.duration = secondsPenTipIsOnScreen
        penTipLayer.add(penTipMoveAnimationGroup, forKey: penTipMoveAnimationKey)

        // Fully visible while drawing, then faded out. The layer's own opacity is 0, so when the
        // animation is over the pen stays hidden without any further work.
        let penTipVisibilityAnimation = CAKeyframeAnimation(keyPath: "opacity")
        penTipVisibilityAnimation.values = [1, 1, 0]
        penTipVisibilityAnimation.keyTimes = [0, NSNumber(value: latestLegEndSeconds / secondsPenTipIsOnScreen), 1]
        penTipVisibilityAnimation.beginTime = animationStartTime
        penTipVisibilityAnimation.duration = secondsPenTipIsOnScreen
        penTipLayer.add(penTipVisibilityAnimation, forKey: penTipVisibilityAnimationKey)
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
    static func frameFromBottomLeft(forFrameFromTopLeft frameFromTopLeft: CGRect, displaySizeInPoints: CGSize) -> CGRect {
        CGRect(
            x: frameFromTopLeft.minX,
            y: displaySizeInPoints.height - frameFromTopLeft.maxY,
            width: frameFromTopLeft.width,
            height: frameFromTopLeft.height
        )
    }

    /// The system font in its rounded design: friendly, and nothing has to be bundled.
    static func roundedSystemFont(ofSize fontSize: CGFloat, weight: NSFont.Weight) -> NSFont {
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
