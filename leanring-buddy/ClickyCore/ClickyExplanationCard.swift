import CoreGraphics
import Foundation

/// One dated point of a timeline row: "2013" and "debut title".
nonisolated struct ClickyExplanationCardTimelinePoint: Equatable {
    let whenText: String
    let whatText: String
}

/// One row of an explanation card. Every case carries only short text, so the card can be parsed,
/// limited, laid out and listed in the prompt without AppKit.
nonisolated enum ClickyExplanationCardRow: Equatable {
    /// One handwritten line.
    case text(String)
    /// A few small boxes, and optionally an arrow to a result box.
    case boxes(inputTexts: [String], resultText: String?)
    /// A few small nodes joined by arrows.
    case flow(nodeTexts: [String])
    /// A few dated points on a line.
    case timeline(points: [ClickyExplanationCardTimelinePoint])

    /// The word used for this row in a `[ROW:...]` tag.
    var tagKindName: String {
        switch self {
        case .text: return "text"
        case .boxes: return "boxes"
        case .flow: return "flow"
        case .timeline: return "timeline"
        }
    }

    /// The row exactly as the grammar writes it after "ROW:", such as "boxes:the|sky|is -> blue".
    /// The conversation history and the "marks on screen" list both use it, so the model always
    /// reads its rows back in the documented format.
    var canonicalTagBody: String {
        switch self {
        case .text(let text):
            return "text:\(text)"
        case .boxes(let inputTexts, let resultText):
            let resultSuffix = resultText.map { " -> \($0)" } ?? ""
            return "boxes:\(inputTexts.joined(separator: "|"))\(resultSuffix)"
        case .flow(let nodeTexts):
            return "flow:\(nodeTexts.joined(separator: " > "))"
        case .timeline(let points):
            return "timeline:" + points.map { "\($0.whenText)=\($0.whatText)" }.joined(separator: "|")
        }
    }
}

/// A small paper card Clicky writes on the screen while it explains something: a title and up to
/// five rows. The app decides where it goes, so it carries no position.
nonisolated struct ClickyExplanationCard: Equatable {
    /// A card is a small diagram, not a page. A longer title is cut, not rejected, like a label.
    static let maximumTitleCharacterCount = 48

    /// Five rows already fill the card's height comfortably; more would run off a small screen.
    static let maximumRowCount = 5

    /// One handwritten line. Longer text is cut.
    static let maximumTextRowCharacterCount = 70

    /// The text of one box, flow node or timeline point. Longer text is cut.
    static let maximumRowPartCharacterCount = 24

    /// The "when" of a timeline point is a year or a short date. Longer text is cut.
    static let maximumTimelineWhenCharacterCount = 12

    /// A boxes row has one to five boxes before its optional result. A flow or timeline needs at
    /// least two parts to be a flow or a timeline, and more than five do not fit the card. A row
    /// outside these counts is dropped, not cut: a diagram missing its last step would mislead.
    static let minimumBoxCountPerBoxesRow = 1
    static let maximumBoxCountPerBoxesRow = 5
    static let minimumPartCountPerFlowOrTimelineRow = 2
    static let maximumPartCountPerFlowOrTimelineRow = 5

    let title: String
    let rows: [ClickyExplanationCardRow]

    func addingRow(_ row: ClickyExplanationCardRow) -> ClickyExplanationCard {
        ClickyExplanationCard(title: title, rows: rows + [row])
    }

    func keepingFirstRows(_ rowCountToKeep: Int) -> ClickyExplanationCard {
        ClickyExplanationCard(title: title, rows: Array(rows.prefix(max(0, rowCountToKeep))))
    }
}

// MARK: - Layout

