import Foundation
import CoreGraphics

// The pure half of Ezra's simple 3D scenes: the validated parts a scene is built from, their
// limits and palette, the bounds and camera-fit maths, where a part lands in the picture as the
// model turns, and where the scene's panel and its numbered tags go on the screen.
//
// A scene is a schematic model made of a few basic shapes, not a photoreal one. It is built only
// from the values below: there is no script, no file loading and no network anywhere in it.
// Everything here is Foundation and CoreGraphics only, so it can be tested without SceneKit.

// MARK: - The parts of a scene

/// The basic shapes a part can be. The raw value is the word used in a `[PART:...]` tag.
nonisolated enum EzraScenePartShapeKind: String, CaseIterable, Equatable {
    case box
    case cylinder
    case sphere
    case cone
    /// A hollow cylinder.
    case tube
    case capsule
    // Round 22: six more shapes, so a model needs fewer boxes standing in for what they are not.
    /// A doughnut: a ring radius (from the middle of the hole to the middle of the tube) and a pipe
    /// radius (the tube's own thickness).
    case torus
    /// A thin torus, for a wire, a rim or a handle: only its radius is written, the pipe follows.
    case ring
    /// A pyramid on a rectangular base, its tip up.
    case pyramid
    /// A flat sheet, for a screen, a fin, a sail or a floor.
    case plane
    /// A right triangle extruded into a block, for a ramp, a roof side or a door stop.
    case wedge
    /// Half a sphere, its flat side down, for a dome, a lamp shade or a button.
    case hemisphere

    /// A box, a sphere and the flat or pointed shapes have no direction to point along, so an axis
    /// means nothing for them. A torus and a ring do have one: the direction of their hole.
    var pointsAlongAnAxis: Bool {
        switch self {
        case .box, .sphere, .pyramid, .plane, .wedge, .hemisphere:
            return false
        case .cylinder, .cone, .tube, .capsule, .torus, .ring:
            return true
        }
    }

    /// How many numbers the size of this shape has in a tag: `w,h,d` for a box, a pyramid and a
    /// wedge, `w,h` for a plane, `radius,length` for the round shapes, `ring,pipe` for a torus,
    /// and one radius for a sphere, a ring and a hemisphere.
    var sizeNumberCount: Int {
        switch self {
        case .box, .pyramid, .wedge:
            return 3
        case .cylinder, .cone, .tube, .capsule, .torus, .plane:
            return 2
        case .sphere, .ring, .hemisphere:
            return 1
        }
    }
}

/// The direction a cylinder, cone, tube or capsule points along. A cone's tip is at the positive
/// end of its axis. For a torus and a ring it is the direction of the hole.
nonisolated enum EzraScenePartAxis: String, CaseIterable, Equatable {
    case x
    case y
    case z
}

/// One colour as plain numbers (sRGB, each from 0 to 1), so the palette can live here without AppKit.
nonisolated struct EzraSceneColourComponents: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    /// 1 for a solid part. Less than 1 only for `glass`.
    let opacity: Double
}

/// The fixed palette a part's colour is picked from. The raw value is the word used in the tag.
/// The colours are a little muted so a model reads as a matte sketch on the cream paper it sits on.
nonisolated enum EzraScenePartColour: String, CaseIterable, Equatable {
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case purple
    case pink
    case brown
    case gray
    case white
    case black
    /// A translucent part, for a window, a lens or a housing that shows what is inside it.
    case glass

    /// How see-through a glass part is.
    static let glassOpacity: Double = 0.38

    /// Reads a colour word. "grey" is the same colour as "gray"; any other unknown word is not a colour.
    static func colour(named colourName: String) -> EzraScenePartColour? {
        let lowercasedColourName = colourName.lowercased()
        if lowercasedColourName == "grey" {
            return .gray
        }
        return EzraScenePartColour(rawValue: lowercasedColourName)
    }

    var isTranslucent: Bool {
        self == .glass
    }

    var components: EzraSceneColourComponents {
        switch self {
        case .red: return Self.solidColour(redByte: 0xD9, greenByte: 0x48, blueByte: 0x3B)
        case .orange: return Self.solidColour(redByte: 0xE8, greenByte: 0x83, blueByte: 0x3A)
        case .yellow: return Self.solidColour(redByte: 0xEB, greenByte: 0xC2, blueByte: 0x46)
        case .green: return Self.solidColour(redByte: 0x5B, greenByte: 0xA8, blueByte: 0x68)
        case .teal: return Self.solidColour(redByte: 0x3F, greenByte: 0xA7, blueByte: 0xA0)
        case .blue: return Self.solidColour(redByte: 0x4A, greenByte: 0x86, blueByte: 0xD4)
        case .purple: return Self.solidColour(redByte: 0x8A, greenByte: 0x6B, blueByte: 0xC9)
        case .pink: return Self.solidColour(redByte: 0xE5, greenByte: 0x8B, blueByte: 0xB0)
        case .brown: return Self.solidColour(redByte: 0x8B, greenByte: 0x62, blueByte: 0x44)
        case .gray: return Self.solidColour(redByte: 0x9A, greenByte: 0xA0, blueByte: 0xA8)
        case .white: return Self.solidColour(redByte: 0xF2, greenByte: 0xF3, blueByte: 0xF5)
        case .black: return Self.solidColour(redByte: 0x2A, greenByte: 0x2C, blueByte: 0x30)
        case .glass:
            return EzraSceneColourComponents(red: 0xBF / 255.0, green: 0xE3 / 255.0, blue: 0xF2 / 255.0, opacity: Self.glassOpacity)
        }
    }

    private static func solidColour(redByte: Int, greenByte: Int, blueByte: Int) -> EzraSceneColourComponents {
        EzraSceneColourComponents(
            red: Double(redByte) / 255.0,
            green: Double(greenByte) / 255.0,
            blue: Double(blueByte) / 255.0,
            opacity: 1
        )
    }
}

/// A position or a size in scene units. x runs to the right, y up, z towards the viewer.
nonisolated struct EzraSceneVector: Equatable {
    let x: Double
    let y: Double
    let z: Double

    static let zero = EzraSceneVector(x: 0, y: 0, z: 0)

    /// Round 22: the distance from the origin to this point.
    var length: Double {
        (x * x + y * y + z * z).squareRoot()
    }
}

/// How large a part is. Which case a part has follows from its shape.
nonisolated enum EzraScenePartDimensions: Equatable {
    /// A box: width along x, height along y, depth along z. Round 22: a pyramid and a wedge are
    /// sized the same way (the pyramid's tip and the wedge's tall side are up, along y).
    case box(width: Double, height: Double, depth: Double)
    /// A cylinder, cone, tube or capsule: its radius and its length along its axis.
    case radiusAndLength(radius: Double, length: Double)
    case sphere(radius: Double)
    /// Round 22: a torus or a ring. `ringRadius` runs from the middle of the hole to the middle of
    /// the tube, `pipeRadius` is the tube's own radius (smaller than `ringRadius`). A ring's pipe is
    /// worked out from its radius (`EzraScenePart.ringPipeRadius(forRingRadius:)`).
    case torus(ringRadius: Double, pipeRadius: Double)
    /// Round 22: a plane, width along x and height along y. It is drawn as a slab
    /// `EzraScenePart.planeThickness` deep, so both of its faces show.
    case plane(width: Double, height: Double)
    /// Round 22: a hemisphere, its flat side down.
    case hemisphere(radius: Double)
}

/// Round 22: a part turned freely, in degrees about the scene's x, y and z axes (through the part's
/// own centre), applied in that order after its axis. The default turns nothing.
nonisolated struct EzraScenePartRotation: Equatable {
    let degreesX: Double
    let degreesY: Double
    let degreesZ: Double

    static let none = EzraScenePartRotation(degreesX: 0, degreesY: 0, degreesZ: 0)

    /// Each angle is at most one whole turn either way. A larger number is a mistake, not a place.
    static let largestAngleInDegrees: Double = 360

    var isDefault: Bool {
        degreesX == 0 && degreesY == 0 && degreesZ == 0
    }

    /// "rx,ry,rz" the way the tags write numbers (at most two decimals, no trailing zeros).
    var tagText: String {
        "\(EzraScene.numberText(degreesX)),\(EzraScene.numberText(degreesY)),\(EzraScene.numberText(degreesZ))"
    }
}

