import Foundation

// Round 17 (file editing): a plain line diff for the change card. Foundation only.

nonisolated enum ClickyDiffLineKind: Equatable {
    case context
    case added
    case removed
    /// Shown between two changed regions that do not touch ("…").
    case hunkSeparator
}

nonisolated struct ClickyDiffLine: Equatable {
    let kind: ClickyDiffLineKind
    let text: String
    /// The 1-based line number in the old text (nil for an added line and a separator).
    let oldLineNumber: Int?
    /// The 1-based line number in the new text (nil for a removed line and a separator).
    let newLineNumber: Int?
}

nonisolated enum ClickyLineDiff {
    /// A changed region bigger than this many old lines times new lines is not compared line by
    /// line (that would need a table of this many cells); all its old lines show as removed and all
    /// its new lines as added. An edit of a few lines never gets near it.
    static let maximumComparedCellCount = 4_000_000

    /// Every line of both texts in order, each marked context, removed or added. Lines shared by the
    /// start and the end of the two texts are found first, so a small edit in a big file costs
    /// next to nothing.
    static func allLines(oldLines: [String], newLines: [String]) -> [ClickyDiffLine] {
        var commonPrefixCount = 0
        while commonPrefixCount < oldLines.count, commonPrefixCount < newLines.count,
              oldLines[commonPrefixCount] == newLines[commonPrefixCount] {
            commonPrefixCount += 1
        }
        var commonSuffixCount = 0
        while commonSuffixCount < oldLines.count - commonPrefixCount,
              commonSuffixCount < newLines.count - commonPrefixCount,
              oldLines[oldLines.count - 1 - commonSuffixCount] == newLines[newLines.count - 1 - commonSuffixCount] {
            commonSuffixCount += 1
        }

        let changedOldLines = Array(oldLines[commonPrefixCount..<(oldLines.count - commonSuffixCount)])
        let changedNewLines = Array(newLines[commonPrefixCount..<(newLines.count - commonSuffixCount)])

        var diffLines: [ClickyDiffLine] = []
        for lineIndex in 0..<commonPrefixCount {
            diffLines.append(ClickyDiffLine(kind: .context, text: oldLines[lineIndex], oldLineNumber: lineIndex + 1, newLineNumber: lineIndex + 1))
        }
        diffLines.append(contentsOf: comparedLines(
            oldLines: changedOldLines,
            newLines: changedNewLines,
            firstOldLineNumber: commonPrefixCount + 1,
            firstNewLineNumber: commonPrefixCount + 1
        ))
        for suffixOffset in 0..<commonSuffixCount {
            let oldIndex = oldLines.count - commonSuffixCount + suffixOffset
            let newIndex = newLines.count - commonSuffixCount + suffixOffset
            diffLines.append(ClickyDiffLine(kind: .context, text: oldLines[oldIndex], oldLineNumber: oldIndex + 1, newLineNumber: newIndex + 1))
        }
        return diffLines
    }

    /// The changed lines with `contextLineCount` unchanged lines on each side, in the style of a
    /// unified diff. Two regions whose context would overlap are one region; regions further apart
    /// are separated by a `.hunkSeparator` line. Nothing changed gives no lines.
    static func hunks(oldLines: [String], newLines: [String], contextLineCount: Int = 2) -> [ClickyDiffLine] {
        let everyLine = allLines(oldLines: oldLines, newLines: newLines)
        let changedLineIndexes = everyLine.indices.filter { everyLine[$0].kind != .context }
        guard !changedLineIndexes.isEmpty else {
            return []
        }

        var indexesToShow = Set<Int>()
        for changedLineIndex in changedLineIndexes {
            let firstIndex = max(0, changedLineIndex - contextLineCount)
            let lastIndex = min(everyLine.count - 1, changedLineIndex + contextLineCount)
            for indexToShow in firstIndex...lastIndex {
                indexesToShow.insert(indexToShow)
            }
        }

        var hunkLines: [ClickyDiffLine] = []
        var previousShownIndex: Int?
        for indexToShow in indexesToShow.sorted() {
            if let previousShownIndex, indexToShow > previousShownIndex + 1 {
                hunkLines.append(ClickyDiffLine(kind: .hunkSeparator, text: "…", oldLineNumber: nil, newLineNumber: nil))
            }
            hunkLines.append(everyLine[indexToShow])
            previousShownIndex = indexToShow
        }
        return hunkLines
    }

    /// The lines of a new file as they show on the card: every line added.
    static func addedLines(of newLines: [String]) -> [ClickyDiffLine] {
        newLines.enumerated().map { lineIndex, line in
            ClickyDiffLine(kind: .added, text: line, oldLineNumber: nil, newLineNumber: lineIndex + 1)
        }
    }

    // MARK: - The changed region

    /// A longest common subsequence of the two regions, walked from the start so that within one
    /// changed block the removed lines come before the added ones.
    private static func comparedLines(
        oldLines: [String],
        newLines: [String],
        firstOldLineNumber: Int,
        firstNewLineNumber: Int
    ) -> [ClickyDiffLine] {
        func allRemovedThenAllAdded() -> [ClickyDiffLine] {
            var lines: [ClickyDiffLine] = []
            for (offset, line) in oldLines.enumerated() {
                lines.append(ClickyDiffLine(kind: .removed, text: line, oldLineNumber: firstOldLineNumber + offset, newLineNumber: nil))
            }
            for (offset, line) in newLines.enumerated() {
                lines.append(ClickyDiffLine(kind: .added, text: line, oldLineNumber: nil, newLineNumber: firstNewLineNumber + offset))
            }
            return lines
        }

        if oldLines.isEmpty || newLines.isEmpty {
            return allRemovedThenAllAdded()
        }
        let tableRowCount = oldLines.count + 1
        let tableColumnCount = newLines.count + 1
        if tableRowCount * tableColumnCount > maximumComparedCellCount {
            return allRemovedThenAllAdded()
        }

        // commonLengthFromHere[oldIndex][newIndex]: how many lines the two tails have in common.
        var commonLengthFromHere = [Int32](repeating: 0, count: tableRowCount * tableColumnCount)
        func cell(_ oldIndex: Int, _ newIndex: Int) -> Int {
            oldIndex * tableColumnCount + newIndex
        }
        for oldIndex in stride(from: oldLines.count - 1, through: 0, by: -1) {
            for newIndex in stride(from: newLines.count - 1, through: 0, by: -1) {
                if oldLines[oldIndex] == newLines[newIndex] {
                    commonLengthFromHere[cell(oldIndex, newIndex)] = commonLengthFromHere[cell(oldIndex + 1, newIndex + 1)] + 1
                } else {
                    commonLengthFromHere[cell(oldIndex, newIndex)] = max(
                        commonLengthFromHere[cell(oldIndex + 1, newIndex)],
                        commonLengthFromHere[cell(oldIndex, newIndex + 1)]
                    )
                }
            }
        }

        var lines: [ClickyDiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, newIndex < newLines.count, oldLines[oldIndex] == newLines[newIndex] {
                lines.append(ClickyDiffLine(kind: .context, text: oldLines[oldIndex], oldLineNumber: firstOldLineNumber + oldIndex, newLineNumber: firstNewLineNumber + newIndex))
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < oldLines.count,
                      newIndex == newLines.count || commonLengthFromHere[cell(oldIndex + 1, newIndex)] >= commonLengthFromHere[cell(oldIndex, newIndex + 1)] {
                lines.append(ClickyDiffLine(kind: .removed, text: oldLines[oldIndex], oldLineNumber: firstOldLineNumber + oldIndex, newLineNumber: nil))
                oldIndex += 1
            } else {
                lines.append(ClickyDiffLine(kind: .added, text: newLines[newIndex], oldLineNumber: nil, newLineNumber: firstNewLineNumber + newIndex))
                newIndex += 1
            }
        }
        return lines
    }
}
