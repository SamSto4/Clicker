//
//  ClickyMemoryCompactionController.swift
//  leanring-buddy
//
//  Compacts a chat into zero to three short memory lines when the chat ends, without asking
//  (round 16). A chat ends after ten quiet minutes (a timer), when a new chat starts, and, best
//  effort, when the app quits. The work is a single small request to the Worker's /chat route
//  (`ClickyMemoryCompactionRunner`); this class only decides when to run it, and records the
//  outcome on the chat.
//
//  It never blocks a turn: every request runs on a background task, and a failure only leaves the
//  chat pending (its covered count does not move) for the next trigger to find again.
//
//  Privacy: only the chats' stored, redacted text is sent, never a screenshot; the metrics line
//  holds numbers and fixed identifiers only; nothing is printed except those numbers.
//

import Foundation

@MainActor
final class ClickyMemoryCompactionController {
    private let chatSession: ClickyChatSession
    private let memoryStore: ClickyMemoryStore
    private let client: ClickyMemoryCompactionClient
    private let systemPromptText: String
    private let metricsLogFileURL: URL
    private let idleSecondsBeforeCompacting: TimeInterval
    private let secondsToWaitBeforeRetryAfterLaunch: TimeInterval
    /// Reads the profile's facts once per request, off the main thread: they go into the request's
    /// `<known>` list and the validator checks the answer against them (the profile is in ~/Documents).
    private let loadProfileFactTexts: @Sendable () -> [String]
    /// Makes the one request. Nil means the real client; a check that must never reach the network
    /// passes its own.
    private let requestSender: (@Sendable (Data, TimeInterval) async -> ClickyMemoryModelResponse)?
    /// False in the panel self test, which promises that no model is asked and nothing is sent to
    /// the network, and whenever no memories folder is known.
    private let isEnabled: Bool

    /// Restarted after every recorded exchange; when it runs out the chat has been quiet for ten
    /// minutes and has ended.
    private var idleCompactionTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    /// A trigger that arrived while a run was under way. The run is repeated once when it ends, so
    /// a chat that ended meanwhile is not left until the next trigger.
    private var triggerRequestedDuringRun: ClickyMemoryCompactionTrigger?

    /// Five seconds past the chat boundary: a timer that fires at exactly ten minutes would see the
    /// chat as not yet ended (the boundary is "more than ten minutes").
    nonisolated static let defaultIdleSecondsBeforeCompacting: TimeInterval = ClickyChatBoundary.newChatAfterSecondsWithoutMessage + 5
    /// The retry after a launch waits a little, so it never competes with the app starting up and
    /// the chat files have been read by then.
    nonisolated static let defaultSecondsToWaitBeforeRetryAfterLaunch: TimeInterval = 20
    /// One run looks at this many chats and, for each, this many batches. A longer backlog is worked
    /// through by the next triggers.
    private static let maximumChatsPerRun = 5
    private static let maximumBatchesPerChatPerRun = 3

    init(
        chatSession: ClickyChatSession,
        memoryStore: ClickyMemoryStore,
        client: ClickyMemoryCompactionClient,
        promptsDirectoryURL: URL?,
        metricsLogFileURL: URL = ClickyMemoryCompactionMetricsLog.defaultLogFileURL,
        isEnabled: Bool,
        idleSecondsBeforeCompacting: TimeInterval = ClickyMemoryCompactionController.defaultIdleSecondsBeforeCompacting,
        secondsToWaitBeforeRetryAfterLaunch: TimeInterval = ClickyMemoryCompactionController.defaultSecondsToWaitBeforeRetryAfterLaunch,
        // The copy of the profile the app already keeps in memory is used when there is one: ~/Documents
        // is iCloud-backed and has stalled for seconds, which on the quit path would eat the whole time
        // limit. A slightly old copy is fine for telling whether a line repeats the profile.
        loadProfileFactTexts: @escaping @Sendable () -> [String] = {
            ClickyProfileStore(profileDirectoryURL: ClickyProfileStore.defaultProfileDirectoryURL).loadFactTexts(preferringCachedFile: true)
        },
        requestSender: (@Sendable (Data, TimeInterval) async -> ClickyMemoryModelResponse)? = nil
    ) {
        self.chatSession = chatSession
        self.memoryStore = memoryStore
        self.client = client
        self.systemPromptText = ClickyMemoryCompaction.loadSystemPromptText(promptsDirectoryURL: promptsDirectoryURL)
        self.metricsLogFileURL = metricsLogFileURL
        self.isEnabled = isEnabled
        self.idleSecondsBeforeCompacting = idleSecondsBeforeCompacting
        self.secondsToWaitBeforeRetryAfterLaunch = secondsToWaitBeforeRetryAfterLaunch
        self.loadProfileFactTexts = loadProfileFactTexts
        self.requestSender = requestSender
    }

