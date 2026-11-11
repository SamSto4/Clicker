#!/usr/bin/env swift
//
//  make_fixtures.swift
//
//  Generates the synthetic "screenshots" used by the Clicky evaluation harness, plus
//  fixtures/manifest.json with the ground-truth bounding box of every element a
//  pointing scenario can ask about.
//
//  The images mimic what CompanionScreenCaptureUtility sends to Claude: JPEG
//  (compression 0.8), 1280 pixels on the long side, origin at the top-left corner.
//
//  Run (from anywhere):   swift /Users/samsto/Clicker/eval/make_fixtures.swift
//  The fixtures are committed to the repo, so you normally never need to re-run this.
//  If you re-run it, element positions in manifest.json may change; scenarios refer to
//  elements by NAME, so they stay valid.
//

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Colors

func colorFromHex(_ hexValue: UInt32, alpha: CGFloat = 1.0) -> CGColor {
    let red = CGFloat((hexValue >> 16) & 0xFF) / 255.0
    let green = CGFloat((hexValue >> 8) & 0xFF) / 255.0
    let blue = CGFloat(hexValue & 0xFF) / 255.0
    return CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

// MARK: - Canvas

/// A top-left-origin drawing surface that also remembers named element rectangles.
final class MockScreenCanvas {
    let widthInPixels: Int
    let heightInPixels: Int
    let context: CGContext
    var elementBoxesByName: [String: CGRect] = [:]

    init(widthInPixels: Int, heightInPixels: Int) {
        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        context = CGContext(
            data: nil,
            width: widthInPixels,
            height: heightInPixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // Flip so that (0, 0) is the top-left corner and y grows downward, like the real screenshots.
        context.translateBy(x: 0, y: CGFloat(heightInPixels))
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
    }

    func recordElement(_ elementName: String, _ rectangle: CGRect) {
        elementBoxesByName[elementName] = rectangle
    }

    func fillRectangle(_ rectangle: CGRect, color: CGColor) {
        context.setFillColor(color)
        context.fill(rectangle)
    }

    func fillRoundedRectangle(_ rectangle: CGRect, cornerRadius: CGFloat, color: CGColor) {
        context.setFillColor(color)
        let path = CGPath(roundedRect: rectangle, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(path)
        context.fillPath()
    }

    func strokeRoundedRectangle(_ rectangle: CGRect, cornerRadius: CGFloat, color: CGColor, lineWidth: CGFloat = 1) {
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        let path = CGPath(roundedRect: rectangle, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(path)
        context.strokePath()
    }

    func drawLine(from startPoint: CGPoint, to endPoint: CGPoint, color: CGColor, lineWidth: CGFloat = 1) {
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.move(to: startPoint)
        context.addLine(to: endPoint)
        context.strokePath()
    }

    func fillCircle(center: CGPoint, radius: CGFloat, color: CGColor) {
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func strokeCircle(center: CGPoint, radius: CGFloat, color: CGColor, lineWidth: CGFloat = 1.5) {
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func fillPolygon(_ points: [CGPoint], color: CGColor) {
        guard let firstPoint = points.first else { return }
        context.setFillColor(color)
        context.move(to: firstPoint)
        for point in points.dropFirst() { context.addLine(to: point) }
        context.closePath()
        context.fillPath()
    }

    func strokePolyline(_ points: [CGPoint], color: CGColor, lineWidth: CGFloat = 1.5) {
        guard let firstPoint = points.first else { return }
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: firstPoint)
        for point in points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
    }

    func fillVerticalGradient(_ rectangle: CGRect, topColor: CGColor, bottomColor: CGColor) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: [topColor, bottomColor] as CFArray, locations: [0, 1]) else { return }
        context.saveGState()
        context.clip(to: rectangle)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rectangle.minX, y: rectangle.minY),
            end: CGPoint(x: rectangle.minX, y: rectangle.maxY),
            options: []
        )
        context.restoreGState()
    }

    private func makeFont(size: CGFloat, isBold: Bool, isMonospaced: Bool) -> CTFont {
        if isMonospaced {
            return CTFontCreateWithName((isBold ? "Menlo-Bold" : "Menlo-Regular") as CFString, size, nil)
        }
        let systemFont = CTFontCreateUIFontForLanguage(isBold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return systemFont
    }

    private func makeLine(_ text: String, size: CGFloat, color: CGColor, isBold: Bool, isMonospaced: Bool) -> CTLine {
        let font = makeFont(size: size, isBold: isBold, isMonospaced: isMonospaced)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    func measureText(_ text: String, size: CGFloat = 12, isBold: Bool = false, isMonospaced: Bool = false) -> CGFloat {
        let line = makeLine(text, size: size, color: colorFromHex(0x000000), isBold: isBold, isMonospaced: isMonospaced)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Draws one line of text vertically centred on `centerY`. Returns the drawn width.
    @discardableResult
    func drawText(
        _ text: String,
        x: CGFloat,
        centerY: CGFloat,
        size: CGFloat = 12,
        color: CGColor,
        isBold: Bool = false,
        isMonospaced: Bool = false
    ) -> CGFloat {
        let line = makeLine(text, size: size, color: color, isBold: isBold, isMonospaced: isMonospaced)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let baselineY = centerY + (ascent - descent) / 2
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
        return width
    }

    /// Draws text so that its right edge sits at `rightEdgeX`.
    func drawTextRightAligned(_ text: String, rightEdgeX: CGFloat, centerY: CGFloat, size: CGFloat = 12, color: CGColor, isBold: Bool = false) {
        let width = measureText(text, size: size, isBold: isBold)
        drawText(text, x: rightEdgeX - width, centerY: centerY, size: size, color: color, isBold: isBold)
    }

    func drawTextCentered(_ text: String, centerX: CGFloat, centerY: CGFloat, size: CGFloat = 12, color: CGColor, isBold: Bool = false) {
        let width = measureText(text, size: size, isBold: isBold)
        drawText(text, x: centerX - width / 2, centerY: centerY, size: size, color: color, isBold: isBold)
    }

    func saveAsJPEG(to fileURL: URL) {
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            fatalError("could not create image destination for \(fileURL.path)")
        }
        // 0.8 matches the compression factor used by CompanionScreenCaptureUtility.
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(fileURL.path)") }
    }
}

// MARK: - Small icon helpers

func drawPlayTriangleIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor) {
    canvas.fillPolygon([
        CGPoint(x: centerX - size * 0.35, y: centerY - size * 0.5),
        CGPoint(x: centerX + size * 0.5, y: centerY),
        CGPoint(x: centerX - size * 0.35, y: centerY + size * 0.5)
    ], color: color)
}

func drawPlusIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor, lineWidth: CGFloat = 1.8) {
    canvas.drawLine(from: CGPoint(x: centerX - size / 2, y: centerY), to: CGPoint(x: centerX + size / 2, y: centerY), color: color, lineWidth: lineWidth)
    canvas.drawLine(from: CGPoint(x: centerX, y: centerY - size / 2), to: CGPoint(x: centerX, y: centerY + size / 2), color: color, lineWidth: lineWidth)
}

func drawMagnifyingGlassIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor) {
    canvas.strokeCircle(center: CGPoint(x: centerX - size * 0.1, y: centerY - size * 0.1), radius: size * 0.34, color: color, lineWidth: 1.6)
    canvas.drawLine(from: CGPoint(x: centerX + size * 0.15, y: centerY + size * 0.15), to: CGPoint(x: centerX + size * 0.42, y: centerY + size * 0.42), color: color, lineWidth: 1.8)
}

func drawBranchIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor) {
    let topPoint = CGPoint(x: centerX - size * 0.2, y: centerY - size * 0.38)
    let bottomPoint = CGPoint(x: centerX - size * 0.2, y: centerY + size * 0.38)
    let sidePoint = CGPoint(x: centerX + size * 0.28, y: centerY - size * 0.1)
    canvas.drawLine(from: topPoint, to: bottomPoint, color: color, lineWidth: 1.6)
    canvas.drawLine(from: sidePoint, to: CGPoint(x: centerX - size * 0.2, y: centerY + size * 0.12), color: color, lineWidth: 1.6)
    for point in [topPoint, bottomPoint, sidePoint] {
        canvas.fillCircle(center: point, radius: size * 0.13, color: color)
    }
}

func drawDocumentsIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor) {
    canvas.strokeRoundedRectangle(CGRect(x: centerX - size * 0.32, y: centerY - size * 0.42, width: size * 0.5, height: size * 0.62), cornerRadius: 2, color: color, lineWidth: 1.5)
    canvas.strokeRoundedRectangle(CGRect(x: centerX - size * 0.12, y: centerY - size * 0.22, width: size * 0.5, height: size * 0.62), cornerRadius: 2, color: color, lineWidth: 1.5)
}

func drawBugPlayIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor) {
    drawPlayTriangleIcon(on: canvas, centerX: centerX - size * 0.08, centerY: centerY - size * 0.05, size: size * 0.55, color: color)
    canvas.strokeCircle(center: CGPoint(x: centerX + size * 0.22, y: centerY + size * 0.22), radius: size * 0.15, color: color, lineWidth: 1.4)
}

func drawExtensionsIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor) {
    let cell = size * 0.3
    for (offsetX, offsetY) in [(-0.34, -0.1), (-0.0, -0.1), (-0.34, 0.24)] as [(CGFloat, CGFloat)] {
        canvas.strokeRoundedRectangle(CGRect(x: centerX + offsetX * size, y: centerY + offsetY * size, width: cell, height: cell), cornerRadius: 1, color: color, lineWidth: 1.4)
    }
    canvas.strokeRoundedRectangle(CGRect(x: centerX + 0.1 * size, y: centerY - 0.42 * size, width: cell, height: cell), cornerRadius: 1, color: color, lineWidth: 1.4)
}

func drawWarningTriangleIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor) {
    canvas.strokePolyline([
        CGPoint(x: centerX, y: centerY - size * 0.4),
        CGPoint(x: centerX + size * 0.45, y: centerY + size * 0.38),
        CGPoint(x: centerX - size * 0.45, y: centerY + size * 0.38),
        CGPoint(x: centerX, y: centerY - size * 0.4)
    ], color: color, lineWidth: 1.4)
    canvas.drawLine(from: CGPoint(x: centerX, y: centerY - size * 0.12), to: CGPoint(x: centerX, y: centerY + size * 0.14), color: color, lineWidth: 1.4)
}

