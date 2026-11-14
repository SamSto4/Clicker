import Foundation

// Round 18 (Jarvis actions): the honesty rule for actions, which mirrors the file editing one. Clicky
// never says it did something a tool result does not confirm, and never says a link or shortcut that
// still waits for the user has already happened. Foundation only.
//
// Two rules (the brief's, made exact):
// - With a link or shortcut queued: a sentence claiming it already happened ("i opened the link",
//   "the shortcut ran", "done.") is dropped, and "it's ready. press return or say yes to go ahead."
//   is added when no other sentence tells the user how to confirm.
// - With actions on: a claim that a timer, reminder, app, link, search or file was set, started, added,
//   opened or run, when no action of that kind really happened this turn, becomes "i didn't do that."
// Never rewritten: answers about state ("your pasta timer has 3 minutes left."), instructions ("you
// can set a timer in the clock app."), questions, offers, negations, and anything with no claim.

nonisolated struct ClickyActionHonestyFacts: Equatable {
    var queuedFileChangeCount = 0
    var queuedLinkCount = 0
    var queuedShortcutCount = 0
    /// A file tool was called this turn.
    var usedFileTools = false
    /// An action tool was called this turn, whether it worked or not.
    var anActionToolWasCalled = false
    /// The kinds of thing that really happened this turn (not what was queued).
    var succeededCategories = Set<ClickyActionClaimCategory>()
    var fileEditingIsOn = false
    var actionsAreOn = false

    var queuedActionCount: Int {
        queuedLinkCount + queuedShortcutCount
    }
}

