import Foundation

// Round 21 (explaining on screen): step-by-step walkthroughs, one look per step (Sam's decision 8).
// "walk me through pushing this branch" gets step one: the reply starts with [STEP:1 of n], says the
// step in one or two sentences with its marks, and lists the plan as [PLAN:k:text] lines. The user
// then says "next", "back", "repeat" or "stop"; each step is a new turn with a fresh screenshot, and
// the per-turn prompt says which step to give. Everything here is pure: the tags, the state, the
// words that steer it and the prompt text. The app (`CompanionManager`) owns the one state there is.

// MARK: - The words that steer a walkthrough

/// What the user said to a walkthrough in progress.
nonisolated enum EzraWalkthroughUserWord: String, CaseIterable, Equatable, Sendable {
    case next
    case back
    case repeatStep = "repeat"
    case stop

    /// The transcript a step turn sends to the model in place of the user's own words, so the model's
    /// history reads naturally and every way of saying "next" reads the same. nil for "stop", which
    /// never reaches the model.
    var stepTurnTranscript: String? {
        switch self {
        case .next: return "next step please"
        case .back: return "go back a step please"
        case .repeatStep: return "repeat that step please"
        case .stop: return nil
        }
    }
}

/// The exact transcripts that steer a walkthrough. Only these, whole, after the ends are trimmed and
/// inner punctuation removed ("Okay, next." is "okay next"); anything longer ("next, and what does
/// staged mean") is an ordinary question. The step turns' own transcripts are in the lists too, so
/// typing what Ezra sends ("next step please") means the same. "next one", "go to the next step"
/// and "previous one" were added after the round 21 tester's live run, where people said them.
/// ("go to the next step" starts like a quick command, "go to <app>", so it is first offered to the
/// quick commands; "the" never names an app there, so it comes back here unchanged.)
nonisolated enum EzraWalkthroughWords {
    static let nextPhrases: Set<String> = [
        "next", "ok next", "okay next", "next step", "next step please", "next please", "done", "go on", "continue",
        "next one", "go to the next step",
    ]
    static let backPhrases: Set<String> = [
        "back", "go back", "previous", "previous step", "go back a step", "go back a step please", "previous one",
    ]
    static let repeatPhrases: Set<String> = [
        "repeat", "again", "say that again", "repeat that", "repeat that step", "repeat that step please",
    ]
    static let stopPhrases: Set<String> = ["stop"]

    /// The transcript reduced to lowercase words: curly apostrophes made straight, every character
    /// that is not a letter, a digit or an apostrophe made a space, and runs of spaces made one.
    static func normalizedWords(_ transcript: String) -> String {
        let straightenedText = EzraChangeConfirmationPhrases.normalized(transcript)
        let wordCharacters = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'"))
        return straightenedText
            .components(separatedBy: wordCharacters.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func userWord(forTranscript transcript: String) -> EzraWalkthroughUserWord? {
        let words = normalizedWords(transcript)
        if nextPhrases.contains(words) { return .next }
        if backPhrases.contains(words) { return .back }
        if repeatPhrases.contains(words) { return .repeatStep }
        if stopPhrases.contains(words) { return .stop }
        return nil
    }
}

// MARK: - The tags of a reply

/// The step tag and the plan lines of one reply.
nonisolated struct EzraWalkthroughReplyTags: Equatable {
    /// k of the first valid `[STEP:k of n]`, nil when the reply has none.
    let stepNumber: Int?
    /// n of the same tag.
    let stepCount: Int?
    /// The plan lines by step number, from valid `[PLAN:k:text]` tags (the first one for each k).
    let planTextsByStepNumber: [Int: String]

    static let none = EzraWalkthroughReplyTags(stepNumber: nil, stepCount: nil, planTextsByStepNumber: [:])

    /// The plan lines in step order.
    var planTexts: [String] {
        planTextsByStepNumber.keys.sorted().compactMap { planTextsByStepNumber[$0] }
    }

    var isEmpty: Bool {
        stepNumber == nil && planTextsByStepNumber.isEmpty
    }
}

/// Reads `[STEP:k of n]` and `[PLAN:k:text]` (any case, spaces allowed around the pieces). A tag
/// with numbers outside 1 ≤ k ≤ n ≤ 12, or a plan line with no text, is dropped here; the reply
/// parser removes every `[STEP:...]` and `[PLAN:...]` from the spoken text whatever it holds.
nonisolated enum EzraWalkthroughTags {
    static let maximumPlanTextCharacterCount = 60

    private static let stepTagPattern = #"\[\s*STEP\s*:([^\[\]]*)\]"#
    private static let planTagPattern = #"\[\s*PLAN\s*:([^\[\]]*)\]"#
    private static let stepBodyPattern = #"^\s*(\d{1,3})\s*of\s*(\d{1,3})\s*$"#

    static func parse(rawReplyText: String) -> EzraWalkthroughReplyTags {
        var stepNumber: Int?
        var stepCount: Int?
        for stepTagBody in tagBodies(matching: stepTagPattern, in: rawReplyText) {
            guard let stepNumbers = stepNumbers(fromTagBody: stepTagBody) else { continue }
            // One step tag per reply: the first valid one counts.
            stepNumber = stepNumbers.stepNumber
            stepCount = stepNumbers.stepCount
            break
        }

        var planTextsByStepNumber: [Int: String] = [:]
        for planTagBody in tagBodies(matching: planTagPattern, in: rawReplyText) {
            guard let firstColonIndex = planTagBody.firstIndex(of: ":"),
                  let planStepNumber = Int(planTagBody[..<firstColonIndex].trimmingCharacters(in: .whitespacesAndNewlines)),
                  planStepNumber >= 1, planStepNumber <= EzraWalkthroughState.maximumStepCount,
                  planTextsByStepNumber[planStepNumber] == nil else {
                continue
            }
            let planText = singleLineText(String(planTagBody[planTagBody.index(after: firstColonIndex)...]), cutToCharacterCount: maximumPlanTextCharacterCount)
            if !planText.isEmpty {
                planTextsByStepNumber[planStepNumber] = planText
            }
        }
        return EzraWalkthroughReplyTags(stepNumber: stepNumber, stepCount: stepCount, planTextsByStepNumber: planTextsByStepNumber)
    }

    /// "2 of 5" as (2, 5), only when 1 ≤ k ≤ n ≤ 12.
    static func stepNumbers(fromTagBody tagBody: String) -> (stepNumber: Int, stepCount: Int)? {
        guard let bodyRegex = try? NSRegularExpression(pattern: stepBodyPattern, options: [.caseInsensitive]),
              let bodyMatch = bodyRegex.firstMatch(in: tagBody, range: NSRange(tagBody.startIndex..., in: tagBody)),
              let stepNumberRange = Range(bodyMatch.range(at: 1), in: tagBody),
              let stepCountRange = Range(bodyMatch.range(at: 2), in: tagBody),
              let stepNumber = Int(tagBody[stepNumberRange]),
              let stepCount = Int(tagBody[stepCountRange]),
              stepNumber >= 1, stepNumber <= stepCount, stepCount <= EzraWalkthroughState.maximumStepCount else {
            return nil
        }
        return (stepNumber, stepCount)
    }

    static func canonicalStepTagText(stepNumber: Int, stepCount: Int) -> String {
        "[STEP:\(stepNumber) of \(stepCount)]"
    }

    static func canonicalPlanTagText(stepNumber: Int, planText: String) -> String {
        "[PLAN:\(stepNumber):\(planText)]"
    }

    /// What goes into the conversation history for a reply with walkthrough tags: the step tag first,
    /// then the history text the reply already has (its words, draw tags and memory tags), then the
    /// plan lines, in step order and canonical form, so later steps stay consistent with the plan. A
    /// reply with no valid walkthrough tag returns the history text untouched.
    static func historyText(appending replyTags: EzraWalkthroughReplyTags, to historyText: String) -> String {
        guard !replyTags.isEmpty else {
            return historyText
        }
        var historyPieces: [String] = []
        if let stepNumber = replyTags.stepNumber, let stepCount = replyTags.stepCount {
            historyPieces.append(canonicalStepTagText(stepNumber: stepNumber, stepCount: stepCount))
        }
        historyPieces.append(historyText)
        for planStepNumber in replyTags.planTextsByStepNumber.keys.sorted() {
            if let planText = replyTags.planTextsByStepNumber[planStepNumber] {
                historyPieces.append(canonicalPlanTagText(stepNumber: planStepNumber, planText: planText))
            }
        }
        return historyPieces
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func tagBodies(matching pattern: String, in text: String) -> [String] {
        guard let tagRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        return tagRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { tagMatch in
            Range(tagMatch.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func singleLineText(_ text: String, cutToCharacterCount maximumCharacterCount: Int) -> String {
        let singleLineText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(singleLineText.prefix(maximumCharacterCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The walkthrough in progress

/// What a step word asks of the walkthrough.
nonisolated enum EzraWalkthroughAdvance: Equatable {
    /// Ask the model for this step (the next one, the one before, or the same one again).
    case giveStep(stepNumber: Int)
    /// "next" after the last step: no model call; Ezra says "that was the last step." and the
    /// walkthrough ends.
    case finished
    /// "stop": the walkthrough ends.
    case stopped
}

/// A step turn: the step word the user said and the step the model is asked for.
nonisolated struct EzraWalkthroughStepRequest: Equatable, Sendable {
    let userWord: EzraWalkthroughUserWord
    let requestedStepNumber: Int
}

/// What a finished reply did to the walkthrough (see `EzraWalkthroughState.stepTaken`): the
/// walkthrough to keep from now on and the step the reply gave, for the metrics line and for the
/// follow-up window after it.
nonisolated struct EzraWalkthroughStepTaken: Equatable {
    let walkthroughAfterReply: EzraWalkthroughState
    let stepNumber: Int
    let stepCount: Int
    /// True when the reply began a walkthrough (or replaced the one in progress with a new plan).
    let beganAWalkthrough: Bool
}

/// The one walkthrough in progress. A value: the app keeps it, and replaces it with the state after a
/// step the model gave.
nonisolated struct EzraWalkthroughState: Equatable {
    /// More steps than this is not a walkthrough but a manual.
    static let maximumStepCount = 12
    /// The follow-up window right after a reply that gave a step waits this long for "next": the user
    /// is doing the step, which takes longer than answering. Every other window keeps the usual six
    /// seconds (see `followUpWindowGiveUpSeconds`).
    static let followUpWindowSeconds: TimeInterval = 45
    /// Ten minutes without a step ends a walkthrough: the user has moved on.
    static let staleAfterSeconds: TimeInterval = 600
    /// Said when the user says "next" after the last step (no model call).
    static let lastStepSentence = "that was the last step."
    /// Said when the user types "stop" or says it with the ask keys (no model call; in the follow-up
    /// window "stop" closes the window silently, like every end phrase).
    static let stoppedSentence = "okay, i stopped the walkthrough."

    let stepCount: Int
    /// One line per step, in order. A step the plan did not name is "step k".
    let planTexts: [String]
    /// The step the user was last given.
    let currentStep: Int
    let startedAt: Date
    /// When the last step was given.
    let lastStepAt: Date

    /// A walkthrough begins with a reply that carries `[STEP:1 of n]` (1 ≤ n ≤ 12). Its plan lines
    /// name the steps; with fewer plan lines, the missing ones are "step k". nil for any other reply.
    static func beginning(fromReplyTags replyTags: EzraWalkthroughReplyTags, now: Date) -> EzraWalkthroughState? {
        guard replyTags.stepNumber == 1, let stepCount = replyTags.stepCount, stepCount >= 1, stepCount <= maximumStepCount else {
            return nil
        }
        let planTexts = (1...stepCount).map { stepNumber in
            replyTags.planTextsByStepNumber[stepNumber] ?? "step \(stepNumber)"
        }
        return EzraWalkthroughState(stepCount: stepCount, planTexts: planTexts, currentStep: 1, startedAt: now, lastStepAt: now)
    }

    /// What the user's word asks for. The state itself moves only when a reply carries the step that
    /// was asked for (`recordingStepGiven`), so a reply without it leaves "next" asking again.
    func advancing(byUserWord userWord: EzraWalkthroughUserWord) -> EzraWalkthroughAdvance {
        switch userWord {
        case .next:
            return currentStep >= stepCount ? .finished : .giveStep(stepNumber: currentStep + 1)
        case .back:
            return .giveStep(stepNumber: max(1, currentStep - 1))
        case .repeatStep:
            return .giveStep(stepNumber: currentStep)
        case .stop:
            return .stopped
        }
    }

    /// The state once the user has been given `stepNumber`.
    func recordingStepGiven(_ stepNumber: Int, at now: Date) -> EzraWalkthroughState {
        EzraWalkthroughState(
            stepCount: stepCount,
            planTexts: planTexts,
            currentStep: max(1, min(stepCount, stepNumber)),
            startedAt: startedAt,
            lastStepAt: now
        )
    }

    func isStale(now: Date) -> Bool {
        now.timeIntervalSince(lastStepAt) >= Self.staleAfterSeconds
    }

    /// How long a follow-up window waits for speech (round 21 review): 45 seconds only right after a
    /// reply that gave a step of the walkthrough still in progress, because the user is now doing
    /// that step. Every other window, during a walkthrough or not, keeps the usual six seconds, so a
    /// room that keeps talking cannot hold the microphone open for long.
    static func followUpWindowGiveUpSeconds(afterAReplyThatTookAStep replyTookAStep: Bool, walkthroughIsInProgress: Bool) -> TimeInterval {
        replyTookAStep && walkthroughIsInProgress ? followUpWindowSeconds : EzraFollowUpListeningConstants.noSpeechGiveUpSeconds
    }

    /// Applies a finished reply's walkthrough tags. Returns nil when the reply took no step: the
    /// walkthrough then stays exactly as it is (its ten minutes are not started again) and the next
    /// follow-up window is the usual one. `walkthroughNow` is the walkthrough as the reply ends,
    /// which a new chat or a stop may have changed since the turn started.
    ///
    /// - A step turn (`stepRequest` set: the user said "next", "back" or "repeat") takes a step only
    ///   when its reply carries exactly the step it asked for, and only while the walkthrough is still
    ///   the one the turn started with. A "repeat" gives the same step again and counts as a step.
    /// - On any other turn a reply with `[STEP:1 of n]` and a plan, or with another step count,
    ///   begins a walkthrough (replacing the one in progress), and a reply that gives another step of
    ///   the walkthrough in progress moves it there (the user said "ok, what now?" instead of
    ///   "next"). Round 21 review: a reply that only repeats the step the user is on, or the same plan
    ///   from step 1 while the user is on step 1, takes no step, so answers that merely mention an
    ///   abandoned walkthrough cannot keep it alive.
    static func stepTaken(
        byReplyTags replyTags: EzraWalkthroughReplyTags,
        stepRequest: EzraWalkthroughStepRequest?,
        walkthroughAtTurnStart: EzraWalkthroughState?,
        walkthroughNow: EzraWalkthroughState?,
        now: Date
    ) -> EzraWalkthroughStepTaken? {
        guard let replyStepNumber = replyTags.stepNumber, let replyStepCount = replyTags.stepCount else {
            return nil
        }
        if let stepRequest {
            guard let walkthroughAtTurnStart,
                  walkthroughNow == walkthroughAtTurnStart,
                  replyStepNumber == stepRequest.requestedStepNumber else {
                return nil
            }
            return EzraWalkthroughStepTaken(
                walkthroughAfterReply: walkthroughAtTurnStart.recordingStepGiven(replyStepNumber, at: now),
                stepNumber: replyStepNumber,
                stepCount: walkthroughAtTurnStart.stepCount,
                beganAWalkthrough: false
            )
        }
        let replyBeginsANewWalkthrough = walkthroughAtTurnStart == nil
            || !replyTags.planTextsByStepNumber.isEmpty
            || replyStepCount != walkthroughAtTurnStart?.stepCount
        if replyBeginsANewWalkthrough, let begunWalkthrough = beginning(fromReplyTags: replyTags, now: now) {
            let replyRepeatsTheWalkthroughTheUserIsOnStepOneOf = walkthroughAtTurnStart.map { walkthroughAtTurnStart in
                walkthroughNow == walkthroughAtTurnStart
                    && walkthroughAtTurnStart.currentStep == 1
                    && walkthroughAtTurnStart.stepCount == begunWalkthrough.stepCount
                    && walkthroughAtTurnStart.planTexts == begunWalkthrough.planTexts
            } ?? false
            if replyRepeatsTheWalkthroughTheUserIsOnStepOneOf {
                return nil
            }
            return EzraWalkthroughStepTaken(
                walkthroughAfterReply: begunWalkthrough,
                stepNumber: 1,
                stepCount: begunWalkthrough.stepCount,
                beganAWalkthrough: true
            )
        }
        if let walkthroughAtTurnStart,
           walkthroughNow == walkthroughAtTurnStart,
           replyStepCount == walkthroughAtTurnStart.stepCount,
           replyStepNumber != walkthroughAtTurnStart.currentStep {
            return EzraWalkthroughStepTaken(
                walkthroughAfterReply: walkthroughAtTurnStart.recordingStepGiven(replyStepNumber, at: now),
                stepNumber: replyStepNumber,
                stepCount: replyStepCount,
                beganAWalkthrough: false
            )
        }
        return nil
    }

    /// The per-turn prompt section while a walkthrough is in progress (after "marks on screen",
    /// before the profile). `userWord` is the step word of a step turn, or nil when the user asked
    /// something else: then the section says which step is current and not to move on.
    func promptSectionText(forUserWord userWord: EzraWalkthroughUserWord?) -> String {
        let planLineText = planTexts.enumerated().map { stepIndex, planText in
            "\(stepIndex + 1). \(planTextWithoutClosingPunctuation(planText))"
        }.joined(separator: "; ")
        var sectionLines = [
            "walkthrough in progress (the user is following your steps one at a time):",
            "- plan: \(planLineText).",
        ]
        switch userWord.map({ advancing(byUserWord: $0) }) {
        case .giveStep(let stepNumber)?:
            let stepTagText = EzraWalkthroughTags.canonicalStepTagText(stepNumber: stepNumber, stepCount: stepCount)
            switch userWord {
            case .next?:
                sectionLines.append("- step \(currentStep) is done. the user said \"next\": give step \(stepNumber) now, starting with \(stepTagText).")
            case .back?:
                sectionLines.append("- the user said \"back\": give step \(stepNumber) again, starting with \(stepTagText).")
            default:
                sectionLines.append("- the user said \"repeat\": give step \(stepNumber) again, starting with \(stepTagText).")
            }
        case .finished?, .stopped?, nil:
            sectionLines.append("- the user is on step \(currentStep) of \(stepCount).")
            sectionLines.append("- the user asked something else; answer it in one or two sentences and do not give the next step unless they say next.")
            // Round 21 review: the line above read as a ban on any walkthrough, so a new one was
            // discouraged while an old one was in progress.
            sectionLines.append("- if they ask for a different walkthrough, start it fresh with [STEP:1 of n] and its plan.")
        }
        return sectionLines.joined(separator: "\n")
    }

    /// A plan line written with a full stop would end "commit.;" in the plan list.
    private func planTextWithoutClosingPunctuation(_ planText: String) -> String {
        var trimmedPlanText = planText
        while let lastCharacter = trimmedPlanText.last, ".;,".contains(lastCharacter) {
            trimmedPlanText.removeLast()
        }
        return trimmedPlanText
    }
}

/// What the prompt needs about the walkthrough on this turn.
nonisolated struct EzraWalkthroughPromptContext: Equatable {
    let state: EzraWalkthroughState
    /// The step word of a step turn, or nil when the user asked something else.
    let userWord: EzraWalkthroughUserWord?
}
