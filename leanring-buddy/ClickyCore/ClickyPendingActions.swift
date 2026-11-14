import Foundation

// Round 18 (Jarvis actions): the actions that wait for the user's return or spoken yes next to the
// file changes (a shortcut to run, a link that is not a plain link to a well-known site), the words
// they have in the model's history and on the change card, and how a confirmed set is carried out:
// the file changes first (all or nothing), then each action in order. Foundation only.

// MARK: - A waiting action

nonisolated enum ClickyPendingAction: Equatable, Sendable {
    case runShortcut(name: String)
    case openLink(url: URL)

    var actionKind: ClickyActionKind {
        switch self {
        case .runShortcut: return .runShortcutQueued
        case .openLink: return .openLinkQueued
        }
    }

    var isShortcut: Bool {
        if case .runShortcut = self { return true }
        return false
    }

    var isLink: Bool {
        if case .openLink = self { return true }
        return false
    }
}

// MARK: - Words for the history

nonisolated enum ClickyActionHistoryText {
    static let maximumPayloadCharacters = ClickyFileEditingLimits.maximumSummaryCharacters

    /// A payload (a shortcut name, a link) made safe for a history line: one line, no square
    /// brackets (it cannot spell a reply tag), straight double quotes turned single, cut to 100
    /// characters, and nil when it looks like a secret (the line then leaves it out).
    static func cleanedPayload(_ rawPayload: String) -> String? {
        let cleanedText = ClickyActionText.oneLine(rawPayload, maximumCharacters: maximumPayloadCharacters)
        if cleanedText.isEmpty || ClickySecretDetector.textLooksLikeASecret(cleanedText) {
            return nil
        }
        return cleanedText
    }

    /// "github.com/SamSto4/Clicker": the host (no "www.") and the path, with no scheme.
    static func shortAddress(of url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        let path = url.path == "/" ? "" : url.path
        return host + path
    }

    /// `run shortcut "morning routine"` or `open link https://example.com/x`. A payload that looks
    /// like a secret is left out (`run shortcut`, `open link`).
    static func description(for action: ClickyPendingAction) -> String {
        switch action {
        case .runShortcut(let name):
            guard let cleanedName = cleanedPayload(name) else { return "run shortcut" }
            return "run shortcut \"\(cleanedName)\""
        case .openLink(let url):
            guard let cleanedLink = cleanedPayload(url.absoluteString) else { return "open link" }
            return "open link \(cleanedLink)"
        }
    }

    static func proposalLine(for action: ClickyPendingAction) -> String {
        "[proposed: " + description(for: action) + "]"
    }

    static func doneLine(_ doneText: String) -> String {
        "[done: " + doneText + "]"
    }

    /// What is added to the model's history text of a turn that did things at once or queued actions:
    /// one `[done: ...]` line per action done, then one `[proposed: ...]` line per file change and
    /// per queued action, each on its own line after the reply's words.
    static func historyText(
        appendingDoneLines doneTexts: [String],
        queuedActions: [ClickyPendingAction],
        to historyText: String
    ) -> String {
        var addedLines = doneTexts.compactMap { doneText -> String? in
            guard let cleanedText = cleanedPayload(doneText) else { return nil }
            return doneLine(cleanedText)
        }
        addedLines.append(contentsOf: queuedActions.map { proposalLine(for: $0) })
        guard !addedLines.isEmpty else {
            return historyText
        }
        let addedText = addedLines.joined(separator: "\n")
        return historyText.isEmpty ? addedText : historyText + "\n" + addedText
    }

    /// `ran shortcut "x"` / `opened github.com/x`, for the "[applied: ...]" line of a confirmed set.
    static func appliedDescription(for action: ClickyPendingAction) -> String {
        switch action {
        case .runShortcut(let name):
            guard let cleanedName = cleanedPayload(name) else { return "ran a shortcut" }
            return "ran shortcut \"\(cleanedName)\""
        case .openLink(let url):
            guard let cleanedAddress = cleanedPayload(shortAddress(of: url)) else { return "opened a link" }
            return "opened \(cleanedAddress)"
        }
    }
}

// MARK: - The card

/// One waiting action as the change card shows it.
nonisolated struct ClickyChangeCardActionRow: Equatable {
    /// "run shortcut" / "open link".
    let actionTitle: String
    /// The shortcut's name, or the whole link (shown monospaced and wrapped).
    let detailText: String
    let detailIsMonospaced: Bool
    /// "can't be undone" for a shortcut.
    let noteText: String?

    static func make(for action: ClickyPendingAction) -> ClickyChangeCardActionRow {
        switch action {
        case .runShortcut(let name):
            return ClickyChangeCardActionRow(actionTitle: "run shortcut", detailText: name, detailIsMonospaced: false, noteText: "can't be undone")
        case .openLink(let url):
            return ClickyChangeCardActionRow(actionTitle: "open link", detailText: ClickyLinkRule.displayText(for: url), detailIsMonospaced: true, noteText: nil)
        }
    }
}

// MARK: - Carrying out the actions of a confirmed set

nonisolated struct ClickyActionRunResult: Equatable, Sendable {
    let action: ClickyPendingAction
    let succeeded: Bool
    /// One line for the card: `ran shortcut "x".`, `that shortcut failed.`, `opened github.com/x.`
    let lineText: String
}

