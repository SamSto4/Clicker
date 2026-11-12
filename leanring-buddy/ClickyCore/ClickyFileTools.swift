import Foundation

// Round 17 (file editing): the five client tools Claude may call, how their input is read, and the
// per-turn session that runs them. The two read tools run at once; the three proposal tools only
// queue a change (nothing touches the disk until the user confirms). Foundation only.

// MARK: - The five tools

nonisolated enum ClickyFileToolName: String, CaseIterable, Equatable {
    case listFolder = "list_folder"
    case readFile = "read_file"
    case proposeEdit = "propose_edit"
    case proposeNewFile = "propose_new_file"
    case proposeDelete = "propose_delete"
}

nonisolated enum ClickyFileToolDefinitions {
    /// The `tools` array of a chat request, exactly as sent. The order and the text are fixed, so
    /// the cached prefix (tools come before the system prompt) is the same on every turn. There is
    /// no `tool_choice`: forcing a tool is a 400 on Sonnet 5.5, and `auto` is the default.
    static func toolsArray() -> [[String: Any]] {
        let pathDescription = "Absolute path, a path starting with ~, a path starting with a folder's name (project/README.md), or a path relative to the open document's folder."
        let summaryDescription = "One short line saying what the change does, for the user."
        return [
            [
                "name": ClickyFileToolName.listFolder.rawValue,
                "description": "List the files and folders inside a folder the user lets you edit, to find a file. Returns at most \(ClickyFileEditingLimits.maximumListedEntries) entries with their sizes.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "The folder. \(pathDescription) Use \".\" for the open document's folder."],
                    ],
                    "required": ["path"],
                ] as [String: Any],
            ],
            [
                "name": ClickyFileToolName.readFile.rawValue,
                "description": "Read a text file inside the folders you may edit. Returns numbered lines, at most \(ClickyFileEditingLimits.maximumLinesPerRead) lines or \(ClickyFileEditingLimits.maximumBytesPerRead / 1024) KB per call; pass start_line and end_line to read another part. Read a file before you propose a change to it.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": pathDescription],
                        "start_line": ["type": "integer", "description": "First line to return, counting from 1."],
                        "end_line": ["type": "integer", "description": "Last line to return."],
                    ],
                    "required": ["path"],
                ] as [String: Any],
            ],
            [
                "name": ClickyFileToolName.proposeEdit.rawValue,
                "description": "Propose replacing one exact piece of text in a file. Nothing is written until the user confirms with return or by saying yes, so never say the change is done. old_text must occur in the file exactly once (include surrounding lines if it does not); new_text must differ from it. Read the file first and propose the smallest change that does the job.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": pathDescription],
                        "old_text": ["type": "string", "description": "The exact text to replace, copied from the file without the line numbers."],
                        "new_text": ["type": "string", "description": "The text that replaces it."],
                        "summary": ["type": "string", "description": summaryDescription],
                    ],
                    "required": ["path", "old_text", "new_text", "summary"],
                ] as [String: Any],
            ],
            [
                "name": ClickyFileToolName.proposeNewFile.rawValue,
                "description": "Propose creating a new text file. It is refused if the file already exists. Nothing is written until the user confirms with return or by saying yes.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": pathDescription],
                        "content": ["type": "string", "description": "Everything that goes in the file."],
                        "summary": ["type": "string", "description": summaryDescription],
                    ],
                    "required": ["path", "content", "summary"],
                ] as [String: Any],
            ],
            [
                "name": ClickyFileToolName.proposeDelete.rawValue,
                "description": "Propose deleting one file. It moves to the Trash only when the user confirms with return or by saying yes; nothing happens before.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": pathDescription],
                        "summary": ["type": "string", "description": summaryDescription],
                    ],
                    "required": ["path", "summary"],
                ] as [String: Any],
            ],
        ]
    }
}

// MARK: - Reading a tool call

