//
//  EzraDrawingOverlayController.swift
//  leanring-buddy
//
//  Shows the marks Ezra draws on the screen (arrows, circles, boxes, underlines, highlights,
//  labels, sticky notes, numbered callouts, the explanation card and the simple 3D scene) and decides how long they stay. The marks are Core Animation layers in a
//  click-through view on top of each screen's existing overlay window, so no extra windows exist
//  and Ezra's screenshots, which already leave out all of Ezra's windows, never contain them.
//  The 3D scene is the one mark that is a view of its own (`EzraScenePanelView`, SceneKit). Since
//  round 22 it sits in a window of its own (`EzraScenePanelWindow`, at the overlay's level and never
//  the key window), so the paper can take the mouse: the model is turned, tilted and zoomed by hand.
//

import AppKit
import QuartzCore

/// A transparent view that only hosts mark layers. One sits on top of each screen's overlay.
final class EzraDrawingSurfaceView: NSView {
    /// The frame of the display this surface covers, in global AppKit coordinates. It is how a
    /// mark finds the surface of the screen it belongs to.
    let displayFrame: CGRect

    init(displayFrame: CGRect, frame: CGRect) {
        self.displayFrame = displayFrame
        super.init(frame: frame)
        // The view hosts its own plain layer (set before wantsLayer), so AppKit leaves the layer's
        // contents alone and the mark layers can simply be added to it.
        layer = CALayer()
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EzraDrawingSurfaceView is only created in code")
    }

    /// The overlay window already ignores the mouse. Returning nil here as well makes sure this
    /// view can never be the reason a click fails to reach the app underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Round 21: a spotlight's shade goes under every other mark on this surface, so the card, the
    /// callouts and the ink of the same reply stay bright on top of it.
    func insertMarkLayerBelowOthers(_ markLayer: CALayer) {
        layer?.insertSublayer(markLayer, at: 0)
    }
}

/// Where one of this turn's screenshots sits: the display it shows and how its pixels map onto it.
struct EzraDrawingDisplayPlacement {
    /// The display's frame in global AppKit coordinates, as `CompanionScreenCapture.displayFrame`.
    let displayFrame: CGRect
    let screenshotToDisplayMapping: EzraScreenshotToDisplayMapping
}

extension CompanionScreenCapture {
    /// How this screenshot's pixels map onto its display. Pointing and drawing both use it.
    var screenshotToDisplayMapping: EzraScreenshotToDisplayMapping {
        EzraScreenshotToDisplayMapping(
            screenshotWidthInPixels: Double(screenshotWidthInPixels),
            screenshotHeightInPixels: Double(screenshotHeightInPixels),
            displayWidthInPoints: Double(displayWidthInPoints),
            displayHeightInPoints: Double(displayHeightInPoints)
        )
    }
}

@MainActor
final class EzraDrawingOverlayController {

    // MARK: - Lifetime and fade timings

    /// How long each kind of mark stays after Ezra has finished speaking, then fades: the marks
    /// 12 s, the explanation card (something to read, so longer) 20 s and the 3D scene (one turn of
    /// the model takes 14 s, so longest) 25 s, as `EzraDrawingLifetimes.standard`, scaled by
    /// the "drawings stay" setting (short, normal or long) in the chat panel's settings tab. It is
    /// read when a reply ends, so a change applies from the next reply on. The 60 second limit
    /// below is a safety net for a turn that never finishes and is not scaled.
    var drawingLifetimes = EzraDrawingLifetimes.standard

    /// A turn that never finishes (the transcript was empty, a request hung) must not leave marks
    /// on the screen for ever. After this long without a finished reply they fade anyway.
    static let maximumSecondsMarksAreKeptWithoutAFinishedReply: TimeInterval = 60

    static let lifetimeFadeOutSeconds: Double = 0.6
    static let eraseFadeOutSeconds: Double = 0.25
    static let scrollFadeOutSeconds: Double = 0.3
    static let applicationSwitchFadeOutSeconds: Double = 0.2

    // MARK: - State

    /// The marks and their numbering. What is on the screen always mirrors this.
    private var drawingBoard = EzraDrawingBoard()

    private var drawingSurfaceViews: [EzraDrawingSurfaceView] = []

    /// The display each mark was drawn on. A mark has an entry from the moment its command is
    /// accepted until it is removed, so a scheduled drawing whose mark has since been removed
    /// (erased, scrolled away, cleared) finds no entry and draws nothing.
    private var displayFramesByMarkNumber: [Int: CGRect] = [:]

    /// The layers of the marks that have actually been drawn.
    private var markLayersByMarkNumber: [Int: CALayer] = [:]

    /// Where the app put the explanation card, in points from its display's top-left corner. The
    /// card has an entry from the moment its command is accepted until it is removed.
    private var explanationCardFramesFromTopLeftByMarkNumber: [Int: CGRect] = [:]

    /// The frame the explanation card was planned to have once every row of its reply is written,
    /// in points from its display's top-left corner. The 3D scene's panel keeps off this frame,
    /// because the card opens with its title alone and only grows into it.
    private var plannedFullExplanationCardFramesFromTopLeftByMarkNumber: [Int: CGRect] = [:]

    /// Where the app put the 3D scene's panel: its frame in points from its display's top-left
    /// corner, and the corner of the screen it sits in. The scene has an entry from the moment
    /// its command is accepted until it is removed.
    private var scenePanelPlacementsByMarkNumber: [Int: EzraScenePanelPlacementResult] = [:]

    /// The scene as it will be once every part accepted so far has been shown. The panel frames
    /// the model for these parts, so the camera does not move again for each part of a reply.
    private var plannedScenesByMarkNumber: [Int: EzraScene] = [:]

    /// The views of the scenes that have actually been shown.
    private var scenePanelViewsByMarkNumber: [Int: EzraScenePanelView] = [:]

    /// Round 22: the window each shown scene sits in, so its paper can take the mouse.
    private var scenePanelWindowsByMarkNumber: [Int: EzraScenePanelWindow] = [:]

    /// Round 22: a scene the user turned, zoomed or clicked stays at least until this moment (uptime
    /// clock), however its reply's countdown runs: each touch makes it the full scene lifetime again.
    private var sceneKeptUntilUptimeSecondsByMarkNumber: [Int: TimeInterval] = [:]

    /// Round 22: how long the user has turned or zoomed the newest scene, for the metrics line of the
    /// turn that drew it. A new scene starts a new count.
    private var interactionClockOfTheNewestScene = EzraSceneInteractionClock()

    /// Round 22: the drawing self test turns this on for its proof pictures, so the scene windows
    /// (hidden from every capture otherwise) show in them; it applies to windows made later too.
    var isShowingScenesInScreenCapturesForSelfTest = false {
        didSet {
            for scenePanelWindow in scenePanelWindowsByMarkNumber.values {
                scenePanelWindow.setVisibleInScreenCapturesForSelfTest(isShowingScenesInScreenCapturesForSelfTest)
            }
        }
    }

    /// Where the tag of each callout on the screen was put, and the place it points at, both in
    /// points from the display's top-left corner. A new callout is kept clear of them.
    private var calloutTagFramesFromTopLeftByMarkNumber: [Int: CGRect] = [:]
    private var calloutTargetsFromTopLeftByMarkNumber: [Int: CGPoint] = [:]

    /// Round 21 review: a spotlight that has been drawn, in display points from its display's
    /// top-left corner, kept so its shade can be redrawn with new cut-outs.
    private struct SpotlightOnScreen {
        let center: EzraDrawingPoint
        let radius: Double
        /// The display it is on, in global AppKit coordinates.
        let displayFrame: CGRect
    }
    private var spotlightsOnScreenByMarkNumber: [Int: SpotlightOnScreen] = [:]

    /// Round 21 review: the frames (global AppKit coordinates) of Ezra's own windows that sit below
    /// the overlay and must not be darkened by a spotlight's shade: the chat panel while it is open
    /// and the status pill while it shows. Set by `CompanionManager`; with nothing set no window is
    /// cut out. When one of them appears, goes or moves, the manager calls `refreshSpotlightCutOuts`.
    var ezraWindowFramesKeptOutOfSpotlightShade: () -> [CGRect] = { [] }

    /// Set by the drawing self test while it runs, so a user who happens to scroll or switch apps
    /// during those few seconds does not wipe the sample marks before their picture is taken.
    /// Escape still clears everything.
    var isIgnoringScrollAndApplicationSwitchClearing = false