nonisolated enum ClickyPendingActionRunner {
    static let shortcutFailedSentence = "that shortcut failed."
    static let linkFailedSentence = "i couldn't open that link."

    /// Runs the actions in order, each with its own result line. A failed action does not stop the
    /// ones after it.
    static func run(_ actions: [ClickyPendingAction], executor: ClickyActionExecutor) async -> [ClickyActionRunResult] {
        var results: [ClickyActionRunResult] = []
        for action in actions {
            switch action {
            case .runShortcut(let name):
                let succeeded = await executor.runShortcut(named: name)
                results.append(ClickyActionRunResult(
                    action: action,
                    succeeded: succeeded,
                    lineText: succeeded ? ClickyActionHistoryText.appliedDescription(for: action) + "." : shortcutFailedSentence
                ))
            case .openLink(let url):
                let succeeded = await executor.openLink(url)
                results.append(ClickyActionRunResult(
                    action: action,
                    succeeded: succeeded,
                    lineText: succeeded ? ClickyActionHistoryText.appliedDescription(for: action) + "." : linkFailedSentence
                ))
            }
        }
        return results
    }
}

nonisolated enum ClickySetApplyOutcome {
    /// The file changes (when there were any) were written, and every action was tried.
    case applied(fileRecord: ClickyAppliedChangeRecord?, actionResults: [ClickyActionRunResult])
    /// A file is no longer what it was when the change was proposed. Nothing was written, and no
    /// action ran.
    case refusedBecauseFileChanged
    /// Something could not be written; whatever was done has been put back. No action ran.
    case failed(reason: String)
}

nonisolated enum ClickySetApplier {
    /// Applies a confirmed set: the file changes first, all or nothing, exactly as round 17 does; if
    /// they are refused or fail, no action runs. Then the actions in order. A set with no file
    /// changes goes straight to its actions. Blocks on the disk, so the app calls it off the main thread.
    static func apply(
        changeSet: ClickyPendingChangeSet,
        backupsRootDirectoryURL: URL,
        executor: ClickyActionExecutor,
        now: Date,
        fileManager: FileManager = .default,
        trashItem: @escaping ClickyChangeApplier.TrashItem = ClickyChangeApplier.defaultTrashItem
    ) async -> ClickySetApplyOutcome {
        var fileRecord: ClickyAppliedChangeRecord?
        if !changeSet.changes.isEmpty {
            switch ClickyChangeApplier.apply(
                changeSet: changeSet,
                backupsRootDirectoryURL: backupsRootDirectoryURL,
                now: now,
                fileManager: fileManager,
                trashItem: trashItem
            ) {
            case .refusedBecauseFileChanged:
                return .refusedBecauseFileChanged
            case .failed(let reason):
                return .failed(reason: reason)
            case .applied(let appliedRecord):
                fileRecord = appliedRecord
            }
        }
        let actionResults = await ClickyPendingActionRunner.run(changeSet.actions, executor: executor)
        return .applied(fileRecord: fileRecord, actionResults: actionResults)
    }
}

// MARK: - History lines for a whole set (file changes and actions together)

nonisolated enum ClickyPendingSetHistoryText {
    /// One line of description per thing that waits, file changes first: what the prompt's "waiting for
    /// the user's answer now" section lists. For a set of file changes alone these are exactly round
    /// 17's descriptions.
    static func waitingDescriptions(changes: [ClickyFileChange], actions: [ClickyPendingAction]) -> [String] {
        changes.map { ClickyChangeHistoryText.changeDescription(for: $0) } + actions.map { ClickyActionHistoryText.description(for: $0) }
    }

    /// The history lines of a set that was confirmed: `[applied: ...]` for the file changes and the
    /// actions that worked, and `[not applied: ...]` for an action that failed. For a set of file
    /// changes alone this is exactly round 17's single line.
    static func appliedLines(changes: [ClickyFileChange], actionResults: [ClickyActionRunResult]) -> [String] {
        let succeededActionTexts = actionResults.filter(\.succeeded).map { ClickyActionHistoryText.appliedDescription(for: $0.action) }
        let failedActionTexts = actionResults.filter { !$0.succeeded }.map { ClickyActionHistoryText.description(for: $0.action) }

        var lines: [String] = []
        if actionResults.isEmpty {
            if !changes.isEmpty {
                lines.append(ClickyChangeHistoryText.appliedHistoryLine(for: changes))
            }
        } else {
            let fileTexts = changes.map { "\($0.action.title) \(ClickyChangeHistoryText.cleanedPath($0.relativePath))" }
            let appliedTexts = fileTexts + succeededActionTexts
            if !appliedTexts.isEmpty {
                lines.append("[applied: " + appliedTexts.joined(separator: ", ") + "]")
            }
        }
        if !failedActionTexts.isEmpty {
            lines.append("[not applied: " + failedActionTexts.joined(separator: ", ") + "]")
        }
        return lines
    }

    /// `[not applied: ...]` for a set that was cancelled, expired or refused. For file changes alone
    /// it is exactly round 17's line.
    static func notAppliedLine(changes: [ClickyFileChange], actions: [ClickyPendingAction]) -> String {
        if actions.isEmpty {
            return ClickyChangeHistoryText.discardedHistoryLine(for: changes)
        }
        let fileTexts = changes.map { "\($0.action.title) \(ClickyChangeHistoryText.cleanedPath($0.relativePath))" }
        return "[not applied: " + (fileTexts + actions.map { ClickyActionHistoryText.description(for: $0) }).joined(separator: ", ") + "]"
    }
}
