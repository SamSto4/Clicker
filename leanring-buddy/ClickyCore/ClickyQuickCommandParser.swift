import Foundation

// Round 19 (Jarvis tuning), candidate B: quick commands. A few plain commands ("open safari", "set a
// timer for 10 minutes for the pasta", "stop the timer") are understood on this Mac and carried out with
// no screenshot, no prompt and no model call: about 0.8 s and nothing spent, instead of 4.7 s and
// $0.0117. Sam's decision of 14 Nov 2026: built, on by default. A wrong match is a wrong action, so the
// grammar is closed and every doubt goes to the model: the whole transcript must match one form
// exactly, the shared word rules (`ClickySimpleCommandWords`, amendment 1) must pass, an app must be
// named exactly or by a known alias (amendment 3: never by a prefix; "open google" must not open Chrome),
// and a timer label must name exactly one running timer. Foundation only.

/// What a quick command does.
nonisolated enum ClickyQuickCommand: Equatable, Sendable {
    case openApp(ClickyInstalledApplication)
    case setTimer(durationSeconds: Int, label: String?)
    /// `reference` is the timer's id, so the executor stops exactly the timer that was named.
    case cancelTimer(reference: String)

    /// The action tool call that carries it out, through the action session, so the limits, the
    /// result text and the `[done: ...]` line are the ones a model turn gets.
    var toolCall: (toolName: String, input: [String: Any]) {
        switch self {
        case .openApp(let application):
            return (ClickyActionToolName.openApp.rawValue, ["name": application.displayName])
        case .setTimer(let durationSeconds, let label):
            var input: [String: Any] = ["duration_seconds": durationSeconds]
            if let label { input["label"] = label }
            return (ClickyActionToolName.setTimer.rawValue, input)
        case .cancelTimer(let reference):
            return (ClickyActionToolName.cancelTimer.rawValue, ["timer": reference])
        }
    }
}

