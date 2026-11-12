import Foundation

/// One leg of the pen's journey while a mark is drawn: the points the pen tip passes through and
/// when, as shares of the mark's whole pen time. An arrow has two legs (the shaft, then the head);
/// every other inked shape has one.
nonisolated struct ClickyDrawingPenPathPart: Equatable {
    /// The same number as the `partIndex` of the strokes this leg follows.
    let partIndex: Int
    /// In display points, origin at the display's top-left corner. These are exactly the points
    /// of the first pass of the stroke, so the pen tip sits on the ink it is laying down.
    let points: [ClickyDrawingPoint]
    /// From 0 to 1: when, within the mark's pen time, the pen starts and finishes this leg.
    let startShareOfPenTime: Double
    let endShareOfPenTime: Double
}

/// Where the pen tip is while a mark is being drawn, and the outline of the pen tip itself.
///
/// Pure numbers in, pure numbers out, like the path generator next to it. The overlay turns the
/// points into Core Animation paths and animations; the tests check the numbers directly.
nonisolated enum ClickyDrawingPenPath {

    // MARK: - Timing

    /// The share of the pen time each part of a mark gets: in proportion to the length of its
    /// first-pass stroke, in the order the parts are drawn. The ink reveal and the pen both use
    /// this one function, so the pen can never run ahead of or behind the line it is drawing.
    static func timeSharesByPartIndex(
        forStrokes handDrawnStrokes: [ClickyHandDrawnStroke]
    ) -> [Int: (startShareOfPenTime: Double, endShareOfPenTime: Double)] {
        let firstPassStrokesInDrawingOrder = handDrawnStrokes
            .filter { $0.passIndex == 0 }
            .sorted { $0.partIndex < $1.partIndex }
        // Never zero, so a mark whose strokes have no length still gets valid shares.
        let totalFirstPassLength = max(1, firstPassStrokesInDrawingOrder.reduce(0) { $0 + $1.lengthInPoints })

        var timeSharesByPartIndex: [Int: (startShareOfPenTime: Double, endShareOfPenTime: Double)] = [:]
        var shareOfPenTimeUsedSoFar = 0.0
        for firstPassStroke in firstPassStrokesInDrawingOrder {
            let partShareOfPenTime = firstPassStroke.lengthInPoints / totalFirstPassLength
            timeSharesByPartIndex[firstPassStroke.partIndex] = (
                startShareOfPenTime: shareOfPenTimeUsedSoFar,
                endShareOfPenTime: shareOfPenTimeUsedSoFar + partShareOfPenTime
            )
            shareOfPenTimeUsedSoFar += partShareOfPenTime
        }
        return timeSharesByPartIndex
    }

    // MARK: - Path

    /// The legs of the pen's journey for a mark's strokes, in the order they are drawn. The pen
    /// follows the first pass only: the second pass is the same line gone over again, and a pen
    /// jumping back to the start for it would look like a glitch. Empty for a label or sticky
    /// note, which have no strokes.
    static func parts(forStrokes handDrawnStrokes: [ClickyHandDrawnStroke]) -> [ClickyDrawingPenPathPart] {
        let timeSharesByPartIndex = timeSharesByPartIndex(forStrokes: handDrawnStrokes)
        return handDrawnStrokes
            .filter { $0.passIndex == 0 && !$0.points.isEmpty }
            .sorted { $0.partIndex < $1.partIndex }
            .compactMap { firstPassStroke in
                guard let partTimeShares = timeSharesByPartIndex[firstPassStroke.partIndex] else {
                    return nil
                }
                return ClickyDrawingPenPathPart(
                    partIndex: firstPassStroke.partIndex,
                    points: firstPassStroke.points,
                    startShareOfPenTime: partTimeShares.startShareOfPenTime,
                    endShareOfPenTime: partTimeShares.endShareOfPenTime
                )
            }
    }

    /// The legs of the pen's journey for a shape given in display points, wobbled with the same
    /// seed as the mark itself.
    static func parts(forShapeInDisplayPoints shape: ClickyDrawingShape, seed: UInt64) -> [ClickyDrawingPenPathPart] {
        parts(forStrokes: ClickyHandDrawnPathGenerator.strokes(forShapeInDisplayPoints: shape, seed: seed))
    }

    // MARK: - The pen tip (our own design)

    /// The nib is a narrow five-sided tip, like the end of a felt pen seen from the side: a point
    /// that widens to the barrel, then a short piece of barrel.
    static let nibBarrelHalfWidthInPoints: Double = 3.4
    /// How far above the point the nib reaches its full width.
    static let nibShoulderHeightInPoints: Double = 7.5
    /// The full length of the nib, from its point to the flat end of the barrel piece.
    static let nibLengthInPoints: Double = 17

    /// The pen leans to the right like one held in a right hand, by this much from upright. It
    /// keeps this lean for the whole stroke (a hand does not spin the pen as it draws), which is
    /// also why the pen needs no rotation animation.
    static let nibTiltFromUprightInDegrees: Double = 32

    /// The outline of the nib around its point, which is at (0, 0). In display directions: x grows
    /// to the right and y grows downwards, so the body of the pen has negative y. The outline
    /// starts at the point and is closed by joining its last corner back to the first.
    static func nibOutlinePoints() -> [ClickyDrawingPoint] {
        let uprightOutlinePoints = [
            ClickyDrawingPoint(x: 0, y: 0),
            ClickyDrawingPoint(x: nibBarrelHalfWidthInPoints, y: -nibShoulderHeightInPoints),
            ClickyDrawingPoint(x: nibBarrelHalfWidthInPoints, y: -nibLengthInPoints),
            ClickyDrawingPoint(x: -nibBarrelHalfWidthInPoints, y: -nibLengthInPoints),
            ClickyDrawingPoint(x: -nibBarrelHalfWidthInPoints, y: -nibShoulderHeightInPoints),
        ]
        // Turning clockwise as seen on screen (y grows downwards) leans the top of the pen to the right.
        let tiltInRadians = nibTiltFromUprightInDegrees * Double.pi / 180
        return uprightOutlinePoints.map { uprightOutlinePoint in
            ClickyDrawingPoint(
                x: uprightOutlinePoint.x * cos(tiltInRadians) - uprightOutlinePoint.y * sin(tiltInRadians),
                y: uprightOutlinePoint.x * sin(tiltInRadians) + uprightOutlinePoint.y * cos(tiltInRadians)
            )
        }
    }
}
