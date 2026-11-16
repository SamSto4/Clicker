import Foundation

/// One `[DRAW:...]`, `[CARD:...]`, `[ROW:...]`, `[SCENE:...]` or `[PART:...]` tag of a reply, with
/// where it sits in the spoken text.
nonisolated struct EzraParsedDrawCommand: Equatable {
    let command: EzraDrawCommand
    /// How much of the spoken text comes before this tag, from 0 (the tag opens the reply) to 1
    /// (the tag follows the last spoken word). The schedule multiplies it by the length of the
    /// audio, so a mark is drawn as the sentence before it ends.
    let spokenFractionBeforeTag: Double
}

nonisolated struct EzraParsedDrawReply: Equatable {
    /// In the order they were written. At most `EzraDrawTagParser.maximumDrawTagCountPerReply`
    /// from `[DRAW:...]` tags, plus at most one card and the rows that fit on it, plus at most one
    /// 3D scene and the parts that fit in it, plus (round 22) the view changes of the scene.
    let commands: [EzraParsedDrawCommand]
    /// Draw, card, row, scene, part and (round 22) view tags that were dropped: malformed, out of
    /// range, past a limit, a row with no card to go on, or a part or view with no scene. They are
    /// still removed from the spoken text by `EzraReplyTagParser`.
    let ignoredDrawTagCount: Int
    /// Round 22: why each dropped `[PART:...]` tag was dropped, in the order they were written (also
    /// counted in `ignoredDrawTagCount`). Fixed identifiers only: the metrics line counts them and
    /// the eval reports them by reason.
    var droppedScenePartReasons: [EzraScenePartDropReason] = []
}

/// Round 22: why a `[PART:...]` tag was dropped. The raw value is a fixed identifier for the eval's
/// records; it never holds any of the tag's own text.
nonisolated enum EzraScenePartDropReason: String, CaseIterable, Equatable {
    /// No scene was opened earlier in the reply and none is on the screen (or `[DRAW:clear]` took it).
    case noSceneToGoIn
    /// The scene already has its 24 parts.
    case sceneIsFull
    /// Fewer pieces than shape, label, position, size and colour.
    case tooFewPieces
    case unknownShape
    case unknownColour
    /// The position is not three numbers.
    case badPosition
    /// A coordinate of the position is outside -5 to 5.
    case positionOutOfRange
    /// The size does not have the count of numbers its shape takes, or one is not a number.
    case wrongSizeNumberCount
    /// A size number is outside 0.05 to 6.
    case sizeOutOfRange
    /// A torus whose pipe radius is not smaller than its ring radius.
    case pipeNotSmallerThanRing
    /// A field with "=" whose key is neither "rot" nor "mat".
    case unknownKey
    /// "rot=" or "mat=" written twice.
    case repeatedKey
    /// "rot=" that is not three numbers, each from -360 to 360.
    case badRotation
    /// "mat=" with a word that is not one of the six materials.
    case unknownMaterial
}

/// Round 22: what reading one `[PART:...]` body gave: a part, or why there is none.
nonisolated enum EzraScenePartReading: Equatable {
    case part(EzraScenePart)
    case dropped(EzraScenePartDropReason)
}

