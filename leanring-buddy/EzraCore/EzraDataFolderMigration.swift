import Foundation

// The rename of Clicky to Ezra (15 Nov 2026). The app's data folders carried the old name, so each one
// moves to its new name once, at launch, before anything reads it:
// - `~/Documents/Clicky Notes` becomes `~/Documents/Ezra Notes` (the daily notes and profile.md);
// - `~/Library/Logs/Clicky` becomes `~/Library/Logs/Ezra` (only this app's metrics logs are in it);
// - six entries of `~/Library/Application Support/Clicky` move into `~/Library/Application Support/Ezra`:
//   Chats, Memories, Backups, Timers, Voices and Context. Each entry moves on its own, and the old
//   `Clicky` folder itself never moves, is never renamed and is never deleted: another app on this Mac
//   keeps its own files there (AgentHarness, BrowserBridge, OneBrain and more).
//
// The rule for each folder (`decision`): when the old folder exists and the new name is free, the old
// folder is renamed (on the same volume); when both exist, the app uses the new one and leaves the old
// one alone; when neither exists, nothing happens. A move that fails prints one line and the app goes
// on with the new folder. Nothing is ever deleted.
//
// This file is the one place that still needs the old names, which is why the rename script leaves it
// alone. Everything here is Foundation only; `moveDataFolders` takes every folder and every fact it
// needs as parameters, so the checks run it on a temporary home folder.