/// Round 22: what a part is made of, which changes how it takes the light. The raw value is the
/// word after `mat=` in a tag. `matte` is the look every part had before round 22.
nonisolated enum EzraScenePartMaterial: String, CaseIterable, Equatable {
    case matte
    case metal
    case plastic
    case rubber
    case glass
    /// A part that gives off light of its own colour, for a lamp, an LED or a flame.
    case glow
}

/// One validated part of a scene. Every value is inside the limits of `EzraScene`.
nonisolated struct EzraScenePart: Equatable {
    let shapeKind: EzraScenePartShapeKind
    /// The part's name, shown on a numbered tag beside the model. nil for an unlabelled part.
    let labelText: String?
    let centre: EzraSceneVector
    let dimensions: EzraScenePartDimensions
    let colour: EzraScenePartColour
    /// Always `.y` for a shape without an axis (a box, a sphere, and since round 22 a pyramid, a
    /// plane, a wedge and a hemisphere), where it means nothing.
    let axis: EzraScenePartAxis
    /// Round 22: how the part is turned after its axis. A part written without `rot=` is not turned,
    /// so every part of an older reply has the value it always had.
    var rotation: EzraScenePartRotation = .none
    /// Round 22: what the part is made of. A part written without `mat=` is matte, the look of every
    /// part before round 22. A part coloured `glass` stays matte here and is shown as glass through
    /// `effectiveMaterial`, so its tag and its look are what they were.
    var material: EzraScenePartMaterial = .matte

    /// The inside of a tube is this share of its radius, so its wall is clearly a wall and its
    /// hole clearly a hole at the size a scene is shown.
    static let tubeInnerRadiusShareOfOuterRadius: Double = 0.7

    /// Round 22: a ring is a torus whose pipe is this share of its radius, so it reads as a wire or
    /// a rim and not as a doughnut.
    static let ringPipeShareOfRadius: Double = 0.08

    /// Round 22: a plane is drawn as a slab this deep, so both of its faces show and catch the light.
    static let planeThickness: Double = 0.02

    /// Round 22: the pipe of a ring with this radius: 0.08 of the radius, at least 0.05 (the smallest
    /// size a part may have, so it can still be seen), and never more than half the radius, so even
    /// the smallest ring keeps a hole.
    static func ringPipeRadius(forRingRadius ringRadius: Double) -> Double {
        min(max(ringRadius * ringPipeShareOfRadius, EzraScene.minimumPartSize), ringRadius / 2)
    }

    /// Round 22: what the part looks like it is made of: glass for a part coloured `glass` (the way a
    /// glass part was written before round 22), otherwise its own material.
    var effectiveMaterial: EzraScenePartMaterial {
        colour == .glass && material == .matte ? .glass : material
    }

    /// A glass part is see-through and is drawn after the solid ones, so what is inside it shows.
    var isTranslucent: Bool {
        effectiveMaterial == .glass
    }

    /// The length a part really has along its axis. A capsule cannot be shorter than its two
    /// round ends, so a shorter one is as long as they are (it is then a ball).
    var lengthAlongAxis: Double {
        switch dimensions {
        case .radiusAndLength(let radius, let length):
            return shapeKind == .capsule ? max(length, 2 * radius) : length
        case .box, .sphere, .torus, .plane, .hemisphere:
            return 0
        }
    }

    /// Half of the part's size along x, y and z: how far it reaches from its centre, before it is
    /// turned by `rotation` (see `boundingHalfExtents` for a turned part).
    var halfExtents: EzraSceneVector {
        switch dimensions {
        case .box(let width, let height, let depth):
            return EzraSceneVector(x: width / 2, y: height / 2, z: depth / 2)
        case .sphere(let radius):
            return EzraSceneVector(x: radius, y: radius, z: radius)
        case .radiusAndLength(let radius, _):
            let halfLength = lengthAlongAxis / 2
            switch axis {
            case .x: return EzraSceneVector(x: halfLength, y: radius, z: radius)
            case .y: return EzraSceneVector(x: radius, y: halfLength, z: radius)
            case .z: return EzraSceneVector(x: radius, y: radius, z: halfLength)
            }
        case .torus(let ringRadius, let pipeRadius):
            // The ring lies across its axis, so it is as wide as ring and pipe together on the two
            // other axes, and as thick as the pipe along the axis.
            let outerRadius = ringRadius + pipeRadius
            switch axis {
            case .x: return EzraSceneVector(x: pipeRadius, y: outerRadius, z: outerRadius)
            case .y: return EzraSceneVector(x: outerRadius, y: pipeRadius, z: outerRadius)
            case .z: return EzraSceneVector(x: outerRadius, y: outerRadius, z: pipeRadius)
            }
        case .plane(let width, let height):
            return EzraSceneVector(x: width / 2, y: height / 2, z: Self.planeThickness / 2)
        case .hemisphere(let radius):
            // The dome is centred on its own bounds like every other part: its flat side is half a
            // radius below the centre and its top half a radius above it.
            return EzraSceneVector(x: radius, y: radius / 2, z: radius)
        }
    }

    /// Round 22: how far the part reaches from its centre along x, y and z however it is turned: its
    /// `halfExtents` when it is not turned, otherwise a cube around its bounding ball, so a camera
    /// fit built from it can never cut a turned part off.
    var boundingHalfExtents: EzraSceneVector {
        guard !rotation.isDefault else {
            return halfExtents
        }
        let boundingBallRadius = halfExtents.length
        return EzraSceneVector(x: boundingBallRadius, y: boundingBallRadius, z: boundingBallRadius)
    }

    /// Round 22: the same part, somewhere else. Used for the exploded view.
    func movedTo(centre newCentre: EzraSceneVector) -> EzraScenePart {
        EzraScenePart(
            shapeKind: shapeKind,
            labelText: labelText,
            centre: newCentre,
            dimensions: dimensions,
            colour: colour,
            axis: axis,
            rotation: rotation,
            material: material
        )
    }

    /// Everything after "PART:" the way the grammar writes it, such as
    /// "cylinder:fan:0,0,2:1.2,0.3:blue:x". The axis is left out when it is the default (up) or
    /// means nothing for the shape. Used for the conversation history and the "marks on screen" list.
    /// Round 22: a turned part ends in ":rot=rx,ry,rz" and a part that is not matte in
    /// ":mat=material", in that order; a part written with neither has exactly the body it had
    /// before. A part coloured glass never writes ":mat=glass", which it already is.
    var canonicalTagBody: String {
        let numberText = EzraScene.numberText
        let sizeText: String
        switch dimensions {
        case .box(let width, let height, let depth):
            sizeText = "\(numberText(width)),\(numberText(height)),\(numberText(depth))"
        case .radiusAndLength(let radius, let length):
            sizeText = "\(numberText(radius)),\(numberText(length))"
        case .sphere(let radius), .hemisphere(let radius):
            sizeText = numberText(radius)
        case .torus(let ringRadius, let pipeRadius):
            // A ring writes only its radius: its pipe follows from it.
            sizeText = shapeKind == .ring ? numberText(ringRadius) : "\(numberText(ringRadius)),\(numberText(pipeRadius))"
        case .plane(let width, let height):
            sizeText = "\(numberText(width)),\(numberText(height))"
        }
        let positionText = "\(numberText(centre.x)),\(numberText(centre.y)),\(numberText(centre.z))"
        let axisSuffix = (shapeKind.pointsAlongAnAxis && axis != .y) ? ":\(axis.rawValue)" : ""
        let rotationSuffix = rotation.isDefault ? "" : ":rot=\(rotation.tagText)"
        let materialIsWritten = material != .matte && !(colour == .glass && material == .glass)
        let materialSuffix = materialIsWritten ? ":mat=\(material.rawValue)" : ""
        return "\(shapeKind.rawValue):\(labelText ?? ""):\(positionText):\(sizeText):\(colour.rawValue)\(axisSuffix)\(rotationSuffix)\(materialSuffix)"
    }
}

