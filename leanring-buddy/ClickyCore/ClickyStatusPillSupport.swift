// CoreGraphics only for CGRect and CGSize, the types AppKit gives screen frames in. No AppKit here.
import CoreGraphics
import Foundation

/// The small live picture next to the word in the status pill.
nonisolated enum ClickyStatusPillIndicator: Equatable {
    /// A few bars that follow the microphone level.
    case listeningBars
    /// Three dots that light up one after the other.
    case thinkingDots
    /// A wave line that keeps travelling.
    case speakingWave
    /// Only the word (a notice such as "copied. press command v to paste.").
    case none
}

/// Which of Clicky's two features the pill is about. Asking is blue and dictating is green
/// everywhere else in the overlay, and the pill keeps to that.
nonisolated enum ClickyStatusPillAccent: Equatable {
    case asking
    case dictating
}

/// What the app's ask-Clicky state is, as the pill needs it. Mirrors `CompanionVoiceState`, which
/// lives in the app target; this copy keeps the pill's decisions testable without the app.
nonisolated enum ClickyStatusPillVoiceActivity: Equatable {
    case idle
    case listening
    case processing
    case responding
}

/// What dictation is doing, as the pill needs it. Mirrors `ClickyDictationOverlayState`.
nonisolated enum ClickyStatusPillDictationActivity: Equatable {
    case hidden
    case listening
    case listeningHandsFree
    /// The keys are up and the words are being cleaned up and pasted.
    case working
    case notice(String)
}

/// What the status pill shows: one short lowercase word (or a notice) and its indicator.
nonisolated struct ClickyStatusPillContent: Equatable {
    let word: String
    let indicator: ClickyStatusPillIndicator
    let accent: ClickyStatusPillAccent

    static let listeningWord = "listening"
    static let thinkingWord = "thinking"
    static let speakingWord = "speaking"
    static let dictatingWord = "dictating"
    static let dictatingHandsFreeWord = "dictating · hands-free"

    /// Decides what the pill shows from the state the app already has. nil means the pill is
    /// hidden, which is the case whenever Clicky is idle.
    ///
    /// What is live wins over what is finished: a dictation in progress comes first, then the ask
    /// keys being held, then Clicky working on an answer, then a dictation notice, and only then
    /// speech that is still playing. So pressing the ask keys while Clicky is still talking shows
    /// "listening" at once.
    ///
    /// `isMicrophoneStartingUp` is true for the short moment between the ask keys going down and
    /// the microphone running. The app's state calls that moment "processing"; for the user the
    /// keys are already held, so the pill says "listening" and does not flash "thinking" first.
    ///
    /// `turnFailureNoticeText` is the short notice of an ask turn that failed ("i can't reach the
    /// internet right now.", or the unspoken reply after "voice unavailable"). Like a dictation
    /// notice it gives way to anything live, and it comes before "speaking" because the error
    /// sentence is spoken by the Mac's own voice while the notice shows.
    static func content(
        voiceActivity: ClickyStatusPillVoiceActivity,
        dictationActivity: ClickyStatusPillDictationActivity,
        isMicrophoneStartingUp: Bool,
        isSpeechAudioPlaying: Bool,
        turnFailureNoticeText: String? = nil
    ) -> ClickyStatusPillContent? {
        switch dictationActivity {
        case .listening:
            return ClickyStatusPillContent(word: dictatingWord, indicator: .listeningBars, accent: .dictating)
        case .listeningHandsFree:
            return ClickyStatusPillContent(word: dictatingHandsFreeWord, indicator: .listeningBars, accent: .dictating)
        case .working:
            // The microphone is closed, so bars that follow it would sit still. The dots say
            // "almost there" while the words are cleaned up and pasted.
            return ClickyStatusPillContent(word: dictatingWord, indicator: .thinkingDots, accent: .dictating)
        case .hidden, .notice:
            break
        }

        if voiceActivity == .listening || (voiceActivity == .processing && isMicrophoneStartingUp) {
            return ClickyStatusPillContent(word: listeningWord, indicator: .listeningBars, accent: .asking)
        }
        if voiceActivity == .processing {
            return ClickyStatusPillContent(word: thinkingWord, indicator: .thinkingDots, accent: .asking)
        }
        if case .notice(let noticeText) = dictationActivity {
            let trimmedNoticeText = noticeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNoticeText.isEmpty {
                return ClickyStatusPillContent(word: trimmedNoticeText, indicator: .none, accent: .dictating)
            }
        }
        if let turnFailureNoticeText {
            let trimmedTurnFailureNoticeText = turnFailureNoticeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTurnFailureNoticeText.isEmpty {
                return ClickyStatusPillContent(word: trimmedTurnFailureNoticeText, indicator: .none, accent: .asking)
            }
        }
        if voiceActivity == .responding || isSpeechAudioPlaying {
            return ClickyStatusPillContent(word: speakingWord, indicator: .speakingWave, accent: .asking)
        }
        return nil
    }
}