/// Every size the card's layout needs. The app fills in the two line heights from the handwriting
/// typeface it picked; everything else has a default that is our own design.
nonisolated struct ClickyExplanationCardLayoutMetrics: Equatable {
    /// About a third of a small laptop screen is 420 points; 320 leaves the page readable beside it.
    var cardWidthInPoints: Double = 320
    var paddingInPoints: Double = 16
    var titleLineHeightInPoints: Double = 26
    /// A long title wraps onto a second line and is cut after that.
    var maximumTitleLineCount: Int = 2
    var gapBetweenTitleAndRowsInPoints: Double = 12
    var gapBetweenRowsInPoints: Double = 14
    var textLineHeightInPoints: Double = 22
    /// A 70 character line needs two lines at most widths; three is the safety limit.
    var maximumTextRowLineCount: Int = 3
    var boxHeightInPoints: Double = 30
    var boxHorizontalPaddingInPoints: Double = 9
    /// A box is never narrower than this, so a one-letter box still looks like a box.
    var minimumBoxWidthInPoints: Double = 30
    var gapBetweenBoxesInPoints: Double = 7
    /// The room an arrow takes between two boxes, and how far the arrow stays from each of them.
    var arrowSlotWidthInPoints: Double = 32
    var arrowInsetInPoints: Double = 5
    /// When a row of boxes is too wide for the card it continues on a second line this far below.
    var gapBetweenBoxLinesInPoints: Double = 8
    var timelinePointHeightInPoints: Double = 24
    /// How far the timeline's line sits from the left edge of the card's content.
    var timelineLineInsetInPoints: Double = 6
    /// The line runs this far past its first and last point.
    var timelineLineOverhangInPoints: Double = 7
    var timelineDotRadiusInPoints: Double = 3.5
    var gapBetweenTimelineLineAndTextInPoints: Double = 14
    var maximumTimelineWhenWidthInPoints: Double = 96
    var gapBetweenTimelineWhenAndWhatInPoints: Double = 10

    var contentWidthInPoints: Double {
        cardWidthInPoints - 2 * paddingInPoints
    }
}

/// One thing to draw in a row, placed in the card: points from the card's top-left corner, with y
/// growing downwards.
nonisolated enum ClickyExplanationCardRowElement: Equatable {
    case textLine(text: String, frame: CGRect)
    case box(text: String, frame: CGRect, isResultBox: Bool)
    case arrow(tail: CGPoint, head: CGPoint)
    case timelineLine(start: CGPoint, end: CGPoint)
    case timelinePoint(dotCenter: CGPoint, whenText: String, whenFrame: CGRect, whatText: String, whatFrame: CGRect)
}

nonisolated struct ClickyExplanationCardRowLayout: Equatable {
    /// The whole row, in the card.
    let frame: CGRect
    /// In the order they are drawn: left to right, top to bottom.
    let elements: [ClickyExplanationCardRowElement]
}

nonisolated struct ClickyExplanationCardLayout: Equatable {
    let cardSize: CGSize
    /// The title, one frame per line.
    let titleLines: [ClickyExplanationCardRowElement]
    /// One layout per row of the card, in order. Adding a row to a card never moves the rows
    /// before it, which is what lets the card grow on screen without redrawing.
    let rowLayouts: [ClickyExplanationCardRowLayout]
}

/// The strokes of one row's ink (box outlines, arrows, the timeline's line) and which stroke
/// belongs to which element, so the pen can draw them one after the other and each box's fill and
/// words can appear as the pen reaches it.
nonisolated struct ClickyExplanationCardRowInk: Equatable {
    /// Every stroke of the row. Their `partIndex` values count up through the row in drawing
    /// order, which is the order `ClickyDrawingPenPath` moves the pen in.
    let strokes: [ClickyHandDrawnStroke]
    /// For each element of the row that has ink (by its index in `elements`), its first part.
    let firstPartIndexByElementIndex: [Int: Int]
    /// The parts that are arrows or the timeline's line. They are drawn in the marker ink; box
    /// outlines are drawn in pencil.
    let partIndexesDrawnInMarkerInk: Set<Int>
}

