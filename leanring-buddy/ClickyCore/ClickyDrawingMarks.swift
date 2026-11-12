import Foundation

/// A position in the labeled screenshot Claude was shown: pixels, origin at the top-left corner.
/// The same type is reused for positions in display points once a shape has been mapped onto a
/// display (see `ClickyScreenshotToDisplayMapping`), where the origin is still the top-left corner.
nonisolated struct ClickyDrawingPoint: Equatable {
    let x: Double
    let y: Double
}

nonisolated struct ClickyDrawingSize: Equatable {
    let width: Double
    let height: Double
}

/// What Clicky can draw on the screen. Every case carries only numbers and short text, so the
/// whole drawing model can be tested without AppKit.
nonisolated enum ClickyDrawingShape: Equatable {
    case arrow(tail: ClickyDrawingPoint, head: ClickyDrawingPoint)
    case circle(center: ClickyDrawingPoint, radius: Double)
    case box(topLeftCorner: ClickyDrawingPoint, size: ClickyDrawingSize)
    case underline(start: ClickyDrawingPoint, end: ClickyDrawingPoint)
    /// A translucent marker band over text.
    case highlight(topLeftCorner: ClickyDrawingPoint, size: ClickyDrawingSize)
    /// A short piece of text in a small pill.
    case label(topLeftCorner: ClickyDrawingPoint, text: String)
    /// A note card with a little more text.
    case stickyNote(topLeftCorner: ClickyDrawingPoint, text: String)
    /// A small numbered tag joined by a leader line to `target`. The app decides where the tag
    /// itself goes (see `ClickyCalloutPlacement`). `calloutNumber` counts 1, 2, 3 within a reply.
    case callout(target: ClickyDrawingPoint, text: String, calloutNumber: Int)
    /// A paper card with a title and rows, written while Clicky explains something. It carries no
    /// position: the app places it (see `ClickyExplanationCardPlacement`).
    case explanationCard(ClickyExplanationCard)

    /// The word used for this shape in a `[DRAW:...]` tag and in the "marks on screen" list.
    var tagKindName: String {
        switch self {
        case .arrow: return "arrow"
        case .circle: return "circle"
        case .box: return "box"
        case .underline: return "underline"
        case .highlight: return "highlight"
        case .label: return "label"
        case .stickyNote: return "sticky"
        case .callout: return "callout"
        case .explanationCard: return "card"
        }
    }

    /// A sticky note and an explanation card are written for the user, not pointed at something
    /// on the page, so they stay when the page scrolls. Every other shape marks a place in the
    /// content and would be wrong the moment that content moves.
    var pointsAtScreenContent: Bool {
        switch self {
        case .stickyNote, .explanationCard:
            return false
        case .arrow, .circle, .box, .underline, .highlight, .label, .callout:
            return true
        }
    }

    var isExplanationCard: Bool {
        if case .explanationCard = self {
            return true
        }
        return false
    }

    /// The one place this shape is about, used to tell which half of the screen a reply marks so
    /// the explanation card can go on the other. nil for the card itself, which marks no place.
    var placeTheShapeIsAbout: ClickyDrawingPoint? {
        switch self {
        case .arrow(_, let head):
            return head
        case .circle(let center, _):
            return center
        case .box(let topLeftCorner, let size), .highlight(let topLeftCorner, let size):
            return ClickyDrawingPoint(x: topLeftCorner.x + size.width / 2, y: topLeftCorner.y + size.height / 2)
        case .underline(let start, let end):
            return ClickyDrawingPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        case .label(let topLeftCorner, _), .stickyNote(let topLeftCorner, _):
            return topLeftCorner
        case .callout(let target, _, _):
            return target
        case .explanationCard:
            return nil
        }
    }
}

/// One mark that is (or is about to be) on the screen.
nonisolated struct ClickyDrawingMark: Equatable {
    /// 1 for the first mark of the session, 2 for the second, and so on. Never reused.
    let markNumber: Int
    let shape: ClickyDrawingShape
    /// 1-based screen number from the image label, as `[POINT]` uses it. nil means the screen the
    /// cursor was on.
    let screenNumber: Int?

    /// The name Claude uses to erase this mark: "m1", "m2", ...
    var markIdentifier: String {
        ClickyDrawingBoard.markIdentifier(forMarkNumber: markNumber)
    }
}