func drawChevron(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor, pointsRight: Bool = true) {
    let direction: CGFloat = pointsRight ? 1 : -1
    canvas.strokePolyline([
        CGPoint(x: centerX - direction * size * 0.25, y: centerY - size * 0.4),
        CGPoint(x: centerX + direction * size * 0.25, y: centerY),
        CGPoint(x: centerX - direction * size * 0.25, y: centerY + size * 0.4)
    ], color: color, lineWidth: 1.6)
}

func drawReloadIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor) {
    canvas.context.setStrokeColor(color)
    canvas.context.setLineWidth(1.8)
    canvas.context.addArc(center: CGPoint(x: centerX, y: centerY), radius: size * 0.36, startAngle: 0.6, endAngle: 5.4, clockwise: false)
    canvas.context.strokePath()
    canvas.fillPolygon([
        CGPoint(x: centerX + size * 0.46, y: centerY - size * 0.22),
        CGPoint(x: centerX + size * 0.16, y: centerY - size * 0.18),
        CGPoint(x: centerX + size * 0.38, y: centerY + size * 0.08)
    ], color: color)
}

func drawStarIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, size: CGFloat, color: CGColor) {
    var points: [CGPoint] = []
    for pointIndex in 0..<10 {
        let angle = -CGFloat.pi / 2 + CGFloat(pointIndex) * CGFloat.pi / 5
        let radius = pointIndex % 2 == 0 ? size * 0.5 : size * 0.22
        points.append(CGPoint(x: centerX + cos(angle) * radius, y: centerY + sin(angle) * radius))
    }
    points.append(points[0])
    canvas.strokePolyline(points, color: color, lineWidth: 1.4)
}

func drawPaneToggleIcon(on canvas: MockScreenCanvas, centerX: CGFloat, centerY: CGFloat, highlightedPane: String, color: CGColor) {
    let frame = CGRect(x: centerX - 9, y: centerY - 7, width: 18, height: 14)
    canvas.strokeRoundedRectangle(frame, cornerRadius: 2, color: color, lineWidth: 1.4)
    switch highlightedPane {
    case "left":
        canvas.fillRectangle(CGRect(x: frame.minX + 1, y: frame.minY + 1, width: 5, height: frame.height - 2), color: color)
    case "right":
        canvas.fillRectangle(CGRect(x: frame.maxX - 6, y: frame.minY + 1, width: 5, height: frame.height - 2), color: color)
    default:
        canvas.fillRectangle(CGRect(x: frame.minX + 1, y: frame.maxY - 5, width: frame.width - 2, height: 4), color: color)
    }
}

// MARK: - Desktop pieces shared by every fixture

func drawDesktopWallpaper(on canvas: MockScreenCanvas) {
    canvas.fillVerticalGradient(
        CGRect(x: 0, y: 0, width: canvas.widthInPixels, height: canvas.heightInPixels),
        topColor: colorFromHex(0x2b3a67),
        bottomColor: colorFromHex(0x6a4c93)
    )
}

/// Draws the macOS menu bar and records one element per menu title (menubar_<name>).
func drawMacMenuBar(on canvas: MockScreenCanvas, applicationName: String, menuTitles: [String]) {
    let menuBarHeight: CGFloat = 22
    canvas.fillRectangle(CGRect(x: 0, y: 0, width: CGFloat(canvas.widthInPixels), height: menuBarHeight), color: colorFromHex(0xE8E6EE))
    canvas.drawLine(from: CGPoint(x: 0, y: menuBarHeight), to: CGPoint(x: CGFloat(canvas.widthInPixels), y: menuBarHeight), color: colorFromHex(0x9a98a3, alpha: 0.6), lineWidth: 0.5)
    let textColor = colorFromHex(0x111111)

    // Apple logo (private-use glyph U+F8FF renders as the logo in the system font).
    canvas.drawText("\u{F8FF}", x: 14, centerY: 11, size: 14, color: textColor)

    var cursorX: CGFloat = 40
    let applicationNameWidth = canvas.drawText(applicationName, x: cursorX, centerY: 11, size: 12.5, color: textColor, isBold: true)
    canvas.recordElement("menubar_" + applicationName.lowercased().replacingOccurrences(of: " ", with: "_"),
                         CGRect(x: cursorX - 6, y: 0, width: applicationNameWidth + 12, height: menuBarHeight))
    cursorX += applicationNameWidth + 18

    for menuTitle in menuTitles {
        let titleWidth = canvas.drawText(menuTitle, x: cursorX, centerY: 11, size: 12.5, color: textColor)
        canvas.recordElement("menubar_" + menuTitle.lowercased().replacingOccurrences(of: " ", with: "_"),
                             CGRect(x: cursorX - 8, y: 0, width: titleWidth + 16, height: menuBarHeight))
        cursorX += titleWidth + 20
    }

    // Right-hand status items: clock, battery, wifi.
    let rightEdgeX = CGFloat(canvas.widthInPixels) - 14
    canvas.drawTextRightAligned("Tue Nov 11  10:42 AM", rightEdgeX: rightEdgeX, centerY: 11, size: 12.5, color: textColor)
    let batteryCenterX = rightEdgeX - 168
    canvas.strokeRoundedRectangle(CGRect(x: batteryCenterX - 12, y: 6, width: 22, height: 10), cornerRadius: 2.5, color: textColor, lineWidth: 1)
    canvas.fillRoundedRectangle(CGRect(x: batteryCenterX - 10.5, y: 7.5, width: 15, height: 7), cornerRadius: 1.5, color: textColor)
    canvas.fillRectangle(CGRect(x: batteryCenterX + 11, y: 9, width: 2, height: 4), color: textColor)
    let wifiCenterX = batteryCenterX - 34
    for arcRadius in [4.0, 7.0, 10.0] as [CGFloat] {
        canvas.context.setStrokeColor(textColor)
        canvas.context.setLineWidth(1.5)
        canvas.context.addArc(center: CGPoint(x: wifiCenterX, y: 16), radius: arcRadius, startAngle: -CGFloat.pi * 0.8, endAngle: -CGFloat.pi * 0.2, clockwise: false)
        canvas.context.strokePath()
    }
    canvas.fillCircle(center: CGPoint(x: wifiCenterX, y: 16), radius: 1.5, color: textColor)
}

func drawTrafficLights(on canvas: MockScreenCanvas, originX: CGFloat, centerY: CGFloat, elementPrefix: String) {
    let lightColors: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
    let lightNames = ["close_button", "minimize_button", "zoom_button"]
    for lightIndex in 0..<3 {
        let centerX = originX + CGFloat(lightIndex) * 20
        canvas.fillCircle(center: CGPoint(x: centerX, y: centerY), radius: 6.5, color: colorFromHex(lightColors[lightIndex]))
        canvas.recordElement("\(elementPrefix)_\(lightNames[lightIndex])", CGRect(x: centerX - 8, y: centerY - 8, width: 16, height: 16))
    }
}

// MARK: - Code syntax highlighting

struct CodePalette {
    let defaultText: CGColor
    let keyword: CGColor
    let typeName: CGColor
    let string: CGColor
    let comment: CGColor
    let number: CGColor
    let attribute: CGColor
}

let xcodeDarkPalette = CodePalette(
    defaultText: colorFromHex(0xdfdfe0), keyword: colorFromHex(0xfc5fa3), typeName: colorFromHex(0x5dd8ff),
    string: colorFromHex(0xfc6a5d), comment: colorFromHex(0x7f8c98), number: colorFromHex(0xd0bf69), attribute: colorFromHex(0xfd8f3f)
)
let vscodeDarkPalette = CodePalette(
    defaultText: colorFromHex(0xd4d4d4), keyword: colorFromHex(0x569cd6), typeName: colorFromHex(0x4ec9b0),
    string: colorFromHex(0xce9178), comment: colorFromHex(0x6a9955), number: colorFromHex(0xb5cea8), attribute: colorFromHex(0xdcdcaa)
)

let swiftKeywordSet: Set<String> = [
    "import", "class", "struct", "enum", "func", "let", "var", "private", "final", "return", "if", "else", "guard",
    "self", "init", "some", "static", "mutating", "async", "await", "in", "for", "try", "nil", "true", "false", "extension", "protocol"
]
let typeScriptKeywordSet: Set<String> = [
    "import", "export", "default", "const", "let", "var", "function", "return", "if", "else", "async", "await",
    "interface", "type", "new", "true", "false", "null", "undefined", "class"
]

func highlightCodeLine(_ line: String, isSwift: Bool, palette: CodePalette) -> [(text: String, color: CGColor)] {
    var segments: [(text: String, color: CGColor)] = []
    let keywordSet = isSwift ? swiftKeywordSet : typeScriptKeywordSet
    let characters = Array(line)
    var index = 0
    var pendingDefaultText = ""

    func flushDefaultText() {
        if !pendingDefaultText.isEmpty {
            segments.append((pendingDefaultText, palette.defaultText))
            pendingDefaultText = ""
        }
    }

    while index < characters.count {
        let character = characters[index]
        if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
            flushDefaultText()
            segments.append((String(characters[index...]), palette.comment))
            return segments
        }
        if character == "\"" || character == "`" || (!isSwift && character == "'") {
            flushDefaultText()
            var endIndex = index + 1
            while endIndex < characters.count, characters[endIndex] != character { endIndex += 1 }
            endIndex = min(endIndex + 1, characters.count)
            segments.append((String(characters[index..<endIndex]), palette.string))
            index = endIndex
            continue
        }
        if character.isLetter || character == "_" || character == "@" {
            var endIndex = index + 1
            while endIndex < characters.count, characters[endIndex].isLetter || characters[endIndex].isNumber || characters[endIndex] == "_" {
                endIndex += 1
            }
            let word = String(characters[index..<endIndex])
            flushDefaultText()
            if word.hasPrefix("@") {
                segments.append((word, palette.attribute))
            } else if keywordSet.contains(word) {
                segments.append((word, palette.keyword))
            } else if let firstLetter = word.first, firstLetter.isUppercase {
                segments.append((word, palette.typeName))
            } else {
                segments.append((word, palette.defaultText))
            }
            index = endIndex
            continue
        }
        if character.isNumber {
            flushDefaultText()
            var endIndex = index + 1
            while endIndex < characters.count, characters[endIndex].isNumber { endIndex += 1 }
            segments.append((String(characters[index..<endIndex]), palette.number))
            index = endIndex
            continue
        }
        pendingDefaultText.append(character)
        index += 1
    }
    flushDefaultText()
    return segments
}

