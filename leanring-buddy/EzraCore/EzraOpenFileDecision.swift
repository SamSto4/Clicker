import Foundation

// Round 18 (Jarvis actions): what `open_file` does with a file the path policy already allowed. The
// decision is pure: the executor gathers the facts (the extension, whether it is a folder or a
// program, which app is in front, which app is the file's default), this file picks the one thing
// that happens, and the executor does exactly that. Files are never run: an app, an installer, a
// script that runs when opened, or a program is refused, and an app that runs things is never the
// one that opens a file (TextEdit is, instead).

// MARK: - Editors

/// How an editor can be asked to open a file at a line.
nonisolated enum EzraEditorLineSupport: Equatable {
    /// `<scheme>://file/<path>:<line>`, handed to the system (the VS Code family).
    case urlScheme(String)
    /// `/usr/bin/xed --line <n> <path>`, run through `Process` with an arguments array (Xcode).
    case xed
    /// The editor opens the file but not at a line.
    case none
}

nonisolated struct EzraKnownEditor: Equatable {
    let bundleIdentifier: String
    let displayName: String
    let lineSupport: EzraEditorLineSupport
}

nonisolated enum EzraKnownEditors {
    static let textEdit = EzraKnownEditor(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit", lineSupport: .none)

    static let editors: [EzraKnownEditor] = [
        EzraKnownEditor(bundleIdentifier: "com.microsoft.VSCode", displayName: "Visual Studio Code", lineSupport: .urlScheme("vscode")),
        EzraKnownEditor(bundleIdentifier: "com.microsoft.VSCodeInsiders", displayName: "Visual Studio Code Insiders", lineSupport: .urlScheme("vscode-insiders")),
        EzraKnownEditor(bundleIdentifier: "com.todesktop.230313mzl4w4u92", displayName: "Cursor", lineSupport: .urlScheme("cursor")),
        EzraKnownEditor(bundleIdentifier: "com.exafunction.windsurf", displayName: "Windsurf", lineSupport: .urlScheme("windsurf")),
        EzraKnownEditor(bundleIdentifier: "com.vscodium", displayName: "VSCodium", lineSupport: .urlScheme("vscodium")),
        EzraKnownEditor(bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode", lineSupport: .xed),
        textEdit,
        EzraKnownEditor(bundleIdentifier: "com.sublimetext.4", displayName: "Sublime Text", lineSupport: .none),
        EzraKnownEditor(bundleIdentifier: "com.sublimetext.3", displayName: "Sublime Text", lineSupport: .none),
        EzraKnownEditor(bundleIdentifier: "com.barebones.bbedit", displayName: "BBEdit", lineSupport: .none),
        EzraKnownEditor(bundleIdentifier: "com.panic.Nova", displayName: "Nova", lineSupport: .none),
        EzraKnownEditor(bundleIdentifier: "dev.zed.Zed", displayName: "Zed", lineSupport: .none),
        EzraKnownEditor(bundleIdentifier: "dev.zed.Zed-Preview", displayName: "Zed Preview", lineSupport: .none),
    ]

    /// The editor for a bundle identifier. Every JetBrains IDE (`com.jetbrains.*`) counts as one that
    /// opens a file but not at a line.
    static func editor(forBundleIdentifier bundleIdentifier: String?) -> EzraKnownEditor? {
        guard let bundleIdentifier else {
            return nil
        }
        if let knownEditor = editors.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return knownEditor
        }
        if bundleIdentifier.hasPrefix("com.jetbrains.") {
            return EzraKnownEditor(bundleIdentifier: bundleIdentifier, displayName: "a JetBrains IDE", lineSupport: .none)
        }
        return nil
    }

    /// Apps that run things when handed a file. A file is never opened with one of these. The review
    /// added the Java launcher, the script menu and the other terminal apps a user may have made the
    /// default for shell scripts: a terminal runs a script it is handed.
    static let bundleIdentifiersOfAppsThatRunThings: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "org.python.python",
        "com.apple.ScriptEditor2",
        "com.apple.Automator",
        "com.apple.installer",
        "com.apple.shortcuts",
        "com.apple.JarLauncher",
        "com.apple.ScriptMenuApp",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "org.tabby",
    ]

    static func appRunsThings(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }
        if bundleIdentifiersOfAppsThatRunThings.contains(bundleIdentifier) {
            return true
        }
        // The Python launcher and the Python IDLE app carry the version in their identifier.
        return bundleIdentifier.lowercased().hasPrefix("org.python.")
    }
}

