import Foundation

/// One `[DRAW:...]` tag of a reply, with where it sits in the spoken text.
nonisolated struct ClickyParsedDrawCommand: Equatable {
    let command: ClickyDrawCommand
    /// How much of the spoken text comes before this tag, from 0 (the tag opens the reply) to 1
    /// (the tag follows the last spoken word). The schedule multiplies it by the length of the
    /// audio, so a mark is drawn as the sentence before it ends.
    let spokenFractionBeforeTag: Double
}

nonisolated struct ClickyParsedDrawReply: Equatable {
    /// In the order they were written. At most `ClickyDrawTagParser.maximumDrawTagCountPerReply`.
    let commands: [ClickyParsedDrawCommand]
    /// Draw tags that were dropped: malformed, out of range, or past the per-reply limit. They are
    /// still removed from the spoken text by `ClickyReplyTagParser`.
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
/// - `[DRAW:erase:m3]`, `[DRAW:undo]`, `[DRAW:clear]`
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

    /// The pattern of one complete draw tag. Group 1 is everything after "DRAW:". Brackets are
    /// excluded from the body so one tag can never swallow the next.
    private static let completeDrawTagPattern = "\\[\\s*DRAW\\s*:([^\\[\\]]*)\\]"

    private struct DrawTagOccurrence {
        let rangeInReplyText: Range<String.Index>
        /// nil when the tag was malformed, out of range, or past the per-reply limit.
        let command: ClickyDrawCommand?
    }

    static func parse(_ rawReplyText: String) -> ClickyParsedDrawReply {
        let drawTagOccurrences = drawTagOccurrences(in: rawReplyText)
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
    static func command(fromTagBody tagBody: String) -> ClickyDrawCommand? {
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

        let kindHoldsText = kindName == "label" || kindName == "sticky"

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
            let maximumCharacterCount = kindName == "label" ? maximumLabelCharacterCount : maximumStickyNoteCharacterCount
            let markText = singleLineText(rejoinedText, cutToCharacterCount: maximumCharacterCount)
            guard !markText.isEmpty else {
                return nil
            }
            let shape: ClickyDrawingShape = kindName == "label"
                ? .label(topLeftCorner: firstPoint, text: markText)
                : .stickyNote(topLeftCorner: firstPoint, text: markText)
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
        finishedHistoryAssistantText: String
    ) -> String {
        let drawTagOccurrences = drawTagOccurrences(in: rawReplyText)
        let canonicalTagTexts = drawTagOccurrences.compactMap { drawTagOccurrence in
            drawTagOccurrence.command.map { canonicalTagText(for: $0) }
        }
        guard !canonicalTagTexts.isEmpty else {
            return finishedHistoryAssistantText
        }

        let spokenTextAsWritten = ClickyReplyTagParser.parse(rawReplyText).spokenText
        let finisherKeptTheWordsAsWritten = finishedSpokenText == spokenTextAsWritten
            && finishedHistoryAssistantText.hasPrefix(finishedSpokenText)
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
            historyPieces.append(ClickyReplyTagParser.parse(replyTextBeforeTag).spokenText)
            if let command = drawTagOccurrence.command {
                historyPieces.append(canonicalTagText(for: command))
            }
            nextUnreadIndex = drawTagOccurrence.rangeInReplyText.upperBound
        }
        historyPieces.append(ClickyReplyTagParser.parse(String(rawReplyText[nextUnreadIndex...])).spokenText)

        // Whatever the finisher added after the spoken words: the saved [NOTE:] and [PROFILE:] tags.
        let memoryTagsKeptByTheFinisher = String(finishedHistoryAssistantText.dropFirst(finishedSpokenText.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        historyPieces.append(memoryTagsKeptByTheFinisher)

        return historyPieces
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Finding the tags

    /// Every complete draw tag of the reply, in order, each with its command or nil. The per-reply
    /// limit is applied here so parsing and the history text always agree on which tags count.
    private static func drawTagOccurrences(in rawReplyText: String) -> [DrawTagOccurrence] {
        let completeDrawTagRegex = try! NSRegularExpression(pattern: completeDrawTagPattern, options: [.caseInsensitive])
        let completeDrawTagMatches = completeDrawTagRegex.matches(
            in: rawReplyText,
            range: NSRange(rawReplyText.startIndex..., in: rawReplyText)
        )

        var drawTagOccurrences: [DrawTagOccurrence] = []
        var acceptedCommandCount = 0
        for completeDrawTagMatch in completeDrawTagMatches {
            guard let rangeInReplyText = Range(completeDrawTagMatch.range, in: rawReplyText),
                  let tagBodyRange = Range(completeDrawTagMatch.range(at: 1), in: rawReplyText) else {
                continue
            }

            var command = self.command(fromTagBody: String(rawReplyText[tagBodyRange]))
            if command != nil {
                if acceptedCommandCount >= maximumDrawTagCountPerReply {
                    command = nil
                } else {
                    acceptedCommandCount += 1
                }
            }
            drawTagOccurrences.append(DrawTagOccurrence(rangeInReplyText: rangeInReplyText, command: command))
        }
        return drawTagOccurrences
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