/// Draws one highlighted code line starting at `x`, returns the x where the text ends.
@discardableResult
func drawHighlightedCodeLine(on canvas: MockScreenCanvas, line: String, x: CGFloat, centerY: CGFloat, fontSize: CGFloat, isSwift: Bool, palette: CodePalette) -> CGFloat {
    var cursorX = x
    for segment in highlightCodeLine(line, isSwift: isSwift, palette: palette) {
        cursorX += canvas.drawText(segment.text, x: cursorX, centerY: centerY, size: fontSize, color: segment.color, isMonospaced: true)
    }
    return cursorX
}

// MARK: - Xcode mock

struct XcodeMockContent {
    var selectedFileName: String
    var codeLines: [String]
    var errorLineIndexes: [Int] = []
    var errorMessage: String? = nil
    var toolbarStatusText: String = "Build Succeeded"
    var toolbarStatusIsError: Bool = false
    var consoleLines: [String]
}

func makeXcodeScreenshot(fileName: String, content: XcodeMockContent) -> (MockScreenCanvas, String) {
    let canvas = MockScreenCanvas(widthInPixels: 1280, heightInPixels: 800)
    drawDesktopWallpaper(on: canvas)
    drawMacMenuBar(on: canvas, applicationName: "Xcode", menuTitles: ["File", "Edit", "View", "Find", "Navigate", "Editor", "Product", "Debug", "Source Control", "Window", "Help"])

    let windowBackground = colorFromHex(0x1f1f24)
    let panelBackground = colorFromHex(0x26262b)
    let toolbarBackground = colorFromHex(0x2d2d33)
    let controlBackground = colorFromHex(0x3b3b42)
    let primaryText = colorFromHex(0xe6e6ea)
    let secondaryText = colorFromHex(0x9a9aa3)
    let separatorColor = colorFromHex(0x0e0e10)

    canvas.fillRectangle(CGRect(x: 0, y: 22, width: 1280, height: 778), color: windowBackground)

    // Toolbar
    canvas.fillRectangle(CGRect(x: 0, y: 22, width: 1280, height: 48), color: toolbarBackground)
    canvas.drawLine(from: CGPoint(x: 0, y: 70), to: CGPoint(x: 1280, y: 70), color: separatorColor, lineWidth: 1)
    drawTrafficLights(on: canvas, originX: 22, centerY: 46, elementPrefix: "xcode")
    drawPaneToggleIcon(on: canvas, centerX: 106, centerY: 46, highlightedPane: "left", color: primaryText)
    canvas.recordElement("xcode_navigator_toggle", CGRect(x: 90, y: 33, width: 32, height: 26))

    canvas.fillRoundedRectangle(CGRect(x: 136, y: 33, width: 28, height: 26), cornerRadius: 5, color: controlBackground)
    drawPlayTriangleIcon(on: canvas, centerX: 150, centerY: 46, size: 13, color: primaryText)
    canvas.recordElement("xcode_run_button", CGRect(x: 136, y: 33, width: 28, height: 26))

    canvas.fillRoundedRectangle(CGRect(x: 170, y: 33, width: 28, height: 26), cornerRadius: 5, color: controlBackground)
    canvas.fillRoundedRectangle(CGRect(x: 178, y: 40, width: 12, height: 12), cornerRadius: 1.5, color: primaryText)
    canvas.recordElement("xcode_stop_button", CGRect(x: 170, y: 33, width: 28, height: 26))

    canvas.fillRoundedRectangle(CGRect(x: 214, y: 34, width: 190, height: 24), cornerRadius: 6, color: controlBackground)
    canvas.fillRoundedRectangle(CGRect(x: 222, y: 39, width: 14, height: 14), cornerRadius: 3, color: colorFromHex(0x1d8cff))
    canvas.drawText("Clicker", x: 244, centerY: 46, size: 12.5, color: primaryText, isBold: true)
    canvas.drawText(">  My Mac", x: 304, centerY: 46, size: 12, color: secondaryText)
    canvas.recordElement("xcode_scheme_selector", CGRect(x: 214, y: 34, width: 190, height: 24))

    canvas.fillRoundedRectangle(CGRect(x: 430, y: 32, width: 470, height: 28), cornerRadius: 6, color: colorFromHex(0x1c1c20))
    let statusColor = content.toolbarStatusIsError ? colorFromHex(0xff6b6b) : primaryText
    canvas.drawTextCentered("Clicker  |  \(content.toolbarStatusText)", centerX: 665, centerY: 46, size: 12.5, color: statusColor)
    canvas.drawTextRightAligned("Today at 10:41 AM", rightEdgeX: 888, centerY: 46, size: 11, color: secondaryText)
    canvas.recordElement("xcode_activity_viewer", CGRect(x: 430, y: 32, width: 470, height: 28))

    drawPlusIcon(on: canvas, centerX: 1144, centerY: 46, size: 13, color: primaryText)
    canvas.recordElement("xcode_library_button", CGRect(x: 1130, y: 33, width: 28, height: 26))
    drawPaneToggleIcon(on: canvas, centerX: 1190, centerY: 46, highlightedPane: "none", color: primaryText)
    canvas.recordElement("xcode_editor_options_button", CGRect(x: 1174, y: 33, width: 32, height: 26))
    drawPaneToggleIcon(on: canvas, centerX: 1226, centerY: 46, highlightedPane: "bottom", color: primaryText)
    canvas.recordElement("xcode_debug_area_toggle", CGRect(x: 1210, y: 33, width: 32, height: 26))
    drawPaneToggleIcon(on: canvas, centerX: 1262, centerY: 46, highlightedPane: "right", color: primaryText)
    canvas.recordElement("xcode_inspector_toggle", CGRect(x: 1246, y: 33, width: 32, height: 26))

    // Navigator
    canvas.fillRectangle(CGRect(x: 0, y: 71, width: 250, height: 701), color: panelBackground)
    canvas.drawLine(from: CGPoint(x: 250, y: 71), to: CGPoint(x: 250, y: 772), color: separatorColor, lineWidth: 1)
    let navigatorTabNames = ["files", "source_control", "symbols", "find", "issues", "tests", "debug", "breakpoints", "reports"]
    for (tabIndex, tabName) in navigatorTabNames.enumerated() {
        let tabCenterX = 20 + CGFloat(tabIndex) * 26
        let isSelectedTab = tabIndex == 0
        let tabColor = isSelectedTab ? colorFromHex(0x4a9dff) : secondaryText
        switch tabName {
        case "files": drawDocumentsIcon(on: canvas, centerX: tabCenterX, centerY: 85, size: 15, color: tabColor)
        case "source_control": drawBranchIcon(on: canvas, centerX: tabCenterX, centerY: 85, size: 15, color: tabColor)
        case "find": drawMagnifyingGlassIcon(on: canvas, centerX: tabCenterX, centerY: 85, size: 15, color: tabColor)
        case "issues": drawWarningTriangleIcon(on: canvas, centerX: tabCenterX, centerY: 85, size: 15, color: tabColor)
        default: canvas.strokeRoundedRectangle(CGRect(x: tabCenterX - 6, y: 79, width: 12, height: 12), cornerRadius: 3, color: tabColor, lineWidth: 1.3)
        }
        canvas.recordElement("xcode_navigator_tab_\(tabName)", CGRect(x: tabCenterX - 12, y: 73, width: 24, height: 24))
    }
    canvas.drawLine(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 250, y: 100), color: separatorColor, lineWidth: 1)

    let navigatorRows: [(depth: Int, name: String, isGroup: Bool)] = [
        (0, "Clicker", true), (1, "Clicker", true),
        (2, "ClickerApp.swift", false), (2, content.selectedFileName == "CompanionManager.swift" ? "CompanionManager.swift" : content.selectedFileName, false),
        (2, "ClaudeAPI.swift", false), (2, "OverlayWindow.swift", false), (2, "DesignSystem.swift", false),
        (2, "Assets.xcassets", true), (2, "Info.plist", false), (1, "Products", true)
    ]
    var seenRowNames: Set<String> = []
    for (rowIndex, row) in navigatorRows.enumerated() {
        let rowCenterY = 118 + CGFloat(rowIndex) * 22
        // De-duplicate the selected file name if it matches a default row.
        if !row.isGroup && seenRowNames.contains(row.name) { continue }
        seenRowNames.insert(row.name)
        if row.name == content.selectedFileName && !row.isGroup {
            canvas.fillRectangle(CGRect(x: 0, y: rowCenterY - 11, width: 250, height: 22), color: colorFromHex(0x3a4a6b))
        }
        let rowX = 12 + CGFloat(row.depth) * 16
        if row.isGroup {
            canvas.drawText(row.depth == 0 ? "v" : (row.name == "Clicker" ? "v" : ">"), x: rowX, centerY: rowCenterY, size: 10, color: secondaryText, isBold: true)
            canvas.fillRoundedRectangle(CGRect(x: rowX + 14, y: rowCenterY - 6, width: 13, height: 12), cornerRadius: 2, color: colorFromHex(row.depth == 0 ? 0x1d8cff : 0x6ea8e6))
            canvas.drawText(row.name, x: rowX + 33, centerY: rowCenterY, size: 12.5, color: primaryText, isBold: row.depth == 0)
        } else {
            canvas.fillRoundedRectangle(CGRect(x: rowX + 14, y: rowCenterY - 6, width: 11, height: 13), cornerRadius: 2, color: row.name.hasSuffix(".swift") ? colorFromHex(0xff7a45) : colorFromHex(0xb0b0b8))
            canvas.drawText(row.name, x: rowX + 31, centerY: rowCenterY, size: 12.5, color: primaryText)
            canvas.recordElement("xcode_navigator_row_\(row.name)", CGRect(x: 0, y: rowCenterY - 11, width: 250, height: 22))
        }
    }
    canvas.fillRoundedRectangle(CGRect(x: 8, y: 746, width: 234, height: 22), cornerRadius: 5, color: colorFromHex(0x1c1c20))
    drawMagnifyingGlassIcon(on: canvas, centerX: 22, centerY: 757, size: 11, color: secondaryText)
    canvas.drawText("Filter", x: 34, centerY: 757, size: 12, color: secondaryText)
    canvas.recordElement("xcode_navigator_filter_field", CGRect(x: 8, y: 746, width: 234, height: 22))

    // Jump bar
    canvas.fillRectangle(CGRect(x: 251, y: 71, width: 1029, height: 24), color: windowBackground)
    canvas.drawText("Clicker  >  Clicker  >  \(content.selectedFileName)", x: 262, centerY: 83, size: 12, color: secondaryText)

    // Editor
    let lineHeight: CGFloat = 17
    let firstLineCenterY: CGFloat = 106
    for (lineIndex, codeLine) in content.codeLines.prefix(27).enumerated() {
        let lineCenterY = firstLineCenterY + CGFloat(lineIndex) * lineHeight
        let isErrorLine = content.errorLineIndexes.contains(lineIndex)
        if isErrorLine {
            canvas.fillRectangle(CGRect(x: 251, y: lineCenterY - lineHeight / 2, width: 1029, height: lineHeight), color: colorFromHex(0xff5555, alpha: 0.16))
            canvas.fillCircle(center: CGPoint(x: 268, y: lineCenterY), radius: 7, color: colorFromHex(0xe5484d))
            canvas.drawTextCentered("!", centerX: 268, centerY: lineCenterY, size: 10, color: colorFromHex(0xffffff), isBold: true)
        }
        canvas.drawTextRightAligned("\(lineIndex + 1)", rightEdgeX: 300, centerY: lineCenterY, size: 11, color: colorFromHex(0x6c6c75))
        let lineEndX = drawHighlightedCodeLine(on: canvas, line: codeLine, x: 312, centerY: lineCenterY, fontSize: 12.5, isSwift: true, palette: xcodeDarkPalette)
        if isErrorLine, let errorMessage = content.errorMessage {
            let messageX = max(lineEndX + 24, 560)
            let messageWidth = canvas.measureText(errorMessage, size: 11.5) + 16
            canvas.fillRoundedRectangle(CGRect(x: messageX, y: lineCenterY - 8, width: messageWidth, height: 16), cornerRadius: 3, color: colorFromHex(0xc4383d))
            canvas.drawText(errorMessage, x: messageX + 8, centerY: lineCenterY, size: 11.5, color: colorFromHex(0xffffff))
        }
    }

    // Debug area
    canvas.fillRectangle(CGRect(x: 251, y: 561, width: 1029, height: 211), color: windowBackground)
    canvas.drawLine(from: CGPoint(x: 251, y: 561), to: CGPoint(x: 1280, y: 561), color: separatorColor, lineWidth: 1)
    canvas.fillRectangle(CGRect(x: 251, y: 562, width: 1029, height: 24), color: toolbarBackground)
    for iconIndex in 0..<5 {
        canvas.strokeRoundedRectangle(CGRect(x: 262 + CGFloat(iconIndex) * 30, y: 568, width: 12, height: 12), cornerRadius: 2, color: secondaryText, lineWidth: 1.2)
    }
    canvas.drawLine(from: CGPoint(x: 760, y: 586), to: CGPoint(x: 760, y: 750), color: separatorColor, lineWidth: 1)
    canvas.drawText("Auto", x: 264, centerY: 604, size: 11.5, color: secondaryText, isBold: true)
    canvas.drawText("v self  CompanionManager", x: 264, centerY: 624, size: 11.5, color: primaryText, isMonospaced: true)
    canvas.drawText("    voiceState  VoiceState", x: 264, centerY: 641, size: 11.5, color: secondaryText, isMonospaced: true)
    canvas.recordElement("xcode_debug_console", CGRect(x: 761, y: 587, width: 519, height: 163))
    for (consoleIndex, consoleLine) in content.consoleLines.suffix(9).enumerated() {
        canvas.drawText(consoleLine, x: 770, centerY: 600 + CGFloat(consoleIndex) * 16, size: 11, color: colorFromHex(0xcfcfd6), isMonospaced: true)
    }
    canvas.fillRectangle(CGRect(x: 251, y: 750, width: 1029, height: 22), color: toolbarBackground)
    canvas.drawText("Auto  v", x: 264, centerY: 761, size: 11.5, color: secondaryText)
    canvas.fillRoundedRectangle(CGRect(x: 1040, y: 753, width: 160, height: 16), cornerRadius: 4, color: colorFromHex(0x1c1c20))
    canvas.drawText("Filter", x: 1050, centerY: 761, size: 11, color: secondaryText)
    canvas.strokeRoundedRectangle(CGRect(x: 1246, y: 755, width: 12, height: 12), cornerRadius: 2, color: primaryText, lineWidth: 1.2)
    canvas.recordElement("xcode_console_clear_button", CGRect(x: 1238, y: 751, width: 28, height: 20))

    return (canvas, fileName)
}

