import Foundation
import CoreGraphics

// The pure half of Clicky's simple 3D scenes: the validated parts a scene is built from, their
// limits and palette, the bounds and camera-fit maths, where a part lands in the picture as the
// model turns, and where the scene's panel and its numbered tags go on the screen.
//
// A scene is a schematic model made of a few basic shapes, not a photoreal one. It is built only
// from the values below: there is no script, no file loading and no network anywhere in it.
// Everything here is Foundation and CoreGraphics only, so it can be tested without SceneKit.

// MARK: - The parts of a scene

/// The basic shapes a part can be. The raw value is the word used in a `[PART:...]` tag.
nonisolated enum ClickyScenePartShapeKind: String, CaseIterable, Equatable {
    case box
    case cylinder
    case sphere
    case cone
    /// A hollow cylinder.
    case tube
    case capsule

    /// A box and a sphere have no direction to point along, so an axis means nothing for them.
    var pointsAlongAnAxis: Bool {
        switch self {
        case .box, .sphere:
            return false
        case .cylinder, .cone, .tube, .capsule:
            return true
        }
    }
}

/// The direction a cylinder, cone, tube or capsule points along. A cone's tip is at the positive
/// end of its axis.
nonisolated enum ClickyScenePartAxis: String, CaseIterable, Equatable {
    case x
    case y
    case z
}

/// One colour as plain numbers (sRGB, each from 0 to 1), so the palette can live here without AppKit.
nonisolated struct ClickySceneColourComponents: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    /// 1 for a solid part. Less than 1 only for `glass`.
    let opacity: Double
}

/// The fixed palette a part's colour is picked from. The raw value is the word used in the tag.
/// The colours are a little muted so a model reads as a matte sketch on the cream paper it sits on.
nonisolated enum ClickyScenePartColour: String, CaseIterable, Equatable {
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
    static func colour(named colourName: String) -> ClickyScenePartColour? {
        let lowercasedColourName = colourName.lowercased()
        if lowercasedColourName == "grey" {
            return .gray
        }
        return ClickyScenePartColour(rawValue: lowercasedColourName)
    }

    var isTranslucent: Bool {
        self == .glass
    }

    var components: ClickySceneColourComponents {
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
            return ClickySceneColourComponents(red: 0xBF / 255.0, green: 0xE3 / 255.0, blue: 0xF2 / 255.0, opacity: Self.glassOpacity)
        }
    }

    private static func solidColour(redByte: Int, greenByte: Int, blueByte: Int) -> ClickySceneColourComponents {
        ClickySceneColourComponents(
            red: Double(redByte) / 255.0,
            green: Double(greenByte) / 255.0,
            blue: Double(blueByte) / 255.0,
            opacity: 1
        )
    }
}

/// A position or a size in scene units. x runs to the right, y up, z towards the viewer.
nonisolated struct ClickySceneVector: Equatable {
    let x: Double
    let y: Double
    let z: Double

    static let zero = ClickySceneVector(x: 0, y: 0, z: 0)
}

/// How large a part is. Which case a part has follows from its shape.
nonisolated enum ClickyScenePartDimensions: Equatable {
    /// A box: width along x, height along y, depth along z.
    case box(width: Double, height: Double, depth: Double)
    /// A cylinder, cone, tube or capsule: its radius and its length along its axis.
    case radiusAndLength(radius: Double, length: Double)
    case sphere(radius: Double)
}

