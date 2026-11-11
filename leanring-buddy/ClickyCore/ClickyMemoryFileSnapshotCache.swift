import Foundation

/// An in-memory copy of the markdown files in the notes folder (the daily notes and profile.md),
/// so that building a turn's prompt never waits for the disk.
///
/// Why it exists: the notes folder lives in ~/Documents, which on this kind of Mac is managed by
/// the iCloud file provider. Reading it is usually instant, but now and then the first read after
/// a pause took 3 to 6 seconds, and the user waited that long before Clicky even asked Claude.
///
/// How it is used:
/// - The app switches it on for the real notes folder and refreshes it in the background (at
///   launch and each time the push-to-talk keys go down).
/// - Only the reads that build the prompt use it. Every save or removal still reads the file
///   fresh from disk first, so a hand edit is never overwritten from a stale copy, and refreshes
///   the copy after writing.
/// - A folder it was never switched on for (every test folder) is always read from disk.
nonisolated final class ClickyMemoryFileSnapshotCache: @unchecked Sendable {
    static let shared = ClickyMemoryFileSnapshotCache()

    private let stateLock = NSLock()
    private var enabledDirectoryPaths = Set<String>()
    private var markdownFileContentsByFileNameByDirectoryPath: [String: [String: String]] = [:]

    /// Switches the cache on for one folder. Until the first refresh finishes, reads fall back to disk.
    func enable(forDirectory directoryURL: URL) {
        stateLock.lock()
        enabledDirectoryPaths.insert(directoryURL.standardizedFileURL.path)
        stateLock.unlock()
    }

    /// The cached files of a folder (file name to contents), or nil when the folder is not cached
    /// or has not been read yet. Never touches the disk.
    func cachedMarkdownFileContentsByFileName(inDirectory directoryURL: URL) -> [String: String]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return markdownFileContentsByFileNameByDirectoryPath[directoryURL.standardizedFileURL.path]
    }

    /// Reads the folder from disk and replaces the cached copy. This is the slow part, so the app
    /// calls it off the main thread. Does nothing for a folder the cache is not switched on for.
    func refresh(directory directoryURL: URL) {
        let directoryPath = directoryURL.standardizedFileURL.path
        stateLock.lock()
        let isEnabledForDirectory = enabledDirectoryPaths.contains(directoryPath)
        stateLock.unlock()
        guard isEnabledForDirectory else {
            return
        }

        let freshMarkdownFileContentsByFileName = Self.readMarkdownFilesFromDisk(inDirectory: directoryURL)
        stateLock.lock()
        markdownFileContentsByFileNameByDirectoryPath[directoryPath] = freshMarkdownFileContentsByFileName
        stateLock.unlock()
    }

    /// Every ".md" file directly inside the folder. A missing folder or an unreadable file is
    /// simply left out, as the stores already treat them.
    static func readMarkdownFilesFromDisk(inDirectory directoryURL: URL) -> [String: String] {
        let fileURLsInDirectory = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        var markdownFileContentsByFileName: [String: String] = [:]
        for fileURL in fileURLsInDirectory where fileURL.pathExtension == "md" {
            if let fileContents = try? String(contentsOf: fileURL, encoding: .utf8) {
                markdownFileContentsByFileName[fileURL.lastPathComponent] = fileContents
            }
        }
        return markdownFileContentsByFileName
    }
}