// MARK: - VS Code mock

struct VSCodeMockContent {
    var fileName: String
    var codeLines: [String]
    var errorLineIndex: Int? = nil
    var errorUnderlineColumns: ClosedRange<Int>? = nil
    var problemEntries: [String] = []
    var terminalLines: [String] = []
    var showProblemsPanel: Bool = false
    var errorCount: Int = 0
}

func makeVSCodeScreenshot(fileName: String, content: VSCodeMockContent) -> (MockScreenCanvas, String) {
    let canvas = MockScreenCanvas(widthInPixels: 1280, heightInPixels: 800)
    drawDesktopWallpaper(on: canvas)
    drawMacMenuBar(on: canvas, applicationName: "Code", menuTitles: ["File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Window", "Help"])

    let editorBackground = colorFromHex(0x1e1e1e)
    let sidebarBackground = colorFromHex(0x252526)
    let activityBarBackground = colorFromHex(0x333333)
    let titleBarBackground = colorFromHex(0x3c3c3c)
    let primaryText = colorFromHex(0xcccccc)
    let secondaryText = colorFromHex(0x8b8b8b)
    let accentBlue = colorFromHex(0x007acc)

    canvas.fillRectangle(CGRect(x: 0, y: 22, width: 1280, height: 778), color: editorBackground)

    // Title bar with command center
    canvas.fillRectangle(CGRect(x: 0, y: 22, width: 1280, height: 30), color: titleBarBackground)
    drawTrafficLights(on: canvas, originX: 20, centerY: 37, elementPrefix: "vscode")
    canvas.fillRoundedRectangle(CGRect(x: 420, y: 28, width: 440, height: 18), cornerRadius: 6, color: colorFromHex(0x2b2b2b))
    canvas.drawTextCentered("clicker-worker", centerX: 640, centerY: 37, size: 12, color: primaryText)
    canvas.recordElement("vscode_command_center", CGRect(x: 420, y: 28, width: 440, height: 18))

    // Activity bar (unlabeled icons, like the real thing)
    canvas.fillRectangle(CGRect(x: 0, y: 52, width: 48, height: 720), color: activityBarBackground)
    let activityIconNames = ["explorer", "search", "source_control", "run_and_debug", "extensions"]
    for (iconIndex, iconName) in activityIconNames.enumerated() {
        let iconCenterY: CGFloat = 78 + CGFloat(iconIndex) * 46
        let iconColor = iconIndex == 0 ? colorFromHex(0xffffff) : colorFromHex(0x858585)
        switch iconName {
        case "explorer": drawDocumentsIcon(on: canvas, centerX: 24, centerY: iconCenterY, size: 24, color: iconColor)
        case "search": drawMagnifyingGlassIcon(on: canvas, centerX: 24, centerY: iconCenterY, size: 24, color: iconColor)
        case "source_control": drawBranchIcon(on: canvas, centerX: 24, centerY: iconCenterY, size: 24, color: iconColor)
        case "run_and_debug": drawBugPlayIcon(on: canvas, centerX: 24, centerY: iconCenterY, size: 24, color: iconColor)
        default: drawExtensionsIcon(on: canvas, centerX: 24, centerY: iconCenterY, size: 24, color: iconColor)
        }
        canvas.recordElement("vscode_activity_\(iconName)", CGRect(x: 0, y: iconCenterY - 23, width: 48, height: 46))
    }
    canvas.fillRectangle(CGRect(x: 0, y: 55, width: 2, height: 46), color: colorFromHex(0xffffff))
    // notification badge on source control
    canvas.fillCircle(center: CGPoint(x: 34, y: 78 + 2 * 46 + 8), radius: 7, color: accentBlue)
    canvas.drawTextCentered("3", centerX: 34, centerY: 78 + 2 * 46 + 8, size: 9, color: colorFromHex(0xffffff), isBold: true)

    // Sidebar (Explorer)
    canvas.fillRectangle(CGRect(x: 48, y: 52, width: 252, height: 720), color: sidebarBackground)
    canvas.drawText("EXPLORER", x: 64, centerY: 70, size: 11, color: primaryText)
    canvas.drawText("v CLICKER-WORKER", x: 58, centerY: 94, size: 11, color: primaryText, isBold: true)
    let explorerRows: [(depth: Int, name: String)] = [(1, "src"), (2, "index.ts"), (2, "types.ts"), (1, "package.json"), (1, "tsconfig.json"), (1, "wrangler.toml")]
    for (rowIndex, row) in explorerRows.enumerated() {
        let rowCenterY: CGFloat = 118 + CGFloat(rowIndex) * 22
        let isActiveFile = row.name == content.fileName
        if isActiveFile {
            canvas.fillRectangle(CGRect(x: 48, y: rowCenterY - 11, width: 252, height: 22), color: colorFromHex(0x37373d))
        }
        canvas.drawText(row.name == "src" ? "v  src" : row.name, x: 62 + CGFloat(row.depth) * 14, centerY: rowCenterY, size: 12.5, color: primaryText)
        canvas.recordElement("vscode_explorer_row_\(row.name)", CGRect(x: 48, y: rowCenterY - 11, width: 252, height: 22))
    }

    // Tabs
    canvas.fillRectangle(CGRect(x: 300, y: 52, width: 980, height: 34), color: sidebarBackground)
    var tabX: CGFloat = 300
    for tabName in [content.fileName, "package.json", "wrangler.toml"] {
        let tabWidth = canvas.measureText(tabName, size: 12.5) + 56
        let isActiveTab = tabName == content.fileName
        canvas.fillRectangle(CGRect(x: tabX, y: 52, width: tabWidth, height: 34), color: isActiveTab ? editorBackground : colorFromHex(0x2d2d2d))
        if isActiveTab {
            canvas.fillRectangle(CGRect(x: tabX, y: 52, width: tabWidth, height: 2), color: accentBlue)
        }
        canvas.drawText(tabName, x: tabX + 16, centerY: 69, size: 12.5, color: isActiveTab ? colorFromHex(0xffffff) : secondaryText)
        canvas.drawText("x", x: tabX + tabWidth - 18, centerY: 69, size: 11, color: secondaryText)
        canvas.recordElement("vscode_tab_\(tabName)", CGRect(x: tabX, y: 52, width: tabWidth, height: 34))
        tabX += tabWidth
    }
    canvas.drawText("src  >  \(content.fileName)", x: 316, centerY: 98, size: 11.5, color: secondaryText)

    // Editor
    let lineHeight: CGFloat = 19
    let firstLineCenterY: CGFloat = 122
    let characterWidth = canvas.measureText("M", size: 13, isMonospaced: true)
    let codeOriginX: CGFloat = 372
    for (lineIndex, codeLine) in content.codeLines.prefix(21).enumerated() {
        let lineCenterY = firstLineCenterY + CGFloat(lineIndex) * lineHeight
        canvas.drawTextRightAligned("\(lineIndex + 1)", rightEdgeX: 346, centerY: lineCenterY, size: 12, color: colorFromHex(0x858585))
        drawHighlightedCodeLine(on: canvas, line: codeLine, x: codeOriginX, centerY: lineCenterY, fontSize: 13, isSwift: false, palette: vscodeDarkPalette)
        if lineIndex == content.errorLineIndex, let underlineColumns = content.errorUnderlineColumns {
            // Red squiggle under the offending characters.
            let squiggleStartX = codeOriginX + CGFloat(underlineColumns.lowerBound) * characterWidth
            let squiggleEndX = codeOriginX + CGFloat(underlineColumns.upperBound + 1) * characterWidth
            var squigglePoints: [CGPoint] = []
            var squiggleX = squiggleStartX
            var isUp = true
            while squiggleX <= squiggleEndX {
                squigglePoints.append(CGPoint(x: squiggleX, y: lineCenterY + 8 + (isUp ? 0 : 2.5)))
                squiggleX += 2.5
                isUp.toggle()
            }
            canvas.strokePolyline(squigglePoints, color: colorFromHex(0xf14c4c), lineWidth: 1.2)
            canvas.recordElement("vscode_error_squiggle", CGRect(x: squiggleStartX, y: lineCenterY - 9, width: squiggleEndX - squiggleStartX, height: 18))
        }
    }

    // Bottom panel
    canvas.drawLine(from: CGPoint(x: 300, y: 540), to: CGPoint(x: 1280, y: 540), color: colorFromHex(0x3c3c3c), lineWidth: 1)
    var panelTabX: CGFloat = 320
    let panelTabTitles = ["PROBLEMS", "OUTPUT", "DEBUG CONSOLE", "TERMINAL", "PORTS"]
    for panelTabTitle in panelTabTitles {
        let isActivePanelTab = (panelTabTitle == "PROBLEMS") == content.showProblemsPanel && (panelTabTitle == "PROBLEMS" || panelTabTitle == "TERMINAL")
        let titleWidth = canvas.drawText(panelTabTitle, x: panelTabX, centerY: 558, size: 11, color: isActivePanelTab ? colorFromHex(0xffffff) : secondaryText)
        var badgeWidth: CGFloat = 0
        if panelTabTitle == "PROBLEMS" {
            canvas.fillCircle(center: CGPoint(x: panelTabX + titleWidth + 12, y: 558), radius: 8, color: accentBlue)
            canvas.drawTextCentered("\(max(content.errorCount, 2))", centerX: panelTabX + titleWidth + 12, centerY: 558, size: 10, color: colorFromHex(0xffffff), isBold: true)
            badgeWidth = 24
        }
        if isActivePanelTab {
            canvas.fillRectangle(CGRect(x: panelTabX, y: 568, width: titleWidth + badgeWidth, height: 1), color: colorFromHex(0xe7e7e7))
        }
        canvas.recordElement("vscode_panel_tab_\(panelTabTitle.lowercased().replacingOccurrences(of: " ", with: "_"))",
                             CGRect(x: panelTabX - 8, y: 544, width: titleWidth + badgeWidth + 16, height: 28))
        panelTabX += titleWidth + badgeWidth + 28
    }
    if content.showProblemsPanel {
        canvas.drawText("v  \(content.fileName)  src  \(content.problemEntries.count)", x: 322, centerY: 590, size: 12, color: primaryText)
        for (entryIndex, entryText) in content.problemEntries.enumerated() {
            let entryCenterY = 612 + CGFloat(entryIndex) * 22
            canvas.fillCircle(center: CGPoint(x: 346, y: entryCenterY), radius: 6, color: colorFromHex(0xf14c4c))
            canvas.drawTextCentered("x", centerX: 346, centerY: entryCenterY - 1, size: 9, color: colorFromHex(0xffffff), isBold: true)
            canvas.drawText(entryText, x: 362, centerY: entryCenterY, size: 12, color: primaryText)
        }
    } else {
        for (terminalIndex, terminalLine) in content.terminalLines.suffix(9).enumerated() {
            canvas.drawText(terminalLine, x: 322, centerY: 592 + CGFloat(terminalIndex) * 17, size: 12, color: primaryText, isMonospaced: true)
        }
    }
    drawPlusIcon(on: canvas, centerX: 1184, centerY: 558, size: 11, color: primaryText, lineWidth: 1.4)
    canvas.recordElement("vscode_panel_new_terminal_button", CGRect(x: 1172, y: 546, width: 24, height: 24))

    // Status bar
    canvas.fillRectangle(CGRect(x: 0, y: 772, width: 1280, height: 28), color: accentBlue)
    let whiteText = colorFromHex(0xffffff)
    canvas.fillRectangle(CGRect(x: 0, y: 772, width: 56, height: 28), color: colorFromHex(0x16825d))
    drawBranchIcon(on: canvas, centerX: 12, centerY: 786, size: 13, color: whiteText)
    canvas.drawText("main", x: 24, centerY: 786, size: 12, color: whiteText)
    canvas.recordElement("vscode_status_branch", CGRect(x: 0, y: 772, width: 56, height: 28))
    canvas.drawText("x 2   ! 0", x: 70, centerY: 786, size: 12, color: whiteText)
    canvas.recordElement("vscode_status_errors", CGRect(x: 64, y: 772, width: 70, height: 28))
    canvas.drawTextRightAligned("Ln 14, Col 18     Spaces: 2     UTF-8     TypeScript", rightEdgeX: 1240, centerY: 786, size: 12, color: whiteText)

    return (canvas, fileName)
}