/// A simple 3D model: a title and the parts added so far, in the order they were written.
nonisolated struct EzraScene: Equatable {
    /// The title is one short line above the model. Longer text is cut, like a card's title.
    static let maximumTitleCharacterCount = 40

    /// A part's name sits on a small tag beside the model. Longer text is cut.
    static let maximumPartLabelCharacterCount = 24

    /// Round 22: twenty-four basic shapes (twelve before) are enough for a model with real parts,
    /// such as a bicycle, and still light to draw. Every one of them may be labelled: the tags stand
    /// in two columns of twelve.
    static let maximumPartCount = 24

    /// A part's centre is at most this far from the middle of the scene on each axis. The app
    /// scales the whole model to its panel, so the numbers only matter relative to each other.
    static let maximumCentreCoordinate: Double = 5

    /// A part thinner than this is invisible at the size a scene is shown, and one larger than
    /// this is bigger than the whole space parts can be placed in.
    static let minimumPartSize: Double = 0.05
    static let maximumPartSize: Double = 6

    let title: String
    let parts: [EzraScenePart]
    /// Round 22: true while the parts are pulled apart (`[VIEW:exploded]` or the toggle on the
    /// paper), false while they sit where their tags put them. A new scene is assembled.
    var isExploded: Bool = false

    func addingPart(_ part: EzraScenePart) -> EzraScene {
        EzraScene(title: title, parts: parts + [part], isExploded: isExploded)
    }

    func keepingFirstParts(_ partCountToKeep: Int) -> EzraScene {
        EzraScene(title: title, parts: Array(parts.prefix(max(0, partCountToKeep))), isExploded: isExploded)
    }

    var hasLabelledParts: Bool {
        parts.contains { $0.labelText != nil }
    }

    /// Round 22: how many parts have a label (and so a numbered tag).
    var labelledPartCount: Int {
        parts.filter { $0.labelText != nil }.count
    }

    /// The number on a part's tag: labelled parts count 1, 2, 3 in the order they were added,
    /// across replies. nil for an unlabelled part or an index the scene does not have.
    func labelNumber(forPartAtIndex partIndex: Int) -> Int? {
        guard partIndex >= 0, partIndex < parts.count, parts[partIndex].labelText != nil else {
            return nil
        }
        return parts[...partIndex].filter { $0.labelText != nil }.count
    }

    /// A number the way the tags write it: at most two decimals, no trailing zeros, "0" for zero.
    static func numberText(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text == "-0" ? "0" : text
    }
}

// MARK: - Bounds, camera fit and projection

/// The smallest box, with sides along the axes, that holds a set of parts.
nonisolated struct EzraSceneBounds: Equatable {
    let minimum: EzraSceneVector
    let maximum: EzraSceneVector

    var centre: EzraSceneVector {
        EzraSceneVector(
            x: (minimum.x + maximum.x) / 2,
            y: (minimum.y + maximum.y) / 2,
            z: (minimum.z + maximum.z) / 2
        )
    }

    /// From the centre to a corner: the radius of a ball around the centre that holds everything.
    var halfDiagonalLength: Double {
        let halfWidth = (maximum.x - minimum.x) / 2
        let halfHeight = (maximum.y - minimum.y) / 2
        let halfDepth = (maximum.z - minimum.z) / 2
        return (halfWidth * halfWidth + halfHeight * halfHeight + halfDepth * halfDepth).squareRoot()
    }
}

/// How the camera is set so a model fills its square picture without ever leaving it.
nonisolated struct EzraSceneCameraFit: Equatable {
    /// The middle of the model. The model turns around the vertical line through this point and
    /// the camera looks at it.
    let modelCentre: EzraSceneVector
    /// The radius of the ball around `modelCentre` that holds every part.
    let boundingSphereRadius: Double
    /// How far the camera is from `modelCentre`.
    let cameraDistance: Double
}

nonisolated enum EzraSceneCamera {
    /// A narrow lens, so a schematic model is not stretched at its edges.
    static let verticalFieldOfViewInDegrees: Double = 30

    /// The camera looks slightly down on the model, so its top faces show and it reads as a solid.
    static let downwardTiltInDegrees: Double = 20

    /// The camera stands this much further back than the fit of the ball around the model. That
    /// ball is already roomy (a model rarely reaches the corners of its bounds), so a little is
    /// enough to keep the model and the dots of its leader lines off the edge of the picture.
    static let fitMarginFactor: Double = 1.04

    /// One slow turn: fast enough to show every side, slow enough to read the tags.
    static let secondsPerTurn: Double = 14

    /// A scene with no parts, or one tiny part, is still framed as if it were this large, so the
    /// camera distance never becomes zero.
    static let smallestBoundingSphereRadius: Double = 0.05

    /// The radius a scene with no parts yet is framed for.
    static let boundingSphereRadiusOfEmptyScene: Double = 1

    /// Round 22: a turned part counts with its `boundingHalfExtents` (a cube around its bounding
    /// ball), so the fit never cuts it off; a part that is not turned counts exactly as before.
    static func bounds(of parts: [EzraScenePart]) -> EzraSceneBounds? {
        guard let firstPart = parts.first else {
            return nil
        }
        let firstReach = firstPart.boundingHalfExtents
        var minimumX = firstPart.centre.x - firstReach.x
        var minimumY = firstPart.centre.y - firstReach.y
        var minimumZ = firstPart.centre.z - firstReach.z
        var maximumX = firstPart.centre.x + firstReach.x
        var maximumY = firstPart.centre.y + firstReach.y
        var maximumZ = firstPart.centre.z + firstReach.z
        for part in parts.dropFirst() {
            let reach = part.boundingHalfExtents
            minimumX = min(minimumX, part.centre.x - reach.x)
            minimumY = min(minimumY, part.centre.y - reach.y)
            minimumZ = min(minimumZ, part.centre.z - reach.z)
            maximumX = max(maximumX, part.centre.x + reach.x)
            maximumY = max(maximumY, part.centre.y + reach.y)
            maximumZ = max(maximumZ, part.centre.z + reach.z)
        }
        return EzraSceneBounds(
            minimum: EzraSceneVector(x: minimumX, y: minimumY, z: minimumZ),
            maximum: EzraSceneVector(x: maximumX, y: maximumY, z: maximumZ)
        )
    }

    /// The camera fit for a set of parts.
    ///
    /// The model turns, so the fit must hold at every angle. A ball around the middle of the
    /// bounds holds the model however it is turned, and a ball of radius r seen from distance d
    /// fills an angle of 2 x asin(r / d). The camera therefore stands at r / sin(half the field of
    /// view), a little further for the margin.
    static func cameraFit(for parts: [EzraScenePart]) -> EzraSceneCameraFit {
        let modelCentre: EzraSceneVector
        let boundingSphereRadius: Double
        if let bounds = bounds(of: parts) {
            modelCentre = bounds.centre
            boundingSphereRadius = max(smallestBoundingSphereRadius, bounds.halfDiagonalLength)
        } else {
            modelCentre = .zero
            boundingSphereRadius = boundingSphereRadiusOfEmptyScene
        }
        let halfFieldOfViewInRadians = verticalFieldOfViewInDegrees / 2 * Double.pi / 180
        return EzraSceneCameraFit(
            modelCentre: modelCentre,
            boundingSphereRadius: boundingSphereRadius,
            cameraDistance: boundingSphereRadius / sin(halfFieldOfViewInRadians) * fitMarginFactor
        )
    }

    /// Where the camera stands, measured from the middle of the model: back along z and raised
    /// by the tilt, looking at the middle.
    static func cameraPositionRelativeToModelCentre(for cameraFit: EzraSceneCameraFit) -> EzraSceneVector {
        let tiltInRadians = downwardTiltInDegrees * Double.pi / 180
        return EzraSceneVector(
            x: 0,
            y: cameraFit.cameraDistance * sin(tiltInRadians),
            z: cameraFit.cameraDistance * cos(tiltInRadians)
        )
    }

    /// How far the model has turned (in radians, around the vertical axis) this many seconds
    /// after it began to turn.
    static func turnAngleInRadians(atSecondsSinceTurnBegan secondsSinceTurnBegan: Double) -> Double {
        2 * Double.pi * (secondsSinceTurnBegan / secondsPerTurn)
    }

    /// Where a point of the model appears in the square picture, in points from the picture's
    /// top-left corner, when the model has turned by `turnAngleInRadians`.
    ///
    /// This is the same perspective the renderer uses, done here in plain numbers. Round 22: it
    /// assumes one steady turn about the vertical axis and the first view's tilt and distance, which
    /// no longer hold once the user drags, zooms or explodes the model, so the app's leader lines now
    /// ask the renderer (`projectPoint`). This stays for the smoke program, which checks the
    /// renderer's projection against it for the first view.
    static func pointInModelView(
        forModelPoint modelPoint: EzraSceneVector,
        cameraFit: EzraSceneCameraFit,
        turnAngleInRadians: Double,
        modelViewSideInPoints: Double
    ) -> CGPoint {
        // The point measured from the middle of the model, then turned around the vertical axis.
        let relativeX = modelPoint.x - cameraFit.modelCentre.x
        let relativeY = modelPoint.y - cameraFit.modelCentre.y
        let relativeZ = modelPoint.z - cameraFit.modelCentre.z
        let turnedX = relativeX * cos(turnAngleInRadians) + relativeZ * sin(turnAngleInRadians)
        let turnedY = relativeY
        let turnedZ = -relativeX * sin(turnAngleInRadians) + relativeZ * cos(turnAngleInRadians)

        // The camera's own directions: right is the world's x; up and forward are tilted.
        let tiltInRadians = downwardTiltInDegrees * Double.pi / 180
        let distanceRightOfCameraAxis = turnedX
        let distanceAboveCameraAxis = turnedY * cos(tiltInRadians) - turnedZ * sin(tiltInRadians)
        let depthInFrontOfCamera = cameraFit.cameraDistance - turnedY * sin(tiltInRadians) - turnedZ * cos(tiltInRadians)

        let halfFieldOfViewInRadians = verticalFieldOfViewInDegrees / 2 * Double.pi / 180
        // Never zero: every part is inside the ball the camera stands well outside of.
        let halfPictureSizeAtThatDepth = max(0.000_001, depthInFrontOfCamera * tan(halfFieldOfViewInRadians))
        let horizontalShare = distanceRightOfCameraAxis / halfPictureSizeAtThatDepth
        let verticalShare = distanceAboveCameraAxis / halfPictureSizeAtThatDepth
        return CGPoint(
            x: (horizontalShare + 1) / 2 * modelViewSideInPoints,
            y: (1 - verticalShare) / 2 * modelViewSideInPoints
        )
    }
}

