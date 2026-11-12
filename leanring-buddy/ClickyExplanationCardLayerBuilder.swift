//
//  ClickyExplanationCardLayerBuilder.swift
//  leanring-buddy
//
//  Turns an explanation card (a cream paper panel with a title and rows of handwriting, boxes,
//  arrows and timelines) and a numbered callout into Core Animation layers. Where things go is
//  worked out by the pure layout code in ClickyCore; this file only measures words with the real
//  typeface, builds layers and starts their animations. The layers live in the existing drawing
//  surface, never inside a hosting view.
//

import AppKit
import QuartzCore
import SwiftUI

@MainActor
enum ClickyExplanationCardLayerBuilder {

    // MARK: - Look (our own design; every value is listed here so it can be tuned in one place)

    static let cardCornerRadiusInPoints: CGFloat = 6
    static let cardEdgeWidthInPoints: CGFloat = 1
    static let cardShadowOpacity: Float = 0.28
    static let cardShadowRadiusInPoints: CGFloat = 12
    static let cardShadowVerticalOffsetInPoints: CGFloat = 5

    /// The squared grid printed on the paper: one faint line every this many points.
    static let cardGridSpacingInPoints: CGFloat = 16
    static let cardGridLineWidthInPoints: CGFloat = 0.5
    /// The grid is drawn once for a card this tall and clipped to the paper, so a card that grows
    /// by a row uncovers more grid instead of needing a new one.
    static let tallestCardHeightInPoints: CGFloat = 1_200

    /// The title is written this much larger than the rows.
    static let titleFontSizeAddedToRowFontSizeInPoints: CGFloat = 4

    /// The pen on the card is finer than on the screen: its boxes are only thirty points tall.
    static let cardFirstPassInkLineWidthInPoints: CGFloat = 1.7
    static let cardSecondPassInkLineWidthInPoints: CGFloat = 1.0

    static let boxCornerRadiusInPoints: CGFloat = 5

    /// How long the paper takes to grow when a row is added, and to move when it has to.
    static let cardGrowSeconds: Double = 0.25

    /// A box's fill and words, and a timeline point, take at least this long to fade in, however
    /// quickly the pen passes them.
    static let minimumFadeInSeconds: Double = 0.2

    /// A callout: a dark pill holding a numbered badge and a few words.
    static let calloutHeightInPoints: CGFloat = 28
    static let calloutBadgeDiameterInPoints: CGFloat = 20
    static let calloutBadgeInsetInPoints: CGFloat = 4
    static let calloutGapBetweenBadgeAndTextInPoints: CGFloat = 7
    static let calloutTrailingPaddingInPoints: CGFloat = 11
    static let calloutBorderWidthInPoints: CGFloat = 1.5
    static let calloutBackgroundOpacity: CGFloat = 0.94
    static let calloutNumberFontSizeInPoints: CGFloat = 12
    /// The leader line is finer than a drawn arrow, so the tag reads as a note and not a mark.
    static let calloutLeaderFirstPassLineWidthInPoints: CGFloat = 2.4
    static let calloutLeaderSecondPassLineWidthInPoints: CGFloat = 1.5
    /// The tag fades in this fast; the pen then draws the leader line from it.
    static let calloutTagFadeInSeconds: Double = 0.2

    /// Core Animation layers accept extra values by key.
    private static let cardPaperLayerKey = "clickyCardPaperLayer"
    private static let cardPaperShadowLayerKey = "clickyCardPaperShadowLayer"
    private static let rowInkLayerKey = "clickyCardRowInkLayer"
    private static let rowRevealStepsKey = "clickyCardRowRevealSteps"
    private static let calloutTagLayerKey = "clickyCalloutTagLayer"
    private static let calloutLeaderInkLayerKey = "clickyCalloutLeaderInkLayer"
    private static let revealAnimationKey = "clickyCardReveal"

    /// One layer of a row that appears while the row is written, and when: as shares of the
    /// row's pen time. A class so it can be stored on a layer by key.
    private final class RevealStep: NSObject {
        let layer: CALayer
        let startShareOfPenTime: Double
        let endShareOfPenTime: Double
        /// True for a line of words, which is uncovered from left to right like writing. False
        /// for a box's fill and words and a timeline point, which fade in.
        let isUncoveredFromLeftToRight: Bool