/// Where everything on an explanation card goes. Pure numbers: the widths of the words are asked
/// for through closures, so the tests can measure with a ruler of their own and the app with the
/// real typeface.
nonisolated enum ClickyExplanationCardLayoutCalculator {
    /// The wobble of a stroke on the card is smaller than on the screen: a box here is thirty
    /// points tall, and the full two and a half points would push its outline into its words.
    static let maximumWobbleDistanceOnCardInPoints: Double = 1.1

    static func layout(
        for card: ClickyExplanationCard,
        metrics: ClickyExplanationCardLayoutMetrics,
        titleTextWidthInPoints: (String) -> Double,
        rowTextWidthInPoints: (String) -> Double
    ) -> ClickyExplanationCardLayout {
        let contentLeftX = metrics.paddingInPoints
        var nextTopY = metrics.paddingInPoints

        var titleLines: [ClickyExplanationCardRowElement] = []
        let wrappedTitleLines = wrappedLines(
            of: card.title,
            maximumLineWidthInPoints: metrics.contentWidthInPoints,
            maximumLineCount: metrics.maximumTitleLineCount,
            textWidthInPoints: titleTextWidthInPoints
        )
        for wrappedTitleLine in wrappedTitleLines {
            titleLines.append(.textLine(
                text: wrappedTitleLine,
                frame: CGRect(
                    x: contentLeftX,
                    y: nextTopY,
                    width: min(metrics.contentWidthInPoints, ceil(titleTextWidthInPoints(wrappedTitleLine))),
                    height: metrics.titleLineHeightInPoints
                )
            ))
            nextTopY += metrics.titleLineHeightInPoints
        }

        var rowLayouts: [ClickyExplanationCardRowLayout] = []
        for (rowIndex, row) in card.rows.enumerated() {
            nextTopY += rowIndex == 0 ? metrics.gapBetweenTitleAndRowsInPoints : metrics.gapBetweenRowsInPoints
            let rowLayout = self.rowLayout(for: row, topY: nextTopY, metrics: metrics, rowTextWidthInPoints: rowTextWidthInPoints)
            rowLayouts.append(rowLayout)
            nextTopY = Double(rowLayout.frame.maxY)
        }

        return ClickyExplanationCardLayout(
            cardSize: CGSize(width: metrics.cardWidthInPoints, height: nextTopY + metrics.paddingInPoints),
            titleLines: titleLines,
            rowLayouts: rowLayouts
        )
    }

    /// One row placed with its top edge at `topY` in the card.
    static func rowLayout(
        for row: ClickyExplanationCardRow,
        topY: Double,
        metrics: ClickyExplanationCardLayoutMetrics,
        rowTextWidthInPoints: (String) -> Double
    ) -> ClickyExplanationCardRowLayout {
        let contentLeftX = metrics.paddingInPoints
        let contentWidth = metrics.contentWidthInPoints

        switch row {
        case .text(let text):
            let wrappedTextLines = wrappedLines(
                of: text,
                maximumLineWidthInPoints: contentWidth,
                maximumLineCount: metrics.maximumTextRowLineCount,
                textWidthInPoints: rowTextWidthInPoints
            )
            var elements: [ClickyExplanationCardRowElement] = []
            for (lineIndex, wrappedTextLine) in wrappedTextLines.enumerated() {
                elements.append(.textLine(
                    text: wrappedTextLine,
                    frame: CGRect(
                        x: contentLeftX,
                        y: topY + Double(lineIndex) * metrics.textLineHeightInPoints,
                        width: min(contentWidth, ceil(rowTextWidthInPoints(wrappedTextLine))),
                        height: metrics.textLineHeightInPoints
                    )
                ))
            }
            let rowHeight = Double(max(1, wrappedTextLines.count)) * metrics.textLineHeightInPoints
            return ClickyExplanationCardRowLayout(
                frame: CGRect(x: contentLeftX, y: topY, width: contentWidth, height: rowHeight),
                elements: elements
            )

        case .boxes(let inputTexts, let resultText):
            var chainItems = inputTexts.map { ChainItem(text: $0, isResultBox: false, followsAnArrow: false) }
            if let resultText {
                chainItems.append(ChainItem(text: resultText, isResultBox: true, followsAnArrow: true))
            }
            return chainRowLayout(for: chainItems, topY: topY, metrics: metrics, rowTextWidthInPoints: rowTextWidthInPoints)

        case .flow(let nodeTexts):
            let chainItems = nodeTexts.enumerated().map { nodeIndex, nodeText in
                ChainItem(text: nodeText, isResultBox: false, followsAnArrow: nodeIndex > 0)
            }
            return chainRowLayout(for: chainItems, topY: topY, metrics: metrics, rowTextWidthInPoints: rowTextWidthInPoints)

        case .timeline(let points):
            // The timeline runs down the card, one point per line. Across the card five points
            // would get under sixty points each, too narrow for what happened at them.
            let lineX = contentLeftX + metrics.timelineLineInsetInPoints
            let textLeftX = lineX + metrics.gapBetweenTimelineLineAndTextInPoints
            let contentRightX = contentLeftX + contentWidth
            var elements: [ClickyExplanationCardRowElement] = []
            var pointElements: [ClickyExplanationCardRowElement] = []
            var dotCenterYs: [Double] = []
            for (pointIndex, point) in points.enumerated() {
                let pointTopY = topY + Double(pointIndex) * metrics.timelinePointHeightInPoints
                let dotCenterY = pointTopY + metrics.timelinePointHeightInPoints / 2
                dotCenterYs.append(dotCenterY)
                let whenWidth = min(metrics.maximumTimelineWhenWidthInPoints, ceil(rowTextWidthInPoints(point.whenText)))
                let whatLeftX = textLeftX + whenWidth + metrics.gapBetweenTimelineWhenAndWhatInPoints
                let whatWidth = max(0, min(contentRightX - whatLeftX, ceil(rowTextWidthInPoints(point.whatText))))
                pointElements.append(.timelinePoint(
                    dotCenter: CGPoint(x: lineX, y: dotCenterY),
                    whenText: point.whenText,
                    whenFrame: CGRect(x: textLeftX, y: pointTopY, width: whenWidth, height: metrics.timelinePointHeightInPoints),
                    whatText: point.whatText,
                    whatFrame: CGRect(x: whatLeftX, y: pointTopY, width: whatWidth, height: metrics.timelinePointHeightInPoints)
                ))
            }
            if let firstDotCenterY = dotCenterYs.first, let lastDotCenterY = dotCenterYs.last {
                // The line is drawn first, from the top down; the points appear as it passes them.
                elements.append(.timelineLine(
                    start: CGPoint(x: lineX, y: firstDotCenterY - metrics.timelineLineOverhangInPoints),
                    end: CGPoint(x: lineX, y: lastDotCenterY + metrics.timelineLineOverhangInPoints)
                ))
            }
            elements += pointElements
            return ClickyExplanationCardRowLayout(
                frame: CGRect(x: contentLeftX, y: topY, width: contentWidth, height: Double(points.count) * metrics.timelinePointHeightInPoints),
                elements: elements
            )
        }
    }

    // MARK: - Boxes joined in a chain (boxes rows and flow rows)

    private struct ChainItem {
        let text: String
        let isResultBox: Bool
        /// True when an arrow leads into this box from the one before it.
        let followsAnArrow: Bool
    }

    /// Boxes from left to right, with a small gap or an arrow between them. A box that does not
    /// fit on the line starts a new one, taking the arrow that leads into it along, so the chain
    /// reads on like a sentence that wraps.
    private static func chainRowLayout(
        for chainItems: [ChainItem],
        topY: Double,
        metrics: ClickyExplanationCardLayoutMetrics,
        rowTextWidthInPoints: (String) -> Double
    ) -> ClickyExplanationCardRowLayout {
        let contentLeftX = metrics.paddingInPoints
        let contentRightX = contentLeftX + metrics.contentWidthInPoints

        var elements: [ClickyExplanationCardRowElement] = []
        var nextLeftX = contentLeftX
        var lineTopY = topY

        for chainItem in chainItems {
            let leadingWidthOnThisLine: Double
            if chainItem.followsAnArrow {
                leadingWidthOnThisLine = metrics.arrowSlotWidthInPoints
            } else {
                leadingWidthOnThisLine = nextLeftX > contentLeftX ? metrics.gapBetweenBoxesInPoints : 0
            }
            let leadingWidthAtLineStart = chainItem.followsAnArrow ? metrics.arrowSlotWidthInPoints : 0

            // Never wider than a whole line, so even the longest box fits the card; the words in
            // it are then cut with an ellipsis when drawn.
            let widestBoxThatFitsALine = metrics.contentWidthInPoints - leadingWidthAtLineStart
            let boxWidth = min(
                widestBoxThatFitsALine,
                max(metrics.minimumBoxWidthInPoints, ceil(rowTextWidthInPoints(chainItem.text)) + 2 * metrics.boxHorizontalPaddingInPoints)
            )

            var leadingWidth = leadingWidthOnThisLine
            let isFirstOnItsLine = nextLeftX <= contentLeftX
            if !isFirstOnItsLine && nextLeftX + leadingWidth + boxWidth > contentRightX {
                nextLeftX = contentLeftX
                lineTopY += metrics.boxHeightInPoints + metrics.gapBetweenBoxLinesInPoints
                leadingWidth = leadingWidthAtLineStart
            }

            let lineMiddleY = lineTopY + metrics.boxHeightInPoints / 2
            if chainItem.followsAnArrow {
                elements.append(.arrow(
                    tail: CGPoint(x: nextLeftX + metrics.arrowInsetInPoints, y: lineMiddleY),
                    head: CGPoint(x: nextLeftX + metrics.arrowSlotWidthInPoints - metrics.arrowInsetInPoints, y: lineMiddleY)
                ))
            }
            let boxLeftX = nextLeftX + leadingWidth
            elements.append(.box(
                text: chainItem.text,
                frame: CGRect(x: boxLeftX, y: lineTopY, width: boxWidth, height: metrics.boxHeightInPoints),
                isResultBox: chainItem.isResultBox
            ))
            nextLeftX = boxLeftX + boxWidth
        }

        return ClickyExplanationCardRowLayout(
            frame: CGRect(
                x: contentLeftX,
                y: topY,
                width: metrics.contentWidthInPoints,
                height: lineTopY + metrics.boxHeightInPoints - topY
            ),
            elements: elements
        )
    }

    // MARK: - Wrapping words

    /// Breaks text into lines no wider than the limit, at spaces. A single word wider than a line
    /// keeps its own line (and is cut when drawn). Whatever is left after the last allowed line is
    /// put on that line, so no word silently disappears from the layout's text.
    static func wrappedLines(
        of text: String,
        maximumLineWidthInPoints: Double,
        maximumLineCount: Int,
        textWidthInPoints: (String) -> Double
    ) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else {
            return []
        }

        var lines: [String] = []
        var currentLine = ""
        for word in words {
            let currentLineWithWord = currentLine.isEmpty ? word : currentLine + " " + word
            let isOnLastAllowedLine = lines.count >= maximumLineCount - 1
            if currentLine.isEmpty || isOnLastAllowedLine || textWidthInPoints(currentLineWithWord) <= maximumLineWidthInPoints {
                currentLine = currentLineWithWord
            } else {
                lines.append(currentLine)
                currentLine = word
            }
        }
        lines.append(currentLine)
        return lines
    }

    // MARK: - Ink

    /// The seed of one row's wobble: from the card's own seed and the row's place in the card, so
    /// a row always looks the same and two rows never share their wobble.
    static func seed(forRowIndex rowIndex: Int, cardSeed: UInt64) -> UInt64 {
        cardSeed &+ UInt64(truncatingIfNeeded: rowIndex + 1) &* 0x1F3D_5B79_A2C4_E681
    }

    /// The pen strokes of a row: a wobbly outline for each box, an arrow for each arrow and one
    /// line for a timeline, in the row's drawing order. Points are in the card (top-left origin).
    static func ink(for rowLayout: ClickyExplanationCardRowLayout, seed: UInt64) -> ClickyExplanationCardRowInk {
        var strokes: [ClickyHandDrawnStroke] = []
        var firstPartIndexByElementIndex: [Int: Int] = [:]
        var partIndexesDrawnInMarkerInk: Set<Int> = []
        var nextPartIndex = 0

        for (elementIndex, element) in rowLayout.elements.enumerated() {
            let elementShape: ClickyDrawingShape
            let isDrawnInMarkerInk: Bool
            switch element {
            case .box(_, let frame, _):
                elementShape = .box(
                    topLeftCorner: ClickyDrawingPoint(x: Double(frame.minX), y: Double(frame.minY)),
                    size: ClickyDrawingSize(width: Double(frame.width), height: Double(frame.height))
                )
                isDrawnInMarkerInk = false
            case .arrow(let tail, let head):
                elementShape = .arrow(
                    tail: ClickyDrawingPoint(x: Double(tail.x), y: Double(tail.y)),
                    head: ClickyDrawingPoint(x: Double(head.x), y: Double(head.y))
                )
                isDrawnInMarkerInk = true
            case .timelineLine(let start, let end):
                elementShape = .underline(
                    start: ClickyDrawingPoint(x: Double(start.x), y: Double(start.y)),
                    end: ClickyDrawingPoint(x: Double(end.x), y: Double(end.y))
                )
                isDrawnInMarkerInk = true
            case .textLine, .timelinePoint:
                continue
            }

            let elementStrokes = ClickyHandDrawnPathGenerator.strokes(
                forShapeInDisplayPoints: elementShape,
                seed: seed &+ UInt64(truncatingIfNeeded: elementIndex + 1) &* 0x6C8E_9CF5_7093_2BD5,
                maximumWobbleDistance: maximumWobbleDistanceOnCardInPoints
            )
            // An element's own parts are numbered from 0 (an arrow's shaft is 0, its head 1). In
            // the row they follow the parts of the elements before them.
            let partCountOfElement = (elementStrokes.map(\.partIndex).max() ?? 0) + 1
            firstPartIndexByElementIndex[elementIndex] = nextPartIndex
            for elementStroke in elementStrokes {
                let partIndexInRow = nextPartIndex + elementStroke.partIndex
                strokes.append(ClickyHandDrawnStroke(
                    points: elementStroke.points,
                    passIndex: elementStroke.passIndex,
                    partIndex: partIndexInRow,
                    highlighterBandWidthInPoints: nil
                ))
                if isDrawnInMarkerInk {
                    partIndexesDrawnInMarkerInk.insert(partIndexInRow)
                }
            }
            nextPartIndex += partCountOfElement
        }

        return ClickyExplanationCardRowInk(
            strokes: strokes,
            firstPartIndexByElementIndex: firstPartIndexByElementIndex,
            partIndexesDrawnInMarkerInk: partIndexesDrawnInMarkerInk
        )
    }

    /// How far the pen travels to write a row once. The schedule turns it into the time the row
    /// takes to appear. A line of words counts by its width, so a long line is not written in a
    /// flash.
    static func penTravelLengthInPoints(for rowLayout: ClickyExplanationCardRowLayout) -> Double {
        var penTravelLength = 0.0
        for element in rowLayout.elements {
            switch element {
            case .textLine(_, let frame):
                penTravelLength += Double(frame.width)
            case .box(_, let frame, _):
                penTravelLength += 2 * Double(frame.width + frame.height)
            case .arrow(let tail, let head):
                let shaftLength = Double(hypot(head.x - tail.x, head.y - tail.y))
                penTravelLength += shaftLength + 2 * ClickyHandDrawnPathGenerator.arrowheadLengthInPoints(forShaftLength: shaftLength)
            case .timelineLine(let start, let end):
                penTravelLength += Double(hypot(end.x - start.x, end.y - start.y))
            case .timelinePoint:
                break
            }
        }
        return penTravelLength
    }
}

