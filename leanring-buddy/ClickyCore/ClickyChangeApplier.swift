import Foundation

// Round 17 (file editing): applying a confirmed set of changes (check again, back up, write
// atomically with the file's permissions, move to the Trash), undoing it, and pruning old backups.
// Foundation only. Everything here blocks on the disk, so the app calls it off the main thread.

// MARK: - What was applied

nonisolated struct ClickyAppliedFileEntry: Equatable {
    let action: ClickyFileChangeAction
    let fileURL: URL
    let relativePath: String
    /// The file's own bytes before the change (edit, and a delete of a file within the size limit),
    /// kept in the backup folder under this name.
    let backupFileName: String?
    /// What Clicky wrote (edit and new file). Undo only goes ahead when the file still holds exactly this.
    let writtenContent: Data?
    /// Where the Trash put a deleted file.
    let trashedFileURL: URL?
    /// The file's permissions before the change; written back after the atomic write replaced the file.
    let originalPOSIXPermissions: Int?
}

nonisolated struct ClickyAppliedChangeRecord: Equatable {
    let setIdentifier: UUID
    let appliedAt: Date
    let backupDirectoryURL: URL
    let entries: [ClickyAppliedFileEntry]

    func isUndoAvailable(at moment: Date) -> Bool {
        moment < appliedAt.addingTimeInterval(ClickyFileEditingLimits.undoLifetimeSeconds)
    }
}

nonisolated enum ClickyChangeApplyOutcome {
    case applied(ClickyAppliedChangeRecord)
    /// A file is no longer what it was when the change was proposed. Nothing was written.
    case refusedBecauseFileChanged
    /// Something could not be written. Whatever was already done has been put back.
    case failed(reason: String)
}

nonisolated enum ClickyChangeUndoOutcome: Equatable {
    case undone
    case expired
    /// A file no longer holds what Clicky wrote (or the Trash no longer holds the deleted file).
    case refusedBecauseFileChanged
    case failed(reason: String)
}

/// What is written to `manifest.json` in a backup folder.
nonisolated struct ClickyBackupManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let originalPath: String
        let action: String
        let time: String
        let backupFileName: String?
        let trashedPath: String?
    }

    let identifier: String
    let createdAt: String
    let entries: [Entry]
}

// MARK: - Applying and undoing