nonisolated enum ClickyFileToolCall: Equatable {
    case listFolder(path: String)
    case readFile(path: String, startLine: Int?, endLine: Int?)
    case proposeEdit(path: String, oldText: String, newText: String, summary: String)
    case proposeNewFile(path: String, content: String, summary: String)
    case proposeDelete(path: String, summary: String)

    /// The tool call, or the short sentence that tells the model what was wrong with it.
    static func parse(toolName: String, input: [String: Any]) -> Result<ClickyFileToolCall, ClickyFileToolInputError> {
        guard let knownToolName = ClickyFileToolName(rawValue: toolName) else {
            return .failure(ClickyFileToolInputError(message: "i don't have a tool called \(toolName)."))
        }

        func requiredText(_ fieldName: String) -> Result<String, ClickyFileToolInputError> {
            guard let value = input[fieldName] as? String else {
                return .failure(ClickyFileToolInputError(message: "\(toolName) needs a text value for \(fieldName)."))
            }
            return .success(value)
        }
        /// A summary is only a label for the user, so a missing one is not an error.
        func optionalSummary() -> String {
            (input["summary"] as? String) ?? ""
        }
        func optionalWholeNumber(_ fieldName: String) -> Result<Int?, ClickyFileToolInputError> {
            guard let rawValue = input[fieldName], !(rawValue is NSNull) else {
                return .success(nil)
            }
            guard let number = rawValue as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == number.doubleValue.rounded() else {
                return .failure(ClickyFileToolInputError(message: "\(toolName) needs a whole number for \(fieldName)."))
            }
            return .success(number.intValue)
        }

        switch knownToolName {
        case .listFolder:
            switch requiredText("path") {
            case .failure(let error): return .failure(error)
            case .success(let path): return .success(.listFolder(path: path))
            }
        case .readFile:
            switch (requiredText("path"), optionalWholeNumber("start_line"), optionalWholeNumber("end_line")) {
            case (.failure(let error), _, _), (_, .failure(let error), _), (_, _, .failure(let error)):
                return .failure(error)
            case (.success(let path), .success(let startLine), .success(let endLine)):
                return .success(.readFile(path: path, startLine: startLine, endLine: endLine))
            }
        case .proposeEdit:
            switch (requiredText("path"), requiredText("old_text"), requiredText("new_text")) {
            case (.failure(let error), _, _), (_, .failure(let error), _), (_, _, .failure(let error)):
                return .failure(error)
            case (.success(let path), .success(let oldText), .success(let newText)):
                return .success(.proposeEdit(path: path, oldText: oldText, newText: newText, summary: optionalSummary()))
            }
        case .proposeNewFile:
            switch (requiredText("path"), requiredText("content")) {
            case (.failure(let error), _), (_, .failure(let error)):
                return .failure(error)
            case (.success(let path), .success(let content)):
                return .success(.proposeNewFile(path: path, content: content, summary: optionalSummary()))
            }
        case .proposeDelete:
            switch requiredText("path") {
            case .failure(let error): return .failure(error)
            case .success(let path): return .success(.proposeDelete(path: path, summary: optionalSummary()))
            }
        }
    }
}

nonisolated struct ClickyFileToolInputError: Error, Equatable {
    let message: String
}

// MARK: - The result of one tool call

nonisolated struct ClickyFileToolResult: Equatable {
    /// What the model reads as the `tool_result` content.
    let text: String
    /// True for a refusal or a failure; the loop sends it with `is_error`.
    let isError: Bool

    static func success(_ text: String) -> ClickyFileToolResult {
        ClickyFileToolResult(text: text, isError: false)
    }

    static func failure(_ text: String) -> ClickyFileToolResult {
        ClickyFileToolResult(text: text, isError: true)
    }
}

// MARK: - The session of one turn