// MARK: - Where the card goes on the screen

/// The app, not the model, places the card: in the right third of the screen, or in the left
/// third when what this reply marks is mostly on the right, always fully on the screen.
nonisolated enum ClickyExplanationCardPlacement {
    /// The card is kept this far inside every screen edge and below the menu bar.
    static let screenEdgeMarginInPoints: Double = 16

    /// True when more than half of the places this reply marks are on the right half of the
    /// display, so a card on the right would cover what is being explained. With nothing marked
    /// the card stays on the right.
    static func marksAreMostlyOnRightHalf(markAnchorXsInDisplayPoints: [Double], displayWidthInPoints: Double) -> Bool {
        guard !markAnchorXsInDisplayPoints.isEmpty else {
            return false
        }
        let anchorCountOnRightHalf = markAnchorXsInDisplayPoints.filter { $0 > displayWidthInPoints / 2 }.count
        return anchorCountOnRightHalf * 2 > markAnchorXsInDisplayPoints.count
    }

    /// The card's frame on the display, in points from the display's top-left corner: centred in
    /// the right (or left) third and centred from top to bottom, then moved to be fully on the
    /// screen below the menu bar.
    static func cardFrame(
        forCardSize cardSize: CGSize,
        displaySizeInPoints: CGSize,
        menuBarHeightInPoints: Double,
        placesCardInLeftThird: Bool
    ) -> CGRect {
        let displayWidth = Double(displaySizeInPoints.width)
        let middleXOfChosenThird = placesCardInLeftThird ? displayWidth / 6 : displayWidth * 5 / 6
        let wantedOrigin = CGPoint(
            x: middleXOfChosenThird - Double(cardSize.width) / 2,
            y: (Double(displaySizeInPoints.height) - Double(cardSize.height)) / 2
        )
        return frameKeptOnScreen(
            CGRect(origin: wantedOrigin, size: cardSize),
            displaySizeInPoints: displaySizeInPoints,
            menuBarHeightInPoints: menuBarHeightInPoints
        )
    }

    /// The card's frame after it has grown by a row: its top-left corner stays where it was,
    /// unless the card would then reach past the bottom of the screen, in which case it moves up.
    static func cardFrameAfterGrowing(
        from currentCardFrame: CGRect,
        toCardSize grownCardSize: CGSize,
        displaySizeInPoints: CGSize,
        menuBarHeightInPoints: Double
    ) -> CGRect {
        frameKeptOnScreen(
            CGRect(origin: currentCardFrame.origin, size: grownCardSize),
            displaySizeInPoints: displaySizeInPoints,
            menuBarHeightInPoints: menuBarHeightInPoints
        )
    }

    /// Moves a frame so all of it is inside the margins. When it is larger than the room there is,
    /// its top-left corner wins: the title must stay readable.
    static func frameKeptOnScreen(_ frame: CGRect, displaySizeInPoints: CGSize, menuBarHeightInPoints: Double) -> CGRect {
        let smallestAllowedX = screenEdgeMarginInPoints
        let largestAllowedX = Double(displaySizeInPoints.width) - Double(frame.width) - screenEdgeMarginInPoints
        let smallestAllowedY = max(0, menuBarHeightInPoints) + screenEdgeMarginInPoints
        let largestAllowedY = Double(displaySizeInPoints.height) - Double(frame.height) - screenEdgeMarginInPoints
        return CGRect(
            x: max(smallestAllowedX, min(Double(frame.minX), largestAllowedX)),
            y: max(smallestAllowedY, min(Double(frame.minY), largestAllowedY)),
            width: frame.width,
            height: frame.height
        )
    }
}