/// One validated part of a scene. Every value is inside the limits of `ClickyScene`.
nonisolated struct ClickyScenePart: Equatable {
    let shapeKind: ClickyScenePartShapeKind
    /// The part's name, shown on a numbered tag beside the model. nil for an unlabelled part.
    let labelText: String?
    let centre: ClickySceneVector
    let dimensions: ClickyScenePartDimensions
    let colour: ClickyScenePartColour
    /// Always `.y` for a box and a sphere, where it means nothing.
    let axis: ClickyScenePartAxis

    /// The inside of a tube is this share of its radius, so its wall is clearly a wall and its
    /// hole clearly a hole at the size a scene is shown.
    static let tubeInnerRadiusShareOfOuterRadius: Double = 0.7

    /// The length a part really has along its axis. A capsule cannot be shorter than its two
    /// round ends, so a shorter one is as long as they are (it is then a ball).
    var lengthAlongAxis: Double {
        switch dimensions {
        case .radiusAndLength(let radius, let length):
            return shapeKind == .capsule ? max(length, 2 * radius) : length
        case .box, .sphere:
            return 0
        }
    }

    /// Half of the part's size along x, y and z: how far it reaches from its centre.
    var halfExtents: ClickySceneVector {
        switch dimensions {
        case .box(let width, let height, let depth):
            return ClickySceneVector(x: width / 2, y: height / 2, z: depth / 2)
        case .sphere(let radius):
            return ClickySceneVector(x: radius, y: radius, z: radius)
        case .radiusAndLength(let radius, _):
            let halfLength = lengthAlongAxis / 2
            switch axis {
            case .x: return ClickySceneVector(x: halfLength, y: radius, z: radius)
            case .y: return ClickySceneVector(x: radius, y: halfLength, z: radius)
            case .z: return ClickySceneVector(x: radius, y: radius, z: halfLength)
            }
        }
    }

    /// Everything after "PART:" the way the grammar writes it, such as
    /// "cylinder:fan:0,0,2:1.2,0.3:blue:x". The axis is left out when it is the default (up) or
    /// means nothing for the shape. Used for the conversation history and the "marks on screen" list.
    var canonicalTagBody: String {
        let numberText = ClickyScene.numberText
        let sizeText: String
        switch dimensions {
        case .box(let width, let height, let depth):
            sizeText = "\(numberText(width)),\(numberText(height)),\(numberText(depth))"
        case .radiusAndLength(let radius, let length):
            sizeText = "\(numberText(radius)),\(numberText(length))"
        case .sphere(let radius):
            sizeText = numberText(radius)
        }
        let positionText = "\(numberText(centre.x)),\(numberText(centre.y)),\(numberText(centre.z))"
        let axisSuffix = (shapeKind.pointsAlongAnAxis && axis != .y) ? ":\(axis.rawValue)" : ""
        return "\(shapeKind.rawValue):\(labelText ?? ""):\(positionText):\(sizeText):\(colour.rawValue)\(axisSuffix)"
    }
}

