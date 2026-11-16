//
//  EzraScenePanelView.swift
//  leanring-buddy
//
//  Shows one simple 3D scene: a small sheet of the same cream paper the explanation card uses,
//  with a title, a slowly turning model built from basic shapes, and one or (round 22) two columns
//  of numbered tags whose leader lines follow their parts. Built from public Apple APIs (SceneKit,
//  AppKit, Core Animation) with our own design. The model is a schematic made of primitives (round
//  22: twelve shapes, turned freely, in six materials), and is built only from the validated parts
//  of `EzraScene`: nothing is loaded from a file, scripted or fetched.
//
//  What is pure (limits, palette, bounds, camera fit, projection, layout, placement, and since round
//  22 the turn of a part, the exploded view, the toggle's place, the drag and zoom numbers and the
//  hemisphere's mesh) lives in `EzraCore` (`EzraSceneModel.swift`, `EzraSceneMeshBuilder.swift`).
//  This file holds the SceneKit and AppKit half and every look constant of the scene. Since round 22
//  the panel sits in a window of its own (`EzraScenePanelWindow.swift`) and takes the mouse over its
//  paper: a drag turns and tilts the model, a scroll or pinch zooms it, the toggle pulls it apart.
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
final class EzraSceneGraph {

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
    /// Round 22: a torus (and a ring) has this many sides round its ring and round its pipe.
    static let torusRingSegmentCount = 32
    static let torusPipeSegmentCount = 16

    // MARK: Materials (round 22)

    /// Metal reflects its surroundings in its own colour and has a soft highlight.
    static let metalMetalness: CGFloat = 0.9
    static let metalRoughness: CGFloat = 0.35
    /// Plastic is not metallic and has a fairly sharp highlight.
    static let plasticMetalness: CGFloat = 0
    static let plasticRoughness: CGFloat = 0.3
    /// Rubber is not metallic and has almost no highlight.
    static let rubberMetalness: CGFloat = 0
    static let rubberRoughness: CGFloat = 0.9
    /// A glowing part gives off this much light of its own colour on top of the light it catches.
    static let glowEmissionIntensity: CGFloat = 0.8
    /// The made-up surroundings a physically based part (metal, plastic, rubber) reflects: a small
    /// gradient from a light sky to a darker floor, drawn when the first such part arrives. It is no
    /// real environment, so metal gets a sheen, not reflections; matte, glass and glow parts do not use it.
    static let lightingEnvironmentWidthInPixels = 64
    static let lightingEnvironmentHeightInPixels = 32
    static let lightingEnvironmentSkyBrightness: CGFloat = 0.98
    static let lightingEnvironmentHorizonBrightness: CGFloat = 0.72
    static let lightingEnvironmentFloorBrightness: CGFloat = 0.38

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
    private(set) var cameraFit: EzraSceneCameraFit

    /// Round 22: the node of every part, by its place in the scene, so a part can be moved (the
    /// exploded view) and its leader line can follow where the renderer shows it.
    private(set) var partNodesByIndex: [Int: SCNNode] = [:]
    /// Round 22: true once a physically based part (metal, plastic, rubber) has given the scene its
    /// made-up surroundings to reflect.
    private var hasLightingEnvironment = false

    /// Round 22: the camera's downward tilt in degrees and its distance as a share of the fit's, which
    /// the user's drag and scroll and the voice's view tags change. 20 and 1 are the first view, the
    /// one every scene had before round 22.
    private(set) var downwardTiltInDegrees: Double = EzraSceneCamera.downwardTiltInDegrees
    private(set) var cameraDistanceFactor: Double = 1

    /// The key of the slow turn's action, so it can be stopped and started again.
    private static let turnActionKey = "ezraSceneTurn"

    init(cameraFit: EzraSceneCameraFit) {
        self.cameraFit = cameraFit

        // The paper behind the model must show through.
        scene.background.contents = NSColor.clear

        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(EzraSceneCamera.verticalFieldOfViewInDegrees)
        camera.projectionDirection = .vertical
        camera.automaticallyAdjustsZRange = true
        cameraNode.camera = camera
        // Pitched down by the tilt: the camera then looks from its raised place at the origin.
        cameraNode.eulerAngles = SCNVector3(-CGFloat(EzraSceneCamera.downwardTiltInDegrees) * .pi / 180, 0, 0)
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

    private func placeCameraAndModel(for cameraFit: EzraSceneCameraFit) {
        // Round 22: with the user's tilt and distance (the first view's 20 degrees and 1 give exactly
        // round 11's place).
        let cameraPosition = EzraSceneCamera.cameraPositionRelativeToModelCentre(
            for: cameraFit,
            downwardTiltInDegrees: downwardTiltInDegrees,
            cameraDistanceFactor: cameraDistanceFactor
        )
        cameraNode.position = SCNVector3(CGFloat(cameraPosition.x), CGFloat(cameraPosition.y), CGFloat(cameraPosition.z))
        cameraNode.eulerAngles = SCNVector3(-CGFloat(downwardTiltInDegrees) * .pi / 180, 0, 0)
        // The middle of the model goes onto the turning axis, at the point the camera looks at.
        modelNode.position = SCNVector3(
            -CGFloat(cameraFit.modelCentre.x),
            -CGFloat(cameraFit.modelCentre.y),
            -CGFloat(cameraFit.modelCentre.z)
        )
    }

    /// Frames the model again, for when parts were added that the old fit did not hold. With
    /// `animationSeconds` above zero the camera glides to its new place instead of jumping.
    func applyCameraFit(_ newCameraFit: EzraSceneCameraFit, animationSeconds: Double) {
        guard newCameraFit != cameraFit else { return }
        cameraFit = newCameraFit
        SCNTransaction.begin()
        SCNTransaction.animationDuration = max(0, animationSeconds)
        placeCameraAndModel(for: newCameraFit)
        SCNTransaction.commit()
    }

    /// Adds one part to the model. With `appearSeconds` above zero it grows a little and fades in.
    /// Round 22: `partIndex` is the part's place in the scene; its node is kept under it. `shownCentre`
    /// is where the part appears when that is not its own centre (the model is exploded).
    func addPartNode(for part: EzraScenePart, partIndex: Int, appearSeconds: Double, shownCentre: EzraSceneVector? = nil) {
        let partNode = Self.makePartNode(for: part)
        if let shownCentre {
            partNode.position = SCNVector3(CGFloat(shownCentre.x), CGFloat(shownCentre.y), CGFloat(shownCentre.z))
        }
        partNodesByIndex[partIndex] = partNode
        if Self.isPhysicallyBased(part.effectiveMaterial) {
            giveTheSceneSurroundingsToReflect()
        }
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

    /// Round 22: moves parts that are on the screen to new centres (the exploded view and back), all
    /// in one glide. Their leader lines follow, because they are read from the presented nodes.
    func moveParts(toCentresByIndex centresByIndex: [Int: EzraSceneVector], animationSeconds: Double) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = max(0, animationSeconds)
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        for (partIndex, centre) in centresByIndex {
            partNodesByIndex[partIndex]?.position = SCNVector3(CGFloat(centre.x), CGFloat(centre.y), CGFloat(centre.z))
        }
        SCNTransaction.commit()
    }

    /// Round 22: true while the model turns on its own, so the leader lines can aim at where a part
    /// will be at their next update.
    private(set) var isTurningOnItsOwn = false

    /// Starts the slow, endless turn around the vertical axis.
    func startTurning() {
        let oneTurnAction = SCNAction.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: EzraSceneCamera.secondsPerTurn)
        turningPivotNode.runAction(SCNAction.repeatForever(oneTurnAction), forKey: Self.turnActionKey)
        isTurningOnItsOwn = true
    }

