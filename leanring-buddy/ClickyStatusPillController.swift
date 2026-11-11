//
//  ClickyStatusPillController.swift
//  leanring-buddy
//
//  The status pill: a small dark pill at the top centre of the screen that says what Clicky is
//  doing ("listening", "thinking", "speaking", "dictating") next to a small live indicator. On a
//  display with a notch it hangs from the notch; otherwise it sits just below the menu bar.
//
//  It lives in its own small panel that never takes focus and never receives clicks. Everything
//  in it is a plain Core Animation layer in a plain AppKit view. Nothing here is SwiftUI and
//  nothing is placed inside an NSHostingView: views added inside a hosting view are not shown,
//  which once hid every mark Clicky drew.
//

import AppKit
import QuartzCore
import SwiftUI

/// The pill's window. Borderless, see-through, above the menu bar, on every Space and over
/// full-screen apps. It can never become the key or main window, so showing it cannot take the
/// keyboard away from the app the user is typing in.
final class ClickyStatusPillPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 26),
            // A non-activating panel can be shown without making Clicky the active application.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Clicks go straight through to whatever is underneath (the menu bar, a browser tab).
        ignoresMouseEvents = true
        // The status bar level is just above the menu bar, so the pill can overlap the menu bar's
        // lower edge under a notch, while menus that open from the menu bar still cover it.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Clicky is almost never the active application; the pill must stay visible anyway.
        hidesOnDeactivate = false
        // The panel is kept for the life of the app and only ordered in and out.
        isReleasedWhenClosed = false
        // No window-server zoom or fade of its own: the pill's layer does the fading.
        animationBehavior = .none
        // Keeps the pill out of screenshots and screen sharing. Clicky's own screenshots already
        // leave out every window of this app; this covers every other capture as well.
        sharingType = .none
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// The panel's content: a plain view that only hosts the pill's layers.
final class ClickyStatusPillContentView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The view hosts its own plain layer (set before wantsLayer), so AppKit leaves the
        // layer's contents alone and the pill's layers can simply be added to it.
        layer = CALayer()
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClickyStatusPillContentView is only created in code")
    }

    /// The panel already ignores the mouse. Returning nil here as well makes sure this view can
    /// never be the reason a click fails to reach the app underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class ClickyStatusPillController {

    /// The design system's pill sizes, in the form the placement maths takes them.
    static let layoutMetrics = ClickyStatusPillMetrics(
        heightInPoints: Double(DS.StatusPill.heightInPoints),
        horizontalPaddingInPoints: Double(DS.StatusPill.horizontalPaddingInPoints),
        indicatorWidthInPoints: Double(DS.StatusPill.indicatorWidthInPoints),
        indicatorToTextGapInPoints: Double(DS.StatusPill.indicatorToTextGapInPoints),
        maximumWidthInPoints: Double(DS.StatusPill.maximumWidthInPoints),
        gapBelowMenuBarInPoints: Double(DS.StatusPill.gapBelowMenuBarInPoints),
        notchOverlapInPoints: Double(DS.StatusPill.notchOverlapInPoints),
        screenEdgeMarginInPoints: Double(DS.StatusPill.screenEdgeMarginInPoints)
    )

    private static let fadeAnimationKey = "clickyStatusPillFade"

    // MARK: - State

    /// Created the first time the pill is shown and then kept for the life of the app.
    private var statusPillPanel: ClickyStatusPillPanel?
    private var pillContainerLayer: CALayer?

    /// What the pill shows right now. nil while it is hidden (or fading out).
    private var shownContent: ClickyStatusPillContent?
    private var shownPlacement: ClickyStatusPillPlacement?

    /// The bars of the listening indicator, kept so the microphone level can move them.
    private var listeningBarLayers: [CALayer] = []

    /// Counts every show and hide. The work that takes the panel off the screen after a fade
    /// carries the number it was scheduled with and does nothing if the pill was shown again
    /// in the meantime.
    private var visibilityGeneration = 0

    // MARK: - Showing and hiding

    /// Shows the pill with this content on this screen, fading it in if it was hidden. Called
    /// again with other content while visible, it changes the word and indicator in place.
    func show(_ content: ClickyStatusPillContent, onScreen screen: NSScreen) {
        let screenGeometry = Self.screenGeometry(for: screen)
        let attributedWord = ClickyStatusPillLayerBuilder.attributedWord(for: content.word)
        let pillSize = ClickyStatusPillLayout.pillSize(
            forTextWidthInPoints: Double(ceil(attributedWord.size().width)),
            hasIndicator: content.indicator != .none,
            metrics: Self.layoutMetrics
        )
        let placement = ClickyStatusPillLayout.placement(
            forPillSize: pillSize,
            screenGeometry: screenGeometry,
            metrics: Self.layoutMetrics
        )

        let wasHidden = shownContent == nil
        // The same word in the same place needs no rebuilding. Rebuilding anyway would restart
        // the indicator's animation and make it stutter.
        guard wasHidden || content != shownContent || placement != shownPlacement else {
            return
        }

        visibilityGeneration += 1
        shownContent = content
        shownPlacement = placement

        let statusPillPanel = existingOrNewStatusPillPanel()
        statusPillPanel.setFrame(placement.frame, display: false)
        if let pillContainerLayer {
            listeningBarLayers = ClickyStatusPillLayerBuilder.layOutPill(
                on: pillContainerLayer,
                content: content,
                pillSize: placement.frame.size,
                hangsFromNotch: placement.hangsFromNotch,
                backingScaleFactor: screen.backingScaleFactor
            )
        }

        // Ordering front without activating: the panel appears, the user's app keeps the keyboard.
        statusPillPanel.orderFrontRegardless()
        if wasHidden {
            fadePill(toOpacity: 1)
        }
    }

    /// Fades the pill out and then takes its panel off the screen. The panel itself is kept.
    func hide() {
        guard shownContent != nil else { return }
        shownContent = nil
        shownPlacement = nil
        visibilityGeneration += 1
        let generationWhenHidden = visibilityGeneration

        fadePill(toOpacity: 0)

        // A work item on the main queue, like the drawing overlay uses: it runs on the main
        // thread and so may touch the panel directly.
        let orderOutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.visibilityGeneration == generationWhenHidden else { return }
            self.statusPillPanel?.orderOut(nil)
            // Nothing keeps animating while the pill is off the screen.
            self.listeningBarLayers.removeAll()
            if let pillContainerLayer = self.pillContainerLayer {
                ClickyStatusPillLayerBuilder.removeContentLayers(from: pillContainerLayer)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + DS.StatusPill.fadeSeconds, execute: orderOutWorkItem)
    }

    /// Moves the listening bars to the microphone level (0 to 1). Does nothing unless the bars
    /// are showing, so it is cheap to call for every level the microphone reports.
    func updateListeningAudioPowerLevel(_ audioPowerLevel: CGFloat) {
        guard !listeningBarLayers.isEmpty else { return }
        CATransaction.begin()
        // A short glide to the new height instead of a jump, so the bars look fluid between
        // level reports.
        CATransaction.setAnimationDuration(DS.StatusPill.barLevelChangeSeconds)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (barIndex, listeningBarLayer) in listeningBarLayers.enumerated() {
            listeningBarLayer.bounds.size.height = ClickyStatusPillLayerBuilder.listeningBarHeight(
                forBarIndex: barIndex,
                audioPowerLevel: audioPowerLevel
            )
        }
        CATransaction.commit()
    }

    /// Lets Clicky's own proof picture (the drawing self test) contain the pill. Normally the
    /// pill is hidden from every capture; the self test is the one place where seeing it in a
    /// capture is the point.
    func setVisibleInScreenCapturesForSelfTest(_ isVisibleInScreenCaptures: Bool) {
        existingOrNewStatusPillPanel().sharingType = isVisibleInScreenCaptures ? .readOnly : .none
    }

    // MARK: - Panel and layers

    private func existingOrNewStatusPillPanel() -> ClickyStatusPillPanel {
        if let statusPillPanel {
            return statusPillPanel
        }
        let newStatusPillPanel = ClickyStatusPillPanel()
        let contentView = ClickyStatusPillContentView(frame: NSRect(origin: .zero, size: newStatusPillPanel.frame.size))
        newStatusPillPanel.contentView = contentView

        let newPillContainerLayer = CALayer()
        // Invisible until the first fade-in.
        newPillContainerLayer.opacity = 0
        contentView.layer?.addSublayer(newPillContainerLayer)

        pillContainerLayer = newPillContainerLayer
        statusPillPanel = newStatusPillPanel
        return newStatusPillPanel
    }

    /// Fades the pill from whatever is on screen right now, which may be the middle of the
    /// opposite fade, so a quick hide-then-show never flickers.
    private func fadePill(toOpacity targetOpacity: Float) {
        guard let pillContainerLayer else { return }
        let opacityOnScreenNow = pillContainerLayer.presentation()?.opacity ?? pillContainerLayer.opacity

        let fadeAnimation = CABasicAnimation(keyPath: "opacity")
        fadeAnimation.fromValue = opacityOnScreenNow
        fadeAnimation.toValue = targetOpacity
        fadeAnimation.duration = DS.StatusPill.fadeSeconds
        fadeAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillContainerLayer.opacity = targetOpacity
        pillContainerLayer.add(fadeAnimation, forKey: Self.fadeAnimationKey)
        CATransaction.commit()
    }

    /// Reads from a screen the few numbers the placement maths needs.
    static func screenGeometry(for screen: NSScreen) -> ClickyStatusPillScreenGeometry {
        ClickyStatusPillScreenGeometry(
            screenFrame: screen.frame,
            safeAreaTopInsetInPoints: Double(screen.safeAreaInsets.top),
            auxiliaryTopLeftAreaWidthInPoints: screen.auxiliaryTopLeftArea.map { Double($0.width) },
            auxiliaryTopRightAreaWidthInPoints: screen.auxiliaryTopRightArea.map { Double($0.width) },
            // The visible frame leaves out the menu bar (and the Dock, which is never at the
            // top), so the difference at the top edge is the menu bar's height on this screen.
            menuBarHeightInPoints: Double(max(0, screen.frame.maxY - screen.visibleFrame.maxY))
        )
    }
}