nonisolated enum ClickyChangeApplier {
    /// Moves a file to the Trash and returns where it went. Replaced by the checks, which use
    /// `FileManager.trashItem` on temporary files.
    typealias TrashItem = @Sendable (URL) throws -> URL?

    static let defaultTrashItem: TrashItem = { itemURL in
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: itemURL, resultingItemURL: &resultingItemURL)
        return resultingItemURL as URL?
    }

    /// `~/Library/Application Support/Clicky/Backups`. Outside every folder the user may add (those
    /// can never be inside `~/Library`).
    static func defaultBackupsRootDirectoryURL(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: - The plan

    /// What applying one file will do, worked out (and checked against the disk) before anything is written.
    private struct PlannedFile {
        let action: ClickyFileChangeAction
        let fileURL: URL
        let relativePath: String
        let originalData: Data?
        let finalData: Data?
        let originalPermissions: Int?
    }

    /// Re-reads every file and works out what each will hold. Returns nil when any file is no
    /// longer what it was when the change was proposed: its text for an edit no longer holds the
    /// old text exactly once, a new file now exists, a deleted file is gone, or the path now
    /// resolves somewhere else (a link was swapped in).
    private static func plan(for changeSet: ClickyPendingChangeSet, fileManager: FileManager) -> [PlannedFile]? {
        var filesInOrder: [URL] = []
        var changesByFile: [URL: [ClickyFileChange]] = [:]
        for change in changeSet.changes {
            if changesByFile[change.fileURL] == nil {
                filesInOrder.append(change.fileURL)
            }
            changesByFile[change.fileURL, default: []].append(change)
        }

        var plannedFiles: [PlannedFile] = []
        for fileURL in filesInOrder {
            guard let changesForFile = changesByFile[fileURL], let firstChange = changesForFile.first else { continue }

            // The path must still lead to the same place inside the same folder.
            let pathNow = ClickyEditableFolders.normalizedPath(forPath: fileURL.path, fileManager: fileManager)
            guard pathNow == fileURL.path,
                  ClickyEditableFolders.path(pathNow, isInsideOrEqualTo: firstChange.allowedFolderURL.path) else {
                return nil
            }

            switch firstChange.action {
            case .newFile:
                // `attributesOfItem` does not follow links: a link counts as something that exists.
                guard (try? fileManager.attributesOfItem(atPath: fileURL.path)) == nil,
                      let newFileContent = firstChange.newFileContent else {
                    return nil
                }
                plannedFiles.append(PlannedFile(
                    action: .newFile,
                    fileURL: fileURL,
                    relativePath: firstChange.relativePath,
                    originalData: nil,
                    finalData: Data(newFileContent.utf8),
                    originalPermissions: nil
                ))

            case .delete:
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    return nil
                }
                let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
                let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                let originalData = fileSize <= ClickyFileEditingLimits.maximumFileBytes ? try? Data(contentsOf: fileURL) : nil
                plannedFiles.append(PlannedFile(
                    action: .delete,
                    fileURL: fileURL,
                    relativePath: firstChange.relativePath,
                    originalData: originalData,
                    finalData: nil,
                    originalPermissions: (attributes?[.posixPermissions] as? NSNumber)?.intValue
                ))

            case .edit:
                guard case .success(let originalText) = ClickyFileTextReader.readText(at: fileURL, fileManager: fileManager),
                      let originalData = try? Data(contentsOf: fileURL) else {
                    return nil
                }
                // The edits of one file are applied one after the other, each to the text the one
                // before left, exactly as the proposals were checked.
                var workingText = originalText
                for change in changesForFile {
                    guard change.action == .edit, let oldText = change.oldText, let newText = change.newText else {
                        return nil
                    }
                    let matchRanges = ClickyFileToolTurnSession.nonOverlappingRanges(of: oldText, in: workingText)
                    guard matchRanges.count == 1 else {
                        return nil
                    }
                    workingText.replaceSubrange(matchRanges[0], with: newText)
                }
                let permissions = ((try? fileManager.attributesOfItem(atPath: fileURL.path))?[.posixPermissions] as? NSNumber)?.intValue
                // Reading as utf-8 drops a byte order mark at the start, so the text never shows it;
                // it is put back here so an edit changes only what the diff showed.
                let utf8ByteOrderMark = Data([0xEF, 0xBB, 0xBF])
                let finalDataPrefix = originalData.starts(with: utf8ByteOrderMark) ? utf8ByteOrderMark : Data()
                plannedFiles.append(PlannedFile(
                    action: .edit,
                    fileURL: fileURL,
                    relativePath: firstChange.relativePath,
                    originalData: originalData,
                    finalData: finalDataPrefix + Data(workingText.utf8),
                    originalPermissions: permissions
                ))
            }
        }
        return plannedFiles
    }

    // MARK: - Apply

    static func apply(
        changeSet: ClickyPendingChangeSet,
        backupsRootDirectoryURL: URL,
        now: Date,
        fileManager: FileManager = .default,
        trashItem: TrashItem = defaultTrashItem
    ) -> ClickyChangeApplyOutcome {
        guard let plannedFiles = plan(for: changeSet, fileManager: fileManager) else {
            return .refusedBecauseFileChanged
        }

        // The backup comes first: if it cannot be written, no file is touched.
        let shortIdentifier = String(UUID().uuidString.prefix(6)).lowercased()
        let backupDirectoryURL = backupsRootDirectoryURL.appendingPathComponent(
            "\(backupFolderTimestamp(for: now))-\(shortIdentifier)",
            isDirectory: true
        )
        var backupFileNamesByPlannedIndex: [Int: String] = [:]
        do {
            try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
            for (plannedIndex, plannedFile) in plannedFiles.enumerated() {
                guard let originalData = plannedFile.originalData else { continue }
                let backupFileName = "\(plannedIndex + 1)-\(plannedFile.fileURL.lastPathComponent)"
                try originalData.write(to: backupDirectoryURL.appendingPathComponent(backupFileName), options: .atomic)
                backupFileNamesByPlannedIndex[plannedIndex] = backupFileName
            }
        } catch {
            return .failed(reason: "the backup could not be written")
        }

        // Then the writes, one file after the other. A failure puts back what was already done.
        var appliedEntries: [ClickyAppliedFileEntry] = []
        for (plannedIndex, plannedFile) in plannedFiles.enumerated() {
            do {
                switch plannedFile.action {
                case .edit:
                    guard let finalData = plannedFile.finalData else { throw CocoaError(.fileWriteUnknown) }
                    try finalData.write(to: plannedFile.fileURL, options: .atomic)
                    // Recorded as soon as the bytes are written, so a failure on the next step puts
                    // this file back too and "could not apply" is never said about a written file.
                    appliedEntries.append(ClickyAppliedFileEntry(
                        action: .edit,
                        fileURL: plannedFile.fileURL,
                        relativePath: plannedFile.relativePath,
                        backupFileName: backupFileNamesByPlannedIndex[plannedIndex],
                        writtenContent: finalData,
                        trashedFileURL: nil,
                        originalPOSIXPermissions: plannedFile.originalPermissions
                    ))
                    // The atomic write replaced the file, so it has the default permissions now; a
                    // script must not lose its executable bit.
                    if let originalPermissions = plannedFile.originalPermissions {
                        try fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: plannedFile.fileURL.path)
                    }
                case .newFile:
                    guard let finalData = plannedFile.finalData else { throw CocoaError(.fileWriteUnknown) }
                    try fileManager.createDirectory(at: plannedFile.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try finalData.write(to: plannedFile.fileURL, options: .atomic)
                    appliedEntries.append(ClickyAppliedFileEntry(
                        action: .newFile,
                        fileURL: plannedFile.fileURL,
                        relativePath: plannedFile.relativePath,
                        backupFileName: nil,
                        writtenContent: finalData,
                        trashedFileURL: nil,
                        originalPOSIXPermissions: nil
                    ))
                case .delete:
                    let trashedFileURL = try trashItem(plannedFile.fileURL)
                    appliedEntries.append(ClickyAppliedFileEntry(
                        action: .delete,
                        fileURL: plannedFile.fileURL,
                        relativePath: plannedFile.relativePath,
                        backupFileName: backupFileNamesByPlannedIndex[plannedIndex],
                        writtenContent: nil,
                        trashedFileURL: trashedFileURL,
                        originalPOSIXPermissions: plannedFile.originalPermissions
                    ))
                }
            } catch {
                let partialRecord = ClickyAppliedChangeRecord(
                    setIdentifier: changeSet.identifier,
                    appliedAt: now,
                    backupDirectoryURL: backupDirectoryURL,
                    entries: appliedEntries
                )
                _ = undo(record: partialRecord, now: now, fileManager: fileManager, trashItem: trashItem)
                return .failed(reason: "a file could not be written")
            }
        }

        let record = ClickyAppliedChangeRecord(
            setIdentifier: changeSet.identifier,
            appliedAt: now,
            backupDirectoryURL: backupDirectoryURL,
            entries: appliedEntries
        )
        writeManifest(for: record, fileManager: fileManager)
        return .applied(record)
    }

    // MARK: - Undo

    static func undo(
        record: ClickyAppliedChangeRecord,
        now: Date,
        fileManager: FileManager = .default,
        trashItem: TrashItem = defaultTrashItem
    ) -> ClickyChangeUndoOutcome {
        guard record.isUndoAvailable(at: now) else {
            return .expired
        }

        // Check every file first, so an undo is all or nothing.
        for entry in record.entries {
            switch entry.action {
            case .edit, .newFile:
                guard let writtenContent = entry.writtenContent,
                      let currentData = try? Data(contentsOf: entry.fileURL),
                      currentData == writtenContent else {
                    return .refusedBecauseFileChanged
                }
            case .delete:
                guard let trashedFileURL = entry.trashedFileURL,
                      fileManager.fileExists(atPath: trashedFileURL.path),
                      (try? fileManager.attributesOfItem(atPath: entry.fileURL.path)) == nil else {
                    return .refusedBecauseFileChanged
                }
            }
        }

        // Newest first, the reverse of the order they were applied in.
        for entry in record.entries.reversed() {
            do {
                switch entry.action {
                case .edit:
                    guard let backupFileName = entry.backupFileName else { throw CocoaError(.fileNoSuchFile) }
                    let originalData = try Data(contentsOf: record.backupDirectoryURL.appendingPathComponent(backupFileName))
                    try originalData.write(to: entry.fileURL, options: .atomic)
                    if let originalPermissions = entry.originalPOSIXPermissions {
                        try fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: entry.fileURL.path)
                    }
                case .newFile:
                    _ = try trashItem(entry.fileURL)
                case .delete:
                    guard let trashedFileURL = entry.trashedFileURL else { throw CocoaError(.fileNoSuchFile) }
                    try fileManager.createDirectory(at: entry.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: trashedFileURL, to: entry.fileURL)
                }
            } catch {
                return .failed(reason: "a file could not be put back")
            }
        }
        return .undone
    }

    // MARK: - Manifest

    private static func writeManifest(for record: ClickyAppliedChangeRecord, fileManager: FileManager) {
        let timestampFormatter = ISO8601DateFormatter()
        let timeText = timestampFormatter.string(from: record.appliedAt)
        let manifest = ClickyBackupManifest(
            identifier: record.backupDirectoryURL.lastPathComponent,
            createdAt: timeText,
            entries: record.entries.map { entry in
                ClickyBackupManifest.Entry(
                    originalPath: entry.fileURL.path,
                    action: entry.action.rawValue,
                    time: timeText,
                    backupFileName: entry.backupFileName,
                    trashedPath: entry.trashedFileURL?.path
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let manifestData = try? encoder.encode(manifest) else { return }
        try? manifestData.write(to: record.backupDirectoryURL.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// `yyyy-MM-dd-HHmmss` in the user's time zone.
    static func backupFolderTimestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: - Pruning

    struct PruneResult: Equatable {
        let removedFolderCount: Int
        let remainingByteCount: Int
    }

    /// True for the names `apply` gives backup folders (`yyyy-MM-dd-HHmmss-` and six lowercase hex
    /// digits). `~/Library/Application Support/Clicky` is a name other apps can use too, so pruning
    /// never removes a folder it did not make.
    static func isClickyBackupFolderName(_ folderName: String) -> Bool {
        folderName.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}-[0-9a-f]{6}$"#, options: .regularExpression) != nil
    }

    /// Deletes backup folders older than `retentionDays`, then the oldest ones until the rest fit
    /// in `maximumTotalBytes`. A folder's age is its creation date on disk. Run at launch, off the
    /// main thread. Never touches anything that is not a direct subfolder of the backups folder
    /// with the name shape `apply` gives (`isClickyBackupFolderName`).
    @discardableResult
    static func pruneBackups(
        in backupsRootDirectoryURL: URL,
        now: Date,
        retentionDays: Int = ClickyFileEditingLimits.backupRetentionDays,
        maximumTotalBytes: Int = ClickyFileEditingLimits.backupMaximumTotalBytes,
        fileManager: FileManager = .default
    ) -> PruneResult {
        guard let childURLs = try? fileManager.contentsOfDirectory(
            at: backupsRootDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return PruneResult(removedFolderCount: 0, remainingByteCount: 0)
        }

        struct BackupFolder {
            let url: URL
            let createdAt: Date
            var byteCount: Int
        }
        var backupFolders: [BackupFolder] = []
        for childURL in childURLs where isClickyBackupFolderName(childURL.lastPathComponent) {
            guard let resourceValues = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey]),
                  resourceValues.isDirectory == true else {
                continue
            }
            backupFolders.append(BackupFolder(
                url: childURL,
                createdAt: resourceValues.creationDate ?? .distantPast,
                byteCount: totalByteCount(ofFolderAt: childURL, fileManager: fileManager)
            ))
        }
        backupFolders.sort { $0.createdAt < $1.createdAt }

        var removedFolderCount = 0
        let oldestAllowedDate = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        var keptFolders: [BackupFolder] = []
        for backupFolder in backupFolders {
            if backupFolder.createdAt < oldestAllowedDate, (try? fileManager.removeItem(at: backupFolder.url)) != nil {
                removedFolderCount += 1
            } else {
                keptFolders.append(backupFolder)
            }
        }

        var totalByteCount = keptFolders.reduce(0) { $0 + $1.byteCount }
        while totalByteCount > maximumTotalBytes, let oldestKeptFolder = keptFolders.first {
            keptFolders.removeFirst()
            if (try? fileManager.removeItem(at: oldestKeptFolder.url)) != nil {
                removedFolderCount += 1
                totalByteCount -= oldestKeptFolder.byteCount
            }
        }
        return PruneResult(removedFolderCount: removedFolderCount, remainingByteCount: totalByteCount)
    }

    private static func totalByteCount(ofFolderAt folderURL: URL, fileManager: FileManager) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        ) else {
            return 0
        }
        var totalByteCount = 0
        for case let fileURL as URL in enumerator {
            totalByteCount += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return totalByteCount
    }
}
