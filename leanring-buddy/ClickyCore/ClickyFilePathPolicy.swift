import Foundation

// Round 17 (file editing): which folders Clicky may edit, and the one function every file tool goes
// through to decide whether a path the model gave may be touched. Foundation only; the only disk
// access is asking whether a path exists and resolving symbolic links, so the whole policy can be
// checked against temporary folders.

// MARK: - The limits

/// Every number the file tools work to, in one place, so the tool definitions, the tool results and
/// the checks all read the same values.
nonisolated enum ClickyFileEditingLimits {
    /// A file bigger than this is refused (read and edit alike).
    static let maximumFileBytes = 512 * 1024
    /// A file with a NUL byte in its first bytes counts as binary and is refused.
    static let binarySniffByteCount = 8 * 1024
    static let maximumListedEntries = 200
    /// One `read_file` call returns at most this many lines or this many bytes of text.
    static let maximumLinesPerRead = 400
    static let maximumBytesPerRead = 40 * 1024
    /// Limits for one turn of the tool loop.
    static let maximumRequestsPerTurn = 6
    static let maximumToolCallsPerTurn = 12
    static let maximumBytesReadPerTurn = 200 * 1024
    static let maximumChangesPerTurn = 5
    /// `max_tokens` for a request that carries the tools (a new file's content can be long).
    static let maximumOutputTokensWithTools = 8000
    /// How long a proposed change waits for the user, and how long an applied one can be undone.
    static let pendingChangeLifetimeSeconds: TimeInterval = 10 * 60
    static let undoLifetimeSeconds: TimeInterval = 30 * 60
    /// Backups older than this, or beyond this many bytes in total (oldest first), are pruned at launch.
    static let backupRetentionDays = 30
    static let backupMaximumTotalBytes = 200 * 1024 * 1024
    /// A change's one-line summary is cut to this many characters before it reaches the history.
    static let maximumSummaryCharacters = 100
}

// MARK: - Folders the user may add

/// Why a folder cannot be on the list of folders Clicky may edit. The settings tab shows the words.
nonisolated enum ClickyEditableFolderRefusal: Equatable {
    case notAFolder
    case isTheRootFolder
    case isTheHomeFolder
    /// A folder that holds the home folder (such as /Users): everything in it would be editable.
    case holdsTheHomeFolder
    case insideLibrary
    case insideSystemFolder(String)

    var explanation: String {
        switch self {
        case .notAFolder:
            return "that is not a folder."
        case .isTheRootFolder:
            return "the whole disk is too much. pick a project folder."
        case .isTheHomeFolder:
            return "your whole home folder is too much. pick a project folder inside it."
        case .holdsTheHomeFolder:
            return "that folder holds your home folder. pick a project folder inside it."
        case .insideLibrary:
            return "the library folder holds app data and settings. pick a project folder."
        case .insideSystemFolder(let systemFolderName):
            return "\(systemFolderName) is a system folder. pick a project folder."
        }
    }
}