// MARK: - The facts and the plan

nonisolated struct EzraOpenFileFacts: Equatable {
    /// Lowercase, no dot. Empty for a file with none.
    var fileExtension: String
    var isFolder: Bool
    /// A Mach-O program that has an executable bit set.
    var isMachOProgram: Bool
    var frontmostApplicationBundleIdentifier: String?
    /// The app the system would open the file with, when it has one.
    var defaultApplicationBundleIdentifier: String?
    /// Any executable bit is set on a file that is not a Mach-O program (a script, often with no
    /// extension). Such a file only ever opens in an editor.
    var hasExecutableBit: Bool = false
}

nonisolated enum EzraOpenFileAction: Equatable {
    /// Show the file (or folder) selected in Finder.
    case revealInFinder
    case openWithDefaultApplication
    /// Open the file with this app, with no line.
    case openInApplication(bundleIdentifier: String)
    /// Hand this `vscode://file/...:line` address to the system.
    case openAtLineWithURLScheme(URL)
    case openAtLineWithXed(line: Int)
}

nonisolated struct EzraOpenFilePlan: Equatable {
    let action: EzraOpenFileAction
    /// The app the file opens in, for the result text (nil for the default app and for Finder).
    let applicationDisplayName: String?
    /// True when the file opens at the line the model asked for.
    let opensAtTheRequestedLine: Bool
    /// A line was asked for but the app cannot open at one, so the file opens without it.
    let lineWasLeftOut: Bool
}

nonisolated enum EzraOpenFileDecisionResult: Equatable {
    case refused(String)
    case plan(EzraOpenFilePlan)
}