nonisolated enum ClickyActionHonesty {
    /// Added when a set that holds a link or shortcut is waiting. A set of file changes alone keeps
    /// round 17's "…to apply it." (`ClickyFileEditingHonesty.readyToApplySentence`).
    static let readyToGoAheadSentence = "it's ready. press return or say yes to go ahead."
    static let didNotDoThatSentence = "i didn't do that."

    /// The spoken text with every sentence that claims something was done put right. The file
    /// editing rule runs first (with the ready sentence that fits the set), then the action rule.
    /// With `actionsAreOn` false this is exactly round 17's rule; with both off the text is returned
    /// as it is.
    static func honestSpokenText(_ spokenText: String, facts: ClickyActionHonestyFacts) -> String {
        var text = spokenText
        if facts.fileEditingIsOn {
            // A bare "done." after a timer was set is not a claim that a file changed: the file rule's
            // short-claim path only applies when no action tool did something this turn.
            text = ClickyFileEditingHonesty.honestSpokenText(
                text,
                queuedChangeCount: facts.queuedFileChangeCount,
                usedFileTools: facts.usedFileTools && facts.succeededCategories.isEmpty,
                readySentence: facts.queuedActionCount > 0 ? readyToGoAheadSentence : ClickyFileEditingHonesty.readyToApplySentence
            )
        }
        if facts.actionsAreOn {
            text = actionRule(text, facts: facts)
        }
        return text
    }

    // MARK: - The action rule

    private static func actionRule(_ spokenText: String, facts: ClickyActionHonestyFacts) -> String {
        let sentences = ClickyFileEditingHonesty.splitIntoSentences(ClickyFileEditingHonesty.removingChangeHistoryLines(from: spokenText))
        var keptSentences: [String] = []
        var didChangeAnything = ClickyFileEditingHonesty.removingChangeHistoryLines(from: spokenText) != spokenText

        let thereIsAQueuedActionToExplain = facts.queuedActionCount > 0
        let otherSentencesTellHowToConfirm = sentences.contains { sentence in
            !claimsAQueuedActionHappened(sentence, facts: facts) && !words(in: sentence).isDisjoint(with: confirmationInstructionWords)
        }
        var hasInsertedTheReadySentence = otherSentencesTellHowToConfirm || facts.queuedFileChangeCount > 0
        var hasInsertedTheDidNotDoThatSentence = false

        for sentence in sentences {
            if thereIsAQueuedActionToExplain && claimsAQueuedActionHappened(sentence, facts: facts) {
                didChangeAnything = true
                if !hasInsertedTheReadySentence {
                    keptSentences.append(readyToGoAheadSentence)
                    hasInsertedTheReadySentence = true
                }
                continue
            }
            if claimsAnActionHappenedThatDidNot(sentence, facts: facts) {
                didChangeAnything = true
                if !hasInsertedTheDidNotDoThatSentence {
                    keptSentences.append(didNotDoThatSentence)
                    hasInsertedTheDidNotDoThatSentence = true
                }
                continue
            }
            keptSentences.append(sentence)
        }
        if thereIsAQueuedActionToExplain && !hasInsertedTheReadySentence {
            keptSentences.append(readyToGoAheadSentence)
            didChangeAnything = true
        }
        // Untouched words stay exactly as they came, so a reply with nothing to put right keeps its
        // spacing and the history keeps the reply as the model wrote it.
        return didChangeAnything ? keptSentences.joined(separator: " ") : spokenText
    }

    // MARK: - Reading a sentence

    /// Words that, with an action noun, say it was done (past or progressive). "loaded" and "showed"
    /// are not here: they describe a page or a window as often as an action.
    private static let claimVerbs: Set<String> = [
        "set", "started", "starting", "added", "adding", "opened", "opening", "launched", "launching",
        "ran", "running", "created", "creating", "scheduled", "scheduling", "cancelled", "canceled",
        "cancelling", "canceling", "stopped", "stopping", "searched", "searching", "switched",
        "triggered", "executed",
    ]
    /// Verbs that mean opening something all by themselves ("opening safari now.").
    private static let openingVerbs: Set<String> = ["opened", "opening", "launched", "launching"]
    private static let searchingVerbs: Set<String> = ["searched", "searching"]
    /// With a searching verb, one of these makes it a search of the web ("i searched the web for it.").
    private static let webSearchWords: Set<String> = ["web", "google", "online", "internet"]
    /// Verbs a sentence may start with to say what Clicky is doing right now ("opening safari now.").
    private static let startingGerunds: Set<String> = [
        "opening", "launching", "starting", "setting", "adding", "running", "creating", "searching",
        "cancelling", "canceling", "stopping", "scheduling",
    ]
    private static let timerNouns: Set<String> = ["timer", "timers", "countdown", "alarm"]
    private static let reminderNouns: Set<String> = ["reminder", "reminders"]
    private static let shortcutNouns: Set<String> = ["shortcut", "shortcuts"]
    private static let linkNouns: Set<String> = ["link", "links", "url", "page", "site", "website", "tab", "browser"]
    /// A sentence that is only "done" (the tool result decides whether that is true).
    private static let bareDoneWords: Set<String> = ["done", "finished", "completed", "set"]
    private static let firstPersonWords: Set<String> = ["i", "i've", "ive", "i'm", "im", "we", "we've"]
    private static let modalWords: Set<String> = [
        "will", "would", "can", "could", "should", "shall", "if", "want", "wanna", "let", "may", "might",
        "i'll", "we'll", "it'll", "going", "once", "when", "whether", "need", "needs", "try", "trying",
    ]
    private static let negationWords: Set<String> = [
        "not", "never", "no", "without", "didn't", "haven't", "hasn't", "couldn't", "can't", "won't",
        "wasn't", "isn't", "don't", "doesn't", "nothing", "unable",
    ]
    /// Words that make a sentence about something that waits for the user, not one that happened.
    private static let waitingWords: Set<String> = [
        "ready", "confirm", "return", "yes", "waiting", "pending", "queued", "proposed", "wait", "say",
    ]
    private static let confirmationInstructionWords: Set<String> = ["ready", "confirm", "return", "yes"]

    /// With a link or shortcut waiting: a sentence that says it already happened. A claim about
    /// something that really happened at once (an app that opened, a timer) is left to the other rule.
    private static func claimsAQueuedActionHappened(_ sentence: String, facts: ClickyActionHonestyFacts) -> Bool {
        let orderedWords = orderedWords(in: sentence)
        let sentenceWords = Set(orderedWords)
        guard !sentence.hasSuffix("?"),
              sentenceWords.isDisjoint(with: modalWords),
              sentenceWords.isDisjoint(with: negationWords),
              sentenceWords.isDisjoint(with: waitingWords) else {
            return false
        }
        let wordsAfterInterjections = wordsWithoutLeadingInterjections(orderedWords)
        // Added in review (the live eval's offline battery): "it's open.", "the page is open.",
        // "pulling it up now." and "there you go." stayed next to the ready sentence.
        if facts.queuedLinkCount > 0 && (isAStateClaim(wordsAfterInterjections) || startsWithAnOpeningGerundOrPhrase(wordsAfterInterjections)) {
            return true
        }
        if facts.queuedShortcutCount > 0, let firstWord = wordsAfterInterjections.first,
           ["ran", "started", "triggered", "executed", "running", "starting"].contains(firstWord) || isAFirstPersonRunClaim(wordsAfterInterjections) {
            return true
        }
        if isAShortConfirmation(wordsAfterInterjections) {
            return true
        }
        let claimsSomethingDone = !sentenceWords.isDisjoint(with: claimVerbs) || !sentenceWords.isDisjoint(with: bareDoneWords)
        guard claimsSomethingDone else {
            return false
        }
        if facts.queuedShortcutCount > 0 && !sentenceWords.isDisjoint(with: shortcutNouns) {
            return true
        }
        if facts.queuedLinkCount > 0 && !sentenceWords.isDisjoint(with: linkNouns) {
            return true
        }
        // "done." or "all done.": a bare claim, with something waiting.
        return isABareDoneClaim(orderedWords: orderedWords)
    }

    private static func isABareDoneClaim(orderedWords: [String]) -> Bool {
        orderedWords.count <= 3
            && orderedWords.contains(where: { ["done", "finished", "completed"].contains($0) })
            && !orderedWords.contains("not")
    }

    /// "all set.", "you're all set.", "there you go.": a few words that only say it is done.
    private static func isAShortConfirmation(_ words: [String]) -> Bool {
        guard words.count <= 4 else {
            return false
        }
        let joinedText = " " + words.joined(separator: " ") + " "
        return [" all set ", " there you go ", " here you go ", " you're set ", " youre set "].contains { joinedText.contains($0) }
    }

    /// "i ran it.", "i've run the shortcut."
    private static func isAFirstPersonRunClaim(_ words: [String]) -> Bool {
        guard let firstPersonIndex = words.prefix(2).firstIndex(where: { firstPersonWords.contains($0) }),
              let runIndex = words.firstIndex(where: { ["ran", "run", "started", "triggered", "executed"].contains($0) }) else {
            return false
        }
        return runIndex > firstPersonIndex && runIndex - firstPersonIndex <= 3
    }

    /// A claim that a timer, reminder, app, link, search or shortcut was set, started, added, opened
    /// or run, when nothing of that kind happened this turn.
    private static func claimsAnActionHappenedThatDidNot(_ sentence: String, facts: ClickyActionHonestyFacts) -> Bool {
        let orderedWords = orderedWords(in: sentence)
        let sentenceWords = Set(orderedWords)
        let nothingCameOfAnActionToolCall = facts.anActionToolWasCalled && facts.succeededCategories.isEmpty && facts.queuedActionCount == 0

        // "i'll remind you at nine." is a promise only a reminder (or a timer) keeps. It is read before
        // the modal-word guard below, which would otherwise skip every "i'll" (added in review).
        if isAReminderPromise(sentence, orderedWords: orderedWords) {
            return !facts.succeededCategories.contains(.reminder) && !facts.succeededCategories.contains(.timer)
        }

        guard !sentence.hasSuffix("?"),
              sentenceWords.isDisjoint(with: modalWords),
              sentenceWords.isDisjoint(with: negationWords),
              sentenceWords.isDisjoint(with: waitingWords) else {
            return false
        }
        let wordsAfterInterjections = wordsWithoutLeadingInterjections(orderedWords)

        // "done." / "all done." / "all set.": only a claim when an action tool was called and nothing
        // came of it.
        if isABareDoneClaim(orderedWords: orderedWords) || isAShortConfirmation(wordsAfterInterjections) {
            return nothingCameOfAnActionToolCall
        }

        if let claimedCategory = categoryOfAClaim(in: orderedWords, nothingCameOfAnActionToolCall: nothingCameOfAnActionToolCall) {
            return !facts.succeededCategories.contains(claimedCategory)
        }

        // "safari is open now.", "youtube is up.", "here's youtube.": these also describe a screen, so
        // they count as claims only right after an action tool was called and nothing came of it.
        return nothingCameOfAnActionToolCall && isAStateClaim(wordsAfterInterjections)
    }

    /// "i'll remind you at nine.", "you'll get a nudge at nine." (not an offer or a question).
    private static func isAReminderPromise(_ sentence: String, orderedWords: [String]) -> Bool {
        let words = wordsWithoutLeadingInterjections(orderedWords)
        let sentenceWords = Set(words)
        guard !sentence.hasSuffix("?"),
              sentenceWords.isDisjoint(with: negationWords),
              sentenceWords.isDisjoint(with: ["can", "could", "would", "if", "want", "should", "may", "might", "whenever", "like"]) else {
            return false
        }
        let joinedText = " " + words.joined(separator: " ") + " "
        let promisePhrases = [
            " i'll remind you ", " i will remind you ", " we'll remind you ", " i'll nudge you ", " i'll ping you ",
            " you'll get a reminder ", " you'll get a nudge ", " you'll get a notification ", " you'll get a ping ",
        ]
        return promisePhrases.contains { joinedText.contains($0) }
    }

    /// A short sentence that says something is open, up, showing or closed, or "here's …".
    private static func isAStateClaim(_ words: [String]) -> Bool {
        guard !words.isEmpty, words.count <= 8 else {
            return false
        }
        if words.first == "here's" || words.starts(with: ["here", "is"]) || words.starts(with: ["here", "are"]) {
            return true
        }
        let stateWords: Set<String> = ["open", "up", "showing", "closed", "launched", "on"]
        for (wordIndex, word) in words.enumerated() where ["is", "are", "it's", "that's", "its"].contains(word) || word.hasSuffix("'s") {
            let followingWords = words.dropFirst(wordIndex + 1).prefix(2)
            if followingWords.contains(where: { stateWords.contains($0) }) {
                return true
            }
        }
        return false
    }

    private static func startsWithAnOpeningGerundOrPhrase(_ words: [String]) -> Bool {
        guard let firstWord = words.first else {
            return false
        }
        if ["opening", "launching", "loading"].contains(firstWord) {
            return true
        }
        let joinedText = " " + words.joined(separator: " ") + " "
        return ["pulling", "bringing", "taking", "heading", "firing"].contains(firstWord)
            && openingPhrases.contains { joinedText.contains(" \($0) ") }
    }

    /// Two-word ways of saying something was opened, and one of saying it was looked up.
    private static let openingPhrases: [String] = [
        "pulled up", "pulling up", "brought up", "bringing up", "fired up", "firing up",
        "took you", "taking you", "heading to", "headed to",
        // "pulling it up", "bringing it up"
        "it up", "that up",
    ]
    private static let searchPhrases: [String] = ["looked up", "looking up", "looked it up", "searched for", "searching for"]
    private static let closingVerbs: Set<String> = ["closed", "closing", "quit", "quitting", "quitted"]
    /// Past tenses that, as the first word of a sentence, are Clicky saying what it did ("opened
    /// safari."). "set" and "quit" are left out: they are also the imperative ("set a timer by …",
    /// "quit safari with command q.").
    private static let pastTenseVerbsAtTheStart: Set<String> = [
        "opened", "launched", "started", "added", "created", "ran", "searched", "scheduled", "stopped",
        "cancelled", "canceled", "closed", "pulled", "brought", "took", "fired",
    ]
    /// First-person verbs that claim an action even with no noun after them ("i ran it."), when an
    /// action tool was called and nothing came of it. "started" and "set" are left out: "i started by
    /// reading the file." is an answer.
    private static let claimVerbsThatNeedNoNoun: [String: ClickyActionClaimCategory] = [
        "ran": .shortcut, "opened": .open, "launched": .open, "added": .reminder, "created": .reminder,
        "scheduled": .reminder, "closed": .close, "quit": .close,
    ]

    /// The kind of thing a sentence claims was done, or nil when it claims nothing. Screen answers use
    /// the same words ("the page loaded fine.", "the window opened on the second screen.", "i started by
    /// reading the file.", "that search returned nothing."), so a claim has to be one of these shapes:
    /// - first person with the verb right after it ("i've set a timer", "i just opened safari"), the
    ///   first person being one of the first two words;
    /// - a sentence that starts with what Clicky is doing ("opening safari now");
    /// - for timers, reminders and shortcuts only, a short passive with the noun first ("reminder
    ///   added.", "your timer is set.", "the shortcut ran.").
    /// What is claimed is the kind of the noun for a timer, a reminder or a shortcut. Opening something
    /// (an app, a link, a search) needs a verb that means opening, or a web search.
    private static func categoryOfAClaim(in allOrderedWords: [String], nothingCameOfAnActionToolCall: Bool) -> ClickyActionClaimCategory? {
        // "ok, opening spotify." and "got it, i've set it." are read without their first words.
        let orderedWords = wordsWithoutLeadingInterjections(allOrderedWords)
        let joinedText = " " + orderedWords.joined(separator: " ") + " "
        let usesAnOpeningPhrase = openingPhrases.contains { joinedText.contains(" \($0) ") }
        let usesASearchPhrase = searchPhrases.contains { joinedText.contains(" \($0) ") }
        let isAVerbOfThisRule: (String) -> Bool = { word in
            claimVerbs.contains(word) || closingVerbs.contains(word) || pastTenseVerbsAtTheStart.contains(word)
                || ["pulling", "bringing", "taking", "heading", "firing", "looked", "looking", "headed"].contains(word)
        }
        guard let firstVerbIndex = orderedWords.firstIndex(where: isAVerbOfThisRule) else {
            return nil
        }
        let sentenceWords = Set(orderedWords)

        // Which kind of action the words are about.
        var category: ClickyActionClaimCategory?
        if !sentenceWords.isDisjoint(with: timerNouns) {
            category = .timer
        } else if !sentenceWords.isDisjoint(with: reminderNouns) {
            category = .reminder
        } else if !sentenceWords.isDisjoint(with: shortcutNouns) {
            category = .shortcut
        } else if !sentenceWords.isDisjoint(with: closingVerbs) {
            category = .close
        } else if !sentenceWords.isDisjoint(with: openingVerbs) || usesAnOpeningPhrase {
            category = .open
        } else if (!sentenceWords.isDisjoint(with: searchingVerbs) && !sentenceWords.isDisjoint(with: webSearchWords)) || usesASearchPhrase {
            category = .open
        }
        // "opening hours are nine to five." starts like a claim and is not one.
        if category == .open && !sentenceWords.isDisjoint(with: ["hours", "times"]) {
            return nil
        }

        let firstPersonIndex = orderedWords.prefix(2).firstIndex(where: { firstPersonWords.contains($0) })
        let verbFollowsTheFirstPerson = firstPersonIndex.map { firstVerbIndex > $0 && firstVerbIndex - $0 <= 3 } ?? false
        let firstWord = orderedWords.first ?? ""

        guard let category else {
            // No noun: "i ran it." or "opened it." is a claim only when an action tool was called and
            // nothing came of it.
            guard nothingCameOfAnActionToolCall else {
                return nil
            }
            let verb = orderedWords[firstVerbIndex]
            if verbFollowsTheFirstPerson || (firstVerbIndex == 0 && pastTenseVerbsAtTheStart.contains(verb)) {
                return claimVerbsThatNeedNoNoun[verb]
            }
            return nil
        }

        // First person, with the verb within three words after it.
        if verbFollowsTheFirstPerson {
            return category
        }
        // Starts with what Clicky is doing ("opening safari now.", "closing safari now.").
        if startingGerunds.contains(firstWord) || ["closing", "quitting"].contains(firstWord) || startsWithAnOpeningGerundOrPhrase(orderedWords) {
            return category
        }
        // Starts with what Clicky did ("opened safari.", "added it to your reminders.").
        if pastTenseVerbsAtTheStart.contains(firstWord) {
            return category
        }
        // A short passive with the noun first, for the three kinds that have one ("your timer is set
        // for ten minutes." was too long for the first limit of five words).
        if category != .open && category != .close, orderedWords.count <= 8 {
            let allNouns = timerNouns.union(reminderNouns).union(shortcutNouns)
            if let firstNounIndex = orderedWords.firstIndex(where: { allNouns.contains($0) }), firstNounIndex < firstVerbIndex {
                return category
            }
        }
        return nil
    }

    /// The words of a sentence after the little words a reply may start with ("ok", "sure", "got it",
    /// "all right"). At least one word is always left.
    private static func wordsWithoutLeadingInterjections(_ orderedWords: [String]) -> [String] {
        var remainingWords = ArraySlice(orderedWords)
        while true {
            if remainingWords.count > 2, remainingWords.prefix(2).elementsEqual(["got", "it"]) || remainingWords.prefix(2).elementsEqual(["all", "right"]) {
                remainingWords = remainingWords.dropFirst(2)
            } else if remainingWords.count > 1, let firstWord = remainingWords.first,
                      ["ok", "okay", "sure", "alright", "great", "perfect", "so", "and", "right"].contains(firstWord) {
                remainingWords = remainingWords.dropFirst()
            } else {
                break
            }
        }
        return Array(remainingWords)
    }

    /// The lowercase words of a sentence in order, apostrophes kept ("didn't").
    private static func orderedWords(in sentence: String) -> [String] {
        let straightened = sentence.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let wordCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "'"))
        return straightened.components(separatedBy: wordCharacters.inverted).filter { !$0.isEmpty }
    }

    private static func words(in sentence: String) -> Set<String> {
        Set(orderedWords(in: sentence))
    }
}