// MARK: - Changing the view (round 22)

/// Which way `[VIEW:turn:...]` turns the model: a quarter turn to the left or right, or round to
/// its front (the side that faced the camera when it was built) or its back.
nonisolated enum EzraSceneTurnDirection: String, CaseIterable, Equatable {
    case left
    case right
    case front
    case back
}

/// Which way `[VIEW:zoom:...]` zooms. The raw value is the word in the tag.
nonisolated enum EzraSceneZoomDirection: String, CaseIterable, Equatable {
    case zoomIn = "in"
    case zoomOut = "out"
}

/// One `[VIEW:...]` tag: how the scene on the screen is to be shown. It never adds or removes a
/// part, and is only accepted while there is a scene to show.
nonisolated enum EzraSceneViewCommand: Equatable {
    /// The parts move apart so the inside shows.
    case exploded
    /// The parts move back to where their tags put them.
    case assembled
    case turn(EzraSceneTurnDirection)
    case zoom(EzraSceneZoomDirection)
    /// Back to the first view: the fit's distance, the usual tilt, the front, assembled, turning.
    case reset

    /// Everything after "VIEW:" the way the grammar writes it, such as "turn:left". The
    /// `[VIEW:explode]` alias is written as "exploded".
    var canonicalTagBody: String {
        switch self {
        case .exploded: return "exploded"
        case .assembled: return "assembled"
        case .turn(let turnDirection): return "turn:\(turnDirection.rawValue)"
        case .zoom(let zoomDirection): return "zoom:\(zoomDirection.rawValue)"
        case .reset: return "reset"
        }
    }
}

// MARK: - Turning a part (round 22)

/// A rotation as a unit quaternion, in plain numbers so the composition of a part's axis and its
/// `rot=` can be worked out and tested here (EzraCore uses Foundation and CoreGraphics only, no
/// `simd`). The app hands the four numbers to SceneKit as the part node's orientation.
nonisolated struct EzraSceneQuaternion: Equatable {
    let x: Double
    let y: Double
    let z: Double
    let w: Double

    static let identity = EzraSceneQuaternion(x: 0, y: 0, z: 0, w: 1)

    /// A turn by `angleInDegrees` about a unit axis, by the right-hand rule.
    init(rotationAboutUnitAxisX axisX: Double, axisY: Double, axisZ: Double, angleInDegrees: Double) {
        let halfAngleInRadians = angleInDegrees * Double.pi / 180 / 2
        let sineOfHalfAngle = sin(halfAngleInRadians)
        self.init(x: axisX * sineOfHalfAngle, y: axisY * sineOfHalfAngle, z: axisZ * sineOfHalfAngle, w: cos(halfAngleInRadians))
    }

    init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    /// `self` after `other`: the product self x other, which first turns by `other` and then by
    /// `self` (both about the scene's fixed axes).
    func after(_ other: EzraSceneQuaternion) -> EzraSceneQuaternion {
        EzraSceneQuaternion(
            x: w * other.x + x * other.w + y * other.z - z * other.y,
            y: w * other.y - x * other.z + y * other.w + z * other.x,
            z: w * other.z + x * other.y - y * other.x + z * other.w,
            w: w * other.w - x * other.x - y * other.y - z * other.z
        )
    }

    /// Where this rotation carries a point (or a direction).
    func rotated(_ vector: EzraSceneVector) -> EzraSceneVector {
        // v' = q v q*, written out.
        let twiceCrossX = 2 * (y * vector.z - z * vector.y)
        let twiceCrossY = 2 * (z * vector.x - x * vector.z)
        let twiceCrossZ = 2 * (x * vector.y - y * vector.x)
        return EzraSceneVector(
            x: vector.x + w * twiceCrossX + (y * twiceCrossZ - z * twiceCrossY),
            y: vector.y + w * twiceCrossY + (z * twiceCrossX - x * twiceCrossZ),
            z: vector.z + w * twiceCrossZ + (x * twiceCrossY - y * twiceCrossX)
        )
    }
}

nonisolated enum EzraSceneRotation {
    /// The turn that lays a shape built standing up (along y) over onto its axis: about z by -90
    /// degrees for x (y goes to x), about x by +90 degrees for z (y goes to z), none for y. These
    /// are the angles the renderer has always used for a part's axis.
    static func quaternion(forAxis axis: EzraScenePartAxis) -> EzraSceneQuaternion {
        switch axis {
        case .x: return EzraSceneQuaternion(rotationAboutUnitAxisX: 0, axisY: 0, axisZ: 1, angleInDegrees: -90)
        case .y: return .identity
        case .z: return EzraSceneQuaternion(rotationAboutUnitAxisX: 1, axisY: 0, axisZ: 0, angleInDegrees: 90)
        }
    }

    /// The whole orientation of a part: first its axis, then `rot=` about the scene's x, then its y,
    /// then its z axis (all through the part's own centre). So a cylinder on x with `rot=0,0,30`
    /// is tilted 30 degrees about z, and a cylinder on x with `rot=0,30,0` is turned 30 degrees about
    /// the vertical, which is what a model writing scene coordinates means by it.
    static func quaternion(axis: EzraScenePartAxis, rotation: EzraScenePartRotation) -> EzraSceneQuaternion {
        let aboutX = EzraSceneQuaternion(rotationAboutUnitAxisX: 1, axisY: 0, axisZ: 0, angleInDegrees: rotation.degreesX)
        let aboutY = EzraSceneQuaternion(rotationAboutUnitAxisX: 0, axisY: 1, axisZ: 0, angleInDegrees: rotation.degreesY)
        let aboutZ = EzraSceneQuaternion(rotationAboutUnitAxisX: 0, axisY: 0, axisZ: 1, angleInDegrees: rotation.degreesZ)
        return aboutZ.after(aboutY).after(aboutX).after(quaternion(forAxis: axis))
    }
}