nonisolated enum ClickyEditableFolders {
    /// The `UserDefaults` key: an array of absolute paths, standardized with symbolic links resolved.
    static let userDefaultsKey = "editableFolderPaths"

    /// Folders (and everything inside them) that can never be added. The home folder, `/` and the
    /// folders holding the home folder are checked separately.
    static let systemFolderPaths = ["/System", "/Applications", "/usr", "/Library", "/bin", "/sbin", "/private/etc"]

    /// The path with `.` and `..` removed and every symbolic link resolved, also when the last
    /// parts of the path do not exist yet (the existing front part is resolved and the rest kept).
    static func normalizedPath(forPath path: String, fileManager: FileManager = .default) -> String {
        normalizedPath(forPath: path, fileManager: fileManager, remainingLinkHops: 16)
    }

    private static func normalizedPath(forPath path: String, fileManager: FileManager, remainingLinkHops: Int) -> String {
        var existingPrefixURL = URL(fileURLWithPath: path).standardizedFileURL
        var missingPathComponents: [String] = []
        // `attributesOfItem` does not follow links, so a link whose target is missing still counts as
        // present here; resolving it below then follows it as far as it goes.
        while existingPrefixURL.path != "/", (try? fileManager.attributesOfItem(atPath: existingPrefixURL.path)) == nil {
            missingPathComponents.insert(existingPrefixURL.lastPathComponent, at: 0)
            existingPrefixURL = existingPrefixURL.deletingLastPathComponent()
        }
        var resolvedURL = existingPrefixURL.resolvingSymlinksInPath()
        // A link whose target does not exist stays a link after the call above. It is followed by
        // hand, so a new file cannot be created through a dangling link that points out of a folder.
        if remainingLinkHops > 0, let linkDestination = try? fileManager.destinationOfSymbolicLink(atPath: resolvedURL.path) {
            let destinationURL = URL(fileURLWithPath: linkDestination, relativeTo: resolvedURL.deletingLastPathComponent())
            resolvedURL = URL(fileURLWithPath: normalizedPath(
                forPath: destinationURL.path,
                fileManager: fileManager,
                remainingLinkHops: remainingLinkHops - 1
            ))
        }
        for missingPathComponent in missingPathComponents {
            resolvedURL.appendPathComponent(missingPathComponent)
        }
        return resolvedURL.standardizedFileURL.path
    }

    /// True when `path` is `folderPath` or lies inside it. The prefix has to end at a "/", so
    /// `/Users/x/foo` is not inside `/Users/x/foobar`.
    static func path(_ path: String, isInsideOrEqualTo folderPath: String) -> Bool {
        if path == folderPath {
            return true
        }
        let folderPathWithSlash = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return path.hasPrefix(folderPathWithSlash)
    }

    /// Why this folder may not be added, or nil when it may. `folderPath` is expected to be
    /// normalized already.
    static func refusal(
        forNormalizedFolderPath folderPath: String,
        homeDirectoryPath: String,
        fileManager: FileManager = .default
    ) -> ClickyEditableFolderRefusal? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notAFolder
        }
        if folderPath == "/" {
            return .isTheRootFolder
        }
        let normalizedHomePath = normalizedPath(forPath: homeDirectoryPath, fileManager: fileManager)
        if folderPath == normalizedHomePath {
            return .isTheHomeFolder
        }
        if path(normalizedHomePath, isInsideOrEqualTo: folderPath) {
            return .holdsTheHomeFolder
        }
        if path(folderPath, isInsideOrEqualTo: normalizedHomePath + "/Library") {
            return .insideLibrary
        }
        for systemFolderPath in systemFolderPaths where path(folderPath, isInsideOrEqualTo: systemFolderPath) {
            return .insideSystemFolder(systemFolderPath)
        }
        return nil
    }

    /// What adding a folder from the settings tab does to the list.
    struct AdditionResult: Equatable {
        let folderPaths: [String]
        /// Set when the folder was refused; the list is then unchanged.
        let refusal: ClickyEditableFolderRefusal?
        let wasAlreadyListed: Bool
    }

    static func adding(
        folderPath rawFolderPath: String,
        to existingFolderPaths: [String],
        homeDirectoryPath: String,
        fileManager: FileManager = .default
    ) -> AdditionResult {
        let normalizedFolderPath = normalizedPath(forPath: rawFolderPath, fileManager: fileManager)
        if let refusal = refusal(forNormalizedFolderPath: normalizedFolderPath, homeDirectoryPath: homeDirectoryPath, fileManager: fileManager) {
            return AdditionResult(folderPaths: existingFolderPaths, refusal: refusal, wasAlreadyListed: false)
        }
        if existingFolderPaths.contains(normalizedFolderPath) {
            return AdditionResult(folderPaths: existingFolderPaths, refusal: nil, wasAlreadyListed: true)
        }
        return AdditionResult(folderPaths: existingFolderPaths + [normalizedFolderPath], refusal: nil, wasAlreadyListed: false)
    }

    static func removing(folderPath: String, from existingFolderPaths: [String]) -> [String] {
        existingFolderPaths.filter { $0 != folderPath }
    }

    /// The list as it was stored: a missing or wrong-shaped value is an empty list (the feature is
    /// off), and anything that is not an absolute path is dropped, so a hand-edited value cannot
    /// turn a relative path into a folder. Duplicates keep their first place.
    static func folderPaths(storedValue: Any?) -> [String] {
        guard let storedPaths = storedValue as? [String] else {
            return []
        }
        var keptPaths: [String] = []
        for storedPath in storedPaths where storedPath.hasPrefix("/") && storedPath != "/" && !keptPaths.contains(storedPath) {
            keptPaths.append(storedPath)
        }
        return keptPaths
    }

    /// The last part of the path, which is what the settings tab and the prompt call the folder.
    static func displayName(forFolderPath folderPath: String) -> String {
        let lastComponent = URL(fileURLWithPath: folderPath).lastPathComponent
        return lastComponent.isEmpty ? folderPath : lastComponent
    }

    /// The path with the home folder written as "~", for the settings tab.
    static func shortenedPath(_ folderPath: String, homeDirectoryPath: String) -> String {
        if folderPath == homeDirectoryPath {
            return "~"
        }
        if folderPath.hasPrefix(homeDirectoryPath + "/") {
            return "~" + folderPath.dropFirst(homeDirectoryPath.count)
        }
        return folderPath
    }
}

