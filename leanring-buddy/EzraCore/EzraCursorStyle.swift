import CoreGraphics
import Foundation

// The look of Ezra's cursor (round 20, the cursor studio): its colour, shape, size and glow, and
// the outline of each shape. Pure, so the numbers the overlay draws with can be checked without the
// app. `EzraCursorStyle.default` is today's cursor exactly (the blue triangle, 16 points, a soft
// glow), so a user who never opens the LOOK section sees nothing change.
//
// What follows the colour: the cursor, the waveform and spinner while asking, the speech bubbles
// next to the cursor, and the status pill's listening and asking accent. What does not: the
// dictation green, the drawing ink and the chat panel (Sam's decision 6 of 14 Nov 2026).
//
// Nothing here ever reaches the model or a log: the style lives in `UserDefaults` only.

// MARK: - Shapes

/// The five shapes the cursor can take. Every pointed shape is drawn with its tip pointing up at
/// 0°, so the overlay's flight rotation (the bezier tangent plus 90°) works for all of them unchanged.
nonisolated enum EzraCursorShape: String, CaseIterable, Codable, Equatable, Sendable {
    case triangle
    case arrow
    case chevron
    case dot
    case ring

    /// The word on the choice in the LOOK section.
    var title: String {
        rawValue
    }

    /// True for the shapes with a tip: they turn toward where Ezra flies and rest tilted like a
    /// mouse pointer. A dot or a ring looks the same at every angle, so it is never turned.
    var pointsTowardFlight: Bool {
        switch self {
        case .triangle, .arrow, .chevron:
            return true
        case .dot, .ring:
            return false
        }
    }

    /// The tilt a pointed shape rests at: today's triangle rests at -35°, like a mouse pointer.
    static let pointedShapeRestAngleDegrees: Double = -35

    /// The angle the shape rests at: -35° for the pointed shapes, 0° for the round ones.
    var restAngleDegrees: Double {
        pointsTowardFlight ? Self.pointedShapeRestAngleDegrees : 0
    }

    /// The angle the overlay turns the shape to. The overlay keeps one pointer angle (the rest angle
    /// of a pointed shape, or the flight tangent while flying); a pointed shape follows it, a round
    /// shape always shows its own rest angle. Keeping that one angle for every shape means a switch
    /// from the ring back to the triangle shows the triangle at -35° straight away.
    func displayedRotationDegrees(pointerRotationDegrees: Double) -> Double {
        pointsTowardFlight ? pointerRotationDegrees : restAngleDegrees
    }

    /// The ring and the chevron are lines (stroked); the triangle, the arrow and the dot are filled.
    var isStroked: Bool {
        switch self {
        case .ring, .chevron:
            return true
        case .triangle, .arrow, .dot:
            return false
        }
    }

    /// The width of a stroked shape's line, as a share of the frame's side. 0 for a filled shape.
    var strokeWidthShare: Double {
        switch self {
        case .ring:
            return 0.16
        case .chevron:
            return 0.22
        case .triangle, .arrow, .dot:
            return 0
        }
    }
}

// MARK: - Sizes

/// Three sizes. The waveform and the spinner are scaled by the same factor, so their own numbers
/// (bar widths, the spinner's 14 points) stay as they are.
nonisolated enum EzraCursorSize: String, CaseIterable, Codable, Equatable, Sendable {
    case small
    case medium
    case large

    var title: String {
        rawValue
    }

    /// The factor applied to today's 16-point cursor (and to the waveform and spinner).
    var scale: Double {
        switch self {
        case .small:
            return 0.75
        case .medium:
            return 1
        case .large:
            return 1.4
        }
    }

    /// Today's cursor frame: 16 points square.
    static let mediumFrameSideInPoints: Double = 16

    /// The side of the cursor's square frame: 12, 16 or 22.4 points.
    var frameSideInPoints: Double {
        Self.mediumFrameSideInPoints * scale
    }
}

// MARK: - Glow