// MARK: - Where a numbered callout goes

/// A callout is a small numbered tag joined by a leader line to the place it is about. The model
/// only names that place; the tag is put a short distance away, on the side with more room, where
/// it covers neither the place itself nor another callout.
nonisolated enum ClickyCalloutPlacement {
    /// A callout is a few words. Longer text is cut, not rejected, like a label.
    static let maximumCalloutCharacterCount = 28

    /// How far the nearest part of the tag is from the place it points at: close enough to belong
    /// to it, far enough not to cover what is around it.
    static let distanceFromTargetInPoints: Double = 46

    /// Tags are kept this far inside every screen edge and below the menu bar.
    static let screenEdgeMarginInPoints: Double = 8

    /// Two tags (or a tag and the card) are kept at least this far apart.
    static let gapBetweenTagsInPoints: Double = 6

    /// The leader line stops this far short of the place, so its arrowhead points at the thing
    /// without lying on top of it.
    static let leaderGapAtTargetInPoints: Double = 6

    /// The room kept clear around the place another callout points at, so a later tag does not
    /// cover it.
    static let clearRadiusAroundOtherTargetsInPoints: Double = 14

    /// The directions a tag can be put in, seen from the place it points at, best first.
    /// `horizontalSign` and `verticalSign` are 1 or -1 and say which side has more room. A tag
    /// beside the place and a little above or below it reads best, so the slanted directions come
    /// first and lean more sideways than up or down.
    static func candidateDirections(horizontalSignTowardsRoom: Double, verticalSignTowardsRoom: Double) -> [(x: Double, y: Double)] {
        let sidewaysShare = 0.8
        let upOrDownShare = 0.6
        return [
            (horizontalSignTowardsRoom * sidewaysShare, verticalSignTowardsRoom * upOrDownShare),
            (horizontalSignTowardsRoom * sidewaysShare, -verticalSignTowardsRoom * upOrDownShare),
            (horizontalSignTowardsRoom, 0),
            (0, verticalSignTowardsRoom),
            (-horizontalSignTowardsRoom * sidewaysShare, verticalSignTowardsRoom * upOrDownShare),
            (0, -verticalSignTowardsRoom),
            (-horizontalSignTowardsRoom * sidewaysShare, -verticalSignTowardsRoom * upOrDownShare),
            (-horizontalSignTowardsRoom, 0),
        ]
    }

    /// The tag's frame, in points from the display's top-left corner.
    ///
    /// The first direction whose tag is fully on the screen and touches nothing in
    /// `occupiedFrames` wins. When every direction touches something, the one that overlaps least
    /// is used. The tag never covers the place it points at.
    static func tagFrame(
        forTargetInDisplayPoints target: CGPoint,
        tagSize: CGSize,
        displaySizeInPoints: CGSize,
        menuBarHeightInPoints: Double,
        occupiedFrames: [CGRect]
    ) -> CGRect {
        let horizontalSignTowardsRoom: Double = Double(target.x) < Double(displaySizeInPoints.width) / 2 ? 1 : -1
        let verticalSignTowardsRoom: Double = Double(target.y) < Double(displaySizeInPoints.height) / 2 ? 1 : -1

        let allowedArea = CGRect(
            x: screenEdgeMarginInPoints,
            y: max(0, menuBarHeightInPoints) + screenEdgeMarginInPoints,
            width: Double(displaySizeInPoints.width) - 2 * screenEdgeMarginInPoints,
            height: Double(displaySizeInPoints.height) - max(0, menuBarHeightInPoints) - 2 * screenEdgeMarginInPoints
        )

        var bestFallbackFrame: CGRect?
        var smallestOverlapArea = Double.greatestFiniteMagnitude

        for candidateDirection in candidateDirections(
            horizontalSignTowardsRoom: horizontalSignTowardsRoom,
            verticalSignTowardsRoom: verticalSignTowardsRoom
        ) {
            // The tag's centre is pushed out along the direction until the part of the tag that
            // faces the place is the wanted distance from it.
            let halfExtentAlongDirection = abs(candidateDirection.x) * Double(tagSize.width) / 2
                + abs(candidateDirection.y) * Double(tagSize.height) / 2
            let directionLength = (candidateDirection.x * candidateDirection.x + candidateDirection.y * candidateDirection.y).squareRoot()
            let distanceToTagCentre = distanceFromTargetInPoints + halfExtentAlongDirection / directionLength
            let candidateFrame = CGRect(
                x: Double(target.x) + candidateDirection.x / directionLength * distanceToTagCentre - Double(tagSize.width) / 2,
                y: Double(target.y) + candidateDirection.y / directionLength * distanceToTagCentre - Double(tagSize.height) / 2,
                width: Double(tagSize.width),
                height: Double(tagSize.height)
            )

            let isFullyOnScreen = allowedArea.contains(candidateFrame)
            let overlapArea = totalOverlapArea(of: candidateFrame, with: occupiedFrames)
            if isFullyOnScreen && overlapArea == 0 {
                return candidateFrame
            }

            // Kept as a fallback: the same tag pulled back onto the screen, as long as that does
            // not put it on top of the place it points at.
            let frameMovedOntoScreen = frameMoved(candidateFrame, inside: allowedArea)
            let frameCoversTarget = frameMovedOntoScreen.insetBy(dx: -leaderGapAtTargetInPoints, dy: -leaderGapAtTargetInPoints).contains(target)
            guard !frameCoversTarget else {
                continue
            }
            let overlapAreaOnScreen = totalOverlapArea(of: frameMovedOntoScreen, with: occupiedFrames)
            if overlapAreaOnScreen < smallestOverlapArea {
                smallestOverlapArea = overlapAreaOnScreen
                bestFallbackFrame = frameMovedOntoScreen
            }
        }

        if let bestFallbackFrame {
            return bestFallbackFrame
        }
        // Only on a display too small to hold a tag beside the place at all: below it, as is.
        return CGRect(
            x: Double(target.x) - Double(tagSize.width) / 2,
            y: Double(target.y) + distanceFromTargetInPoints,
            width: Double(tagSize.width),
            height: Double(tagSize.height)
        )
    }

    /// The leader line: from the point of the tag's edge nearest the place, to just short of the
    /// place. Returns nil when the tag is so close that no line fits between them.
    static func leaderLine(fromTagFrame tagFrame: CGRect, toTargetInDisplayPoints target: CGPoint) -> (start: CGPoint, end: CGPoint)? {
        let nearestPointOnTag = CGPoint(
            x: max(tagFrame.minX, min(target.x, tagFrame.maxX)),
            y: max(tagFrame.minY, min(target.y, tagFrame.maxY))
        )
        let distanceToTarget = Double(hypot(target.x - nearestPointOnTag.x, target.y - nearestPointOnTag.y))
        guard distanceToTarget > leaderGapAtTargetInPoints + 4 else {
            return nil
        }
        let shareOfTheWayToStop = (distanceToTarget - leaderGapAtTargetInPoints) / distanceToTarget
        return (
            start: nearestPointOnTag,
            end: CGPoint(
                x: Double(nearestPointOnTag.x) + Double(target.x - nearestPointOnTag.x) * shareOfTheWayToStop,
                y: Double(nearestPointOnTag.y) + Double(target.y - nearestPointOnTag.y) * shareOfTheWayToStop
            )
        )
    }

    /// The square kept clear around a place a callout points at.
    static func clearFrame(aroundTarget target: CGPoint) -> CGRect {
        CGRect(
            x: Double(target.x) - clearRadiusAroundOtherTargetsInPoints,
            y: Double(target.y) - clearRadiusAroundOtherTargetsInPoints,
            width: 2 * clearRadiusAroundOtherTargetsInPoints,
            height: 2 * clearRadiusAroundOtherTargetsInPoints
        )
    }

    private static func totalOverlapArea(of frame: CGRect, with occupiedFrames: [CGRect]) -> Double {
        // The gap is added around the tag, so "touches nothing" means "at least the gap apart".
        let frameWithGap = frame.insetBy(dx: -gapBetweenTagsInPoints, dy: -gapBetweenTagsInPoints)
        var totalOverlapArea = 0.0
        for occupiedFrame in occupiedFrames {
            let overlap = frameWithGap.intersection(occupiedFrame)
            if !overlap.isNull {
                totalOverlapArea += Double(overlap.width * overlap.height)
            }
        }
        return totalOverlapArea
    }

    private static func frameMoved(_ frame: CGRect, inside allowedArea: CGRect) -> CGRect {
        CGRect(
            x: max(allowedArea.minX, min(frame.minX, allowedArea.maxX - frame.width)),
            y: max(allowedArea.minY, min(frame.minY, allowedArea.maxY - frame.height)),
            width: frame.width,
            height: frame.height
        )
    }
}