    /// Whether a request can be made at all: the real client needs a Worker address; a sender passed
    /// in (by a check) always can.
    private var canMakeRequests: Bool {
        requestSender != nil || client.isConfigured
    }

    /// The function that makes the one request, with the time limit it is given.
    private var sendRequestWithTimeLimit: @Sendable (Data, TimeInterval) async -> ClickyMemoryModelResponse {
        if let requestSender {
            return requestSender
        }
        return Self.makeSender(using: client)
    }

    /// Made in a nonisolated function on purpose: the quit path waits for this request on the main
    /// thread, so the closure must never need the main actor to run (it would wait for a thread that
    /// is waiting for it).
    private nonisolated static func makeSender(using client: ClickyMemoryCompactionClient) -> @Sendable (Data, TimeInterval) async -> ClickyMemoryModelResponse {
        return { requestBodyData, timeoutSeconds in
            await client.requestCompaction(withBodyData: requestBodyData, timeoutSeconds: timeoutSeconds)
        }
    }

    // MARK: - Triggers

    /// Called after each exchange is recorded in a chat. Restarts the ten-minute countdown; when the
    /// exchange opened a new chat, the chat before it has just ended and is compacted now.
    func exchangeWasRecorded(startedANewChat: Bool) {
        guard isEnabled else { return }
        scheduleCompactionAfterIdle()
        if startedANewChat {
            compactEndedChats(trigger: .newChat)
        }
    }

    /// Called when the user picks "new chat": the chat they were in has ended.
    func userStartedANewChat() {
        compactEndedChats(trigger: .newChat)
    }