    // MARK: The view the user and the voice change (round 22)

    /// The key of a voice turn's action ("turn it left", "show me the back"), so a drag can stop it.
    private static let voiceTurnActionKey = "ezraSceneVoiceTurn"

    /// Stops the slow turn (or a voice turn still under way) where it is on the screen, for the user's
    /// hand or a new voice turn. The model stays at the angle it is shown at. Without an action running
    /// the model is left alone, so the steps of one drag never undo each other.
    func stopTurningOnItsOwn() {
        let anActionTurnsTheModel = turningPivotNode.action(forKey: Self.turnActionKey) != nil
            || turningPivotNode.action(forKey: Self.voiceTurnActionKey) != nil
        isTurningOnItsOwn = false
        guard anActionTurnsTheModel else { return }
        let turnAngleOnScreen = turnAngleInRadiansOnScreenNow
        turningPivotNode.removeAction(forKey: Self.turnActionKey)
        turningPivotNode.removeAction(forKey: Self.voiceTurnActionKey)
        changeWithoutAnimation {
            turningPivotNode.eulerAngles = SCNVector3(0, CGFloat(turnAngleOnScreen), 0)
        }
    }

    /// Starts the slow turn again from wherever the model is.
    func resumeTurningOnItsOwn() {
        guard !isTurningOnItsOwn else { return }
        startTurning()
    }

    /// How far the model is turned in the node's own values (not the frame on the screen). Read from
    /// the transform, like `turnAngleInRadiansOnScreenNow`, because SceneKit may hand back a turn of
    /// more than a quarter as a different set of euler angles (half a turn about x and z, and the rest
    /// about y), and adding to that y would turn the model the wrong way.
    var turnAngleInRadiansOfTheModel: Double {
        let modelTransform = turningPivotNode.transform
        return Double(atan2(modelTransform.m31, modelTransform.m11))
    }

    /// Turns the model by an angle at once (a drag).
    func turnModel(byRadians turnChangeInRadians: Double) {
        let newTurnAngleInRadians = turnAngleInRadiansOfTheModel + turnChangeInRadians
        changeWithoutAnimation {
            turningPivotNode.eulerAngles = SCNVector3(0, CGFloat(newTurnAngleInRadians), 0)
        }
    }

    /// Turns the model to an angle, gliding there (a voice turn), by turning it about its vertical axis
    /// by the difference, the same way the slow turn moves it.
    func turnModel(toRadians turnAngleInRadians: Double, animationSeconds: Double) {
        let turnChangeInRadians = turnAngleInRadians - turnAngleInRadiansOfTheModel
        let voiceTurnAction = SCNAction.rotateBy(x: 0, y: CGFloat(turnChangeInRadians), z: 0, duration: max(0, animationSeconds))
        voiceTurnAction.timingMode = .easeInEaseOut
        turningPivotNode.runAction(voiceTurnAction, forKey: Self.voiceTurnActionKey)
    }

    /// Tilts the camera round the model (kept within the tilt's limits), at once or gliding.
    func tiltCamera(toDownwardTiltInDegrees newDownwardTiltInDegrees: Double, animationSeconds: Double) {
        downwardTiltInDegrees = EzraSceneViewControl.clampedDownwardTilt(newDownwardTiltInDegrees)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = max(0, animationSeconds)
        placeCameraAndModel(for: cameraFit)
        SCNTransaction.commit()
    }

    /// Moves the camera nearer or further (kept within the zoom's limits), at once or gliding.
    func setCameraDistanceFactor(_ newCameraDistanceFactor: Double, animationSeconds: Double) {
        cameraDistanceFactor = EzraSceneViewControl.clampedCameraDistanceFactor(newCameraDistanceFactor)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = max(0, animationSeconds)
        placeCameraAndModel(for: cameraFit)
        SCNTransaction.commit()
    }

    /// Back to the first view, gliding: the usual tilt and distance, and the model turned the nearest
    /// way round to its front. Call `stopTurningOnItsOwn` first.
    func resetToTheFirstView(animationSeconds: Double) {
        downwardTiltInDegrees = EzraSceneCamera.downwardTiltInDegrees
        cameraDistanceFactor = 1
        SCNTransaction.begin()
        SCNTransaction.animationDuration = max(0, animationSeconds)
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        placeCameraAndModel(for: cameraFit)
        SCNTransaction.commit()
        turnModel(
            toRadians: EzraSceneViewControl.turnAngleInRadians(afterTurning: .front, from: turnAngleInRadiansOfTheModel),
            animationSeconds: animationSeconds
        )
    }

    /// Changes made inside run at once, even inside an animated transaction around them.
    private func changeWithoutAnimation(_ changes: () -> Void) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        changes()
        SCNTransaction.commit()
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

    /// Round 22: where the middle of a part is in the world in the frame that is on the screen, for its
    /// leader line. It is the middle of the part's geometry, not the node's origin: a node with a pivot
    /// (the pyramid, the wedge) has its origin where the geometry's own origin lands, which for a
    /// turned pyramid is not its middle (the smoke program's render check found the pyramid's line
    /// ten points off). A part added since the renderer's last frame is not in the presented scene yet
    /// (its presentation sits at the origin with no parent), so its own place is used until it is.
    static func worldPositionOfPartCentre(of partNode: SCNNode) -> SCNVector3 {
        var geometryCentre = SCNVector3(0, 0, 0)
        if let partGeometry = partNode.geometry {
            let (geometryMinimum, geometryMaximum) = partGeometry.boundingBox
            geometryCentre = SCNVector3(
                (geometryMinimum.x + geometryMaximum.x) / 2,
                (geometryMinimum.y + geometryMaximum.y) / 2,
                (geometryMinimum.z + geometryMaximum.z) / 2
            )
        }
        let presentedPartNode = partNode.presentation
        let nodeAsShown = presentedPartNode.parent == nil ? partNode : presentedPartNode
        return nodeAsShown.convertPosition(geometryCentre, to: nil)
    }

    // MARK: Building a part