/// Builds the pill's layers: the dark shape, the word, and the three live indicators. Kept
/// apart from the controller so the same layers can be rendered offscreen by the checks.
@MainActor
enum ClickyStatusPillLayerBuilder {
    private static let indicatorAnimationKey = "clickyStatusPillIndicator"

    /// Takes the pill's shape, indicator and word off and stops their animations.
    static func removeContentLayers(from pillContainerLayer: CALayer) {
        for contentLayer in pillContainerLayer.sublayers ?? [] {
            contentLayer.removeAllAnimations()
            contentLayer.removeFromSuperlayer()
        }
    }

    /// Lays the pill out for new content: the dark shape, the indicator, the word. Returns
    /// the bars of the listening indicator (empty for every other indicator), so the caller can
    /// move them with the microphone level.
    @discardableResult
    static func layOutPill(
        on pillContainerLayer: CALayer,
        content: ClickyStatusPillContent,
        pillSize: CGSize,
        hangsFromNotch: Bool,
        backingScaleFactor: CGFloat
    ) -> [CALayer] {
        // Laying out must not start Core Animation's automatic animations: the word would slide
        // to its new place instead of simply being there.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        removeContentLayers(from: pillContainerLayer)
        var listeningBarLayers: [CALayer] = []

        pillContainerLayer.frame = CGRect(origin: .zero, size: pillSize)
        pillContainerLayer.addSublayer(makePillShapeLayer(pillSize: pillSize, hangsFromNotch: hangsFromNotch, backingScaleFactor: backingScaleFactor))

        var nextContentX = DS.StatusPill.horizontalPaddingInPoints

        if content.indicator != .none {
            let indicatorContainerLayer = CALayer()
            indicatorContainerLayer.frame = CGRect(
                x: nextContentX,
                y: (pillSize.height - DS.StatusPill.indicatorHeightInPoints) / 2,
                width: DS.StatusPill.indicatorWidthInPoints,
                height: DS.StatusPill.indicatorHeightInPoints
            )
            pillContainerLayer.addSublayer(indicatorContainerLayer)

            let indicatorAccentColor = accentColor(for: content.accent)
            switch content.indicator {
            case .listeningBars:
                listeningBarLayers = addListeningBars(to: indicatorContainerLayer, accentColor: indicatorAccentColor)
            case .thinkingDots:
                addThinkingDots(to: indicatorContainerLayer, accentColor: indicatorAccentColor)
            case .speakingWave:
                addSpeakingWave(to: indicatorContainerLayer, accentColor: indicatorAccentColor, backingScaleFactor: backingScaleFactor)
            case .none:
                break
            }
            nextContentX += DS.StatusPill.indicatorWidthInPoints + DS.StatusPill.indicatorToTextGapInPoints
        }

        // Whatever room is left after the padding; a notice too long for it is cut off with an ellipsis.
        let wordWidth = max(0, pillSize.width - nextContentX - DS.StatusPill.horizontalPaddingInPoints)
        let attributedWordToShow = attributedWord(for: content.word, fittingWidthInPoints: wordWidth)
        let wordHeight = ceil(attributedWordToShow.size().height)

        let wordLayer = CATextLayer()
        wordLayer.string = attributedWordToShow
        wordLayer.frame = CGRect(
            x: nextContentX,
            y: (pillSize.height - wordHeight) / 2,
            width: wordWidth,
            height: wordHeight
        )
        // Without the screen's scale the text would be drawn at one pixel per point and look blurry.
        wordLayer.contentsScale = backingScaleFactor
        pillContainerLayer.addSublayer(wordLayer)

        return listeningBarLayers
    }

