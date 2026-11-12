//
//  ClickyScenePanelView.swift
//  leanring-buddy
//
//  Shows one simple 3D scene: a small sheet of the same cream paper the explanation card uses,
//  with a title, a slowly turning model built from basic shapes, and a column of numbered tags
//  whose leader lines follow their parts. Built from public Apple APIs (SceneKit, AppKit, Core
//  Animation) with our own design. The model is a schematic made of primitives, and is built only
//  from the validated parts of `ClickyScene`: nothing is loaded from a file, scripted or fetched.
//
//  What is pure (limits, palette, bounds, camera fit, projection, layout, placement) lives in
//  `ClickyCore/ClickySceneModel.swift`. This file holds the SceneKit and AppKit half and every
//  look constant of the scene.
//

import AppKit
import Metal
import QuartzCore
import SceneKit
// For `NSColor(_: Color)`, which turns the design system's colours into AppKit colours.
import SwiftUI

// MARK: - The SceneKit scene

/// The SceneKit objects of one scene: the turning model, the camera and the lights. It knows
/// nothing about views, so the same graph is shown by the panel and rendered offscreen by the
/// smoke program.
final class ClickySceneGraph {

    // MARK: Geometry limits

    /// How many flat sides a round shape gets. Enough to look round at the size a scene is shown,
    /// and few enough that a full scene of twelve parts stays a few thousand triangles.
    static let roundShapeSegmentCount = 24
    /// The round ends of a capsule, from the rim to the tip.
    static let capsuleCapSegmentCount = 8
    /// A box gets softly rounded edges, this share of its shortest side, so its faces catch the
    /// light differently and it reads as a solid.
    static let boxChamferShareOfShortestSide: CGFloat = 0.06
    static let boxChamferSegmentCount = 2

    // MARK: Light

    /// The main light, from the upper left in front of the model.
    static let keyLightIntensity: CGFloat = 760
    static let keyLightPitchInDegrees: CGFloat = -45
    static let keyLightYawInDegrees: CGFloat = -30
    /// A weaker light from the right that keeps the shaded side from going black.
    static let fillLightIntensity: CGFloat = 300
    static let fillLightPitchInDegrees: CGFloat = -15
    static let fillLightYawInDegrees: CGFloat = 50
    /// Light from everywhere, so no face is ever fully dark.
    static let ambientLightIntensity: CGFloat = 380

    // MARK: Motion

    /// A part grows from this share of its size while it fades in.
    static let partAppearStartScale: CGFloat = 0.6
    /// A translucent part is drawn after the solid ones, so what is inside it shows through.
    static let translucentPartRenderingOrder = 10

    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Turns around the vertical axis. It sits at the middle of the picture; the model inside it
    /// is moved so its own middle is on that axis.
    private let turningPivotNode = SCNNode()
    private let modelNode = SCNNode()
    private(set) var cameraFit: ClickySceneCameraFit

    init(cameraFit: ClickySceneCameraFit) {
        self.cameraFit = cameraFit

        // The paper behind the model must show through.
        scene.background.contents = NSColor.clear

        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(ClickySceneCamera.verticalFieldOfViewInDegrees)
        camera.projectionDirection = .vertical
        camera.automaticallyAdjustsZRange = true
        cameraNode.camera = camera
        // Pitched down by the tilt: the camera then looks from its raised place at the origin.
        cameraNode.eulerAngles = SCNVector3(-CGFloat(ClickySceneCamera.downwardTiltInDegrees) * .pi / 180, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        // The lights stand still while the model turns, so its faces brighten and darken as they
        // pass, which is what makes a matte shape read as three-dimensional.
        scene.rootNode.addChildNode(Self.makeDirectionalLightNode(
            intensity: Self.keyLightIntensity,
            pitchInDegrees: Self.keyLightPitchInDegrees,
            yawInDegrees: Self.keyLightYawInDegrees
        ))
        scene.rootNode.addChildNode(Self.makeDirectionalLightNode(
            intensity: Self.fillLightIntensity,
            pitchInDegrees: Self.fillLightPitchInDegrees,
            yawInDegrees: Self.fillLightYawInDegrees
        ))
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = Self.ambientLightIntensity
        ambientLight.color = NSColor.white
        let ambientLightNode = SCNNode()
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)

        turningPivotNode.addChildNode(modelNode)
        scene.rootNode.addChildNode(turningPivotNode)

        placeCameraAndModel(for: cameraFit)
    }