    static func makePartNode(for part: EzraScenePart) -> SCNNode {
        let partGeometry = makeGeometry(for: part)
        partGeometry.materials = [makeMaterial(for: part)]

        let partNode = SCNNode(geometry: partGeometry)
        partNode.position = SCNVector3(CGFloat(part.centre.x), CGFloat(part.centre.y), CGFloat(part.centre.z))
        // Round 22: a pyramid's geometry stands on its base and a wedge's on its outline, not round
        // their middles like the other shapes. The node's pivot is put at the middle of the geometry's
        // bounds, so a part's centre means the same for every shape (and it turns and grows round it).
        // (SceneKit's own translation-matrix maker is avoided on purpose: its name reads as a key to
        // the credential-shape rules, which would hide this line when Ezra reads this file.)
        if part.shapeKind == .pyramid || part.shapeKind == .wedge {
            let (geometryMinimum, geometryMaximum) = partGeometry.boundingBox
            partNode.pivot = SCNMatrix4Translate(
                SCNMatrix4Identity,
                (geometryMinimum.x + geometryMaximum.x) / 2,
                (geometryMinimum.y + geometryMaximum.y) / 2,
                (geometryMinimum.z + geometryMaximum.z) / 2
            )
        }
        if part.rotation.isDefault {
            // SceneKit builds cylinders, cones, tubes, capsules and tori standing up (along y, a cone's
            // tip on top, a torus's hole upright). They are laid over to point along x or z.
            if part.shapeKind.pointsAlongAnAxis {
                switch part.axis {
                case .x: partNode.eulerAngles = SCNVector3(0, 0, -CGFloat.pi / 2)
                case .y: break
                case .z: partNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
                }
            }
        } else {
            // Round 22: a turned part gets one orientation: its axis first, then its rot= about the
            // scene's x, y and z axes (worked out and tested in `EzraSceneRotation`).
            let orientation = EzraSceneRotation.quaternion(axis: part.axis, rotation: part.rotation)
            partNode.orientation = SCNQuaternion(CGFloat(orientation.x), CGFloat(orientation.y), CGFloat(orientation.z), CGFloat(orientation.w))
        }
        if part.isTranslucent {
            partNode.renderingOrder = translucentPartRenderingOrder
        }
        return partNode
    }