    /// The dark shape of the pill. Below a menu bar it is a capsule with a faint edge. Under a
    /// notch it is flat on top, where it joins the notch, and rounded below, in the notch's own
    /// black and with no edge (an edge would draw a line between the notch and the pill).
    ///
    /// It is drawn as a path. A layer's own corner rounding could do the same with "masked
    /// corners", but drawing the outline keeps the shape identical wherever the layer is rendered,
    /// including the offscreen pictures the checks make.
    private static func makePillShapeLayer(pillSize: CGSize, hangsFromNotch: Bool, backingScaleFactor: CGFloat) -> CAShapeLayer {
        let pillShapeLayer = CAShapeLayer()
        pillShapeLayer.frame = CGRect(origin: .zero, size: pillSize)
        pillShapeLayer.contentsScale = backingScaleFactor

        if hangsFromNotch {
            let cornerRadius = min(DS.StatusPill.notchCornerRadiusInPoints, pillSize.height / 2, pillSize.width / 2)
            // A layer's y grows upwards on the Mac: y = height is the flat top edge under the
            // notch, y = 0 is the rounded bottom edge.
            let hangingPillPath = CGMutablePath()
            hangingPillPath.move(to: CGPoint(x: 0, y: pillSize.height))
            hangingPillPath.addLine(to: CGPoint(x: 0, y: cornerRadius))
            hangingPillPath.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: cornerRadius, y: 0), radius: cornerRadius)
            hangingPillPath.addLine(to: CGPoint(x: pillSize.width - cornerRadius, y: 0))
            hangingPillPath.addArc(tangent1End: CGPoint(x: pillSize.width, y: 0), tangent2End: CGPoint(x: pillSize.width, y: cornerRadius), radius: cornerRadius)
            hangingPillPath.addLine(to: CGPoint(x: pillSize.width, y: pillSize.height))
            hangingPillPath.closeSubpath()
            pillShapeLayer.path = hangingPillPath
            pillShapeLayer.fillColor = NSColor(DS.Colors.overlayStatusPillNotchBackground).cgColor
            pillShapeLayer.strokeColor = nil
        } else {
            // The edge is drawn centred on the path, so the path is moved in by half the edge's
            // width to keep the whole edge inside the pill.
            let halfBorderWidth = DS.StatusPill.borderWidthInPoints / 2
            let capsuleRect = CGRect(origin: .zero, size: pillSize).insetBy(dx: halfBorderWidth, dy: halfBorderWidth)
            let capsuleCornerRadius = min(capsuleRect.height, capsuleRect.width) / 2
            pillShapeLayer.path = CGPath(roundedRect: capsuleRect, cornerWidth: capsuleCornerRadius, cornerHeight: capsuleCornerRadius, transform: nil)
            pillShapeLayer.fillColor = NSColor(DS.Colors.overlayStatusPillBackground)
                .withAlphaComponent(DS.StatusPill.backgroundOpacity).cgColor
            pillShapeLayer.strokeColor = NSColor(DS.Colors.overlayStatusPillBorder).cgColor
            pillShapeLayer.lineWidth = DS.StatusPill.borderWidthInPoints
        }
        return pillShapeLayer
    }

    // MARK: - Indicators (every movement is a looping Core Animation; no timers, no SwiftUI)

    static func listeningBarHeight(forBarIndex barIndex: Int, audioPowerLevel: CGFloat) -> CGFloat {
        let barHeightShare = ClickyStatusPillLayout.listeningBarHeightShare(
            forBarIndex: barIndex,
            barCount: DS.StatusPill.barCount,
            audioPowerLevel: Double(audioPowerLevel)
        )
        return DS.StatusPill.barMinimumHeightInPoints
            + (DS.StatusPill.barMaximumHeightInPoints - DS.StatusPill.barMinimumHeightInPoints) * CGFloat(barHeightShare)
    }

    /// A few thin bars. Their height is set from the microphone level as it is reported
    /// (`updateListeningAudioPowerLevel`); on top of that each bar breathes slightly in a loop,
    /// one after the other, so the indicator is alive even in silence.
    private static func addListeningBars(to indicatorContainerLayer: CALayer, accentColor: CGColor) -> [CALayer] {
        var listeningBarLayers: [CALayer] = []
        let barCount = DS.StatusPill.barCount
        let widthOfAllBars = CGFloat(barCount) * DS.StatusPill.barWidthInPoints
            + CGFloat(barCount - 1) * DS.StatusPill.barSpacingInPoints
        let firstBarCenterX = (indicatorContainerLayer.bounds.width - widthOfAllBars) / 2 + DS.StatusPill.barWidthInPoints / 2

        for barIndex in 0..<barCount {
            let listeningBarLayer = CALayer()
            listeningBarLayer.backgroundColor = accentColor
            listeningBarLayer.cornerRadius = DS.StatusPill.barWidthInPoints / 2
            listeningBarLayer.bounds = CGRect(
                x: 0,
                y: 0,
                width: DS.StatusPill.barWidthInPoints,
                height: listeningBarHeight(forBarIndex: barIndex, audioPowerLevel: 0)
            )
            // Positioned by its centre, so a bar grows up and down from the middle of the pill.
            listeningBarLayer.position = CGPoint(
                x: firstBarCenterX + CGFloat(barIndex) * (DS.StatusPill.barWidthInPoints + DS.StatusPill.barSpacingInPoints),
                y: indicatorContainerLayer.bounds.midY
            )

            let idlePulseAnimation = CABasicAnimation(keyPath: "transform.scale.y")
            idlePulseAnimation.fromValue = DS.StatusPill.barIdlePulseSmallestScale
            idlePulseAnimation.toValue = DS.StatusPill.barIdlePulseLargestScale
            idlePulseAnimation.duration = DS.StatusPill.barIdlePulseSeconds
            idlePulseAnimation.autoreverses = true
            idlePulseAnimation.repeatCount = .infinity
            idlePulseAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Starting each bar a little further into the same loop makes the pulse ripple
            // across the bars instead of all of them moving together.
            idlePulseAnimation.timeOffset = Double(barIndex) * DS.StatusPill.barIdlePulseStaggerSeconds
            listeningBarLayer.add(idlePulseAnimation, forKey: indicatorAnimationKey)

            indicatorContainerLayer.addSublayer(listeningBarLayer)
            listeningBarLayers.append(listeningBarLayer)
        }
        return listeningBarLayers
    }

    /// Three dots that brighten and grow one after the other, in a loop.
    private static func addThinkingDots(to indicatorContainerLayer: CALayer, accentColor: CGColor) {
        let dotCount = DS.StatusPill.dotCount
        let widthOfAllDots = CGFloat(dotCount) * DS.StatusPill.dotDiameterInPoints
            + CGFloat(dotCount - 1) * DS.StatusPill.dotSpacingInPoints
        let firstDotCenterX = (indicatorContainerLayer.bounds.width - widthOfAllDots) / 2 + DS.StatusPill.dotDiameterInPoints / 2

        for dotIndex in 0..<dotCount {
            let dotLayer = CALayer()
            dotLayer.backgroundColor = accentColor
            dotLayer.cornerRadius = DS.StatusPill.dotDiameterInPoints / 2
            dotLayer.bounds = CGRect(x: 0, y: 0, width: DS.StatusPill.dotDiameterInPoints, height: DS.StatusPill.dotDiameterInPoints)
            dotLayer.position = CGPoint(
                x: firstDotCenterX + CGFloat(dotIndex) * (DS.StatusPill.dotDiameterInPoints + DS.StatusPill.dotSpacingInPoints),
                y: indicatorContainerLayer.bounds.midY
            )
            dotLayer.opacity = DS.StatusPill.dotDimmestOpacity

            // Bright for a third of the loop, dim for the rest: with three dots a third of a
            // loop apart, one dot is always lit and the light walks from left to right.
            let brightenAnimation = CAKeyframeAnimation(keyPath: "opacity")
            brightenAnimation.values = [DS.StatusPill.dotDimmestOpacity, 1, DS.StatusPill.dotDimmestOpacity, DS.StatusPill.dotDimmestOpacity]
            brightenAnimation.keyTimes = [0, 0.25, 0.55, 1]
            let growAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
            growAnimation.values = [DS.StatusPill.dotSmallestScale, 1, DS.StatusPill.dotSmallestScale, DS.StatusPill.dotSmallestScale]
            growAnimation.keyTimes = [0, 0.25, 0.55, 1]

            let pulseAnimationGroup = CAAnimationGroup()
            pulseAnimationGroup.animations = [brightenAnimation, growAnimation]
            pulseAnimationGroup.duration = DS.StatusPill.dotPulseCycleSeconds
            pulseAnimationGroup.repeatCount = .infinity
            pulseAnimationGroup.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // A later dot is earlier in the loop, so it lights up after the dot to its left.
            pulseAnimationGroup.timeOffset = DS.StatusPill.dotPulseCycleSeconds
                - Double(dotIndex) * DS.StatusPill.dotPulseStaggerSeconds
            dotLayer.add(pulseAnimationGroup, forKey: indicatorAnimationKey)

            indicatorContainerLayer.addSublayer(dotLayer)
        }
    }

    /// One smooth wave line that keeps travelling to the left. The line is drawn one wave longer
    /// than the indicator is wide and slid left by exactly one wave, over and over; because the
    /// picture after one wave is the same as at the start, the loop has no visible seam.
    private static func addSpeakingWave(to indicatorContainerLayer: CALayer, accentColor: CGColor, backingScaleFactor: CGFloat) {
        // Only the part of the line inside the indicator's room is shown.
        indicatorContainerLayer.masksToBounds = true

        let waveLength = DS.StatusPill.waveLengthInPoints
        let waveHalfHeight = DS.StatusPill.waveHeightInPoints / 2
        let waveMiddleY = indicatorContainerLayer.bounds.midY
        let waveLineEndX = indicatorContainerLayer.bounds.width + waveLength

        let wavePath = CGMutablePath()
        let horizontalStepInPoints: CGFloat = 0.5
        var waveLineX: CGFloat = 0
        wavePath.move(to: CGPoint(x: 0, y: waveMiddleY))
        while waveLineX <= waveLineEndX {
            let waveLineY = waveMiddleY + waveHalfHeight * sin(2 * .pi * waveLineX / waveLength)
            wavePath.addLine(to: CGPoint(x: waveLineX, y: waveLineY))
            waveLineX += horizontalStepInPoints
        }

        let waveLineLayer = CAShapeLayer()
        waveLineLayer.frame = CGRect(x: 0, y: 0, width: waveLineEndX, height: indicatorContainerLayer.bounds.height)
        waveLineLayer.path = wavePath
        waveLineLayer.fillColor = nil
        waveLineLayer.strokeColor = accentColor
        waveLineLayer.lineWidth = DS.StatusPill.waveLineWidthInPoints
        waveLineLayer.lineCap = .round
        waveLineLayer.lineJoin = .round
        waveLineLayer.contentsScale = backingScaleFactor

        let travelAnimation = CABasicAnimation(keyPath: "transform.translation.x")
        travelAnimation.fromValue = 0
        travelAnimation.toValue = -waveLength
        travelAnimation.duration = DS.StatusPill.waveTravelSecondsPerWaveLength
        travelAnimation.repeatCount = .infinity
        // Linear, or the wave would slow down and speed up once per loop.
        travelAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        waveLineLayer.add(travelAnimation, forKey: indicatorAnimationKey)

        indicatorContainerLayer.addSublayer(waveLineLayer)
    }

    // MARK: - Helpers

    private static func accentColor(for accent: ClickyStatusPillAccent) -> CGColor {
        switch accent {
        case .asking:
            return NSColor(DS.Colors.overlayCursorBlue).cgColor
        case .dictating:
            return NSColor(DS.Colors.overlayDictationAccent).cgColor
        }
    }

    static func attributedWord(for word: String) -> NSAttributedString {
        NSAttributedString(string: word, attributes: [
            .font: NSFont.systemFont(ofSize: DS.StatusPill.textFontSizeInPoints, weight: .medium),
            .foregroundColor: NSColor(DS.Colors.overlayStatusPillText),
        ])
    }

    /// The word as it is shown in a pill with this much room for it: whole when it fits,
    /// otherwise shortened from the end and finished with an ellipsis. The cutting is done here
    /// and not left to the text layer, so the pill never shows an empty space where a long
    /// notice should be.
    static func attributedWord(for word: String, fittingWidthInPoints availableWidthInPoints: CGFloat) -> NSAttributedString {
        let wholeAttributedWord = attributedWord(for: word)
        // Half a point of slack: the pill's width was rounded up from this same measurement.
        guard wholeAttributedWord.size().width > availableWidthInPoints + 0.5 else {
            return wholeAttributedWord
        }
        var shortenedWord = word
        while !shortenedWord.isEmpty {
            shortenedWord.removeLast()
            let shortenedAttributedWord = attributedWord(
                for: shortenedWord.trimmingCharacters(in: .whitespaces) + "…"
            )
            if shortenedAttributedWord.size().width <= availableWidthInPoints + 0.5 {
                return shortenedAttributedWord
            }
        }
        return attributedWord(for: "")
    }
}