/// One instruction from a `[DRAW:...]` tag.
nonisolated enum ClickyDrawCommand: Equatable {
    case addMark(shape: ClickyDrawingShape, screenNumber: Int?)
    /// `markIdentifier` is lowercased, such as "m3".
    case eraseMark(markIdentifier: String)
    case undoNewestMark
    case clearAllMarks
    /// From a `[ROW:...]` tag: one more row on the explanation card that is on the board.
    case addCardRow(ClickyExplanationCardRow)

    /// True for the commands that put something new on the screen.
    var addsAMark: Bool {
        if case .addMark = self {
            return true
        }
        return false
    }
}

/// What applying one command did to the board, so the overlay knows which layers to add or remove.
nonisolated enum ClickyDrawingBoardChange: Equatable {
    /// `marksRemovedToMakeRoom` is not empty only when the board was full.
    case addedMark(ClickyDrawingMark, marksRemovedToMakeRoom: [ClickyDrawingMark])
    case removedMarks([ClickyDrawingMark])
    /// A row was written on the card. `cardMark` is the card with the row already on it, and
    /// `rowIndex` is the new row's place in it.
    case addedRowToCard(cardMark: ClickyDrawingMark, rowIndex: Int)
    /// An erase of an unknown id, an undo or clear with nothing drawn, or a row with no card to
    /// go on (or a card that is already full).
    case nothingChanged
}

/// The marks on screen and the numbering of marks for the session. A plain value with no timers
/// and no layers: the overlay controller owns one and mirrors it on screen.
nonisolated struct ClickyDrawingBoard: Equatable {
    /// A safety limit so a long session of "add another one" cannot fill the screen or the
    /// prompt's "marks on screen" list. When a new mark would exceed it, the oldest mark goes.
    static let maximumMarkCountOnScreen = 20

    /// Oldest first.
    private(set) var marks: [ClickyDrawingMark] = []
    /// Keeps counting when marks are erased or cleared, so an id always names one mark for the
    /// whole session and an old id can never erase a newer mark by accident.
    private(set) var nextMarkNumber = 1

    static func markIdentifier(forMarkNumber markNumber: Int) -> String {
        "m\(markNumber)"
    }

    var isEmpty: Bool {
        marks.isEmpty
    }

    mutating func apply(_ drawCommand: ClickyDrawCommand) -> ClickyDrawingBoardChange {
        switch drawCommand {
        case .addMark(let shape, let screenNumber):
            var marksRemovedToMakeRoom: [ClickyDrawingMark] = []
            // There is one explanation card at a time: opening a new one replaces the old one.
            if shape.isExplanationCard {
                marksRemovedToMakeRoom += marks.filter { $0.shape.isExplanationCard }
                marks.removeAll { $0.shape.isExplanationCard }
            }

            let addedMark = ClickyDrawingMark(markNumber: nextMarkNumber, shape: shape, screenNumber: screenNumber)
            nextMarkNumber += 1
            marks.append(addedMark)

            while marks.count > Self.maximumMarkCountOnScreen {
                marksRemovedToMakeRoom.append(marks.removeFirst())
            }
            return .addedMark(addedMark, marksRemovedToMakeRoom: marksRemovedToMakeRoom)

        case .eraseMark(let markIdentifier):
            return removeMarks { existingMark in
                existingMark.markIdentifier == markIdentifier.lowercased()
            }

        case .undoNewestMark:
            guard let newestMark = marks.last else {
                return .nothingChanged
            }
            return removeMarks { existingMark in
                existingMark.markNumber == newestMark.markNumber
            }

        case .clearAllMarks:
            return removeMarks { _ in true }

        case .addCardRow(let row):
            guard let cardMarkIndex = marks.lastIndex(where: { $0.shape.isExplanationCard }),
                  case .explanationCard(let card) = marks[cardMarkIndex].shape,
                  card.rows.count < ClickyExplanationCard.maximumRowCount else {
                return .nothingChanged
            }
            // The card keeps its number and its place in the order of the marks: it is the same
            // mark with one more row.
            let cardMarkWithRow = ClickyDrawingMark(
                markNumber: marks[cardMarkIndex].markNumber,
                shape: .explanationCard(card.addingRow(row)),
                screenNumber: marks[cardMarkIndex].screenNumber
            )
            marks[cardMarkIndex] = cardMarkWithRow
            return .addedRowToCard(cardMark: cardMarkWithRow, rowIndex: card.rows.count)
        }
    }

    /// The explanation card on the board, if there is one.
    var explanationCardMark: ClickyDrawingMark? {
        marks.last { $0.shape.isExplanationCard }
    }

    /// Takes rows back off a card: used when the rows of an interrupted reply were accepted but
    /// never written on the screen, so the board and the screen agree again.
    mutating func keepOnlyFirstRows(_ rowCountToKeep: Int, ofCardWithMarkNumber cardMarkNumber: Int) {
        guard let cardMarkIndex = marks.firstIndex(where: { $0.markNumber == cardMarkNumber }),
              case .explanationCard(let card) = marks[cardMarkIndex].shape,
              card.rows.count > rowCountToKeep else {
            return
        }
        marks[cardMarkIndex] = ClickyDrawingMark(
            markNumber: cardMarkNumber,
            shape: .explanationCard(card.keepingFirstRows(rowCountToKeep)),
            screenNumber: marks[cardMarkIndex].screenNumber
        )
    }

    /// Removes the marks the overlay took off the screen by itself (the lifetime ran out, the page
    /// scrolled, a display went away). The numbering is not reset.
    @discardableResult
    mutating func removeMarks(where shouldRemoveMark: (ClickyDrawingMark) -> Bool) -> ClickyDrawingBoardChange {
        let removedMarks = marks.filter(shouldRemoveMark)
        guard !removedMarks.isEmpty else {
            return .nothingChanged
        }
        marks.removeAll(where: shouldRemoveMark)
        return .removedMarks(removedMarks)
    }
}

