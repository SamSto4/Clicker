import Foundation

// Round 17 (file editing): reading a file's text for the model, hiding the lines that look like
// credentials, and splitting text into numbered lines. Foundation only.

/// Lines in the text a tool shows or checks, as the model sees them: no trailing carriage return
/// (a file with Windows line endings reads the same as any other), and no extra empty line at the
/// end of a file that ends with a line break.
nonisolated enum ClickyTextLines {
    static func lines(of text: String) -> [String] {
        if text.isEmpty {
            return []
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines.map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    /// True when the text uses Windows line endings. The model writes "\n", so text it gives for a
    /// file like that is converted before it is looked for or written.
    static func usesWindowsLineEndings(_ text: String) -> Bool {
        text.contains("\r\n")
    }

    /// The model's text with line breaks in the style of the file it is meant for.
    static func matchingLineEndings(of modelText: String, toFileText fileText: String) -> String {
        guard usesWindowsLineEndings(fileText) else {
            return modelText
        }
        return modelText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }
}

/// Lines that hold a credential are never shown to the model: they are replaced by one marker.
/// Only the shape rules run (`ClickySecretDetector.textHoldsCredentialShape`); the keyword rules
/// were tuned for spoken sentences and would flag ordinary source such as
/// `let appTokenHeaderName = "X-Clicky-App-Token"`.
nonisolated enum ClickyFileContentRedaction {
    static let removedLineMarker = "[removed: looked like a secret]"

    /// The indexes (0-based) of the lines among `lines` that look like a secret.
    ///
    /// A PEM private key block is hidden whole, from its BEGIN line to its END line, found with
    /// plain string search over every line (cheap). The shape rules run on the lines in
    /// `rangeToCheck` only (all lines when nil): they are regular expressions compiled for every
    /// call, so a caller that shows 400 lines of a 10,000 line file pays for 400.
    static func secretLineIndexes(in lines: [String], rangeToCheck: Range<Int>? = nil) -> Set<Int> {
        var secretIndexes = Set<Int>()
        for (lineIndex, line) in lines.enumerated() where !secretIndexes.contains(lineIndex) && isPrivateKeyHeaderLine(line) {
            // The block runs to its END line. A header with no END line close behind it (a line of
            // source that only mentions the header, such as a regular expression) hides itself only.
            let lastLineIndexToLookAt = min(lines.count - 1, lineIndex + maximumPrivateKeyBlockLineCount)
            let endLineIndex = (lineIndex...lastLineIndexToLookAt).first { lines[$0].contains("-----END") }
            let lastHiddenLineIndex = endLineIndex ?? lineIndex
            for hiddenLineIndex in lineIndex...lastHiddenLineIndex {
                secretIndexes.insert(hiddenLineIndex)
            }
        }
        let indexesToCheck = rangeToCheck ?? 0..<lines.count
        for lineIndex in indexesToCheck where lineIndex >= 0 && lineIndex < lines.count && !secretIndexes.contains(lineIndex) {
            if ClickySecretDetector.textHoldsCredentialShape(lines[lineIndex]) {
                secretIndexes.insert(lineIndex)
            }
        }
        return secretIndexes
    }

    /// The longest private key block that is hidden whole. Real keys are a few dozen lines.
    static let maximumPrivateKeyBlockLineCount = 100

    /// "-----BEGIN RSA PRIVATE KEY-----" and its kin: the whole line is the header.
    private static func isPrivateKeyHeaderLine(_ line: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        return trimmedLine.hasPrefix("-----BEGIN ") && trimmedLine.hasSuffix("-----") && trimmedLine.uppercased().contains("PRIVATE KEY")
    }

    /// The line as the model sees it.
    static func visibleLine(_ line: String, isSecret: Bool) -> String {
        isSecret ? removedLineMarker : line
    }
}

/// What reading a file can run into.
nonisolated enum ClickyFileReadFailure: Error, Equatable {
    case isAFolder
    case doesNotExist
    case notReadable
    case tooBig(byteCount: Int)
    case binary
    case notUTF8

    var message: String {
        switch self {
        case .isAFolder:
            return "that is a folder, not a file. use list_folder."
        case .doesNotExist:
            return "that path doesn't exist."
        case .notReadable:
            return "i couldn't read that file."
        case .tooBig:
            return "that file is bigger than \(ClickyFileEditingLimits.maximumFileBytes / 1024) KB, so it is not readable."
        case .binary:
            return "that file is binary, not text, so it is not readable."
        case .notUTF8:
            return "that file is not plain utf-8 text, so it is not readable."
        }
    }
}

nonisolated enum ClickyFileTextReader {
    /// The text of a file, or the reason it may not be read: a folder, too big (checked before
    /// the file is read), a NUL byte in the first 8 KB (binary), or bytes that are not utf-8.
    static func readText(at fileURL: URL, fileManager: FileManager = .default) -> Result<String, ClickyFileReadFailure> {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return .failure(.doesNotExist)
        }
        if isDirectory.boolValue {
            return .failure(.isAFolder)
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let fileSize = (attributes[.size] as? NSNumber)?.intValue,
           fileSize > ClickyFileEditingLimits.maximumFileBytes {
            return .failure(.tooBig(byteCount: fileSize))
        }
        guard let fileData = try? Data(contentsOf: fileURL) else {
            return .failure(.notReadable)
        }
        // The size could have changed between the check and the read.
        if fileData.count > ClickyFileEditingLimits.maximumFileBytes {
            return .failure(.tooBig(byteCount: fileData.count))
        }
        if fileData.prefix(ClickyFileEditingLimits.binarySniffByteCount).contains(0) {
            return .failure(.binary)
        }
        guard let fileText = String(data: fileData, encoding: .utf8) else {
            return .failure(.notUTF8)
        }
        return .success(fileText)
    }
}

/// How big a number of bytes is, in the few words a tool result uses.
nonisolated enum ClickyByteCountText {
    static func text(forByteCount byteCount: Int) -> String {
        if byteCount < 1024 {
            return "\(byteCount) bytes"
        }
        let kilobytes = Double(byteCount) / 1024
        if kilobytes < 1024 {
            return String(format: "%.1f KB", kilobytes)
        }
        return String(format: "%.1f MB", kilobytes / 1024)
    }
}