/// Round 22: the scene numbers of one reply for its metrics line: counts only, never a title, a
/// label or a tag's text.
nonisolated struct EzraSceneReplyCounts: Equatable {
    /// How many parts the reply's scene has once its tags are applied (the scene it opened, or the
    /// one on the screen it added to). nil when no scene is left after the reply.
    let scenePartCount: Int?
    /// `[PART:...]` tags the parser dropped.
    let droppedPartCount: Int
    /// `[VIEW:...]` tags that were accepted.
    let viewCommandCount: Int

    /// The counts of a reply, or nil when it wrote no scene tag the parser kept or dropped as a
    /// part (an ordinary reply, whose metrics line then has no scene field at all).
    /// `partCountOfSceneAlreadyOnScreen` is what the parser was given.
    static func counts(of parsedDrawReply: EzraParsedDrawReply, partCountOfSceneAlreadyOnScreen: Int?) -> EzraSceneReplyCounts? {
        var partCountOfTheScene = partCountOfSceneAlreadyOnScreen
        var viewCommandCount = 0
        var replyTouchedAScene = !parsedDrawReply.droppedScenePartReasons.isEmpty
        for parsedDrawCommand in parsedDrawReply.commands {
            switch parsedDrawCommand.command {
            case .addMark(.scene, _):
                partCountOfTheScene = 0
                replyTouchedAScene = true
            case .addScenePart:
                partCountOfTheScene = (partCountOfTheScene ?? 0) + 1
                replyTouchedAScene = true
            case .changeSceneView:
                viewCommandCount += 1
                replyTouchedAScene = true
            case .clearAllMarks:
                partCountOfTheScene = nil
            case .addMark, .eraseMark, .undoNewestMark, .addCardRow:
                break
            }
        }
        guard replyTouchedAScene else {
            return nil
        }
        return EzraSceneReplyCounts(
            scenePartCount: partCountOfTheScene,
            droppedPartCount: parsedDrawReply.droppedScenePartReasons.count,
            viewCommandCount: viewCommandCount
        )
    }
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
/// - `[DRAW:spotlight:x,y:radius]` (round 21) darkens everything but a circle; one per reply,
///   radius 20 to 2,000
/// - `[DRAW:erase:m3]`, `[DRAW:undo]`, `[DRAW:clear]`
///
/// An explanation card has tags of its own, which do not count towards the draw tag limit:
/// - `[CARD:title]` opens a card (one per reply; it replaces a card already on screen)
/// - `[ROW:text:words]`, `[ROW:boxes:a|b|c -> d]`, `[ROW:flow:a > b > c]`,
///   `[ROW:timeline:when=what|when=what]`, and since round 21 `[ROW:code:text]` and
///   `[ROW:table:a|b|c;d|e|f]`, add a row to the card opened in this reply, or to the card already
///   on screen
///
/// A simple 3D scene has tags of its own too, which do not count towards the draw tag limit either:
/// - `[SCENE:title]` opens a scene (one per reply; it replaces a scene already on screen)
/// - `[PART:shape:label:x,y,z:size:colour]` with an optional last `:axis` adds a part to the scene
///   opened in this reply, or to the scene already on screen. shape is box, cylinder, sphere,
///   cone, tube or capsule; the label may be empty; size is `w,h,d` for a box, `radius` for a
///   sphere and `radius,length` for the others; axis is x, y or z (default y, up). Round 22: also
///   torus `ring,pipe`, ring `radius`, pyramid `w,h,d`, plane `w,h`, wedge `w,h,d` and hemisphere
///   `radius`; after the colour (and the axis) an optional `:rot=rx,ry,rz` (degrees, each -360 to
///   360) and `:mat=matte|metal|plastic|rubber|glass|glow`, in either order; at most 24 parts
/// - (round 22) `[VIEW:exploded]` (alias `[VIEW:explode]`), `[VIEW:assembled]`,
///   `[VIEW:turn:left|right|front|back]`, `[VIEW:zoom:in|out]` and `[VIEW:reset]` change how the
///   scene opened in this reply, or the one on screen, is shown; any number per reply
///
/// This parser only finds and validates draw tags. Removing them from the spoken text stays the
/// job of `EzraReplyTagParser`, which knows the tag name so they are never read aloud.
nonisolated enum EzraDrawTagParser {
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

    /// Round 21: a spotlight's hole, in screenshot pixels. Smaller than this it is a pinhole that
    /// hides what it should show; larger, it darkens almost nothing.
    static let minimumSpotlightRadius: Double = 20
    static let maximumSpotlightRadius: Double = 2_000

    /// The pattern of one complete draw, card or row tag. Group 1 is the tag name and group 2 is
    /// everything after its colon. Brackets are excluded from the body so one tag can never
    /// swallow the next. Round 22 adds the scene's VIEW tag.
    private static let completeDrawTagPattern = "\\[\\s*(DRAW|CARD|ROW|SCENE|PART|VIEW)\\s*:([^\\[\\]]*)\\]"

    private struct DrawTagOccurrence {
        let rangeInReplyText: Range<String.Index>
        /// nil when the tag was malformed, out of range, or past the per-reply limit.
        let command: EzraDrawCommand?
        /// Round 22: for a `[PART:...]` tag that was dropped, why.
        var scenePartDropReason: EzraScenePartDropReason? = nil
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
    ) -> EzraParsedDrawReply {
        let drawTagOccurrences = drawTagOccurrences(
            in: rawReplyText,
            rowCountOfCardAlreadyOnScreen: rowCountOfCardAlreadyOnScreen,
            partCountOfSceneAlreadyOnScreen: partCountOfSceneAlreadyOnScreen
        )
        guard !drawTagOccurrences.isEmpty else {
            return EzraParsedDrawReply(commands: [], ignoredDrawTagCount: 0)
        }

        // The spoken text is measured with the same parser that produces it, so the fraction
        // matches what the voice will actually say.
        let totalSpokenCharacterCount = EzraReplyTagParser.parse(rawReplyText).spokenText.count

        var parsedCommands: [EzraParsedDrawCommand] = []
        var ignoredDrawTagCount = 0
        var droppedScenePartReasons: [EzraScenePartDropReason] = []
        for drawTagOccurrence in drawTagOccurrences {
            guard let command = drawTagOccurrence.command else {
                ignoredDrawTagCount += 1
                if let scenePartDropReason = drawTagOccurrence.scenePartDropReason {
                    droppedScenePartReasons.append(scenePartDropReason)
                }
                continue
            }

            let replyTextBeforeTag = String(rawReplyText[..<drawTagOccurrence.rangeInReplyText.lowerBound])
            let spokenCharacterCountBeforeTag = EzraReplyTagParser.parse(replyTextBeforeTag).spokenText.count
            let spokenFractionBeforeTag: Double
            if totalSpokenCharacterCount > 0 {
                spokenFractionBeforeTag = min(1, Double(spokenCharacterCountBeforeTag) / Double(totalSpokenCharacterCount))
            } else {
                spokenFractionBeforeTag = 0
            }
            parsedCommands.append(EzraParsedDrawCommand(command: command, spokenFractionBeforeTag: spokenFractionBeforeTag))
        }

        return EzraParsedDrawReply(
            commands: parsedCommands,
            ignoredDrawTagCount: ignoredDrawTagCount,
            droppedScenePartReasons: droppedScenePartReasons
        )
    }

    /// Reads the body of one draw tag (everything after "DRAW:"), such as "circle:120,11:34" or
    /// "undo". Returns nil for anything that is not exactly one of the documented forms.
    ///
    /// `calloutNumber` is the number a callout gets if this tag is one; the caller counts them.
    static func command(fromTagBody tagBody: String, calloutNumber: Int = 1) -> EzraDrawCommand? {
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
            case "callout": maximumCharacterCount = EzraCalloutPlacement.maximumCalloutCharacterCount
            default: maximumCharacterCount = maximumStickyNoteCharacterCount
            }
            let markText = singleLineText(rejoinedText, cutToCharacterCount: maximumCharacterCount)
            guard !markText.isEmpty else {
                return nil
            }
            let shape: EzraDrawingShape
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
            let shape: EzraDrawingShape = kindName == "arrow"
                ? .arrow(tail: firstPoint, head: secondPoint)
                : .underline(start: firstPoint, end: secondPoint)
            return .addMark(shape: shape, screenNumber: screenNumber)

        case "circle":
            guard let radius = Double(secondComponent), radius.isFinite,
                  radius >= minimumCircleRadius, radius <= maximumCircleRadius else {
                return nil
            }
            return .addMark(shape: .circle(center: firstPoint, radius: radius), screenNumber: screenNumber)

        case "spotlight":
            // Round 21: "spotlight:x,y:radius", the same shape of tag as a circle.
            guard let radius = Double(secondComponent), radius.isFinite,
                  radius >= minimumSpotlightRadius, radius <= maximumSpotlightRadius else {
                return nil
            }
            return .addMark(shape: .spotlight(center: firstPoint, radius: radius), screenNumber: screenNumber)

        case "box", "highlight":
            guard let size = size(fromComponent: secondComponent) else {
                return nil
            }
            let shape: EzraDrawingShape = kindName == "box"
                ? .box(topLeftCorner: firstPoint, size: size)
                : .highlight(topLeftCorner: firstPoint, size: size)
            return .addMark(shape: shape, screenNumber: screenNumber)

        default:
            return nil
        }
    }

    /// The tag exactly as the grammar writes it, with whole-pixel coordinates. Used for the
    /// conversation history, so what the model reads back is the documented format and stays short.
    static func canonicalTagText(for drawCommand: EzraDrawCommand) -> String {
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
        case .changeSceneView(let viewCommand):
            return "[VIEW:\(viewCommand.canonicalTagBody)]"
        case .addMark(.scene(let scene), _):
            // A scene is opened by its title alone; its parts are tags of their own.
            return "[SCENE:\(scene.title)]"
        case .addMark(.explanationCard(let card), _):
            // A card is opened by its title alone; its rows are tags of their own.
            return "[CARD:\(card.title)]"
        case .addMark(let shape, let screenNumber):
            let coordinateText = EzraDrawingMarksOnScreenText.coordinateText
            let wholeNumberText = EzraDrawingMarksOnScreenText.wholeNumberText
            let tagBodyAfterKind: String
            switch shape {
            case .arrow(let tail, let head):
                tagBodyAfterKind = "\(coordinateText(tail)):\(coordinateText(head))"
            case .underline(let start, let end):
                tagBodyAfterKind = "\(coordinateText(start)):\(coordinateText(end))"
            case .circle(let center, let radius), .spotlight(let center, let radius):
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
        let parsedReplyAsWritten = EzraReplyTagParser.parse(rawReplyText)
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
            historyPieces.append(EzraReplyTagParser.parse(replyTextBeforeTag).spokenTextAsWritten)
            if let command = drawTagOccurrence.command {
                historyPieces.append(canonicalTagText(for: command))
            }
            nextUnreadIndex = drawTagOccurrence.rangeInReplyText.upperBound
        }
        historyPieces.append(EzraReplyTagParser.parse(String(rawReplyText[nextUnreadIndex...])).spokenTextAsWritten)

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
        // Round 21: one spotlight per reply, for the reason there is one card per reply.
        var hasDrawnASpotlightInThisReply = false

        for completeDrawTagMatch in completeDrawTagMatches {
            guard let rangeInReplyText = Range(completeDrawTagMatch.range, in: rawReplyText),
                  let tagNameRange = Range(completeDrawTagMatch.range(at: 1), in: rawReplyText),
                  let tagBodyRange = Range(completeDrawTagMatch.range(at: 2), in: rawReplyText) else {
                continue
            }
            let tagName = rawReplyText[tagNameRange].uppercased()
            let tagBody = String(rawReplyText[tagBodyRange])

            var command: EzraDrawCommand?
            var scenePartDropReason: EzraScenePartDropReason?
            switch tagName {
            case "CARD":
                // One card per reply: a second one would replace the first while its rows are
                // still being spoken about.
                if !hasOpenedACardInThisReply, let cardTitle = cardTitle(fromTagBody: tagBody) {
                    command = .addMark(shape: .explanationCard(EzraExplanationCard(title: cardTitle, rows: [])), screenNumber: nil)
                    hasOpenedACardInThisReply = true
                    rowCountOfCardRowsGoOn = 0
                }

            case "ROW":
                if let rowCountSoFar = rowCountOfCardRowsGoOn,
                   rowCountSoFar < EzraExplanationCard.maximumRowCount,
                   let cardRow = cardRow(fromTagBody: tagBody) {
                    command = .addCardRow(cardRow)
                    rowCountOfCardRowsGoOn = rowCountSoFar + 1
                }

            case "SCENE":
                // One scene per reply, for the reason there is one card per reply: a second one
                // would replace the first while its parts are still being spoken about.
                if !hasOpenedASceneInThisReply, let sceneTitle = sceneTitle(fromTagBody: tagBody) {
                    command = .addMark(shape: .scene(EzraScene(title: sceneTitle, parts: [])), screenNumber: nil)
                    hasOpenedASceneInThisReply = true
                    partCountOfScenePartsGoIn = 0
                }

            case "PART":
                // The same acceptance as before round 22 (a scene to go in, room in it, a part that
                // reads), now with the reason when one of them is missing.
                if let partCountSoFar = partCountOfScenePartsGoIn {
                    if partCountSoFar < EzraScene.maximumPartCount {
                        switch scenePartReading(fromTagBody: tagBody) {
                        case .part(let scenePart):
                            command = .addScenePart(scenePart)
                            partCountOfScenePartsGoIn = partCountSoFar + 1
                        case .dropped(let dropReason):
                            scenePartDropReason = dropReason
                        }
                    } else {
                        scenePartDropReason = .sceneIsFull
                    }
                } else {
                    scenePartDropReason = .noSceneToGoIn
                }

            case "VIEW":
                // Round 22: a view change needs a scene to show, like a part needs one to go in: the
                // one opened earlier in this reply or the one on the screen.
                if partCountOfScenePartsGoIn != nil, let viewCommand = viewCommand(fromTagBody: tagBody) {
                    command = .changeSceneView(viewCommand)
                }

            default:
                command = self.command(fromTagBody: tagBody, calloutNumber: nextCalloutNumber)
                // A second spotlight is dropped before it is counted, so like a malformed tag it
                // uses up none of the eight.
                if case .addMark(.spotlight, _) = command, hasDrawnASpotlightInThisReply {
                    command = nil
                }
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
                if case .addMark(.spotlight, _) = command {
                    hasDrawnASpotlightInThisReply = true
                }
                if case .clearAllMarks = command {
                    // The card went with everything else, so a later row has nothing to go on.
                    // The same for the scene and a later part.
                    rowCountOfCardRowsGoOn = nil
                    partCountOfScenePartsGoIn = nil
                }
            }
            drawTagOccurrences.append(DrawTagOccurrence(
                rangeInReplyText: rangeInReplyText,
                command: command,
                scenePartDropReason: scenePartDropReason
            ))
        }
        return drawTagOccurrences
    }

    // MARK: - Reading a card and its rows

    /// Reads the body of a `[CARD:...]` tag: all of it is the title, colons included.
    static func cardTitle(fromTagBody tagBody: String) -> String? {
        let cardTitle = singleLineText(tagBody, cutToCharacterCount: EzraExplanationCard.maximumTitleCharacterCount)
        return cardTitle.isEmpty ? nil : cardTitle
    }

    /// Reads the body of a `[ROW:...]` tag, such as "boxes:the|sky|is -> blue". Returns nil for an
    /// unknown kind, an empty row, or a row with too few or too many parts.
    static func cardRow(fromTagBody tagBody: String) -> EzraExplanationCardRow? {
        guard let firstColonIndex = tagBody.firstIndex(of: ":") else {
            return nil
        }
        let kindName = tagBody[..<firstColonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rowContent = String(tagBody[tagBody.index(after: firstColonIndex)...])
        let maximumPartCharacterCount = EzraExplanationCard.maximumRowPartCharacterCount

        switch kindName {
        case "text":
            let rowText = singleLineText(rowContent, cutToCharacterCount: EzraExplanationCard.maximumTextRowCharacterCount)
            return rowText.isEmpty ? nil : .text(rowText)

        case "boxes":
            // Everything before the first "->" is the boxes; what follows it is the result.
            let boxesAndResult = rowContent.replacingOccurrences(of: "→", with: "->").components(separatedBy: "->")
            let inputTexts = rowParts(of: boxesAndResult[0], separatedBy: "|", cutToCharacterCount: maximumPartCharacterCount)
            guard inputTexts.count >= EzraExplanationCard.minimumBoxCountPerBoxesRow,
                  inputTexts.count <= EzraExplanationCard.maximumBoxCountPerBoxesRow else {
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
            guard nodeTexts.count >= EzraExplanationCard.minimumPartCountPerFlowOrTimelineRow,
                  nodeTexts.count <= EzraExplanationCard.maximumPartCountPerFlowOrTimelineRow else {
                return nil
            }
            return .flow(nodeTexts: nodeTexts)

        case "timeline":
            var timelinePoints: [EzraExplanationCardTimelinePoint] = []
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
                    cutToCharacterCount: EzraExplanationCard.maximumTimelineWhenCharacterCount
                )
                let whatText = singleLineText(
                    String(pointText[pointText.index(after: firstEqualsIndex)...]),
                    cutToCharacterCount: maximumPartCharacterCount
                )
                guard !whenText.isEmpty, !whatText.isEmpty else {
                    return nil
                }
                timelinePoints.append(EzraExplanationCardTimelinePoint(whenText: whenText, whatText: whatText))
            }
            guard timelinePoints.count >= EzraExplanationCard.minimumPartCountPerFlowOrTimelineRow,
                  timelinePoints.count <= EzraExplanationCard.maximumPartCountPerFlowOrTimelineRow else {
                return nil
            }
            return .timeline(points: timelinePoints)

        case "code":
            // Round 21: everything after "code:" is the line of code, colons and pipes included,
            // made one line and cut to the limit.
            let codeText = singleLineText(rowContent, cutToCharacterCount: EzraExplanationCard.maximumCodeRowCharacterCount)
            return codeText.isEmpty ? nil : .code(codeText)

        case "table":
            return tableRow(fromRowContent: rowContent)

        default:
            return nil
        }
    }

    /// Round 21: reads "plan|price;free|0;pro|12": rows split at ";", cells at "|". Each cell is
    /// trimmed and cut to 16 characters (an empty cell, such as a blank top-left corner, is kept).
    /// A blank row (a trailing ";") is left out. Two to four columns, and every row with the same
    /// number of cells, or the row is dropped: a table with a missing cell would put the words under
    /// the wrong heading.
    ///
    /// Two mistakes the model made in the round 21 tester's live run are read leniently instead of
    /// dropping the row. A table of more than four rows keeps its first four (the header and three
    /// more). A body that does not read as a table is read once more with the two separators swapped
    /// (rows at "|", cells at ";"); a table read that way is kept the right way round, so the history
    /// shows the model the separators it should use.
    static func tableRow(fromRowContent rowContent: String) -> EzraExplanationCardRow? {
        if let tableRows = tableRows(fromRowContent: rowContent, rowSeparator: ";", cellSeparator: "|") {
            return .table(rows: tableRows)
        }
        if let tableRowsReadWithTheSeparatorsSwapped = tableRows(fromRowContent: rowContent, rowSeparator: "|", cellSeparator: ";") {
            return .table(rows: tableRowsReadWithTheSeparatorsSwapped)
        }
        return nil
    }

    /// The cells of a table body read with these separators, or nil when they do not make a table.
    private static func tableRows(fromRowContent rowContent: String, rowSeparator: String, cellSeparator: String) -> [[String]]? {
        var tableRows: [[String]] = []
        for tableRowText in rowContent.components(separatedBy: rowSeparator) {
            if tableRowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            // Rows past the fourth are left out before anything is checked, so the first four still
            // make a table when a later row is longer, shorter or broken.
            guard tableRows.count < EzraExplanationCard.maximumTableRowCount else {
                break
            }
            tableRows.append(tableRowText.components(separatedBy: cellSeparator).map { cellText in
                singleLineText(cellText, cutToCharacterCount: EzraExplanationCard.maximumTableCellCharacterCount)
            })
        }
        guard tableRows.count >= EzraExplanationCard.minimumTableRowCount,
              let columnCount = tableRows.first?.count,
              columnCount >= EzraExplanationCard.minimumTableColumnCount,
              columnCount <= EzraExplanationCard.maximumTableColumnCount,
              tableRows.allSatisfy({ $0.count == columnCount }),
              tableRows.joined().contains(where: { !$0.isEmpty }) else {
            return nil
        }
        return tableRows
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
        let sceneTitle = singleLineText(tagBody, cutToCharacterCount: EzraScene.maximumTitleCharacterCount)
        return sceneTitle.isEmpty ? nil : sceneTitle
    }

    /// Reads the body of a `[PART:...]` tag, such as "cylinder:fan:0,0,2:1.2,0.3:blue:x".
    /// Returns nil for an unknown shape or colour, a position or size outside the limits, or the
    /// wrong count of numbers for the shape. Nothing is clamped: a part the model did not mean is
    /// worse than a missing one. Only the label is cut when it is too long. Round 22: see
    /// `scenePartReading(fromTagBody:)`, which also says why a part was dropped.
    static func scenePart(fromTagBody tagBody: String) -> EzraScenePart? {
        if case .part(let scenePart) = scenePartReading(fromTagBody: tagBody) {
            return scenePart
        }
        return nil
    }

    /// Reads the body of a `[PART:...]` tag into a part, or the reason there is none.
    ///
    /// The tag is read from its end, because the label (the second piece) may be empty or may
    /// itself hold a colon. Round 22: the pieces after the colour are optional and are taken off
    /// the end first, in any order: a piece holding "=" is a keyed field (`rot=rx,ry,rz` or
    /// `mat=material`, each at most once; another key drops the part), and a piece that is "x", "y"
    /// or "z" is the axis (once). A trailing piece is only taken while more than shape, label,
    /// position, size and colour are left, so a colour can never be read as an axis. A part written
    /// without the round 22 fields reads exactly as it always did.
    static func scenePartReading(fromTagBody tagBody: String) -> EzraScenePartReading {
        let untrimmedColonSeparatedComponents = tagBody
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0) }
        var colonSeparatedComponents = untrimmedColonSeparatedComponents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // shape, label, position, size and colour at the least.
        let minimumComponentCount = 5
        guard colonSeparatedComponents.count >= minimumComponentCount else {
            return .dropped(.tooFewPieces)
        }
        guard let shapeKind = EzraScenePartShapeKind(rawValue: colonSeparatedComponents[0].lowercased()) else {
            return .dropped(.unknownShape)
        }

        var axis = EzraScenePartAxis.y
        var axisWasWritten = false
        var rotation = EzraScenePartRotation.none
        var rotationWasWritten = false
        var material = EzraScenePartMaterial.matte
        var materialWasWritten = false
        while colonSeparatedComponents.count > minimumComponentCount, let lastComponent = colonSeparatedComponents.last {
            if let equalsSignIndex = lastComponent.firstIndex(of: "=") {
                let keyText = lastComponent[..<equalsSignIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let valueText = lastComponent[lastComponent.index(after: equalsSignIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
                switch keyText {
                case "rot":
                    guard !rotationWasWritten else {
                        return .dropped(.repeatedKey)
                    }
                    guard let rotationNumbers = sceneNumbers(
                        fromComponent: valueText,
                        expectedCount: 3,
                        smallestAllowedValue: -EzraScenePartRotation.largestAngleInDegrees,
                        largestAllowedValue: EzraScenePartRotation.largestAngleInDegrees
                    ) else {
                        return .dropped(.badRotation)
                    }
                    rotation = EzraScenePartRotation(degreesX: rotationNumbers[0], degreesY: rotationNumbers[1], degreesZ: rotationNumbers[2])
                    rotationWasWritten = true
                case "mat":
                    guard !materialWasWritten else {
                        return .dropped(.repeatedKey)
                    }
                    guard let materialFromValue = EzraScenePartMaterial(rawValue: valueText.lowercased()) else {
                        return .dropped(.unknownMaterial)
                    }
                    material = materialFromValue
                    materialWasWritten = true
                default:
                    return .dropped(.unknownKey)
                }
                colonSeparatedComponents.removeLast()
            } else if !axisWasWritten, let axisFromLastComponent = EzraScenePartAxis(rawValue: lastComponent.lowercased()) {
                axis = axisFromLastComponent
                axisWasWritten = true
                colonSeparatedComponents.removeLast()
            } else {
                break
            }
        }

        let colourComponent = colonSeparatedComponents[colonSeparatedComponents.count - 1]
        let sizeComponent = colonSeparatedComponents[colonSeparatedComponents.count - 2]
        let positionComponent = colonSeparatedComponents[colonSeparatedComponents.count - 3]
        // Everything between the shape and the position is the label.
        let labelComponentCount = colonSeparatedComponents.count - 4
        let rejoinedLabelText = untrimmedColonSeparatedComponents[1..<(1 + labelComponentCount)].joined(separator: ":")
        let labelText = singleLineText(rejoinedLabelText, cutToCharacterCount: EzraScene.maximumPartLabelCharacterCount)

        guard let colour = EzraScenePartColour.colour(named: colourComponent) else {
            return .dropped(.unknownColour)
        }
        guard let positionNumbers = sceneNumbers(fromComponent: positionComponent, expectedCount: 3) else {
            return .dropped(.badPosition)
        }
        guard numbers(positionNumbers, areAllFrom: -EzraScene.maximumCentreCoordinate, to: EzraScene.maximumCentreCoordinate) else {
            return .dropped(.positionOutOfRange)
        }
        guard let sizeNumbers = sceneNumbers(fromComponent: sizeComponent, expectedCount: shapeKind.sizeNumberCount) else {
            return .dropped(.wrongSizeNumberCount)
        }
        guard numbers(sizeNumbers, areAllFrom: EzraScene.minimumPartSize, to: EzraScene.maximumPartSize) else {
            return .dropped(.sizeOutOfRange)
        }

        let dimensions: EzraScenePartDimensions
        switch shapeKind {
        case .box, .pyramid, .wedge:
            dimensions = .box(width: sizeNumbers[0], height: sizeNumbers[1], depth: sizeNumbers[2])
        case .sphere:
            dimensions = .sphere(radius: sizeNumbers[0])
        case .cylinder, .cone, .tube, .capsule:
            dimensions = .radiusAndLength(radius: sizeNumbers[0], length: sizeNumbers[1])
        case .torus:
            // A pipe as thick as the ring (or thicker) would fill the hole: not a torus.
            guard sizeNumbers[1] < sizeNumbers[0] else {
                return .dropped(.pipeNotSmallerThanRing)
            }
            dimensions = .torus(ringRadius: sizeNumbers[0], pipeRadius: sizeNumbers[1])
        case .ring:
            dimensions = .torus(ringRadius: sizeNumbers[0], pipeRadius: EzraScenePart.ringPipeRadius(forRingRadius: sizeNumbers[0]))
        case .plane:
            dimensions = .plane(width: sizeNumbers[0], height: sizeNumbers[1])
        case .hemisphere:
            dimensions = .hemisphere(radius: sizeNumbers[0])
        }

        return .part(EzraScenePart(
            shapeKind: shapeKind,
            labelText: labelText.isEmpty ? nil : labelText,
            centre: EzraSceneVector(x: positionNumbers[0], y: positionNumbers[1], z: positionNumbers[2]),
            dimensions: dimensions,
            colour: colour,
            // An axis written for a shape without one means nothing and is not kept.
            axis: shapeKind.pointsAlongAnAxis ? axis : .y,
            rotation: rotation,
            // A part coloured glass is already glass: "glass:mat=glass" is the same part as
            // "glass", so it reads (and is written back) the way a glass part always was.
            material: colour == .glass && material == .glass ? .matte : material
        ))
    }

    /// Round 22: reads the body of a `[VIEW:...]` tag ("exploded", "explode", "assembled",
    /// "turn:left", "zoom:in", "reset", ...). Case and spaces around the pieces do not matter.
    /// Returns nil for anything else.
    static func viewCommand(fromTagBody tagBody: String) -> EzraSceneViewCommand? {
        let colonSeparatedComponents = tagBody
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        switch colonSeparatedComponents.count {
        case 1:
            switch colonSeparatedComponents[0] {
            case "exploded", "explode": return .exploded
            case "assembled": return .assembled
            case "reset": return .reset
            default: return nil
            }
        case 2:
            switch colonSeparatedComponents[0] {
            case "turn":
                return EzraSceneTurnDirection(rawValue: colonSeparatedComponents[1]).map { .turn($0) }
            case "zoom":
                return EzraSceneZoomDirection(rawValue: colonSeparatedComponents[1]).map { .zoom($0) }
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Reads "0,0,2" or "1.2,0.3" as exactly `expectedCount` real numbers inside the given range.
    private static func sceneNumbers(
        fromComponent component: String,
        expectedCount: Int,
        smallestAllowedValue: Double,
        largestAllowedValue: Double
    ) -> [Double]? {
        guard let numbers = sceneNumbers(fromComponent: component, expectedCount: expectedCount),
              self.numbers(numbers, areAllFrom: smallestAllowedValue, to: largestAllowedValue) else {
            return nil
        }
        return numbers
    }

    /// Round 22: reads "0,0,2" as exactly `expectedCount` real numbers, whatever their size, so a
    /// part with numbers that are only out of range can be told apart from one with a bad count.
    private static func sceneNumbers(fromComponent component: String, expectedCount: Int) -> [Double]? {
        let numberStrings = component
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard numberStrings.count == expectedCount else {
            return nil
        }
        var numbers: [Double] = []
        for numberString in numberStrings {
            guard let number = Double(numberString), number.isFinite else {
                return nil
            }
            numbers.append(number)
        }
        return numbers
    }

    private static func numbers(_ numbers: [Double], areAllFrom smallestAllowedValue: Double, to largestAllowedValue: Double) -> Bool {
        numbers.allSatisfy { $0 >= smallestAllowedValue && $0 <= largestAllowedValue }
    }

    // MARK: - Reading the pieces of a tag

    /// Reads "120,40" as a position. Both numbers must be real, not negative, and not absurdly far
    /// outside any screenshot.
    private static func point(fromComponent component: String) -> EzraDrawingPoint? {
        guard let numberPair = numberPair(fromComponent: component),
              numberPair.first >= 0, numberPair.first <= maximumAcceptedCoordinate,
              numberPair.second >= 0, numberPair.second <= maximumAcceptedCoordinate else {
            return nil
        }
        return EzraDrawingPoint(x: numberPair.first, y: numberPair.second)
    }

    /// Reads "160,60" as a width and a height. A box or highlight needs a real area.
    private static func size(fromComponent component: String) -> EzraDrawingSize? {
        guard let numberPair = numberPair(fromComponent: component),
              numberPair.first >= 1, numberPair.first <= maximumAcceptedCoordinate,
              numberPair.second >= 1, numberPair.second <= maximumAcceptedCoordinate else {
            return nil
        }
        return EzraDrawingSize(width: numberPair.first, height: numberPair.second)
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