/// The sizes the pill is laid out with. The values live in the design system (`DS.StatusPill`);
/// they are handed in here so the placement maths can be tested without the app.
nonisolated struct ClickyStatusPillMetrics: Equatable {
    let heightInPoints: Double
    let horizontalPaddingInPoints: Double
    let indicatorWidthInPoints: Double
    let indicatorToTextGapInPoints: Double
    let maximumWidthInPoints: Double
    let gapBelowMenuBarInPoints: Double
    let notchOverlapInPoints: Double
    let screenEdgeMarginInPoints: Double
}

/// What the pill needs to know about a screen. Everything is in points; the frame is in global
/// AppKit coordinates (origin bottom-left, y grows upwards), as `NSScreen.frame` gives it.
nonisolated struct ClickyStatusPillScreenGeometry: Equatable {
    let screenFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`: the height of the notch, 0 on a display without one.
    let safeAreaTopInsetInPoints: Double
    /// The widths of the usable strips left and right of the notch (`auxiliaryTopLeftArea`,
    /// `auxiliaryTopRightArea`). nil when the system does not report them.
    let auxiliaryTopLeftAreaWidthInPoints: Double?
    let auxiliaryTopRightAreaWidthInPoints: Double?
    /// The height of the menu bar on this screen, 0 when it is hidden or on another screen.
    let menuBarHeightInPoints: Double

    var hasNotch: Bool {
        safeAreaTopInsetInPoints > 0
    }
}

nonisolated struct ClickyStatusPillPlacement: Equatable {
    /// Where the pill goes, in global AppKit coordinates.
    let frame: CGRect
    /// True when the pill hangs from a notch: its top is then flat and joins the notch.
    let hangsFromNotch: Bool
}

nonisolated enum ClickyStatusPillLayout {
    /// How large the pill is for a word of the given width: padding, the indicator if there is
    /// one, the word, padding. Never wider than the maximum; the word is then cut off.
    static func pillSize(
        forTextWidthInPoints textWidthInPoints: Double,
        hasIndicator: Bool,
        metrics: ClickyStatusPillMetrics
    ) -> CGSize {
        let indicatorAndGapWidth = hasIndicator
            ? metrics.indicatorWidthInPoints + metrics.indicatorToTextGapInPoints
            : 0
        let wantedWidth = 2 * metrics.horizontalPaddingInPoints + indicatorAndGapWidth + max(0, textWidthInPoints)
        return CGSize(
            width: min(metrics.maximumWidthInPoints, wantedWidth.rounded(.up)),
            height: metrics.heightInPoints
        )
    }

    /// The horizontal middle of the notch. The notch is the gap between the two usable strips at
    /// the top of the screen; without those strips the notch is taken to be centred, as it is on
    /// every Mac made so far.
    static func notchCenterX(for screenGeometry: ClickyStatusPillScreenGeometry) -> Double {
        guard let auxiliaryTopLeftAreaWidthInPoints = screenGeometry.auxiliaryTopLeftAreaWidthInPoints,
              let auxiliaryTopRightAreaWidthInPoints = screenGeometry.auxiliaryTopRightAreaWidthInPoints else {
            return Double(screenGeometry.screenFrame.midX)
        }
        let notchLeftEdgeX = Double(screenGeometry.screenFrame.minX) + auxiliaryTopLeftAreaWidthInPoints
        let notchRightEdgeX = Double(screenGeometry.screenFrame.maxX) - auxiliaryTopRightAreaWidthInPoints
        guard notchRightEdgeX > notchLeftEdgeX else {
            return Double(screenGeometry.screenFrame.midX)
        }
        return (notchLeftEdgeX + notchRightEdgeX) / 2
    }

    /// Where the pill goes on a screen.
    ///
    /// With a notch it hangs directly below the notch, centred on it, starting a hair inside the
    /// notch so the two join. Without a notch it sits just below the menu bar, centred on the
    /// screen. Either way it is moved or narrowed as needed to stay inside the screen.
    static func placement(
        forPillSize pillSize: CGSize,
        screenGeometry: ClickyStatusPillScreenGeometry,
        metrics: ClickyStatusPillMetrics
    ) -> ClickyStatusPillPlacement {
        let screenFrame = screenGeometry.screenFrame
        let screenEdgeMargin = CGFloat(metrics.screenEdgeMarginInPoints)

        let widestPillThatFits = max(0, screenFrame.width - 2 * screenEdgeMargin)
        let pillWidth = min(pillSize.width, widestPillThatFits)
        let pillHeight = min(pillSize.height, screenFrame.height)

        let wantedCenterX: CGFloat
        let wantedTopY: CGFloat
        if screenGeometry.hasNotch {
            wantedCenterX = CGFloat(notchCenterX(for: screenGeometry))
            wantedTopY = screenFrame.maxY - CGFloat(screenGeometry.safeAreaTopInsetInPoints) + CGFloat(metrics.notchOverlapInPoints)
        } else {
            wantedCenterX = screenFrame.midX
            wantedTopY = screenFrame.maxY - CGFloat(max(0, screenGeometry.menuBarHeightInPoints)) - CGFloat(metrics.gapBelowMenuBarInPoints)
        }

        let smallestAllowedX = screenFrame.minX + screenEdgeMargin
        let largestAllowedX = max(smallestAllowedX, screenFrame.maxX - screenEdgeMargin - pillWidth)
        let pillOriginX = max(smallestAllowedX, min(wantedCenterX - pillWidth / 2, largestAllowedX))

        // AppKit measures upwards, so the pill's origin is its bottom edge.
        let highestAllowedOriginY = screenFrame.maxY - pillHeight
        let pillOriginY = max(screenFrame.minY, min(wantedTopY - pillHeight, highestAllowedOriginY))

        return ClickyStatusPillPlacement(
            frame: CGRect(x: pillOriginX.rounded(), y: pillOriginY.rounded(), width: pillWidth, height: pillHeight),
            hangsFromNotch: screenGeometry.hasNotch
        )
    }

    // MARK: - Listening bars

    /// The bars in the middle are taller than the ones at the sides, so the group reads as a
    /// voice and not as a row of equal sticks. This is how far each position can rise, from the
    /// middle (1) outwards.
    static func listeningBarReachShare(forBarIndex barIndex: Int, barCount: Int) -> Double {
        guard barCount > 1 else { return 1 }
        let middleBarPosition = Double(barCount - 1) / 2
        let distanceFromMiddleAsShare = abs(Double(barIndex) - middleBarPosition) / middleBarPosition
        return 1 - 0.55 * distanceFromMiddleAsShare
    }

    /// How tall a listening bar is, from 0 (its resting height) to 1 (its full height), for a
    /// microphone level between 0 and 1. Speech at a normal distance gives levels well below 1,
    /// so the level is amplified and bent upwards: quiet speech already moves the bars visibly,
    /// and loud speech cannot push them past the top.
    static func listeningBarHeightShare(forBarIndex barIndex: Int, barCount: Int, audioPowerLevel: Double) -> Double {
        let levelAboveBackgroundNoise = max(0, audioPowerLevel - 0.01)
        let amplifiedLevel = min(1, levelAboveBackgroundNoise * 3)
        let easedLevel = amplifiedLevel.squareRoot()
        return easedLevel * listeningBarReachShare(forBarIndex: barIndex, barCount: barCount)
    }
}

/// Which handwriting-style typeface Clicky's drawn text (labels and sticky notes) uses.
///
/// Only typefaces that come with macOS are named here and none is bundled. They are tried in
/// order and the first one this Mac has is used; when none is installed the caller falls back to
/// the rounded system font.
nonisolated struct ClickyDrawingHandwritingFontChoice: Equatable {
    let fontFamilyName: String
    /// Handwriting faces look smaller than the system font at the same point size and differ
    /// among themselves, so each has its own sizes, chosen to be as easy to read as the 13 point
    /// rounded system font they replace.
    let labelFontSizeInPoints: Double
    let stickyNoteFontSizeInPoints: Double

    static let candidatesInOrderOfPreference: [ClickyDrawingHandwritingFontChoice] = [
        ClickyDrawingHandwritingFontChoice(fontFamilyName: "Bradley Hand", labelFontSizeInPoints: 16, stickyNoteFontSizeInPoints: 16),
        ClickyDrawingHandwritingFontChoice(fontFamilyName: "Noteworthy", labelFontSizeInPoints: 14, stickyNoteFontSizeInPoints: 14),
        ClickyDrawingHandwritingFontChoice(fontFamilyName: "Chalkboard SE", labelFontSizeInPoints: 14, stickyNoteFontSizeInPoints: 14),
        ClickyDrawingHandwritingFontChoice(fontFamilyName: "Marker Felt", labelFontSizeInPoints: 15, stickyNoteFontSizeInPoints: 15),
    ]

    /// The sizes used with the rounded system font when no handwriting face is installed.
    static let fallbackSystemFontSizeInPoints: Double = 13

    /// The first candidate the Mac has, or nil when it has none of them.
    static func firstAvailableChoice(isFontFamilyAvailable: (String) -> Bool) -> ClickyDrawingHandwritingFontChoice? {
        candidatesInOrderOfPreference.first { isFontFamilyAvailable($0.fontFamilyName) }
    }
}
