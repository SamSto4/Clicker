import Foundation

/// How a screenshot's pixels map onto the display it was taken of. Claude's coordinates are pixels
/// of the (scaled-down) screenshot; the overlay works in the display's points. Both have their
/// origin at the top-left corner.
///
/// This is the one mapping used by pointing and by drawing, so a mark lands exactly where the
/// blue cursor would point for the same coordinates.
nonisolated struct ClickyScreenshotToDisplayMapping: Equatable {
    let screenshotWidthInPixels: Double
    let screenshotHeightInPixels: Double
    let displayWidthInPoints: Double
    let displayHeightInPoints: Double

    var horizontalPointsPerScreenshotPixel: Double {
        displayWidthInPoints / screenshotWidthInPixels
    }

    var verticalPointsPerScreenshotPixel: Double {
        displayHeightInPoints / screenshotHeightInPixels
    }

    /// A screenshot pixel as a position on the display, in points from the display's top-left
    /// corner. A coordinate outside the screenshot is first pulled back to its nearest edge.
    func displayPointFromTopLeft(forScreenshotPixel screenshotPixel: ClickyDrawingPoint) -> ClickyDrawingPoint {
        let clampedPixelX = max(0, min(screenshotPixel.x, screenshotWidthInPixels))
        let clampedPixelY = max(0, min(screenshotPixel.y, screenshotHeightInPixels))
        return ClickyDrawingPoint(
            x: clampedPixelX * horizontalPointsPerScreenshotPixel,
            y: clampedPixelY * verticalPointsPerScreenshotPixel
        )
    }

    /// The same shape in display points (origin top-left), ready to be drawn. Positions are
    /// clamped to the screenshot, and a box or highlight is shortened so it ends at the screen
    /// edge instead of running off it.
    func shapeInDisplayPoints(forShapeInScreenshotPixels shape: ClickyDrawingShape) -> ClickyDrawingShape {
        switch shape {
        case .arrow(let tail, let head):
            return .arrow(
                tail: displayPointFromTopLeft(forScreenshotPixel: tail),
                head: displayPointFromTopLeft(forScreenshotPixel: head)
            )
        case .underline(let start, let end):
            return .underline(
                start: displayPointFromTopLeft(forScreenshotPixel: start),
                end: displayPointFromTopLeft(forScreenshotPixel: end)
            )
        case .circle(let center, let radius):
            // The two scales are equal up to rounding (the screenshot keeps the display's aspect
            // ratio), so their average keeps a circle a circle.
            let averagePointsPerScreenshotPixel = (horizontalPointsPerScreenshotPixel + verticalPointsPerScreenshotPixel) / 2
            return .circle(
                center: displayPointFromTopLeft(forScreenshotPixel: center),
                radius: radius * averagePointsPerScreenshotPixel
            )
        case .box(let topLeftCorner, let size):
            let displayTopLeftCorner = displayPointFromTopLeft(forScreenshotPixel: topLeftCorner)
            return .box(topLeftCorner: displayTopLeftCorner, size: displaySize(for: size, startingAt: displayTopLeftCorner))
        case .highlight(let topLeftCorner, let size):
            let displayTopLeftCorner = displayPointFromTopLeft(forScreenshotPixel: topLeftCorner)
            return .highlight(topLeftCorner: displayTopLeftCorner, size: displaySize(for: size, startingAt: displayTopLeftCorner))
        case .label(let topLeftCorner, let text):
            return .label(topLeftCorner: displayPointFromTopLeft(forScreenshotPixel: topLeftCorner), text: text)
        case .stickyNote(let topLeftCorner, let text):
            return .stickyNote(topLeftCorner: displayPointFromTopLeft(forScreenshotPixel: topLeftCorner), text: text)
        case .callout(let target, let text, let calloutNumber):
            return .callout(target: displayPointFromTopLeft(forScreenshotPixel: target), text: text, calloutNumber: calloutNumber)
        case .explanationCard:
            // The card holds no screenshot coordinates: the app places it on the display.
            return shape
        }
    }

    private func displaySize(for sizeInScreenshotPixels: ClickyDrawingSize, startingAt displayTopLeftCorner: ClickyDrawingPoint) -> ClickyDrawingSize {
        let scaledWidth = sizeInScreenshotPixels.width * horizontalPointsPerScreenshotPixel
        let scaledHeight = sizeInScreenshotPixels.height * verticalPointsPerScreenshotPixel
        // At least one point is kept so a shape that starts on the very edge still has a size.
        return ClickyDrawingSize(
            width: max(1, min(scaledWidth, displayWidthInPoints - displayTopLeftCorner.x)),
            height: max(1, min(scaledHeight, displayHeightInPoints - displayTopLeftCorner.y))
        )
    }

    /// Which of this turn's screenshots a tag means. The same rule pointing uses: a valid
    /// `screenN` picks that screenshot, anything else means the screen the cursor is on.
    /// Returns nil when there is no screenshot to draw on.
    static func screenshotIndex(forScreenNumber screenNumber: Int?, screenshotCount: Int, cursorScreenshotIndex: Int?) -> Int? {
        if let screenNumber, screenNumber >= 1, screenNumber <= screenshotCount {
            return screenNumber - 1
        }
        if let cursorScreenshotIndex, cursorScreenshotIndex >= 0, cursorScreenshotIndex < screenshotCount {
            return cursorScreenshotIndex
        }
        return nil
    }
}