nonisolated enum ClickyQuickCommandParser {
    /// The words that open an app.
    static let openingVerbs = ["open", "launch", "switch to", "go to"]
    /// An app named by fewer letters than this is never a quick command ("open x").
    static let minimumAppNameLetters = 3
    /// Words that, as the app or its first word, mean the user is not naming an app ("open it",
    /// "open the settings page", "open my notes", "open a new tab").
    static let wordsThatDoNotNameAnApp: Set<String> = [
        "it", "that", "this", "these", "those", "them", "the", "my", "a", "an", "your", "our", "his", "her",
        "their", "its", "some", "any", "one", "something", "anything", "everything", "me", "us", "new", "another",
    ]
    /// Number words up to sixty; with "a" and "an" for one ("a minute", "an hour").
    static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60,
    ]
    static let unitSeconds: [String: Int] = [
        "second": 1, "seconds": 1, "minute": 60, "minutes": 60, "hour": 3600, "hours": 3600,
    ]

    /// The quick command the transcript is, or nil when it is not exactly one (then the model gets it).
    static func parse(
        transcript: String,
        installedApplications: [ClickyInstalledApplication],
        runningTimers: [ClickyTimer],
        assistantName: String = ""
    ) -> ClickyQuickCommand? {
        guard let commandText = ClickySimpleCommandWords.plainCommandText(transcript, assistantName: assistantName) else {
            return nil
        }
        if let application = applicationToOpen(commandText: commandText, installedApplications: installedApplications) {
            return .openApp(application)
        }
        if let timer = timerToSet(commandText: commandText) {
            return .setTimer(durationSeconds: timer.durationSeconds, label: timer.label)
        }
        if let reference = timerToCancel(commandText: commandText, runningTimers: runningTimers) {
            return .cancelTimer(reference: reference)
        }
        return nil
    }

    /// A cheap first look, before the installed apps are listed: could this be a quick command at all?
    /// False means the turn goes straight to the model.
    static func couldBeAQuickCommand(_ transcript: String, assistantName: String = "") -> Bool {
        guard let commandText = ClickySimpleCommandWords.plainCommandText(transcript, assistantName: assistantName) else {
            return false
        }
        let firstWords = ["open ", "launch ", "switch to ", "go to ", "set ", "stop the ", "cancel the ", "timer for "]
        return firstWords.contains { commandText.hasPrefix($0) } || commandText.hasSuffix(" timer") || commandText.contains(" timer for ")
    }

    // MARK: - Apps

    /// "open <app>", "launch <app>", "switch to <app>", "go to <app>", where the app is named exactly
    /// (or by a known alias) and only one installed app has that name.
    static func applicationToOpen(commandText: String, installedApplications: [ClickyInstalledApplication]) -> ClickyInstalledApplication? {
        for openingVerb in openingVerbs where commandText.hasPrefix(openingVerb + " ") {
            let requestedName = String(commandText.dropFirst(openingVerb.count + 1))
            return exactApplication(named: requestedName, installedApplications: installedApplications)
        }
        return nil
    }

    /// The one installed app with this name (case and accents ignored, without ".app" or a trailing
    /// " app"), or the app a known alias names. Never a prefix: a request that is only the start of a
    /// name, a pronoun, a determiner, or fewer than three letters names no app here.
    static func exactApplication(named rawRequestedName: String, installedApplications: [ClickyInstalledApplication]) -> ClickyInstalledApplication? {
        var requestedName = ClickyActionText.normalizedForComparison(rawRequestedName)
        if requestedName.hasSuffix(".app") {
            requestedName = String(requestedName.dropLast(4))
        }
        let requestedWords = requestedName.split(separator: " ").map(String.init)
        guard let firstWord = requestedWords.first,
              !wordsThatDoNotNameAnApp.contains(firstWord),
              requestedName.filter(\.isLetter).count >= minimumAppNameLetters else {
            return nil
        }
        var candidateNames = [requestedName]
        if requestedName.hasSuffix(" app") {
            candidateNames.append(String(requestedName.dropLast(4)))
        }
        for candidateName in candidateNames {
            if let aliasTarget = ClickyAppNameMatcher.aliases[candidateName],
               let application = onlyApplication(withNormalizedName: aliasTarget, installedApplications: installedApplications) {
                return application
            }
            if let application = onlyApplication(withNormalizedName: candidateName, installedApplications: installedApplications) {
                return application
            }
        }
        return nil
    }

    /// The installed app with exactly this name; nil for none, and for two at different places (the
    /// model then asks which).
    private static func onlyApplication(withNormalizedName normalizedName: String, installedApplications: [ClickyInstalledApplication]) -> ClickyInstalledApplication? {
        let matches = installedApplications.filter { ClickyActionText.normalizedForComparison($0.displayName) == normalizedName }
        guard let firstMatch = matches.first, Set(matches.map(\.path)).count == 1 else {
            return nil
        }
        return firstMatch
    }

    // MARK: - Setting a timer

    /// "set a timer for <duration>", "timer for <duration>", "set a <n> <unit> timer" and "<n> <unit>
    /// timer", each with an optional "for <label>" or "called <label>" after it (amendment 6: the short
    /// forms too, "set a 5 minute timer for tea"). The duration is a number (digits, or a word up to
    /// sixty, or "a"/"an" for one) and a unit (seconds, minutes, hours), or "half an hour". A duration
    /// with "and" ("an hour and a half") never gets here: the word rules send it to the model.
    static func timerToSet(commandText rawCommandText: String) -> (durationSeconds: Int, label: String?)? {
        // "5-minute" and "twenty-five" are read as "5 minute" and "twenty five".
        let commandText = ClickyActionText.collapsedToOneLine(rawCommandText.replacingOccurrences(of: "-", with: " "))
        let restAfterTheWords: String
        let durationIsAnAdjective: Bool
        if commandText.hasPrefix("set a timer for ") {
            restAfterTheWords = String(commandText.dropFirst("set a timer for ".count))
            durationIsAnAdjective = false
        } else if commandText.hasPrefix("timer for ") {
            restAfterTheWords = String(commandText.dropFirst("timer for ".count))
            durationIsAnAdjective = false
        } else if commandText.hasPrefix("set a ") {
            restAfterTheWords = String(commandText.dropFirst("set a ".count))
            durationIsAnAdjective = true
        } else {
            restAfterTheWords = commandText
            durationIsAnAdjective = true
        }

        var words = restAfterTheWords.split(separator: " ").map(String.init)
        guard let duration = leadingDuration(of: words) else {
            return nil
        }
        words.removeFirst(duration.wordCount)
        if durationIsAnAdjective {
            // "<n> minute timer ...": the word "timer" must follow the duration.
            guard words.first == "timer" else { return nil }
            words.removeFirst()
        }
        let label: String?
        if words.isEmpty {
            label = nil
        } else {
            guard let labelWord = words.first, labelWord == "for" || labelWord == "called", words.count >= 2 else {
                return nil
            }
            label = cleanedLabel(Array(words.dropFirst()))
            guard label != nil else { return nil }
        }
        guard duration.seconds >= ClickyActionLimits.minimumTimerSeconds, duration.seconds <= ClickyActionLimits.maximumTimerSeconds else {
            return nil
        }
        return (duration.seconds, label)
    }

    /// The duration the words start with and how many words it took, or nil.
    static func leadingDuration(of words: [String]) -> (seconds: Int, wordCount: Int)? {
        if words.count >= 3, words[0] == "half", words[1] == "an", words[2] == "hour" {
            return (1800, 3)
        }
        guard words.count >= 2 else { return nil }
        let number: Int
        let numberWordCount: Int
        if let digits = Int(words[0]), words[0].allSatisfy(\.isNumber) {
            number = digits
            numberWordCount = 1
        } else if let tens = numberWords[words[0]], [20, 30, 40, 50].contains(tens), words.count >= 3,
                  let ones = numberWords[words[1]], (1...9).contains(ones), words[1] != "a", words[1] != "an" {
            number = tens + ones
            numberWordCount = 2
        } else if let wordNumber = numberWords[words[0]] {
            number = wordNumber
            numberWordCount = 1
        } else {
            return nil
        }
        guard words.count > numberWordCount, let secondsPerUnit = unitSeconds[words[numberWordCount]] else {
            return nil
        }
        // "a minute" and "an hour" need the singular; "10 minute" is the adjective form ("10 minute timer").
        let (multipliedSeconds, overflowed) = number.multipliedReportingOverflow(by: secondsPerUnit)
        guard !overflowed else { return nil }
        return (multipliedSeconds, numberWordCount + 1)
    }

    /// The label words with a leading "the", "my", "a", "an" or "our" taken off; nil when nothing is
    /// left. The timer board cleans it further (one line, at most 30 characters).
    static func cleanedLabel(_ labelWords: [String]) -> String? {
        var words = labelWords
        if let firstWord = words.first, ["the", "my", "a", "an", "our"].contains(firstWord) {
            words.removeFirst()
        }
        let label = words.joined(separator: " ")
        return label.isEmpty ? nil : label
    }

    // MARK: - Stopping a timer

    /// "stop the timer" or "cancel the timer" with exactly one timer running, or "stop the <label>
    /// timer" / "cancel the <label> timer" where the label names exactly one running timer (an exact
    /// label first, then one that holds the words). The timer's id comes back.
    static func timerToCancel(commandText: String, runningTimers: [ClickyTimer]) -> String? {
        let labelPart: String
        if commandText == "stop the timer" || commandText == "cancel the timer" {
            labelPart = ""
        } else if let stopRange = ["stop the ", "cancel the "].first(where: { commandText.hasPrefix($0) }), commandText.hasSuffix(" timer") {
            labelPart = String(commandText.dropFirst(stopRange.count).dropLast(" timer".count))
            guard !labelPart.isEmpty else { return nil }
        } else {
            return nil
        }
        if labelPart.isEmpty {
            return runningTimers.count == 1 ? runningTimers[0].identifier : nil
        }
        let reference = ClickyActionText.normalizedForComparison(labelPart)
        let exactMatches = runningTimers.filter { timer in
            timer.label.map { ClickyActionText.normalizedForComparison($0) == reference } ?? false
        }
        if exactMatches.count == 1 {
            return exactMatches[0].identifier
        }
        if exactMatches.count > 1 {
            return nil
        }
        let containingMatches = runningTimers.filter { timer in
            guard let label = timer.label else { return false }
            let normalizedLabel = ClickyActionText.normalizedForComparison(label)
            return normalizedLabel.contains(reference) || reference.contains(normalizedLabel)
        }
        return containingMatches.count == 1 ? containingMatches[0].identifier : nil
    }
}