    /// Called once at launch: a chat whose compaction was interrupted last time (offline, quit
    /// before it finished) is picked up again shortly after the app is up.
    func scheduleRetryAfterLaunch() {
        guard isEnabled else { return }
        let secondsToWait = secondsToWaitBeforeRetryAfterLaunch
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secondsToWait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.compactEndedChats(trigger: .launch)
        }
    }

    private func scheduleCompactionAfterIdle() {
        idleCompactionTask?.cancel()
        let secondsToWait = idleSecondsBeforeCompacting
        idleCompactionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secondsToWait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.compactEndedChats(trigger: .idleTimer)
        }
    }

    // MARK: - A run

    /// Compacts every chat that has ended and has exchanges not yet covered. One run at a time: a
    /// trigger during a run is remembered and repeats the run once the first has finished.
    func compactEndedChats(trigger: ClickyMemoryCompactionTrigger) {
        guard isEnabled, canMakeRequests else { return }
        guard runTask == nil else {
            triggerRequestedDuringRun = trigger
            return
        }
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.compactEndedChatsOneAfterAnother(trigger: trigger)
            self.runTask = nil
            if let triggerRequestedDuringRun = self.triggerRequestedDuringRun {
                self.triggerRequestedDuringRun = nil
                self.compactEndedChats(trigger: triggerRequestedDuringRun)
            }
        }
    }

    private func compactEndedChatsOneAfterAnother(trigger: ClickyMemoryCompactionTrigger) async {
        let chatsDueForCompaction = chatSession.chatsEndedAndAwaitingMemoryCompaction(
            at: Date(),
            treatingActiveChatAsEnded: false
        )
        for chatDueForCompaction in chatsDueForCompaction.prefix(Self.maximumChatsPerRun) {
            var chatToCompact = chatDueForCompaction
            batchLoop: for _ in 0..<Self.maximumBatchesPerChatPerRun {
                guard !Task.isCancelled else { return }
                let batchResult = await compactNextBatchInBackground(of: chatToCompact, trigger: trigger)
                recordMetrics(of: batchResult)

                switch batchResult.outcome {
                case .nothingNew:
                    break batchLoop
                case .skippedAsTooShort(let coveringExchangeCount), .completed(let coveringExchangeCount, _):
                    chatSession.markMemoryCompacted(chatID: chatToCompact.id, coveredExchangeCount: coveringExchangeCount)
                    // The next batch starts from what is left, but only while the chat is still due: if
                    // the user went back into it meanwhile it has not ended, and it is left alone.
                    let chatsStillDue = chatSession.chatsEndedAndAwaitingMemoryCompaction(at: Date(), treatingActiveChatAsEnded: false)
                    guard let chatStillDue = chatsStillDue.first(where: { $0.id == chatToCompact.id }) else {
                        break batchLoop
                    }
                    chatToCompact = chatStillDue
                case .failed:
                    // Probably offline. The chats stay pending; the next trigger tries again.
                    return
                }
            }
        }
    }

    /// The request and the work around it run off the main thread, the profile read included (it is
    /// in ~/Documents, which can be slow).
    private func compactNextBatchInBackground(
        of chat: ClickyChat,
        trigger: ClickyMemoryCompactionTrigger
    ) async -> ClickyMemoryCompactionBatchResult {
        let memoryStore = self.memoryStore
        let systemPromptText = self.systemPromptText
        let loadProfileFactTexts = self.loadProfileFactTexts
        let sendRequestWithTimeLimit = self.sendRequestWithTimeLimit
        return await Task.detached(priority: .utility) {
            await ClickyMemoryCompactionRunner.compactNextBatch(
                of: chat,
                trigger: trigger,
                systemPromptText: systemPromptText,
                memoryStore: memoryStore,
                loadProfileFactTexts: loadProfileFactTexts,
                sendRequestBody: { requestBodyData in
                    await sendRequestWithTimeLimit(requestBodyData, ClickyMemoryCompaction.requestTimeoutSeconds)
                }
            )
        }.value
    }

    private func recordMetrics(of batchResult: ClickyMemoryCompactionBatchResult) {
        guard let metrics = batchResult.metrics else { return }
        print(metrics.makeConsoleSummaryLine())
        ClickyMemoryCompactionMetricsLog.recordInBackground(metrics, to: metricsLogFileURL)
    }

    // MARK: - Quitting

    /// Best effort while the app quits: compacts the chat that was last in use (the active chat
    /// counts as ended now) with one request and a short time limit, then waits for it. If the
    /// request does not finish in time nothing is lost: the chat stays pending and the next launch
    /// retries it. Blocks the main thread for at most about 3.5 seconds, and only when a chat has
    /// something new in it.
    func compactBeforeQuitting() {
        guard isEnabled, canMakeRequests else { return }
        idleCompactionTask?.cancel()
        // The newest chat that is due: the one the user was just in.
        guard let chatToCompact = chatSession.chatsEndedAndAwaitingMemoryCompaction(
            at: Date(),
            treatingActiveChatAsEnded: true
        ).last else {
            return
        }

        let memoryStore = self.memoryStore
        let systemPromptText = self.systemPromptText
        let loadProfileFactTexts = self.loadProfileFactTexts
        let sendRequestWithTimeLimit = self.sendRequestWithTimeLimit
        let resultBox = ClickyQuitCompactionResultBox()
        let finishedSemaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let batchResult = await ClickyMemoryCompactionRunner.compactNextBatch(
                of: chatToCompact,
                trigger: .quit,
                systemPromptText: systemPromptText,
                memoryStore: memoryStore,
                loadProfileFactTexts: loadProfileFactTexts,
                sendRequestBody: { requestBodyData in
                    await sendRequestWithTimeLimit(requestBodyData, ClickyMemoryCompaction.requestTimeoutSecondsWhenQuitting)
                }
            )
            resultBox.store(batchResult)
            finishedSemaphore.signal()
        }
        let waitSeconds = ClickyMemoryCompaction.requestTimeoutSecondsWhenQuitting + 0.5
        guard finishedSemaphore.wait(timeout: .now() + waitSeconds) == .success,
              let batchResult = resultBox.storedResult else {
            return
        }

        if let metrics = batchResult.metrics {
            print(metrics.makeConsoleSummaryLine())
            ClickyMemoryCompactionMetricsLog.record(metrics, to: metricsLogFileURL)
        }
        switch batchResult.outcome {
        case .skippedAsTooShort(let coveringExchangeCount), .completed(let coveringExchangeCount, _):
            chatSession.markMemoryCompacted(chatID: chatToCompact.id, coveredExchangeCount: coveringExchangeCount)
            chatSession.waitForPendingWritesBeforeQuitting()
        case .nothingNew, .failed:
            break
        }
    }
}

/// Carries the result of the quit-time compaction from its background task to the main thread that
/// is waiting for it. The task stores the result before it signals the semaphore, so the main thread
/// reads it only afterwards.
private nonisolated final class ClickyQuitCompactionResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ClickyMemoryCompactionBatchResult?

    func store(_ batchResult: ClickyMemoryCompactionBatchResult) {
        lock.lock()
        result = batchResult
        lock.unlock()
    }

    var storedResult: ClickyMemoryCompactionBatchResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