        init(layer: CALayer, startShareOfPenTime: Double, endShareOfPenTime: Double, isUncoveredFromLeftToRight: Bool) {
            self.layer = layer
            self.startShareOfPenTime = startShareOfPenTime
            self.endShareOfPenTime = endShareOfPenTime
            self.isUncoveredFromLeftToRight = isUncoveredFromLeftToRight
        }
    }

    // MARK: - Typeface and measuring

    /// The rows use the handwriting typeface sticky notes use, so everything Clicky writes is in
    /// one hand.
    static var rowFont: NSFont {
        ClickyDrawingMarkLayerBuilder.stickyNoteFont
    }

    static var titleFont: NSFont {
        let rowFont = self.rowFont
        let titleFontSize = rowFont.pointSize + titleFontSizeAddedToRowFontSizeInPoints
        return NSFont(descriptor: rowFont.fontDescriptor, size: titleFontSize) ?? rowFont
    }

    static var calloutNumberFont: NSFont {
        ClickyDrawingMarkLayerBuilder.roundedSystemFont(ofSize: calloutNumberFontSizeInPoints, weight: .bold)
    }

    private static func textSize(of text: String, font: NSFont) -> CGSize {
        let measuredSize = NSAttributedString(string: text, attributes: [.font: font]).size()
        return CGSize(width: ceil(measuredSize.width), height: ceil(measuredSize.height))
    }

    /// The layout sizes with the line heights of the typeface picked on this Mac.
    static var layoutMetrics: ClickyExplanationCardLayoutMetrics {
        var layoutMetrics = ClickyExplanationCardLayoutMetrics()
        layoutMetrics.titleLineHeightInPoints = Double(textSize(of: "Ag", font: titleFont).height)
        layoutMetrics.textLineHeightInPoints = Double(textSize(of: "Ag", font: rowFont).height)
        // A box must hold a line of words with a little air above and below.
        layoutMetrics.boxHeightInPoints = max(layoutMetrics.boxHeightInPoints, layoutMetrics.textLineHeightInPoints + 6)
        layoutMetrics.timelinePointHeightInPoints = max(layoutMetrics.timelinePointHeightInPoints, layoutMetrics.textLineHeightInPoints + 2)
        return layoutMetrics
    }

    /// Where everything on the card goes, measured with the real typeface.
    static func cardLayout(for card: ClickyExplanationCard) -> ClickyExplanationCardLayout {
        let titleFont = self.titleFont
        let rowFont = self.rowFont
        return ClickyExplanationCardLayoutCalculator.layout(
            for: card,
            metrics: layoutMetrics,
            titleTextWidthInPoints: { Double(textSize(of: $0, font: titleFont).width) },
            rowTextWidthInPoints: { Double(textSize(of: $0, font: rowFont).width) }
        )
    }

    /// How far the pen travels to write one row, for the schedule. A row's own size does not
    /// depend on the rows around it, so it is laid out alone.
    static func penTravelLengthInPoints(for row: ClickyExplanationCardRow) -> Double {
        let rowFont = self.rowFont
        let rowLayout = ClickyExplanationCardLayoutCalculator.rowLayout(
            for: row,
            topY: 0,
            metrics: layoutMetrics,
            rowTextWidthInPoints: { Double(textSize(of: $0, font: rowFont).width) }
        )
        return ClickyExplanationCardLayoutCalculator.penTravelLengthInPoints(for: rowLayout)
    }

    // MARK: - Card

    /// A rectangle given in the card (from its top-left corner, y growing downwards) as a frame
    /// for a sublayer of the card layer.
    ///
    /// The card layer has no size and sits on the card's top-left corner, so everything on the
    /// card hangs below it at negative y. That way the paper can grow downwards by a row without
    /// anything already written having to move.
    private static func frameInCardLayer(forFrameInCard frameInCard: CGRect) -> CGRect {
        CGRect(x: frameInCard.minX, y: -frameInCard.maxY, width: frameInCard.width, height: frameInCard.height)
    }

    private static func cardLayerPosition(forCardFrameFromTopLeft cardFrameFromTopLeft: CGRect, displaySizeInPoints: CGSize) -> CGPoint {
        // Core Animation on the Mac measures from the bottom-left corner of the display.
        CGPoint(x: cardFrameFromTopLeft.minX, y: displaySizeInPoints.height - cardFrameFromTopLeft.minY)
    }