    private static func makeDirectionalLightNode(intensity: CGFloat, pitchInDegrees: CGFloat, yawInDegrees: CGFloat) -> SCNNode {
        let directionalLight = SCNLight()
        directionalLight.type = .directional
        directionalLight.intensity = intensity
        directionalLight.color = NSColor.white
        // No shadows: the model floats on paper, and a shadow map would cost more than the model.
        directionalLight.castsShadow = false
        let lightNode = SCNNode()
        lightNode.light = directionalLight
        lightNode.eulerAngles = SCNVector3(pitchInDegrees * .pi / 180, yawInDegrees * .pi / 180, 0)
        return lightNode
    }

    private func placeCameraAndModel(for cameraFit: ClickySceneCameraFit) {
        let cameraPosition = ClickySceneCamera.cameraPositionRelativeToModelCentre(for: cameraFit)
        cameraNode.position = SCNVector3(CGFloat(cameraPosition.x), CGFloat(cameraPosition.y), CGFloat(cameraPosition.z))
        // The middle of the model goes onto the turning axis, at the point the camera looks at.
        modelNode.position = SCNVector3(
            -CGFloat(cameraFit.modelCentre.x),
            -CGFloat(cameraFit.modelCentre.y),
            -CGFloat(cameraFit.modelCentre.z)
        )
    }

    /// Frames the model again, for when parts were added that the old fit did not hold. With
    /// `animationSeconds` above zero the camera glides to its new place instead of jumping.
    func applyCameraFit(_ newCameraFit: ClickySceneCameraFit, animationSeconds: Double) {
        guard newCameraFit != cameraFit else { return }
        cameraFit = newCameraFit
        SCNTransaction.begin()
        SCNTransaction.animationDuration = max(0, animationSeconds)
        placeCameraAndModel(for: newCameraFit)
        SCNTransaction.commit()
    }

    /// Adds one part to the model. With `appearSeconds` above zero it grows a little and fades in.
    func addPartNode(for part: ClickyScenePart, appearSeconds: Double) {
        let partNode = Self.makePartNode(for: part)
        if appearSeconds > 0 {
            partNode.opacity = 0
            partNode.scale = SCNVector3(Self.partAppearStartScale, Self.partAppearStartScale, Self.partAppearStartScale)
            let appearAction = SCNAction.group([
                SCNAction.fadeIn(duration: appearSeconds),
                SCNAction.scale(to: 1, duration: appearSeconds)
            ])
            appearAction.timingMode = .easeOut
            partNode.runAction(appearAction)
        }
        modelNode.addChildNode(partNode)
    }