/// The short list of marks that goes into the next turn's system prompt, so Claude can erase or
/// add to a drawing it can no longer see (Clicky's own windows are left out of the screenshots).
nonisolated enum ClickyDrawingMarksOnScreenText {
    /// Returns nil when nothing is drawn, so an ordinary turn's prompt gets no extra section and
    /// stays byte-identical to what it was before drawing existed.
    static func sectionText(for marksOnScreen: [ClickyDrawingMark]) -> String? {
        guard !marksOnScreen.isEmpty else {
            return nil
        }

        var sectionText = "marks on screen (you drew these earlier and the user still sees them; they are not in the screenshot; positions are screenshot pixels; remove one with [DRAW:erase:id], the newest with [DRAW:undo], all of them with [DRAW:clear]):"
        for markOnScreen in marksOnScreen {
            sectionText += "\n- " + lineText(for: markOnScreen)
        }
        return sectionText
    }

    /// One mark as "m2: arrow from 300,200 to 160,60".
    static func lineText(for mark: ClickyDrawingMark) -> String {
        let shapeDescription: String
        switch mark.shape {
        case .arrow(let tail, let head):
            shapeDescription = "arrow from \(coordinateText(tail)) to \(coordinateText(head))"
        case .circle(let center, let radius):
            shapeDescription = "circle at \(coordinateText(center)) radius \(wholeNumberText(radius))"
        case .box(let topLeftCorner, let size):
            shapeDescription = "box at \(coordinateText(topLeftCorner)) size \(sizeText(size))"
        case .underline(let start, let end):
            shapeDescription = "underline from \(coordinateText(start)) to \(coordinateText(end))"
        case .highlight(let topLeftCorner, let size):
            shapeDescription = "highlight at \(coordinateText(topLeftCorner)) size \(sizeText(size))"
        case .label(let topLeftCorner, let text):
            shapeDescription = "label at \(coordinateText(topLeftCorner)) saying \"\(text)\""
        case .stickyNote(let topLeftCorner, let text):
            shapeDescription = "sticky note at \(coordinateText(topLeftCorner)) saying \"\(text)\""
        case .callout(let target, let text, let calloutNumber):
            shapeDescription = "callout \(calloutNumber) pointing at \(coordinateText(target)) saying \"\(text)\""
        case .explanationCard(let card):
            // The card has no position to give: the app placed it. Its rows are listed the way
            // their tags are written, so the model can see what is on it and add to it.
            let rowsDescription = card.rows.isEmpty
                ? "no rows yet"
                : "rows: " + card.rows.map { "[ROW:\($0.canonicalTagBody)]" }.joined(separator: " ")
            let roomDescription = card.rows.count < ClickyExplanationCard.maximumRowCount
                ? "add a row with [ROW:...]"
                : "it is full"
            shapeDescription = "card titled \"\(card.title)\", \(rowsDescription) (\(roomDescription); a new [CARD:title] replaces it)"
        }

        let screenDescription = mark.screenNumber.map { " (screen \($0))" } ?? ""
        return "\(mark.markIdentifier): \(shapeDescription)\(screenDescription)"
    }

    /// Coordinates are written as whole pixels, the way the tags ask for them.
    static func wholeNumberText(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    static func coordinateText(_ point: ClickyDrawingPoint) -> String {
        "\(wholeNumberText(point.x)),\(wholeNumberText(point.y))"
    }

    private static func sizeText(_ size: ClickyDrawingSize) -> String {
        "\(wholeNumberText(size.width))x\(wholeNumberText(size.height))"
    }
}