// MARK: - The exploded view (round 22)

/// Pulls a model's parts apart so its inside shows: every part moves away from the middle of the
/// model's bounds, along the line from that middle through its own centre.
nonisolated enum EzraSceneExplosion {
    /// A part moves this share of its distance from the middle further out, so it ends at 1.6
    /// times its offset: far enough to separate nested parts of a typical model, near enough that
    /// the model still reads as one thing.
    static let explosionShare: Double = 0.6

    /// Where a part's centre goes in the exploded view. A part at the middle does not move.
    static func explodedCentre(forPartCentre partCentre: EzraSceneVector, boundsCentre: EzraSceneVector) -> EzraSceneVector {
        EzraSceneVector(
            x: partCentre.x + (partCentre.x - boundsCentre.x) * explosionShare,
            y: partCentre.y + (partCentre.y - boundsCentre.y) * explosionShare,
            z: partCentre.z + (partCentre.z - boundsCentre.z) * explosionShare
        )
    }

    /// Every part of a model at its exploded place, in the same order. The middle is that of the
    /// model's own bounds, so the camera fit for the exploded parts keeps the model in its picture.
    static func explodedParts(_ parts: [EzraScenePart]) -> [EzraScenePart] {
        guard let boundsCentre = EzraSceneCamera.bounds(of: parts)?.centre else {
            return parts
        }
        return parts.map { part in
            part.movedTo(centre: explodedCentre(forPartCentre: part.centre, boundsCentre: boundsCentre))
        }
    }

    /// The parts as the panel shows them: pulled apart while exploded, where their tags put them
    /// otherwise. The camera is fitted to these, so the model stays in its picture either way.
    static func shownParts(_ parts: [EzraScenePart], isExploded: Bool) -> [EzraScenePart] {
        isExploded ? explodedParts(parts) : parts
    }
}

// MARK: - The panel: paper, title, the model's picture and the tags

/// Where everything on a scene's panel goes, in points from the panel's top-left corner.
nonisolated struct EzraScenePanelLayout: Equatable {
    let panelSize: CGSize
    let titleFrame: CGRect
    /// The square the model is drawn in.
    let modelViewFrame: CGRect
    /// The column of numbered tags beside the model. nil while no part has a label.
    let labelColumnFrame: CGRect?
    /// True when the tags are on the left of the model (the panel then sits on the right of the
    /// screen, so the tags are on the side facing the middle of the screen).
    let labelColumnIsOnLeftOfModel: Bool
    /// Round 22: the second column of tags (13 to 24), beyond the first on the same side. nil until
    /// a scene has its thirteenth labelled part.
    var secondLabelColumnFrame: CGRect? = nil

    /// Round 22: how many columns of tags the paper has: 0, 1 or 2.
    var labelColumnCount: Int {
        (labelColumnFrame == nil ? 0 : 1) + (secondLabelColumnFrame == nil ? 0 : 1)
    }
}

nonisolated enum EzraScenePanelLayoutCalculator {
    /// The paper's edge to its content.
    static let paperPaddingInPoints: Double = 10
    static let titleRowHeightInPoints: Double = 26
    /// The square the model is drawn in: "about 300 points" with the padding around it.
    static let modelViewSideInPoints: Double = 280
    static let gapBetweenModelAndLabelColumnInPoints: Double = 4
    /// Wide enough for a typical part name in the handwriting typeface; a longer one ends in an ellipsis.
    static let labelColumnWidthInPoints: Double = 150
    static let labelTagHeightInPoints: Double = 20
    /// From the top of one tag to the top of the next. Twelve tags (a full column) are 276 points,
    /// which fits beside the 280 point model.
    static let labelTagPitchInPoints: Double = 23
    /// The numbered disc at the model's end of a tag. The leader line starts at its edge.
    static let labelDiscDiameterInPoints: Double = 16
    static let gapBetweenLabelDiscAndTextInPoints: Double = 5
    /// Round 22: a column holds twelve tags; tags 13 to 24 stand in the second column.
    static let maximumLabelTagCountPerColumn = 12
    /// Round 22: at most two columns, for the 24 parts a scene may have.
    static let maximumLabelColumnCount = 2

    /// Round 22: how many columns of tags a scene with this many labelled parts needs: none, one
    /// (1 to 12) or two (13 and more).
    static func columnCount(forLabelledPartCount labelledPartCount: Int) -> Int {
        guard labelledPartCount > 0 else {
            return 0
        }
        let neededColumnCount = (labelledPartCount + maximumLabelTagCountPerColumn - 1) / maximumLabelTagCountPerColumn
        return min(maximumLabelColumnCount, neededColumnCount)
    }

    static func layout(hasLabelColumn: Bool, labelColumnIsOnLeftOfModel: Bool) -> EzraScenePanelLayout {
        layout(labelColumnCount: hasLabelColumn ? 1 : 0, labelColumnIsOnLeftOfModel: labelColumnIsOnLeftOfModel)
    }

    /// Round 22: the paper with no, one or two columns of tags: 300, 454 or 608 points wide, always
    /// 326 high. Both columns are on the side facing the middle of the screen, the first next to
    /// the model and the second beyond it. With no or one column the layout is exactly the one
    /// before round 22.
    static func layout(labelColumnCount requestedLabelColumnCount: Int, labelColumnIsOnLeftOfModel: Bool) -> EzraScenePanelLayout {
        let labelColumnCount = min(maximumLabelColumnCount, max(0, requestedLabelColumnCount))
        let oneLabelColumnAndGapWidth = labelColumnWidthInPoints + gapBetweenModelAndLabelColumnInPoints
        let labelColumnsAndGapsWidth = Double(labelColumnCount) * oneLabelColumnAndGapWidth
        let panelWidth = 2 * paperPaddingInPoints + modelViewSideInPoints + labelColumnsAndGapsWidth
        let panelHeight = 2 * paperPaddingInPoints + titleRowHeightInPoints + modelViewSideInPoints
        let contentTopY = paperPaddingInPoints + titleRowHeightInPoints

        let modelViewOriginX = paperPaddingInPoints + (labelColumnIsOnLeftOfModel ? labelColumnsAndGapsWidth : 0)
        let modelViewFrame = CGRect(x: modelViewOriginX, y: contentTopY, width: modelViewSideInPoints, height: modelViewSideInPoints)

        // The column with this place in line from the model: 1 next to it, 2 beyond the first.
        func labelColumnFrame(atPlaceFromTheModel placeFromTheModel: Int) -> CGRect {
            let labelColumnOriginX = labelColumnIsOnLeftOfModel
                ? modelViewOriginX - Double(placeFromTheModel) * oneLabelColumnAndGapWidth
                : modelViewOriginX + modelViewSideInPoints + gapBetweenModelAndLabelColumnInPoints + Double(placeFromTheModel - 1) * oneLabelColumnAndGapWidth
            return CGRect(x: labelColumnOriginX, y: contentTopY, width: labelColumnWidthInPoints, height: modelViewSideInPoints)
        }

        // Round 22: the title ends before the explode toggle at the right end of its row.
        let titleWidth = panelWidth - 2 * paperPaddingInPoints - explodeToggleSideInPoints - gapBetweenTitleAndExplodeToggleInPoints
        return EzraScenePanelLayout(
            panelSize: CGSize(width: panelWidth, height: panelHeight),
            titleFrame: CGRect(x: paperPaddingInPoints, y: paperPaddingInPoints, width: titleWidth, height: titleRowHeightInPoints),
            modelViewFrame: modelViewFrame,
            labelColumnFrame: labelColumnCount >= 1 ? labelColumnFrame(atPlaceFromTheModel: 1) : nil,
            labelColumnIsOnLeftOfModel: labelColumnIsOnLeftOfModel,
            secondLabelColumnFrame: labelColumnCount >= 2 ? labelColumnFrame(atPlaceFromTheModel: 2) : nil
        )
    }

    /// The place of the tag with this number (1 for the first labelled part). The tags stand in
    /// columns from the top, in the order their parts were added, and never move once placed: only
    /// the far end of a tag's leader line follows the turning model. Round 22: tags 1 to 12 are in
    /// the first column, 13 to 24 in the second. nil when the panel has no column for the number,
    /// or the number is not one a scene can have.
    static func labelTagFrame(forLabelNumber labelNumber: Int, in panelLayout: EzraScenePanelLayout) -> CGRect? {
        guard labelNumber >= 1, labelNumber <= EzraScene.maximumPartCount else {
            return nil
        }
        let columnIndex = (labelNumber - 1) / maximumLabelTagCountPerColumn
        let placeInColumn = (labelNumber - 1) % maximumLabelTagCountPerColumn
        let columnFrameOrNil = columnIndex == 0 ? panelLayout.labelColumnFrame : panelLayout.secondLabelColumnFrame
        guard let columnFrame = columnFrameOrNil else {
            return nil
        }
        return CGRect(
            x: Double(columnFrame.minX),
            y: Double(columnFrame.minY) + Double(placeInColumn) * labelTagPitchInPoints,
            width: Double(columnFrame.width),
            height: labelTagHeightInPoints
        )
    }

    /// The numbered disc of a tag: at the end of the tag that faces the model.
    static func labelDiscFrame(forLabelTagFrame labelTagFrame: CGRect, in panelLayout: EzraScenePanelLayout) -> CGRect {
        let discOriginX = panelLayout.labelColumnIsOnLeftOfModel
            ? Double(labelTagFrame.maxX) - labelDiscDiameterInPoints
            : Double(labelTagFrame.minX)
        return CGRect(
            x: discOriginX,
            y: Double(labelTagFrame.midY) - labelDiscDiameterInPoints / 2,
            width: labelDiscDiameterInPoints,
            height: labelDiscDiameterInPoints
        )
    }

    /// The words of a tag: the rest of the tag, on the far side of the disc from the model.
    static func labelTextFrame(forLabelTagFrame labelTagFrame: CGRect, in panelLayout: EzraScenePanelLayout) -> CGRect {
        let textWidth = Double(labelTagFrame.width) - labelDiscDiameterInPoints - gapBetweenLabelDiscAndTextInPoints
        let textOriginX = panelLayout.labelColumnIsOnLeftOfModel
            ? Double(labelTagFrame.minX)
            : Double(labelTagFrame.minX) + labelDiscDiameterInPoints + gapBetweenLabelDiscAndTextInPoints
        return CGRect(x: textOriginX, y: Double(labelTagFrame.minY), width: textWidth, height: Double(labelTagFrame.height))
    }

    /// Where a tag's leader line starts: the point of its disc nearest the model.
    static func leaderStartPoint(forLabelTagFrame labelTagFrame: CGRect, in panelLayout: EzraScenePanelLayout) -> CGPoint {
        let discFrame = labelDiscFrame(forLabelTagFrame: labelTagFrame, in: panelLayout)
        return CGPoint(
            x: panelLayout.labelColumnIsOnLeftOfModel ? discFrame.maxX : discFrame.minX,
            y: discFrame.midY
        )
    }

    /// Where a tag's leader line ends: the place of its part in the model's picture, as a point
    /// of the panel, for the first view (see `EzraSceneCamera.pointInModelView`; the app asks the
    /// renderer since round 22, and this stays for the smoke program).
    static func leaderEndPoint(
        forPartCentre partCentre: EzraSceneVector,
        cameraFit: EzraSceneCameraFit,
        turnAngleInRadians: Double,
        in panelLayout: EzraScenePanelLayout
    ) -> CGPoint {
        let pointInModelView = EzraSceneCamera.pointInModelView(
            forModelPoint: partCentre,
            cameraFit: cameraFit,
            turnAngleInRadians: turnAngleInRadians,
            modelViewSideInPoints: Double(panelLayout.modelViewFrame.width)
        )
        return CGPoint(
            x: panelLayout.modelViewFrame.minX + pointInModelView.x,
            y: panelLayout.modelViewFrame.minY + pointInModelView.y
        )
    }
}

