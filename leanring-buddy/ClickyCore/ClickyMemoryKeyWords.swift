import Foundation

/// What happened when a spoken "forget ..." request removed saved memory from the profile or the notes.
nonisolated enum ClickyMemoryRemovalResult: Equatable {
    case removed(removedTexts: [String])
    case noMatch
    /// Two or more saved items match equally well, so nothing was removed: guessing could forget
    /// the wrong one. The user is asked to say which.
    case ambiguous(matchCount: Int)
    case failed(errorDescription: String)
}

/// The outcome of looking for the one saved text a spoken "forget <thing>" refers to.
nonisolated enum ClickyMemoryBestMatch: Equatable {
    case none
    case single(index: Int)
    /// Several candidates match equally well.
    case tie(indexes: [Int])
}

/// Turns a sentence into the few words that carry its subject, so two short sentences can be
/// compared without a language model. It serves two jobs with the same rule: deciding that a new
/// profile fact is about the same subject as an older one (so the new fact replaces the old), and
/// finding which saved memory a spoken "forget <thing>" refers to.
///
/// The rule is deliberately cautious. When two sentences share no key word they are treated as
/// unrelated: nothing is replaced and nothing is forgotten, which loses less than a wrong guess.
nonisolated enum ClickyMemoryKeyWords {
    static let minimumKeyWordCharacterCount = 3

    /// Words that say little about the subject. Besides ordinary filler this holds the verbs and
    /// adverbs that open nearly every profile fact ("uses", "prefers", "always"), because two facts
    /// that merely both say "prefers" are not about the same thing.
    static let ignoredWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "what", "when", "where", "which", "who", "how",
        "did", "does", "you", "your", "are", "was", "were", "have", "has", "had", "not", "but",
        "from", "about", "just", "can", "could", "would", "should", "will", "please", "clicky",
        "hey", "there", "they", "them", "their", "its", "into", "out", "all", "any", "his", "her",
        "she", "him", "our", "own", "also", "than", "then", "very", "really", "more", "most", "much",
        "over", "instead", "only", "still", "now", "too", "been", "being", "one", "some", "something",
        "anything", "everything", "thing", "things", "stuff", "new", "old",
        "user", "users", "like", "likes", "liked", "love", "loves", "hate", "hates", "enjoy", "enjoys",
        "use", "uses", "used", "using", "prefer", "prefers", "preferred", "want", "wants", "need", "needs",
        "always", "usually", "never", "often", "sometimes", "mostly", "generally", "typically", "normally",
        "tell", "told", "said", "say", "says", "remember", "remembers", "remembered", "note", "notes", "reminder", "reminders", "forget",
        "profile", "preference", "preferences", "fact", "facts", "saved", "stored",
        "keep", "keeps", "write", "writes", "writing", "work", "works", "working", "make", "makes",
        "code", "coding",
    ]

    /// Words that name a whole category (a slot such as "name" or "editor", or a vague noun like
    /// "number"). Sharing only one of these says almost nothing about whether two sentences are the
    /// same fact: "forget my name" must not remove "the dog's name is rex" just because both say
    /// "name". Slots are handled by `ClickyProfileSlots`; for everything else a match on one of
    /// these words alone is too weak to delete anything.
    static let genericKeyWords: Set<String> = [
        "name", "editor", "shell", "language", "answer", "system", "favorite", "favourite", "number",
        "main", "default", "preferred", "usual", "thing", "time", "day", "life", "home",
        "tab", "space", "indent", "indentation",
    ]

    /// Different words for the same subject, so "call me sam" and "my name is alex" are seen as
    /// both being about the name.
    static let canonicalKeyWordBySynonym: [String: String] = [
        "call": "name", "called": "name", "named": "name", "nickname": "name",
        "ide": "editor",
        "reply": "answer", "response": "answer",
    ]

    /// The key words of a sentence: lowercase, plural endings removed, filler and very short
    /// words dropped, synonyms folded into one word.
    static func keyWords(in text: String) -> Set<String> {
        var keyWords = Set<String>()
        let rawWords = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        for rawWord in rawWords {
            guard rawWord.count >= minimumKeyWordCharacterCount else {
                continue
            }
            let singularWord = removingPluralEnding(from: rawWord)
            if ignoredWords.contains(rawWord) || ignoredWords.contains(singularWord) {
                continue
            }
            keyWords.insert(canonicalKeyWordBySynonym[singularWord] ?? singularWord)
        }
        return keyWords
    }

    /// True when the two sentences share at least one key word.
    static func textsShareAKeyWord(_ firstText: String, _ secondText: String) -> Bool {
        !keyWords(in: firstText).isDisjoint(with: keyWords(in: secondText))
    }

    static func isGenericKeyWord(_ keyWord: String) -> Bool {
        genericKeyWords.contains(keyWord)
    }

    /// Finds the one candidate a "forget <thing>" points at, cautiously.
    /// - A candidate qualifies when it shares at least two key words with the target, or shares
    ///   one key word that is not a generic category word (so "dentist" can qualify, "name" alone
    ///   cannot).
    /// - The qualifying candidate sharing the most key words wins.
    /// - If several tie, the answer is `.tie`: the caller removes nothing and asks the user to say which.
    static func bestMatch(forTargetText targetText: String, in candidateTexts: [String]) -> ClickyMemoryBestMatch {
        let targetKeyWords = keyWords(in: targetText)
        guard !targetKeyWords.isEmpty else {
            return .none
        }

        var sharedKeyWordCountByQualifyingIndex: [Int: Int] = [:]
        for (candidateIndex, candidateText) in candidateTexts.enumerated() {
            let sharedKeyWords = keyWords(in: candidateText).intersection(targetKeyWords)
            let sharesTwoOrMore = sharedKeyWords.count >= 2
            let sharesOneDistinctiveWord = sharedKeyWords.count == 1 && !isGenericKeyWord(sharedKeyWords.first ?? "")
            if sharesTwoOrMore || sharesOneDistinctiveWord {
                sharedKeyWordCountByQualifyingIndex[candidateIndex] = sharedKeyWords.count
            }
        }
        guard let highestSharedKeyWordCount = sharedKeyWordCountByQualifyingIndex.values.max() else {
            return .none
        }
        let bestIndexes = sharedKeyWordCountByQualifyingIndex
            .filter { $0.value == highestSharedKeyWordCount }
            .map(\.key)
            .sorted()
        return bestIndexes.count == 1 ? .single(index: bestIndexes[0]) : .tie(indexes: bestIndexes)
    }

    /// True when two texts say essentially the same thing, such as a [PROFILE:] and a [NOTE:] the
    /// model wrote for one statement: one has all the key words of the other, or they overlap by
    /// at least 60 percent. Texts with no key words are compared by their plain words.
    static func textsAreEssentiallyTheSame(_ firstText: String, _ secondText: String) -> Bool {
        let firstKeyWords = keyWords(in: firstText)
        let secondKeyWords = keyWords(in: secondText)
        if firstKeyWords.isEmpty || secondKeyWords.isEmpty {
            let firstPlainText = firstText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let secondPlainText = secondText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return !firstPlainText.isEmpty && firstPlainText == secondPlainText
        }
        if firstKeyWords.isSubset(of: secondKeyWords) || secondKeyWords.isSubset(of: firstKeyWords) {
            return true
        }
        let overlapCount = firstKeyWords.intersection(secondKeyWords).count
        let unionCount = firstKeyWords.union(secondKeyWords).count
        return Double(overlapCount) / Double(unionCount) >= 0.6
    }

    /// Returns the positions of the candidates that match the target best: every candidate that
    /// shares the highest number of key words with it. Candidates sharing none are never returned,
    /// so a target with no key words (or no overlap) matches nothing.
    static func indexesOfBestMatches(forTargetText targetText: String, in candidateTexts: [String]) -> [Int] {
        let targetKeyWords = keyWords(in: targetText)
        guard !targetKeyWords.isEmpty else {
            return []
        }

        let sharedKeyWordCounts = candidateTexts.map { candidateText in
            keyWords(in: candidateText).intersection(targetKeyWords).count
        }
        guard let highestSharedKeyWordCount = sharedKeyWordCounts.max(), highestSharedKeyWordCount > 0 else {
            return []
        }
        return sharedKeyWordCounts.indices.filter { candidateIndex in
            sharedKeyWordCounts[candidateIndex] == highestSharedKeyWordCount
        }
    }

    /// "tabs" and "tab" should be the same word, and "replies" and "reply". Words ending in "ss"
    /// or "us" ("class", "status") keep their ending.
    private static func removingPluralEnding(from word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") {
            return String(word.dropLast(3)) + "y"
        }
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") else {
            return word
        }
        return String(word.dropLast())
    }
}
