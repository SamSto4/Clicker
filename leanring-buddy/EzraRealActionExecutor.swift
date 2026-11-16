//
//  EzraRealActionExecutor.swift
//  leanring-buddy
//
//  The real side of the action tools (round 18, Jarvis actions): the only place that launches an
//  app, opens a link or a file, talks to Apple Reminders (EventKit) or runs the `shortcuts`
//  command. Everything it is asked to do has already been checked by `EzraActionToolTurnSession`
//  (the link rule, the path policy, the open-file decision, the limits); this file only does it.
//  The checks and the eval use a fake that records calls instead (`EzraActionExecutor`).
//
//  Nothing here logs an app name, a link, a path, a reminder title, a timer label or a shortcut
//  name, and the output of a shortcut is never read.
//

import AppKit
import EventKit

// MARK: - The executor

nonisolated final class EzraRealActionExecutor: EzraActionExecutor, @unchecked Sendable {
    private let timerController: EzraTimerController
    private let remindersAccess: EzraRemindersAccess
    private let shortcutsCommand = EzraShortcutsCommand()

    init(timerController: EzraTimerController, remindersAccess: EzraRemindersAccess) {
        self.timerController = timerController
        self.remindersAccess = remindersAccess
    }

    // MARK: - Apps and links

    func installedApplications() async -> [EzraInstalledApplication] {
        let homeDirectoryPath = NSHomeDirectory()
        var installedApplications: [EzraInstalledApplication] = []
        for searchFolderPath in EzraAppNameMatcher.searchFolderPaths {
            let expandedFolderPath = searchFolderPath.hasPrefix("~/")
                ? homeDirectoryPath + String(searchFolderPath.dropFirst(1))
                : searchFolderPath
            // One level deep, and never inside a bundle: only the names of the folder's own entries.
            guard let entryNames = try? FileManager.default.contentsOfDirectory(atPath: expandedFolderPath) else { continue }
            for entryName in entryNames where entryName.hasSuffix(".app") {
                installedApplications.append(EzraInstalledApplication(
                    displayName: String(entryName.dropLast(4)),
                    path: expandedFolderPath + "/" + entryName
                ))
            }
        }
        return installedApplications
    }

    func launchApplication(_ application: EzraInstalledApplication) async -> Bool {
        await launchApplicationOnTheMainActor(atPath: application.path)
    }

    func openLink(_ url: URL) async -> Bool {
        await openOnTheMainActor(url)
    }

    func frontmostApplicationBundleIdentifier() async -> String? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }

    func defaultApplicationBundleIdentifier(forFileAt fileURL: URL) async -> String? {
        await MainActor.run {
            guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: fileURL) else { return nil }
            return Bundle(url: applicationURL)?.bundleIdentifier
        }
    }

    func perform(_ plan: EzraOpenFilePlan, onFileAt fileURL: URL) async -> Bool {
        switch plan.action {
        case .revealInFinder:
            return await revealOnTheMainActor(fileURL)
        case .openWithDefaultApplication:
            return await openOnTheMainActor(fileURL)
        case .openInApplication(let bundleIdentifier):
            return await openFileOnTheMainActor(fileURL, withApplicationWithBundleIdentifier: bundleIdentifier)
        case .openAtLineWithURLScheme(let editorURL):
            return await openOnTheMainActor(editorURL)
        case .openAtLineWithXed(let line):
            // An arguments array, never a shell: the path can hold any character.
            let result = await EzraProcessRunner.run(
                executablePath: "/usr/bin/xed",
                arguments: ["--line", String(line), fileURL.path],
                timeoutSeconds: 10,
                capturesOutput: false
            )
            return result.exitCode == 0
        }
    }

    @MainActor
    private func launchApplicationOnTheMainActor(atPath applicationPath: String) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: applicationPath), configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private func openOnTheMainActor(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func revealOnTheMainActor(_ fileURL: URL) -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return true
    }

    @MainActor
    private func openFileOnTheMainActor(_ fileURL: URL, withApplicationWithBundleIdentifier bundleIdentifier: String) async -> Bool {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([fileURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Timers

    func startTimer(durationSeconds: Int, rawLabel: String?) async -> EzraTimerStartOutcome {
        await timerController.startTimer(durationSeconds: durationSeconds, rawLabel: rawLabel)
    }

    func cancelTimer(reference: String) async -> EzraTimerCancelOutcome {
        await timerController.cancelTimer(reference: reference)
    }

    // MARK: - Reminders

    func createReminder(_ request: EzraReminderRequest) async -> EzraReminderCreateOutcome {
        await remindersAccess.createReminder(request)
    }

    func removeReminder(withIdentifier identifier: String) async -> Bool {
        await remindersAccess.removeReminder(withIdentifier: identifier)
    }

    func listReminders(range: EzraReminderRange) async -> EzraReminderListOutcome {
        await remindersAccess.listReminders(range: range)
    }

    // MARK: - Shortcuts

    func listShortcutNames() async -> EzraShortcutListOutcome {
        await shortcutsCommand.listNames()
    }

    func runShortcut(named name: String) async -> Bool {
        await shortcutsCommand.run(named: name)
    }
}

// MARK: - Running a command

nonisolated struct EzraProcessResult {
    /// nil when the command could not be started or was stopped for taking too long.
    let exitCode: Int32?
    /// What the command printed, only when asked for. Never logged.
    let output: String
}

nonisolated enum EzraProcessRunner {
    /// Runs a command with an arguments array (never a shell), waits for it for at most
    /// `timeoutSeconds` and stops it after that. Blocks a background thread, not the caller's.
    static func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        capturesOutput: Bool
    ) async -> EzraProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let outputPipe = Pipe()
                process.standardOutput = capturesOutput ? outputPipe : FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: EzraProcessResult(exitCode: nil, output: ""))
                    return
                }
                // The watchdog stops a command that takes too long, which also ends the read below.
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

                var outputData = Data()
                if capturesOutput {
                    outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                }
                process.waitUntilExit()
                let wasStoppedByTheWatchdog = watchdog.isCancelled == false && process.terminationReason == .uncaughtSignal
                watchdog.cancel()
                continuation.resume(returning: EzraProcessResult(
                    exitCode: wasStoppedByTheWatchdog ? nil : process.terminationStatus,
                    output: String(data: outputData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}

nonisolated final class EzraShortcutsCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var nameCache = EzraShortcutNameCache()

    /// `/usr/bin/shortcuts list`, with a 5 second limit. The names are kept for 60 seconds. The
    /// output format (one name per line) is what the command's documentation describes; it was not
    /// checked against a real run while this was written.
    func listNames() async -> EzraShortcutListOutcome {
        if let cachedNames = lock.withLock({ nameCache.names(at: Date()) }) {
            return .names(cachedNames)
        }
        let result = await EzraProcessRunner.run(
            executablePath: "/usr/bin/shortcuts",
            arguments: ["list"],
            timeoutSeconds: EzraActionLimits.shortcutListTimeoutSeconds,
            capturesOutput: true
        )
        guard result.exitCode == 0 else {
            return .failed
        }
        let names = EzraShortcutListParser.names(fromOutput: result.output)
        lock.withLock { nameCache.store(names, at: Date()) }
        return .names(names)
    }

    /// `/usr/bin/shortcuts run <name>`, with a 60 second limit. Its output is thrown away.
    func run(named name: String) async -> Bool {
        let result = await EzraProcessRunner.run(
            executablePath: "/usr/bin/shortcuts",
            arguments: ["run", name],
            timeoutSeconds: EzraActionLimits.shortcutRunTimeoutSeconds,
            capturesOutput: false
        )
        return result.exitCode == 0
    }
}

// MARK: - Apple Reminders

/// Owns the one `EKEventStore`. Access is asked for on first use (never at launch), with
/// `requestFullAccessToReminders`.
@MainActor
final class EzraRemindersAccess {
    private let eventStore = EKEventStore()

    /// The state the settings tab shows next to "reminders".
    static func isAccessGranted() -> Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    private func ensureAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await eventStore.requestFullAccessToReminders()) ?? false
        default:
            return false
        }
    }

    func createReminder(_ request: EzraReminderRequest) async -> EzraReminderCreateOutcome {
        guard await ensureAccess() else { return .accessIsOff }
        guard let defaultCalendar = eventStore.defaultCalendarForNewReminders() else { return .failed }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = defaultCalendar
        reminder.title = request.title
        reminder.notes = request.notes
        if let due = request.due {
            // The due time is a local date and time; an alarm at that moment makes it notify.
            reminder.dueDateComponents = DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone.current,
                year: due.year, month: due.month, day: due.day, hour: due.hour, minute: due.minute
            )
            reminder.addAlarm(EKAlarm(absoluteDate: due.date))
        }
        do {
            try eventStore.save(reminder, commit: true)
            return .created(identifier: reminder.calendarItemIdentifier)
        } catch {
            return .failed
        }
    }

    func removeReminder(withIdentifier identifier: String) async -> Bool {
        guard await ensureAccess(),
              let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return false
        }
        do {
            try eventStore.remove(reminder, commit: true)
            return true
        } catch {
            return false
        }
    }

    func listReminders(range: EzraReminderRange) async -> EzraReminderListOutcome {
        guard await ensureAccess() else { return .accessIsOff }

        let now = Date()
        let calendar = Calendar.current
        let predicate: NSPredicate
        switch range {
        case .today:
            // Due today or overdue: everything incomplete due before tomorrow starts.
            let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: startOfTomorrow, calendars: nil)
        case .upcoming:
            let endOfRange = calendar.date(byAdding: .day, value: EzraActionLimits.upcomingReminderDays, to: now) ?? now
            predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: now, ending: endOfRange, calendars: nil)
        }

        let summaries: [EzraReminderSummary] = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { @Sendable reminders in
                // Only plain values leave this callback, which runs on a queue of EventKit's.
                let summaries = (reminders ?? []).map { reminder in
                    EzraReminderSummary(
                        title: reminder.title ?? "",
                        dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    )
                }
                continuation.resume(returning: summaries)
            }
        }
        return .reminders(summaries)
    }
}