// MARK: - The explode toggle and what the mouse is over (round 22)

/// Round 22: what a point of a scene's panel is, for the scene window's mouse handling.
nonisolated enum EzraScenePanelHitRegion: Equatable {
    /// The shadow room around the paper, or beyond it: not the scene's (a click there does nothing).
    case outsideThePaper
    /// The small toggle in the paper's top-right corner that explodes or assembles the model.
    case explodeToggle
    /// Anywhere else on the paper: a drag there turns the model, a scroll or a pinch zooms it.
    case paper
}

nonisolated extension EzraScenePanelLayoutCalculator {
    /// Round 22: the explode toggle is a small rounded square at the right end of the title row.
    static let explodeToggleSideInPoints: Double = 22
    /// The title stops this far before the toggle, so a long title never runs under it.
    static let gapBetweenTitleAndExplodeToggleInPoints: Double = 6
    /// A click this close outside the toggle still counts as on it: it is small and in a corner.
    static let explodeToggleHitSlopInPoints: Double = 3

    /// Where the toggle is, in points from the panel's top-left corner.
    static func explodeToggleFrame(in panelLayout: EzraScenePanelLayout) -> CGRect {
        CGRect(
            x: Double(panelLayout.panelSize.width) - paperPaddingInPoints - explodeToggleSideInPoints,
            y: paperPaddingInPoints + (titleRowHeightInPoints - explodeToggleSideInPoints) / 2,
            width: explodeToggleSideInPoints,
            height: explodeToggleSideInPoints
        )
    }

    /// What a point of the panel (from its top-left corner) is: off the paper, the toggle (with a
    /// little slop, kept on the paper), or the paper.
    static func hitRegion(atPointInPanel pointInPanel: CGPoint, in panelLayout: EzraScenePanelLayout) -> EzraScenePanelHitRegion {
        let paperFrame = CGRect(origin: .zero, size: panelLayout.panelSize)
        guard paperFrame.contains(pointInPanel) else {
            return .outsideThePaper
        }
        let toggleHitFrame = explodeToggleFrame(in: panelLayout)
            .insetBy(dx: -explodeToggleHitSlopInPoints, dy: -explodeToggleHitSlopInPoints)
            .intersection(paperFrame)
        return toggleHitFrame.contains(pointInPanel) ? .explodeToggle : .paper
    }
}

// MARK: - Turning, tilting and zooming the view (round 22)