// MARK: - Terminal mock

struct TerminalMockLine {
    var text: String
    var color: UInt32 = 0xe5e5e5
    var elementName: String? = nil
}

func makeTerminalScreenshot(widthInPixels: Int, heightInPixels: Int, windowRectangle: CGRect, tabTitles: [String], lines: [TerminalMockLine]) -> MockScreenCanvas {
    let canvas = MockScreenCanvas(widthInPixels: widthInPixels, heightInPixels: heightInPixels)
    drawDesktopWallpaper(on: canvas)
    drawMacMenuBar(on: canvas, applicationName: "Terminal", menuTitles: ["Shell", "Edit", "View", "Window", "Help"])

    // Window shadow + body
    canvas.fillRoundedRectangle(windowRectangle.insetBy(dx: -3, dy: -3).offsetBy(dx: 0, dy: 6), cornerRadius: 14, color: colorFromHex(0x000000, alpha: 0.25))
    canvas.fillRoundedRectangle(windowRectangle, cornerRadius: 10, color: colorFromHex(0x1c1c1e))
    // Title bar + tab bar
    canvas.fillRoundedRectangle(CGRect(x: windowRectangle.minX, y: windowRectangle.minY, width: windowRectangle.width, height: 56), cornerRadius: 10, color: colorFromHex(0x2e2e30))
    canvas.fillRectangle(CGRect(x: windowRectangle.minX, y: windowRectangle.minY + 30, width: windowRectangle.width, height: 26), color: colorFromHex(0x2e2e30))
    drawTrafficLights(on: canvas, originX: windowRectangle.minX + 20, centerY: windowRectangle.minY + 15, elementPrefix: "terminal")
    canvas.drawTextCentered("samsto  --  zsh  --  110x34", centerX: windowRectangle.midX, centerY: windowRectangle.minY + 15, size: 12.5, color: colorFromHex(0xc9c9cc))

    var tabX = windowRectangle.minX + 8
    let tabWidth: CGFloat = 200
    for (tabIndex, tabTitle) in tabTitles.enumerated() {
        let isActiveTab = tabIndex == 0
        canvas.fillRoundedRectangle(CGRect(x: tabX, y: windowRectangle.minY + 32, width: tabWidth, height: 22), cornerRadius: 5, color: isActiveTab ? colorFromHex(0x4a4a4e) : colorFromHex(0x38383b))
        canvas.drawTextCentered(tabTitle, centerX: tabX + tabWidth / 2, centerY: windowRectangle.minY + 43, size: 12, color: colorFromHex(0xe5e5e5))
        canvas.recordElement("terminal_tab_\(tabIndex + 1)", CGRect(x: tabX, y: windowRectangle.minY + 32, width: tabWidth, height: 22))
        tabX += tabWidth + 6
    }
    let newTabCenterX = windowRectangle.maxX - 24
    drawPlusIcon(on: canvas, centerX: newTabCenterX, centerY: windowRectangle.minY + 43, size: 12, color: colorFromHex(0xc9c9cc), lineWidth: 1.6)
    canvas.recordElement("terminal_new_tab_button", CGRect(x: newTabCenterX - 13, y: windowRectangle.minY + 31, width: 26, height: 24))

    // Content
    let lineHeight: CGFloat = 18
    let contentOriginX = windowRectangle.minX + 14
    let contentTopY = windowRectangle.minY + 66
    let maxVisibleLines = Int((windowRectangle.height - 76) / lineHeight)
    let visibleLines = Array(lines.suffix(maxVisibleLines))
    for (lineIndex, line) in visibleLines.enumerated() {
        let lineCenterY = contentTopY + CGFloat(lineIndex) * lineHeight + lineHeight / 2
        let drawnWidth = canvas.drawText(line.text, x: contentOriginX, centerY: lineCenterY, size: 13, color: colorFromHex(line.color), isMonospaced: true)
        if let elementName = line.elementName {
            canvas.recordElement(elementName, CGRect(x: contentOriginX, y: lineCenterY - lineHeight / 2, width: max(drawnWidth, 40), height: lineHeight))
        }
    }
    // Block cursor after the last line
    let lastLineCenterY = contentTopY + CGFloat(max(visibleLines.count - 1, 0)) * lineHeight + lineHeight / 2
    let lastLineWidth = canvas.measureText(visibleLines.last?.text ?? "", size: 13, isMonospaced: true)
    canvas.fillRectangle(CGRect(x: contentOriginX + lastLineWidth + 2, y: lastLineCenterY - 8, width: 8, height: 16), color: colorFromHex(0xcfcfcf))
    return canvas
}

