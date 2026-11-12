//
//  ClickyDrawingOverlayController.swift
//  leanring-buddy
//
//  Shows the marks Clicky draws on the screen (arrows, circles, boxes, underlines, highlights,
//  labels, sticky notes, numbered callouts, the explanation card and the simple 3D scene) and decides how long they stay. The marks are Core Animation layers in a
//  click-through view on top of each screen's existing overlay window, so no extra windows exist
//  and Clicky's screenshots, which already leave out all of Clicky's windows, never contain them.
//  The 3D scene is the one mark that is a view of its own (`ClickyScenePanelView`, SceneKit): it is
//  added to the same overlay window, next to the drawing surface.
//

import AppKit
import QuartzCore

/// A transparent view that only hosts mark layers. One sits on top of each screen's overlay.
final class ClickyDrawingSurfaceView: NSView {
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
        fatalError("ClickyDrawingSurfaceView is only created in code")
    }

    /// The overlay window already ignores the mouse. Returning nil here as well makes sure this
    /// view can never be the reason a click fails to reach the app underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Where one of this turn's screenshots sits: the display it shows and how its pixels map onto it.
struct ClickyDrawingDisplayPlacement {
    /// The display's frame in global AppKit coordinates, as `CompanionScreenCapture.displayFrame`.
    let displayFrame: CGRect
    let screenshotToDisplayMapping: ClickyScreenshotToDisplayMapping
}

extension CompanionScreenCapture {
    /// How this screenshot's pixels map onto its display. Pointing and drawing both use it.
    var screenshotToDisplayMapping: ClickyScreenshotToDisplayMapping {
        ClickyScreenshotToDisplayMapping(
            screenshotWidthInPixels: Double(screenshotWidthInPixels),
            screenshotHeightInPixels: Double(screenshotHeightInPixels),
            displayWidthInPoints: Double(displayWidthInPoints),
            displayHeightInPoints: Double(displayHeightInPoints)
        )
    }
}

@MainActor
final class ClickyDrawingOverlayController {

    // MARK: - Lifetime and fade timings

    /// Marks stay this long after Clicky has finished speaking, then fade.
    static let secondsMarksStayAfterReplyEnds: TimeInterval = 12

    /// The explanation card is something to read, not a pointer at the page, so it stays longer
    /// than the other marks after Clicky has finished speaking.
    static let secondsExplanationCardStaysAfterReplyEnds: TimeInterval = 20

    /// The 3D scene is something to look at from every side, and one turn of the model takes
    /// 14 seconds, so it stays longest of all after Clicky has finished speaking.
    static let secondsSceneStaysAfterReplyEnds: TimeInterval = 25

    /// A turn that never finishes (the transcript was empty, a request hung) must not leave marks
    /// on the screen for ever. After this long without a finished reply they fade anyway.
    static let maximumSecondsMarksAreKeptWithoutAFinishedReply: TimeInterval = 60

    static let lifetimeFadeOutSeconds: Double = 0.6
    static let eraseFadeOutSeconds: Double = 0.25
    static let scrollFadeOutSeconds: Double = 0.3
    static let applicationSwitchFadeOutSeconds: Double = 0.2

    // MARK: - State

    /// The marks and their numbering. What is on the screen always mirrors this.
    private var drawingBoard = ClickyDrawingBoard()

    private var drawingSurfaceViews: [ClickyDrawingSurfaceView] = []

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
    private var scenePanelPlacementsByMarkNumber: [Int: ClickyScenePanelPlacementResult] = [:]

    /// The scene as it will be once every part accepted so far has been shown. The panel frames
    /// the model for these parts, so the camera does not move again for each part of a reply.
    private var plannedScenesByMarkNumber: [Int: ClickyScene] = [:]

    /// The views of the scenes that have actually been shown.
    private var scenePanelViewsByMarkNumber: [Int: ClickyScenePanelView] = [:]