// MARK: - Files that are never read or written

/// File names that may hold secrets, and the folder that holds the repository's own data. They are
/// refused even inside a folder the user chose.
nonisolated enum ClickyProtectedFileNames {
    static func nameIsProtected(_ fileName: String) -> Bool {
        let lowercasedName = fileName.lowercased()
        if lowercasedName == ".env" || lowercasedName.hasPrefix(".env.") {
            return true
        }
        for protectedSuffix in [".pem", ".key", ".p12"] where lowercasedName.hasSuffix(protectedSuffix) {
            return true
        }
        if lowercasedName.contains(".keychain") {
            return true
        }
        if lowercasedName.hasPrefix("id_rsa") || lowercasedName.hasPrefix("id_ed25519") {
            return true
        }
        if lowercasedName.contains("secret") || lowercasedName.contains("credential") {
            return true
        }
        return lowercasedName == "clickyworkersecrets.plist"
    }

    /// Any case: on a case-insensitive disk (the macOS default) ".GIT" is the same folder. Paths that
    /// exist are already resolved to the case on disk, so this only matters for a name that does not.
    static func isGitFolderName(_ pathComponent: String) -> Bool {
        pathComponent.lowercased() == ".git"
    }
}

// MARK: - Resolving a path the model gave

/// Where a path that passed the policy lies.
nonisolated struct ClickyResolvedFilePath: Equatable {
    let fileURL: URL
    let allowedFolderURL: URL
    /// The path below the allowed folder ("" for the folder itself), with "/" between parts.
    let relativePathInAllowedFolder: String

    var allowedFolderDisplayName: String {
        ClickyEditableFolders.displayName(forFolderPath: allowedFolderURL.path)
    }
}

nonisolated enum ClickyFilePathRefusal: Error, Equatable {
    case noFolderIsAllowed
    case emptyPath
    case outsideAllowedFolders
    case insideGitFolder
    case secretLookingName
    /// A relative name that exists in more than one allowed folder (the folders' names).
    case existsInSeveralFolders([String])
    /// A relative path for a new file, with several folders allowed and no open document to say which.
    case needsFolderChoice([String])
    case doesNotExist

    /// The short plain sentence the model sees as a tool result.
    var message: String {
        switch self {
        case .noFolderIsAllowed:
            return "no folder is set up for editing. the user can add one in the settings tab."
        case .emptyPath:
            return "that path is empty."
        case .outsideAllowedFolders:
            return "that path is outside the folders you may edit."
        case .insideGitFolder:
            return "files inside a .git folder are not readable or editable."
        case .secretLookingName:
            return "that file looks like it holds secrets, so it is not readable."
        case .existsInSeveralFolders(let folderNames):
            return "that name exists in more than one folder you may edit (\(folderNames.joined(separator: ", "))). ask the user which one, then use the full path."
        case .needsFolderChoice(let folderNames):
            return "several folders may be edited (\(folderNames.joined(separator: ", "))) and no open document says which one. ask the user which folder, then use the full path."
        case .doesNotExist:
            return "that path doesn't exist."
        }
    }
}

nonisolated enum ClickyFilePathIntent {
    /// A path that has to exist (read, edit, delete, list).
    case existingItem
    /// A file that is about to be created.
    case newFile
}