/// Runs the tool calls of one turn against one path policy, and keeps what the turn used and
/// queued: the number of calls, the bytes read, and the proposed changes. The tool loop calls
/// `execute` for each `tool_use` block, one after the other.
nonisolated final class ClickyFileToolTurnSession: @unchecked Sendable {
    /// The reply to a proposal that was queued. The model must not say the change is done.
    static let changeQueuedResultText = "queued; the user must confirm with return or a spoken yes before anything is written."

    static let toolCallLimitResultText = "you have used all \(ClickyFileEditingLimits.maximumToolCallsPerTurn) tool calls allowed in one turn. stop calling tools and tell the user what you found so far."
    static let bytesReadLimitResultText = "you have read as much as one turn allows (\(ClickyFileEditingLimits.maximumBytesReadPerTurn / 1024) KB). stop reading and tell the user what you found so far."
    static let changeCountLimitResultText = "at most \(ClickyFileEditingLimits.maximumChangesPerTurn) changes can be queued in one turn. tell the user to confirm these first, then ask again for the rest."

    private let policy: ClickyFilePathPolicy
    private let fileManager: FileManager
    private let lock = NSLock()

    private var queuedChangesStorage: [ClickyFileChange] = []
    private var toolCallCountStorage = 0
    private var bytesReadStorage = 0

    init(policy: ClickyFilePathPolicy, fileManager: FileManager = .default) {
        self.policy = policy
        self.fileManager = fileManager
    }

    var queuedChanges: [ClickyFileChange] {
        lock.lock(); defer { lock.unlock() }
        return queuedChangesStorage
    }

    var toolCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return toolCallCountStorage
    }

    /// The bytes of file text returned to the model by `read_file`.
    var bytesRead: Int {
        lock.lock(); defer { lock.unlock() }
        return bytesReadStorage
    }

    /// Runs one tool call. Never throws: every problem comes back as a short sentence the model can
    /// act on.
    func execute(toolName: String, input: [String: Any]) -> ClickyFileToolResult {
        lock.lock(); defer { lock.unlock() }

        toolCallCountStorage += 1
        if toolCallCountStorage > ClickyFileEditingLimits.maximumToolCallsPerTurn {
            return .failure(Self.toolCallLimitResultText)
        }

        let toolCall: ClickyFileToolCall
        switch ClickyFileToolCall.parse(toolName: toolName, input: input) {
        case .failure(let inputError):
            return .failure(inputError.message)
        case .success(let parsedToolCall):
            toolCall = parsedToolCall
        }

        switch toolCall {
        case .listFolder(let path):
            return listFolder(rawPath: path)
        case .readFile(let path, let startLine, let endLine):
            return readFile(rawPath: path, startLine: startLine, endLine: endLine)
        case .proposeEdit(let path, let oldText, let newText, let summary):
            return proposeEdit(rawPath: path, oldText: oldText, newText: newText, rawSummary: summary)
        case .proposeNewFile(let path, let content, let summary):
            return proposeNewFile(rawPath: path, content: content, rawSummary: summary)
        case .proposeDelete(let path, let summary):
            return proposeDelete(rawPath: path, rawSummary: summary)
        }
    }

    // MARK: - list_folder

    private func listFolder(rawPath: String) -> ClickyFileToolResult {
        switch policy.resolve(rawPath: rawPath, intent: .existingItem) {
        case .failure(let refusal):
            // "." or an empty path with several folders and no open document: show the folders.
            let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPath.isEmpty || trimmedPath == "." {
                switch refusal {
                case .existsInSeveralFolders, .emptyPath, .doesNotExist:
                    if !policy.allowedFolderURLs.isEmpty {
                        let folderLines = policy.allowedFolderURLs.map { "\(ClickyEditableFolders.displayName(forFolderPath: $0.path)) (\($0.path))" }
                        return .success("folders you may edit:\n" + folderLines.joined(separator: "\n"))
                    }
                default:
                    break
                }
            }
            return .failure(refusal.message)
        case .success(let resolvedPath):
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolvedPath.fileURL.path, isDirectory: &isDirectory) else {
                return .failure(ClickyFilePathRefusal.doesNotExist.message)
            }
            guard isDirectory.boolValue else {
                return .failure("that is a file, not a folder. use read_file.")
            }
            guard let entryURLs = try? fileManager.contentsOfDirectory(
                at: resolvedPath.fileURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            ) else {
                return .failure("i couldn't list that folder.")
            }

            var hiddenEntryCount = 0
            var visibleEntries: [(name: String, description: String)] = []
            for entryURL in entryURLs {
                let entryName = entryURL.lastPathComponent
                if ClickyProtectedFileNames.isGitFolderName(entryName) || ClickyProtectedFileNames.nameIsProtected(entryName) {
                    hiddenEntryCount += 1
                    continue
                }
                let resourceValues = try? entryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                if resourceValues?.isSymbolicLink == true {
                    visibleEntries.append((entryName, "\(entryName) (link)"))
                } else if resourceValues?.isDirectory == true {
                    visibleEntries.append((entryName, "\(entryName)/ (folder)"))
                } else {
                    let sizeText = ClickyByteCountText.text(forByteCount: resourceValues?.fileSize ?? 0)
                    visibleEntries.append((entryName, "\(entryName) (file, \(sizeText))"))
                }
            }
            visibleEntries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            let displayPath = Self.displayPath(of: resolvedPath)
            var resultLines: [String] = []
            if visibleEntries.isEmpty {
                resultLines.append("\(displayPath) is empty.")
            } else if visibleEntries.count > ClickyFileEditingLimits.maximumListedEntries {
                resultLines.append("\(displayPath): the first \(ClickyFileEditingLimits.maximumListedEntries) of \(visibleEntries.count) entries:")
            } else {
                resultLines.append("\(displayPath): \(visibleEntries.count) \(visibleEntries.count == 1 ? "entry" : "entries"):")
            }
            resultLines.append(contentsOf: visibleEntries.prefix(ClickyFileEditingLimits.maximumListedEntries).map(\.description))
            if hiddenEntryCount > 0 {
                resultLines.append("(\(hiddenEntryCount) \(hiddenEntryCount == 1 ? "entry is" : "entries are") hidden: not readable or editable)")
            }
            return .success(resultLines.joined(separator: "\n"))
        }
    }

    // MARK: - read_file

    private func readFile(rawPath: String, startLine: Int?, endLine: Int?) -> ClickyFileToolResult {
        if bytesReadStorage >= ClickyFileEditingLimits.maximumBytesReadPerTurn {
            return .failure(Self.bytesReadLimitResultText)
        }
        let resolvedPath: ClickyResolvedFilePath
        switch policy.resolve(rawPath: rawPath, intent: .existingItem) {
        case .failure(let refusal): return .failure(refusal.message)
        case .success(let path): resolvedPath = path
        }
        let fileText: String
        switch ClickyFileTextReader.readText(at: resolvedPath.fileURL, fileManager: fileManager) {
        case .failure(let readFailure): return .failure(readFailure.message)
        case .success(let text): fileText = text
        }

        let fileLines = ClickyTextLines.lines(of: fileText)
        let displayPath = Self.displayPath(of: resolvedPath)
        if fileLines.isEmpty {
            return .success("\(displayPath) is empty.")
        }

        let firstLineNumber = max(1, startLine ?? 1)
        if firstLineNumber > fileLines.count {
            return .failure("that file has only \(fileLines.count) \(fileLines.count == 1 ? "line" : "lines").")
        }
        let requestedLastLineNumber = min(fileLines.count, endLine ?? fileLines.count)
        if requestedLastLineNumber < firstLineNumber {
            return .failure("end_line is before start_line.")
        }
        let cappedLastLineNumber = min(requestedLastLineNumber, firstLineNumber + ClickyFileEditingLimits.maximumLinesPerRead - 1)

        let windowRange = (firstLineNumber - 1)..<cappedLastLineNumber
        let secretLineIndexes = ClickyFileContentRedaction.secretLineIndexes(in: fileLines, rangeToCheck: windowRange)

        var numberedLines: [String] = []
        var byteCountOfNumberedLines = 0
        var lastLineNumberShown = firstLineNumber - 1
        var hiddenSecretLineCount = 0
        for lineIndex in windowRange {
            let isSecret = secretLineIndexes.contains(lineIndex)
            let numberedLine = "\(lineIndex + 1): " + ClickyFileContentRedaction.visibleLine(fileLines[lineIndex], isSecret: isSecret)
            let byteCountWithThisLine = byteCountOfNumberedLines + numberedLine.utf8.count + 1
            // One line is always shown, however long, so a read always makes progress.
            if byteCountWithThisLine > ClickyFileEditingLimits.maximumBytesPerRead && !numberedLines.isEmpty {
                break
            }
            numberedLines.append(numberedLine)
            byteCountOfNumberedLines = byteCountWithThisLine
            lastLineNumberShown = lineIndex + 1
            if isSecret {
                hiddenSecretLineCount += 1
            }
        }

        var resultLines = ["\(displayPath), lines \(firstLineNumber)-\(lastLineNumberShown) of \(fileLines.count):"]
        resultLines.append(contentsOf: numberedLines)
        if lastLineNumberShown < requestedLastLineNumber {
            resultLines.append("(cut after line \(lastLineNumberShown). to continue, call read_file with start_line \(lastLineNumberShown + 1).)")
        }
        if hiddenSecretLineCount > 0 {
            // The live eval had the model ask the user to paste such a line into the chat; it must not.
            resultLines.append("(\(hiddenSecretLineCount) \(hiddenSecretLineCount == 1 ? "line was" : "lines were") hidden: looked like a secret. you cannot change \(hiddenSecretLineCount == 1 ? "it" : "them"); never ask the user to paste a secret, they can change it themselves.)")
        }
        let resultText = resultLines.joined(separator: "\n")
        bytesReadStorage += byteCountOfNumberedLines
        return .success(resultText)
    }

    // MARK: - propose_edit

    /// What the model is told when the text is missing, or sits on a line that is hidden from it.
    /// The two are deliberately the same sentence: the model must not learn that a hidden line exists.
    static let textNotFoundResultText = "i couldn't find old_text in that file. read the file again and copy old_text exactly, without the line numbers."

    private func proposeEdit(rawPath: String, oldText modelOldText: String, newText modelNewText: String, rawSummary: String) -> ClickyFileToolResult {
        if queuedChangesStorage.count >= ClickyFileEditingLimits.maximumChangesPerTurn {
            return .failure(Self.changeCountLimitResultText)
        }
        let resolvedPath: ClickyResolvedFilePath
        switch policy.resolve(rawPath: rawPath, intent: .existingItem) {
        case .failure(let refusal): return .failure(refusal.message)
        case .success(let path): resolvedPath = path
        }
        if let conflictText = conflictWithQueuedChanges(forFileURL: resolvedPath.fileURL, newActionIsEdit: true) {
            return .failure(conflictText)
        }
        let diskText: String
        switch ClickyFileTextReader.readText(at: resolvedPath.fileURL, fileManager: fileManager) {
        case .failure(let readFailure): return .failure(readFailure.message)
        case .success(let text): diskText = text
        }

        // Edits already queued for this file in this turn are applied first, in order, so this one
        // is checked against the text the file will have when it comes up.
        var textBeforeThisEdit = diskText
        for queuedChange in queuedChangesStorage where queuedChange.fileURL == resolvedPath.fileURL && queuedChange.action == .edit {
            if let queuedOldText = queuedChange.oldText, let queuedNewText = queuedChange.newText,
               let queuedRange = textBeforeThisEdit.range(of: queuedOldText, options: [.literal]) {
                textBeforeThisEdit.replaceSubrange(queuedRange, with: queuedNewText)
            }
        }

        if modelOldText.isEmpty {
            return .failure("old_text is empty. give the exact text to replace.")
        }
        let oldText = ClickyTextLines.matchingLineEndings(of: modelOldText, toFileText: diskText)
        let newText = ClickyTextLines.matchingLineEndings(of: modelNewText, toFileText: diskText)
        if oldText == newText {
            return .failure("new_text is the same as old_text, so there is nothing to change.")
        }

        let matchRanges = Self.nonOverlappingRanges(of: oldText, in: textBeforeThisEdit)
        if matchRanges.isEmpty {
            return .failure(Self.textNotFoundResultText)
        }
        if matchRanges.count > 1 {
            return .failure("old_text appears \(matchRanges.count) times in that file. add more surrounding lines so it matches exactly once.")
        }
        let matchRange = matchRanges[0]

        // A match that touches a line hidden as a secret is refused as if it were not there.
        let linesBeforeThisEdit = textBeforeThisEdit.components(separatedBy: "\n")
        // Counted as unicode scalars: a Windows line break is one Character in Swift, not two.
        let firstMatchedLineIndex = textBeforeThisEdit[..<matchRange.lowerBound].unicodeScalars.filter { $0 == "\n" }.count
        var lastMatchedLineIndex = textBeforeThisEdit[..<matchRange.upperBound].unicodeScalars.filter { $0 == "\n" }.count
        if oldText.hasSuffix("\n") {
            lastMatchedLineIndex -= 1
        }
        lastMatchedLineIndex = max(firstMatchedLineIndex, min(lastMatchedLineIndex, linesBeforeThisEdit.count - 1))
        let secretLineIndexes = ClickyFileContentRedaction.secretLineIndexes(
            in: linesBeforeThisEdit,
            rangeToCheck: firstMatchedLineIndex..<(lastMatchedLineIndex + 1)
        )
        if (firstMatchedLineIndex...lastMatchedLineIndex).contains(where: { secretLineIndexes.contains($0) }) {
            return .failure(Self.textNotFoundResultText)
        }

        var textAfterThisEdit = textBeforeThisEdit
        textAfterThisEdit.replaceSubrange(matchRange, with: newText)
        let diffLines = ClickyLineDiff.hunks(
            oldLines: ClickyTextLines.lines(of: textBeforeThisEdit),
            newLines: ClickyTextLines.lines(of: textAfterThisEdit)
        )
        let diffPreview = ClickyChangeDiffPreview.preview(of: diffLines)

        queuedChangesStorage.append(ClickyFileChange(
            identifier: UUID(),
            action: .edit,
            fileURL: resolvedPath.fileURL,
            allowedFolderURL: resolvedPath.allowedFolderURL,
            relativePath: resolvedPath.relativePathInAllowedFolder,
            summary: ClickyChangeHistoryText.cleanedSummary(rawSummary),
            oldText: oldText,
            newText: newText,
            newFileContent: nil,
            diffPreviewLines: diffPreview.lines,
            hiddenDiffLineCount: diffPreview.hiddenLineCount,
            deletedFileDescription: nil
        ))
        return .success(Self.changeQueuedResultText)
    }

    // MARK: - propose_new_file

    private func proposeNewFile(rawPath: String, content: String, rawSummary: String) -> ClickyFileToolResult {
        if queuedChangesStorage.count >= ClickyFileEditingLimits.maximumChangesPerTurn {
            return .failure(Self.changeCountLimitResultText)
        }
        let resolvedPath: ClickyResolvedFilePath
        switch policy.resolve(rawPath: rawPath, intent: .newFile) {
        case .failure(let refusal): return .failure(refusal.message)
        case .success(let path): resolvedPath = path
        }
        guard !resolvedPath.relativePathInAllowedFolder.isEmpty else {
            return .failure("that is the folder itself. give a file name.")
        }
        // `attributesOfItem` does not follow links, so a link (even one that points nowhere) counts
        // as something that exists and is not overwritten.
        if (try? fileManager.attributesOfItem(atPath: resolvedPath.fileURL.path)) != nil {
            return .failure("that file already exists. use propose_edit to change it.")
        }
        if queuedChangesStorage.contains(where: { $0.fileURL == resolvedPath.fileURL }) {
            return .failure("a change for that file is already queued in this turn.")
        }
        if content.utf8.count > ClickyFileEditingLimits.maximumFileBytes {
            return .failure("that content is bigger than \(ClickyFileEditingLimits.maximumFileBytes / 1024) KB, so a file that big is not created.")
        }
        if content.utf8.prefix(ClickyFileEditingLimits.binarySniffByteCount).contains(0) {
            return .failure("only plain text files can be created.")
        }
        // The folders above the file may not exist yet, but the nearest one that does must be a folder.
        var nearestExistingAncestorURL = resolvedPath.fileURL.deletingLastPathComponent()
        while (try? fileManager.attributesOfItem(atPath: nearestExistingAncestorURL.path)) == nil, nearestExistingAncestorURL.path != "/" {
            nearestExistingAncestorURL = nearestExistingAncestorURL.deletingLastPathComponent()
        }
        var ancestorIsDirectory: ObjCBool = false
        fileManager.fileExists(atPath: nearestExistingAncestorURL.path, isDirectory: &ancestorIsDirectory)
        guard ancestorIsDirectory.boolValue else {
            return .failure("a part of that path is a file, not a folder.")
        }

        let addedLines = ClickyLineDiff.addedLines(of: ClickyTextLines.lines(of: content))
        let diffPreview = ClickyChangeDiffPreview.preview(of: addedLines)
        queuedChangesStorage.append(ClickyFileChange(
            identifier: UUID(),
            action: .newFile,
            fileURL: resolvedPath.fileURL,
            allowedFolderURL: resolvedPath.allowedFolderURL,
            relativePath: resolvedPath.relativePathInAllowedFolder,
            summary: ClickyChangeHistoryText.cleanedSummary(rawSummary),
            oldText: nil,
            newText: nil,
            newFileContent: content,
            diffPreviewLines: diffPreview.lines,
            hiddenDiffLineCount: diffPreview.hiddenLineCount,
            deletedFileDescription: nil
        ))
        return .success(Self.changeQueuedResultText)
    }

    // MARK: - propose_delete

    private func proposeDelete(rawPath: String, rawSummary: String) -> ClickyFileToolResult {
        if queuedChangesStorage.count >= ClickyFileEditingLimits.maximumChangesPerTurn {
            return .failure(Self.changeCountLimitResultText)
        }
        let resolvedPath: ClickyResolvedFilePath
        switch policy.resolve(rawPath: rawPath, intent: .existingItem) {
        case .failure(let refusal): return .failure(refusal.message)
        case .success(let path): resolvedPath = path
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedPath.fileURL.path, isDirectory: &isDirectory) else {
            return .failure(ClickyFilePathRefusal.doesNotExist.message)
        }
        guard !isDirectory.boolValue else {
            return .failure("i can only delete single files, not folders.")
        }
        if let conflictText = conflictWithQueuedChanges(forFileURL: resolvedPath.fileURL, newActionIsEdit: false) {
            return .failure(conflictText)
        }
        let fileSize = ((try? fileManager.attributesOfItem(atPath: resolvedPath.fileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        queuedChangesStorage.append(ClickyFileChange(
            identifier: UUID(),
            action: .delete,
            fileURL: resolvedPath.fileURL,
            allowedFolderURL: resolvedPath.allowedFolderURL,
            relativePath: resolvedPath.relativePathInAllowedFolder,
            summary: ClickyChangeHistoryText.cleanedSummary(rawSummary),
            oldText: nil,
            newText: nil,
            newFileContent: nil,
            diffPreviewLines: [],
            hiddenDiffLineCount: 0,
            deletedFileDescription: ClickyByteCountText.text(forByteCount: fileSize)
        ))
        return .success(Self.changeQueuedResultText)
    }

    // MARK: - Shared

    /// Two proposals for one file are fine when both are edits (they are applied in order). Any
    /// other mix would leave the second one meaning something different from what was checked.
    private func conflictWithQueuedChanges(forFileURL fileURL: URL, newActionIsEdit: Bool) -> String? {
        for queuedChange in queuedChangesStorage where queuedChange.fileURL == fileURL {
            if newActionIsEdit && queuedChange.action == .edit {
                continue
            }
            return "a different change for that file is already queued in this turn."
        }
        return nil
    }

    private static func displayPath(of resolvedPath: ClickyResolvedFilePath) -> String {
        let folderName = resolvedPath.allowedFolderDisplayName
        return resolvedPath.relativePathInAllowedFolder.isEmpty ? folderName : folderName + "/" + resolvedPath.relativePathInAllowedFolder
    }

    /// Every place `needle` occurs in `text`, none overlapping the one before it.
    static func nonOverlappingRanges(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else {
            return []
        }
        var ranges: [Range<String.Index>] = []
        var searchStartIndex = text.startIndex
        while searchStartIndex < text.endIndex,
              let foundRange = text.range(of: needle, options: [.literal], range: searchStartIndex..<text.endIndex) {
            ranges.append(foundRange)
            searchStartIndex = foundRange.upperBound
        }
        return ranges
    }
}