/// How much the cursor glows. `soft` is today's glow. The speech bubbles keep their own shadow
/// (0.5 opacity, radius 6) at every level: they follow the colour, not the glow.
nonisolated enum EzraCursorGlow: String, CaseIterable, Codable, Equatable, Sendable {
    case off
    case soft
    case strong

    var title: String {
        rawValue
    }

    /// The glow's radius while the cursor rests.
    var cursorGlowRadiusAtRest: Double {
        switch self {
        case .off:
            return 0
        case .soft:
            return 8
        case .strong:
            return 14
        }
    }

    /// How much the glow grows per unit of flight scale (the cursor swells to 1.3 mid-flight).
    var cursorGlowRadiusGainPerFlightScale: Double {
        switch self {
        case .off:
            return 0
        case .soft:
            return 20
        case .strong:
            return 30
        }
    }

    /// The glow's opacity: the colour at full strength for soft and strong, nothing for off.
    var cursorGlowOpacity: Double {
        switch self {
        case .off:
            return 0
        case .soft, .strong:
            return 1
        }
    }

    /// The glow's radius at a flight scale. Written in the same order as today's overlay code
    /// (`8 + (buddyFlightScale - 1.0) * 20`), so the default gives the very same numbers.
    func cursorGlowRadius(atFlightScale flightScale: Double) -> Double {
        cursorGlowRadiusAtRest + (flightScale - 1) * cursorGlowRadiusGainPerFlightScale
    }

    /// A strong glow has a second, wider and fainter halo around the first.
    var hasWideSecondGlow: Bool {
        self == .strong
    }

    /// The second halo's opacity: 0.35 for strong, nothing otherwise (the overlay then draws a clear
    /// shadow of radius 0, which shows nothing).
    var wideSecondGlowOpacity: Double {
        hasWideSecondGlow ? 0.35 : 0
    }

    /// The second halo is twice as wide as the first.
    func wideSecondGlowRadius(atFlightScale flightScale: Double) -> Double {
        hasWideSecondGlow ? 2 * cursorGlowRadius(atFlightScale: flightScale) : 0
    }

    /// The glow of the waveform (while listening) and the spinner (while thinking). Today's is 6.
    var feedbackGlowRadius: Double {
        switch self {
        case .off:
            return 0
        case .soft:
            return 6
        case .strong:
            return 10
        }
    }

    /// The waveform's and spinner's glow opacity. Today's is 0.6.
    var feedbackGlowOpacity: Double {
        switch self {
        case .off:
            return 0
        case .soft:
            return 0.6
        case .strong:
            return 0.8
        }
    }
}

// MARK: - Colour

/// One colour of the LOOK section's palette.
nonisolated struct EzraCursorPaletteEntry: Equatable, Sendable {
    let name: String
    let hex: String
}