/// When one draw command happens, counted from the moment the voice starts.
nonisolated struct ClickyDrawingScheduledTime: Equatable {
    let startSecondsAfterSpeechBegins: Double
    /// How long the pen takes to draw the mark. For a label or sticky note, how long it takes to
    /// appear. Not used by erase, undo and clear, which only fade something out.
    let penDurationSeconds: Double
}

/// Decides when each mark of a reply is drawn. There is one audio request for the whole spoken
/// text and no word timings, so the time of a tag is estimated from how far into the text it sits.
nonisolated enum ClickyDrawingSchedule {
    /// A mark drawn faster than this is a flash the eye cannot follow.
    static let minimumPenDurationSeconds: Double = 0.3

    /// A mark drawn slower than this is still being drawn while the next sentence is spoken.
    static let maximumPenDurationSeconds: Double = 1.4

    /// How fast the pen moves between the floor and the ceiling: about the speed of a hand
    /// circling something on a whiteboard.
    static let penSpeedInPointsPerSecond: Double = 700

    /// With no audio (speech failed, or the reply had no words) there is nothing to pace against,
    /// so the marks follow each other at a steady, readable beat.
    static let secondsBetweenMarksWithoutAudio: Double = 0.35

    /// Two tags written after the same sentence would start in the same instant. A small gap lets
    /// the eye see them begin one after the other, in the order they were written.
    static let minimumSecondsBetweenMarkStarts: Double = 0.12

    static func penDurationSeconds(forPenTravelLengthInPoints penTravelLengthInPoints: Double) -> Double {
        let unclampedPenDurationSeconds = penTravelLengthInPoints / penSpeedInPointsPerSecond
        return max(minimumPenDurationSeconds, min(maximumPenDurationSeconds, unclampedPenDurationSeconds))
    }

    /// One scheduled time per command, in the same order.
    ///
    /// With audio, a command starts at (its share of the spoken text) x (the audio's length), so a
    /// mark is drawn as the sentence before it ends. Start times never go backwards and never pass
    /// the end of the audio. Without audio, the commands are `secondsBetweenMarksWithoutAudio`
    /// apart, starting at once.
    ///
    /// `penTravelLengthsInPoints` holds one length per command (0 for anything that is not a
    /// stroke); a missing entry counts as 0.
    static func scheduledTimes(
        forSpokenFractionsBeforeTags spokenFractionsBeforeTags: [Double],
        penTravelLengthsInPoints: [Double],
        speechAudioDurationSeconds: Double?
    ) -> [ClickyDrawingScheduledTime] {
        var scheduledTimes: [ClickyDrawingScheduledTime] = []
        var previousStartSeconds: Double?

        for (commandIndex, spokenFractionBeforeTag) in spokenFractionsBeforeTags.enumerated() {
            let penTravelLengthInPoints = commandIndex < penTravelLengthsInPoints.count ? penTravelLengthsInPoints[commandIndex] : 0
            let penDurationSeconds = penDurationSeconds(forPenTravelLengthInPoints: penTravelLengthInPoints)

            let startSeconds: Double
            if let speechAudioDurationSeconds, speechAudioDurationSeconds > 0, speechAudioDurationSeconds.isFinite {
                let clampedSpokenFraction = max(0, min(1, spokenFractionBeforeTag))
                var startSecondsFromSpokenPosition = clampedSpokenFraction * speechAudioDurationSeconds
                if let previousStartSeconds {
                    startSecondsFromSpokenPosition = max(
                        startSecondsFromSpokenPosition,
                        previousStartSeconds + minimumSecondsBetweenMarkStarts
                    )
                }
                // Never after the voice has finished: the last marks then start together with the
                // last word instead of trailing behind it.
                startSeconds = min(startSecondsFromSpokenPosition, speechAudioDurationSeconds)
            } else {
                startSeconds = Double(commandIndex) * secondsBetweenMarksWithoutAudio
            }

            scheduledTimes.append(ClickyDrawingScheduledTime(
                startSecondsAfterSpeechBegins: startSeconds,
                penDurationSeconds: penDurationSeconds
            ))
            previousStartSeconds = startSeconds
        }
        return scheduledTimes
    }
}