    /// Starts the slow, endless turn around the vertical axis.
    func startTurning() {
        let oneTurnAction = SCNAction.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: ClickySceneCamera.secondsPerTurn)
        turningPivotNode.runAction(SCNAction.repeatForever(oneTurnAction), forKey: "clickySceneTurn")
    }

    /// Sets how far the model has turned, without animation. Used for a still picture.
    func setTurnAngle(inRadians turnAngleInRadians: Double) {
        turningPivotNode.eulerAngles = SCNVector3(0, CGFloat(turnAngleInRadians), 0)
    }

    /// How far the model is turned in the frame that is on the screen right now. Read from the
    /// node being presented, so it is right in the middle of the turn animation too.
    var turnAngleInRadiansOnScreenNow: Double {
        let presentedTransform = turningPivotNode.presentation.transform
        // For a turn around the vertical axis by an angle, m11 is its cosine and m31 its sine.
        return Double(atan2(presentedTransform.m31, presentedTransform.m11))
    }

    // MARK: Building a part

    static func makePartNode(for part: ClickyScenePart) -> SCNNode {
        let partGeometry = makeGeometry(for: part)
        partGeometry.materials = [makeMaterial(for: part.colour)]

        let partNode = SCNNode(geometry: partGeometry)
        partNode.position = SCNVector3(CGFloat(part.centre.x), CGFloat(part.centre.y), CGFloat(part.centre.z))
        // SceneKit builds cylinders, cones, tubes and capsules standing up (along y, a cone's tip
        // on top). They are laid over to point along x or z.
        if part.shapeKind.pointsAlongAnAxis {
            switch part.axis {
            case .x: partNode.eulerAngles = SCNVector3(0, 0, -CGFloat.pi / 2)
            case .y: break
            case .z: partNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
            }
        }
        if part.colour.isTranslucent {
            partNode.renderingOrder = translucentPartRenderingOrder
        }
        return partNode
    }

    static func makeGeometry(for part: ClickyScenePart) -> SCNGeometry {
        switch part.dimensions {
        case .box(let width, let height, let depth):
            let box = SCNBox(
                width: CGFloat(width),
                height: CGFloat(height),
                length: CGFloat(depth),
                chamferRadius: CGFloat(min(width, height, depth)) * boxChamferShareOfShortestSide
            )
            box.chamferSegmentCount = boxChamferSegmentCount
            return box

        case .sphere(let radius):
            let sphere = SCNSphere(radius: CGFloat(radius))
            sphere.segmentCount = roundShapeSegmentCount
            return sphere

        case .radiusAndLength(let radius, _):
            let length = CGFloat(part.lengthAlongAxis)
            switch part.shapeKind {
            case .cone:
                let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(radius), height: length)
                cone.radialSegmentCount = roundShapeSegmentCount
                cone.heightSegmentCount = 1
                return cone
            case .tube:
                let tube = SCNTube(
                    innerRadius: CGFloat(radius * ClickyScenePart.tubeInnerRadiusShareOfOuterRadius),
                    outerRadius: CGFloat(radius),
                    height: length
                )
                tube.radialSegmentCount = roundShapeSegmentCount
                tube.heightSegmentCount = 1
                return tube
            case .capsule:
                let capsule = SCNCapsule(capRadius: CGFloat(radius), height: length)
                capsule.radialSegmentCount = roundShapeSegmentCount
                capsule.capSegmentCount = capsuleCapSegmentCount
                capsule.heightSegmentCount = 1
                return capsule
            case .cylinder, .box, .sphere:
                // A box or sphere never has these dimensions; a cylinder is the plain round shape.
                let cylinder = SCNCylinder(radius: CGFloat(radius), height: length)
                cylinder.radialSegmentCount = roundShapeSegmentCount
                cylinder.heightSegmentCount = 1
                return cylinder
            }
        }
    }

    /// A matte material in one palette colour. `glass` is see-through and shows both of its sides.
    static func makeMaterial(for colour: ClickyScenePartColour) -> SCNMaterial {
        let colourComponents = colour.components
        let material = SCNMaterial()
        // Lambert shading has no highlight at all, which is what matte means.
        material.lightingModel = .lambert
        material.diffuse.contents = NSColor(
            srgbRed: CGFloat(colourComponents.red),
            green: CGFloat(colourComponents.green),
            blue: CGFloat(colourComponents.blue),
            alpha: 1
        )
        if colour.isTranslucent {
            material.transparency = CGFloat(colourComponents.opacity)
            material.isDoubleSided = true
            // Otherwise the glass would hide the parts behind it that are drawn after it.
            material.writesToDepthBuffer = false
        }
        return material
    }
}

// MARK: - Views

/// A plain view that only hosts its own layer and never takes the mouse.
private final class ClickySceneLayerHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Its own plain layer, set before wantsLayer, so AppKit leaves the layer's contents alone.
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClickySceneLayerHostView is only created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// The SceneKit view of a scene. It never takes the mouse, so clicks reach the app underneath.
private final class ClickyMouseTransparentSceneKitView: SCNView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// The whole panel of one scene. A plain AppKit view that the drawing overlay controller adds to
/// the overlay window's container view, next to the drawing surface (never inside the SwiftUI
/// hosting view, which does not show views added inside it).
final class ClickyScenePanelView: NSView {

    // MARK: Look and timing constants

    /// The view is this much larger than the paper on every side, so the paper's soft shadow has
    /// room and is never cut off at the view's edge.
    static let shadowRoomInPoints: CGFloat = 24

    /// The view's own frame rate cap. Thirty frames a second is smooth for so slow a turn, and
    /// half the display's rate keeps the model cheap while it turns.
    static let framesPerSecond = 30

    static let panelFadeInSeconds: Double = 0.25
    /// How long a part takes to grow and fade in, and its tag and leader line with it.
    static let partAppearSeconds: Double = 0.35
    /// How long the camera takes to frame a model that has grown.
    static let cameraRefitSeconds: Double = 0.35

    /// The far ends of the leader lines are moved this often (ten times a second), each time
    /// gliding to where the part will be when the next move comes, so they follow the model
    /// smoothly without any per-frame work.
    static let leaderUpdateIntervalSeconds: Double = 0.1