/// The cursor's colour, always stored as "#RRGGBB" in upper case.
nonisolated enum EzraCursorColour {
    /// The dictation green and the drawing ink mean something else on the screen (dictating, a mark
    /// Ezra drew), so neither is offered in the palette. A hex typed by hand is still accepted.
    static let dictationGreenHex = "#2FCB9A"
    static let drawingInkHex = "#FF5A36"

    /// Ten colours, in the order the swatches are shown. The first is today's blue.
    static let palette: [EzraCursorPaletteEntry] = [
        EzraCursorPaletteEntry(name: "blue", hex: "#3380FF"),
        EzraCursorPaletteEntry(name: "sky", hex: "#35B8FF"),
        EzraCursorPaletteEntry(name: "teal", hex: "#1FB5C9"),
        EzraCursorPaletteEntry(name: "green", hex: "#3DCB5B"),
        EzraCursorPaletteEntry(name: "yellow", hex: "#FFC93C"),
        EzraCursorPaletteEntry(name: "orange", hex: "#FF9F1C"),
        EzraCursorPaletteEntry(name: "red", hex: "#FF4D5E"),
        EzraCursorPaletteEntry(name: "pink", hex: "#FF5FA8"),
        EzraCursorPaletteEntry(name: "purple", hex: "#9B6BFF"),
        EzraCursorPaletteEntry(name: "white", hex: "#F2F4F5"),
    ]

    /// Reads a colour typed by the user: "#RGB", "RGB", "#RRGGBB" or "RRGGBB", in any case, with
    /// spaces around it allowed. Returns "#RRGGBB" in upper case, or nil for anything else (an alpha
    /// channel, five digits, a word, "0x...", a digit that is not plain ASCII). The design system's
    /// `Color(hex:)` turns garbage into black, so user input always goes through here first.
    static func parse(_ text: String) -> String? {
        var hexDigits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexDigits.hasPrefix("#") {
            hexDigits.removeFirst()
        }
        guard hexDigits.count == 3 || hexDigits.count == 6 else {
            return nil
        }
        // `isHexDigit` alone also accepts the fullwidth forms of the digits, so ASCII is required too.
        guard hexDigits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return nil
        }
        let sixHexDigits: String
        if hexDigits.count == 3 {
            // "#abc" means "#aabbcc": every digit is doubled.
            sixHexDigits = hexDigits.map { "\($0)\($0)" }.joined()
        } else {
            sixHexDigits = hexDigits
        }
        return "#" + sixHexDigits.uppercased()
    }

    /// The red, green and blue of a colour, each from 0 to 1, for the app's sRGB colour. Computed the
    /// same way as the design system's `Color(hex:)`, so the default blue gives the very same
    /// numbers as `DS.Colors.overlayCursorBlue`. A hex that does not parse gives today's blue, never
    /// black.
    static func components(hex: String) -> (red: Double, green: Double, blue: Double) {
        let validHex = parse(hex) ?? EzraCursorStyle.defaultColourHex
        let rgbValue = UInt64(validHex.dropFirst(), radix: 16) ?? 0x3380FF
        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0
        return (red, green, blue)
    }

    /// The palette's name for a colour ("red"), or nil for a colour typed by hand.
    static func paletteName(forHex hex: String) -> String? {
        guard let validHex = parse(hex) else { return nil }
        return palette.first { $0.hex == validHex }?.name
    }
}

// MARK: - The style

/// The cursor's whole look, as stored in four `UserDefaults` keys.
nonisolated struct EzraCursorStyle: Codable, Equatable, Sendable {
    /// "#RRGGBB", upper case.
    var colourHex: String
    var shape: EzraCursorShape
    var size: EzraCursorSize
    var glow: EzraCursorGlow

    /// Today's blue (`DS.Colors.overlayCursorBlue`).
    static let defaultColourHex = "#3380FF"

    /// Today's cursor exactly: the blue triangle at 16 points with the soft glow.
    static let `default` = EzraCursorStyle(
        colourHex: defaultColourHex,
        shape: .triangle,
        size: .medium,
        glow: .soft
    )

    var isDefault: Bool {
        self == .default
    }

    /// The speech bubbles next to the cursor (welcome, onboarding, pointing, the dictation notice)
    /// keep today's shadow at every glow level; only their colour follows the style.
    static let bubbleShadowOpacity: Double = 0.5
    static let bubbleShadowRadius: Double = 6

    // MARK: The draw self test's style

    /// The variable that gives the draw self test a style, honoured only while `EZRA_DRAW_SELF_TEST=1`.
    static let drawSelfTestEnvironmentVariable = "EZRA_DRAW_SELF_TEST_CURSOR_STYLE"

    /// Reads a style like "#FF4D5E,ring,large,strong" for the draw self test. The parts are separated
    /// by commas and may come in any order; each is tried as a colour, a shape, a size and a glow
    /// word (in any case), the first of each kind is used, and anything unknown is ignored. A part
    /// that is missing keeps today's value, so garbage gives today's cursor. No word of the
    /// shapes, sizes or glows is also a valid hex, so a part can never be read two ways.
    static func parse(selfTestDescription: String) -> EzraCursorStyle {
        var parsedStyle = EzraCursorStyle.default
        var hasReadColour = false
        var hasReadShape = false
        var hasReadSize = false
        var hasReadGlow = false
        for rawPart in selfTestDescription.split(separator: ",", omittingEmptySubsequences: true) {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedPart = part.lowercased()
            if !hasReadColour, let colourHex = EzraCursorColour.parse(part) {
                parsedStyle.colourHex = colourHex
                hasReadColour = true
            } else if !hasReadShape, let shape = EzraCursorShape(rawValue: lowercasedPart) {
                parsedStyle.shape = shape
                hasReadShape = true
            } else if !hasReadSize, let size = EzraCursorSize(rawValue: lowercasedPart) {
                parsedStyle.size = size
                hasReadSize = true
            } else if !hasReadGlow, let glow = EzraCursorGlow(rawValue: lowercasedPart) {
                parsedStyle.glow = glow
                hasReadGlow = true
            }
        }
        return parsedStyle
    }

    /// Fixed words for the console ("shape ring, size large, glow strong, colour red"): the palette's
    /// name for the colour, or "custom" for a hex typed by hand, so no hex of the user's own is printed.
    var consoleWords: String {
        let colourWord = EzraCursorColour.paletteName(forHex: colourHex) ?? "custom"
        return "shape \(shape.rawValue), size \(size.rawValue), glow \(glow.rawValue), colour \(colourWord)"
    }
}