    static func makeGeometry(for part: EzraScenePart) -> SCNGeometry {
        switch part.dimensions {
        case .box(let width, let height, let depth) where part.shapeKind == .pyramid:
            // Round 22: a pyramid on a width by depth base, its tip up (SceneKit's own pyramid).
            return SCNPyramid(width: CGFloat(width), height: CGFloat(height), length: CGFloat(depth))

        case .box(let width, let height, let depth) where part.shapeKind == .wedge:
            // Round 22: a right triangle in the x-y plane, the right angle at the bottom left, drawn
            // round its middle and extruded along z.
            let trianglePath = NSBezierPath()
            trianglePath.move(to: NSPoint(x: -width / 2, y: -height / 2))
            trianglePath.line(to: NSPoint(x: width / 2, y: -height / 2))
            trianglePath.line(to: NSPoint(x: -width / 2, y: height / 2))
            trianglePath.close()
            let wedge = SCNShape(path: trianglePath, extrusionDepth: CGFloat(depth))
            wedge.chamferRadius = 0
            return wedge

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
                    innerRadius: CGFloat(radius * EzraScenePart.tubeInnerRadiusShareOfOuterRadius),
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
            case .cylinder, .box, .sphere, .torus, .ring, .pyramid, .plane, .wedge, .hemisphere:
                // Only the four round shapes have these dimensions; a cylinder is the plain round shape.
                let cylinder = SCNCylinder(radius: CGFloat(radius), height: length)
                cylinder.radialSegmentCount = roundShapeSegmentCount
                cylinder.heightSegmentCount = 1
                return cylinder
            }

        case .torus(let ringRadius, let pipeRadius):
            // Round 22: a torus, and a ring (a torus with a thin pipe), its hole upright.
            let torus = SCNTorus(ringRadius: CGFloat(ringRadius), pipeRadius: CGFloat(pipeRadius))
            torus.ringSegmentCount = torusRingSegmentCount
            torus.pipeSegmentCount = torusPipeSegmentCount
            return torus

        case .plane(let width, let height):
            // Round 22: a thin slab rather than a one-sided sheet, so it shows and catches the light
            // from both sides as the model turns.
            return SCNBox(width: CGFloat(width), height: CGFloat(height), length: CGFloat(EzraScenePart.planeThickness), chamferRadius: 0)

        case .hemisphere(let radius):
            // Round 22: a dome from the pure mesh builder, already centred on its own bounds.
            return makeHemisphereGeometry(radius: radius)
        }
    }

    /// Round 22: the hemisphere's mesh (positions, normals, triangles) as a SceneKit geometry.
    static func makeHemisphereGeometry(radius: Double) -> SCNGeometry {
        let hemisphereMesh = EzraSceneMeshBuilder.hemisphere(radius: radius)
        let vertexSource = SCNGeometrySource(vertices: hemisphereMesh.positions.map { position in
            SCNVector3(CGFloat(position.x), CGFloat(position.y), CGFloat(position.z))
        })
        let normalSource = SCNGeometrySource(normals: hemisphereMesh.normals.map { normal in
            SCNVector3(CGFloat(normal.x), CGFloat(normal.y), CGFloat(normal.z))
        })
        let triangleElement = SCNGeometryElement(indices: hemisphereMesh.triangleIndices.map { Int32($0) }, primitiveType: .triangles)
        return SCNGeometry(sources: [vertexSource, normalSource], elements: [triangleElement])
    }

    /// Round 22: the material of a part, from its colour and what it is made of. A matte part, and a
    /// part coloured glass with no `mat=`, get exactly the material every part had before round 22.
    static func makeMaterial(for part: EzraScenePart) -> SCNMaterial {
        let colourComponents = part.colour.components
        let diffuseColour = NSColor(
            srgbRed: CGFloat(colourComponents.red),
            green: CGFloat(colourComponents.green),
            blue: CGFloat(colourComponents.blue),
            alpha: 1
        )
        switch part.effectiveMaterial {
        case .matte:
            return makeMaterial(for: part.colour)
        case .glass where part.colour == .glass:
            // A glass part written the round 11 way: its look is exactly what it was.
            return makeMaterial(for: .glass)
        case .glass:
            // Glass of any colour: as see-through as round 11's glass, and drawn in two passes (back
            // faces, then front faces), so a round glass part looks solid and its far side still shows.
            let material = SCNMaterial()
            material.lightingModel = .lambert
            material.diffuse.contents = diffuseColour
            material.transparency = CGFloat(EzraScenePartColour.glassOpacity)
            material.transparencyMode = .dualLayer
            material.writesToDepthBuffer = false
            return material
        case .metal, .plastic, .rubber:
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = diffuseColour
            switch part.effectiveMaterial {
            case .metal:
                material.metalness.contents = metalMetalness
                material.roughness.contents = metalRoughness
            case .plastic:
                material.metalness.contents = plasticMetalness
                material.roughness.contents = plasticRoughness
            default:
                material.metalness.contents = rubberMetalness
                material.roughness.contents = rubberRoughness
            }
            return material
        case .glow:
            let material = SCNMaterial()
            material.lightingModel = .lambert
            material.diffuse.contents = diffuseColour
            material.emission.contents = diffuseColour
            material.emission.intensity = glowEmissionIntensity
            return material
        }
    }

    /// Round 22: true for the materials SceneKit shades physically, which reflect the scene's surroundings.
    static func isPhysicallyBased(_ material: EzraScenePartMaterial) -> Bool {
        material == .metal || material == .plastic || material == .rubber
    }

    /// Round 22: gives the scene its made-up surroundings (a light sky, a darker floor) the first time a
    /// physically based part arrives. A scene without one keeps no surroundings, as before round 22.
    private func giveTheSceneSurroundingsToReflect() {
        guard !hasLightingEnvironment else { return }
        hasLightingEnvironment = true
        scene.lightingEnvironment.contents = Self.makeLightingEnvironmentImage()
    }

    /// A small vertical gradient, drawn at runtime (no image ships with the app): 2 to 1, the way an
    /// all-round picture of surroundings is laid out, light at the top and dark at the bottom.
    static func makeLightingEnvironmentImage() -> CGImage? {
        guard let grayColourSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let drawingContext = CGContext(
                  data: nil,
                  width: lightingEnvironmentWidthInPixels,
                  height: lightingEnvironmentHeightInPixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: grayColourSpace,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ),
              let gradient = CGGradient(
                  colorsSpace: grayColourSpace,
                  colors: [
                      CGColor(gray: lightingEnvironmentSkyBrightness, alpha: 1),
                      CGColor(gray: lightingEnvironmentHorizonBrightness, alpha: 1),
                      CGColor(gray: lightingEnvironmentFloorBrightness, alpha: 1),
                  ] as CFArray,
                  locations: [0, 0.5, 1]
              ) else {
            return nil
        }
        // A bitmap context counts from the bottom, so the sky (the gradient's start) is drawn at the top.
        drawingContext.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: lightingEnvironmentHeightInPixels),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
        return drawingContext.makeImage()
    }

    /// A matte material in one palette colour. `glass` is see-through and shows both of its sides.
    static func makeMaterial(for colour: EzraScenePartColour) -> SCNMaterial {
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
private final class EzraSceneLayerHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Its own plain layer, set before wantsLayer, so AppKit leaves the layer's contents alone.
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EzraSceneLayerHostView is only created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// The SceneKit view of a scene. It never takes the mouse: the panel view around it handles every
/// drag, scroll and click (round 22), and outside a scene window nothing does.
private final class EzraMouseTransparentSceneKitView: SCNView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// The whole panel of one scene. A plain AppKit view; since round 22 the drawing overlay controller
/// puts it in a window of its own (`EzraScenePanelWindow`), never inside a SwiftUI hosting view.
final class EzraScenePanelView: NSView {

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
    /// Round 22: how long the parts take to move apart (or back together) and the camera to frame them.
    static let explodeSeconds: Double = 0.6

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

    /// Round 22: the explode toggle's look. Its size and place are in the pure layout
    /// (`EzraScenePanelLayoutCalculator.explodeToggleFrame`), so the window's hit test agrees with it.
    static let explodeToggleCornerRadiusInPoints: CGFloat = 5
    static let explodeToggleOutlineWidthInPoints: CGFloat = 1.2
    static let explodeToggleGlyphLineWidthInPoints: CGFloat = 1.4
    /// The arrows run along the diagonals, from this far out from the middle to this far.
    static let explodeToggleArrowInnerReachInPoints: CGFloat = 2.5
    static let explodeToggleArrowOuterReachInPoints: CGFloat = 7
    static let explodeToggleArrowHeadLengthInPoints: CGFloat = 3
    static let explodeToggleArrowHeadAngleInDegrees: CGFloat = 35

    /// Round 22: four arrows along the diagonals of a square of this side: pointing out from the
    /// middle (the toggle explodes the model) or in towards it (it puts the model back together).
    /// Drawn at runtime; no image ships with the app.
    static func makeExplodeToggleGlyphPath(sideInPoints: CGFloat, arrowsPointOutwards: Bool) -> CGPath {
        let glyphPath = CGMutablePath()
        let middle = CGPoint(x: sideInPoints / 2, y: sideInPoints / 2)
        let headAngleInRadians = explodeToggleArrowHeadAngleInDegrees * .pi / 180
        for (horizontalSign, verticalSign) in [(CGFloat(1), CGFloat(1)), (1, -1), (-1, 1), (-1, -1)] {
            // The unit direction of this diagonal, out from the middle.
            let directionX = horizontalSign / CGFloat(2).squareRoot()
            let directionY = verticalSign / CGFloat(2).squareRoot()
            let innerPoint = CGPoint(x: middle.x + directionX * explodeToggleArrowInnerReachInPoints * CGFloat(2).squareRoot(), y: middle.y + directionY * explodeToggleArrowInnerReachInPoints * CGFloat(2).squareRoot())
            let outerPoint = CGPoint(x: middle.x + directionX * explodeToggleArrowOuterReachInPoints * CGFloat(2).squareRoot(), y: middle.y + directionY * explodeToggleArrowOuterReachInPoints * CGFloat(2).squareRoot())
            let tailPoint = arrowsPointOutwards ? innerPoint : outerPoint
            let tipPoint = arrowsPointOutwards ? outerPoint : innerPoint
            glyphPath.move(to: tailPoint)
            glyphPath.addLine(to: tipPoint)
            // The head: two short strokes back from the tip, either side of the arrow's line.
            let backwardsX = arrowsPointOutwards ? -directionX : directionX
            let backwardsY = arrowsPointOutwards ? -directionY : directionY
            for headSideSign in [CGFloat(1), -1] {
                let turnedAngle = headSideSign * headAngleInRadians
                let headX = backwardsX * cos(turnedAngle) - backwardsY * sin(turnedAngle)
                let headY = backwardsX * sin(turnedAngle) + backwardsY * cos(turnedAngle)
                glyphPath.move(to: tipPoint)
                glyphPath.addLine(to: CGPoint(x: tipPoint.x + headX * explodeToggleArrowHeadLengthInPoints, y: tipPoint.y + headY * explodeToggleArrowHeadLengthInPoints))
            }
        }
        return glyphPath
    }

    /// True when this Mac can draw a scene at all. Without Metal the scene is dropped and only
    /// the spoken reply remains.
    static let canRenderScenes: Bool = MTLCreateSystemDefaultDevice() != nil

    // MARK: State

    let sceneGraph: EzraSceneGraph
    private let sceneTitle: String
    private let backingScaleFactor: CGFloat
    private(set) var panelLayout: EzraScenePanelLayout

    private let paperHostView = EzraSceneLayerHostView(frame: .zero)
    private let sceneKitView: EzraMouseTransparentSceneKitView
    private let leaderHostView = EzraSceneLayerHostView(frame: .zero)

    private let paperShadowLayer = CALayer()
    private let paperLayer = CALayer()
    private let paperGridLayer = CAShapeLayer()
    private let titleTextLayer = CATextLayer()

    /// Round 22: the explode toggle in the paper's top-right corner: a rounded square with a pencil
    /// outline, a light fill while the pointer is over it, and four arrows pointing out (to explode)
    /// or in (to assemble).
    private let explodeToggleOutlineLayer = CAShapeLayer()
    private let explodeToggleGlyphLayer = CAShapeLayer()
    /// Round 22: true while the parts are shown pulled apart.
    private(set) var isShowingExplodedParts = false
    /// Round 22: true while the pointer is over the toggle, which then shows its light fill.
    private(set) var isPointerOverExplodeToggle = false

    private struct LabelledPart {
        let labelNumber: Int
        let labelText: String
        /// Round 22: the part's place in the scene, which finds its node, so the leader line ends where
        /// the renderer shows the part (turned, tilted, zoomed or exploded).
        let partIndex: Int
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
        EzraExplanationCardLayerBuilder.rowFont
    }

    static var labelFont: NSFont {
        let rowFont = EzraExplanationCardLayerBuilder.rowFont
        return NSFont(descriptor: rowFont.fontDescriptor, size: min(rowFont.pointSize, largestLabelFontSizeInPoints)) ?? rowFont
    }

    static var labelNumberFont: NSFont {
        EzraDrawingMarkLayerBuilder.roundedSystemFont(ofSize: labelNumberFontSizeInPoints, weight: .bold)
    }

    // MARK: Creating

    /// `panelFrameInContainer` is where the paper goes in the container view's own coordinates
    /// (AppKit's, measured from the bottom-left corner). `cameraFit` frames the model for the
    /// parts this reply is about to add, so the camera does not have to move after each of them.
    init(
        sceneTitle: String,
        cameraFit: EzraSceneCameraFit,
        panelLayout: EzraScenePanelLayout,
        panelFrameInContainer: CGRect,
        backingScaleFactor: CGFloat
    ) {
        self.sceneTitle = sceneTitle
        self.sceneGraph = EzraSceneGraph(cameraFit: cameraFit)
        self.panelLayout = panelLayout
        self.backingScaleFactor = backingScaleFactor
        self.sceneKitView = EzraMouseTransparentSceneKitView(frame: .zero)
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
        paperShadowLayer.cornerRadius = EzraExplanationCardLayerBuilder.cardCornerRadiusInPoints
        paperShadowLayer.shadowColor = NSColor.black.cgColor
        paperShadowLayer.shadowOpacity = EzraExplanationCardLayerBuilder.cardShadowOpacity
        paperShadowLayer.shadowRadius = EzraExplanationCardLayerBuilder.cardShadowRadiusInPoints
        // Negative is downwards, because a layer's own coordinates grow upwards.
        paperShadowLayer.shadowOffset = CGSize(width: 0, height: -EzraExplanationCardLayerBuilder.cardShadowVerticalOffsetInPoints)
        paperHostView.layer?.addSublayer(paperShadowLayer)

        // The paper clips the grid to its rounded corners, and a layer that clips cannot cast a
        // shadow, which is why the shadow has a layer of its own underneath.
        paperLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingCardPaper).cgColor
        paperLayer.cornerRadius = EzraExplanationCardLayerBuilder.cardCornerRadiusInPoints
        paperLayer.borderColor = NSColor(DS.Colors.overlayDrawingCardEdge).cgColor
        paperLayer.borderWidth = EzraExplanationCardLayerBuilder.cardEdgeWidthInPoints
        paperLayer.masksToBounds = true
        paperGridLayer.fillColor = nil
        paperGridLayer.strokeColor = NSColor(DS.Colors.overlayDrawingCardGridLine).cgColor
        paperGridLayer.lineWidth = EzraExplanationCardLayerBuilder.cardGridLineWidthInPoints
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

        explodeToggleOutlineLayer.fillColor = NSColor.clear.cgColor
        explodeToggleOutlineLayer.strokeColor = NSColor(DS.Colors.overlayDrawingCardPencil).cgColor
        explodeToggleOutlineLayer.lineWidth = Self.explodeToggleOutlineWidthInPoints
        explodeToggleOutlineLayer.contentsScale = backingScaleFactor
        paperHostView.layer?.addSublayer(explodeToggleOutlineLayer)
        explodeToggleGlyphLayer.fillColor = nil
        explodeToggleGlyphLayer.strokeColor = NSColor(DS.Colors.overlayDrawingCardPencil).cgColor
        explodeToggleGlyphLayer.lineWidth = Self.explodeToggleGlyphLineWidthInPoints
        explodeToggleGlyphLayer.lineCap = .round
        explodeToggleGlyphLayer.lineJoin = .round
        explodeToggleGlyphLayer.contentsScale = backingScaleFactor
        paperHostView.layer?.addSublayer(explodeToggleGlyphLayer)
        CATransaction.commit()

        layOutPanelContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EzraScenePanelView is only created in code")
    }

    // MARK: The mouse (round 22)

    /// True while the panel sits in its own scene window (`EzraScenePanelWindow`), which takes the
    /// mouse over the paper. False everywhere else (an offscreen picture) and from the moment the scene
    /// starts to fade, so a scene on its way out never catches a click.
    var takesTheMouse = false {
        didSet {
            updateTrackingAreas()
            if !takesTheMouse {
                setPointerIsOverExplodeToggle(false)
            }
        }
    }

    /// Told about every drag, scroll, pinch and toggle click, so the scene's countdown starts again and
    /// the time is counted for the metrics line.
    var userTouchedTheSceneHandler: (@MainActor () -> Void)?
    /// Told when the explode toggle is clicked. The overlay controller decides what happens, because
    /// the board (and so the next prompt) must learn that the model is now apart or together.
    var explodeToggleClickedHandler: (@MainActor () -> Void)?

    private var pointerTrackingArea: NSTrackingArea?
    /// Where the press that is going on began: the toggle, the paper, or nil with no press.
    private var regionOfThePressGoingOn: EzraScenePanelHitRegion?
    private var lastDragLocationInWindow: CGPoint?
    /// Starts the slow turn again ten seconds after the user (or the voice) last turned or zoomed it.
    private var turnResumeWorkItem: DispatchWorkItem?

    /// A point of this view as a point of the paper, measured from the paper's top-left corner (the
    /// pure layout's own coordinates).
    private func pointInPanel(forPointInOwnCoordinates pointInOwnCoordinates: CGPoint) -> CGPoint {
        CGPoint(
            x: pointInOwnCoordinates.x - Self.shadowRoomInPoints,
            y: Self.shadowRoomInPoints + panelLayout.panelSize.height - pointInOwnCoordinates.y
        )
    }

    private func hitRegion(forLocationInWindow locationInWindow: CGPoint) -> EzraScenePanelHitRegion {
        EzraScenePanelLayoutCalculator.hitRegion(
            atPointInPanel: pointInPanel(forPointInOwnCoordinates: convert(locationInWindow, from: nil)),
            in: panelLayout
        )
    }

    /// Round 22: in its scene window the panel takes the mouse over the paper only; the shadow room
    /// around it stays click-through. Anywhere else (an offscreen picture), and while it fades out, it
    /// never takes the mouse. The point comes in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard takesTheMouse, let superview else { return nil }
        let pointInOwnCoordinates = convert(point, from: superview)
        let region = EzraScenePanelLayoutCalculator.hitRegion(
            atPointInPanel: pointInPanel(forPointInOwnCoordinates: pointInOwnCoordinates),
            in: panelLayout
        )
        return region == .outsideThePaper ? nil : self
    }

    /// The scene window never becomes the key window, so every click is a "first" click; it must
    /// still turn the model or press the toggle rather than only bring the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Tracks the pointer even though Ezra is almost never the active app, for the toggle's light fill
    /// and the pointer's shape.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
            self.pointerTrackingArea = nil
        }
        guard takesTheMouse else { return }
        let newPointerTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newPointerTrackingArea)
        pointerTrackingArea = newPointerTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointerLook(atLocationInWindow: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointerLook(atLocationInWindow: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerIsOverExplodeToggle(false)
        if regionOfThePressGoingOn == nil {
            NSCursor.arrow.set()
        }
    }

    /// The pointing hand over the toggle (it is a button), the open hand over the rest of the paper
    /// (it can be grabbed and turned), the closed hand while it is being turned, the arrow off it.
    private func updatePointerLook(atLocationInWindow locationInWindow: CGPoint) {
        guard takesTheMouse else { return }
        let region = hitRegion(forLocationInWindow: locationInWindow)
        setPointerIsOverExplodeToggle(region == .explodeToggle && regionOfThePressGoingOn != .paper)
        if regionOfThePressGoingOn == .paper {
            NSCursor.closedHand.set()
            return
        }
        switch region {
        case .explodeToggle: NSCursor.pointingHand.set()
        case .paper: NSCursor.openHand.set()
        case .outsideThePaper: NSCursor.arrow.set()
        }
    }

    private func setPointerIsOverExplodeToggle(_ pointerIsOverExplodeToggle: Bool) {
        guard pointerIsOverExplodeToggle != isPointerOverExplodeToggle else { return }
        isPointerOverExplodeToggle = pointerIsOverExplodeToggle
        updateExplodeToggleLook()
    }

    override func mouseDown(with event: NSEvent) {
        let region = hitRegion(forLocationInWindow: event.locationInWindow)
        guard region != .outsideThePaper else { return }
        regionOfThePressGoingOn = region
        lastDragLocationInWindow = event.locationInWindow
        updatePointerLook(atLocationInWindow: event.locationInWindow)
    }

    /// A drag across the paper turns the model (left and right) and tilts the camera round it (up and
    /// down). A press that began on the toggle never turns the model.
    override func mouseDragged(with event: NSEvent) {
        guard regionOfThePressGoingOn == .paper, let lastDragLocationInWindow else { return }
        let horizontalDragPoints = Double(event.locationInWindow.x - lastDragLocationInWindow.x)
        let verticalDragPoints = Double(event.locationInWindow.y - lastDragLocationInWindow.y)
        self.lastDragLocationInWindow = event.locationInWindow
        guard horizontalDragPoints != 0 || verticalDragPoints != 0 else { return }
        pauseTheTurnForAWhile(resumingAfterSeconds: EzraSceneViewControl.secondsBeforeTheTurnResumes)
        sceneGraph.turnModel(byRadians: EzraSceneViewControl.turnAngleChangeInRadians(forHorizontalDragPoints: horizontalDragPoints))
        sceneGraph.tiltCamera(
            toDownwardTiltInDegrees: EzraSceneViewControl.downwardTiltInDegrees(
                afterVerticalDragPoints: verticalDragPoints,
                from: sceneGraph.downwardTiltInDegrees
            ),
            animationSeconds: 0
        )
        userTouchedTheSceneHandler?()
    }

    /// A press and release both on the toggle is a click on it.
    override func mouseUp(with event: NSEvent) {
        let regionWhereThePressBegan = regionOfThePressGoingOn
        regionOfThePressGoingOn = nil
        lastDragLocationInWindow = nil
        if regionWhereThePressBegan == .explodeToggle && hitRegion(forLocationInWindow: event.locationInWindow) == .explodeToggle {
            userTouchedTheSceneHandler?()
            explodeToggleClickedHandler?()
        }
        updatePointerLook(atLocationInWindow: event.locationInWindow)
    }

    /// Scrolling over the paper zooms the model; the page behind it does not scroll. A trackpad gives
    /// points, a mouse wheel gives lines.
    override func scrollWheel(with event: NSEvent) {
        let scrollPoints = event.hasPreciseScrollingDeltas
            ? Double(event.scrollingDeltaY)
            : Double(event.scrollingDeltaY) * EzraSceneViewControl.scrollPointsPerWheelLine
        guard scrollPoints != 0 else { return }
        pauseTheTurnForAWhile(resumingAfterSeconds: EzraSceneViewControl.secondsBeforeTheTurnResumes)
        sceneGraph.setCameraDistanceFactor(
            EzraSceneViewControl.cameraDistanceFactor(afterScrollPoints: scrollPoints, from: sceneGraph.cameraDistanceFactor),
            animationSeconds: EzraSceneViewControl.scrollZoomSeconds
        )
        userTouchedTheSceneHandler?()
    }

    /// A pinch on a trackpad zooms too.
    override func magnify(with event: NSEvent) {
        let magnification = Double(event.magnification)
        guard magnification != 0 else { return }
        pauseTheTurnForAWhile(resumingAfterSeconds: EzraSceneViewControl.secondsBeforeTheTurnResumes)
        sceneGraph.setCameraDistanceFactor(
            EzraSceneViewControl.cameraDistanceFactor(afterMagnification: magnification, from: sceneGraph.cameraDistanceFactor),
            animationSeconds: 0
        )
        userTouchedTheSceneHandler?()
    }

    /// Stops the slow turn and starts it again after `resumingAfterSeconds`, unless the model is turned
    /// or zoomed again before then (each time moves the restart back).
    private func pauseTheTurnForAWhile(resumingAfterSeconds secondsBeforeTheTurnResumes: Double) {
        sceneGraph.stopTurningOnItsOwn()
        turnResumeWorkItem?.cancel()
        let resumeWorkItem = DispatchWorkItem { [weak self] in
            // A scene that has gone (faded, erased) stays still.
            guard let self, self.superview != nil else { return }
            self.sceneGraph.resumeTurningOnItsOwn()
        }
        turnResumeWorkItem = resumeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, secondsBeforeTheTurnResumes), execute: resumeWorkItem)
    }

    // MARK: The voice's view tags (round 22)

    /// `[VIEW:turn:left]` and the others: a quarter turn, or the nearest way round to the front or the
    /// back, over half a second. The slow turn waits ten seconds, as after a drag.
    func turnTheModel(_ turnDirection: EzraSceneTurnDirection) {
        pauseTheTurnForAWhile(resumingAfterSeconds: EzraSceneViewControl.secondsBeforeTheTurnResumes)
        sceneGraph.turnModel(
            toRadians: EzraSceneViewControl.turnAngleInRadians(afterTurning: turnDirection, from: sceneGraph.turnAngleInRadiansOfTheModel),
            animationSeconds: EzraSceneViewControl.voiceViewChangeSeconds
        )
    }

    /// `[VIEW:zoom:in]` and `[VIEW:zoom:out]`, over half a second. The model keeps turning.
    func zoomTheModel(_ zoomDirection: EzraSceneZoomDirection) {
        sceneGraph.setCameraDistanceFactor(
            EzraSceneViewControl.cameraDistanceFactor(afterZooming: zoomDirection, from: sceneGraph.cameraDistanceFactor),
            animationSeconds: EzraSceneViewControl.voiceViewChangeSeconds
        )
    }

    /// `[VIEW:reset]`: back to the first view (the overlay controller puts the parts back together),
    /// and the slow turn starts again once the glide is over.
    func resetTheView() {
        pauseTheTurnForAWhile(resumingAfterSeconds: EzraSceneViewControl.voiceViewChangeSeconds)
        sceneGraph.resetToTheFirstView(animationSeconds: EzraSceneViewControl.voiceViewChangeSeconds)
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
        // Round 22: a scene on its way out no longer takes the mouse or starts turning again.
        takesTheMouse = false
        turnResumeWorkItem?.cancel()
        turnResumeWorkItem = nil
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

    /// Adds one part to the model. `partIndex` is its place in the scene. `labelNumber` is the number
    /// on its tag, or nil for a part without a label. `cameraFit` frames the model with this part (and
    /// the ones still to come in this reply) in it. Round 22: `shownCentre` is where the part appears
    /// while the model is pulled apart (nil: its own centre).
    func addPart(_ part: EzraScenePart, partIndex: Int, labelNumber: Int?, cameraFit: EzraSceneCameraFit, isAnimated: Bool, shownCentre: EzraSceneVector? = nil) {
        sceneGraph.applyCameraFit(cameraFit, animationSeconds: isAnimated ? Self.cameraRefitSeconds : 0)
        sceneGraph.addPartNode(for: part, partIndex: partIndex, appearSeconds: isAnimated ? Self.partAppearSeconds : 0, shownCentre: shownCentre)

        guard let labelNumber, let labelText = part.labelText else { return }
        addLabelTag(labelNumber: labelNumber, labelText: labelText, partIndex: partIndex, isAnimated: isAnimated)
    }

    /// Round 22: shows the parts that are on the screen at new centres (pulled apart, or back where
    /// their tags put them) and frames them, all in one glide; the leader lines follow by themselves.
    /// It remembers which it is, so the toggle shows what its next click does.
    func showParts(atCentres shownCentresByIndex: [Int: EzraSceneVector], cameraFit: EzraSceneCameraFit, isExploded: Bool, animationSeconds: Double) {
        isShowingExplodedParts = isExploded
        sceneGraph.moveParts(toCentresByIndex: shownCentresByIndex, animationSeconds: animationSeconds)
        sceneGraph.applyCameraFit(cameraFit, animationSeconds: animationSeconds)
        updateExplodeToggleLook()
    }

    private func addLabelTag(labelNumber: Int, labelText: String, partIndex: Int, isAnimated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let tagLayer = CALayer()
        let discLayer = CALayer()
        discLayer.backgroundColor = NSColor(DS.Colors.overlayDrawingInk).cgColor
        discLayer.cornerRadius = CGFloat(EzraScenePanelLayoutCalculator.labelDiscDiameterInPoints) / 2
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
            partIndex: partIndex,
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

        updateLeaderLines(glideSeconds: 0)

        if isAnimated {
            // The tag and its leader line appear together with their part.
            for appearingLayer in [tagLayer, leaderLineLayer, leaderDotLayer] {
                let fadeInAnimation = CABasicAnimation(keyPath: "opacity")
                fadeInAnimation.fromValue = 0
                fadeInAnimation.toValue = appearingLayer.opacity
                fadeInAnimation.duration = Self.partAppearSeconds
                fadeInAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                appearingLayer.add(fadeInAnimation, forKey: "ezraSceneLabelAppear")
            }
        }
    }

    // MARK: Layout

    /// Gives the panel a new layout and place, for when the first labelled part arrives on a
    /// scene that had no column of tags, or (round 22) the thirteenth on a scene with one column.
    /// The columns are on the side facing the middle of the screen and the panel keeps its corner,
    /// so the model stays exactly where it was.
    func applyPanelLayout(_ newPanelLayout: EzraScenePanelLayout, panelFrameInContainer: CGRect) {
        panelLayout = newPanelLayout
        frame = panelFrameInContainer.insetBy(dx: -Self.shadowRoomInPoints, dy: -Self.shadowRoomInPoints)
        layOutPanelContent()
        updateLeaderLines(glideSeconds: 0)
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

        // Round 22: the explode toggle at the right end of the title row.
        let explodeToggleFrame = frameInOwnCoordinates(forFrameInPanel: EzraScenePanelLayoutCalculator.explodeToggleFrame(in: panelLayout))
        explodeToggleOutlineLayer.frame = explodeToggleFrame
        explodeToggleGlyphLayer.frame = explodeToggleFrame
        let toggleSquare = CGRect(origin: .zero, size: explodeToggleFrame.size)
        explodeToggleOutlineLayer.path = CGPath(
            roundedRect: toggleSquare.insetBy(dx: Self.explodeToggleOutlineWidthInPoints / 2, dy: Self.explodeToggleOutlineWidthInPoints / 2),
            cornerWidth: Self.explodeToggleCornerRadiusInPoints,
            cornerHeight: Self.explodeToggleCornerRadiusInPoints,
            transform: nil
        )
        updateExplodeToggleLook()

        for labelledPart in labelledParts {
            layOutLabelTag(of: labelledPart)
        }
        CATransaction.commit()
    }

    /// Round 22: the toggle shows what a click does: arrows out while the model is together, in
    /// while it is pulled apart; a light fill while the pointer is over it.
    private func updateExplodeToggleLook() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        explodeToggleGlyphLayer.path = Self.makeExplodeToggleGlyphPath(
            sideInPoints: explodeToggleGlyphLayer.bounds.width,
            arrowsPointOutwards: !isShowingExplodedParts
        )
        explodeToggleOutlineLayer.fillColor = isPointerOverExplodeToggle
            ? NSColor(DS.Colors.overlayDrawingSceneToggleHoverFill).cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()
    }

    /// The faint squared grid of the paper, counted from its top-left corner like the card's.
    private static func makeGridPath(paperSize: CGSize) -> CGPath {
        let gridSpacing = EzraExplanationCardLayerBuilder.cardGridSpacingInPoints
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
        guard let tagFrameInPanel = EzraScenePanelLayoutCalculator.labelTagFrame(forLabelNumber: labelledPart.labelNumber, in: panelLayout) else {
            return
        }
        // The tag layer covers the whole host, so its pieces are placed in the host's coordinates.
        labelledPart.tagLayer.frame = paperHostView.bounds
        labelledPart.leaderLineLayer.frame = leaderHostView.bounds

        let discFrame = frameInOwnCoordinates(
            forFrameInPanel: EzraScenePanelLayoutCalculator.labelDiscFrame(forLabelTagFrame: tagFrameInPanel, in: panelLayout)
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
            forFrameInPanel: EzraScenePanelLayoutCalculator.labelTextFrame(forLabelTagFrame: tagFrameInPanel, in: panelLayout)
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
                self.updateLeaderLines(glideSeconds: Self.leaderUpdateIntervalSeconds)
            }
        }
    }

    /// How the points `projectPoint` gives map onto the SceneKit view's own points. Round 22: worked
    /// out from the renderer each time rather than assumed, because the camera always looks at the
    /// world's origin (where the middle of the model sits): the origin is projected to the middle of
    /// the view, which gives the units, and a point a little above it shows which way y grows.
    private struct SceneKitViewProjection {
        let projectedUnitsPerPoint: CGFloat
        let projectedYGrowsUpwards: Bool
        let viewHeightInPoints: CGFloat
    }

    private func currentSceneKitViewProjection() -> SceneKitViewProjection? {
        let sceneKitViewBounds = sceneKitView.bounds
        guard sceneKitViewBounds.width > 0, sceneKitViewBounds.height > 0 else { return nil }
        let projectedOrigin = sceneKitView.projectPoint(SCNVector3(0, 0, 0))
        var projectedUnitsPerPoint = projectedOrigin.x / (sceneKitViewBounds.width / 2)
        if !projectedUnitsPerPoint.isFinite || projectedUnitsPerPoint <= 0 {
            projectedUnitsPerPoint = 1
        }
        let heightAboveOrigin = CGFloat(max(0.01, sceneGraph.cameraFit.boundingSphereRadius * 0.1))
        let projectedPointAboveOrigin = sceneKitView.projectPoint(SCNVector3(0, heightAboveOrigin, 0))
        return SceneKitViewProjection(
            projectedUnitsPerPoint: projectedUnitsPerPoint,
            projectedYGrowsUpwards: projectedPointAboveOrigin.y >= projectedOrigin.y,
            viewHeightInPoints: sceneKitViewBounds.height
        )
    }

    /// Where a point of the scene (in world coordinates) is in this view.
    private func pointInOwnCoordinates(forWorldPosition worldPosition: SCNVector3, projection: SceneKitViewProjection) -> CGPoint {
        let projectedPoint = sceneKitView.projectPoint(worldPosition)
        let xInSceneKitView = projectedPoint.x / projection.projectedUnitsPerPoint
        let projectedYInPoints = projectedPoint.y / projection.projectedUnitsPerPoint
        let yInSceneKitView = projection.projectedYGrowsUpwards ? projectedYInPoints : projection.viewHeightInPoints - projectedYInPoints
        return convert(CGPoint(x: xInSceneKitView, y: yInSceneKitView), from: sceneKitView)
    }

    /// Moves the far end of every leader line to where the renderer shows its part. Round 22: read
    /// from the part's node as it is presented (turned, tilted, zoomed, exploded or in the middle of
    /// any of those) and projected by the SceneKit view, so a line follows every way the model moves.
    /// The tags themselves never move. With `glideSeconds` above zero the ends glide there from where
    /// they are now, aiming at where the part will be once the slow turn has gone on that long.
    func updateLeaderLines(glideSeconds: Double) {
        guard let projection = currentSceneKitViewProjection() else { return }
        let turnInRadiansBeforeTheGlideEnds = glideSeconds > 0 && sceneGraph.isTurningOnItsOwn
            ? EzraSceneCamera.turnAngleInRadians(atSecondsSinceTurnBegan: glideSeconds)
            : 0
        for labelledPart in labelledParts {
            guard let tagFrameInPanel = EzraScenePanelLayoutCalculator.labelTagFrame(forLabelNumber: labelledPart.labelNumber, in: panelLayout),
                  let partNode = sceneGraph.partNodesByIndex[labelledPart.partIndex] else {
                continue
            }
            let leaderStartPoint = pointInOwnCoordinates(
                forPointInPanel: EzraScenePanelLayoutCalculator.leaderStartPoint(forLabelTagFrame: tagFrameInPanel, in: panelLayout)
            )
            let partWorldPositionNow = EzraSceneGraph.worldPositionOfPartCentre(of: partNode)
            // The model turns round the vertical line through the world's origin.
            let cosineOfTurn = CGFloat(cos(turnInRadiansBeforeTheGlideEnds))
            let sineOfTurn = CGFloat(sin(turnInRadiansBeforeTheGlideEnds))
            let aimedWorldPosition = SCNVector3(
                partWorldPositionNow.x * cosineOfTurn + partWorldPositionNow.z * sineOfTurn,
                partWorldPositionNow.y,
                -partWorldPositionNow.x * sineOfTurn + partWorldPositionNow.z * cosineOfTurn
            )
            let leaderEndPoint = pointInOwnCoordinates(forWorldPosition: aimedWorldPosition, projection: projection)
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
                leaderLineLayer.add(pathGlideAnimation, forKey: "ezraSceneLeaderGlide")

                let dotGlideAnimation = CABasicAnimation(keyPath: "position")
                dotGlideAnimation.fromValue = NSValue(point: dotPositionOnScreenNow)
                dotGlideAnimation.toValue = NSValue(point: leaderEndPoint)
                dotGlideAnimation.duration = glideSeconds
                dotGlideAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
                leaderDotLayer.add(dotGlideAnimation, forKey: "ezraSceneLeaderGlide")
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