    static let leaderLineWidthInPoints: CGFloat = 1.2
    static let leaderLineOpacity: Float = 0.85
    /// The dot at the part's end of a leader line, with a paper-coloured rim so it shows on a
    /// part of any colour.
    static let leaderDotDiameterInPoints: CGFloat = 6
    static let leaderDotRimWidthInPoints: CGFloat = 1

    static let labelNumberFontSizeInPoints: CGFloat = 10
    /// The tags' words are a little smaller than the card's rows, so a name of two or three
    /// words fits beside the model.
    static let largestLabelFontSizeInPoints: CGFloat = 14

    /// True when this Mac can draw a scene at all. Without Metal the scene is dropped and only
    /// the spoken reply remains.
    static let canRenderScenes: Bool = MTLCreateSystemDefaultDevice() != nil

    // MARK: State

    let sceneGraph: ClickySceneGraph
    private let sceneTitle: String
    private let backingScaleFactor: CGFloat
    private(set) var panelLayout: ClickyScenePanelLayout

    private let paperHostView = ClickySceneLayerHostView(frame: .zero)
    private let sceneKitView: ClickyMouseTransparentSceneKitView
    private let leaderHostView = ClickySceneLayerHostView(frame: .zero)

    private let paperShadowLayer = CALayer()
    private let paperLayer = CALayer()
    private let paperGridLayer = CAShapeLayer()
    private let titleTextLayer = CATextLayer()

    private struct LabelledPart {
        let labelNumber: Int
        let labelText: String
        let partCentre: ClickySceneVector
        let tagLayer: CALayer
        let discLayer: CALayer
        let numberTextLayer: CATextLayer
        let wordsTextLayer: CATextLayer
        let leaderLineLayer: CAShapeLayer
        let leaderDotLayer: CALayer
    }

    private var labelledParts: [LabelledPart] = []
    private var leaderUpdateTask: Task<Void, Never>?

    // MARK: Typefaces

    /// The title is in the hand the card's rows are written in.
    static var titleFont: NSFont {
        ClickyExplanationCardLayerBuilder.rowFont
    }

    static var labelFont: NSFont {
        let rowFont = ClickyExplanationCardLayerBuilder.rowFont
        return NSFont(descriptor: rowFont.fontDescriptor, size: min(rowFont.pointSize, largestLabelFontSizeInPoints)) ?? rowFont
    }

    static var labelNumberFont: NSFont {
        ClickyDrawingMarkLayerBuilder.roundedSystemFont(ofSize: labelNumberFontSizeInPoints, weight: .bold)
    }

    // MARK: Creating

    /// `panelFrameInContainer` is where the paper goes in the container view's own coordinates
    /// (AppKit's, measured from the bottom-left corner). `cameraFit` frames the model for the
    /// parts this reply is about to add, so the camera does not have to move after each of them.
    init(
        sceneTitle: String,
        cameraFit: ClickySceneCameraFit,
        panelLayout: ClickyScenePanelLayout,
        panelFrameInContainer: CGRect,
        backingScaleFactor: CGFloat
    ) {
        self.sceneTitle = sceneTitle
        self.sceneGraph = ClickySceneGraph(cameraFit: cameraFit)
        self.panelLayout = panelLayout
        self.backingScaleFactor = backingScaleFactor
        self.sceneKitView = ClickyMouseTransparentSceneKitView(frame: .zero)
        super.init(frame: panelFrameInContainer.insetBy(dx: -Self.shadowRoomInPoints, dy: -Self.shadowRoomInPoints))
        wantsLayer = true

        sceneKitView.scene = sceneGraph.scene
        sceneKitView.pointOfView = sceneGraph.cameraNode
        // Transparent, so the paper shows behind the model.
        sceneKitView.backgroundColor = .clear
        sceneKitView.antialiasingMode = .multisampling4X
        sceneKitView.preferredFramesPerSecond = Self.framesPerSecond
        sceneKitView.allowsCameraControl = false
        sceneKitView.autoenablesDefaultLighting = false
        // Only draws while something moves; the turn keeps it going until the view is torn down.
        sceneKitView.rendersContinuously = false

        // Back to front: the paper with the title and tags, the model, then the leader lines,
        // which must cross over the model to reach their parts.
        addSubview(paperHostView)
        addSubview(sceneKitView)
        addSubview(leaderHostView)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paperShadowLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingCardPaper).cgColor
        paperShadowLayer.cornerRadius = ClickyExplanationCardLayerBuilder.cardCornerRadiusInPoints
        paperShadowLayer.shadowColor = NSColor.black.cgColor
        paperShadowLayer.shadowOpacity = ClickyExplanationCardLayerBuilder.cardShadowOpacity
        paperShadowLayer.shadowRadius = ClickyExplanationCardLayerBuilder.cardShadowRadiusInPoints
        // Negative is downwards, because a layer's own coordinates grow upwards.
        paperShadowLayer.shadowOffset = CGSize(width: 0, height: -ClickyExplanationCardLayerBuilder.cardShadowVerticalOffsetInPoints)
        paperHostView.layer?.addSublayer(paperShadowLayer)