    private enum PendingScheduledWork {
        case drawMark(markNumber: Int)
        /// A row of the explanation card. `rowIndex` is the row's place on the card.
        case drawCardRow(cardMarkNumber: Int, rowIndex: Int)
        /// A part of the 3D scene. `partIndex` is the part's place in the scene.
        case drawScenePart(sceneMarkNumber: Int, partIndex: Int)
        /// Round 22: a `[VIEW:...]` change of the 3D scene. `explodedStateBefore` is whether the scene
        /// was exploded before it, so a change that is never shown can be taken back off the board.
        case changeSceneView(sceneMarkNumber: Int, explodedStateBefore: Bool)
        case removeMarks(markNumbers: [Int], fadeOutSeconds: Double)
    }

    private struct PendingScheduledCommand {
        let pendingCommandIdentifier: Int
        let work: PendingScheduledWork
        let dispatchWorkItem: DispatchWorkItem
    }

    /// Commands of the current reply that are waiting for their moment in the speech.
    private var pendingScheduledCommands: [PendingScheduledCommand] = []
    private var nextPendingCommandIdentifier = 0

    /// When the last scheduled mark of the current reply will have been fully drawn, on the
    /// uptime clock. The lifetime countdown never starts before this.
    private var latestScheduledDrawingEndUptimeSeconds: TimeInterval = 0

    private var lifetimeFadeWorkItem: DispatchWorkItem?
    /// Counts the turns (and key presses) that asked for the marks to be kept. Only the newest
    /// one may start the lifetime countdown, so an older, cancelled turn that ends late cannot
    /// make the marks fade while the user is already asking the next question.
    private var keepMarksGeneration = 0

    /// Kept for the life of the app: this controller is created once and never released.
    private var applicationActivationObserver: NSObjectProtocol?