    /// Where the tag of each callout on the screen was put, and the place it points at, both in
    /// points from the display's top-left corner. A new callout is kept clear of them.
    private var calloutTagFramesFromTopLeftByMarkNumber: [Int: CGRect] = [:]
    private var calloutTargetsFromTopLeftByMarkNumber: [Int: CGPoint] = [:]

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
            // Clicky itself coming to the front (its panel, a permission prompt) is not the user
            // moving on to other content.
            let activatedApplicationIsClicky = activatedApplication?.processIdentifier == ownProcessIdentifier
            guard !activatedApplicationIsClicky else { return }
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
    /// joins every Space and is left out of Clicky's screenshots.
    func addDrawingSurface(onTopOf overlayContentView: NSView, displayFrame: CGRect) {
        let drawingSurfaceView = ClickyDrawingSurfaceView(displayFrame: displayFrame, frame: overlayContentView.bounds)
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

    // MARK: - What is on screen

    var hasMarksOnScreen: Bool {
        !drawingBoard.isEmpty
    }

    /// The marks to list in the next prompt, with screen numbers that match this turn's
    /// screenshots. Screens are numbered per turn (the cursor's screen comes first), so the number
    /// a mark was drawn with may now mean another screen; it is looked up again from the display
    /// the mark is on. A mark whose display is no longer connected is removed.
    func drawingMarksForPrompt(displayFramesInScreenshotOrder: [CGRect]) -> [ClickyDrawingMark] {
        var marksForPrompt: [ClickyDrawingMark] = []
        var markNumbersOnMissingDisplays: [Int] = []
        for markOnBoard in drawingBoard.marks {
            guard let markDisplayFrame = displayFramesByMarkNumber[markOnBoard.markNumber],
                  let screenshotIndex = displayFramesInScreenshotOrder.firstIndex(of: markDisplayFrame) else {
                markNumbersOnMissingDisplays.append(markOnBoard.markNumber)
                continue
            }
            marksForPrompt.append(ClickyDrawingMark(
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
        let secondsUntilLastMarkIsDrawn = max(0, latestScheduledDrawingEndUptimeSeconds - ClickyTurnMetrics.currentUptimeSeconds)
        scheduleLifetimeFade(
            afterSeconds: secondsUntilLastMarkIsDrawn + Self.secondsMarksStayAfterReplyEnds,
            extraSecondsExplanationCardStays: Self.secondsExplanationCardStaysAfterReplyEnds - Self.secondsMarksStayAfterReplyEnds,
            extraSecondsSceneStays: Self.secondsSceneStaysAfterReplyEnds - Self.secondsMarksStayAfterReplyEnds
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
            let explanationCardMarkThatStays = extraSecondsExplanationCardStays > 0 ? self.drawingBoard.explanationCardMark : nil
            let sceneMarkThatStays = extraSecondsSceneStays > 0 ? self.drawingBoard.sceneMark : nil
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
                    extraSecondsSceneStays: sceneMarkThatStays != nil ? max(0, extraSecondsSceneStays - extraSecondsExplanationCardStays) : 0
                )
            } else {
                self.scheduleLifetimeFade(afterSeconds: extraSecondsSceneStays)
            }
        }
        lifetimeFadeWorkItem = fadeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsUntilFade, execute: fadeWorkItem)
    }

    // MARK: - Drawing a reply

    /// Carries out the draw commands of one reply, each at its moment in the speech.
    ///
    /// Call this right after the audio has started, with the audio's length, or with nil when
    /// there is no audio; the marks then follow each other at a steady beat.
    /// `displayPlacementsInScreenshotOrder` describes this turn's screenshots in the order Claude
    /// saw them, and `cursorScreenshotIndex` is the one the cursor was on.
    func performDrawCommands(
        _ parsedDrawCommands: [ClickyParsedDrawCommand],
        displayPlacementsInScreenshotOrder: [ClickyDrawingDisplayPlacement],
        cursorScreenshotIndex: Int?,
        speechAudioDurationSeconds: Double?
    ) {
        guard !parsedDrawCommands.isEmpty else { return }

        // Work out where each new mark goes first, because how long the pen takes depends on the
        // mark's size on the display. A mark with no screen to go on is dropped.
        struct PlacedDrawCommand {
            let parsedDrawCommand: ClickyParsedDrawCommand
            let displayPlacement: ClickyDrawingDisplayPlacement?
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
                    penTravelLengthInPoints = ClickyExplanationCardLayerBuilder.penTravelLengthInPoints(for: cardRow)
                }
                placedDrawCommands.append(PlacedDrawCommand(parsedDrawCommand: parsedDrawCommand, displayPlacement: nil, penTravelLengthInPoints: penTravelLengthInPoints))
                continue
            }
            guard let screenshotIndex = ClickyScreenshotToDisplayMapping.screenshotIndex(
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
                penTravelLengthInPoints: ClickyHandDrawnPathGenerator.penTravelLengthInPoints(forShapeInDisplayPoints: shapeInDisplayPoints)
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

        let scheduledTimes = ClickyDrawingSchedule.scheduledTimes(
            forSpokenFractionsBeforeTags: spokenFractionsWhereSentencesBegin,
            penTravelLengthsInPoints: placedDrawCommands.map(\.penTravelLengthInPoints),
            speechAudioDurationSeconds: speechAudioDurationSeconds
        )

        let nowUptimeSeconds = ClickyTurnMetrics.currentUptimeSeconds
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
                    var marksOfThisReplyOnTheCardsDisplay: [ClickyDrawingShape] = []
                    for (otherCommandIndex, otherPlacedDrawCommand) in placedDrawCommands.enumerated() {
                        switch otherPlacedDrawCommand.parsedDrawCommand.command {
                        case .addCardRow(let cardRow):
                            if otherCommandIndex > placedCommandIndex, cardWithRowsOfThisReply.rows.count < ClickyExplanationCard.maximumRowCount {
                                cardWithRowsOfThisReply = cardWithRowsOfThisReply.addingRow(cardRow)
                            }
                        case .addMark(let otherShapeInScreenshotPixels, _):
                            if let otherDisplayPlacement = otherPlacedDrawCommand.displayPlacement,
                               otherDisplayPlacement.displayFrame == displayPlacement.displayFrame {
                                marksOfThisReplyOnTheCardsDisplay.append(otherDisplayPlacement.screenshotToDisplayMapping.shapeInDisplayPoints(
                                    forShapeInScreenshotPixels: otherShapeInScreenshotPixels
                                ))
                            }
                        case .eraseMark, .undoNewestMark, .clearAllMarks, .addScenePart:
                            break
                        }
                    }
                    let displaySizeInPoints = displayPlacement.displayFrame.size
                    let plannedCardFrame = ClickyExplanationCardPlacement.cardFrame(
                        forCardSize: ClickyExplanationCardLayerBuilder.cardLayout(for: cardWithRowsOfThisReply).cardSize,
                        displaySizeInPoints: displaySizeInPoints,
                        menuBarHeightInPoints: menuBarHeightInPoints(forDisplayFrame: displayPlacement.displayFrame),
                        placesCardInLeftThird: ClickyExplanationCardPlacement.marksAreMostlyOnRightHalf(
                            markAnchorXsInDisplayPoints: marksOfThisReplyOnTheCardsDisplay.compactMap { $0.placeTheShapeIsAbout?.x },
                            displayWidthInPoints: Double(displaySizeInPoints.width)
                        )
                    )
                    // It opens with its title alone and grows downwards from this corner.
                    explanationCardFramesFromTopLeftByMarkNumber[addedMark.markNumber] = CGRect(
                        origin: plannedCardFrame.origin,
                        size: ClickyExplanationCardLayerBuilder.cardLayout(for: openedCard).cardSize
                    )
                    plannedFullExplanationCardFramesFromTopLeftByMarkNumber[addedMark.markNumber] = plannedCardFrame
                }
                if case .scene(let openedScene) = addedMark.shape {
                    // Without Metal there is nothing to draw the model with. The scene is dropped
                    // silently (its parts then find no scene to go in) and the reply is still spoken.
                    guard ClickyScenePanelView.canRenderScenes else {
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
                            if otherCommandIndex > placedCommandIndex, sceneWithPartsOfThisReply.parts.count < ClickyScene.maximumPartCount {
                                sceneWithPartsOfThisReply = sceneWithPartsOfThisReply.addingPart(scenePart)
                            }
                        case .addMark(let otherShapeInScreenshotPixels, _):
                            if let otherDisplayPlacement = otherPlacedDrawCommand.displayPlacement,
                               otherDisplayPlacement.displayFrame == displayPlacement.displayFrame,
                               let occupiedFrame = ClickyScenePanelPlacement.occupiedFrame(
                                   ofShapeInDisplayPoints: otherDisplayPlacement.screenshotToDisplayMapping.shapeInDisplayPoints(
                                       forShapeInScreenshotPixels: otherShapeInScreenshotPixels
                                   )
                               ) {
                                occupiedFramesOnTheScenesDisplay.append(occupiedFrame)
                            }
                        case .eraseMark, .undoNewestMark, .clearAllMarks, .addCardRow:
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
                    // known before the corner is.
                    let panelSize = ClickyScenePanelLayoutCalculator.layout(
                        hasLabelColumn: sceneWithPartsOfThisReply.hasLabelledParts,
                        labelColumnIsOnLeftOfModel: true
                    ).panelSize
                    scenePanelPlacementsByMarkNumber[addedMark.markNumber] = ClickyScenePanelPlacement.placement(
                        forPanelSize: panelSize,
                        displaySizeInPoints: displaySizeInPoints,
                        menuBarHeightInPoints: menuBarHeightInPoints,
                        statusPillKeepClearFrame: ClickyScenePanelPlacement.statusPillKeepClearFrame(
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
                    nowUptimeSeconds + scheduledTime.startSecondsAfterSpeechBegins + ClickyScenePanelView.partAppearSeconds
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

        for commandToCancel in commandsToCancel {
            commandToCancel.dispatchWorkItem.cancel()
            switch commandToCancel.work {
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
    func fadeMarksThatPointAtScreenContent() {
        guard !isIgnoringScrollAndApplicationSwitchClearing else { return }
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

    private func drawingSurfaceView(forDisplayFrame displayFrame: CGRect) -> ClickyDrawingSurfaceView? {
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

    private func drawMarkOnScreen(_ mark: ClickyDrawingMark, displayPlacement: ClickyDrawingDisplayPlacement, penDurationSeconds: Double) {
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
            markLayer = ClickyExplanationCardLayerBuilder.makeCardLayer(
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
                    occupiedFrames.append(ClickyCalloutPlacement.clearFrame(aroundTarget: otherTarget))
                }
                if let cardFrame = explanationCardFramesFromTopLeftByMarkNumber[otherMarkNumber] {
                    occupiedFrames.append(cardFrame)
                }
                if let scenePanelPlacement = scenePanelPlacementsByMarkNumber[otherMarkNumber] {
                    occupiedFrames.append(scenePanelPlacement.panelFrame)
                }
            }
            let tagFrameFromTopLeft = ClickyCalloutPlacement.tagFrame(
                forTargetInDisplayPoints: targetInDisplayPoints,
                tagSize: ClickyExplanationCardLayerBuilder.calloutTagSize(forText: text),
                displaySizeInPoints: displaySizeInPoints,
                menuBarHeightInPoints: menuBarHeightInPoints(forDisplayFrame: displayPlacement.displayFrame),
                occupiedFrames: occupiedFrames
            )
            calloutTagFramesFromTopLeftByMarkNumber[mark.markNumber] = tagFrameFromTopLeft
            calloutTargetsFromTopLeftByMarkNumber[mark.markNumber] = targetInDisplayPoints
            markLayer = ClickyExplanationCardLayerBuilder.makeCalloutLayer(
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

        case .arrow, .circle, .box, .underline, .highlight, .label, .stickyNote:
            markLayer = ClickyDrawingMarkLayerBuilder.makeMarkLayer(
                forMarkNumber: mark.markNumber,
                shapeInDisplayPoints: shapeInDisplayPoints,
                displaySizeInPoints: displaySizeInPoints,
                backingScaleFactor: backingScaleFactor
            )
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.addSublayer(markLayer)
        CATransaction.commit()
        markLayersByMarkNumber[mark.markNumber] = markLayer
        let surfaceWindow = drawingSurfaceView.window
        print("✏️ draw: mark m\(mark.markNumber) \(mark.shape.tagKindName) drawn layerFrame=\(markLayer.frame.integral) surfaceFrame=\(drawingSurfaceView.frame.integral) inWindow=\(surfaceWindow != nil) windowVisible=\(surfaceWindow?.isVisible ?? false) windowAlpha=\(surfaceWindow?.alphaValue ?? -1) hidden=\(drawingSurfaceView.isHiddenOrHasHiddenAncestor)")

        if case .callout = shapeInDisplayPoints {
            // The tag fades in while the pen draws the leader line.
            ClickyExplanationCardLayerBuilder.animateCalloutAppearance(of: markLayer, penDurationSeconds: penDurationSeconds)
        } else {
            // Ink is revealed with the pen; a label, a sticky note and the card fade and grow in.
            ClickyDrawingMarkLayerBuilder.animateAppearance(of: markLayer, penDurationSeconds: penDurationSeconds)
        }
    }

    /// Writes one row on the explanation card that is on the screen. `cardMark` is the card with
    /// the row already on it. Nothing happens when the card has gone (erased, cleared, faded)
    /// while the row waited for its moment.
    private func drawCardRowOnScreen(cardMark: ClickyDrawingMark, rowIndex: Int, penDurationSeconds: Double) {
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
        let grownCardFrameFromTopLeft = ClickyExplanationCardPlacement.cardFrameAfterGrowing(
            from: currentCardFrameFromTopLeft,
            toCardSize: ClickyExplanationCardLayerBuilder.cardLayout(for: cardWithRow).cardSize,
            displaySizeInPoints: displaySizeInPoints,
            menuBarHeightInPoints: menuBarHeightInPoints(forDisplayFrame: cardDisplayFrame)
        )
        explanationCardFramesFromTopLeftByMarkNumber[cardMark.markNumber] = grownCardFrameFromTopLeft

        ClickyExplanationCardLayerBuilder.addRow(
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

    /// Where a panel frame given from the display's top-left corner is in the container view,
    /// which, like every AppKit view here, measures from its bottom-left corner.
    private func frameInContainerView(forFrameFromTopLeft frameFromTopLeft: CGRect, displaySizeInPoints: CGSize) -> CGRect {
        CGRect(
            x: frameFromTopLeft.minX,
            y: displaySizeInPoints.height - frameFromTopLeft.maxY,
            width: frameFromTopLeft.width,
            height: frameFromTopLeft.height
        )
    }

    /// Puts the panel of a newly opened scene on the screen: the paper and the title, with the
    /// camera already framing the parts that are about to follow. The parts themselves arrive
    /// one by one through `drawScenePartOnScreen`.
    private func showScenePanelOnScreen(
        sceneMarkNumber: Int,
        scene: ClickyScene,
        drawingSurfaceView: ClickyDrawingSurfaceView,
        backingScaleFactor: CGFloat
    ) {
        // The panel is a sibling of the drawing surface in the overlay window's plain container
        // view. It must not go inside the SwiftUI hosting view, which does not show such views.
        guard let scenePanelPlacement = scenePanelPlacementsByMarkNumber[sceneMarkNumber],
              let overlayContainerView = drawingSurfaceView.superview else {
            print("✏️ draw: scene m\(sceneMarkNumber) not shown (no place or no container view)")
            return
        }
        let plannedScene = plannedScenesByMarkNumber[sceneMarkNumber] ?? scene
        let panelLayout = ClickyScenePanelLayoutCalculator.layout(
            hasLabelColumn: plannedScene.hasLabelledParts,
            labelColumnIsOnLeftOfModel: scenePanelPlacement.corner.isOnRightSideOfScreen
        )
        let scenePanelView = ClickyScenePanelView(
            sceneTitle: scene.title,
            cameraFit: ClickySceneCamera.cameraFit(for: plannedScene.parts),
            panelLayout: panelLayout,
            panelFrameInContainer: frameInContainerView(
                forFrameFromTopLeft: scenePanelPlacement.panelFrame,
                displaySizeInPoints: drawingSurfaceView.displayFrame.size
            ),
            backingScaleFactor: backingScaleFactor
        )
        // A scene opened with parts already in it (none does today) shows them at once.
        for (partIndex, part) in scene.parts.enumerated() {
            scenePanelView.addPart(
                part,
                labelNumber: scene.labelNumber(forPartAtIndex: partIndex),
                cameraFit: ClickySceneCamera.cameraFit(for: plannedScene.parts),
                isAnimated: false
            )
        }
        overlayContainerView.addSubview(scenePanelView, positioned: .above, relativeTo: drawingSurfaceView)
        scenePanelViewsByMarkNumber[sceneMarkNumber] = scenePanelView
        scenePanelView.fadeInAndStartTurning()
        print("✏️ draw: scene m\(sceneMarkNumber) shown panelFrame=\(scenePanelPlacement.panelFrame.integral) corner=\(scenePanelPlacement.corner) plannedParts=\(plannedScene.parts.count)")
    }

    /// Adds one part to the scene that is on the screen. `sceneMark` is the scene with the part
    /// already in it. Nothing happens when the scene has gone (erased, cleared, faded) while the
    /// part waited for its moment.
    private func drawScenePartOnScreen(sceneMark: ClickyDrawingMark, partIndex: Int) {
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
        // them on the side facing the middle of the screen. The panel keeps its corner, so the
        // model does not move.
        if plannedScene.hasLabelledParts, scenePanelView.panelLayout.labelColumnFrame == nil {
            let panelLayoutWithLabelColumn = ClickyScenePanelLayoutCalculator.layout(
                hasLabelColumn: true,
                labelColumnIsOnLeftOfModel: scenePanelPlacement.corner.isOnRightSideOfScreen
            )
            let grownPanelFrame = ClickyScenePanelPlacement.panelFrame(
                forPanelSize: panelLayoutWithLabelColumn.panelSize,
                corner: scenePanelPlacement.corner,
                displaySizeInPoints: sceneDisplayFrame.size,
                menuBarHeightInPoints: menuBarHeightInPoints(forDisplayFrame: sceneDisplayFrame)
            )
            scenePanelPlacementsByMarkNumber[sceneMark.markNumber] = ClickyScenePanelPlacementResult(
                panelFrame: grownPanelFrame,
                corner: scenePanelPlacement.corner
            )
            scenePanelView.applyPanelLayout(
                panelLayoutWithLabelColumn,
                panelFrameInContainer: frameInContainerView(forFrameFromTopLeft: grownPanelFrame, displaySizeInPoints: sceneDisplayFrame.size)
            )
        }

        scenePanelView.addPart(
            sceneWithPart.parts[partIndex],
            labelNumber: sceneWithPart.labelNumber(forPartAtIndex: partIndex),
            cameraFit: ClickySceneCamera.cameraFit(for: plannedScene.parts),
            isAnimated: true
        )
        print("✏️ draw: part \(partIndex + 1) of scene m\(sceneMark.markNumber) shown (\(sceneWithPart.parts[partIndex].shapeKind.rawValue))")
    }

    private func removeMarkFromScreen(markNumber: Int, fadeOutSeconds: Double) {
        displayFramesByMarkNumber[markNumber] = nil
        explanationCardFramesFromTopLeftByMarkNumber[markNumber] = nil
        plannedFullExplanationCardFramesFromTopLeftByMarkNumber[markNumber] = nil
        scenePanelPlacementsByMarkNumber[markNumber] = nil
        plannedScenesByMarkNumber[markNumber] = nil
        // The scene's view stops its renderer and leaves the window, so it costs nothing once gone.
        if let scenePanelView = scenePanelViewsByMarkNumber.removeValue(forKey: markNumber) {
            scenePanelView.fadeOutAndRemove(fadeOutSeconds: fadeOutSeconds)
        }
        calloutTagFramesFromTopLeftByMarkNumber[markNumber] = nil
        calloutTargetsFromTopLeftByMarkNumber[markNumber] = nil
        guard let markLayer = markLayersByMarkNumber.removeValue(forKey: markNumber) else {
            return
        }
        ClickyDrawingMarkLayerBuilder.fadeOutAndRemove(markLayer, fadeOutSeconds: fadeOutSeconds)
    }
}