nonisolated struct ClickyFilePathPolicy {
    /// The folders, normalized (symbolic links resolved), in the order the user added them.
    let allowedFolderURLs: [URL]
    let homeDirectoryPath: String
    /// The document of the frontmost window when it lies inside an allowed folder. Relative paths
    /// are tried against its folder first.
    let frontmostDocumentFolderURL: URL?
    private let fileManager: FileManager

    init(
        allowedFolderPaths: [String],
        homeDirectoryPath: String,
        frontmostDocumentPath: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.homeDirectoryPath = homeDirectoryPath
        let normalizedAllowedFolderPaths = allowedFolderPaths.map {
            ClickyEditableFolders.normalizedPath(forPath: $0, fileManager: fileManager)
        }
        self.allowedFolderURLs = normalizedAllowedFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }

        if let frontmostDocumentPath {
            let documentFolderPath = ClickyEditableFolders.normalizedPath(
                forPath: URL(fileURLWithPath: frontmostDocumentPath).deletingLastPathComponent().path,
                fileManager: fileManager
            )
            let documentFolderIsInsideAnAllowedFolder = normalizedAllowedFolderPaths.contains {
                ClickyEditableFolders.path(documentFolderPath, isInsideOrEqualTo: $0)
            }
            self.frontmostDocumentFolderURL = documentFolderIsInsideAnAllowedFolder
                ? URL(fileURLWithPath: documentFolderPath, isDirectory: true)
                : nil
        } else {
            self.frontmostDocumentFolderURL = nil
        }
    }

    var allowedFolderDisplayNames: [String] {
        allowedFolderURLs.map { ClickyEditableFolders.displayName(forFolderPath: $0.path) }
    }

    /// Resolves what the model wrote (absolute, "~", or relative) to one file inside one allowed
    /// folder, or says why not. Every file tool calls this and nothing else decides.
    func resolve(rawPath: String, intent: ClickyFilePathIntent) -> Result<ClickyResolvedFilePath, ClickyFilePathRefusal> {
        guard !allowedFolderURLs.isEmpty else {
            return .failure(.noFolderIsAllowed)
        }
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return .failure(.emptyPath)
        }

        if trimmedPath == "~" || trimmedPath.hasPrefix("~/") {
            let pathBelowHome = String(trimmedPath.dropFirst(1))
            return finishResolving(candidatePath: homeDirectoryPath + pathBelowHome)
        }
        if trimmedPath.hasPrefix("/") {
            return finishResolving(candidatePath: trimmedPath)
        }
        return resolveRelativePath(trimmedPath, intent: intent)
    }

    private func resolveRelativePath(_ relativePath: String, intent: ClickyFilePathIntent) -> Result<ClickyResolvedFilePath, ClickyFilePathRefusal> {
        func candidatePath(inside baseFolderURL: URL) -> String {
            baseFolderURL.appendingPathComponent(relativePath).path
        }

        // "project/README.md": a path that starts with the name of an allowed folder means the file in
        // that folder. Tool results and the prompt write paths that way, so the model writes them back
        // (measured in the round 17 eval: with two folders it wrote "project" and "website/README.md").
        let relativePathComponents = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let pathBelowNamedFolder = relativePathComponents.dropFirst().joined(separator: "/")
        let foldersNamedByFirstComponent = allowedFolderURLs.filter { allowedFolderURL in
            relativePathComponents.first == ClickyEditableFolders.displayName(forFolderPath: allowedFolderURL.path)
        }
        func candidatePathBelowNamedFolder(_ namedFolderURL: URL) -> String {
            pathBelowNamedFolder.isEmpty ? namedFolderURL.path : namedFolderURL.appendingPathComponent(pathBelowNamedFolder).path
        }

        switch intent {
        case .existingItem:
            // The folder of the document in the frontmost window is tried first: "this file" and
            // "the one next to it" mean that folder.
            if let frontmostDocumentFolderURL, fileManager.fileExists(atPath: candidatePath(inside: frontmostDocumentFolderURL)) {
                return finishResolving(candidatePath: candidatePath(inside: frontmostDocumentFolderURL))
            }
            // Every place the path names an existing item: below each allowed folder, and below the
            // folder its first part names. Two different places are ambiguous.
            var existingCandidates: [(normalizedPath: String, candidatePath: String, folderURL: URL)] = []
            func addCandidateIfItExists(_ candidatePathToCheck: String, folderURL: URL) {
                guard fileManager.fileExists(atPath: candidatePathToCheck) else { return }
                let normalizedCandidatePath = ClickyEditableFolders.normalizedPath(forPath: candidatePathToCheck, fileManager: fileManager)
                guard !existingCandidates.contains(where: { $0.normalizedPath == normalizedCandidatePath }) else { return }
                existingCandidates.append((normalizedCandidatePath, candidatePathToCheck, folderURL))
            }
            for allowedFolderURL in allowedFolderURLs {
                addCandidateIfItExists(candidatePath(inside: allowedFolderURL), folderURL: allowedFolderURL)
            }
            for namedFolderURL in foldersNamedByFirstComponent {
                addCandidateIfItExists(candidatePathBelowNamedFolder(namedFolderURL), folderURL: namedFolderURL)
            }
            if existingCandidates.count > 1 {
                return .failure(.existsInSeveralFolders(existingCandidates.map { ClickyEditableFolders.displayName(forFolderPath: $0.folderURL.path) }))
            }
            if let onlyCandidate = existingCandidates.first {
                return finishResolving(candidatePath: onlyCandidate.candidatePath)
            }
            // Nothing exists under that name. Still run the policy so that a path that would be
            // refused anyway (`../x`) is refused for that reason, not reported as missing.
            let policyVerdict = finishResolving(candidatePath: candidatePath(inside: frontmostDocumentFolderURL ?? allowedFolderURLs[0]))
            if case .failure(let refusal) = policyVerdict, refusal != .doesNotExist {
                return policyVerdict
            }
            return .failure(.doesNotExist)

        case .newFile:
            // A new file whose path starts with one folder's name goes in that folder, unless the
            // place it would go otherwise already holds something of that name (then the name is a
            // subfolder there, as before).
            if foldersNamedByFirstComponent.count == 1, let namedFolderURL = foldersNamedByFirstComponent.first, !pathBelowNamedFolder.isEmpty {
                let defaultBaseFolderURL = frontmostDocumentFolderURL ?? (allowedFolderURLs.count == 1 ? allowedFolderURLs[0] : nil)
                let defaultBaseHoldsThatName = defaultBaseFolderURL.map {
                    (try? fileManager.attributesOfItem(atPath: $0.appendingPathComponent(relativePathComponents[0]).path)) != nil
                } ?? false
                if !defaultBaseHoldsThatName {
                    return finishResolving(candidatePath: candidatePathBelowNamedFolder(namedFolderURL))
                }
            }
            if let frontmostDocumentFolderURL {
                return finishResolving(candidatePath: candidatePath(inside: frontmostDocumentFolderURL))
            }
            if allowedFolderURLs.count == 1 {
                return finishResolving(candidatePath: candidatePath(inside: allowedFolderURLs[0]))
            }
            return .failure(.needsFolderChoice(allowedFolderDisplayNames))
        }
    }

    /// The common last steps: standardize, resolve links, find the allowed folder that holds the
    /// path, and apply the name rules to every part below that folder.
    private func finishResolving(candidatePath: String) -> Result<ClickyResolvedFilePath, ClickyFilePathRefusal> {
        let normalizedCandidatePath = ClickyEditableFolders.normalizedPath(forPath: candidatePath, fileManager: fileManager)
        guard let holdingFolderURL = allowedFolderURLs.first(where: {
            ClickyEditableFolders.path(normalizedCandidatePath, isInsideOrEqualTo: $0.path)
        }) else {
            return .failure(.outsideAllowedFolders)
        }

        let relativePath: String
        if normalizedCandidatePath == holdingFolderURL.path {
            relativePath = ""
        } else {
            let folderPathWithSlash = holdingFolderURL.path.hasSuffix("/") ? holdingFolderURL.path : holdingFolderURL.path + "/"
            relativePath = String(normalizedCandidatePath.dropFirst(folderPathWithSlash.count))
        }

        let relativeComponents = relativePath.split(separator: "/").map(String.init)
        if relativeComponents.contains(where: { ClickyProtectedFileNames.isGitFolderName($0) }) {
            return .failure(.insideGitFolder)
        }
        if relativeComponents.contains(where: { ClickyProtectedFileNames.nameIsProtected($0) }) {
            return .failure(.secretLookingName)
        }
        return .success(ClickyResolvedFilePath(
            fileURL: URL(fileURLWithPath: normalizedCandidatePath),
            allowedFolderURL: holdingFolderURL,
            relativePathInAllowedFolder: relativePath
        ))
    }
}