// MARK: - System Settings mock

func makeSettingsScreenshot() -> MockScreenCanvas {
    let canvas = MockScreenCanvas(widthInPixels: 1280, heightInPixels: 800)
    drawDesktopWallpaper(on: canvas)
    drawMacMenuBar(on: canvas, applicationName: "System Settings", menuTitles: ["File", "Edit", "View", "Window", "Help"])

    let windowRectangle = CGRect(x: 190, y: 70, width: 900, height: 660)
    canvas.fillRoundedRectangle(windowRectangle.insetBy(dx: -3, dy: -3).offsetBy(dx: 0, dy: 8), cornerRadius: 16, color: colorFromHex(0x000000, alpha: 0.25))
    canvas.fillRoundedRectangle(windowRectangle, cornerRadius: 12, color: colorFromHex(0xf6f6f8))
    // Sidebar
    canvas.fillRoundedRectangle(CGRect(x: windowRectangle.minX, y: windowRectangle.minY, width: 230, height: windowRectangle.height), cornerRadius: 12, color: colorFromHex(0xe6e6ea))
    canvas.fillRectangle(CGRect(x: windowRectangle.minX + 200, y: windowRectangle.minY, width: 30, height: windowRectangle.height), color: colorFromHex(0xe6e6ea))
    drawTrafficLights(on: canvas, originX: windowRectangle.minX + 22, centerY: windowRectangle.minY + 22, elementPrefix: "settings")

    let darkText = colorFromHex(0x1d1d1f)
    let grayText = colorFromHex(0x86868b)
    canvas.fillRoundedRectangle(CGRect(x: windowRectangle.minX + 14, y: windowRectangle.minY + 46, width: 202, height: 26), cornerRadius: 7, color: colorFromHex(0xd8d8dc))
    drawMagnifyingGlassIcon(on: canvas, centerX: windowRectangle.minX + 30, centerY: windowRectangle.minY + 59, size: 12, color: grayText)
    canvas.drawText("Search", x: windowRectangle.minX + 44, centerY: windowRectangle.minY + 59, size: 12.5, color: grayText)
    canvas.recordElement("settings_search_field", CGRect(x: windowRectangle.minX + 14, y: windowRectangle.minY + 46, width: 202, height: 26))

    canvas.fillCircle(center: CGPoint(x: windowRectangle.minX + 40, y: windowRectangle.minY + 108), radius: 18, color: colorFromHex(0x9aa0b4))
    canvas.drawText("Sam Sto", x: windowRectangle.minX + 66, centerY: windowRectangle.minY + 101, size: 13, color: darkText, isBold: true)
    canvas.drawText("Apple Account", x: windowRectangle.minX + 66, centerY: windowRectangle.minY + 117, size: 11, color: grayText)

    let sidebarItems: [(name: String, iconColor: UInt32)] = [
        ("Wi-Fi", 0x2f7cf6), ("Bluetooth", 0x2f7cf6), ("Network", 0x2f7cf6), ("Battery", 0x34c759), ("General", 0x8e8e93),
        ("Accessibility", 0x2f7cf6), ("Appearance", 0x1c1c1e), ("Control Center", 0x8e8e93), ("Desktop & Dock", 0x1c1c1e),
        ("Displays", 0x2f7cf6), ("Notifications", 0xff3b30), ("Sound", 0xff3b30), ("Focus", 0x5e5ce6),
        ("Lock Screen", 0x1c1c1e), ("Privacy & Security", 0x2f7cf6), ("Touch ID & Password", 0xff6b6b)
    ]
    for (itemIndex, item) in sidebarItems.enumerated() {
        let rowCenterY = windowRectangle.minY + 158 + CGFloat(itemIndex) * 31
        let isSelected = item.name == "Privacy & Security"
        if isSelected {
            canvas.fillRoundedRectangle(CGRect(x: windowRectangle.minX + 10, y: rowCenterY - 14, width: 210, height: 28), cornerRadius: 7, color: colorFromHex(0x2f7cf6))
        }
        canvas.fillRoundedRectangle(CGRect(x: windowRectangle.minX + 20, y: rowCenterY - 10, width: 20, height: 20), cornerRadius: 5, color: colorFromHex(item.iconColor))
        canvas.drawText(item.name, x: windowRectangle.minX + 50, centerY: rowCenterY, size: 13, color: isSelected ? colorFromHex(0xffffff) : darkText)
        let elementKey = item.name.lowercased().replacingOccurrences(of: " & ", with: "_and_").replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        canvas.recordElement("settings_sidebar_\(elementKey)", CGRect(x: windowRectangle.minX + 10, y: rowCenterY - 14, width: 210, height: 28))
    }

    // Main pane
    let paneX = windowRectangle.minX + 250
    drawChevron(on: canvas, centerX: paneX + 6, centerY: windowRectangle.minY + 30, size: 14, color: grayText, pointsRight: false)
    drawChevron(on: canvas, centerX: paneX + 30, centerY: windowRectangle.minY + 30, size: 14, color: grayText, pointsRight: true)
    canvas.drawText("Privacy & Security", x: paneX + 56, centerY: windowRectangle.minY + 30, size: 16, color: darkText, isBold: true)

    let privacyRows = [
        "Location Services", "Contacts", "Calendars", "Reminders", "Photos", "Bluetooth", "Microphone", "Camera",
        "Accessibility", "Screen & System Audio Recording", "Input Monitoring", "Full Disk Access"
    ]
    let groupTopY = windowRectangle.minY + 64
    let rowHeight: CGFloat = 40
    canvas.fillRoundedRectangle(CGRect(x: paneX, y: groupTopY, width: 624, height: rowHeight * CGFloat(privacyRows.count)), cornerRadius: 10, color: colorFromHex(0xffffff))
    for (rowIndex, rowTitle) in privacyRows.enumerated() {
        let rowCenterY = groupTopY + CGFloat(rowIndex) * rowHeight + rowHeight / 2
        if rowIndex > 0 {
            canvas.drawLine(from: CGPoint(x: paneX + 50, y: groupTopY + CGFloat(rowIndex) * rowHeight), to: CGPoint(x: paneX + 624, y: groupTopY + CGFloat(rowIndex) * rowHeight), color: colorFromHex(0xe3e3e6), lineWidth: 1)
        }
        canvas.fillRoundedRectangle(CGRect(x: paneX + 14, y: rowCenterY - 11, width: 22, height: 22), cornerRadius: 6, color: colorFromHex(rowIndex % 2 == 0 ? 0x2f7cf6 : 0x5e5ce6))
        canvas.drawText(rowTitle, x: paneX + 50, centerY: rowCenterY, size: 13.5, color: darkText)
        if rowIndex == 0 {
            canvas.drawTextRightAligned("On", rightEdgeX: paneX + 590, centerY: rowCenterY, size: 13, color: grayText)
        }
        drawChevron(on: canvas, centerX: paneX + 604, centerY: rowCenterY, size: 11, color: grayText)
        let elementKey = rowTitle.lowercased().replacingOccurrences(of: " & ", with: "_and_").replacingOccurrences(of: " ", with: "_")
        canvas.recordElement("settings_row_\(elementKey)", CGRect(x: paneX, y: rowCenterY - rowHeight / 2, width: 624, height: rowHeight))
    }
    return canvas
}

// MARK: - Browser mock