/// A simple 3D model: a title and the parts added so far, in the order they were written.
nonisolated struct ClickyScene: Equatable {
    /// The title is one short line above the model. Longer text is cut, like a card's title.
    static let maximumTitleCharacterCount = 40

    /// A part's name sits on a small tag beside the model. Longer text is cut.
    static let maximumPartLabelCharacterCount = 24

    /// Twelve basic shapes are enough for a schematic model, keep the scene light to draw, and
    /// are as many tags as fit beside the model.
    static let maximumPartCount = 12

    /// A part's centre is at most this far from the middle of the scene on each axis. The app
    /// scales the whole model to its panel, so the numbers only matter relative to each other.
    static let maximumCentreCoordinate: Double = 5

    /// A part thinner than this is invisible at the size a scene is shown, and one larger than
    /// this is bigger than the whole space parts can be placed in.
    static let minimumPartSize: Double = 0.05
    static let maximumPartSize: Double = 6

    let title: String
    let parts: [ClickyScenePart]

    func addingPart(_ part: ClickyScenePart) -> ClickyScene {
        ClickyScene(title: title, parts: parts + [part])
    }

    func keepingFirstParts(_ partCountToKeep: Int) -> ClickyScene {
        ClickyScene(title: title, parts: Array(parts.prefix(max(0, partCountToKeep))))
    }

    var hasLabelledParts: Bool {
        parts.contains { $0.labelText != nil }
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
nonisolated struct ClickySceneBounds: Equatable {
    let minimum: ClickySceneVector
    let maximum: ClickySceneVector

    var centre: ClickySceneVector {
        ClickySceneVector(
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
nonisolated struct ClickySceneCameraFit: Equatable {
    /// The middle of the model. The model turns around the vertical line through this point and
    /// the camera looks at it.
    let modelCentre: ClickySceneVector
    /// The radius of the ball around `modelCentre` that holds every part.
    let boundingSphereRadius: Double
    /// How far the camera is from `modelCentre`.
    let cameraDistance: Double
}

nonisolated enum ClickySceneCamera {
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

    static func bounds(of parts: [ClickyScenePart]) -> ClickySceneBounds? {
        guard let firstPart = parts.first else {
            return nil
        }
        var minimumX = firstPart.centre.x - firstPart.halfExtents.x
        var minimumY = firstPart.centre.y - firstPart.halfExtents.y
        var minimumZ = firstPart.centre.z - firstPart.halfExtents.z
        var maximumX = firstPart.centre.x + firstPart.halfExtents.x
        var maximumY = firstPart.centre.y + firstPart.halfExtents.y
        var maximumZ = firstPart.centre.z + firstPart.halfExtents.z
        for part in parts.dropFirst() {
            minimumX = min(minimumX, part.centre.x - part.halfExtents.x)
            minimumY = min(minimumY, part.centre.y - part.halfExtents.y)
            minimumZ = min(minimumZ, part.centre.z - part.halfExtents.z)
            maximumX = max(maximumX, part.centre.x + part.halfExtents.x)
            maximumY = max(maximumY, part.centre.y + part.halfExtents.y)
            maximumZ = max(maximumZ, part.centre.z + part.halfExtents.z)
        }
        return ClickySceneBounds(
            minimum: ClickySceneVector(x: minimumX, y: minimumY, z: minimumZ),
            maximum: ClickySceneVector(x: maximumX, y: maximumY, z: maximumZ)
        )
    }

    /// The camera fit for a set of parts.
    ///
    /// The model turns, so the fit must hold at every angle. A ball around the middle of the
    /// bounds holds the model however it is turned, and a ball of radius r seen from distance d
    /// fills an angle of 2 x asin(r / d). The camera therefore stands at r / sin(half the field of
    /// view), a little further for the margin.
    static func cameraFit(for parts: [ClickyScenePart]) -> ClickySceneCameraFit {
        let modelCentre: ClickySceneVector
        let boundingSphereRadius: Double
        if let bounds = bounds(of: parts) {
            modelCentre = bounds.centre
            boundingSphereRadius = max(smallestBoundingSphereRadius, bounds.halfDiagonalLength)
        } else {
            modelCentre = .zero
            boundingSphereRadius = boundingSphereRadiusOfEmptyScene
        }
        let halfFieldOfViewInRadians = verticalFieldOfViewInDegrees / 2 * Double.pi / 180
        return ClickySceneCameraFit(
            modelCentre: modelCentre,
            boundingSphereRadius: boundingSphereRadius,
            cameraDistance: boundingSphereRadius / sin(halfFieldOfViewInRadians) * fitMarginFactor
        )
    }

    /// Where the camera stands, measured from the middle of the model: back along z and raised
    /// by the tilt, looking at the middle.
    static func cameraPositionRelativeToModelCentre(for cameraFit: ClickySceneCameraFit) -> ClickySceneVector {
        let tiltInRadians = downwardTiltInDegrees * Double.pi / 180
        return ClickySceneVector(
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
    /// This is the same perspective the renderer uses (the smoke program checks the two against
    /// each other), done here in plain numbers so the leader lines of the tags can follow the
    /// model without asking the renderer.
    static func pointInModelView(
        forModelPoint modelPoint: ClickySceneVector,
        cameraFit: ClickySceneCameraFit,
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

// MARK: - The panel: paper, title, the model's picture and the tags

/// Where everything on a scene's panel goes, in points from the panel's top-left corner.
nonisolated struct ClickyScenePanelLayout: Equatable {
    let panelSize: CGSize
    let titleFrame: CGRect
    /// The square the model is drawn in.
    let modelViewFrame: CGRect
    /// The column of numbered tags beside the model. nil while no part has a label.
    let labelColumnFrame: CGRect?
    /// True when the tags are on the left of the model (the panel then sits on the right of the
    /// screen, so the tags are on the side facing the middle of the screen).
    let labelColumnIsOnLeftOfModel: Bool
}

nonisolated enum ClickyScenePanelLayoutCalculator {
    /// The paper's edge to its content.
    static let paperPaddingInPoints: Double = 10
    static let titleRowHeightInPoints: Double = 26
    /// The square the model is drawn in: "about 300 points" with the padding around it.
    static let modelViewSideInPoints: Double = 280
    static let gapBetweenModelAndLabelColumnInPoints: Double = 4
    /// Wide enough for a typical part name in the handwriting typeface; a longer one ends in an ellipsis.
    static let labelColumnWidthInPoints: Double = 150
    static let labelTagHeightInPoints: Double = 20
    /// From the top of one tag to the top of the next. Twelve tags (the most a scene can have)
    /// are 276 points, which fits beside the 280 point model.
    static let labelTagPitchInPoints: Double = 23
    /// The numbered disc at the model's end of a tag. The leader line starts at its edge.
    static let labelDiscDiameterInPoints: Double = 16
    static let gapBetweenLabelDiscAndTextInPoints: Double = 5

    static func layout(hasLabelColumn: Bool, labelColumnIsOnLeftOfModel: Bool) -> ClickyScenePanelLayout {
        let labelColumnAndGapWidth = hasLabelColumn ? labelColumnWidthInPoints + gapBetweenModelAndLabelColumnInPoints : 0
        let panelWidth = 2 * paperPaddingInPoints + modelViewSideInPoints + labelColumnAndGapWidth
        let panelHeight = 2 * paperPaddingInPoints + titleRowHeightInPoints + modelViewSideInPoints
        let contentTopY = paperPaddingInPoints + titleRowHeightInPoints

        let modelViewOriginX = paperPaddingInPoints + ((hasLabelColumn && labelColumnIsOnLeftOfModel) ? labelColumnAndGapWidth : 0)
        let modelViewFrame = CGRect(x: modelViewOriginX, y: contentTopY, width: modelViewSideInPoints, height: modelViewSideInPoints)

        var labelColumnFrame: CGRect?
        if hasLabelColumn {
            let labelColumnOriginX = labelColumnIsOnLeftOfModel
                ? paperPaddingInPoints
                : modelViewOriginX + modelViewSideInPoints + gapBetweenModelAndLabelColumnInPoints
            labelColumnFrame = CGRect(x: labelColumnOriginX, y: contentTopY, width: labelColumnWidthInPoints, height: modelViewSideInPoints)
        }

        return ClickyScenePanelLayout(
            panelSize: CGSize(width: panelWidth, height: panelHeight),
            titleFrame: CGRect(x: paperPaddingInPoints, y: paperPaddingInPoints, width: panelWidth - 2 * paperPaddingInPoints, height: titleRowHeightInPoints),
            modelViewFrame: modelViewFrame,
            labelColumnFrame: labelColumnFrame,
            labelColumnIsOnLeftOfModel: labelColumnIsOnLeftOfModel
        )
    }

    /// The place of the tag with this number (1 for the first labelled part). The tags stand in
    /// one column from the top, in the order their parts were added, and never move once placed:
    /// only the far end of a tag's leader line follows the turning model. nil when the panel has
    /// no column or the number is not one a scene can have.
    static func labelTagFrame(forLabelNumber labelNumber: Int, in panelLayout: ClickyScenePanelLayout) -> CGRect? {
        guard let labelColumnFrame = panelLayout.labelColumnFrame,
              labelNumber >= 1, labelNumber <= ClickyScene.maximumPartCount else {
            return nil
        }
        return CGRect(
            x: Double(labelColumnFrame.minX),
            y: Double(labelColumnFrame.minY) + Double(labelNumber - 1) * labelTagPitchInPoints,
            width: Double(labelColumnFrame.width),
            height: labelTagHeightInPoints
        )
    }

    /// The numbered disc of a tag: at the end of the tag that faces the model.
    static func labelDiscFrame(forLabelTagFrame labelTagFrame: CGRect, in panelLayout: ClickyScenePanelLayout) -> CGRect {
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
    static func labelTextFrame(forLabelTagFrame labelTagFrame: CGRect, in panelLayout: ClickyScenePanelLayout) -> CGRect {
        let textWidth = Double(labelTagFrame.width) - labelDiscDiameterInPoints - gapBetweenLabelDiscAndTextInPoints
        let textOriginX = panelLayout.labelColumnIsOnLeftOfModel
            ? Double(labelTagFrame.minX)
            : Double(labelTagFrame.minX) + labelDiscDiameterInPoints + gapBetweenLabelDiscAndTextInPoints
        return CGRect(x: textOriginX, y: Double(labelTagFrame.minY), width: textWidth, height: Double(labelTagFrame.height))
    }

    /// Where a tag's leader line starts: the point of its disc nearest the model.
    static func leaderStartPoint(forLabelTagFrame labelTagFrame: CGRect, in panelLayout: ClickyScenePanelLayout) -> CGPoint {
        let discFrame = labelDiscFrame(forLabelTagFrame: labelTagFrame, in: panelLayout)
        return CGPoint(
            x: panelLayout.labelColumnIsOnLeftOfModel ? discFrame.maxX : discFrame.minX,
            y: discFrame.midY
        )
    }

    /// Where a tag's leader line ends: the place of its part in the model's picture, as a point
    /// of the panel.
    static func leaderEndPoint(
        forPartCentre partCentre: ClickySceneVector,
        cameraFit: ClickySceneCameraFit,
        turnAngleInRadians: Double,
        in panelLayout: ClickyScenePanelLayout
    ) -> CGPoint {
        let pointInModelView = ClickySceneCamera.pointInModelView(
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

// MARK: - Where the panel goes on the screen

/// The corner of the screen a scene's panel sits in.
nonisolated enum ClickyScenePanelCorner: Equatable {
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

nonisolated struct ClickyScenePanelPlacementResult: Equatable {
    /// In points from the display's top-left corner.
    let panelFrame: CGRect
    let corner: ClickyScenePanelCorner
}

/// The app places the scene: the model only says what to build. The panel goes in a corner of the
/// screen, the lower right one by default, and moves to another corner when that one is taken by
/// the explanation card or by what this reply marks.
nonisolated enum ClickyScenePanelPlacement {
    /// The panel is kept this far inside every screen edge and below the menu bar, like the card.
    static let screenEdgeMarginInPoints: Double = 16

    /// The lower corners first: they are furthest from the menu bar, the status pill and the
    /// tool bars most apps keep at the top.
    static let cornersInOrderOfPreference: [ClickyScenePanelCorner] = [.lowerRight, .lowerLeft, .upperRight, .upperLeft]

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
        corner: ClickyScenePanelCorner,
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
    ) -> ClickyScenePanelPlacementResult {
        var bestPlacement: ClickyScenePanelPlacementResult?
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
                bestPlacement = ClickyScenePanelPlacementResult(panelFrame: candidateFrame, corner: corner)
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
        return ClickyScenePanelPlacementResult(
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
    /// keep off it. nil for the card and a scene, whose frames the app knows exactly.
    static func occupiedFrame(ofShapeInDisplayPoints shape: ClickyDrawingShape) -> CGRect? {
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
        case .explanationCard, .scene:
            return nil
        }
    }
}
