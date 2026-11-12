import Foundation

/// One `[DRAW:...]`, `[CARD:...]`, `[ROW:...]`, `[SCENE:...]` or `[PART:...]` tag of a reply, with
/// where it sits in the spoken text.
nonisolated struct ClickyParsedDrawCommand: Equatable {
    let command: ClickyDrawCommand
    /// How much of the spoken text comes before this tag, from 0 (the tag opens the reply) to 1
    /// (the tag follows the last spoken word). The schedule multiplies it by the length of the
    /// audio, so a mark is drawn as the sentence before it ends.
    let spokenFractionBeforeTag: Double
}

nonisolated struct ClickyParsedDrawReply: Equatable {
    /// In the order they were written. At most `ClickyDrawTagParser.maximumDrawTagCountPerReply`
    /// from `[DRAW:...]` tags, plus at most one card and the rows that fit on it, plus at most one
    /// 3D scene and the parts that fit in it.
    let commands: [ClickyParsedDrawCommand]
    /// Draw, card, row, scene and part tags that were dropped: malformed, out of range, past a
    /// limit, a row with no card to go on, or a part with no scene to go in. They are still removed from the spoken text by `ClickyReplyTagParser`.
    let ignoredDrawTagCount: Int
}

/// Reads the `[DRAW:...]` tags Claude writes between the sentences of a draw reply.
///
/// The grammar (case-insensitive; coordinates are pixels of the labeled screenshot, the same space
/// `[POINT]` uses; an optional last `:screenN` picks another screen):
/// - `[DRAW:arrow:x1,y1:x2,y2]` from tail to head
/// - `[DRAW:circle:x,y:radius]`
/// - `[DRAW:box:x,y:width,height]`
/// - `[DRAW:underline:x1,y1:x2,y2]`
/// - `[DRAW:highlight:x,y:width,height]`
/// - `[DRAW:label:x,y:text]`
/// - `[DRAW:sticky:x,y:text]`
/// - `[DRAW:callout:x,y:text]` a numbered tag pointing at x,y; the numbers run 1, 2, 3 in a reply
/// - `[DRAW:erase:m3]`, `[DRAW:undo]`, `[DRAW:clear]`
///
/// An explanation card has tags of its own, which do not count towards the draw tag limit:
/// - `[CARD:title]` opens a card (one per reply; it replaces a card already on screen)
/// - `[ROW:text:words]`, `[ROW:boxes:a|b|c -> d]`, `[ROW:flow:a > b > c]`,
///   `[ROW:timeline:when=what|when=what]` add a row to the card opened in this reply, or to the
///   card already on screen
///
/// A simple 3D scene has tags of its own too, which do not count towards the draw tag limit either:
/// - `[SCENE:title]` opens a scene (one per reply; it replaces a scene already on screen)
/// - `[PART:shape:label:x,y,z:size:colour]` with an optional last `:axis` adds a part to the scene
///   opened in this reply, or to the scene already on screen. shape is box, cylinder, sphere,
///   cone, tube or capsule; the label may be empty; size is `w,h,d` for a box, `radius` for a
///   sphere and `radius,length` for the others; axis is x, y or z (default y, up)
///
/// This parser only finds and validates draw tags. Removing them from the spoken text stays the
/// job of `ClickyReplyTagParser`, which knows the tag name so they are never read aloud.
nonisolated enum ClickyDrawTagParser {
    /// A reply is at most four short sentences, so eight marks is already a busy drawing. More
    /// than that is most likely a runaway reply, and the extra tags are ignored.
    static let maximumDrawTagCountPerReply = 8

    /// A label is a word or two next to a mark. Longer text is cut, not rejected, like notes are.
    static let maximumLabelCharacterCount = 40

    /// A sticky note holds a sentence. Longer text is cut.
    static let maximumStickyNoteCharacterCount = 120

    /// Screenshots are at most 1280 pixels on their long side. A coordinate far beyond any
    /// screenshot is a mistake and not a place, so the tag is dropped instead of being clamped to
    /// an edge the model never meant. Values inside this limit but outside the actual screenshot
    /// are clamped later, the same way `[POINT]` coordinates are.
    static let maximumAcceptedCoordinate: Double = 10_000

    /// A circle smaller than this is a dot, and one larger than this cannot be seen as a circle on
    /// any screenshot.
    static let minimumCircleRadius: Double = 2
    static let maximumCircleRadius: Double = 5_000

    /// The pattern of one complete draw, card or row tag. Group 1 is the tag name and group 2 is
    /// everything after its colon. Brackets are excluded from the body so one tag can never
    /// swallow the next.
    private static let completeDrawTagPattern = "\\[\\s*(DRAW|CARD|ROW|SCENE|PART)\\s*:([^\\[\\]]*)\\]"

    private struct DrawTagOccurrence {
        let rangeInReplyText: Range<String.Index>
        /// nil when the tag was malformed, out of range, or past the per-reply limit.
        let command: ClickyDrawCommand?
    }

    /// `rowCountOfCardAlreadyOnScreen` is how many rows the explanation card on the screen has, or
    /// nil when no card is on the screen. A `[ROW:...]` tag needs a card to go on: the one opened
    /// earlier in the same reply, or else the one on screen.
    ///
    /// `partCountOfSceneAlreadyOnScreen` is the same for a `[PART:...]` tag and the 3D scene: how
    /// many parts the scene on the screen has, or nil when no scene is on the screen.
    static func parse(
        _ rawReplyText: String,
        rowCountOfCardAlreadyOnScreen: Int? = nil,
        partCountOfSceneAlreadyOnScreen: Int? = nil
    ) -> ClickyParsedDrawReply {
        let drawTagOccurrences = drawTagOccurrences(
            in: rawReplyText,
            rowCountOfCardAlreadyOnScreen: rowCountOfCardAlreadyOnScreen,
            partCountOfSceneAlreadyOnScreen: partCountOfSceneAlreadyOnScreen
        )
        guard !drawTagOccurrences.isEmpty else {
            return ClickyParsedDrawReply(commands: [], ignoredDrawTagCount: 0)
        }

        // The spoken text is measured with the same parser that produces it, so the fraction
        // matches what the voice will actually say.
        let totalSpokenCharacterCount = ClickyReplyTagParser.parse(rawReplyText).spokenText.count

        var parsedCommands: [ClickyParsedDrawCommand] = []
        var ignoredDrawTagCount = 0
        for drawTagOccurrence in drawTagOccurrences {
            guard let command = drawTagOccurrence.command else {
                ignoredDrawTagCount += 1
                continue
            }

            let replyTextBeforeTag = String(rawReplyText[..<drawTagOccurrence.rangeInReplyText.lowerBound])
            let spokenCharacterCountBeforeTag = ClickyReplyTagParser.parse(replyTextBeforeTag).spokenText.count
            let spokenFractionBeforeTag: Double
            if totalSpokenCharacterCount > 0 {
                spokenFractionBeforeTag = min(1, Double(spokenCharacterCountBeforeTag) / Double(totalSpokenCharacterCount))
            } else {
                spokenFractionBeforeTag = 0
            }
            parsedCommands.append(ClickyParsedDrawCommand(command: command, spokenFractionBeforeTag: spokenFractionBeforeTag))
        }

        return ClickyParsedDrawReply(commands: parsedCommands, ignoredDrawTagCount: ignoredDrawTagCount)
    }

    /// Reads the body of one draw tag (everything after "DRAW:"), such as "circle:120,11:34" or
    /// "undo". Returns nil for anything that is not exactly one of the documented forms.
    ///
    /// `calloutNumber` is the number a callout gets if this tag is one; the caller counts them.
    static func command(fromTagBody tagBody: String, calloutNumber: Int = 1) -> ClickyDrawCommand? {
        // The untrimmed pieces are kept as well: the text of a label is put back together from
        // them, so "step 1: open it" keeps the space after its colon.
        var untrimmedColonSeparatedComponents = tagBody
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0) }
        var colonSeparatedComponents = untrimmedColonSeparatedComponents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let kindComponent = colonSeparatedComponents.first else {
            return nil
        }
        let kindName = kindComponent.lowercased()

        switch kindName {
        case "undo":
            return colonSeparatedComponents.count == 1 ? .undoNewestMark : nil
        case "clear":
            return colonSeparatedComponents.count == 1 ? .clearAllMarks : nil
        case "erase":
            guard colonSeparatedComponents.count == 2,
                  let markIdentifier = markIdentifier(fromComponent: colonSeparatedComponents[1]) else {
                return nil
            }
            return .eraseMark(markIdentifier: markIdentifier)
        default:
            break
        }

        let kindHoldsText = kindName == "label" || kindName == "sticky" || kindName == "callout"

        // A trailing "screenN" picks the screen. For a label or sticky note it only counts when
        // some text is left before it, so a label that says just "screen 2" keeps its text.
        var screenNumber: Int?
        let minimumComponentCountWithScreenSuffix = 4
        if colonSeparatedComponents.count >= minimumComponentCountWithScreenSuffix,
           let lastComponent = colonSeparatedComponents.last,
           let screenNumberFromLastComponent = self.screenNumber(fromComponent: lastComponent) {
            screenNumber = screenNumberFromLastComponent
            colonSeparatedComponents.removeLast()
            untrimmedColonSeparatedComponents.removeLast()
        }

        guard colonSeparatedComponents.count >= 3,
              let firstPoint = point(fromComponent: colonSeparatedComponents[1]) else {
            return nil
        }

        if kindHoldsText {
            // The text may itself contain colons, so everything after the position is rejoined.
            let rejoinedText = untrimmedColonSeparatedComponents.dropFirst(2).joined(separator: ":")
            let maximumCharacterCount: Int
            switch kindName {
            case "label": maximumCharacterCount = maximumLabelCharacterCount
            case "callout": maximumCharacterCount = ClickyCalloutPlacement.maximumCalloutCharacterCount
            default: maximumCharacterCount = maximumStickyNoteCharacterCount
            }
            let markText = singleLineText(rejoinedText, cutToCharacterCount: maximumCharacterCount)
            guard !markText.isEmpty else {
                return nil
            }
            let shape: ClickyDrawingShape
            switch kindName {
            case "label": shape = .label(topLeftCorner: firstPoint, text: markText)
            case "callout": shape = .callout(target: firstPoint, text: markText, calloutNumber: calloutNumber)
            default: shape = .stickyNote(topLeftCorner: firstPoint, text: markText)
            }
            return .addMark(shape: shape, screenNumber: screenNumber)
        }

        // Every other shape is exactly: kind, a position, and one more group of numbers.
        guard colonSeparatedComponents.count == 3 else {
            return nil
        }
        let secondComponent = colonSeparatedComponents[2]

        switch kindName {
        case "arrow", "underline":
            // A line needs two different ends: with both in one place there is no direction for
            // an arrowhead and nothing to underline.
            guard let secondPoint = point(fromComponent: secondComponent), secondPoint != firstPoint else {
                return nil
            }
            let shape: ClickyDrawingShape = kindName == "arrow"
                ? .arrow(tail: firstPoint, head: secondPoint)
                : .underline(start: firstPoint, end: secondPoint)
            return .addMark(shape: shape, screenNumber: screenNumber)

        case "circle":
            guard let radius = Double(secondComponent), radius.isFinite,
                  radius >= minimumCircleRadius, radius <= maximumCircleRadius else {
                return nil
            }
            return .addMark(shape: .circle(center: firstPoint, radius: radius), screenNumber: screenNumber)

        case "box", "highlight":
            guard let size = size(fromComponent: secondComponent) else {
                return nil
            }
            let shape: ClickyDrawingShape = kindName == "box"
                ? .box(topLeftCorner: firstPoint, size: size)
                : .highlight(topLeftCorner: firstPoint, size: size)
            return .addMark(shape: shape, screenNumber: screenNumber)

        default:
            return nil
        }
    }

    /// The tag exactly as the grammar writes it, with whole-pixel coordinates. Used for the
    /// conversation history, so what the model reads back is the documented format and stays short.
    static func canonicalTagText(for drawCommand: ClickyDrawCommand) -> String {
        switch drawCommand {
        case .undoNewestMark:
            return "[DRAW:undo]"
        case .clearAllMarks:
            return "[DRAW:clear]"
        case .eraseMark(let markIdentifier):
            return "[DRAW:erase:\(markIdentifier)]"
        case .addCardRow(let row):
            return "[ROW:\(row.canonicalTagBody)]"
        case .addScenePart(let part):
            return "[PART:\(part.canonicalTagBody)]"
        case .addMark(.scene(let scene), _):
            // A scene is opened by its title alone; its parts are tags of their own.
            return "[SCENE:\(scene.title)]"
        case .addMark(.explanationCard(let card), _):
            // A card is opened by its title alone; its rows are tags of their own.
            return "[CARD:\(card.title)]"
        case .addMark(let shape, let screenNumber):
            let coordinateText = ClickyDrawingMarksOnScreenText.coordinateText
            let wholeNumberText = ClickyDrawingMarksOnScreenText.wholeNumberText
            let tagBodyAfterKind: String
            switch shape {
            case .arrow(let tail, let head):
                tagBodyAfterKind = "\(coordinateText(tail)):\(coordinateText(head))"
            case .underline(let start, let end):
                tagBodyAfterKind = "\(coordinateText(start)):\(coordinateText(end))"
            case .circle(let center, let radius):
                tagBodyAfterKind = "\(coordinateText(center)):\(wholeNumberText(radius))"
            case .box(let topLeftCorner, let size), .highlight(let topLeftCorner, let size):
                tagBodyAfterKind = "\(coordinateText(topLeftCorner)):\(wholeNumberText(size.width)),\(wholeNumberText(size.height))"
            case .label(let topLeftCorner, let text), .stickyNote(let topLeftCorner, let text):
                tagBodyAfterKind = "\(coordinateText(topLeftCorner)):\(text)"
            case .callout(let target, let text, _):
                // The number is not written: it comes from the tag's place in the reply.
                tagBodyAfterKind = "\(coordinateText(target)):\(text)"
            case .explanationCard(let card):
                tagBodyAfterKind = card.title
            case .scene(let scene):
                tagBodyAfterKind = scene.title
            }
            let screenSuffix = screenNumber.map { ":screen\($0)" } ?? ""
            return "[DRAW:\(shape.tagKindName):\(tagBodyAfterKind)\(screenSuffix)]"
        }
    }

    /// What goes into the conversation history for a reply that drew something.
    ///
    /// The turn finisher's history text holds the spoken words and the memory tags, with every draw
    /// tag stripped. Draw tags are put back (as `[NOTE:]` tags are kept) so the model sees its own
    /// earlier drawing in the documented format and keeps using it. When the finisher spoke the
    /// reply's words unchanged, each tag goes back after the sentence it followed, which is the
    /// shape of a draw reply. When the finisher rewrote the words (a memory refusal, for example),
    /// the sentence positions no longer mean anything, so the tags are appended at the end.
    ///
    /// A reply without valid draw tags returns the finisher's text untouched, so an ordinary
    /// turn's history is exactly what it was.
    static func historyAssistantText(
        rawReplyText: String,
        finishedSpokenText: String,
        finishedHistoryAssistantText: String,
        rowCountOfCardAlreadyOnScreen: Int? = nil,
        partCountOfSceneAlreadyOnScreen: Int? = nil
    ) -> String {
        let drawTagOccurrences = drawTagOccurrences(
            in: rawReplyText,
            rowCountOfCardAlreadyOnScreen: rowCountOfCardAlreadyOnScreen,
            partCountOfSceneAlreadyOnScreen: partCountOfSceneAlreadyOnScreen
        )
        let canonicalTagTexts = drawTagOccurrences.compactMap { drawTagOccurrence in
            drawTagOccurrence.command.map { canonicalTagText(for: $0) }
        }
        guard !canonicalTagTexts.isEmpty else {
            return finishedHistoryAssistantText
        }

        // The finisher speaks the reply without markdown marks but keeps them in history, so the
        // spoken text is compared without the marks and the history text with them.
        let parsedReplyAsWritten = ClickyReplyTagParser.parse(rawReplyText)
        let historyReplyTextAsWritten = parsedReplyAsWritten.spokenTextAsWritten
        let finisherKeptTheWordsAsWritten = finishedSpokenText == parsedReplyAsWritten.spokenText
            && finishedHistoryAssistantText.hasPrefix(historyReplyTextAsWritten)
        guard finisherKeptTheWordsAsWritten else {
            return ([finishedHistoryAssistantText] + canonicalTagTexts)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        // Walk the reply: the words between two draw tags, then the tag that followed them.
        var historyPieces: [String] = []
        var nextUnreadIndex = rawReplyText.startIndex
        for drawTagOccurrence in drawTagOccurrences {
            let replyTextBeforeTag = String(rawReplyText[nextUnreadIndex..<drawTagOccurrence.rangeInReplyText.lowerBound])
            historyPieces.append(ClickyReplyTagParser.parse(replyTextBeforeTag).spokenTextAsWritten)
            if let command = drawTagOccurrence.command {
                historyPieces.append(canonicalTagText(for: command))
            }
            nextUnreadIndex = drawTagOccurrence.rangeInReplyText.upperBound
        }
        historyPieces.append(ClickyReplyTagParser.parse(String(rawReplyText[nextUnreadIndex...])).spokenTextAsWritten)

        // Whatever the finisher added after the spoken words: the saved [NOTE:] and [PROFILE:] tags.
        let memoryTagsKeptByTheFinisher = String(finishedHistoryAssistantText.dropFirst(historyReplyTextAsWritten.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        historyPieces.append(memoryTagsKeptByTheFinisher)

        return historyPieces
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Finding the tags

    /// Every complete draw, card, row, scene and part tag of the reply, in order, each with its
    /// command or nil.
    /// The limits are applied here so parsing and the history text always agree on which tags count.
    private static func drawTagOccurrences(
        in rawReplyText: String,
        rowCountOfCardAlreadyOnScreen: Int?,
        partCountOfSceneAlreadyOnScreen: Int?
    ) -> [DrawTagOccurrence] {
        let completeDrawTagRegex = try! NSRegularExpression(pattern: completeDrawTagPattern, options: [.caseInsensitive])
        let completeDrawTagMatches = completeDrawTagRegex.matches(
            in: rawReplyText,
            range: NSRange(rawReplyText.startIndex..., in: rawReplyText)
        )

        var drawTagOccurrences: [DrawTagOccurrence] = []
        var acceptedDrawCommandCount = 0
        var nextCalloutNumber = 1
        var hasOpenedACardInThisReply = false
        // How many rows the card a `[ROW:...]` tag would go on has at this point of the reply.
        // nil while there is no card for a row to go on.
        var rowCountOfCardRowsGoOn = rowCountOfCardAlreadyOnScreen
        var hasOpenedASceneInThisReply = false
        // The same for a `[PART:...]` tag: how many parts the scene it would go in has at this
        // point of the reply, nil while there is no scene.
        var partCountOfScenePartsGoIn = partCountOfSceneAlreadyOnScreen

        for completeDrawTagMatch in completeDrawTagMatches {
            guard let rangeInReplyText = Range(completeDrawTagMatch.range, in: rawReplyText),
                  let tagNameRange = Range(completeDrawTagMatch.range(at: 1), in: rawReplyText),
                  let tagBodyRange = Range(completeDrawTagMatch.range(at: 2), in: rawReplyText) else {
                continue
            }
            let tagName = rawReplyText[tagNameRange].uppercased()
            let tagBody = String(rawReplyText[tagBodyRange])

            var command: ClickyDrawCommand?
            switch tagName {
            case "CARD":
                // One card per reply: a second one would replace the first while its rows are
                // still being spoken about.
                if !hasOpenedACardInThisReply, let cardTitle = cardTitle(fromTagBody: tagBody) {
                    command = .addMark(shape: .explanationCard(ClickyExplanationCard(title: cardTitle, rows: [])), screenNumber: nil)
                    hasOpenedACardInThisReply = true
                    rowCountOfCardRowsGoOn = 0
                }

            case "ROW":
                if let rowCountSoFar = rowCountOfCardRowsGoOn,
                   rowCountSoFar < ClickyExplanationCard.maximumRowCount,
                   let cardRow = cardRow(fromTagBody: tagBody) {
                    command = .addCardRow(cardRow)
                    rowCountOfCardRowsGoOn = rowCountSoFar + 1
                }

            case "SCENE":
                // One scene per reply, for the reason there is one card per reply: a second one
                // would replace the first while its parts are still being spoken about.
                if !hasOpenedASceneInThisReply, let sceneTitle = sceneTitle(fromTagBody: tagBody) {
                    command = .addMark(shape: .scene(ClickyScene(title: sceneTitle, parts: [])), screenNumber: nil)
                    hasOpenedASceneInThisReply = true
                    partCountOfScenePartsGoIn = 0
                }

            case "PART":
                if let partCountSoFar = partCountOfScenePartsGoIn,
                   partCountSoFar < ClickyScene.maximumPartCount,
                   let scenePart = scenePart(fromTagBody: tagBody) {
                    command = .addScenePart(scenePart)
                    partCountOfScenePartsGoIn = partCountSoFar + 1
                }

            default:
                command = self.command(fromTagBody: tagBody, calloutNumber: nextCalloutNumber)
                if command != nil {
                    if acceptedDrawCommandCount >= maximumDrawTagCountPerReply {
                        command = nil
                    } else {
                        acceptedDrawCommandCount += 1
                    }
                }
                if case .addMark(.callout, _) = command {
                    nextCalloutNumber += 1
                }
                if case .clearAllMarks = command {
                    // The card went with everything else, so a later row has nothing to go on.
                    // The same for the scene and a later part.
                    rowCountOfCardRowsGoOn = nil
                    partCountOfScenePartsGoIn = nil
                }
            }
            drawTagOccurrences.append(DrawTagOccurrence(rangeInReplyText: rangeInReplyText, command: command))
        }
        return drawTagOccurrences
    }

    // MARK: - Reading a card and its rows

    /// Reads the body of a `[CARD:...]` tag: all of it is the title, colons included.
    static func cardTitle(fromTagBody tagBody: String) -> String? {
        let cardTitle = singleLineText(tagBody, cutToCharacterCount: ClickyExplanationCard.maximumTitleCharacterCount)
        return cardTitle.isEmpty ? nil : cardTitle
    }

    /// Reads the body of a `[ROW:...]` tag, such as "boxes:the|sky|is -> blue". Returns nil for an
    /// unknown kind, an empty row, or a row with too few or too many parts.
    static func cardRow(fromTagBody tagBody: String) -> ClickyExplanationCardRow? {
        guard let firstColonIndex = tagBody.firstIndex(of: ":") else {
            return nil
        }
        let kindName = tagBody[..<firstColonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rowContent = String(tagBody[tagBody.index(after: firstColonIndex)...])
        let maximumPartCharacterCount = ClickyExplanationCard.maximumRowPartCharacterCount

        switch kindName {
        case "text":
            let rowText = singleLineText(rowContent, cutToCharacterCount: ClickyExplanationCard.maximumTextRowCharacterCount)
            return rowText.isEmpty ? nil : .text(rowText)

        case "boxes":
            // Everything before the first "->" is the boxes; what follows it is the result.
            let boxesAndResult = rowContent.replacingOccurrences(of: "→", with: "->").components(separatedBy: "->")
            let inputTexts = rowParts(of: boxesAndResult[0], separatedBy: "|", cutToCharacterCount: maximumPartCharacterCount)
            guard inputTexts.count >= ClickyExplanationCard.minimumBoxCountPerBoxesRow,
                  inputTexts.count <= ClickyExplanationCard.maximumBoxCountPerBoxesRow else {
                return nil
            }
            let resultText = boxesAndResult.count > 1
                ? singleLineText(boxesAndResult.dropFirst().joined(separator: " "), cutToCharacterCount: maximumPartCharacterCount)
                : ""
            return .boxes(inputTexts: inputTexts, resultText: resultText.isEmpty ? nil : resultText)

        case "flow":
            // The grammar joins the nodes with ">". An arrow written as "->" or "→" means the same.
            let rowContentWithOneSeparator = rowContent
                .replacingOccurrences(of: "→", with: ">")
                .replacingOccurrences(of: "->", with: ">")
            let nodeTexts = rowParts(of: rowContentWithOneSeparator, separatedBy: ">", cutToCharacterCount: maximumPartCharacterCount)
            guard nodeTexts.count >= ClickyExplanationCard.minimumPartCountPerFlowOrTimelineRow,
                  nodeTexts.count <= ClickyExplanationCard.maximumPartCountPerFlowOrTimelineRow else {
                return nil
            }
            return .flow(nodeTexts: nodeTexts)

        case "timeline":
            var timelinePoints: [ClickyExplanationCardTimelinePoint] = []
            for pointText in rowContent.components(separatedBy: "|") {
                if pointText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                // "when=what". A point without both halves makes the whole row unreadable.
                guard let firstEqualsIndex = pointText.firstIndex(of: "=") else {
                    return nil
                }
                let whenText = singleLineText(
                    String(pointText[..<firstEqualsIndex]),
                    cutToCharacterCount: ClickyExplanationCard.maximumTimelineWhenCharacterCount
                )
                let whatText = singleLineText(
                    String(pointText[pointText.index(after: firstEqualsIndex)...]),
                    cutToCharacterCount: maximumPartCharacterCount
                )
                guard !whenText.isEmpty, !whatText.isEmpty else {
                    return nil
                }
                timelinePoints.append(ClickyExplanationCardTimelinePoint(whenText: whenText, whatText: whatText))
            }
            guard timelinePoints.count >= ClickyExplanationCard.minimumPartCountPerFlowOrTimelineRow,
                  timelinePoints.count <= ClickyExplanationCard.maximumPartCountPerFlowOrTimelineRow else {
                return nil
            }
            return .timeline(points: timelinePoints)

        default:
            return nil
        }
    }

    /// The parts of a row between its separators, each one line and cut to the limit. Empty parts
    /// (from "a||b" or a trailing separator) are left out.
    private static func rowParts(of rowContent: String, separatedBy separator: String, cutToCharacterCount maximumCharacterCount: Int) -> [String] {
        rowContent
            .components(separatedBy: separator)
            .map { singleLineText($0, cutToCharacterCount: maximumCharacterCount) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Reading a 3D scene and its parts

    /// Reads the body of a `[SCENE:...]` tag: all of it is the title, colons included.
    static func sceneTitle(fromTagBody tagBody: String) -> String? {
        let sceneTitle = singleLineText(tagBody, cutToCharacterCount: ClickyScene.maximumTitleCharacterCount)
        return sceneTitle.isEmpty ? nil : sceneTitle
    }

    /// Reads the body of a `[PART:...]` tag, such as "cylinder:fan:0,0,2:1.2,0.3:blue:x".
    /// Returns nil for an unknown shape or colour, a position or size outside the limits, or the
    /// wrong count of numbers for the shape. Nothing is clamped: a part the model did not mean is
    /// worse than a missing one. Only the label is cut when it is too long.
    static func scenePart(fromTagBody tagBody: String) -> ClickyScenePart? {
        let untrimmedColonSeparatedComponents = tagBody
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0) }
        var colonSeparatedComponents = untrimmedColonSeparatedComponents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // shape, label, position, size and colour at the least.
        let minimumComponentCount = 5
        guard colonSeparatedComponents.count >= minimumComponentCount,
              let shapeKind = ClickyScenePartShapeKind(rawValue: colonSeparatedComponents[0].lowercased()) else {
            return nil
        }

        // The tag is read from its end, because the label (the second piece) may be empty or may
        // itself hold a colon. A last piece that is "x", "y" or "z" is the axis, but only when a
        // colour is still left before it.
        var axis = ClickyScenePartAxis.y
        if colonSeparatedComponents.count > minimumComponentCount,
           let lastComponent = colonSeparatedComponents.last,
           let axisFromLastComponent = ClickyScenePartAxis(rawValue: lastComponent.lowercased()) {
            axis = axisFromLastComponent
            colonSeparatedComponents.removeLast()
        }

        let colourComponent = colonSeparatedComponents[colonSeparatedComponents.count - 1]
        let sizeComponent = colonSeparatedComponents[colonSeparatedComponents.count - 2]
        let positionComponent = colonSeparatedComponents[colonSeparatedComponents.count - 3]
        // Everything between the shape and the position is the label.
        let labelComponentCount = colonSeparatedComponents.count - 4
        let rejoinedLabelText = untrimmedColonSeparatedComponents[1..<(1 + labelComponentCount)].joined(separator: ":")
        let labelText = singleLineText(rejoinedLabelText, cutToCharacterCount: ClickyScene.maximumPartLabelCharacterCount)

        guard let colour = ClickyScenePartColour.colour(named: colourComponent),
              let positionNumbers = sceneNumbers(
                  fromComponent: positionComponent,
                  expectedCount: 3,
                  smallestAllowedValue: -ClickyScene.maximumCentreCoordinate,
                  largestAllowedValue: ClickyScene.maximumCentreCoordinate
              ) else {
            return nil
        }

        let expectedSizeNumberCount: Int
        switch shapeKind {
        case .box: expectedSizeNumberCount = 3
        case .sphere: expectedSizeNumberCount = 1
        case .cylinder, .cone, .tube, .capsule: expectedSizeNumberCount = 2
        }
        guard let sizeNumbers = sceneNumbers(
            fromComponent: sizeComponent,
            expectedCount: expectedSizeNumberCount,
            smallestAllowedValue: ClickyScene.minimumPartSize,
            largestAllowedValue: ClickyScene.maximumPartSize
        ) else {
            return nil
        }

        let dimensions: ClickyScenePartDimensions
        switch shapeKind {
        case .box:
            dimensions = .box(width: sizeNumbers[0], height: sizeNumbers[1], depth: sizeNumbers[2])
        case .sphere:
            dimensions = .sphere(radius: sizeNumbers[0])
        case .cylinder, .cone, .tube, .capsule:
            dimensions = .radiusAndLength(radius: sizeNumbers[0], length: sizeNumbers[1])
        }

        return ClickyScenePart(
            shapeKind: shapeKind,
            labelText: labelText.isEmpty ? nil : labelText,
            centre: ClickySceneVector(x: positionNumbers[0], y: positionNumbers[1], z: positionNumbers[2]),
            dimensions: dimensions,
            colour: colour,
            // An axis written for a box or a sphere means nothing and is not kept.
            axis: shapeKind.pointsAlongAnAxis ? axis : .y
        )
    }

    /// Reads "0,0,2" or "1.2,0.3" as exactly `expectedCount` real numbers inside the given range.
    private static func sceneNumbers(
        fromComponent component: String,
        expectedCount: Int,
        smallestAllowedValue: Double,
        largestAllowedValue: Double
    ) -> [Double]? {
        let numberStrings = component
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard numberStrings.count == expectedCount else {
            return nil
        }
        var numbers: [Double] = []
        for numberString in numberStrings {
            guard let number = Double(numberString), number.isFinite,
                  number >= smallestAllowedValue, number <= largestAllowedValue else {
                return nil
            }
            numbers.append(number)
        }
        return numbers
    }

    // MARK: - Reading the pieces of a tag

    /// Reads "120,40" as a position. Both numbers must be real, not negative, and not absurdly far
    /// outside any screenshot.
    private static func point(fromComponent component: String) -> ClickyDrawingPoint? {
        guard let numberPair = numberPair(fromComponent: component),
              numberPair.first >= 0, numberPair.first <= maximumAcceptedCoordinate,
              numberPair.second >= 0, numberPair.second <= maximumAcceptedCoordinate else {
            return nil
        }
        return ClickyDrawingPoint(x: numberPair.first, y: numberPair.second)
    }

    /// Reads "160,60" as a width and a height. A box or highlight needs a real area.
    private static func size(fromComponent component: String) -> ClickyDrawingSize? {
        guard let numberPair = numberPair(fromComponent: component),
              numberPair.first >= 1, numberPair.first <= maximumAcceptedCoordinate,
              numberPair.second >= 1, numberPair.second <= maximumAcceptedCoordinate else {
            return nil
        }
        return ClickyDrawingSize(width: numberPair.first, height: numberPair.second)
    }

    private static func numberPair(fromComponent component: String) -> (first: Double, second: Double)? {
        let numberStrings = component
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard numberStrings.count == 2,
              let firstNumber = Double(numberStrings[0]),
              let secondNumber = Double(numberStrings[1]),
              firstNumber.isFinite,
              secondNumber.isFinite else {
            return nil
        }
        return (firstNumber, secondNumber)
    }

    /// Reads "m3" (or "M3") as a mark id. Anything else is not an id.
    private static func markIdentifier(fromComponent component: String) -> String? {
        let lowercasedComponent = component.lowercased()
        guard lowercasedComponent.range(of: "^m[0-9]{1,6}$", options: .regularExpression) != nil else {
            return nil
        }
        return lowercasedComponent
    }

    /// Reads a "screen2" or "screen 2" suffix, the same form `[POINT]` accepts.
    private static func screenNumber(fromComponent component: String) -> Int? {
        let lowercasedComponent = component.lowercased()
        guard lowercasedComponent.range(of: "^screen\\s*[0-9]{1,2}$", options: .regularExpression) != nil else {
            return nil
        }
        let digits = lowercasedComponent.filter(\.isNumber)
        guard let screenNumber = Int(digits), screenNumber >= 1 else {
            return nil
        }
        return screenNumber
    }

    /// Text drawn on screen is one line of plain words: line breaks and runs of spaces become one
    /// space, and text over the limit is cut at the limit.
    private static func singleLineText(_ text: String, cutToCharacterCount maximumCharacterCount: Int) -> String {
        let singleLineText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(singleLineText.prefix(maximumCharacterCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