func makeBrowserScreenshot() -> MockScreenCanvas {
    let canvas = MockScreenCanvas(widthInPixels: 1280, heightInPixels: 800)
    drawDesktopWallpaper(on: canvas)
    drawMacMenuBar(on: canvas, applicationName: "Chrome", menuTitles: ["File", "Edit", "View", "History", "Bookmarks", "Profiles", "Tab", "Window", "Help"])

    let darkText = colorFromHex(0x202124)
    let grayText = colorFromHex(0x5f6368)
    canvas.fillRectangle(CGRect(x: 0, y: 22, width: 1280, height: 778), color: colorFromHex(0xffffff))
    // Tab strip
    canvas.fillRectangle(CGRect(x: 0, y: 22, width: 1280, height: 40), color: colorFromHex(0xdee1e6))
    drawTrafficLights(on: canvas, originX: 20, centerY: 42, elementPrefix: "browser")
    var tabX: CGFloat = 84
    for (tabIndex, tabTitle) in ["Workers & Pages - Console", "GitHub - clicky", "API docs"].enumerated() {
        let isActiveTab = tabIndex == 0
        canvas.fillRoundedRectangle(CGRect(x: tabX, y: 30, width: 210, height: 32), cornerRadius: 9, color: isActiveTab ? colorFromHex(0xffffff) : colorFromHex(0xdee1e6))
        canvas.fillCircle(center: CGPoint(x: tabX + 18, y: 46), radius: 6, color: colorFromHex(isActiveTab ? 0xf38020 : 0x8a8f98))
        canvas.drawText(tabTitle, x: tabX + 34, centerY: 46, size: 12.5, color: darkText)
        canvas.drawText("x", x: tabX + 190, centerY: 46, size: 11, color: grayText)
        canvas.recordElement("browser_tab_\(tabIndex + 1)", CGRect(x: tabX, y: 30, width: 210, height: 32))
        tabX += 214
    }
    drawPlusIcon(on: canvas, centerX: tabX + 14, centerY: 46, size: 12, color: grayText, lineWidth: 1.6)
    canvas.recordElement("browser_new_tab_button", CGRect(x: tabX, y: 32, width: 28, height: 28))

    // Toolbar
    drawChevron(on: canvas, centerX: 28, centerY: 82, size: 16, color: grayText, pointsRight: false)
    canvas.recordElement("browser_back_button", CGRect(x: 12, y: 66, width: 32, height: 32))
    drawChevron(on: canvas, centerX: 66, centerY: 82, size: 16, color: grayText, pointsRight: true)
    canvas.recordElement("browser_forward_button", CGRect(x: 50, y: 66, width: 32, height: 32))
    drawReloadIcon(on: canvas, centerX: 104, centerY: 82, size: 17, color: grayText)
    canvas.recordElement("browser_reload_button", CGRect(x: 88, y: 66, width: 32, height: 32))
    canvas.fillRoundedRectangle(CGRect(x: 134, y: 67, width: 980, height: 30), cornerRadius: 15, color: colorFromHex(0xf1f3f4))
    canvas.drawText("dash.example.com/workers/overview", x: 160, centerY: 82, size: 13.5, color: darkText)
    canvas.recordElement("browser_url_bar", CGRect(x: 134, y: 67, width: 980, height: 30))
    drawStarIcon(on: canvas, centerX: 1094, centerY: 82, size: 15, color: grayText)
    canvas.recordElement("browser_bookmark_star", CGRect(x: 1078, y: 68, width: 30, height: 28))
    canvas.fillCircle(center: CGPoint(x: 1196, y: 82), radius: 12, color: colorFromHex(0x7b61ff))
    canvas.recordElement("browser_profile_button", CGRect(x: 1182, y: 68, width: 28, height: 28))
    for dotIndex in 0..<3 {
        canvas.fillCircle(center: CGPoint(x: 1246, y: 74 + CGFloat(dotIndex) * 8), radius: 1.8, color: grayText)
    }
    canvas.recordElement("browser_menu_button", CGRect(x: 1232, y: 66, width: 28, height: 32))
    canvas.drawLine(from: CGPoint(x: 0, y: 104), to: CGPoint(x: 1280, y: 104), color: colorFromHex(0xdadce0), lineWidth: 1)

    // Page: left navigation
    canvas.fillRectangle(CGRect(x: 0, y: 105, width: 230, height: 695), color: colorFromHex(0xf7f7f8))
    canvas.drawLine(from: CGPoint(x: 230, y: 105), to: CGPoint(x: 230, y: 800), color: colorFromHex(0xe3e3e6), lineWidth: 1)
    let navigationItems = ["Home", "Workers & Pages", "R2 Storage", "Domains", "Analytics", "Settings", "Billing"]
    for (itemIndex, itemTitle) in navigationItems.enumerated() {
        let itemCenterY = 142 + CGFloat(itemIndex) * 40
        let isSelected = itemTitle == "Workers & Pages"
        if isSelected {
            canvas.fillRoundedRectangle(CGRect(x: 10, y: itemCenterY - 17, width: 210, height: 34), cornerRadius: 6, color: colorFromHex(0xfde8d6))
        }
        canvas.fillRoundedRectangle(CGRect(x: 22, y: itemCenterY - 8, width: 16, height: 16), cornerRadius: 4, color: colorFromHex(isSelected ? 0xf38020 : 0x9aa0a6))
        canvas.drawText(itemTitle, x: 50, centerY: itemCenterY, size: 13.5, color: darkText, isBold: isSelected)
        canvas.recordElement("browser_sidebar_\(itemTitle.lowercased().replacingOccurrences(of: " & ", with: "_and_").replacingOccurrences(of: " ", with: "_"))", CGRect(x: 10, y: itemCenterY - 17, width: 210, height: 34))
    }

    // Page: main content
    canvas.drawText("Account Home  >  Workers & Pages", x: 262, centerY: 138, size: 12, color: grayText)
    canvas.drawText("Workers & Pages", x: 262, centerY: 182, size: 28, color: darkText, isBold: true)
    canvas.fillRoundedRectangle(CGRect(x: 1050, y: 162, width: 190, height: 40), cornerRadius: 6, color: colorFromHex(0x0051c3))
    canvas.drawTextCentered("Create application", centerX: 1145, centerY: 182, size: 14, color: colorFromHex(0xffffff), isBold: true)
    canvas.recordElement("browser_create_application_button", CGRect(x: 1050, y: 162, width: 190, height: 40))

    var contentTabX: CGFloat = 262
    for tabTitle in ["Overview", "Metrics", "Logs", "Settings"] {
        let titleWidth = canvas.drawText(tabTitle, x: contentTabX, centerY: 246, size: 14, color: tabTitle == "Overview" ? darkText : grayText, isBold: tabTitle == "Overview")
        if tabTitle == "Overview" {
            canvas.fillRectangle(CGRect(x: contentTabX, y: 262, width: titleWidth, height: 2), color: colorFromHex(0xf38020))
        }
        canvas.recordElement("browser_tab_link_\(tabTitle.lowercased())", CGRect(x: contentTabX - 8, y: 232, width: titleWidth + 16, height: 32))
        contentTabX += titleWidth + 36
    }
    canvas.drawLine(from: CGPoint(x: 262, y: 264), to: CGPoint(x: 1240, y: 264), color: colorFromHex(0xe3e3e6), lineWidth: 1)

    canvas.strokeRoundedRectangle(CGRect(x: 262, y: 290, width: 978, height: 150), cornerRadius: 8, color: colorFromHex(0xdadce0), lineWidth: 1)
    canvas.drawText("Name", x: 284, centerY: 316, size: 12, color: grayText, isBold: true)
    canvas.drawText("Type", x: 560, centerY: 316, size: 12, color: grayText, isBold: true)
    canvas.drawText("Last deployed", x: 760, centerY: 316, size: 12, color: grayText, isBold: true)
    canvas.drawLine(from: CGPoint(x: 262, y: 334), to: CGPoint(x: 1240, y: 334), color: colorFromHex(0xe3e3e6), lineWidth: 1)
    let applicationRows = [("clicky-proxy", "Worker", "Today, 10:21 AM"), ("notes-sync", "Worker", "Nov 3, 4:05 PM"), ("landing-page", "Pages", "Oct 28, 9:12 AM")]
    for (rowIndex, rowValues) in applicationRows.enumerated() {
        let rowCenterY = 358 + CGFloat(rowIndex) * 34
        canvas.drawText(rowValues.0, x: 284, centerY: rowCenterY, size: 13.5, color: colorFromHex(0x0051c3), isBold: true)
        canvas.drawText(rowValues.1, x: 560, centerY: rowCenterY, size: 13.5, color: darkText)
        canvas.drawText(rowValues.2, x: 760, centerY: rowCenterY, size: 13.5, color: darkText)
        canvas.recordElement("browser_row_\(rowValues.0.replacingOccurrences(of: "-", with: "_"))", CGRect(x: 262, y: rowCenterY - 17, width: 978, height: 34))
    }
    canvas.drawText("Need help getting started? Read the Workers documentation.", x: 262, centerY: 490, size: 13.5, color: grayText)
    return canvas
}

// MARK: - Fixture content

let xcodeMainCode = [
    "import SwiftUI",
    "import AVFoundation",
    "",
    "@MainActor",
    "final class CompanionManager: ObservableObject {",
    "    @Published private(set) var voiceState: VoiceState = .idle",
    "    @Published var selectedModel: String = \"claude-sonnet-5-5\"",
    "",
    "    private let claudeAPI: ClaudeAPI",
    "    private var currentResponseTask: Task<Void, Never>?",
    "",
    "    init(claudeAPI: ClaudeAPI) {",
    "        self.claudeAPI = claudeAPI",
    "    }",
    "",
    "    func startListening() {",
    "        currentResponseTask?.cancel()",
    "        voiceState = .listening",
    "    }",
    "",
    "    func stopListening() {",
    "        voiceState = .processing",
    "        // send the transcript to the proxy and wait for the reply",
    "    }",
    "}"
]
let xcodeMainConsole = [
    "Clicker[4121:88201] Companion ready",
    "Clicker[4121:88201] Hotkey monitor started",
    "Clicker[4121:88201] Screen capture permission granted",
    "Clicker[4121:88201] Claude streaming request: 0.4MB, 1 image(s)",
    "Clicker[4121:88201] Companion received transcript: what is on my screen"
]

let mutatingCode = [
    "import Foundation",
    "",
    "struct VisitCounter {",
    "    var totalVisits = 0",
    "    var lastVisitDate: Date?",
    "",
    "    func recordVisit() {",
    "        totalVisits += 1",
    "        lastVisitDate = Date()",
    "    }",
    "",
    "    func summary() -> String {",
    "        return \"visits: \\(totalVisits)\"",
    "    }",
    "}",
    "",
    "let counter = VisitCounter()",
    "counter.recordVisit()",
    "print(counter.summary())"
]
let mainActorCode = [
    "import SwiftUI",
    "",
    "final class SettingsViewModel: ObservableObject {",
    "    @Published var statusText = \"idle\"",
    "",
    "    @MainActor",
    "    func refreshStatusText(with newText: String) {",
    "        statusText = newText",
    "    }",
    "",
    "    func loadSettingsFromDisk() {",
    "        let loadedText = readStatusFile()",
    "        refreshStatusText(with: loadedText)",
    "    }",
    "",
    "    private func readStatusFile() -> String {",
    "        return \"ready\"",
    "    }",
    "}"
]
let optionalCode = [
    "import Foundation",
    "",
    "struct UserProfile {",
    "    var fullName: String",
    "    var nickname: String?",
    "}",
    "",
    "func greeting(for user: UserProfile) -> String {",
    "    let displayName: String = user.nickname",
    "    return \"hello, \\(displayName)\"",
    "}",
    "",
    "let sam = UserProfile(fullName: \"Sam Sto\", nickname: nil)",
    "print(greeting(for: sam))"
]
let cartCode = [
    "import SwiftUI",
    "",
    "class CartModel {",
    "    var items: [String] = []",
    "",
    "    func add(_ item: String) {",
    "        items.append(item)",
    "    }",
    "}",
    "",
    "struct CartView: View {",
    "    let cartModel = CartModel()",
    "",
    "    var body: some View {",
    "        VStack {",
    "            Text(\"items: \\(cartModel.items.count)\")",
    "            Button(\"Add apple\") {",
    "                cartModel.add(\"apple\")",
    "            }",
    "        }",
    "    }",
    "}"
]

let workerTypeScriptCode = [
    "interface User {",
    "  id: string;",
    "  name: string;",
    "}",
    "",
    "const users: User[] = [",
    "  { id: \"a1\", name: \"Sam\" },",
    "  { id: \"b2\", name: \"Robin\" },",
    "];",
    "",
    "function getUserName(id: string): string {",
    "  const user = users.find((candidate) => candidate.id === id);",
    "  // look the user up by id",
    "  return user.name;",
    "}",
    "",
    "export default {",
    "  async fetch(request: Request): Promise<Response> {",
    "    const url = new URL(request.url);",
    "    const name = getUserName(url.searchParams.get(\"id\") ?? \"\");",
    "    return new Response(`hello ${name}`);",
    "  },",
    "};"
]
let workerPlainTerminal = [
    "samsto@mac clicker-worker % npx wrangler dev",
    " (wrangler 4.12.0)",
    "Ready on http://localhost:8787",
    "[wrangler:info] GET / 200 OK (4ms)",
    "[wrangler:info] GET /chat 405 Method Not Allowed (2ms)"
]

