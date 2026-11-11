import Foundation

/// A small random number generator that always gives the same numbers for the same seed
/// (the SplitMix64 mixing steps). The wobble of a mark comes from it, so a mark looks the same
/// every time it is built and the tests can check exact results.
nonisolated struct ClickyDeterministicRandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixedValue = state
        mixedValue = (mixedValue ^ (mixedValue >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixedValue = (mixedValue ^ (mixedValue >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixedValue ^ (mixedValue >> 31)
    }

    /// A number from 0 up to, but not including, 1.
    mutating func nextUnitInterval() -> Double {
        // The top 53 bits fill a Double's precision exactly.
        Double(nextUInt64() >> 11) / Double(UInt64(1) << 53)
    }

    mutating func nextValue(between lowerBound: Double, and upperBound: Double) -> Double {
        lowerBound + (upperBound - lowerBound) * nextUnitInterval()
    }

    /// Either -1 or 1.
    mutating func nextSign() -> Double {
        nextUnitInterval() < 0.5 ? -1 : 1
    }
}

/// One pen stroke of a mark: the points the pen passes through, in order.
nonisolated struct ClickyHandDrawnStroke: Equatable {
    /// In display points, origin at the display's top-left corner.
    let points: [ClickyDrawingPoint]
    /// 0 for the first pass of the pen, 1 for the second pass drawn over it.
    let passIndex: Int
    /// The order in which the parts of a mark are drawn: an arrow's shaft is part 0 and its head
    /// is part 1. Every other shape has only part 0.
    let partIndex: Int
    /// Set for a highlight: the stroke is one wide translucent band of this width. nil for ink.
    let highlighterBandWidthInPoints: Double?

    /// The length of the path through the points.
    var lengthInPoints: Double {
        var totalLength = 0.0
        for pointIndex in points.indices.dropFirst() {
            totalLength += ClickyHandDrawnPathGenerator.distance(from: points[pointIndex - 1], to: points[pointIndex])
        }
        return totalLength
    }
}

/// Turns an ideal shape into slightly wobbly pen strokes, the way a person draws on a whiteboard:
/// lines that are almost straight, a circle that overshoots where it started, and every stroke gone
/// over twice so the two passes do not quite line up.
///
/// Pure numbers in, pure numbers out. The overlay turns the points into Core Animation paths.
nonisolated enum ClickyHandDrawnPathGenerator {
    /// No point of a stroke is farther than this from the ideal shape, so a mark still clearly
    /// circles or underlines the thing it is about.
    static let maximumWobbleDistanceInPoints: Double = 2.5

    /// A short stroke gets less wobble than a long one, or a small circle would look crumpled.
    /// The wobble allowed is this share of the stroke's size, within the two limits below.
    static let wobbleShareOfStrokeSize: Double = 0.05
    static let minimumWobbleDistanceInPoints: Double = 0.8

    /// About one point every this many points of pen travel: enough for the wobble to be smooth,
    /// few enough to stay cheap.
    static let pointSpacingInPoints: Double = 14
    static let minimumPointCountPerLine = 5
    static let maximumPointCountPerLine = 40
    static let minimumPointCountPerCircle = 24
    static let maximumPointCountPerCircle = 96

    /// Each stroke is drawn twice with different wobble.
    static let passCount = 2

    /// A hand-drawn circle does not close exactly: the pen runs a little past where it started.
    static let minimumCircleOvershootShareOfFullTurn: Double = 0.03
    static let maximumCircleOvershootShareOfFullTurn: Double = 0.08

    /// The two short strokes of an arrowhead: their length as a share of the shaft (within limits)
    /// and how far each one opens away from the shaft.
    static let arrowheadLengthShareOfShaft: Double = 0.28
    static let minimumArrowheadLengthInPoints: Double = 10
    static let maximumArrowheadLengthInPoints: Double = 22
    static let arrowheadHalfAngleInRadians: Double = 0.45

    /// A highlight is a wide band, where sideways wobble shows as a ragged edge. It gets less.
    static let maximumHighlightWobbleDistanceInPoints: Double = 1.0

    /// The seed of a mark's wobble. It depends only on the mark's number, so the same mark is
    /// always drawn the same way, and two marks never share their wobble.
    static func seed(forMarkNumber markNumber: Int) -> UInt64 {
        UInt64(truncatingIfNeeded: markNumber) &* 0x2545_F491_4F6C_DD1D &+ 0x0C11_C4B1
    }

    /// The strokes of a shape given in display points. A label or sticky note has no strokes: it
    /// is text on a card, not ink.
    static func strokes(forShapeInDisplayPoints shape: ClickyDrawingShape, seed: UInt64) -> [ClickyHandDrawnStroke] {
        var strokes: [ClickyHandDrawnStroke] = []

        for passIndex in 0..<passCount {
            // Each pass gets its own stream of random numbers, so the second pass is a different
            // wobble of the same shape and not a copy of the first.
            var randomNumberGenerator = ClickyDeterministicRandomNumberGenerator(
                seed: seed &+ UInt64(passIndex) &* 0x9E37_79B9
            )

            switch shape {
            case .underline(let start, let end):
                strokes.append(ClickyHandDrawnStroke(
                    points: wobblyLinePoints(from: start, to: end, maximumWobbleDistance: maximumWobbleDistanceInPoints, randomNumberGenerator: &randomNumberGenerator),
                    passIndex: passIndex,
                    partIndex: 0,
                    highlighterBandWidthInPoints: nil
                ))

            case .arrow(let tail, let head):
                strokes.append(ClickyHandDrawnStroke(
                    points: wobblyLinePoints(from: tail, to: head, maximumWobbleDistance: maximumWobbleDistanceInPoints, randomNumberGenerator: &randomNumberGenerator),
                    passIndex: passIndex,
                    partIndex: 0,
                    highlighterBandWidthInPoints: nil
                ))
                let arrowheadBarbEnds = arrowheadBarbEnds(tail: tail, head: head)
                // One stroke: in from the first barb to the tip, then out along the second barb.
                let firstBarbPoints = wobblyLinePoints(from: arrowheadBarbEnds.first, to: head, maximumWobbleDistance: minimumWobbleDistanceInPoints, randomNumberGenerator: &randomNumberGenerator)
                let secondBarbPoints = wobblyLinePoints(from: head, to: arrowheadBarbEnds.second, maximumWobbleDistance: minimumWobbleDistanceInPoints, randomNumberGenerator: &randomNumberGenerator)
                strokes.append(ClickyHandDrawnStroke(
                    points: firstBarbPoints + secondBarbPoints,
                    passIndex: passIndex,
                    partIndex: 1,
                    highlighterBandWidthInPoints: nil
                ))

            case .circle(let center, let radius):
                strokes.append(ClickyHandDrawnStroke(
                    points: wobblyCirclePoints(center: center, radius: radius, randomNumberGenerator: &randomNumberGenerator),
                    passIndex: passIndex,
                    partIndex: 0,
                    highlighterBandWidthInPoints: nil
                ))

            case .box(let topLeftCorner, let size):
                // One stroke around the four sides, clockwise from the top-left corner. Each side
                // has its own wobble, so the corners do not quite meet, as with a real pen.
                let cornerPoints = boxCornerPoints(topLeftCorner: topLeftCorner, size: size)
                var boxPoints: [ClickyDrawingPoint] = []
                for cornerIndex in cornerPoints.indices {
                    let sideStart = cornerPoints[cornerIndex]
                    let sideEnd = cornerPoints[(cornerIndex + 1) % cornerPoints.count]
                    boxPoints += wobblyLinePoints(from: sideStart, to: sideEnd, maximumWobbleDistance: maximumWobbleDistanceInPoints, randomNumberGenerator: &randomNumberGenerator)
                }
                strokes.append(ClickyHandDrawnStroke(points: boxPoints, passIndex: passIndex, partIndex: 0, highlighterBandWidthInPoints: nil))

            case .highlight(let topLeftCorner, let size):
                let highlightBandLine = highlightBandLine(topLeftCorner: topLeftCorner, size: size)
                strokes.append(ClickyHandDrawnStroke(
                    points: wobblyLinePoints(from: highlightBandLine.start, to: highlightBandLine.end, maximumWobbleDistance: maximumHighlightWobbleDistanceInPoints, randomNumberGenerator: &randomNumberGenerator),
                    passIndex: passIndex,
                    partIndex: 0,
                    highlighterBandWidthInPoints: size.height
                ))

            case .label, .stickyNote:
                break
            }
        }

        return strokes
    }

    /// How far the pen travels to draw the shape once (one pass), without wobble. The schedule
    /// uses it to decide how long the drawing takes. 0 for a label or sticky note.
    static func penTravelLengthInPoints(forShapeInDisplayPoints shape: ClickyDrawingShape) -> Double {
        switch shape {
        case .underline(let start, let end):
            return distance(from: start, to: end)
        case .arrow(let tail, let head):
            return distance(from: tail, to: head) + 2 * arrowheadLengthInPoints(forShaftLength: distance(from: tail, to: head))
        case .circle(_, let radius):
            return 2 * Double.pi * radius
        case .box(_, let size):
            return 2 * (size.width + size.height)
        case .highlight(_, let size):
            return size.width
        case .label, .stickyNote:
            return 0
        }
    }

    // MARK: - Ideal geometry (also used by the tests to measure the wobble against)

    static func distance(from firstPoint: ClickyDrawingPoint, to secondPoint: ClickyDrawingPoint) -> Double {
        let horizontalDistance = secondPoint.x - firstPoint.x
        let verticalDistance = secondPoint.y - firstPoint.y
        return (horizontalDistance * horizontalDistance + verticalDistance * verticalDistance).squareRoot()
    }

    /// Top-left, top-right, bottom-right, bottom-left.
    static func boxCornerPoints(topLeftCorner: ClickyDrawingPoint, size: ClickyDrawingSize) -> [ClickyDrawingPoint] {
        [
            topLeftCorner,
            ClickyDrawingPoint(x: topLeftCorner.x + size.width, y: topLeftCorner.y),
            ClickyDrawingPoint(x: topLeftCorner.x + size.width, y: topLeftCorner.y + size.height),
            ClickyDrawingPoint(x: topLeftCorner.x, y: topLeftCorner.y + size.height),
        ]
    }

    /// The centre line of a highlight band. The band is drawn as one wide stroke with round ends,
    /// and a round end reaches half the band's height past the line's end, so the line is pulled
    /// in by that much on each side to keep the band inside the rectangle that was asked for.
    static func highlightBandLine(topLeftCorner: ClickyDrawingPoint, size: ClickyDrawingSize) -> (start: ClickyDrawingPoint, end: ClickyDrawingPoint) {
        let middleY = topLeftCorner.y + size.height / 2
        // A band narrower than it is tall has no room to pull in, so it becomes a short dab.
        let pullInDistance = min(size.height / 2, size.width / 2 - 0.5)
        let safePullInDistance = max(0, pullInDistance)
        return (
            ClickyDrawingPoint(x: topLeftCorner.x + safePullInDistance, y: middleY),
            ClickyDrawingPoint(x: topLeftCorner.x + size.width - safePullInDistance, y: middleY)
        )
    }

    static func arrowheadLengthInPoints(forShaftLength shaftLength: Double) -> Double {
        max(minimumArrowheadLengthInPoints, min(maximumArrowheadLengthInPoints, shaftLength * arrowheadLengthShareOfShaft))
    }

    /// Where the two short strokes of the arrowhead end, on either side of the shaft.
    static func arrowheadBarbEnds(tail: ClickyDrawingPoint, head: ClickyDrawingPoint) -> (first: ClickyDrawingPoint, second: ClickyDrawingPoint) {
        let shaftLength = distance(from: tail, to: head)
        let arrowheadLength = arrowheadLengthInPoints(forShaftLength: shaftLength)
        // The direction from the head back towards the tail, turned to either side.
        let backwardAngle = atan2(tail.y - head.y, tail.x - head.x)
        let firstBarbAngle = backwardAngle + arrowheadHalfAngleInRadians
        let secondBarbAngle = backwardAngle - arrowheadHalfAngleInRadians
        return (
            ClickyDrawingPoint(x: head.x + arrowheadLength * cos(firstBarbAngle), y: head.y + arrowheadLength * sin(firstBarbAngle)),
            ClickyDrawingPoint(x: head.x + arrowheadLength * cos(secondBarbAngle), y: head.y + arrowheadLength * sin(secondBarbAngle))
        )
    }

    // MARK: - Wobble

    /// How far a stroke of this size may stray from its ideal shape.
    static func wobbleDistance(forStrokeSizeInPoints strokeSizeInPoints: Double, maximumWobbleDistance: Double) -> Double {
        let wobbleFromSize = strokeSizeInPoints * wobbleShareOfStrokeSize
        return min(maximumWobbleDistance, max(min(minimumWobbleDistanceInPoints, maximumWobbleDistance), wobbleFromSize))
    }

    /// A slow drift plus a faster, smaller tremor: two sine waves with random strength and phase.
    /// Their strengths add up to at most 90% of the allowed wobble, which leaves room for the
    /// stroke starting or ending slightly off its end point.
    private struct WobbleProfile {
        let slowDriftStrength: Double
        let slowDriftCycles: Double
        let slowDriftPhase: Double
        let fastTremorStrength: Double
        let fastTremorCycles: Double
        let fastTremorPhase: Double

        init(allowedWobbleDistance: Double, randomNumberGenerator: inout ClickyDeterministicRandomNumberGenerator) {
            slowDriftStrength = allowedWobbleDistance * randomNumberGenerator.nextValue(between: 0.35, and: 0.6) * randomNumberGenerator.nextSign()
            slowDriftCycles = randomNumberGenerator.nextValue(between: 0.5, and: 1.5)
            slowDriftPhase = randomNumberGenerator.nextUnitInterval()
            fastTremorStrength = allowedWobbleDistance * randomNumberGenerator.nextValue(between: 0.1, and: 0.3) * randomNumberGenerator.nextSign()
            fastTremorCycles = randomNumberGenerator.nextValue(between: 2, and: 3.5)
            fastTremorPhase = randomNumberGenerator.nextUnitInterval()
        }

        /// The sideways offset at a position along the stroke, from 0 (start) to 1 (end).
        func sidewaysOffset(atShareOfStroke shareOfStroke: Double) -> Double {
            slowDriftStrength * sin(2 * Double.pi * (slowDriftCycles * shareOfStroke + slowDriftPhase))
                + fastTremorStrength * sin(2 * Double.pi * (fastTremorCycles * shareOfStroke + fastTremorPhase))
        }
    }

    /// The share of the allowed wobble a stroke may start before, or stop short of, its end point.
    private static let endPointSlackShareOfWobble: Double = 0.4

    private static func wobblyLinePoints(
        from startPoint: ClickyDrawingPoint,
        to endPoint: ClickyDrawingPoint,
        maximumWobbleDistance: Double,
        randomNumberGenerator: inout ClickyDeterministicRandomNumberGenerator
    ) -> [ClickyDrawingPoint] {
        let lineLength = distance(from: startPoint, to: endPoint)
        guard lineLength > 0 else {
            return [startPoint, endPoint]
        }

        let allowedWobbleDistance = wobbleDistance(forStrokeSizeInPoints: lineLength, maximumWobbleDistance: maximumWobbleDistance)
        let wobbleProfile = WobbleProfile(allowedWobbleDistance: allowedWobbleDistance, randomNumberGenerator: &randomNumberGenerator)
        let endPointSlack = allowedWobbleDistance * endPointSlackShareOfWobble
        // Positive: the pen starts a little before the start point (or runs a little past the end).
        let distanceStartedBeforeStartPoint = randomNumberGenerator.nextValue(between: -endPointSlack, and: endPointSlack)
        let distanceRunPastEndPoint = randomNumberGenerator.nextValue(between: -endPointSlack, and: endPointSlack)

        let directionX = (endPoint.x - startPoint.x) / lineLength
        let directionY = (endPoint.y - startPoint.y) / lineLength
        // Perpendicular to the line: the direction the wobble pushes the pen.
        let sidewaysX = -directionY
        let sidewaysY = directionX

        let pointCount = max(minimumPointCountPerLine, min(maximumPointCountPerLine, Int(lineLength / pointSpacingInPoints) + 2))
        let penTravelLength = lineLength + distanceStartedBeforeStartPoint + distanceRunPastEndPoint

        var linePoints: [ClickyDrawingPoint] = []
        for pointIndex in 0..<pointCount {
            let shareOfStroke = Double(pointIndex) / Double(pointCount - 1)
            let distanceAlongLine = -distanceStartedBeforeStartPoint + shareOfStroke * penTravelLength
            let sidewaysOffset = wobbleProfile.sidewaysOffset(atShareOfStroke: shareOfStroke)
            linePoints.append(ClickyDrawingPoint(
                x: startPoint.x + directionX * distanceAlongLine + sidewaysX * sidewaysOffset,
                y: startPoint.y + directionY * distanceAlongLine + sidewaysY * sidewaysOffset
            ))
        }
        return linePoints
    }

    private static func wobblyCirclePoints(
        center: ClickyDrawingPoint,
        radius: Double,
        randomNumberGenerator: inout ClickyDeterministicRandomNumberGenerator
    ) -> [ClickyDrawingPoint] {
        let allowedWobbleDistance = wobbleDistance(forStrokeSizeInPoints: 2 * radius, maximumWobbleDistance: maximumWobbleDistanceInPoints)
        let wobbleProfile = WobbleProfile(allowedWobbleDistance: allowedWobbleDistance, randomNumberGenerator: &randomNumberGenerator)

        // A person starts a circle somewhere near the top and goes round past the starting point.
        let startAngle = randomNumberGenerator.nextValue(between: -0.75 * Double.pi, and: -0.25 * Double.pi)
        let overshootShareOfFullTurn = randomNumberGenerator.nextValue(
            between: minimumCircleOvershootShareOfFullTurn,
            and: maximumCircleOvershootShareOfFullTurn
        )
        let sweptAngle = 2 * Double.pi * (1 + overshootShareOfFullTurn)

        let circumference = 2 * Double.pi * radius
        let pointCount = max(minimumPointCountPerCircle, min(maximumPointCountPerCircle, Int(circumference / pointSpacingInPoints) + 1))

        var circlePoints: [ClickyDrawingPoint] = []
        for pointIndex in 0..<pointCount {
            let shareOfStroke = Double(pointIndex) / Double(pointCount - 1)
            let angle = startAngle + shareOfStroke * sweptAngle
            // The wobble moves the pen towards or away from the centre.
            let wobblyRadius = radius + wobbleProfile.sidewaysOffset(atShareOfStroke: shareOfStroke)
            circlePoints.append(ClickyDrawingPoint(
                x: center.x + wobblyRadius * cos(angle),
                y: center.y + wobblyRadius * sin(angle)
            ))
        }
        return circlePoints
    }
}
