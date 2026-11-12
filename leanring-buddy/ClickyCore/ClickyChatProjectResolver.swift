import Foundation

/// What the app knows about where the user was when a chat started. Read once, at the first
/// message of a chat, and never sent to the model: it only groups the chat list.
nonisolated struct ClickyChatProjectContext: Equatable {
    /// The path of the frontmost window's document (its `AXDocument` attribute), when the app
    /// reports one. Xcode, TextEdit, Preview and most document apps do; browsers and terminals do not.
    let documentPath: String?
    /// The frontmost window's title, used only for the VS Code family, which reports no document
    /// but names the open folder in its title.
    let windowTitle: String?
    let applicationBundleIdentifier: String?
    let applicationName: String?

    init(documentPath: String?, windowTitle: String?, applicationBundleIdentifier: String?, applicationName: String?) {
        self.documentPath = documentPath
        self.windowTitle = windowTitle
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationName = applicationName
    }
}

/// Works out the project a chat belongs to, in this order:
/// 1. the git repository root, if the document's file is inside one;
/// 2. the document's folder;
/// 3. for the VS Code family, the folder named in the window title;
/// 4. the app.
nonisolated enum ClickyChatProjectResolver {
    static let gitRepositoryKeyPrefix = "git:"
    static let folderKeyPrefix = "folder:"
    static let folderNameKeyPrefix = "folder-name:"
    static let applicationKeyPrefix = "app:"

    /// The VS Code family: Code, Code Insiders, VSCodium, Cursor and Windsurf. Their windows
    /// report no `AXDocument`; the open folder is read from the window title instead.
    static let vsCodeFamilyBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
    ]

    /// The names the VS Code family puts at the end of a window title, which are not folder names.
    static let vsCodeFamilyApplicationTitleSuffixes: [String] = [
        "Visual Studio Code",
        "Visual Studio Code - Insiders",
        "Code - Insiders",
        "VSCodium",
        "Cursor",
        "Windsurf",
    ]

    /// The value of a window's `AXDocument` attribute is a file URL as text
    /// ("file:///Users/sam/My%20Folder/main.swift"), not a path. This gives the path, with the
    /// percent escapes decoded. A plain absolute path is returned as it is; anything else (a web
    /// address, an empty string, text that is not a path) gives nil, and the project then falls
    /// back to the folder named in the title or to the app.
    static func documentPath(fromAccessibilityDocumentValue accessibilityDocumentValue: String?) -> String? {
        guard let trimmedValue = accessibilityDocumentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            return nil
        }
        if trimmedValue.hasPrefix("/") {
            return trimmedValue
        }
        guard let documentURL = URL(string: trimmedValue), documentURL.isFileURL else {
            return nil
        }
        let documentPath = documentURL.path
        return documentPath.hasPrefix("/") ? documentPath : nil
    }

    /// `fileExists` is injected so the walk up to a git root can be tested with a pretend disk.
    static func resolve(
        _ context: ClickyChatProjectContext,
        fileExists: (String) -> Bool
    ) -> ClickyChatProject {
        if let documentPath = context.documentPath, documentPath.hasPrefix("/") {
            let documentFolderPath = (documentPath as NSString).deletingLastPathComponent
            if let gitRepositoryRootPath = gitRepositoryRootPath(containing: documentFolderPath, fileExists: fileExists) {
                return ClickyChatProject(
                    key: gitRepositoryKeyPrefix + gitRepositoryRootPath,
                    displayName: (gitRepositoryRootPath as NSString).lastPathComponent
                )
            }
            if !documentFolderPath.isEmpty && documentFolderPath != "/" {
                return ClickyChatProject(
                    key: folderKeyPrefix + documentFolderPath,
                    displayName: (documentFolderPath as NSString).lastPathComponent
                )
            }
        }

        if let applicationBundleIdentifier = context.applicationBundleIdentifier,
           vsCodeFamilyBundleIdentifiers.contains(applicationBundleIdentifier),
           let windowTitle = context.windowTitle,
           let folderName = folderName(fromVSCodeFamilyWindowTitle: windowTitle) {
            return ClickyChatProject(key: folderNameKeyPrefix + folderName, displayName: folderName)
        }

        let applicationName = context.applicationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let applicationBundleIdentifier = context.applicationBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if applicationBundleIdentifier.isEmpty && applicationName.isEmpty {
            return .unknown
        }
        return ClickyChatProject(
            key: applicationKeyPrefix + (applicationBundleIdentifier.isEmpty ? applicationName : applicationBundleIdentifier),
            displayName: applicationName.isEmpty ? applicationBundleIdentifier : applicationName
        )
    }

    /// Walks up from the folder looking for `.git`, which is a folder in an ordinary checkout and
    /// a file in a worktree or submodule; both count. Stops at the root.
    static func gitRepositoryRootPath(containing folderPath: String, fileExists: (String) -> Bool) -> String? {
        var currentFolderPath = (folderPath as NSString).standardizingPath
        while !currentFolderPath.isEmpty && currentFolderPath != "/" {
            if fileExists((currentFolderPath as NSString).appendingPathComponent(".git")) {
                return currentFolderPath
            }
            let parentFolderPath = (currentFolderPath as NSString).deletingLastPathComponent
            if parentFolderPath == currentFolderPath { break }
            currentFolderPath = parentFolderPath
        }
        return nil
    }

    /// The folder in a VS Code family window title. The titles look like
    /// "main.swift — Clicker", "● main.swift — Clicker — Visual Studio Code", "Clicker — Cursor"
    /// or, with a dash, "main.swift - Clicker - Visual Studio Code". The folder is the last part
    /// once the app's name is taken off the end; an unsaved-marker "●" in front is ignored.
    /// nil when the title is empty or only names the app.
    static func folderName(fromVSCodeFamilyWindowTitle windowTitle: String) -> String? {
        var titleParts = windowTitle
            .replacingOccurrences(of: " - ", with: " — ")
            .components(separatedBy: " — ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        while let lastPart = titleParts.last, vsCodeFamilyApplicationTitleSuffixes.contains(lastPart) {
            titleParts.removeLast()
        }
        guard let folderPart = titleParts.last else { return nil }
        let cleanedFolderName = folderPart
            .replacingOccurrences(of: "●", with: "")
            .trimmingCharacters(in: .whitespaces)
        // A folder name "[Extension Development Host]" or a title that is only a file name on its
        // own (no folder open) is not a project.
        guard !cleanedFolderName.isEmpty, !cleanedFolderName.hasPrefix("[") else { return nil }
        // With a file and a folder the folder is the second part; a lone part is the folder only
        // when it does not look like a file name.
        if titleParts.count == 1, cleanedFolderName.contains("."), !cleanedFolderName.hasSuffix(".") {
            return nil
        }
        return cleanedFolderName
    }
}