        // The paper clips the grid to its rounded corners, and a layer that clips cannot cast a
        // shadow, which is why the shadow has a layer of its own underneath.
        paperLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingCardPaper).cgColor
        paperLayer.cornerRadius = ClickyExplanationCardLayerBuilder.cardCornerRadiusInPoints
        paperLayer.borderColor = NSColor(DS.Colors.overlayDrawingCardEdge).cgColor
        paperLayer.borderWidth = ClickyExplanationCardLayerBuilder.cardEdgeWidthInPoints
        paperLayer.masksToBounds = true
        paperGridLayer.fillColor = nil
        paperGridLayer.strokeColor = NSColor(DS.Colors.overlayDrawingCardGridLine).cgColor
        paperGridLayer.lineWidth = ClickyExplanationCardLayerBuilder.cardGridLineWidthInPoints
        paperGridLayer.contentsScale = backingScaleFactor
        paperLayer.addSublayer(paperGridLayer)
        paperHostView.layer?.addSublayer(paperLayer)

        titleTextLayer.string = NSAttributedString(string: sceneTitle, attributes: [
            .font: Self.titleFont,
            .foregroundColor: NSColor(DS.Colors.overlayDrawingCardText)
        ])
        titleTextLayer.alignmentMode = .left
        // A title wider than the paper ends in an ellipsis.
        titleTextLayer.truncationMode = .end
        titleTextLayer.contentsScale = backingScaleFactor
        paperHostView.layer?.addSublayer(titleTextLayer)
        CATransaction.commit()

        layOutPanelContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClickyScenePanelView is only created in code")
    }

    /// The overlay window already ignores the mouse. Returning nil here as well makes sure the
    /// scene can never be the reason a click fails to reach the app underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: Showing and removing

    /// Fades the panel in and starts the model turning. Call once, after adding it to its container.
    func fadeInAndStartTurning() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = Self.panelFadeInSeconds
            self.animator().alphaValue = 1
        }
        sceneGraph.startTurning()
        sceneKitView.isPlaying = true
        startFollowingTheModelWithLeaderLines()
    }

    /// Fades the panel out, then stops the renderer and takes the view away, so a scene that has
    /// gone costs nothing. With zero seconds it is gone at once.
    func fadeOutAndRemove(fadeOutSeconds: Double) {
        leaderUpdateTask?.cancel()
        leaderUpdateTask = nil
        guard fadeOutSeconds > 0 else {
            stopRenderingAndRemoveFromContainer()
            return
        }
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = fadeOutSeconds
            self.animator().alphaValue = 0
        }
        // The view is kept alive by this closure until the fade is over.
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutSeconds) {
            self.stopRenderingAndRemoveFromContainer()
        }
    }

    private func stopRenderingAndRemoveFromContainer() {
        sceneKitView.isPlaying = false
        sceneKitView.scene = nil
        removeFromSuperview()
    }

    // MARK: Adding parts

    /// Adds one part to the model. `labelNumber` is the number on its tag, or nil for a part
    /// without a label. `cameraFit` frames the model with this part (and the ones still to come
    /// in this reply) in it.
    func addPart(_ part: ClickyScenePart, labelNumber: Int?, cameraFit: ClickySceneCameraFit, isAnimated: Bool) {
        sceneGraph.applyCameraFit(cameraFit, animationSeconds: isAnimated ? Self.cameraRefitSeconds : 0)
        sceneGraph.addPartNode(for: part, appearSeconds: isAnimated ? Self.partAppearSeconds : 0)

        guard let labelNumber, let labelText = part.labelText else { return }
        addLabelTag(labelNumber: labelNumber, labelText: labelText, partCentre: part.centre, isAnimated: isAnimated)
    }

    private func addLabelTag(labelNumber: Int, labelText: String, partCentre: ClickySceneVector, isAnimated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let tagLayer = CALayer()
        let discLayer = CALayer()
        discLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingInk).cgColor
        discLayer.cornerRadius = CGFloat(ClickyScenePanelLayoutCalculator.labelDiscDiameterInPoints) / 2
        tagLayer.addSublayer(discLayer)

        let numberTextLayer = CATextLayer()
        numberTextLayer.string = NSAttributedString(string: String(labelNumber), attributes: [
            .font: Self.labelNumberFont,
            .foregroundColor: NSColor.white
        ])
        numberTextLayer.alignmentMode = .center
        numberTextLayer.contentsScale = backingScaleFactor
        tagLayer.addSublayer(numberTextLayer)

        let wordsTextLayer = CATextLayer()
        wordsTextLayer.string = NSAttributedString(string: labelText, attributes: [
            .font: Self.labelFont,
            .foregroundColor: NSColor(DS.Colors.overlayDrawingCardText)
        ])
        // A name wider than the column ends in an ellipsis.
        wordsTextLayer.truncationMode = .end
        wordsTextLayer.contentsScale = backingScaleFactor
        tagLayer.addSublayer(wordsTextLayer)
        paperHostView.layer?.addSublayer(tagLayer)

        let leaderLineLayer = CAShapeLayer()
        leaderLineLayer.fillColor = nil
        leaderLineLayer.strokeColor = NSColor(DS.Colors.overlayDrawingInk).cgColor
        leaderLineLayer.lineWidth = Self.leaderLineWidthInPoints
        leaderLineLayer.lineCap = .round
        leaderLineLayer.opacity = Self.leaderLineOpacity
        leaderLineLayer.contentsScale = backingScaleFactor
        leaderHostView.layer?.addSublayer(leaderLineLayer)

        let leaderDotLayer = CALayer()
        leaderDotLayer.bounds = CGRect(x: 0, y: 0, width: Self.leaderDotDiameterInPoints, height: Self.leaderDotDiameterInPoints)
        leaderDotLayer.cornerRadius = Self.leaderDotDiameterInPoints / 2
        leaderDotLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingInk).cgColor
        leaderDotLayer.borderColor = NSColor(DS.Colors.overlayDrawingCardPaper).cgColor
        leaderDotLayer.borderWidth = Self.leaderDotRimWidthInPoints
        leaderHostView.layer?.addSublayer(leaderDotLayer)

        let labelledPart = LabelledPart(
            labelNumber: labelNumber,
            labelText: labelText,
            partCentre: partCentre,
            tagLayer: tagLayer,
            discLayer: discLayer,
            numberTextLayer: numberTextLayer,
            wordsTextLayer: wordsTextLayer,
            leaderLineLayer: leaderLineLayer,
            leaderDotLayer: leaderDotLayer
        )
        labelledParts.append(labelledPart)
        layOutLabelTag(of: labelledPart)
        CATransaction.commit()

        updateLeaderLines(forTurnAngleInRadians: sceneGraph.turnAngleInRadiansOnScreenNow, glideSeconds: 0)

        if isAnimated {
            // The tag and its leader line appear together with their part.
            for appearingLayer in [tagLayer, leaderLineLayer, leaderDotLayer] {
                let fadeInAnimation = CABasicAnimation(keyPath: "opacity")
                fadeInAnimation.fromValue = 0
                fadeInAnimation.toValue = appearingLayer.opacity
                fadeInAnimation.duration = Self.partAppearSeconds
                fadeInAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                appearingLayer.add(fadeInAnimation, forKey: "clickySceneLabelAppear")
            }
        }
    }

    // MARK: Layout

    /// Gives the panel a new layout and place, for when the first labelled part arrives on a
    /// scene that had no column of tags. The column is on the side facing the middle of the
    /// screen and the panel keeps its corner, so the model stays exactly where it was.
    func applyPanelLayout(_ newPanelLayout: ClickyScenePanelLayout, panelFrameInContainer: CGRect) {
        panelLayout = newPanelLayout
        frame = panelFrameInContainer.insetBy(dx: -Self.shadowRoomInPoints, dy: -Self.shadowRoomInPoints)
        layOutPanelContent()
        updateLeaderLines(forTurnAngleInRadians: sceneGraph.turnAngleInRadiansOnScreenNow, glideSeconds: 0)
    }

    /// The pure layout measures from the panel's top-left corner. AppKit views and their layers
    /// measure from the bottom-left corner, and the paper starts `shadowRoomInPoints` inside this
    /// view. This turns a frame of the layout into this view's (and its full-size layers') own.
    private func frameInOwnCoordinates(forFrameInPanel frameInPanel: CGRect) -> CGRect {
        CGRect(
            x: Self.shadowRoomInPoints + frameInPanel.minX,
            y: Self.shadowRoomInPoints + panelLayout.panelSize.height - frameInPanel.maxY,
            width: frameInPanel.width,
            height: frameInPanel.height
        )
    }

    private func pointInOwnCoordinates(forPointInPanel pointInPanel: CGPoint) -> CGPoint {
        CGPoint(
            x: Self.shadowRoomInPoints + pointInPanel.x,
            y: Self.shadowRoomInPoints + panelLayout.panelSize.height - pointInPanel.y
        )
    }

    private func layOutPanelContent() {
        paperHostView.frame = bounds
        leaderHostView.frame = bounds
        sceneKitView.frame = frameInOwnCoordinates(forFrameInPanel: panelLayout.modelViewFrame)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let paperFrame = frameInOwnCoordinates(forFrameInPanel: CGRect(origin: .zero, size: panelLayout.panelSize))
        paperShadowLayer.frame = paperFrame
        paperLayer.frame = paperFrame
        paperGridLayer.frame = paperLayer.bounds
        paperGridLayer.path = Self.makeGridPath(paperSize: paperFrame.size)

        // The title is one line, centred from top to bottom in its row.
        let titleLineHeight = ceil(NSAttributedString(string: "Ag", attributes: [.font: Self.titleFont]).size().height)
        let titleRowFrame = frameInOwnCoordinates(forFrameInPanel: panelLayout.titleFrame)
        titleTextLayer.frame = CGRect(
            x: titleRowFrame.minX,
            y: titleRowFrame.midY - titleLineHeight / 2,
            width: titleRowFrame.width,
            height: titleLineHeight
        )

        for labelledPart in labelledParts {
            layOutLabelTag(of: labelledPart)
        }
        CATransaction.commit()
    }

    /// The faint squared grid of the paper, counted from its top-left corner like the card's.
    private static func makeGridPath(paperSize: CGSize) -> CGPath {
        let gridSpacing = ClickyExplanationCardLayerBuilder.cardGridSpacingInPoints
        let gridPath = CGMutablePath()
        var lineX = gridSpacing
        while lineX < paperSize.width {
            gridPath.move(to: CGPoint(x: lineX, y: 0))
            gridPath.addLine(to: CGPoint(x: lineX, y: paperSize.height))
            lineX += gridSpacing
        }
        var lineDistanceFromTop = gridSpacing
        while lineDistanceFromTop < paperSize.height {
            gridPath.move(to: CGPoint(x: 0, y: paperSize.height - lineDistanceFromTop))
            gridPath.addLine(to: CGPoint(x: paperSize.width, y: paperSize.height - lineDistanceFromTop))
            lineDistanceFromTop += gridSpacing
        }
        return gridPath
    }

    private func layOutLabelTag(of labelledPart: LabelledPart) {
        guard let tagFrameInPanel = ClickyScenePanelLayoutCalculator.labelTagFrame(forLabelNumber: labelledPart.labelNumber, in: panelLayout) else {
            return
        }
        // The tag layer covers the whole host, so its pieces are placed in the host's coordinates.
        labelledPart.tagLayer.frame = paperHostView.bounds
        labelledPart.leaderLineLayer.frame = leaderHostView.bounds

        let discFrame = frameInOwnCoordinates(
            forFrameInPanel: ClickyScenePanelLayoutCalculator.labelDiscFrame(forLabelTagFrame: tagFrameInPanel, in: panelLayout)
        )
        labelledPart.discLayer.frame = discFrame

        let numberLineHeight = ceil(NSAttributedString(string: "8", attributes: [.font: Self.labelNumberFont]).size().height)
        labelledPart.numberTextLayer.frame = CGRect(
            x: discFrame.minX,
            y: discFrame.midY - numberLineHeight / 2,
            width: discFrame.width,
            height: numberLineHeight
        )

        let wordsRowFrame = frameInOwnCoordinates(
            forFrameInPanel: ClickyScenePanelLayoutCalculator.labelTextFrame(forLabelTagFrame: tagFrameInPanel, in: panelLayout)
        )
        let wordsLineHeight = ceil(NSAttributedString(string: "Ag", attributes: [.font: Self.labelFont]).size().height)
        labelledPart.wordsTextLayer.frame = CGRect(
            x: wordsRowFrame.minX,
            y: wordsRowFrame.midY - wordsLineHeight / 2,
            width: wordsRowFrame.width,
            height: wordsLineHeight
        )
        // The words stand next to the disc, which is at the end of the tag that faces the model.
        labelledPart.wordsTextLayer.alignmentMode = panelLayout.labelColumnIsOnLeftOfModel ? .right : .left
    }

    // MARK: Leader lines

    private func startFollowingTheModelWithLeaderLines() {
        leaderUpdateTask?.cancel()
        leaderUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.leaderUpdateIntervalSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard !self.labelledParts.isEmpty else { continue }
                // Aim at where the part will be when the next update comes, and glide there, so
                // the line's end stays on its part between updates.
                let turnAngleAtNextUpdate = self.sceneGraph.turnAngleInRadiansOnScreenNow
                    + ClickySceneCamera.turnAngleInRadians(atSecondsSinceTurnBegan: Self.leaderUpdateIntervalSeconds)
                self.updateLeaderLines(forTurnAngleInRadians: turnAngleAtNextUpdate, glideSeconds: Self.leaderUpdateIntervalSeconds)
            }
        }
    }

    /// Moves the far end of every leader line to where its part is when the model is turned by
    /// the given angle. The tags themselves never move. With `glideSeconds` above zero the ends
    /// glide there from where they are now.
    func updateLeaderLines(forTurnAngleInRadians turnAngleInRadians: Double, glideSeconds: Double) {
        for labelledPart in labelledParts {
            guard let tagFrameInPanel = ClickyScenePanelLayoutCalculator.labelTagFrame(forLabelNumber: labelledPart.labelNumber, in: panelLayout) else {
                continue
            }
            let leaderStartPoint = pointInOwnCoordinates(
                forPointInPanel: ClickyScenePanelLayoutCalculator.leaderStartPoint(forLabelTagFrame: tagFrameInPanel, in: panelLayout)
            )
            let leaderEndPoint = pointInOwnCoordinates(
                forPointInPanel: ClickyScenePanelLayoutCalculator.leaderEndPoint(
                    forPartCentre: labelledPart.partCentre,
                    cameraFit: sceneGraph.cameraFit,
                    turnAngleInRadians: turnAngleInRadians,
                    in: panelLayout
                )
            )
            let leaderPath = CGMutablePath()
            leaderPath.move(to: leaderStartPoint)
            leaderPath.addLine(to: leaderEndPoint)

            let leaderLineLayer = labelledPart.leaderLineLayer
            let leaderDotLayer = labelledPart.leaderDotLayer
            // Start from what is on screen right now, which may be the middle of the last glide.
            let pathOnScreenNow = leaderLineLayer.presentation()?.path ?? leaderLineLayer.path
            let dotPositionOnScreenNow = leaderDotLayer.presentation()?.position ?? leaderDotLayer.position

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            leaderLineLayer.path = leaderPath
            leaderDotLayer.position = leaderEndPoint
            if glideSeconds > 0, let pathOnScreenNow {
                let pathGlideAnimation = CABasicAnimation(keyPath: "path")
                pathGlideAnimation.fromValue = pathOnScreenNow
                pathGlideAnimation.toValue = leaderPath
                pathGlideAnimation.duration = glideSeconds
                pathGlideAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
                leaderLineLayer.add(pathGlideAnimation, forKey: "clickySceneLeaderGlide")

                let dotGlideAnimation = CABasicAnimation(keyPath: "position")
                dotGlideAnimation.fromValue = NSValue(point: dotPositionOnScreenNow)
                dotGlideAnimation.toValue = NSValue(point: leaderEndPoint)
                dotGlideAnimation.duration = glideSeconds
                dotGlideAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
                leaderDotLayer.add(dotGlideAnimation, forKey: "clickySceneLeaderGlide")
            }
            CATransaction.commit()
        }
    }

    // MARK: For a still picture (the smoke program's offscreen render)

    /// The layer with the paper, the title and the tags.
    var paperAndTagsLayer: CALayer? {
        paperHostView.layer
    }

    /// The layer with the leader lines, which lies over the model.
    var leaderLinesLayer: CALayer? {
        leaderHostView.layer
    }

    /// Where the model's picture is in this view, measured from the bottom-left corner.
    var modelViewFrameInOwnCoordinates: CGRect {
        frameInOwnCoordinates(forFrameInPanel: panelLayout.modelViewFrame)
    }
}