nonisolated enum EzraDataFolderMigration {
    // MARK: - The names

    static let oldNotesFolderName = "Clicky Notes"
    static let newNotesFolderName = "Ezra Notes"
    /// The app's own folder in `~/Library/Logs` and in `~/Library/Application Support`, before and after.
    static let oldAppFolderName = "Clicky"
    static let newAppFolderName = "Ezra"
    /// This app's own entries of the old Application Support folder (`Context` came with round 21b).
    /// Everything else in that folder belongs to another app and stays where it is.
    static let applicationSupportEntryNames = ["Chats", "Memories", "Backups", "Timers", "Voices", "Context"]

    /// The notes folder is in `~/Documents`, which is protected and iCloud-backed: looking into it can
    /// show a macOS access prompt (so it waits for onboarding, like the launch warm-up) and its first
    /// access in a new process has taken seconds. Once its move is settled, this flag skips the look.
    static let notesFolderMoveIsSettledUserDefaultsKey = "ezraNotesFolderMoveIsSettled"
    /// The key `CompanionManager.hasCompletedOnboarding` reads and writes.
    static let onboardingCompletedUserDefaultsKey = "hasCompletedOnboarding"

    // MARK: - One folder's move

    /// One folder that moves: its place under the old name and under the new one.
    struct FolderMove: Equatable, Sendable {
        /// Short words for the console line: "notes", "logs", "chats", "memories", ...
        let shortName: String
        let oldFolderURL: URL
        let newFolderURL: URL
    }

    /// What is at a path. A link counts as what it points to; a link that points nowhere is something
    /// else. `cannotBeRead` is a path the app may not look at (a macOS privacy refusal, for instance):
    /// it is never taken for "nothing there", so a refusal never settles a move that has not happened.
    enum ItemAtPath: Equatable, Sendable {
        case nothing
        case folder
        case somethingElse
        case cannotBeRead
    }

    enum Decision: Equatable, Sendable {
        /// The old folder exists and the new name is free: rename the old folder.
        case moveOldFolderToNewName
        /// No old folder: nothing to do (also when only the new folder exists).
        case nothingToMove
        /// Both exist: the app uses the new folder, and the old one is left alone.
        case useNewFolderAndLeaveOldAlone
        /// Something that is not a folder has the new name: the old folder stays where it is.
        case leaveOldFolderBecauseSomethingElseHasTheNewName
        /// Something that is not a folder has the old name: it is not a folder this app made.
        case leaveOldItemBecauseItIsNotAFolder
        /// The old folder, or the new name when there is an old folder, could not be looked at.
        case cannotTellWhatIsThere
    }

    static func decision(oldItem: ItemAtPath, newItem: ItemAtPath) -> Decision {
        switch (oldItem, newItem) {
        case (.nothing, _):
            return .nothingToMove
        case (.cannotBeRead, _), (.folder, .cannotBeRead):
            return .cannotTellWhatIsThere
        case (.somethingElse, _):
            return .leaveOldItemBecauseItIsNotAFolder
        case (.folder, .nothing):
            return .moveOldFolderToNewName
        case (.folder, .folder):
            return .useNewFolderAndLeaveOldAlone
        case (.folder, .somethingElse):
            return .leaveOldFolderBecauseSomethingElseHasTheNewName
        }
    }

    enum Outcome: Equatable, Sendable {
        case moved
        case nothingToMove
        case keptBothAndUsedNewFolder
        case leftOldItemAloneBecauseItIsNotAFolder
        case failed(reason: String)

        /// True when a later launch has nothing left to try for this folder.
        var isSettled: Bool {
            if case .failed = self {
                return false
            }
            return true
        }
    }

    struct MoveResult: Equatable, Sendable {
        let folderMove: FolderMove
        let outcome: Outcome
    }

    // MARK: - The folders

    static func notesFolderMove(documentsDirectoryURL: URL) -> FolderMove {
        FolderMove(
            shortName: "notes",
            oldFolderURL: documentsDirectoryURL.appendingPathComponent(oldNotesFolderName, isDirectory: true),
            newFolderURL: documentsDirectoryURL.appendingPathComponent(newNotesFolderName, isDirectory: true)
        )
    }

    static func logsFolderMove(libraryLogsDirectoryURL: URL) -> FolderMove {
        FolderMove(
            shortName: "logs",
            oldFolderURL: libraryLogsDirectoryURL.appendingPathComponent(oldAppFolderName, isDirectory: true),
            newFolderURL: libraryLogsDirectoryURL.appendingPathComponent(newAppFolderName, isDirectory: true)
        )
    }

    /// One move per entry, never one for the old folder as a whole.
    static func applicationSupportEntryMoves(applicationSupportDirectoryURL: URL) -> [FolderMove] {
        let oldAppFolderURL = applicationSupportDirectoryURL.appendingPathComponent(oldAppFolderName, isDirectory: true)
        let newAppFolderURL = applicationSupportDirectoryURL.appendingPathComponent(newAppFolderName, isDirectory: true)
        return applicationSupportEntryNames.map { entryName in
            FolderMove(
                shortName: entryName.lowercased(),
                oldFolderURL: oldAppFolderURL.appendingPathComponent(entryName, isDirectory: true),
                newFolderURL: newAppFolderURL.appendingPathComponent(entryName, isDirectory: true)
            )
        }
    }

    /// The base folders of this Mac, found the way the stores find theirs (`EzraNoteStore`,
    /// `EzraChatStore`, `EzraTurnMetricsLog` and the others), so the new names are exactly their folders.
    static var realDocumentsDirectoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
    }

    static var realApplicationSupportDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static var realLibraryLogsDirectoryURL: URL {
        let libraryDirectoryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return libraryDirectoryURL.appendingPathComponent("Logs", isDirectory: true)
    }

    // MARK: - Doing it

    static func itemAtPath(_ path: String, fileManager: FileManager) -> ItemAtPath {
        let attributes: [FileAttributeKey: Any]
        do {
            // Does not follow a link at the end of the path, so a link that points nowhere is seen too.
            attributes = try fileManager.attributesOfItem(atPath: path)
        } catch {
            return errorMeansNothingIsThere(error as NSError) ? .nothing : .cannotBeRead
        }
        let itemType = attributes[.type] as? FileAttributeType
        if itemType == .typeSymbolicLink {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? .folder : .somethingElse
            }
            // A link that points nowhere still holds the name, so a move onto it would fail.
            return .somethingElse
        }
        return itemType == .typeDirectory ? .folder : .somethingElse
    }

    /// No such file, or a part of the path that is a file and not a folder: nothing can be at the path.
    /// Every other error (such as a privacy refusal) means the app could not look.
    private static func errorMeansNothingIsThere(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return true
        }
        let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError
        for posixError in [error, underlyingError].compactMap({ $0 }) where posixError.domain == NSPOSIXErrorDomain {
            if posixError.code == Int(ENOENT) || posixError.code == Int(ENOTDIR) {
                return true
            }
        }
        return false
    }

    /// Applies the rule to each folder in turn. Never throws and never deletes anything: a move is
    /// `FileManager.moveItem`, which refuses to replace anything at the new name.
    static func moveFolders(_ folderMoves: [FolderMove], fileManager: FileManager) -> [MoveResult] {
        folderMoves.map { folderMove in
            let oldItem = itemAtPath(folderMove.oldFolderURL.path, fileManager: fileManager)
            let newItem = itemAtPath(folderMove.newFolderURL.path, fileManager: fileManager)
            switch decision(oldItem: oldItem, newItem: newItem) {
            case .nothingToMove:
                return MoveResult(folderMove: folderMove, outcome: .nothingToMove)
            case .leaveOldItemBecauseItIsNotAFolder:
                return MoveResult(folderMove: folderMove, outcome: .leftOldItemAloneBecauseItIsNotAFolder)
            case .useNewFolderAndLeaveOldAlone:
                return MoveResult(folderMove: folderMove, outcome: .keptBothAndUsedNewFolder)
            case .leaveOldFolderBecauseSomethingElseHasTheNewName:
                return MoveResult(folderMove: folderMove, outcome: .failed(reason: "something that is not a folder has the new name"))
            case .cannotTellWhatIsThere:
                return MoveResult(folderMove: folderMove, outcome: .failed(reason: "the folder could not be looked at"))
            case .moveOldFolderToNewName:
                do {
                    // The new parent: ~/Library/Application Support/Ezra for an entry (the others exist already).
                    try fileManager.createDirectory(at: folderMove.newFolderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: folderMove.oldFolderURL, to: folderMove.newFolderURL)
                    return MoveResult(folderMove: folderMove, outcome: .moved)
                } catch {
                    return MoveResult(folderMove: folderMove, outcome: .failed(reason: error.localizedDescription))
                }
            }
        }
    }

    /// The one line the console gets for a folder, or nil when there is nothing to say.
    static func consoleLine(for moveResult: MoveResult) -> String? {
        let folderMove = moveResult.folderMove
        switch moveResult.outcome {
        case .nothingToMove:
            return nil
        case .moved:
            return "📦 Ezra: moved the \(folderMove.shortName) folder to \(folderMove.newFolderURL.path)"
        case .keptBothAndUsedNewFolder:
            return "📦 Ezra: \(folderMove.oldFolderURL.path) and \(folderMove.newFolderURL.path) both exist; using the new one and leaving the old one alone"
        case .leftOldItemAloneBecauseItIsNotAFolder:
            return "📦 Ezra: \(folderMove.oldFolderURL.path) is not a folder, so it stays where it is"
        case .failed(let reason):
            return "⚠️ Ezra: couldn't move the \(folderMove.shortName) folder to \(folderMove.newFolderURL.path) (\(reason)); using the new folder"
        }
    }

    /// What one launch did.
    struct LaunchReport: Equatable, Sendable {
        let results: [MoveResult]
        /// True when the notes folder's move is settled after this launch (settled before, or settled now).
        let notesFolderMoveIsSettled: Bool
        let skippedBecauseASelfTestIsRunning: Bool
    }

    /// The whole move for one launch, with every folder and fact passed in.
    /// - A self test (the panel's or the drawing's) moves nothing: self tests never touch the real folders.
    /// - The notes folder is looked at only after onboarding and only until its move is settled (see
    ///   `notesFolderMoveIsSettledUserDefaultsKey`). The logs and the Application Support entries are
    ///   local folders, quick to look at, so they are looked at on every launch.
    static func moveDataFolders(
        environment: [String: String],
        hasCompletedOnboarding: Bool,
        notesFolderMoveWasSettledBefore: Bool,
        documentsDirectoryURL: URL,
        applicationSupportDirectoryURL: URL,
        libraryLogsDirectoryURL: URL,
        fileManager: FileManager
    ) -> LaunchReport {
        let isSelfTest = environment[EzraChatStore.panelSelfTestEnvironmentVariable] == "1"
            || environment[EzraTimerStore.drawingSelfTestEnvironmentVariable] == "1"
        guard !isSelfTest else {
            return LaunchReport(results: [], notesFolderMoveIsSettled: notesFolderMoveWasSettledBefore, skippedBecauseASelfTestIsRunning: true)
        }
        var folderMoves = [logsFolderMove(libraryLogsDirectoryURL: libraryLogsDirectoryURL)]
        folderMoves += applicationSupportEntryMoves(applicationSupportDirectoryURL: applicationSupportDirectoryURL)
        let looksAtNotesFolder = hasCompletedOnboarding && !notesFolderMoveWasSettledBefore
        let notesMove = notesFolderMove(documentsDirectoryURL: documentsDirectoryURL)
        if looksAtNotesFolder {
            folderMoves.append(notesMove)
        }
        let results = moveFolders(folderMoves, fileManager: fileManager)
        let notesResultIsSettled = results.first(where: { $0.folderMove == notesMove })?.outcome.isSettled ?? false
        return LaunchReport(
            results: results,
            notesFolderMoveIsSettled: notesFolderMoveWasSettledBefore || notesResultIsSettled,
            skippedBecauseASelfTestIsRunning: false
        )
    }

    /// The one call at launch (`CompanionAppDelegate.init`, before `CompanionManager`, whose stores read
    /// these folders, exists): this Mac's folders, `UserDefaults.standard` and one console line per folder
    /// that moved or could not move.
    static func moveDataFoldersAtLaunch() {
        let userDefaults = UserDefaults.standard
        let notesFolderMoveWasSettledBefore = userDefaults.bool(forKey: notesFolderMoveIsSettledUserDefaultsKey)
        let launchReport = moveDataFolders(
            environment: ProcessInfo.processInfo.environment,
            hasCompletedOnboarding: userDefaults.bool(forKey: onboardingCompletedUserDefaultsKey),
            notesFolderMoveWasSettledBefore: notesFolderMoveWasSettledBefore,
            documentsDirectoryURL: realDocumentsDirectoryURL,
            applicationSupportDirectoryURL: realApplicationSupportDirectoryURL,
            libraryLogsDirectoryURL: realLibraryLogsDirectoryURL,
            fileManager: FileManager.default
        )
        for moveResult in launchReport.results {
            if let consoleLine = consoleLine(for: moveResult) {
                print(consoleLine)
            }
        }
        if launchReport.notesFolderMoveIsSettled && !notesFolderMoveWasSettledBefore {
            userDefaults.set(true, forKey: notesFolderMoveIsSettledUserDefaultsKey)
        }
    }
}
