import Foundation

// Round 17 (file editing): the change the model proposed, the set of changes one turn queued, how
// they read in the model's history, and what the change card shows. Foundation only.

nonisolated enum ClickyFileChangeAction: String, Equatable {
    case edit
    case newFile
    case delete

    /// The words the history line and the card use.
    var title: String {
        switch self {
        case .edit: return "edit"
        case .newFile: return "new file"
        case .delete: return "delete"
        }
    }
}

nonisolated struct ClickyFileChange: Equatable {
    let identifier: UUID
    let action: ClickyFileChangeAction
    /// The file, with symbolic links resolved.
    let fileURL: URL
    let allowedFolderURL: URL
    /// The path below the allowed folder, which is what the card and the history line show.
    let relativePath: String
    /// The model's one-line summary, already cleaned (`ClickyChangeHistoryText.cleanedSummary`).
    let summary: String
    /// An edit: the text to replace and what replaces it, with line breaks in the style of the file.
    let oldText: String?
    let newText: String?
    /// A new file: everything that goes in it.
    let newFileContent: String?
    /// The first lines of the diff as the card shows them (secret-looking lines hidden), at most
    /// `ClickyChangeCardContent.maximumLinesPerChange`, and how many more there were.
    let diffPreviewLines: [ClickyDiffLine]
    let hiddenDiffLineCount: Int
    /// A delete: what the file was, for the card ("12 lines" or the size).
    let deletedFileDescription: String?
}

nonisolated struct ClickyPendingChangeSet: Equatable {
    let identifier: UUID
    let changes: [ClickyFileChange]
    let proposedAt: Date

    init(identifier: UUID = UUID(), changes: [ClickyFileChange], proposedAt: Date) {
        self.identifier = identifier
        self.changes = changes
        self.proposedAt = proposedAt
    }

    func expiresAt() -> Date {
        proposedAt.addingTimeInterval(ClickyFileEditingLimits.pendingChangeLifetimeSeconds)
    }

    func isExpired(at moment: Date) -> Bool {
        moment >= expiresAt()
    }
}

// MARK: - Words for the history

/// How a proposal is written down for the model's conversation history, so the next turn knows what
/// is pending. These lines go to the model only; the chat store's display text (which memory
/// compaction reads) never holds them.
nonisolated enum ClickyChangeHistoryText {
    /// The model's own summary made safe to put in history: one line, no square brackets (it cannot
    /// spell a reply tag), cut to `maximumSummaryCharacters`, and empty when it looks like a secret.
    static func cleanedSummary(_ rawSummary: String) -> String {
        var cleanedText = rawSummary
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
        cleanedText = cleanedText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if ClickySecretDetector.textLooksLikeASecret(cleanedText) {
            return ""
        }
        if cleanedText.count > ClickyFileEditingLimits.maximumSummaryCharacters {
            cleanedText = String(cleanedText.prefix(ClickyFileEditingLimits.maximumSummaryCharacters - 1)) + "…"
        }
        return cleanedText
    }

    /// The path as a history line shows it: no square brackets, one line, at most 80 characters.
    static func cleanedPath(_ rawPath: String) -> String {
        var cleanedText = rawPath
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        if cleanedText.count > 80 {
            cleanedText = "…" + String(cleanedText.suffix(79))
        }
        return cleanedText
    }

    /// "edit Foo.swift: rename the button". No summary leaves the last part out.
    static func changeDescription(for change: ClickyFileChange) -> String {
        var descriptionText = "\(change.action.title) \(cleanedPath(change.relativePath))"
        if !change.summary.isEmpty {
            descriptionText += ": \(change.summary)"
        }
        return descriptionText
    }

    /// "[proposed: edit Foo.swift: rename the button]". No summary leaves the last part out.
    static func proposalLine(for change: ClickyFileChange) -> String {
        "[proposed: " + changeDescription(for: change) + "]"
    }

    static func proposalLines(for changes: [ClickyFileChange]) -> [String] {
        changes.map { proposalLine(for: $0) }
    }

    /// What is added to the model's history text of the turn that queued changes.
    static func historyTextAppending(proposalLinesOf changes: [ClickyFileChange], to historyText: String) -> String {
        guard !changes.isEmpty else {
            return historyText
        }
        let proposalText = proposalLines(for: changes).joined(separator: "\n")
        return historyText.isEmpty ? proposalText : historyText + "\n" + proposalText
    }

    /// The history text of a turn that applied or discarded a pending set without asking the model.
    static func appliedHistoryLine(for changes: [ClickyFileChange]) -> String {
        "[applied: " + changes.map { "\($0.action.title) \(cleanedPath($0.relativePath))" }.joined(separator: ", ") + "]"
    }

    static func discardedHistoryLine(for changes: [ClickyFileChange]) -> String {
        "[not applied: " + changes.map { "\($0.action.title) \(cleanedPath($0.relativePath))" }.joined(separator: ", ") + "]"
    }
}