nonisolated enum EzraOpenFileDecision {
    /// Extensions that are an app, an installer or a file that runs when opened.
    static let refusedExtensions: Set<String> = [
        "app", "pkg", "mpkg", "dmg",
        "command", "tool", "terminal", "workflow", "shortcut", "scpt", "scptd", "applescript",
        // Added in review: a Java archive or launch file runs code; a location file opens the link or
        // place it holds, which would skip the link rule; a configuration profile starts an install.
        "jar", "jnlp", "webloc", "inetloc", "fileloc", "url", "afploc", "ftploc", "mobileconfig",
        // From the tester's report: an old Terminal settings file can run commands, office files with
        // macros run code once enabled, and a remote desktop or screen sharing file connects to a host.
        "term", "docm", "xlsm", "pptm", "potm", "dotm", "xltm", "rdp", "vnc",
    ]

    /// Script languages: whatever the default app is, these open only in an editor (the one in
    /// front, a known editor that is the default, or TextEdit), never in an app this file does not
    /// know, which could be a terminal or a launcher that runs them.
    static let scriptExtensions: Set<String> = [
        "sh", "zsh", "bash", "fish", "csh", "tcsh", "ksh", "py", "pyw", "rb", "pl", "php", "js", "mjs", "cjs",
        "lua", "tcl", "ps1", "bat", "cmd", "awk",
    ]

    /// Text, source and script files: the kind of file an editor is the right place for.
    static let textSourceAndScriptExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "log", "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "plist", "ini", "cfg", "conf", "env",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "go", "rs", "rb", "py", "js", "jsx", "mjs", "cjs", "ts", "tsx",
        "php", "pl", "lua", "r", "scala", "dart", "sql", "graphql", "html", "htm", "css", "scss", "sass", "less", "vue", "svelte",
        "sh", "zsh", "bash", "fish", "ps1", "bat", "gradle", "make", "mk", "cmake", "dockerfile", "gitignore", "gitattributes", "editorconfig", "strings", "entitlements", "xcconfig", "pbxproj",
    ]

    static let refusedBecauseItWouldRun = EzraActionResultTexts.programWouldRun

    /// Picks what happens to a file, a folder or a request to show it in Finder.
    static func decide(
        facts: EzraOpenFileFacts,
        fileURL: URL,
        line: Int?,
        revealRequested: Bool
    ) -> EzraOpenFileDecisionResult {
        // Showing something in Finder runs nothing, so a request to reveal is always allowed.
        if revealRequested {
            return .plan(EzraOpenFilePlan(action: .revealInFinder, applicationDisplayName: nil, opensAtTheRequestedLine: false, lineWasLeftOut: false))
        }
        // An app bundle is a folder on disk, so this check comes before the folder one: opening
        // "Tool.app" would launch it.
        if refusedExtensions.contains(facts.fileExtension) || facts.isMachOProgram {
            return .refused(refusedBecauseItWouldRun)
        }
        if facts.isFolder {
            return .plan(EzraOpenFilePlan(action: .revealInFinder, applicationDisplayName: nil, opensAtTheRequestedLine: false, lineWasLeftOut: false))
        }

        // A script (by its extension, or any file with an executable bit) is only ever opened in an
        // editor, never in an app this file does not know.
        let isAScript = scriptExtensions.contains(facts.fileExtension) || facts.hasExecutableBit
        let isATextSourceOrScriptFile = textSourceAndScriptExtensions.contains(facts.fileExtension) || isAScript

        // Which app opens it. A text, source or script file goes to the editor the user is in; any
        // other file, and any text file when no editor is in front, goes to its default app. A script
        // whose default app is not a known editor goes to TextEdit.
        var chosenEditor: EzraKnownEditor?
        if isATextSourceOrScriptFile, let frontmostEditor = EzraKnownEditors.editor(forBundleIdentifier: facts.frontmostApplicationBundleIdentifier) {
            chosenEditor = frontmostEditor
        } else if EzraKnownEditors.appRunsThings(bundleIdentifier: facts.defaultApplicationBundleIdentifier) {
            chosenEditor = EzraKnownEditors.textEdit
        } else if let defaultEditor = EzraKnownEditors.editor(forBundleIdentifier: facts.defaultApplicationBundleIdentifier) {
            chosenEditor = defaultEditor
        } else if isAScript {
            chosenEditor = EzraKnownEditors.textEdit
        } else {
            chosenEditor = nil
        }

        guard let chosenEditor else {
            // The default app (or none: the executor then reports that nothing could open it).
            return .plan(EzraOpenFilePlan(action: .openWithDefaultApplication, applicationDisplayName: nil, opensAtTheRequestedLine: false, lineWasLeftOut: line != nil))
        }

        if let line, line >= 1 {
            switch chosenEditor.lineSupport {
            case .urlScheme(let scheme):
                if let lineURL = editorURL(scheme: scheme, fileURL: fileURL, line: line) {
                    return .plan(EzraOpenFilePlan(action: .openAtLineWithURLScheme(lineURL), applicationDisplayName: chosenEditor.displayName, opensAtTheRequestedLine: true, lineWasLeftOut: false))
                }
            case .xed:
                return .plan(EzraOpenFilePlan(action: .openAtLineWithXed(line: line), applicationDisplayName: chosenEditor.displayName, opensAtTheRequestedLine: true, lineWasLeftOut: false))
            case .none:
                break
            }
        }
        return .plan(EzraOpenFilePlan(
            action: .openInApplication(bundleIdentifier: chosenEditor.bundleIdentifier),
            applicationDisplayName: chosenEditor.displayName,
            opensAtTheRequestedLine: false,
            lineWasLeftOut: line != nil
        ))
    }

    /// `vscode://file/<path>:<line>` with the path percent-encoded.
    static func editorURL(scheme: String, fileURL: URL, line: Int) -> URL? {
        guard let encodedPath = fileURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "\(scheme)://file\(encodedPath):\(line)")
    }

    /// The result text after the file opened.
    static func openedResultText(fileName: String, plan: EzraOpenFilePlan, line: Int?) -> String {
        let shownName = EzraActionText.oneLine(fileName, maximumCharacters: 80)
        switch plan.action {
        case .revealInFinder:
            return "showed \(shownName) in finder."
        case .openWithDefaultApplication:
            return plan.lineWasLeftOut ? "opened \(shownName), without the line: its app can't open at a line." : "opened \(shownName)."
        case .openInApplication, .openAtLineWithURLScheme, .openAtLineWithXed:
            let applicationName = plan.applicationDisplayName ?? "its app"
            if plan.opensAtTheRequestedLine, let line {
                return "opened \(shownName) at line \(line) in \(applicationName)."
            }
            if plan.lineWasLeftOut {
                return "opened \(shownName) in \(applicationName), without the line: \(applicationName) can't open at a line."
            }
            return "opened \(shownName) in \(applicationName)."
        }
    }
}