// MARK: - Outlines

/// One step of a shape's outline, in the order the app's `Path` takes them.
nonisolated enum EzraCursorPathPart: Equatable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    /// A circle or part of one. Degrees as SwiftUI's `Path.addArc` takes them (0° points right).
    case arc(center: CGPoint, radius: Double, startDegrees: Double, endDegrees: Double)
    case close
}

/// A shape's outline in a frame, and whether it is filled or drawn as a line.
nonisolated struct EzraCursorOutline: Equatable, Sendable {
    let parts: [EzraCursorPathPart]
    let isStroked: Bool
    /// The width of the line of a stroked shape, in points. 0 for a filled shape.
    let strokeWidth: Double

    /// The points the outline goes through, and for each circle the four points where it reaches
    /// furthest left, right, up and down. The checks use them to see that a shape stays in its frame.
    var extremePoints: [CGPoint] {
        parts.flatMap { part -> [CGPoint] in
            switch part {
            case .move(let point), .line(let point):
                return [point]
            case .arc(let center, let radius, _, _):
                return [
                    CGPoint(x: center.x - radius, y: center.y),
                    CGPoint(x: center.x + radius, y: center.y),
                    CGPoint(x: center.x, y: center.y - radius),
                    CGPoint(x: center.x, y: center.y + radius),
                ]
            case .close:
                return []
            }
        }
    }
}