    init() {
        // A drawing points at things in the app the user was looking at. Once another app comes
        // to the front those things are gone, so the drawing goes too.
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Ezra itself coming to the front (its panel, a permission prompt) is not the user
            // moving on to other content.
            let activatedApplicationIsEzra = activatedApplication?.processIdentifier == ownProcessIdentifier
            guard !activatedApplicationIsEzra else { return }
            // Hop to the main actor with a task. `MainActor.assumeIsolated` crashed here
            // (a segmentation fault inside the runtime's executor check) on every app switch,
            // even though the observer runs on the main queue.
            Task { @MainActor [weak self] in
                guard let self, !self.isIgnoringScrollAndApplicationSwitchClearing else { return }
                self.clearAllMarks(fadeOutSeconds: Self.applicationSwitchFadeOutSeconds)
            }
        }
    }

    // MARK: - Surfaces (called by OverlayWindowManager)

    /// Adds a drawing surface on top of one screen's overlay content. It is a subview of the
    /// overlay's own content view, so it lives and dies with that window and needs no window of
    /// its own: the overlay window already covers the screen, ignores clicks, never activates,
    /// joins every Space and is left out of Ezra's screenshots.
    func addDrawingSurface(onTopOf overlayContentView: NSView, displayFrame: CGRect) {
        let drawingSurfaceView = EzraDrawingSurfaceView(displayFrame: displayFrame, frame: overlayContentView.bounds)
        overlayContentView.addSubview(drawingSurfaceView)
        drawingSurfaceViews.append(drawingSurfaceView)
    }

    /// Called when the overlay windows go away. Their marks go with them, so the board is emptied
    /// too and the next prompt does not list marks nobody can see.
    func removeAllDrawingSurfaces() {
        clearAllMarks(fadeOutSeconds: 0)
        for drawingSurfaceView in drawingSurfaceViews {
            drawingSurfaceView.removeFromSuperview()
        }
        drawingSurfaceViews.removeAll()
    }

    // MARK: - Spotlight cut-outs (round 21 review)

    /// Called when Ezra's chat panel or status pill appears, goes or moves. Every spotlight on the
    /// screen cuts their frames out of its shade again; with no spotlight drawn this does nothing.
    func refreshSpotlightCutOuts() {
        for (markNumber, spotlightOnScreen) in spotlightsOnScreenByMarkNumber {
            guard let spotlightLayer = markLayersByMarkNumber[markNumber] else { continue }
            EzraDrawingMarkLayerBuilder.updateSpotlightShadeCutOuts(
                of: spotlightLayer,
                center: spotlightOnScreen.center,
                radius: spotlightOnScreen.radius,
                displaySizeInPoints: spotlightOnScreen.displayFrame.size,
                cutOutFramesFromTopLeft: spotlightCutOutFramesFromTopLeft(forDisplayFrame: spotlightOnScreen.displayFrame)
            )
        }
    }

    /// The parts of Ezra's own windows on this display, from its top-left corner.
    private func spotlightCutOutFramesFromTopLeft(forDisplayFrame displayFrame: CGRect) -> [CGRect] {
        EzraSpotlightShade.cutOutFramesFromTopLeft(
            forWindowFramesInGlobalPoints: ezraWindowFramesKeptOutOfSpotlightShade(),
            displayFrame: displayFrame
        )
    }

    // MARK: - What is on screen

    var hasMarksOnScreen: Bool {
        !drawingBoard.isEmpty
    }

    /// The marks to list in the next prompt, with screen numbers that match this turn's
    /// screenshots. Screens are numbered per turn (the cursor's screen comes first), so the number
    /// a mark was drawn with may now mean another screen; it is looked up again from the display
    /// the mark is on. A mark whose display is no longer connected is removed.
    func drawingMarksForPrompt(displayFramesInScreenshotOrder: [CGRect]) -> [EzraDrawingMark] {
        var marksForPrompt: [EzraDrawingMark] = []
        var markNumbersOnMissingDisplays: [Int] = []
        for markOnBoard in drawingBoard.marks {
            guard let markDisplayFrame = displayFramesByMarkNumber[markOnBoard.markNumber],
                  let screenshotIndex = displayFramesInScreenshotOrder.firstIndex(of: markDisplayFrame) else {
                markNumbersOnMissingDisplays.append(markOnBoard.markNumber)
                continue
            }
            marksForPrompt.append(EzraDrawingMark(
                markNumber: markOnBoard.markNumber,
                shape: markOnBoard.shape,
                // With one screen the tags carry no screen number, so the list has none either.
                screenNumber: displayFramesInScreenshotOrder.count > 1 ? screenshotIndex + 1 : nil
            ))
        }

        if !markNumbersOnMissingDisplays.isEmpty {
            drawingBoard.removeMarks { markNumbersOnMissingDisplays.contains($0.markNumber) }
            for markNumber in markNumbersOnMissingDisplays {
                removeMarkFromScreen(markNumber: markNumber, fadeOutSeconds: 0)
            }
        }
        return marksForPrompt
    }

    // MARK: - Keeping marks while the user asks again

    /// Called when the user presses the ask shortcut and when a turn starts. The lifetime
    /// countdown stops so the marks are still there to be edited by the reply. Returns a value to
    /// hand back to `finishKeepingMarks` when that turn's reply has ended.
    @discardableResult
    func beginKeepingMarks() -> Int {
        keepMarksGeneration += 1
        scheduleLifetimeFade(afterSeconds: Self.maximumSecondsMarksAreKeptWithoutAFinishedReply)
        return keepMarksGeneration
    }

    /// Called when a turn's reply has ended (its audio finished, or the turn failed or was
    /// cancelled). Starts the countdown after which the marks fade, unless a newer press or turn
    /// has asked for them to be kept since.
    func finishKeepingMarks(keepMarksGeneration finishedKeepMarksGeneration: Int) {
        guard finishedKeepMarksGeneration == keepMarksGeneration else { return }
        // Without audio the marks are still being drawn when the turn ends; the countdown starts
        // when the last of them is done.
        let secondsUntilLastMarkIsDrawn = max(0, latestScheduledDrawingEndUptimeSeconds - EzraTurnMetrics.currentUptimeSeconds)
        scheduleLifetimeFade(
            afterSeconds: secondsUntilLastMarkIsDrawn + drawingLifetimes.secondsMarksStayAfterReplyEnds,
            extraSecondsExplanationCardStays: drawingLifetimes.secondsExplanationCardStaysAfterReplyEnds - drawingLifetimes.secondsMarksStayAfterReplyEnds,
            extraSecondsSceneStays: drawingLifetimes.secondsSceneStaysAfterReplyEnds - drawingLifetimes.secondsMarksStayAfterReplyEnds
        )
    }

    /// Schedules the fade of every mark. With `extraSecondsExplanationCardStays` above zero, an
    /// explanation card on the board is left when the other marks fade and goes that much later.
    /// `extraSecondsSceneStays` does the same for the 3D scene, which stays longer still.
    private func scheduleLifetimeFade(
        afterSeconds secondsUntilFade: TimeInterval,
        extraSecondsExplanationCardStays: TimeInterval = 0,
        extraSecondsSceneStays: TimeInterval = 0
    ) {
        lifetimeFadeWorkItem?.cancel()
        let fadeWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Round 22: a scene the user has just turned or zoomed stays its full lifetime from that
            // touch, even when its reply's countdown is over.
            let extraSecondsSceneStaysWithTheUsersTouch = max(extraSecondsSceneStays, self.secondsTheTouchedSceneStillStays())
            let explanationCardMarkThatStays = extraSecondsExplanationCardStays > 0 ? self.drawingBoard.explanationCardMark : nil
            let sceneMarkThatStays = extraSecondsSceneStaysWithTheUsersTouch > 0 ? self.drawingBoard.sceneMark : nil
            let markNumbersThatStay = [explanationCardMarkThatStays?.markNumber, sceneMarkThatStays?.markNumber].compactMap { $0 }
            guard !markNumbersThatStay.isEmpty else {
                self.clearAllMarks(fadeOutSeconds: Self.lifetimeFadeOutSeconds)
                return
            }
            // Everything but the card and the scene fades now; those get their own countdown.
            self.drawingBoard.removeMarks { !markNumbersThatStay.contains($0.markNumber) }
            for markNumber in Array(self.displayFramesByMarkNumber.keys) where !markNumbersThatStay.contains(markNumber) {
                self.removeMarkFromScreen(markNumber: markNumber, fadeOutSeconds: Self.lifetimeFadeOutSeconds)
            }
            if explanationCardMarkThatStays != nil {
                // The card goes next. A scene, if there is one, is left again and goes after it.
                self.scheduleLifetimeFade(
                    afterSeconds: extraSecondsExplanationCardStays,
                    extraSecondsSceneStays: sceneMarkThatStays != nil ? max(0, extraSecondsSceneStaysWithTheUsersTouch - extraSecondsExplanationCardStays) : 0
                )
            } else {
                self.scheduleLifetimeFade(afterSeconds: extraSecondsSceneStaysWithTheUsersTouch)
            }
        }
        lifetimeFadeWorkItem = fadeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsUntilFade, execute: fadeWorkItem)
    }

    /// Round 22: how much longer the scene on the board stays because the user touched it (zero when
    /// it was never touched, or its time is over).
    private func secondsTheTouchedSceneStillStays() -> TimeInterval {
        guard let sceneMark = drawingBoard.sceneMark,
              let sceneKeptUntilUptimeSeconds = sceneKeptUntilUptimeSecondsByMarkNumber[sceneMark.markNumber] else {
            return 0
        }
        return max(0, sceneKeptUntilUptimeSeconds - EzraTurnMetrics.currentUptimeSeconds)
    }

    // MARK: - The user's hand on a scene (round 22)

    /// A drag, scroll, pinch or toggle click on a scene: its countdown starts again from the full scene
    /// lifetime, and the time counts for the metrics line.
    private func sceneWasTouchedByTheUser(markNumber sceneMarkNumber: Int) {
        guard scenePanelViewsByMarkNumber[sceneMarkNumber] != nil else { return }
        let nowUptimeSeconds = EzraTurnMetrics.currentUptimeSeconds
        sceneKeptUntilUptimeSecondsByMarkNumber[sceneMarkNumber] = nowUptimeSeconds + drawingLifetimes.secondsSceneStaysAfterReplyEnds
        interactionClockOfTheNewestScene.recordInteraction(atUptimeSeconds: nowUptimeSeconds)
    }

    /// The whole seconds the user has turned or zoomed the newest scene so far, for the metrics line.
    var wholeSecondsTheUserTurnedOrZoomedTheNewestScene: Int {
        interactionClockOfTheNewestScene.wholeSeconds
    }

    /// The toggle on the paper: pulls the model apart, or puts it back together, as `[VIEW:exploded]`
    /// and `[VIEW:assembled]` do. The board learns it too, so the next prompt says which it is.
    private func explodeToggleWasClicked(sceneMarkNumber: Int) {
        guard let scenePanelView = scenePanelViewsByMarkNumber[sceneMarkNumber] else { return }
        let explodedAfterTheClick = !scenePanelView.isShowingExplodedParts
        drawingBoard.setExplodedState(explodedAfterTheClick, ofSceneWithMarkNumber: sceneMarkNumber)
        if var plannedScene = plannedScenesByMarkNumber[sceneMarkNumber] {
            plannedScene.isExploded = explodedAfterTheClick
            plannedScenesByMarkNumber[sceneMarkNumber] = plannedScene
        }
        showSceneParts(ofSceneWithMarkNumber: sceneMarkNumber, exploded: explodedAfterTheClick, animationSeconds: EzraScenePanelView.explodeSeconds)
        print("✏️ draw: scene m\(sceneMarkNumber) toggled by the user (exploded: \(explodedAfterTheClick))")
    }

    // MARK: - Drawing a reply

    /// Carries out the draw commands of one reply, each at its moment in the speech.
    ///
    /// Call this right after the audio has started, with the audio's length, or with nil when
    /// there is no audio; the marks then follow each other at a steady beat.
    /// `displayPlacementsInScreenshotOrder` describes this turn's screenshots in the order Claude
    /// saw them, and `cursorScreenshotIndex` is the one the cursor was on.
    func performDrawCommands(
        _ parsedDrawCommands: [EzraParsedDrawCommand],
        displayPlacementsInScreenshotOrder: [EzraDrawingDisplayPlacement],
        cursorScreenshotIndex: Int?,
        speechAudioDurationSeconds: Double?
    ) {
        guard !parsedDrawCommands.isEmpty else { return }

        // Work out where each new mark goes first, because how long the pen takes depends on the
        // mark's size on the display. A mark with no screen to go on is dropped.
        struct PlacedDrawCommand {
            let parsedDrawCommand: EzraParsedDrawCommand
            let displayPlacement: EzraDrawingDisplayPlacement?
            let penTravelLengthInPoints: Double
        }
        var placedDrawCommands: [PlacedDrawCommand] = []
        for parsedDrawCommand in parsedDrawCommands {
            guard case .addMark(let shapeInScreenshotPixels, let screenNumber) = parsedDrawCommand.command else {
                // A row of the explanation card is written with the pen, so it takes as long as
                // its boxes, arrows and words are long. Erase, undo and clear draw nothing, and a
                // part of the 3D scene is not drawn with the pen.
                var penTravelLengthInPoints = 0.0
                if case .addCardRow(let cardRow) = parsedDrawCommand.command {
                    penTravelLengthInPoints = EzraExplanationCardLayerBuilder.penTravelLengthInPoints(for: cardRow)
                }
                placedDrawCommands.append(PlacedDrawCommand(parsedDrawCommand: parsedDrawCommand, displayPlacement: nil, penTravelLengthInPoints: penTravelLengthInPoints))
                continue
            }
            guard let screenshotIndex = EzraScreenshotToDisplayMapping.screenshotIndex(
                forScreenNumber: screenNumber,
                screenshotCount: displayPlacementsInScreenshotOrder.count,
                cursorScreenshotIndex: cursorScreenshotIndex
            ) else {
                continue
            }
            let displayPlacement = displayPlacementsInScreenshotOrder[screenshotIndex]
            guard drawingSurfaceView(forDisplayFrame: displayPlacement.displayFrame) != nil else {
                continue
            }
            let shapeInDisplayPoints = displayPlacement.screenshotToDisplayMapping.shapeInDisplayPoints(
                forShapeInScreenshotPixels: shapeInScreenshotPixels
            )
            placedDrawCommands.append(PlacedDrawCommand(
                parsedDrawCommand: parsedDrawCommand,
                displayPlacement: displayPlacement,
                penTravelLengthInPoints: EzraHandDrawnPathGenerator.penTravelLengthInPoints(forShapeInDisplayPoints: shapeInDisplayPoints)
            ))
        }
        // Numbers only: how many marks were asked for, how many found a screen to go on, and how
        // many screens have a drawing surface. A drawing that never appears shows up here.
        print("✏️ draw: asked=\(parsedDrawCommands.count) placed=\(placedDrawCommands.count) surfaces=\(drawingSurfaceViews.count) audioSeconds=\(speechAudioDurationSeconds.map { String(format: "%.1f", $0) } ?? "none")")
        guard !placedDrawCommands.isEmpty else { return }

        // A mark is drawn as its sentence BEGINS, not as it ends. Drawing at the end made the
        // first mark wait for a whole spoken sentence, which felt slow. A tag sits right after its
        // sentence, so the sentence began where the previous group of tags sat (or at the start of
        // the reply for the first group).
        let spokenFractionsBeforeTags = placedDrawCommands.map(\.parsedDrawCommand.spokenFractionBeforeTag)
        let distinctSpokenFractionsInOrder = Array(Set(spokenFractionsBeforeTags)).sorted()
        let spokenFractionsWhereSentencesBegin = spokenFractionsBeforeTags.map { spokenFractionBeforeTag -> Double in
            guard let positionAmongDistinctFractions = distinctSpokenFractionsInOrder.firstIndex(of: spokenFractionBeforeTag),
                  positionAmongDistinctFractions > 0 else {
                return 0
            }
            return distinctSpokenFractionsInOrder[positionAmongDistinctFractions - 1]
        }

        let scheduledTimes = EzraDrawingSchedule.scheduledTimes(
            forSpokenFractionsBeforeTags: spokenFractionsWhereSentencesBegin,
            penTravelLengthsInPoints: placedDrawCommands.map(\.penTravelLengthInPoints),
            speechAudioDurationSeconds: speechAudioDurationSeconds
        )

        let nowUptimeSeconds = EzraTurnMetrics.currentUptimeSeconds
        for (placedCommandIndex, (placedDrawCommand, scheduledTime)) in zip(placedDrawCommands, scheduledTimes).enumerated() {
            // The board changes at once, so ids are given in the order the tags were written and a
            // later tag of the same reply (an undo, say) sees the marks before it. Only what
            // happens on screen waits for its moment.
            let boardChange = drawingBoard.apply(placedDrawCommand.parsedDrawCommand.command)

            switch boardChange {
            case .addedMark(let addedMark, let marksRemovedToMakeRoom):
                guard let displayPlacement = placedDrawCommand.displayPlacement else { continue }
                displayFramesByMarkNumber[addedMark.markNumber] = displayPlacement.displayFrame
                if case .explanationCard(let openedCard) = addedMark.shape {
                    // The card is placed now, while every mark of the reply is known: it goes on
                    // the side this reply does not draw on, and is centred for the height it will
                    // have once the rows that follow it in this reply are written.
                    var cardWithRowsOfThisReply = openedCard
                    var marksOfThisReplyOnTheCardsDisplay: [EzraDrawingShape] = []
                    for (otherCommandIndex, otherPlacedDrawCommand) in placedDrawCommands.enumerated() {
                        switch otherPlacedDrawCommand.parsedDrawCommand.command {
                        case .addCardRow(let cardRow):
                            if otherCommandIndex > placedCommandIndex, cardWithRowsOfThisReply.rows.count < EzraExplanationCard.maximumRowCount {
                                cardWithRowsOfThisReply = cardWithRowsOfThisReply.addingRow(cardRow)
                            }
                        case .addMark(let otherShapeInScreenshotPixels, _):
                            if let otherDisplayPlacement = otherPlacedDrawCommand.displayPlacement,
                               otherDisplayPlacement.displayFrame == displayPlacement.displayFrame {
                                marksOfThisReplyOnTheCardsDisplay.append(otherDisplayPlacement.screenshotToDisplayMapping.shapeInDisplayPoints(
                                    forShapeInScreenshotPixels: otherShapeInScreenshotPixels
                                ))
                            }
                        case .eraseMark, .undoNewestMark, .clearAllMarks, .addScenePart, .changeSceneView:
                            break
                        }
                    }
                    let displaySizeInPoints = displayPlacement.displayFrame.size
                    let plannedCardFrame = EzraExplanationCardPlacement.cardFrame(
                        forCardSize: EzraExplanationCardLayerBuilder.cardLayout(for: cardWithRowsOfThisReply).cardSize,
                        displaySizeInPoints: displaySizeInPoints,
                        menuBarHeightInPoints: menuBarHeightInPoints(forDisplayFrame: displayPlacement.displayFrame),
                        placesCardInLeftThird: EzraExplanationCardPlacement.marksAreMostlyOnRightHalf(
                            markAnchorXsInDisplayPoints: marksOfThisReplyOnTheCardsDisplay.compactMap { $0.placeTheShapeIsAbout?.x },
                            displayWidthInPoints: Double(displaySizeInPoints.width)
                        )
                    )
                    // It opens with its title alone and grows downwards from this corner.
                    explanationCardFramesFromTopLeftByMarkNumber[addedMark.markNumber] = CGRect(
                        origin: plannedCardFrame.origin,
                        size: EzraExplanationCardLayerBuilder.cardLayout(for: openedCard).cardSize
                    )
                    plannedFullExplanationCardFramesFromTopLeftByMarkNumber[addedMark.markNumber] = plannedCardFrame
                }
                if case .scene(let openedScene) = addedMark.shape {
                    // Without Metal there is nothing to draw the model with. The scene is dropped
                    // silently (its parts then find no scene to go in) and the reply is still spoken.
                    guard EzraScenePanelView.canRenderScenes else {
                        drawingBoard.removeMarks { $0.markNumber == addedMark.markNumber }
                        displayFramesByMarkNumber[addedMark.markNumber] = nil
                        print("✏️ draw: scene m\(addedMark.markNumber) dropped (this Mac has no Metal device)")
                        continue
                    }
                    // Like the card, the scene's panel is placed now, while every mark of the
                    // reply is known: in a corner that the card and this reply's marks leave
                    // free, and sized for the tags of the parts that follow it in this reply.
                    var sceneWithPartsOfThisReply = openedScene
                    var occupiedFramesOnTheScenesDisplay: [CGRect] = []
                    for (otherCommandIndex, otherPlacedDrawCommand) in placedDrawCommands.enumerated() {
                        switch otherPlacedDrawCommand.parsedDrawCommand.command {
                        case .addScenePart(let scenePart):
                            if otherCommandIndex > placedCommandIndex, sceneWithPartsOfThisReply.parts.count < EzraScene.maximumPartCount {
                                sceneWithPartsOfThisReply = sceneWithPartsOfThisReply.addingPart(scenePart)
                            }
                        case .addMark(let otherShapeInScreenshotPixels, _):
                            if let otherDisplayPlacement = otherPlacedDrawCommand.displayPlacement,
                               otherDisplayPlacement.displayFrame == displayPlacement.displayFrame,
                               let occupiedFrame = EzraScenePanelPlacement.occupiedFrame(
                                   ofShapeInDisplayPoints: otherDisplayPlacement.screenshotToDisplayMapping.shapeInDisplayPoints(
                                       forShapeInScreenshotPixels: otherShapeInScreenshotPixels
                                   )
                               ) {
                                occupiedFramesOnTheScenesDisplay.append(occupiedFrame)
                            }
                        case .eraseMark, .undoNewestMark, .clearAllMarks, .addCardRow, .changeSceneView:
                            break
                        }
                    }
                    // The card on this display: where it is now and where it will have grown to.
                    for (otherMarkNumber, otherDisplayFrame) in displayFramesByMarkNumber where otherDisplayFrame == displayPlacement.displayFrame {
                        if let cardFrame = explanationCardFramesFromTopLeftByMarkNumber[otherMarkNumber] {
                            occupiedFramesOnTheScenesDisplay.append(
                                cardFrame.union(plannedFullExplanationCardFramesFromTopLeftByMarkNumber[otherMarkNumber] ?? cardFrame)
                            )
                        }
                    }
                    let displaySizeInPoints = displayPlacement.displayFrame.size
                    let menuBarHeightInPoints = menuBarHeightInPoints(forDisplayFrame: displayPlacement.displayFrame)
                    // The side the tags are on does not change the panel's size, so the size is
                    // known before the corner is. Round 22: one column of tags for up to twelve
                    // labelled parts, two for more.
                    let panelSize = EzraScenePanelLayoutCalculator.layout(
                        labelColumnCount: EzraScenePanelLayoutCalculator.columnCount(forLabelledPartCount: sceneWithPartsOfThisReply.labelledPartCount),
                        labelColumnIsOnLeftOfModel: true
                    ).panelSize
                    scenePanelPlacementsByMarkNumber[addedMark.markNumber] = EzraScenePanelPlacement.placement(
                        forPanelSize: panelSize,
                        displaySizeInPoints: displaySizeInPoints,
                        menuBarHeightInPoints: menuBarHeightInPoints,
                        statusPillKeepClearFrame: EzraScenePanelPlacement.statusPillKeepClearFrame(
                            displaySizeInPoints: displaySizeInPoints,
                            menuBarHeightInPoints: menuBarHeightInPoints,
                            statusPillMaximumWidthInPoints: Double(DS.StatusPill.maximumWidthInPoints),
                            statusPillHeightInPoints: Double(DS.StatusPill.heightInPoints),
                            statusPillGapBelowMenuBarInPoints: Double(DS.StatusPill.gapBelowMenuBarInPoints)
                        ),
                        occupiedFrames: occupiedFramesOnTheScenesDisplay
                    )
                    plannedScenesByMarkNumber[addedMark.markNumber] = sceneWithPartsOfThisReply
                }
                schedule(
                    .drawMark(markNumber: addedMark.markNumber),
                    afterSeconds: scheduledTime.startSecondsAfterSpeechBegins
                ) { [weak self] in
                    self?.drawMarkOnScreen(
                        addedMark,
                        displayPlacement: displayPlacement,
                        penDurationSeconds: scheduledTime.penDurationSeconds
                    )
                }
                latestScheduledDrawingEndUptimeSeconds = max(
                    latestScheduledDrawingEndUptimeSeconds,
                    nowUptimeSeconds + scheduledTime.startSecondsAfterSpeechBegins + scheduledTime.penDurationSeconds
                )
                if !marksRemovedToMakeRoom.isEmpty {
                    scheduleRemoval(
                        ofMarkNumbers: marksRemovedToMakeRoom.map(\.markNumber),
                        afterSeconds: scheduledTime.startSecondsAfterSpeechBegins
                    )
                }

            case .removedMarks(let removedMarks):
                scheduleRemoval(
                    ofMarkNumbers: removedMarks.map(\.markNumber),
                    afterSeconds: scheduledTime.startSecondsAfterSpeechBegins
                )

            case .addedRowToCard(let cardMark, let rowIndex):
                schedule(
                    .drawCardRow(cardMarkNumber: cardMark.markNumber, rowIndex: rowIndex),
                    afterSeconds: scheduledTime.startSecondsAfterSpeechBegins
                ) { [weak self] in
                    self?.drawCardRowOnScreen(
                        cardMark: cardMark,
                        rowIndex: rowIndex,
                        penDurationSeconds: scheduledTime.penDurationSeconds
                    )
                }
                latestScheduledDrawingEndUptimeSeconds = max(
                    latestScheduledDrawingEndUptimeSeconds,
                    nowUptimeSeconds + scheduledTime.startSecondsAfterSpeechBegins + scheduledTime.penDurationSeconds
                )

            case .addedPartToScene(let sceneMark, let partIndex):
                if case .scene(let sceneWithPart) = sceneMark.shape {
                    // A part added by a later reply than the one that opened the scene: the model
                    // is framed again for the parts it has now.
                    let plannedPartCount = plannedScenesByMarkNumber[sceneMark.markNumber]?.parts.count ?? 0
                    if sceneWithPart.parts.count > plannedPartCount {
                        plannedScenesByMarkNumber[sceneMark.markNumber] = sceneWithPart
                    }
                }
                schedule(
                    .drawScenePart(sceneMarkNumber: sceneMark.markNumber, partIndex: partIndex),
                    afterSeconds: scheduledTime.startSecondsAfterSpeechBegins
                ) { [weak self] in
                    self?.drawScenePartOnScreen(sceneMark: sceneMark, partIndex: partIndex)
                }
                latestScheduledDrawingEndUptimeSeconds = max(
                    latestScheduledDrawingEndUptimeSeconds,
                    nowUptimeSeconds + scheduledTime.startSecondsAfterSpeechBegins + EzraScenePanelView.partAppearSeconds
                )

            case .sceneViewChanged(let sceneMark, let viewCommand, let sceneWasExplodedBefore):
                // Round 22: the view changes as its sentence begins, like a part appears. The planned
                // scene learns the exploded state at once, so parts of this reply that come after the
                // change appear where it puts them.
                if case .scene(let sceneAfterTheChange) = sceneMark.shape, var plannedScene = plannedScenesByMarkNumber[sceneMark.markNumber] {
                    plannedScene.isExploded = sceneAfterTheChange.isExploded
                    plannedScenesByMarkNumber[sceneMark.markNumber] = plannedScene
                }
                schedule(
                    .changeSceneView(sceneMarkNumber: sceneMark.markNumber, explodedStateBefore: sceneWasExplodedBefore),
                    afterSeconds: scheduledTime.startSecondsAfterSpeechBegins
                ) { [weak self] in
                    self?.changeSceneViewOnScreen(sceneMarkNumber: sceneMark.markNumber, viewCommand: viewCommand)
                }
                latestScheduledDrawingEndUptimeSeconds = max(
                    latestScheduledDrawingEndUptimeSeconds,
                    nowUptimeSeconds + scheduledTime.startSecondsAfterSpeechBegins + EzraScenePanelView.explodeSeconds
                )

            case .nothingChanged:
                // An erase of an id that is not on the board, an undo with nothing to undo, a
                // row with no card to go on, or a part with no scene to go in.
                break
            }
        }

        // Marks must never be left without a countdown, even if nobody asked for them to be kept.
        if lifetimeFadeWorkItem == nil {
            scheduleLifetimeFade(afterSeconds: Self.maximumSecondsMarksAreKeptWithoutAFinishedReply)
        }
    }

    /// Stops the part of a reply's drawing that has not happened yet, because its speech was cut
    /// off (the user pressed the keys again, or started dictating). Marks already drawn stay.
    /// Marks not drawn yet are forgotten, and removals that were waiting happen now, so the board
    /// and the screen agree again.
    func cancelCommandsNotYetDrawn() {
        let commandsToCancel = pendingScheduledCommands
        pendingScheduledCommands.removeAll()
        // Round 22: for each scene, the exploded state before the first view change that was never
        // shown: that is what is on the screen, so the board goes back to it.
        var explodedStateOnScreenBySceneMarkNumber: [Int: Bool] = [:]

        for commandToCancel in commandsToCancel {
            commandToCancel.dispatchWorkItem.cancel()
            switch commandToCancel.work {
            case .changeSceneView(let sceneMarkNumber, let explodedStateBefore):
                if explodedStateOnScreenBySceneMarkNumber[sceneMarkNumber] == nil {
                    explodedStateOnScreenBySceneMarkNumber[sceneMarkNumber] = explodedStateBefore
                }
            case .drawMark(let markNumber):
                drawingBoard.removeMarks { $0.markNumber == markNumber }
                removeMarkFromScreen(markNumber: markNumber, fadeOutSeconds: 0)
            case .drawCardRow(let cardMarkNumber, let rowIndex):
                // The row was never written, so it comes back off the card on the board. Rows are
                // written in order, so every row from this one on is one that was not written.
                drawingBoard.keepOnlyFirstRows(rowIndex, ofCardWithMarkNumber: cardMarkNumber)
            case .drawScenePart(let sceneMarkNumber, let partIndex):
                // The same for a part that was never shown: it comes back out of the scene on
                // the board, and with it every part after it.
                drawingBoard.keepOnlyFirstParts(partIndex, ofSceneWithMarkNumber: sceneMarkNumber)
                if let plannedScene = plannedScenesByMarkNumber[sceneMarkNumber] {
                    plannedScenesByMarkNumber[sceneMarkNumber] = plannedScene.keepingFirstParts(partIndex)
                }
            case .removeMarks(let markNumbers, let fadeOutSeconds):
                for markNumber in markNumbers {
                    removeMarkFromScreen(markNumber: markNumber, fadeOutSeconds: fadeOutSeconds)
                }
            }
        }
        for (sceneMarkNumber, explodedStateOnScreen) in explodedStateOnScreenBySceneMarkNumber {
            drawingBoard.setExplodedState(explodedStateOnScreen, ofSceneWithMarkNumber: sceneMarkNumber)
            if var plannedScene = plannedScenesByMarkNumber[sceneMarkNumber] {
                plannedScene.isExploded = explodedStateOnScreen
                plannedScenesByMarkNumber[sceneMarkNumber] = plannedScene
            }
        }
        latestScheduledDrawingEndUptimeSeconds = 0
    }

    // MARK: - Clearing

    /// Removes every mark. Escape passes 0 so they are gone at once.
    func clearAllMarks(fadeOutSeconds: Double) {
        for pendingScheduledCommand in pendingScheduledCommands {
            pendingScheduledCommand.dispatchWorkItem.cancel()
        }
        pendingScheduledCommands.removeAll()
        latestScheduledDrawingEndUptimeSeconds = 0
        lifetimeFadeWorkItem?.cancel()
        lifetimeFadeWorkItem = nil

        drawingBoard.removeMarks { _ in true }
        // Every tracked mark goes, including ones whose removal was still waiting for its moment.
        for markNumber in Array(displayFramesByMarkNumber.keys) {
            removeMarkFromScreen(markNumber: markNumber, fadeOutSeconds: fadeOutSeconds)
        }
    }

    /// The page under the marks moved, so everything that points at a place on it is now wrong
    /// and fades. Sticky notes and the explanation card are written for the user and stay. Marks of the current reply that
    /// have not been drawn yet are dropped too: they would land on content that has moved.
    /// Round 22: `scrollLocationOnScreen` is where the pointer was (global AppKit coordinates). A
    /// scroll over a scene's window zoomed the model and moved no page, so nothing fades.
    func fadeMarksThatPointAtScreenContent(unlessScrollIsOver scrollLocationOnScreen: CGPoint? = nil) {
        guard !isIgnoringScrollAndApplicationSwitchClearing else { return }
        if let scrollLocationOnScreen,
           scenePanelWindowsByMarkNumber.values.contains(where: { $0.frame.contains(scrollLocationOnScreen) }) {
            return
        }
        guard case .removedMarks(let removedMarks) = drawingBoard.removeMarks(where: { $0.shape.pointsAtScreenContent }) else {
            return
        }
        for removedMark in removedMarks {
            removeMarkFromScreen(markNumber: removedMark.markNumber, fadeOutSeconds: Self.scrollFadeOutSeconds)
        }
    }

    // MARK: - Scheduling

    private func schedule(_ work: PendingScheduledWork, afterSeconds secondsFromNow: Double, perform workToPerform: @escaping () -> Void) {
        let pendingCommandIdentifier = nextPendingCommandIdentifier
        nextPendingCommandIdentifier += 1

        let dispatchWorkItem = DispatchWorkItem { [weak self] in
            // Taken off the list first, so cancelling "what has not been drawn yet" can never
            // touch a command that has already run.
            self?.pendingScheduledCommands.removeAll { $0.pendingCommandIdentifier == pendingCommandIdentifier }
            workToPerform()
        }
        pendingScheduledCommands.append(PendingScheduledCommand(
            pendingCommandIdentifier: pendingCommandIdentifier,
            work: work,
            dispatchWorkItem: dispatchWorkItem
        ))
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, secondsFromNow), execute: dispatchWorkItem)
    }

    private func scheduleRemoval(ofMarkNumbers markNumbers: [Int], afterSeconds secondsFromNow: Double) {
        schedule(
            .removeMarks(markNumbers: markNumbers, fadeOutSeconds: Self.eraseFadeOutSeconds),
            afterSeconds: secondsFromNow
        ) { [weak self] in
            for markNumber in markNumbers {
                self?.removeMarkFromScreen(markNumber: markNumber, fadeOutSeconds: Self.eraseFadeOutSeconds)
            }
        }
    }

    // MARK: - Layers

    private func drawingSurfaceView(forDisplayFrame displayFrame: CGRect) -> EzraDrawingSurfaceView? {
        drawingSurfaceViews.first { $0.displayFrame == displayFrame }
    }

    /// The height of the menu bar on a display, so the card and callouts stay below it. Zero for a
    /// display that is no longer connected.
    private func menuBarHeightInPoints(forDisplayFrame displayFrame: CGRect) -> Double {
        guard let screen = NSScreen.screens.first(where: { $0.frame == displayFrame }) else {
            return 0
        }
        return Double(max(0, screen.frame.maxY - screen.visibleFrame.maxY))
    }

    private func drawMarkOnScreen(_ mark: EzraDrawingMark, displayPlacement: EzraDrawingDisplayPlacement, penDurationSeconds: Double) {
        // No entry means the mark was removed (erased, scrolled away, cleared) while it waited.
        guard displayFramesByMarkNumber[mark.markNumber] != nil,
              let drawingSurfaceView = drawingSurfaceView(forDisplayFrame: displayPlacement.displayFrame),
              let surfaceLayer = drawingSurfaceView.layer else {
            print("✏️ draw: mark m\(mark.markNumber) not drawn (stillWanted=\(displayFramesByMarkNumber[mark.markNumber] != nil) surfaces=\(drawingSurfaceViews.count))")
            return
        }

        let shapeInDisplayPoints = displayPlacement.screenshotToDisplayMapping.shapeInDisplayPoints(
            forShapeInScreenshotPixels: mark.shape
        )
        let displaySizeInPoints = drawingSurfaceView.displayFrame.size
        let backingScaleFactor = drawingSurfaceView.window?.backingScaleFactor ?? 2

        // The 3D scene is a view of its own next to the drawing surface, not a layer in it.
        if case .scene(let scene) = mark.shape {
            showScenePanelOnScreen(
                sceneMarkNumber: mark.markNumber,
                scene: scene,
                drawingSurfaceView: drawingSurfaceView,
                backingScaleFactor: backingScaleFactor
            )
            return
        }

        let markLayer: CALayer
        switch shapeInDisplayPoints {
        case .explanationCard(let card):
            guard let cardFrameFromTopLeft = explanationCardFramesFromTopLeftByMarkNumber[mark.markNumber] else { return }
            markLayer = EzraExplanationCardLayerBuilder.makeCardLayer(
                forMarkNumber: mark.markNumber,
                card: card,
                cardFrameFromTopLeft: cardFrameFromTopLeft,
                displaySizeInPoints: displaySizeInPoints,
                backingScaleFactor: backingScaleFactor
            )

        case .callout(let target, let text, let calloutNumber):
            let targetInDisplayPoints = CGPoint(x: target.x, y: target.y)
            // The tag is placed now, clear of what is already on this display: the tags of the
            // other callouts, the places they point at, and the explanation card.
            var occupiedFrames: [CGRect] = []
            for (otherMarkNumber, otherDisplayFrame) in displayFramesByMarkNumber where otherDisplayFrame == displayPlacement.displayFrame {
                if let otherTagFrame = calloutTagFramesFromTopLeftByMarkNumber[otherMarkNumber] {
                    occupiedFrames.append(otherTagFrame)
                }
                if let otherTarget = calloutTargetsFromTopLeftByMarkNumber[otherMarkNumber] {
                    occupiedFrames.append(EzraCalloutPlacement.clearFrame(aroundTarget: otherTarget))
                }
                if let cardFrame = explanationCardFramesFromTopLeftByMarkNumber[otherMarkNumber] {
                    occupiedFrames.append(cardFrame)
                }
                if let scenePanelPlacement = scenePanelPlacementsByMarkNumber[otherMarkNumber] {
                    occupiedFrames.append(scenePanelPlacement.panelFrame)
                }
            }
            let tagFrameFromTopLeft = EzraCalloutPlacement.tagFrame(
                forTargetInDisplayPoints: targetInDisplayPoints,
                tagSize: EzraExplanationCardLayerBuilder.calloutTagSize(forText: text),
                displaySizeInPoints: displaySizeInPoints,
                menuBarHeightInPoints: menuBarHeightInPoints(forDisplayFrame: displayPlacement.displayFrame),
                occupiedFrames: occupiedFrames
            )
            calloutTagFramesFromTopLeftByMarkNumber[mark.markNumber] = tagFrameFromTopLeft
            calloutTargetsFromTopLeftByMarkNumber[mark.markNumber] = targetInDisplayPoints
            markLayer = EzraExplanationCardLayerBuilder.makeCalloutLayer(
                forMarkNumber: mark.markNumber,
                targetInDisplayPoints: targetInDisplayPoints,
                text: text,
                calloutNumber: calloutNumber,
                tagFrameFromTopLeft: tagFrameFromTopLeft,
                displaySizeInPoints: displaySizeInPoints,
                backingScaleFactor: backingScaleFactor
            )

        case .scene:
            // Shown above, as a view.
            return

        case .spotlight(let center, let radius):
            // Round 21 review: Ezra's own chat panel and status pill sit below the overlay, so their
            // frames on this display are cut out of the shade (and again whenever they change).
            markLayer = EzraDrawingMarkLayerBuilder.makeSpotlightLayer(
                center: center,
                radius: radius,
                displaySizeInPoints: displaySizeInPoints,
                backingScaleFactor: backingScaleFactor,
                cutOutFramesFromTopLeft: spotlightCutOutFramesFromTopLeft(forDisplayFrame: drawingSurfaceView.displayFrame)
            )
            spotlightsOnScreenByMarkNumber[mark.markNumber] = SpotlightOnScreen(center: center, radius: radius, displayFrame: drawingSurfaceView.displayFrame)

        case .arrow, .circle, .box, .underline, .highlight, .label, .stickyNote:
            markLayer = EzraDrawingMarkLayerBuilder.makeMarkLayer(
                forMarkNumber: mark.markNumber,
                shapeInDisplayPoints: shapeInDisplayPoints,
                displaySizeInPoints: displaySizeInPoints,
                backingScaleFactor: backingScaleFactor
            )
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if shapeInDisplayPoints.isSpotlight {
            // Round 21: the shade goes under every other mark, so what this reply draws stays bright.
            drawingSurfaceView.insertMarkLayerBelowOthers(markLayer)
        } else {
            surfaceLayer.addSublayer(markLayer)
        }
        CATransaction.commit()
        markLayersByMarkNumber[mark.markNumber] = markLayer
        let surfaceWindow = drawingSurfaceView.window
        print("✏️ draw: mark m\(mark.markNumber) \(mark.shape.tagKindName) drawn layerFrame=\(markLayer.frame.integral) surfaceFrame=\(drawingSurfaceView.frame.integral) inWindow=\(surfaceWindow != nil) windowVisible=\(surfaceWindow?.isVisible ?? false) windowAlpha=\(surfaceWindow?.alphaValue ?? -1) hidden=\(drawingSurfaceView.isHiddenOrHasHiddenAncestor)")

        if case .callout = shapeInDisplayPoints {
            // The tag fades in while the pen draws the leader line.
            EzraExplanationCardLayerBuilder.animateCalloutAppearance(of: markLayer, penDurationSeconds: penDurationSeconds)
        } else if shapeInDisplayPoints.isSpotlight {
            // The shade fades in; it has no ink for a pen to draw.
            EzraDrawingMarkLayerBuilder.animateSpotlightAppearance(of: markLayer)
        } else {
            // Ink is revealed with the pen; a label, a sticky note and the card fade and grow in.
            EzraDrawingMarkLayerBuilder.animateAppearance(of: markLayer, penDurationSeconds: penDurationSeconds)
        }
    }

    /// Writes one row on the explanation card that is on the screen. `cardMark` is the card with
    /// the row already on it. Nothing happens when the card has gone (erased, cleared, faded)
    /// while the row waited for its moment.
    private func drawCardRowOnScreen(cardMark: EzraDrawingMark, rowIndex: Int, penDurationSeconds: Double) {
        guard case .explanationCard(let cardWithRow) = cardMark.shape,
              let cardLayer = markLayersByMarkNumber[cardMark.markNumber],
              let currentCardFrameFromTopLeft = explanationCardFramesFromTopLeftByMarkNumber[cardMark.markNumber],
              let cardDisplayFrame = displayFramesByMarkNumber[cardMark.markNumber],
              let drawingSurfaceView = drawingSurfaceView(forDisplayFrame: cardDisplayFrame) else {
            print("✏️ draw: row \(rowIndex + 1) of card m\(cardMark.markNumber) not drawn (the card is not on screen)")
            return
        }

        let displaySizeInPoints = drawingSurfaceView.displayFrame.size
        // The card grows downwards by the row, and moves up only if it would leave the screen.
        let grownCardFrameFromTopLeft = EzraExplanationCardPlacement.cardFrameAfterGrowing(
            from: currentCardFrameFromTopLeft,
            toCardSize: EzraExplanationCardLayerBuilder.cardLayout(for: cardWithRow).cardSize,
            displaySizeInPoints: displaySizeInPoints,
            menuBarHeightInPoints: menuBarHeightInPoints(forDisplayFrame: cardDisplayFrame)
        )
        explanationCardFramesFromTopLeftByMarkNumber[cardMark.markNumber] = grownCardFrameFromTopLeft

        EzraExplanationCardLayerBuilder.addRow(
            atRowIndex: rowIndex,
            of: cardWithRow,
            to: cardLayer,
            markNumber: cardMark.markNumber,
            cardFrameFromTopLeft: grownCardFrameFromTopLeft,
            displaySizeInPoints: displaySizeInPoints,
            backingScaleFactor: drawingSurfaceView.window?.backingScaleFactor ?? 2,
            penDurationSeconds: penDurationSeconds
        )
        print("✏️ draw: row \(rowIndex + 1) of card m\(cardMark.markNumber) drawn cardFrame=\(grownCardFrameFromTopLeft.integral)")
    }

    // MARK: - The 3D scene

    /// Round 22: where a scene's window goes on the screen: the panel frame (given from its display's
    /// top-left corner) in global AppKit coordinates, which measure from the bottom-left corner of the
    /// main display, grown by the room the paper's shadow needs on every side.
    private func sceneWindowFrameOnScreen(forPanelFrameFromTopLeft panelFrameFromTopLeft: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + panelFrameFromTopLeft.minX,
            y: displayFrame.maxY - panelFrameFromTopLeft.maxY,
            width: panelFrameFromTopLeft.width,
            height: panelFrameFromTopLeft.height
        ).insetBy(dx: -EzraScenePanelView.shadowRoomInPoints, dy: -EzraScenePanelView.shadowRoomInPoints)
    }

    /// Round 22: the paper's frame inside its own window: the window is the paper plus the shadow's
    /// room on every side.
    private func panelFrameInsideTheSceneWindow(forPanelSize panelSize: CGSize) -> CGRect {
        CGRect(
            origin: CGPoint(x: EzraScenePanelView.shadowRoomInPoints, y: EzraScenePanelView.shadowRoomInPoints),
            size: panelSize
        )
    }

    /// Puts the panel of a newly opened scene on the screen: the paper and the title, with the
    /// camera already framing the parts that are about to follow. The parts themselves arrive
    /// one by one through `drawScenePartOnScreen`.
    private func showScenePanelOnScreen(
        sceneMarkNumber: Int,
        scene: EzraScene,
        drawingSurfaceView: EzraDrawingSurfaceView,
        backingScaleFactor: CGFloat
    ) {
        // Round 22: the panel goes in a window of its own (never inside a SwiftUI hosting view),
        // ordered just above the overlay window of this display.
        guard let scenePanelPlacement = scenePanelPlacementsByMarkNumber[sceneMarkNumber] else {
            print("✏️ draw: scene m\(sceneMarkNumber) not shown (no place)")
            return
        }
        let plannedScene = plannedScenesByMarkNumber[sceneMarkNumber] ?? scene
        let panelLayout = EzraScenePanelLayoutCalculator.layout(
            labelColumnCount: EzraScenePanelLayoutCalculator.columnCount(forLabelledPartCount: plannedScene.labelledPartCount),
            labelColumnIsOnLeftOfModel: scenePanelPlacement.corner.isOnRightSideOfScreen
        )
        let scenePanelView = EzraScenePanelView(
            sceneTitle: scene.title,
            cameraFit: EzraSceneCamera.cameraFit(for: plannedScene.parts),
            panelLayout: panelLayout,
            panelFrameInContainer: panelFrameInsideTheSceneWindow(forPanelSize: scenePanelPlacement.panelFrame.size),
            backingScaleFactor: backingScaleFactor
        )
        // A scene opened with parts already in it (none does today) shows them at once.
        for (partIndex, part) in scene.parts.enumerated() {
            scenePanelView.addPart(
                part,
                partIndex: partIndex,
                labelNumber: scene.labelNumber(forPartAtIndex: partIndex),
                cameraFit: EzraSceneCamera.cameraFit(for: plannedScene.parts),
                isAnimated: false
            )
        }
        let scenePanelWindow = EzraScenePanelWindow(
            scenePanelView: scenePanelView,
            frameOnScreen: sceneWindowFrameOnScreen(
                forPanelFrameFromTopLeft: scenePanelPlacement.panelFrame,
                displayFrame: drawingSurfaceView.displayFrame
            )
        )
        scenePanelView.userTouchedTheSceneHandler = { [weak self] in
            self?.sceneWasTouchedByTheUser(markNumber: sceneMarkNumber)
        }
        scenePanelView.explodeToggleClickedHandler = { [weak self] in
            self?.explodeToggleWasClicked(sceneMarkNumber: sceneMarkNumber)
        }
        scenePanelWindow.setVisibleInScreenCapturesForSelfTest(isShowingScenesInScreenCapturesForSelfTest)
        scenePanelWindow.show(aboveOverlayWindow: drawingSurfaceView.window)
        scenePanelViewsByMarkNumber[sceneMarkNumber] = scenePanelView
        scenePanelWindowsByMarkNumber[sceneMarkNumber] = scenePanelWindow
        interactionClockOfTheNewestScene = EzraSceneInteractionClock()
        scenePanelView.fadeInAndStartTurning()
        print("✏️ draw: scene m\(sceneMarkNumber) shown panelFrame=\(scenePanelPlacement.panelFrame.integral) corner=\(scenePanelPlacement.corner) plannedParts=\(plannedScene.parts.count)")
    }

    /// Adds one part to the scene that is on the screen. `sceneMark` is the scene with the part
    /// already in it. Nothing happens when the scene has gone (erased, cleared, faded) while the
    /// part waited for its moment.
    private func drawScenePartOnScreen(sceneMark: EzraDrawingMark, partIndex: Int) {
        guard case .scene(let sceneWithPart) = sceneMark.shape,
              partIndex < sceneWithPart.parts.count,
              let scenePanelView = scenePanelViewsByMarkNumber[sceneMark.markNumber],
              let scenePanelPlacement = scenePanelPlacementsByMarkNumber[sceneMark.markNumber],
              let sceneDisplayFrame = displayFramesByMarkNumber[sceneMark.markNumber] else {
            print("✏️ draw: part \(partIndex + 1) of scene m\(sceneMark.markNumber) not shown (the scene is not on screen)")
            return
        }
        let plannedScene = plannedScenesByMarkNumber[sceneMark.markNumber] ?? sceneWithPart

        // The first labelled part of a scene that had no tags yet: the paper grows a column for
        // them on the side facing the middle of the screen. Round 22: the thirteenth labelled part
        // grows a second column beyond the first. The panel keeps its corner, so the model does not
        // move.
        let neededLabelColumnCount = EzraScenePanelLayoutCalculator.columnCount(forLabelledPartCount: plannedScene.labelledPartCount)
        if neededLabelColumnCount > scenePanelView.panelLayout.labelColumnCount {
            let panelLayoutWithLabelColumn = EzraScenePanelLayoutCalculator.layout(
                labelColumnCount: neededLabelColumnCount,
                labelColumnIsOnLeftOfModel: scenePanelPlacement.corner.isOnRightSideOfScreen
            )
            let grownPanelFrame = EzraScenePanelPlacement.panelFrame(
                forPanelSize: panelLayoutWithLabelColumn.panelSize,
                corner: scenePanelPlacement.corner,
                displaySizeInPoints: sceneDisplayFrame.size,
                menuBarHeightInPoints: menuBarHeightInPoints(forDisplayFrame: sceneDisplayFrame)
            )
            scenePanelPlacementsByMarkNumber[sceneMark.markNumber] = EzraScenePanelPlacementResult(
                panelFrame: grownPanelFrame,
                corner: scenePanelPlacement.corner
            )
            // Round 22: the window grows with the paper (it keeps its corner, so the model stays where
            // it is on the screen), and the paper lays itself out inside it.
            scenePanelWindowsByMarkNumber[sceneMark.markNumber]?.moveAndResize(
                toFrameOnScreen: sceneWindowFrameOnScreen(forPanelFrameFromTopLeft: grownPanelFrame, displayFrame: sceneDisplayFrame)
            )
            scenePanelView.applyPanelLayout(
                panelLayoutWithLabelColumn,
                panelFrameInContainer: panelFrameInsideTheSceneWindow(forPanelSize: grownPanelFrame.size)
            )
        }

        // Round 22: while the model is pulled apart, the new part appears at its exploded place, and
        // the parts already shown glide to theirs (the model's middle moves a little as it grows).
        let shownPlannedParts = EzraSceneExplosion.shownParts(plannedScene.parts, isExploded: scenePanelView.isShowingExplodedParts)
        let shownCameraFit = EzraSceneCamera.cameraFit(for: shownPlannedParts)
        if scenePanelView.isShowingExplodedParts {
            scenePanelView.showParts(
                atCentres: shownCentresByIndex(of: shownPlannedParts, onlyIndexesBelow: partIndex),
                cameraFit: shownCameraFit,
                isExploded: true,
                animationSeconds: EzraScenePanelView.partAppearSeconds
            )
        }
        scenePanelView.addPart(
            sceneWithPart.parts[partIndex],
            partIndex: partIndex,
            labelNumber: sceneWithPart.labelNumber(forPartAtIndex: partIndex),
            cameraFit: shownCameraFit,
            isAnimated: true,
            shownCentre: scenePanelView.isShowingExplodedParts && partIndex < shownPlannedParts.count ? shownPlannedParts[partIndex].centre : nil
        )
        print("✏️ draw: part \(partIndex + 1) of scene m\(sceneMark.markNumber) shown (\(sceneWithPart.parts[partIndex].shapeKind.rawValue))")
    }

    /// Round 22: the centres of the parts as shown, by their place in the scene, for the parts with a
    /// place below `partIndexLimit` (the ones already on the screen).
    private func shownCentresByIndex(of shownParts: [EzraScenePart], onlyIndexesBelow partIndexLimit: Int) -> [Int: EzraSceneVector] {
        var shownCentresByIndex: [Int: EzraSceneVector] = [:]
        for (partIndex, shownPart) in shownParts.enumerated() where partIndex < partIndexLimit {
            shownCentresByIndex[partIndex] = shownPart.centre
        }
        return shownCentresByIndex
    }

    /// Round 22: carries out a `[VIEW:...]` change on the scene that is on the screen. Nothing happens
    /// when the scene has gone while the change waited for its moment.
    private func changeSceneViewOnScreen(sceneMarkNumber: Int, viewCommand: EzraSceneViewCommand) {
        guard let scenePanelView = scenePanelViewsByMarkNumber[sceneMarkNumber] else {
            print("✏️ draw: a view change of scene m\(sceneMarkNumber) not shown (the scene is not on screen)")
            return
        }
        switch viewCommand {
        case .exploded:
            showSceneParts(ofSceneWithMarkNumber: sceneMarkNumber, exploded: true, animationSeconds: EzraScenePanelView.explodeSeconds)
        case .assembled:
            showSceneParts(ofSceneWithMarkNumber: sceneMarkNumber, exploded: false, animationSeconds: EzraScenePanelView.explodeSeconds)
        case .turn(let turnDirection):
            scenePanelView.turnTheModel(turnDirection)
        case .zoom(let zoomDirection):
            scenePanelView.zoomTheModel(zoomDirection)
        case .reset:
            // Reset is the first view: together again, the usual tilt and distance, facing the front.
            if scenePanelView.isShowingExplodedParts {
                showSceneParts(ofSceneWithMarkNumber: sceneMarkNumber, exploded: false, animationSeconds: EzraScenePanelView.explodeSeconds)
            }
            scenePanelView.resetTheView()
        }
        print("✏️ draw: scene m\(sceneMarkNumber) view changed (\(viewCommand.canonicalTagBody))")
    }

    /// Round 22: shows every part of a scene that is on the screen pulled apart or put back together,
    /// framed for how it is shown, over `animationSeconds`.
    private func showSceneParts(ofSceneWithMarkNumber sceneMarkNumber: Int, exploded: Bool, animationSeconds: Double) {
        guard let scenePanelView = scenePanelViewsByMarkNumber[sceneMarkNumber],
              let plannedScene = plannedScenesByMarkNumber[sceneMarkNumber] else {
            return
        }
        let shownPlannedParts = EzraSceneExplosion.shownParts(plannedScene.parts, isExploded: exploded)
        scenePanelView.showParts(
            atCentres: shownCentresByIndex(of: shownPlannedParts, onlyIndexesBelow: shownPlannedParts.count),
            cameraFit: EzraSceneCamera.cameraFit(for: shownPlannedParts),
            isExploded: exploded,
            animationSeconds: animationSeconds
        )
    }

    private func removeMarkFromScreen(markNumber: Int, fadeOutSeconds: Double) {
        displayFramesByMarkNumber[markNumber] = nil
        spotlightsOnScreenByMarkNumber[markNumber] = nil
        explanationCardFramesFromTopLeftByMarkNumber[markNumber] = nil
        plannedFullExplanationCardFramesFromTopLeftByMarkNumber[markNumber] = nil
        scenePanelPlacementsByMarkNumber[markNumber] = nil
        plannedScenesByMarkNumber[markNumber] = nil
        // The scene's view stops its renderer and its window closes, so it costs nothing once gone.
        let scenePanelView = scenePanelViewsByMarkNumber.removeValue(forKey: markNumber)
        if let scenePanelWindow = scenePanelWindowsByMarkNumber.removeValue(forKey: markNumber) {
            scenePanelWindow.fadeOutAndClose(fadeOutSeconds: fadeOutSeconds)
        } else {
            scenePanelView?.fadeOutAndRemove(fadeOutSeconds: fadeOutSeconds)
        }
        sceneKeptUntilUptimeSecondsByMarkNumber[markNumber] = nil
        calloutTagFramesFromTopLeftByMarkNumber[markNumber] = nil
        calloutTargetsFromTopLeftByMarkNumber[markNumber] = nil
        guard let markLayer = markLayersByMarkNumber.removeValue(forKey: markNumber) else {
            return
        }
        EzraDrawingMarkLayerBuilder.fadeOutAndRemove(markLayer, fadeOutSeconds: fadeOutSeconds)
    }
}