    /// Builds the layer of a card: paper, grid, title, and any rows the card already has (written
    /// in full, without animation). `cardFrameFromTopLeft` is where the app placed the card on the
    /// display, in points from the display's top-left corner.
    static func makeCardLayer(
        forMarkNumber markNumber: Int,
        card: ClickyExplanationCard,
        cardFrameFromTopLeft: CGRect,
        displaySizeInPoints: CGSize,
        backingScaleFactor: CGFloat
    ) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let cardLayout = cardLayout(for: card)

        let cardLayer = CALayer()
        cardLayer.bounds = .zero
        cardLayer.position = cardLayerPosition(forCardFrameFromTopLeft: cardFrameFromTopLeft, displaySizeInPoints: displaySizeInPoints)

        // The paper clips the grid to its rounded corners, and a layer that clips cannot cast a
        // shadow. A second layer of the same shape under it casts the shadow instead.
        let paperShadowLayer = CALayer()
        paperShadowLayer.anchorPoint = CGPoint(x: 0, y: 1)
        paperShadowLayer.position = .zero
        paperShadowLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingCardPaper).cgColor
        paperShadowLayer.cornerRadius = cardCornerRadiusInPoints
        paperShadowLayer.shadowColor = NSColor.black.cgColor
        paperShadowLayer.shadowOpacity = cardShadowOpacity
        paperShadowLayer.shadowRadius = cardShadowRadiusInPoints
        // Negative is downwards, because a layer's own coordinates grow upwards.
        paperShadowLayer.shadowOffset = CGSize(width: 0, height: -cardShadowVerticalOffsetInPoints)
        cardLayer.addSublayer(paperShadowLayer)

        let paperLayer = CALayer()
        paperLayer.anchorPoint = CGPoint(x: 0, y: 1)
        paperLayer.position = .zero
        paperLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingCardPaper).cgColor
        paperLayer.cornerRadius = cardCornerRadiusInPoints
        paperLayer.borderColor = NSColor(DS.Colors.overlayDrawingCardEdge).cgColor
        paperLayer.borderWidth = cardEdgeWidthInPoints
        paperLayer.masksToBounds = true
        paperLayer.addSublayer(makeGridLayer(cardWidthInPoints: cardLayout.cardSize.width, backingScaleFactor: backingScaleFactor))
        cardLayer.addSublayer(paperLayer)

        cardLayer.setValue(paperLayer, forKey: cardPaperLayerKey)
        cardLayer.setValue(paperShadowLayer, forKey: cardPaperShadowLayerKey)
        setPaperSize(of: cardLayer, to: cardLayout.cardSize)

        for titleLine in cardLayout.titleLines {
            guard case .textLine(let text, let frame) = titleLine else { continue }
            cardLayer.addSublayer(makeTextLayer(
                text: text,
                font: titleFont,
                color: NSColor(DS.Colors.overlayDrawingCardText),
                frameInCard: frame,
                alignmentMode: .left,
                backingScaleFactor: backingScaleFactor
            ))
        }

        for rowIndex in cardLayout.rowLayouts.indices {
            cardLayer.addSublayer(makeRowLayer(
                for: cardLayout.rowLayouts[rowIndex],
                rowIndex: rowIndex,
                markNumber: markNumber,
                backingScaleFactor: backingScaleFactor
            ))
        }

        return cardLayer
    }

    /// Writes one more row on a card that is on the screen: the paper grows (and the card moves
    /// if the app says so), then the row is written with the pen. `card` already holds the row.
    static func addRow(
        atRowIndex rowIndex: Int,
        of card: ClickyExplanationCard,
        to cardLayer: CALayer,
        markNumber: Int,
        cardFrameFromTopLeft: CGRect,
        displaySizeInPoints: CGSize,
        backingScaleFactor: CGFloat,
        penDurationSeconds: Double
    ) {
        let cardLayout = cardLayout(for: card)
        guard rowIndex >= 0, rowIndex < cardLayout.rowLayouts.count else { return }

        // The paper grows and the card moves with Core Animation's own short animation.
        CATransaction.begin()
        CATransaction.setAnimationDuration(cardGrowSeconds)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        setPaperSize(of: cardLayer, to: cardLayout.cardSize)
        cardLayer.position = cardLayerPosition(forCardFrameFromTopLeft: cardFrameFromTopLeft, displaySizeInPoints: displaySizeInPoints)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rowLayer = makeRowLayer(
            for: cardLayout.rowLayouts[rowIndex],
            rowIndex: rowIndex,
            markNumber: markNumber,
            backingScaleFactor: backingScaleFactor
        )
        cardLayer.addSublayer(rowLayer)
        CATransaction.commit()

        animateRowAppearance(of: rowLayer, penDurationSeconds: penDurationSeconds)
    }

    /// The paper and its shadow hang from the card's top-left corner. Their bounds start at minus
    /// their height, so y = 0 inside them is always the top edge and the grid never slides when
    /// the height changes.
    private static func setPaperSize(of cardLayer: CALayer, to cardSize: CGSize) {
        let paperBounds = CGRect(x: 0, y: -cardSize.height, width: cardSize.width, height: cardSize.height)
        (cardLayer.value(forKey: cardPaperLayerKey) as? CALayer)?.bounds = paperBounds
        (cardLayer.value(forKey: cardPaperShadowLayerKey) as? CALayer)?.bounds = paperBounds
    }

    private static func makeGridLayer(cardWidthInPoints: CGFloat, backingScaleFactor: CGFloat) -> CAShapeLayer {
        let gridPath = CGMutablePath()
        var lineX = cardGridSpacingInPoints
        while lineX < cardWidthInPoints {
            gridPath.move(to: CGPoint(x: lineX, y: 0))
            gridPath.addLine(to: CGPoint(x: lineX, y: tallestCardHeightInPoints))
            lineX += cardGridSpacingInPoints
        }
        var lineDistanceFromTop = cardGridSpacingInPoints
        while lineDistanceFromTop < tallestCardHeightInPoints {
            gridPath.move(to: CGPoint(x: 0, y: tallestCardHeightInPoints - lineDistanceFromTop))
            gridPath.addLine(to: CGPoint(x: cardWidthInPoints, y: tallestCardHeightInPoints - lineDistanceFromTop))
            lineDistanceFromTop += cardGridSpacingInPoints
        }

        let gridLayer = CAShapeLayer()
        // Its top edge is the paper's top edge (y = 0 inside the paper).
        gridLayer.frame = CGRect(x: 0, y: -tallestCardHeightInPoints, width: cardWidthInPoints, height: tallestCardHeightInPoints)
        gridLayer.path = gridPath
        gridLayer.fillColor = nil
        gridLayer.strokeColor = NSColor(DS.Colors.overlayDrawingCardGridLine).cgColor
        gridLayer.lineWidth = cardGridLineWidthInPoints
        gridLayer.contentsScale = backingScaleFactor
        return gridLayer
    }

    private static func makeTextLayer(
        text: String,
        font: NSFont,
        color: NSColor,
        frameInCard: CGRect,
        alignmentMode: CATextLayerAlignmentMode,
        backingScaleFactor: CGFloat
    ) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        textLayer.frame = frameInCardLayer(forFrameInCard: frameInCard)
        textLayer.alignmentMode = alignmentMode
        // Words wider than their place end in an ellipsis instead of running over their box.
        textLayer.truncationMode = .end
        // Without the screen's scale the text would be drawn at one pixel per point and look blurry.
        textLayer.contentsScale = backingScaleFactor
        return textLayer
    }

    /// The layers of one row: its ink (box outlines, arrows, a timeline's line, with the pen
    /// tip), the fills of its boxes, and its words. Everything is fully visible as built; the
    /// row remembers what to reveal when, for `animateRowAppearance`.
    private static func makeRowLayer(
        for rowLayout: ClickyExplanationCardRowLayout,
        rowIndex: Int,
        markNumber: Int,
        backingScaleFactor: CGFloat
    ) -> CALayer {
        // Like the card layer, a row layer has no size and sits on the card's top-left corner, so
        // its sublayers use the card's coordinates.
        let rowLayer = CALayer()
        rowLayer.bounds = .zero
        rowLayer.position = .zero

        let rowInk = ClickyExplanationCardLayoutCalculator.ink(
            for: rowLayout,
            seed: ClickyExplanationCardLayoutCalculator.seed(
                forRowIndex: rowIndex,
                cardSeed: ClickyHandDrawnPathGenerator.seed(forMarkNumber: markNumber)
            )
        )
        let timeSharesByPartIndex = ClickyDrawingPenPath.timeSharesByPartIndex(forStrokes: rowInk.strokes)

        var revealSteps: [RevealStep] = []
        let rowFont = self.rowFont
        let textColor = NSColor(DS.Colors.overlayDrawingCardText)

        // Lines of words are written one after the other, each for a share of the time in
        // proportion to its width.
        let textLineWidths = rowLayout.elements.compactMap { element -> CGFloat? in
            if case .textLine(_, let frame) = element { return frame.width }
            return nil
        }
        let totalTextLineWidth = max(1, textLineWidths.reduce(0, +))
        var textLineWidthWrittenSoFar: CGFloat = 0

        let timelinePointCount = rowLayout.elements.filter { element in
            if case .timelinePoint = element { return true }
            return false
        }.count
        var timelinePointIndex = 0

        // Fills go under the ink and words on top of it, whatever order they are built in.
        var fillLayers: [CALayer] = []
        var textLayers: [CALayer] = []

        for (elementIndex, element) in rowLayout.elements.enumerated() {
            switch element {
            case .textLine(let text, let frame):
                let textLayer = makeTextLayer(text: text, font: rowFont, color: textColor, frameInCard: frame, alignmentMode: .left, backingScaleFactor: backingScaleFactor)
                textLayers.append(textLayer)
                let startShare = Double(textLineWidthWrittenSoFar / totalTextLineWidth)
                textLineWidthWrittenSoFar += frame.width
                let endShare = Double(textLineWidthWrittenSoFar / totalTextLineWidth)
                revealSteps.append(RevealStep(layer: textLayer, startShareOfPenTime: startShare, endShareOfPenTime: endShare, isUncoveredFromLeftToRight: true))

            case .box(let text, let frame, let isResultBox):
                let fillLayer = CALayer()
                fillLayer.frame = frameInCardLayer(forFrameInCard: frame)
                fillLayer.cornerRadius = boxCornerRadiusInPoints
                fillLayer.backgroundColor = NSColor(isResultBox ? DS.Colors.overlayDrawingCardResultBoxFill : DS.Colors.overlayDrawingCardBoxFill).cgColor
                fillLayers.append(fillLayer)

                let textHeight = textSize(of: text, font: rowFont).height
                let boxHorizontalPadding = CGFloat(layoutMetrics.boxHorizontalPaddingInPoints)
                let textLayer = makeTextLayer(
                    text: text,
                    font: rowFont,
                    color: textColor,
                    frameInCard: CGRect(
                        x: frame.minX + boxHorizontalPadding / 2,
                        y: frame.midY - textHeight / 2,
                        width: frame.width - boxHorizontalPadding,
                        height: textHeight
                    ),
                    alignmentMode: .center,
                    backingScaleFactor: backingScaleFactor
                )
                textLayers.append(textLayer)

                // The fill and the words appear while the pen draws this box's outline.
                let boxTimeShares = rowInk.firstPartIndexByElementIndex[elementIndex].flatMap { timeSharesByPartIndex[$0] }
                    ?? (startShareOfPenTime: 0, endShareOfPenTime: 1)
                for boxLayer in [fillLayer, textLayer] {
                    revealSteps.append(RevealStep(
                        layer: boxLayer,
                        startShareOfPenTime: boxTimeShares.startShareOfPenTime,
                        endShareOfPenTime: boxTimeShares.endShareOfPenTime,
                        isUncoveredFromLeftToRight: false
                    ))
                }

            case .timelinePoint(let dotCenter, let whenText, let whenFrame, let whatText, let whatFrame):
                let dotRadius = CGFloat(layoutMetrics.timelineDotRadiusInPoints)
                let dotLayer = CALayer()
                dotLayer.frame = frameInCardLayer(forFrameInCard: CGRect(
                    x: dotCenter.x - dotRadius,
                    y: dotCenter.y - dotRadius,
                    width: 2 * dotRadius,
                    height: 2 * dotRadius
                ))
                dotLayer.cornerRadius = dotRadius
                dotLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingInk).cgColor
                let whenLayer = makeTextLayer(text: whenText, font: rowFont, color: NSColor(DS.Colors.overlayDrawingCardAccentText), frameInCard: whenFrame, alignmentMode: .left, backingScaleFactor: backingScaleFactor)
                let whatLayer = makeTextLayer(text: whatText, font: rowFont, color: textColor, frameInCard: whatFrame, alignmentMode: .left, backingScaleFactor: backingScaleFactor)
                textLayers += [dotLayer, whenLayer, whatLayer]

                // A point appears as the pen, drawing the line downwards, passes it.
                let shareOfLineAtPoint = timelinePointCount > 1 ? Double(timelinePointIndex) / Double(timelinePointCount - 1) : 0
                timelinePointIndex += 1
                let startShare = shareOfLineAtPoint * 0.8
                for pointLayer in [dotLayer, whenLayer, whatLayer] {
                    revealSteps.append(RevealStep(layer: pointLayer, startShareOfPenTime: startShare, endShareOfPenTime: startShare + 0.2, isUncoveredFromLeftToRight: false))
                }

            case .arrow, .timelineLine:
                // Ink only: drawn below from the row's strokes.
                break
            }
        }

        for fillLayer in fillLayers {
            rowLayer.addSublayer(fillLayer)
        }

        if !rowInk.strokes.isEmpty {
            let markerInkColor = NSColor(DS.Colors.overlayDrawingInk).cgColor
            var inkColorsByPartIndex: [Int: CGColor] = [:]
            for partIndex in rowInk.partIndexesDrawnInMarkerInk {
                inkColorsByPartIndex[partIndex] = markerInkColor
            }
            let rowInkLayer = ClickyDrawingMarkLayerBuilder.makeInkLayer(
                for: rowInk.strokes,
                // The strokes are in the card's coordinates, and the row layer sits on the card's
                // top-left corner: an area of no height puts the ink layer exactly there.
                displaySizeInPoints: .zero,
                backingScaleFactor: backingScaleFactor,
                inkLook: ClickyDrawingMarkLayerBuilder.InkLook(
                    firstPassLineWidthInPoints: cardFirstPassInkLineWidthInPoints,
                    secondPassLineWidthInPoints: cardSecondPassInkLineWidthInPoints,
                    castsShadow: false,
                    inkColor: NSColor(DS.Colors.overlayDrawingCardPencil).cgColor,
                    inkColorsByPartIndex: inkColorsByPartIndex,
                    penTipFillColor: markerInkColor
                )
            )
            rowLayer.addSublayer(rowInkLayer)
            rowLayer.setValue(rowInkLayer, forKey: rowInkLayerKey)
        }

        for textLayer in textLayers {
            rowLayer.addSublayer(textLayer)
        }
        rowLayer.setValue(revealSteps, forKey: rowRevealStepsKey)
        return rowLayer
    }

    /// Writes a row that has just been added to the screen: the pen draws its ink, each box's
    /// fill and words fade in as the pen reaches the box, and lines of words are uncovered from
    /// left to right. The layer must already be in the layer tree.
    private static func animateRowAppearance(of rowLayer: CALayer, penDurationSeconds: Double) {
        if let rowInkLayer = rowLayer.value(forKey: rowInkLayerKey) as? CALayer {
            ClickyDrawingMarkLayerBuilder.animateAppearance(of: rowInkLayer, penDurationSeconds: penDurationSeconds)
        }

        let revealSteps = (rowLayer.value(forKey: rowRevealStepsKey) as? [RevealStep]) ?? []
        for revealStep in revealSteps {
            let revealedLayer = revealStep.layer
            let startSeconds = revealStep.startShareOfPenTime * penDurationSeconds
            let stepSeconds = (revealStep.endShareOfPenTime - revealStep.startShareOfPenTime) * penDurationSeconds

            if revealStep.isUncoveredFromLeftToRight {
                // A mask that grows from the left edge uncovers the words in writing order.
                let maskLayer = CALayer()
                maskLayer.backgroundColor = NSColor.black.cgColor
                maskLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
                maskLayer.position = CGPoint(x: 0, y: revealedLayer.bounds.midY)
                maskLayer.bounds = revealedLayer.bounds
                revealedLayer.mask = maskLayer

                let uncoverAnimation = CABasicAnimation(keyPath: "bounds.size.width")
                uncoverAnimation.fromValue = 0
                uncoverAnimation.toValue = revealedLayer.bounds.width
                uncoverAnimation.beginTime = maskLayer.convertTime(CACurrentMediaTime(), from: nil) + startSeconds
                uncoverAnimation.duration = max(0.05, stepSeconds)
                // "backwards" keeps the line covered until its own start time.
                uncoverAnimation.fillMode = .backwards
                uncoverAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
                maskLayer.add(uncoverAnimation, forKey: revealAnimationKey)
            } else {
                let fadeInAnimation = CABasicAnimation(keyPath: "opacity")
                fadeInAnimation.fromValue = 0
                fadeInAnimation.toValue = revealedLayer.opacity
                fadeInAnimation.beginTime = revealedLayer.convertTime(CACurrentMediaTime(), from: nil) + startSeconds
                fadeInAnimation.duration = max(minimumFadeInSeconds, stepSeconds)
                fadeInAnimation.fillMode = .backwards
                fadeInAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                revealedLayer.add(fadeInAnimation, forKey: revealAnimationKey)
            }
        }
    }

    // MARK: - Callout

    private static func attributedCalloutText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: ClickyDrawingMarkLayerBuilder.labelFont,
            .foregroundColor: NSColor(DS.Colors.overlayDrawingLabelText),
        ])
    }

    /// The size of a callout's tag: the numbered badge, a gap, and the words.
    static func calloutTagSize(forText text: String) -> CGSize {
        let textWidth = ceil(attributedCalloutText(text).size().width)
        return CGSize(
            width: calloutBadgeInsetInPoints + calloutBadgeDiameterInPoints + calloutGapBetweenBadgeAndTextInPoints + textWidth + calloutTrailingPaddingInPoints,
            height: calloutHeightInPoints
        )
    }

    /// Builds the layer of a callout: the tag at `tagFrameFromTopLeft` (where the app placed it)
    /// and a hand-drawn leader line with an arrowhead from the tag to the place it is about.
    /// Positions are display points from the display's top-left corner.
    static func makeCalloutLayer(
        forMarkNumber markNumber: Int,
        targetInDisplayPoints: CGPoint,
        text: String,
        calloutNumber: Int,
        tagFrameFromTopLeft: CGRect,
        displaySizeInPoints: CGSize,
        backingScaleFactor: CGFloat
    ) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // The callout layer covers the display, so the tag and the leader line, which are in
        // different places, can both be put in it with display coordinates.
        let calloutLayer = CALayer()
        calloutLayer.frame = CGRect(origin: .zero, size: displaySizeInPoints)

        if let leaderLine = ClickyCalloutPlacement.leaderLine(fromTagFrame: tagFrameFromTopLeft, toTargetInDisplayPoints: targetInDisplayPoints) {
            let leaderStrokes = ClickyHandDrawnPathGenerator.strokes(
                forShapeInDisplayPoints: .arrow(
                    tail: ClickyDrawingPoint(x: Double(leaderLine.start.x), y: Double(leaderLine.start.y)),
                    head: ClickyDrawingPoint(x: Double(leaderLine.end.x), y: Double(leaderLine.end.y))
                ),
                seed: ClickyHandDrawnPathGenerator.seed(forMarkNumber: markNumber)
            )
            var leaderInkLook = ClickyDrawingMarkLayerBuilder.screenMarkInkLook
            leaderInkLook.firstPassLineWidthInPoints = calloutLeaderFirstPassLineWidthInPoints
            leaderInkLook.secondPassLineWidthInPoints = calloutLeaderSecondPassLineWidthInPoints
            let leaderInkLayer = ClickyDrawingMarkLayerBuilder.makeInkLayer(
                for: leaderStrokes,
                displaySizeInPoints: displaySizeInPoints,
                backingScaleFactor: backingScaleFactor,
                inkLook: leaderInkLook
            )
            calloutLayer.addSublayer(leaderInkLayer)
            calloutLayer.setValue(leaderInkLayer, forKey: calloutLeaderInkLayerKey)
        }

        // The tag: a dark pill with an ink-coloured edge, like a label, so it can be read on any page.
        let tagLayer = CALayer()
        tagLayer.frame = ClickyDrawingMarkLayerBuilder.frameFromBottomLeft(
            forFrameFromTopLeft: tagFrameFromTopLeft,
            displaySizeInPoints: displaySizeInPoints
        )
        tagLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingLabelBackground).withAlphaComponent(calloutBackgroundOpacity).cgColor
        tagLayer.cornerRadius = tagFrameFromTopLeft.height / 2
        tagLayer.borderColor = NSColor(DS.Colors.overlayDrawingInk).cgColor
        tagLayer.borderWidth = calloutBorderWidthInPoints

        // The badge: the callout's number on a disc of the marker ink.
        let badgeLayer = CALayer()
        badgeLayer.frame = CGRect(
            x: calloutBadgeInsetInPoints,
            y: (tagFrameFromTopLeft.height - calloutBadgeDiameterInPoints) / 2,
            width: calloutBadgeDiameterInPoints,
            height: calloutBadgeDiameterInPoints
        )
        badgeLayer.cornerRadius = calloutBadgeDiameterInPoints / 2
        badgeLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingInk).cgColor
        tagLayer.addSublayer(badgeLayer)

        let attributedNumber = NSAttributedString(string: String(calloutNumber), attributes: [
            .font: calloutNumberFont,
            .foregroundColor: NSColor(DS.Colors.overlayDrawingLabelText),
        ])
        let numberHeight = ceil(attributedNumber.size().height)
        let numberLayer = CATextLayer()
        numberLayer.string = attributedNumber
        numberLayer.alignmentMode = .center
        numberLayer.frame = CGRect(
            x: 0,
            y: (calloutBadgeDiameterInPoints - numberHeight) / 2,
            width: calloutBadgeDiameterInPoints,
            height: numberHeight
        )
        numberLayer.contentsScale = backingScaleFactor
        badgeLayer.addSublayer(numberLayer)

        let attributedText = attributedCalloutText(text)
        let measuredTextSize = attributedText.size()
        let textHeight = ceil(measuredTextSize.height)
        let textLeftX = calloutBadgeInsetInPoints + calloutBadgeDiameterInPoints + calloutGapBetweenBadgeAndTextInPoints
        let textLayer = CATextLayer()
        textLayer.string = attributedText
        textLayer.truncationMode = .end
        textLayer.frame = CGRect(
            x: textLeftX,
            y: (tagFrameFromTopLeft.height - textHeight) / 2,
            width: max(0, tagFrameFromTopLeft.width - textLeftX - calloutTrailingPaddingInPoints),
            height: textHeight
        )
        textLayer.contentsScale = backingScaleFactor
        tagLayer.addSublayer(textLayer)

        calloutLayer.addSublayer(tagLayer)
        calloutLayer.setValue(tagLayer, forKey: calloutTagLayerKey)
        return calloutLayer
    }

    /// Starts the appearance of a callout that has just been added to the screen: the tag fades
    /// in while the pen draws the leader line from it to the place it is about.
    static func animateCalloutAppearance(of calloutLayer: CALayer, penDurationSeconds: Double) {
        if let tagLayer = calloutLayer.value(forKey: calloutTagLayerKey) as? CALayer {
            let fadeInAnimation = CABasicAnimation(keyPath: "opacity")
            fadeInAnimation.fromValue = 0
            fadeInAnimation.toValue = tagLayer.opacity
            let growAnimation = CABasicAnimation(keyPath: "transform.scale")
            growAnimation.fromValue = ClickyDrawingMarkLayerBuilder.textMarkAppearStartScale
            growAnimation.toValue = 1
            let appearAnimationGroup = CAAnimationGroup()
            appearAnimationGroup.animations = [fadeInAnimation, growAnimation]
            appearAnimationGroup.duration = calloutTagFadeInSeconds
            appearAnimationGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tagLayer.add(appearAnimationGroup, forKey: revealAnimationKey)
        }
        if let leaderInkLayer = calloutLayer.value(forKey: calloutLeaderInkLayerKey) as? CALayer {
            ClickyDrawingMarkLayerBuilder.animateAppearance(of: leaderInkLayer, penDurationSeconds: penDurationSeconds)
        }
    }
}