// MARK: - What the card shows

nonisolated struct ClickyChangeCardSection: Equatable {
    /// "edit" / "new file" / "delete".
    let actionTitle: String
    let relativePath: String
    let summary: String
    /// A line under the title: "moves to the Trash" for a delete.
    let noteText: String?
    let diffLines: [ClickyDiffLine]
}

nonisolated struct ClickyChangeCardContent: Equatable {
    let sections: [ClickyChangeCardSection]
    /// The lines that did not fit in the card's limit ("+N more lines").
    let hiddenLineCount: Int

    static let maximumLinesPerChange = 40
    static let maximumLinesInCard = 40

    var hiddenLinesText: String? {
        hiddenLineCount > 0 ? "+\(hiddenLineCount) more lines" : nil
    }

    /// At most `maximumLinesInCard` diff lines are shown across all the changes, in order. A change
    /// that is not reached still gets its title, so the card names every file.
    static func make(for changes: [ClickyFileChange]) -> ClickyChangeCardContent {
        var remainingLineBudget = maximumLinesInCard
        var hiddenLineCount = 0
        var sections: [ClickyChangeCardSection] = []
        for change in changes {
            let linesToShow = Array(change.diffPreviewLines.prefix(remainingLineBudget))
            remainingLineBudget -= linesToShow.count
            hiddenLineCount += (change.diffPreviewLines.count - linesToShow.count) + change.hiddenDiffLineCount
            sections.append(ClickyChangeCardSection(
                actionTitle: change.action.title,
                relativePath: change.relativePath,
                summary: change.summary,
                noteText: noteText(for: change),
                diffLines: linesToShow
            ))
        }
        return ClickyChangeCardContent(sections: sections, hiddenLineCount: hiddenLineCount)
    }

    private static func noteText(for change: ClickyFileChange) -> String? {
        switch change.action {
        case .delete:
            if let deletedFileDescription = change.deletedFileDescription {
                return "moves to the Trash (\(deletedFileDescription))"
            }
            return "moves to the Trash"
        case .newFile, .edit:
            return nil
        }
    }
}

// MARK: - The diff of a change, as the card shows it

nonisolated enum ClickyChangeDiffPreview {
    /// The first lines of the diff of a whole-file change, with lines that look like credentials
    /// hidden, and how many more lines there were.
    static func preview(of diffLines: [ClickyDiffLine]) -> (lines: [ClickyDiffLine], hiddenLineCount: Int) {
        let linesToKeep = Array(diffLines.prefix(ClickyChangeCardContent.maximumLinesPerChange))
        let maskedLines = linesToKeep.map { diffLine -> ClickyDiffLine in
            guard diffLine.kind != .hunkSeparator, ClickySecretDetector.textHoldsCredentialShape(diffLine.text) else {
                return diffLine
            }
            return ClickyDiffLine(
                kind: diffLine.kind,
                text: ClickyFileContentRedaction.removedLineMarker,
                oldLineNumber: diffLine.oldLineNumber,
                newLineNumber: diffLine.newLineNumber
            )
        }
        return (maskedLines, diffLines.count - linesToKeep.count)
    }
}