/// Round 22: the numbers of the scene window's drag, scroll and pinch, and of the voice's view tags, as
/// plain functions so they can be checked without a window. The model's turn is in radians; the
/// camera's tilt is its downward tilt in degrees (20, the first view, looks a little from above).
nonisolated enum EzraSceneViewControl {
    /// A horizontal drag turns the model this much per point; a vertical one tilts the camera this much.
    static let dragTurnInDegreesPerPoint: Double = 0.6
    static let dragTiltInDegreesPerPoint: Double = 0.4
    /// The camera may tilt from looking up a little from below (-20) to looking steeply down (60):
    /// the camera's own pitch from +20 to -60 degrees.
    static let smallestDownwardTiltInDegrees: Double = -20
    static let largestDownwardTiltInDegrees: Double = 60
    /// The camera may come in to 0.6 of the fit's distance and go out to twice it.
    static let smallestCameraDistanceFactor: Double = 0.6
    static let largestCameraDistanceFactor: Double = 2
    /// A scroll of one point changes the distance by this share; a line of a mouse wheel that reports
    /// no points counts as ten.
    static let scrollZoomSharePerPoint: Double = 0.02
    static let scrollPointsPerWheelLine: Double = 10
    /// "zoom in" brings the camera to three quarters of its distance, "zoom out" takes it a third further.
    static let voiceZoomInFactor: Double = 0.75
    static let voiceZoomOutFactor: Double = 1.33
    /// How long the view takes to change for a voice tag (a turn, a zoom, a reset), and for a scroll step.
    static let voiceViewChangeSeconds: Double = 0.5
    static let scrollZoomSeconds: Double = 0.08
    /// The slow turn starts again this long after the user last turned, tilted or zoomed the model,
    /// or after a voice turn or zoom.
    static let secondsBeforeTheTurnResumes: Double = 10

    static func turnAngleChangeInRadians(forHorizontalDragPoints horizontalDragPoints: Double) -> Double {
        horizontalDragPoints * dragTurnInDegreesPerPoint * Double.pi / 180
    }

    /// AppKit's y grows upwards, so a drag down (a negative change) looks more from above.
    static func downwardTiltInDegrees(afterVerticalDragPoints verticalDragPoints: Double, from downwardTiltInDegrees: Double) -> Double {
        clampedDownwardTilt(downwardTiltInDegrees - verticalDragPoints * dragTiltInDegreesPerPoint)
    }

    static func clampedDownwardTilt(_ downwardTiltInDegrees: Double) -> Double {
        min(largestDownwardTiltInDegrees, max(smallestDownwardTiltInDegrees, downwardTiltInDegrees))
    }

    static func clampedCameraDistanceFactor(_ cameraDistanceFactor: Double) -> Double {
        min(largestCameraDistanceFactor, max(smallestCameraDistanceFactor, cameraDistanceFactor))
    }

    /// A scroll with a positive y comes closer.
    static func cameraDistanceFactor(afterScrollPoints scrollPoints: Double, from cameraDistanceFactor: Double) -> Double {
        clampedCameraDistanceFactor(cameraDistanceFactor * (1 - scrollPoints * scrollZoomSharePerPoint))
    }

    /// Spreading two fingers (a positive magnification) comes closer.
    static func cameraDistanceFactor(afterMagnification magnification: Double, from cameraDistanceFactor: Double) -> Double {
        clampedCameraDistanceFactor(cameraDistanceFactor * (1 - magnification))
    }

    static func cameraDistanceFactor(afterZooming zoomDirection: EzraSceneZoomDirection, from cameraDistanceFactor: Double) -> Double {
        switch zoomDirection {
        case .zoomIn: return clampedCameraDistanceFactor(cameraDistanceFactor * voiceZoomInFactor)
        case .zoomOut: return clampedCameraDistanceFactor(cameraDistanceFactor * voiceZoomOutFactor)
        }
    }

    /// Where a voice turn takes the model from the angle it is at: a quarter turn left (bringing its
    /// left side round to the front) or right, or the nearest way round to its front (a whole number of
    /// turns) or its back (half a turn more).
    static func turnAngleInRadians(afterTurning turnDirection: EzraSceneTurnDirection, from currentTurnAngleInRadians: Double) -> Double {
        let wholeTurnInRadians = 2 * Double.pi
        switch turnDirection {
        case .left:
            return currentTurnAngleInRadians + Double.pi / 2
        case .right:
            return currentTurnAngleInRadians - Double.pi / 2
        case .front:
            return (currentTurnAngleInRadians / wholeTurnInRadians).rounded() * wholeTurnInRadians
        case .back:
            return ((currentTurnAngleInRadians - Double.pi) / wholeTurnInRadians).rounded() * wholeTurnInRadians + Double.pi
        }
    }
}

nonisolated extension EzraSceneCamera {
    /// Round 22: where the camera stands for a downward tilt and a distance factor. A tilt of 20 and a
    /// factor of 1 give exactly `cameraPositionRelativeToModelCentre(for:)`. It always looks at the
    /// middle of the model.
    static func cameraPositionRelativeToModelCentre(
        for cameraFit: EzraSceneCameraFit,
        downwardTiltInDegrees: Double,
        cameraDistanceFactor: Double
    ) -> EzraSceneVector {
        let tiltInRadians = downwardTiltInDegrees * Double.pi / 180
        let cameraDistance = cameraFit.cameraDistance * cameraDistanceFactor
        return EzraSceneVector(
            x: 0,
            y: cameraDistance * sin(tiltInRadians),
            z: cameraDistance * cos(tiltInRadians)
        )
    }
}

/// Round 22: how long the user turned, tilted or zoomed a scene, for the metrics line. Interactions
/// closer together than half a second are one stretch, and the stretches are added up; a single click
/// counts nothing.
nonisolated struct EzraSceneInteractionClock: Equatable {
    static let longestPauseWithinOneStretchInSeconds: Double = 0.5

    private(set) var totalSeconds: Double = 0
    private var lastInteractionUptimeSeconds: Double?

    mutating func recordInteraction(atUptimeSeconds interactionUptimeSeconds: Double) {
        if let lastInteractionUptimeSeconds {
            let secondsSinceTheLastOne = interactionUptimeSeconds - lastInteractionUptimeSeconds
            if secondsSinceTheLastOne > 0 && secondsSinceTheLastOne <= Self.longestPauseWithinOneStretchInSeconds {
                totalSeconds += secondsSinceTheLastOne
            }
        }
        lastInteractionUptimeSeconds = interactionUptimeSeconds
    }

    /// The whole seconds, for the metrics line.
    var wholeSeconds: Int {
        Int(totalSeconds.rounded())
    }
}

// MARK: - The drawing self test's sample scene (round 22)

/// The 3D scene the drawing self test (`EZRA_DRAW_SELF_TEST=1`) builds, kept here as plain text so
/// the smoke program can check that every tag of it reads. It is test data only: nothing in normal use
/// reads it.
nonisolated enum EzraDrawingSelfTestSamples {
    /// Twenty-four parts (the limit), two of each of the twelve shapes in four rows of six: the first
    /// fifteen labelled, so both columns of tags show; every material at least once (the old glass
    /// colour and `mat=glass` side by side); a pyramid and a plane turned with `rot=`; a torus and a
    /// ring with their holes facing the camera.
    static let scenePartTagsText = [
        "[PART:box:box:-3.75,1.8,0:0.8,0.8,0.8:red:mat=metal]",
        "[PART:cylinder:cylinder:-2.25,1.8,0:0.4,0.9:orange:mat=plastic]",
        "[PART:sphere:sphere:-0.75,1.8,0:0.45:yellow:mat=rubber]",
        "[PART:cone:cone:0.75,1.8,0:0.45,0.9:green:mat=glass]",
        "[PART:tube:tube:2.25,1.8,0:0.45,0.8:teal:mat=glow]",
        "[PART:capsule:capsule:3.75,1.8,0:0.25,0.9:blue]",
        "[PART:torus:torus:-3.75,0.6,0:0.4,0.12:purple:z:mat=metal]",
        "[PART:ring:ring:-2.25,0.6,0:0.45:pink:z]",
        "[PART:pyramid:pyramid:-0.75,0.6,0:0.8,0.8,0.8:brown:rot=0,45,0:mat=plastic]",
        "[PART:plane:plane:0.75,0.6,0:0.8,0.6:gray:rot=-30,0,0:mat=glow]",
        "[PART:wedge:wedge:2.25,0.6,0:0.8,0.6,0.6:white:mat=rubber]",
        "[PART:hemisphere:hemisphere:3.75,0.6,0:0.45:glass]",
        "[PART:box:steel block:-3.75,-0.6,0:0.7,0.5,0.7:gray:mat=metal]",
        "[PART:cylinder:axle:-2.25,-0.6,0:0.12,1.1:black:x:mat=metal]",
        "[PART:sphere:knob:-0.75,-0.6,0:0.35:red:mat=plastic]",
        "[PART:cone::0.75,-0.6,0:0.4,0.8:orange:x]",
        "[PART:tube::2.25,-0.6,0:0.4,0.7:blue:z:mat=metal]",
        "[PART:capsule::3.75,-0.6,0:0.2,0.8:green:x:mat=rubber]",
        "[PART:torus::-3.75,-1.8,0:0.4,0.1:yellow:x:mat=glow]",
        "[PART:ring::-2.25,-1.8,0:0.4:gray:mat=metal]",
        "[PART:pyramid::-0.75,-1.8,0:0.7,0.7,0.7:teal]",
        "[PART:plane::0.75,-1.8,0:0.7,0.7:white]",
        "[PART:wedge::2.25,-1.8,0:0.7,0.5,0.5:purple:mat=plastic]",
        "[PART:hemisphere::3.75,-1.8,0:0.4:pink:mat=matte]",
    ].joined(separator: " ")
}

// MARK: - Where the panel goes on the screen

/// The corner of the screen a scene's panel sits in.
nonisolated enum EzraScenePanelCorner: Equatable {
    case lowerRight
    case lowerLeft
    case upperRight
    case upperLeft

    var isOnRightSideOfScreen: Bool {
        self == .lowerRight || self == .upperRight
    }

    var isOnLowerSideOfScreen: Bool {
        self == .lowerRight || self == .lowerLeft
    }
}