/// The outline of each shape in a frame. Every shape is drawn in the square of side
/// `min(width, height)` centred in the frame (as today's triangle is), so a frame that is not square
/// never stretches a shape.
nonisolated enum EzraCursorShapeGeometry {
    /// How far today's triangle reaches above its frame, as a share of the square's side. The
    /// triangle is centred on its centroid, so its tip is two thirds of its height above the
    /// middle: (√3/2) × (2/3) − 1/2 ≈ 0.077 of the side, 1.24 points above a 16-point frame. Its
    /// points are kept to the digit (the default cursor must stay exactly today's), so the checks
    /// allow the triangle this one overhang at the top.
    static let triangleTipOverhangShareOfSide: Double = sqrt(3.0) / 3.0 - 0.5

    static func outline(for shape: EzraCursorShape, in rect: CGRect) -> EzraCursorOutline {
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        switch shape {
        case .triangle:
            return triangleOutline(in: rect)
        case .arrow:
            return arrowOutline(in: square)
        case .chevron:
            return chevronOutline(in: square, strokeWidth: side * shape.strokeWidthShare)
        case .dot:
            return circleOutline(in: square, diameterShareOfSide: 0.78, isStroked: false, strokeWidth: 0)
        case .ring:
            return circleOutline(in: square, diameterShareOfSide: 0.86, isStroked: true, strokeWidth: side * shape.strokeWidthShare)
        }
    }

    /// Today's equilateral triangle (`Triangle` in OverlayWindow.swift before round 20), with the very
    /// same arithmetic in the very same order, so every point is identical to the digit.
    private static func triangleOutline(in rect: CGRect) -> EzraCursorOutline {
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0
        let topVertex = CGPoint(x: rect.midX, y: rect.midY - height / 1.5)
        let bottomLeftVertex = CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3)
        let bottomRightVertex = CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3)
        return EzraCursorOutline(
            parts: [.move(topVertex), .line(bottomLeftVertex), .line(bottomRightVertex), .close],
            isStroked: false,
            strokeWidth: 0
        )
    }

    /// The classic arrow, pointing up: the tip at the top centre, two barbs at 0.42 of the height out
    /// to the full width, and a tail 0.3 of the width wide down to the bottom. Seven points, mirrored.
    private static func arrowOutline(in square: CGRect) -> EzraCursorOutline {
        let side = square.width
        let barbY = square.minY + 0.42 * side
        let tailHalfWidth = 0.15 * side
        let tip = CGPoint(x: square.midX, y: square.minY)
        let rightBarb = CGPoint(x: square.maxX, y: barbY)
        let rightTailTop = CGPoint(x: square.midX + tailHalfWidth, y: barbY)
        let rightTailBottom = CGPoint(x: square.midX + tailHalfWidth, y: square.maxY)
        let leftTailBottom = CGPoint(x: square.midX - tailHalfWidth, y: square.maxY)
        let leftTailTop = CGPoint(x: square.midX - tailHalfWidth, y: barbY)
        let leftBarb = CGPoint(x: square.minX, y: barbY)
        return EzraCursorOutline(
            parts: [
                .move(tip), .line(rightBarb), .line(rightTailTop), .line(rightTailBottom),
                .line(leftTailBottom), .line(leftTailTop), .line(leftBarb), .close,
            ],
            isStroked: false,
            strokeWidth: 0
        )
    }

    /// An open "V" upside down, pointing up: the point at the top centre and the two legs ending at
    /// the lower corners. It is a line with round caps and joins, so its points sit half a line's
    /// width inside the square: the drawn line then just reaches the corners and the top.
    private static func chevronOutline(in square: CGRect, strokeWidth: Double) -> EzraCursorOutline {
        let insetForRoundCaps = strokeWidth / 2
        let leftLegEnd = CGPoint(x: square.minX + insetForRoundCaps, y: square.maxY - insetForRoundCaps)
        let point = CGPoint(x: square.midX, y: square.minY + insetForRoundCaps)
        let rightLegEnd = CGPoint(x: square.maxX - insetForRoundCaps, y: square.maxY - insetForRoundCaps)
        return EzraCursorOutline(
            parts: [.move(leftLegEnd), .line(point), .line(rightLegEnd)],
            isStroked: true,
            strokeWidth: strokeWidth
        )
    }

    /// A circle of the given share of the square's side, centred: the dot (filled, 0.78) and the
    /// ring (a line, 0.86).
    private static func circleOutline(in square: CGRect, diameterShareOfSide: Double, isStroked: Bool, strokeWidth: Double) -> EzraCursorOutline {
        let radius = square.width * diameterShareOfSide / 2
        let center = CGPoint(x: square.midX, y: square.midY)
        return EzraCursorOutline(
            parts: [.arc(center: center, radius: radius, startDegrees: 0, endDegrees: 360), .close],
            isStroked: isStroked,
            strokeWidth: strokeWidth
        )
    }
}