func buildFixtures() -> [String: MockScreenCanvas] {
    var fixtures: [String: MockScreenCanvas] = [:]

    fixtures["xcode_main.jpg"] = makeXcodeScreenshot(fileName: "CompanionManager.swift", content: XcodeMockContent(
        selectedFileName: "CompanionManager.swift", codeLines: xcodeMainCode, consoleLines: xcodeMainConsole)).0

    fixtures["xcode_error_mutating.jpg"] = makeXcodeScreenshot(fileName: "VisitCounter.swift", content: XcodeMockContent(
        selectedFileName: "VisitCounter.swift", codeLines: mutatingCode, errorLineIndexes: [7, 8],
        errorMessage: "Cannot assign to property: 'self' is immutable",
        toolbarStatusText: "Build Failed", toolbarStatusIsError: true,
        consoleLines: ["error: Build failed with 2 errors"])).0

    fixtures["xcode_error_mainactor.jpg"] = makeXcodeScreenshot(fileName: "SettingsViewModel.swift", content: XcodeMockContent(
        selectedFileName: "SettingsViewModel.swift", codeLines: mainActorCode, errorLineIndexes: [12],
        errorMessage: "Call to main actor-isolated instance method 'refreshStatusText(with:)' in a synchronous nonisolated context",
        toolbarStatusText: "Build Failed", toolbarStatusIsError: true,
        consoleLines: ["error: Build failed with 1 error"])).0

    fixtures["xcode_error_optional.jpg"] = makeXcodeScreenshot(fileName: "UserProfile.swift", content: XcodeMockContent(
        selectedFileName: "UserProfile.swift", codeLines: optionalCode, errorLineIndexes: [8],
        errorMessage: "Value of optional type 'String?' must be unwrapped to a value of type 'String'",
        toolbarStatusText: "Build Failed", toolbarStatusIsError: true,
        consoleLines: ["error: Build failed with 1 error"])).0

    fixtures["xcode_swiftui_state.jpg"] = makeXcodeScreenshot(fileName: "CartView.swift", content: XcodeMockContent(
        selectedFileName: "CartView.swift", codeLines: cartCode,
        consoleLines: ["Clicker[5102:91133] app launched", "Clicker[5102:91133] tapped Add apple", "Clicker[5102:91133] tapped Add apple"])).0

    fixtures["vscode_main.jpg"] = makeVSCodeScreenshot(fileName: "index.ts", content: VSCodeMockContent(
        fileName: "index.ts", codeLines: workerTypeScriptCode, terminalLines: workerPlainTerminal, errorCount: 2)).0

    fixtures["vscode_error_ts.jpg"] = makeVSCodeScreenshot(fileName: "index.ts", content: VSCodeMockContent(
        fileName: "index.ts", codeLines: workerTypeScriptCode, errorLineIndex: 13, errorUnderlineColumns: 9...12,
        problemEntries: ["'user' is possibly 'undefined'. ts(18048)   [Ln 14, Col 10]"],
        showProblemsPanel: true, errorCount: 1)).0

    let terminalWindow = CGRect(x: 110, y: 60, width: 1060, height: 700)
    fixtures["terminal_main.jpg"] = makeTerminalScreenshot(widthInPixels: 1280, heightInPixels: 800, windowRectangle: terminalWindow,
        tabTitles: ["clicky -- zsh", "worker -- node"], lines: [
            TerminalMockLine(text: "samsto@mac clicky % git status"),
            TerminalMockLine(text: "On branch main"),
            TerminalMockLine(text: "Your branch is ahead of 'origin/main' by 1 commit."),
            TerminalMockLine(text: "  (use \"git push\" to publish your local commits)"),
            TerminalMockLine(text: ""),
            TerminalMockLine(text: "Changes not staged for commit:"),
            TerminalMockLine(text: "        modified:   NotesStore.swift", color: 0xff6b6b),
            TerminalMockLine(text: ""),
            TerminalMockLine(text: "samsto@mac clicky % git log --oneline -3"),
            TerminalMockLine(text: "a41b9d2 (HEAD -> main) wip: add notes folder"),
            TerminalMockLine(text: "7c03e1f fix tts playback cutting off"),
            TerminalMockLine(text: "e5d2210 import clicky with locked-down worker"),
            TerminalMockLine(text: "samsto@mac clicky % swift build"),
            TerminalMockLine(text: "Compiling Swift Module 'clicky' (12 sources)"),
            TerminalMockLine(text: "/Users/samsto/clicky/NotesStore.swift:18:31: error: cannot find 'notesFolderURL' in scope", color: 0xff6b6b, elementName: "terminal_error_line"),
            TerminalMockLine(text: "        let fileURL = notesFolderURL.appendingPathComponent(fileName)"),
            TerminalMockLine(text: "                      ^~~~~~~~~~~~~~"),
            TerminalMockLine(text: "samsto@mac clicky % ")
        ])

    fixtures["terminal_second.jpg"] = makeTerminalScreenshot(widthInPixels: 1280, heightInPixels: 720, windowRectangle: CGRect(x: 120, y: 56, width: 1040, height: 610),
        tabTitles: ["server -- zsh", "logs -- tail"], lines: [
            TerminalMockLine(text: "samsto@mac server % tail -f app.log"),
            TerminalMockLine(text: "10:40:12 INFO  listening on port 8080"),
            TerminalMockLine(text: "10:40:31 INFO  GET /health 200"),
            TerminalMockLine(text: "10:41:02 WARN  slow response: 1204ms")
        ])

    fixtures["terminal_git_push_rejected.jpg"] = makeTerminalScreenshot(widthInPixels: 1280, heightInPixels: 800, windowRectangle: terminalWindow,
        tabTitles: ["clicky -- zsh", "worker -- node"], lines: [
            TerminalMockLine(text: "samsto@mac clicky % git add -A && git commit -m \"add notes feature\""),
            TerminalMockLine(text: "[main 3f9c2a1] add notes feature"),
            TerminalMockLine(text: " 4 files changed, 120 insertions(+), 8 deletions(-)"),
            TerminalMockLine(text: "samsto@mac clicky % git push origin main"),
            TerminalMockLine(text: "To github.com:samsto/clicky.git"),
            TerminalMockLine(text: " ! [rejected]        main -> main (fetch first)", color: 0xff6b6b),
            TerminalMockLine(text: "error: failed to push some refs to 'github.com:samsto/clicky.git'", color: 0xff6b6b),
            TerminalMockLine(text: "hint: Updates were rejected because the remote contains work that you do not", color: 0xe5c07b),
            TerminalMockLine(text: "hint: have locally. This is usually caused by another repository pushing to", color: 0xe5c07b),
            TerminalMockLine(text: "hint: the same ref. If you want to integrate the remote changes, use", color: 0xe5c07b),
            TerminalMockLine(text: "hint: 'git pull' before pushing again.", color: 0xe5c07b),
            TerminalMockLine(text: "samsto@mac clicky % ")
        ])

    fixtures["terminal_py_error.jpg"] = makeTerminalScreenshot(widthInPixels: 1280, heightInPixels: 800, windowRectangle: terminalWindow,
        tabTitles: ["scripts -- zsh", "worker -- node"], lines: [
            TerminalMockLine(text: "samsto@mac scripts % python3 fetch_prices.py"),
            TerminalMockLine(text: "Traceback (most recent call last):", color: 0xff6b6b),
            TerminalMockLine(text: "  File \"/Users/samsto/scripts/fetch_prices.py\", line 1, in <module>"),
            TerminalMockLine(text: "    import requests"),
            TerminalMockLine(text: "ModuleNotFoundError: No module named 'requests'", color: 0xff6b6b),
            TerminalMockLine(text: "samsto@mac scripts % ")
        ])

    fixtures["terminal_port_in_use.jpg"] = makeTerminalScreenshot(widthInPixels: 1280, heightInPixels: 800, windowRectangle: terminalWindow,
        tabTitles: ["worker -- node", "clicky -- zsh"], lines: [
            TerminalMockLine(text: "samsto@mac worker % npm run dev"),
            TerminalMockLine(text: ""),
            TerminalMockLine(text: "> clicky-proxy@1.0.0 dev"),
            TerminalMockLine(text: "> node server.js"),
            TerminalMockLine(text: ""),
            TerminalMockLine(text: "node:events:497"),
            TerminalMockLine(text: "      throw er; // Unhandled 'error' event"),
            TerminalMockLine(text: "      ^"),
            TerminalMockLine(text: ""),
            TerminalMockLine(text: "Error: listen EADDRINUSE: address already in use :::3000", color: 0xff6b6b),
            TerminalMockLine(text: "    at Server.setupListenIncoming (node:net:1940:16)"),
            TerminalMockLine(text: "    at listenInCluster (node:net:1997:12)"),
            TerminalMockLine(text: "Emitted 'error' event on Server instance at:"),
            TerminalMockLine(text: "  code: 'EADDRINUSE',"),
            TerminalMockLine(text: "  errno: -48,"),
            TerminalMockLine(text: "  syscall: 'listen',"),
            TerminalMockLine(text: "  port: 3000"),
            TerminalMockLine(text: "samsto@mac worker % ")
        ])

    fixtures["settings_main.jpg"] = makeSettingsScreenshot()
    fixtures["browser_main.jpg"] = makeBrowserScreenshot()
    return fixtures
}

// MARK: - Entry point

let fixturesDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures")
try FileManager.default.createDirectory(at: fixturesDirectoryURL, withIntermediateDirectories: true)

var manifestFixtures: [String: Any] = [:]
for (fileName, canvas) in buildFixtures().sorted(by: { $0.key < $1.key }) {
    canvas.saveAsJPEG(to: fixturesDirectoryURL.appendingPathComponent(fileName))
    var elementsJSON: [String: Any] = [:]
    for (elementName, rectangle) in canvas.elementBoxesByName {
        elementsJSON[elementName] = [
            "x": Int(rectangle.minX.rounded()), "y": Int(rectangle.minY.rounded()),
            "w": Int(rectangle.width.rounded()), "h": Int(rectangle.height.rounded())
        ]
    }
    manifestFixtures[fileName] = ["width": canvas.widthInPixels, "height": canvas.heightInPixels, "elements": elementsJSON]
    print("wrote \(fileName) (\(canvas.widthInPixels)x\(canvas.heightInPixels), \(canvas.elementBoxesByName.count) elements)")
}
let manifestData = try JSONSerialization.data(withJSONObject: ["fixtures": manifestFixtures], options: [.prettyPrinted, .sortedKeys])
try manifestData.write(to: fixturesDirectoryURL.appendingPathComponent("manifest.json"))
print("wrote manifest.json")