nonisolated struct EzraScenePanelPlacementResult: Equatable {
    /// In points from the display's top-left corner.
    let panelFrame: CGRect
    let corner: EzraScenePanelCorner
}

/// The app places the scene: the model only says what to build. The panel goes in a corner of the
/// screen, the lower right one by default, and moves to another corner when that one is taken by
/// the explanation card or by what this reply marks.
nonisolated enum EzraScenePanelPlacement {
    /// The panel is kept this far inside every screen edge and below the menu bar, like the card.
    static let screenEdgeMarginInPoints: Double = 16

    /// The lower corners first: they are furthest from the menu bar, the status pill and the
    /// tool bars most apps keep at the top.
    static let cornersInOrderOfPreference: [EzraScenePanelCorner] = [.lowerRight, .lowerLeft, .upperRight, .upperLeft]

    /// The air kept around the status pill.
    static let statusPillClearanceInPoints: Double = 8

    /// A label or sticky note has no size in its tag. These are about the size they are drawn at,
    /// close enough to keep the panel off them.
    static let assumedLabelSize = CGSize(width: 180, height: 30)
    static let assumedStickyNoteSize = CGSize(width: 210, height: 110)
    /// A callout's tag sits about this far from the place it points at, on any side.
    static let assumedCalloutReachInPoints: Double = 60
    /// A stroke is a few points wide and wobbles a little around its ideal line.
    static let strokeAllowanceInPoints: Double = 8

    /// The strip at the top middle of the display where the status pill can be: from the top
    /// edge (the pill hangs from the notch on a display that has one) down past a pill below the
    /// menu bar, as wide as the widest pill. A scene's panel never reaches into it.
    static func statusPillKeepClearFrame(
        displaySizeInPoints: CGSize,
        menuBarHeightInPoints: Double,
        statusPillMaximumWidthInPoints: Double,
        statusPillHeightInPoints: Double,
        statusPillGapBelowMenuBarInPoints: Double
    ) -> CGRect {
        let keepClearWidth = min(Double(displaySizeInPoints.width), statusPillMaximumWidthInPoints + 2 * statusPillClearanceInPoints)
        let keepClearHeight = max(0, menuBarHeightInPoints) + statusPillGapBelowMenuBarInPoints + statusPillHeightInPoints + statusPillClearanceInPoints
        return CGRect(
            x: (Double(displaySizeInPoints.width) - keepClearWidth) / 2,
            y: 0,
            width: keepClearWidth,
            height: keepClearHeight
        )
    }

    /// The panel's frame when it sits in a corner: inside the margins and below the menu bar.
    /// On a display too small for the panel its top-left corner wins, so the title stays readable.
    static func panelFrame(
        forPanelSize panelSize: CGSize,
        corner: EzraScenePanelCorner,
        displaySizeInPoints: CGSize,
        menuBarHeightInPoints: Double
    ) -> CGRect {
        let smallestAllowedX = screenEdgeMarginInPoints
        let smallestAllowedY = max(0, menuBarHeightInPoints) + screenEdgeMarginInPoints
        let largestAllowedX = Double(displaySizeInPoints.width) - Double(panelSize.width) - screenEdgeMarginInPoints
        let largestAllowedY = Double(displaySizeInPoints.height) - Double(panelSize.height) - screenEdgeMarginInPoints
        return CGRect(
            x: corner.isOnRightSideOfScreen ? max(smallestAllowedX, largestAllowedX) : smallestAllowedX,
            y: corner.isOnLowerSideOfScreen ? max(smallestAllowedY, largestAllowedY) : smallestAllowedY,
            width: Double(panelSize.width),
            height: Double(panelSize.height)
        )
    }

    /// Picks the corner for a scene's panel.
    ///
    /// A corner where the panel would reach into the status pill's strip is never used. Of the
    /// others, the first in the order of preference that covers nothing in `occupiedFrames` (the
    /// explanation card, the marks of this reply) is taken; if every corner covers something, the
    /// one that covers the least. On a display so small that every corner reaches the pill's
    /// strip, the panel goes in the lower right corner and starts below the strip.
    static func placement(
        forPanelSize panelSize: CGSize,
        displaySizeInPoints: CGSize,
        menuBarHeightInPoints: Double,
        statusPillKeepClearFrame: CGRect,
        occupiedFrames: [CGRect]
    ) -> EzraScenePanelPlacementResult {
        var bestPlacement: EzraScenePanelPlacementResult?
        var smallestCoveredArea = Double.infinity

        for corner in cornersInOrderOfPreference {
            let candidateFrame = panelFrame(
                forPanelSize: panelSize,
                corner: corner,
                displaySizeInPoints: displaySizeInPoints,
                menuBarHeightInPoints: menuBarHeightInPoints
            )
            guard !candidateFrame.intersects(statusPillKeepClearFrame) else {
                continue
            }
            var coveredArea = 0.0
            for occupiedFrame in occupiedFrames {
                let coveredFrame = candidateFrame.intersection(occupiedFrame)
                if !coveredFrame.isNull {
                    coveredArea += Double(coveredFrame.width) * Double(coveredFrame.height)
                }
            }
            // Strictly smaller, so of two equally free corners the preferred one stays.
            if coveredArea < smallestCoveredArea {
                smallestCoveredArea = coveredArea
                bestPlacement = EzraScenePanelPlacementResult(panelFrame: candidateFrame, corner: corner)
            }
        }

        if let bestPlacement {
            return bestPlacement
        }

        let lowerRightFrame = panelFrame(
            forPanelSize: panelSize,
            corner: .lowerRight,
            displaySizeInPoints: displaySizeInPoints,
            menuBarHeightInPoints: menuBarHeightInPoints
        )
        return EzraScenePanelPlacementResult(
            panelFrame: CGRect(
                x: lowerRightFrame.minX,
                y: max(lowerRightFrame.minY, statusPillKeepClearFrame.maxY),
                width: lowerRightFrame.width,
                height: lowerRightFrame.height
            ),
            corner: .lowerRight
        )
    }

    /// About where a mark is on the display (points from the top-left corner), so the panel can
    /// keep off it. nil for the card and a scene, whose frames the app knows exactly, and for a
    /// spotlight (round 21): its shade covers the whole screen, so counting it would leave the panel
    /// no free corner at all.
    static func occupiedFrame(ofShapeInDisplayPoints shape: EzraDrawingShape) -> CGRect? {
        switch shape {
        case .arrow(let firstEnd, let secondEnd), .underline(let firstEnd, let secondEnd):
            return CGRect(
                x: min(firstEnd.x, secondEnd.x),
                y: min(firstEnd.y, secondEnd.y),
                width: abs(firstEnd.x - secondEnd.x),
                height: abs(firstEnd.y - secondEnd.y)
            ).insetBy(dx: -strokeAllowanceInPoints, dy: -strokeAllowanceInPoints)
        case .circle(let center, let radius):
            return CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
                .insetBy(dx: -strokeAllowanceInPoints, dy: -strokeAllowanceInPoints)
        case .box(let topLeftCorner, let size), .highlight(let topLeftCorner, let size):
            return CGRect(x: topLeftCorner.x, y: topLeftCorner.y, width: size.width, height: size.height)
                .insetBy(dx: -strokeAllowanceInPoints, dy: -strokeAllowanceInPoints)
        case .label(let topLeftCorner, _):
            return CGRect(origin: CGPoint(x: topLeftCorner.x, y: topLeftCorner.y), size: assumedLabelSize)
        case .stickyNote(let topLeftCorner, _):
            return CGRect(origin: CGPoint(x: topLeftCorner.x, y: topLeftCorner.y), size: assumedStickyNoteSize)
        case .callout(let target, _, _):
            return CGRect(
                x: target.x - assumedCalloutReachInPoints,
                y: target.y - assumedCalloutReachInPoints,
                width: 2 * assumedCalloutReachInPoints,
                height: 2 * assumedCalloutReachInPoints
            )
        case .explanationCard, .scene, .spotlight:
            return nil
        }
    }
}
