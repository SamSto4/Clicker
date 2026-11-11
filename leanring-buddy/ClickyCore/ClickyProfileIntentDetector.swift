import Foundation

/// A spoken request to remove something Clicky saved.
nonisolated enum ClickyForgetRequest: Equatable {
    /// "forget that": the thing saved most recently.
    case previouslySavedThing
    /// "forget my dentist appointment" or "forget that i use vim": `targetText` is what follows.
    case specificThing(targetText: String)
    /// "forget my editor and my shell": more than one thing at once. Nothing is removed; the user
    /// is asked to say them one at a time.
    case severalThings
    /// "forget everything", "wipe your memory", "forget what you know about me" and every other
    /// way of asking to clear it all. Refused: no voice command wipes the profile or the notes.
    /// Deleting profile.md (and the daily note files) is the way to do that.
    case everything
    /// A request to change memory that cannot be carried out as it was said, because a question or
    /// instruction came with it ("forget my name, and what is the capital of france") or because
    /// it was only a brush-off ("forget it, where's the run button"). Nothing is removed and the
    /// turn is answered normally. `namesAMemoryObject` is true when something specific was named
    /// ("my name"), so Clicky can add that it did not forget anything.
    case notExecutable(namesAMemoryObject: Bool)
}

/// Decides, from the user's spoken words alone, whether they stated something lasting about
/// themselves or asked to forget something.
///
/// Screen text is untrusted: a web page can say "remember that ..." or "i prefer ...". Only the
/// transcript of what the user said can unlock a profile save, so this file never looks at
/// anything else. A [PROFILE:] tag from the model is honored only when the transcript passes
/// `transcriptStatesLastingFactOrPreference`, which is generous because a false positive still
/// needs the model to have written a tag.
nonisolated enum ClickyProfileIntentDetector {
    // MARK: - Lasting statements

    /// The word "i", but not at the start of a question: in "how do i use xcode" or "should i
    /// write this in swift" the user is asking, not telling.
    private static let firstPersonSubject = #"(?<!\b(?:how|do|does|did|can|could|should|would|will|shall|what|when|why|where|whether|if|may|might)\s)\bi"#

    /// Words after a verb that make the statement about the thing on screen right now, not about
    /// the user: "i like how this looks", "i use this button a lot".
    private static let onScreenReferenceLookahead = #"(?!\w)(?!\s+(?:this|that|these|those|it|how|the\s+way|what|when|here|there)\b)"#

    /// Phrases that state a lasting fact, a preference, or a standing instruction to the assistant.
    /// One-off moods and tasks ("i'm a bit lost", "i hate this error", "i need to finish this
    /// email") deliberately match none of them.
    private static let lastingStatementPatterns: [String] = [
        // Habits and preferences in the first person: "i prefer tabs", "i only ever write swift".
        #"\#(firstPersonSubject)\s+(?:really\s+|always\s+|usually\s+|mostly\s+|generally\s+|typically\s+|normally\s+|also\s+|still\s+|sometimes\s+|occasionally\s+|now\s+|currently\s+|only\s+(?:ever\s+)?|exclusively\s+)?(?:prefer|use|like|love|enjoy|speak|live|write|code|program|develop|study|teach|work\s+(?:at|as|in|for|from|with))\#(onScreenReferenceLookahead)"#,
        // Updates to an earlier preference: "i no longer use vim", "i switched to helix", "i've
        // started using fish", "i'm using helix now", "i stopped using tabs".
        #"\#(firstPersonSubject)(?:['’]ve|\s+have)?\s+(?:no\s+longer|stopped|quit|gave\s+up|given\s+up|dropped|ditched|abandoned)\s+(?:on\s+)?(?!(?:this|that|it|the)\b)\w"#,
        #"\#(firstPersonSubject)(?:['’]ve|\s+have)?\s+(?:switched|moved|changed|migrated|gone|went)\s+(?:over\s+|back\s+)?(?:from\s+[^.?!]{1,30}?\s+)?to\s+(?!(?:the|a|an|this|that|my|your|next|previous|another|it)\b)\w"#,
        #"\#(firstPersonSubject)(?:['’]ve|\s+have)?\s+(?:started|begun|began|begin)\s+(?:using|writing|coding|programming|working\s+(?:in|with)|to\s+use)\s+(?!(?:this|that|it|the)\b)\w"#,
        #"\#(firstPersonSubject)(?:['’]ve|\s+have)?\s+(?:went\s+with|replaced\s+\w+\s+with|changed\s+my\s+\w+(?:\s+\w+)?\s+to)\s+(?!(?:the|a|an|this|that|it)\b)\w"#,
        #"\bi(?:['’]m|\s+am)\s+using\s+(?!(?:this|that|it|the|a|an)\b)[\w+#.-]+(?:\s+[\w+#.-]+)?\s+(?<!right\s)now\b"#,
        #"\bi(?:['’]m|\s+am)\s+now\s+using\b"#,
        #"\bi(?:['’]m|\s+am)\s+no\s+longer\s+(?:using|writing|coding|programming|into|a\s+fan\s+of)\b"#,
        #"\#(firstPersonSubject)\s*(?:do\s*not|don['’]?t)\s+(?:use|write|code|program|like|prefer|want|need)\b[^.?!]{0,40}\b(?:anymore|any\s+more|any\s+longer)\b"#,
        #"\#(firstPersonSubject)\s+(?:always|usually|never|mostly|generally|typically|normally)\s+(?:use|write|code|program|work|prefer|want|like|need|drink|eat|wear|build|test|commit|type|read|keep|start|end|take|go)\b"#,
        #"\#(firstPersonSubject)\s+tend\s+to\b"#,
        #"\#(firstPersonSubject)\s+only(?:\s+ever)?\s+(?:write|use|code|program|speak|drink|eat|wear|read|work|develop|build|type)\b"#,
        #"\#(firstPersonSubject)\s*(?:do\s*not|don['’]?t)\s+(?:like|use|drink|eat)\#(onScreenReferenceLookahead)"#,
        // Dislikes only count when they are about how the assistant answers.
        #"\#(firstPersonSubject)\s+(?:hate|dislike|can['’]?t\s+stand)\s+(?:it\s+when\s+you|when\s+you|long\b|lengthy|verbose|wordy|rambling|emoji|being\s+called|(?:your|the)\s+(?:answers?|repl(?:y|ies)|responses?)|answers|replies|explanations)"#,
        #"\bi['’]?d\s+(?:rather|prefer)\b"#,
        #"\bi\s+would\s+(?:rather|prefer)\b"#,
        // Identity: "my name's sam", "call me sam", "i go by sam", "i'm called sam", "i'm a designer".
        #"\bmy\s+name(?:['’]s|\s+is)\b"#,
        #"\b(?:call|address|refer\s+to)\s+me\b(?!\s+(?:later|back|when|if|tomorrow|tonight|at|on|in|after|before|soon|now)\b)"#,
        #"\bi\s+go\s+by\b"#,
        #"\bi(?:['’]m|\s+am)\s+(?:called|named|known\s+as)\b"#,
        #"\b(?:people|everyone|everybody|friends|they|folks)\s+calls?\s+me\b"#,
        #"\b(?:it['’]?s|i['’]?m|this\s+is|name['’]?s)\s+\w+,?\s+by\s+the\s+way\b"#,
        #"\bi(?:['’]m|\s+am)\s+(?:a|an)\s+(?!(?:bit|little|lot|few|tad|touch|long|while|mess|wreck|loss|moment|minute|second|big|huge|way|kind|sort)\b)\w"#,
        #"\bi(?:['’]m|\s+am)\s+(?:new\s+to|learning|based\s+in|from|left[\s-]handed|right[\s-]handed|vegetarian|vegan|colou?r[\s-]?blind|dyslexic|allergic|fluent|bilingual|retired)\b"#,
        #"\bi(?:['’]m|\s+am)\s+(?:on|using|running)\s+(?:a\s+|an\s+)?(?:mac(?:book|os)?|windows|linux|ubuntu|fedora|chromebook)\b"#,
        #"\bmy\s+(?:pronouns|favou?rite\s+\w+|preferred\s+\w+|main\s+\w+|default\s+\w+|usual\s+\w+|editor|ide|browser|terminal|shell|language|time\s*zone|job|role|profession|company|team|stack|os|operating\s+system|keyboard|font|theme)(?:\s+(?:is|are|will\s+be)|['’]s)\b"#,
        // Standing instructions: "from now on ...", "answer me in spanish", "short answers please".
        #"\bfrom\s+now\s+on\b"#,
        #"\bgoing\s+forward\b"#,
        #"\bin\s+(?:the\s+)?future\b"#,
        #"\b(?:always|never|only)\s+(?:ever\s+)?(?:answer|reply|respond|give|use|say|explain|call|speak|talk|keep|show|write|start|end|be|add|include|skip|avoid|put|spell|address|refer|ask)\b"#,
        #"\bkeep\s+(?:your\s+|the\s+|all\s+|my\s+)?(?:answers?|repl(?:y|ies)|responses?|explanations?)\b"#,
        #"\bkeep\s+(?:it|things|them)\s+(?:short|brief|concise|simple|casual|formal|quick|light|friendly|professional)\b"#,
        #"\b(?:short|shorter|brief|briefer|concise|long|longer|lengthy|detailed|simple|simpler|formal|casual|technical|plain)\s+(?:answers|replies|responses|explanations)\b"#,
        #"\b(?:answer|reply|respond|speak|talk|write)\s+(?:to\s+me\s+|me\s+)?in\s+(?:english|spanish|french|german|italian|portuguese|dutch|swedish|norwegian|danish|finnish|polish|russian|ukrainian|turkish|arabic|hebrew|hindi|urdu|bengali|chinese|mandarin|cantonese|japanese|korean|vietnamese|thai|indonesian|greek|czech|romanian|hungarian|lowercase|uppercase|plain\s+english|simple\s+(?:terms|words|english)|short\s+sentences)\b"#,
        #"(?<!\bi\s)\b(?:speak|talk)\s+(?:to\s+me\s+)?(?:in\s+)?(?:english|spanish|french|german|italian|portuguese|dutch|swedish|norwegian|danish|finnish|polish|russian|ukrainian|turkish|arabic|hebrew|hindi|urdu|bengali|chinese|mandarin|cantonese|japanese|korean|vietnamese|thai|indonesian|greek|czech|romanian|hungarian)\b"#,
        #"\buse\s+(?:metric|imperial|celsius|fahrenheit|kilometers|kilometres|miles|24[\s-]hour|12[\s-]hour|military\s+time)\b"#,
        #"\b(?:shorter|longer|briefer|simpler|more\s+detailed|more\s+concise|less\s+detailed)\s+(?:please|from\s+now\s+on|next\s+time|going\s+forward)\b"#,
        #"\b(?:less|more)\s+(?:detail|detailed|verbose|concise)\b\s+(?:please|next\s+time|from\s+now\s+on|going\s+forward|in\s+future|in\s+general|every\s+time|always|generally)\b"#,
        #"^\W*(?:use\s+)?(?:less|more)\s+(?:detail|detailed|concise|verbose)\W*$"#,
        #"\b(?:no|without)\s+(?:more\s+)?emojis?\b"#,
        #"\b(?:lowercase|all\s+lowercase|uppercase)\s+only\b"#,
        #"\btabs?\b[^.?!]{0,25}\b(?:not|over|instead\s+of|rather\s+than)\b[^.?!]{0,10}\bspaces?\b"#,
        #"\bspaces?\b[^.?!]{0,25}\b(?:not|over|instead\s+of|rather\s+than)\b[^.?!]{0,10}\btabs?\b"#,
        #"\b(?:don['’]?t|do\s+not|stop)\s+(?:ever\s+)?(?:call\s+me|saying|using|adding|asking|explaining|repeating|apologi[sz]ing|use\s+emoji|say)\b"#,
        #"\bbe\s+(?:more\s+)?(?:brief|concise|terse|formal|casual|detailed|verbose)\b"#,
        #"\bi\s+want\s+(?:you\s+to\s+(?:always|never)|(?:shorter|longer|brief|short|concise|detailed)\s+(?:answers|replies|responses))"#,
    ]

    /// Patterns that must be read with their capitalization. A transcript that capitalizes the
    /// word after "I am" is almost always giving a name ("I am Sam"). Lowercase "i am tired" is not
    /// matched, so a mood never opens the gate.
    private static let lastingStatementCaseSensitivePatterns: [String] = [
        #"\b[Ii](?:['’]m|\s+am)\s+[A-Z][a-z]+\b"#,
    ]

    static func transcriptStatesLastingFactOrPreference(_ userTranscript: String) -> Bool {
        if lastingStatementPatterns.contains(where: { containsMatch(of: $0, in: userTranscript) }) {
            return true
        }
        return lastingStatementCaseSensitivePatterns.contains {
            containsMatch(of: $0, in: userTranscript, isCaseSensitive: true)
        }
    }

    // MARK: - Grounding in the user's own words

    /// The user speaking about themselves: "i", "my", "me" and their contractions.
    private static let selfReferencePattern = #"\b(?:i|i['’]m|i['’]ve|i['’]d|i['’]ll|my|me|mine|myself)\b"#

    /// An utterance that opens like a question about something ("what is ...", "how do i ...",
    /// "is my ..."). A question states nothing lasting, so it never grounds a profile fact.
    private static let questionOpeningPattern = #"^\s*(?:(?:hey|hi|ok|okay|so|well|um|uh|clicky)[\s,]+)*(?:what|where|when|why|who|whose|which|how|is|are|am|do|does|did|should|was|were)\b"#

    /// A second way through the save gate, for requests the phrase list cannot predict
    /// ("change my name to helix", "switch my editor to zed", "no, it's helix for me").
    /// The phrase list alone made memory feel rigid: an ordinary request was answered with
    /// "i didn't save that." This check keeps the reason the gate exists (text on screen must never
    /// write memory) without needing a fixed wording:
    /// - the user must be talking about themselves, not asking a question, and not describing
    ///   a passing state or a one-off task, and
    /// - the specific words of the fact (its value, such as "helix") must be words the user
    ///   actually spoke. Screen text can make the model write a tag, but it cannot put the fact's
    ///   words into the user's mouth.
    /// Words that mark a passing state or a one-off task ("i'm tired today", "i need to finish
    /// this email"). Such an utterance is not a lasting fact even when the model tags it.
    private static let oneOffStatementPattern = #"\b(?:today|tonight|tomorrow|yesterday|right\s+now|at\s+the\s+moment|for\s+now|this\s+(?:morning|afternoon|evening|week|weekend|time|once)|need\s+to|have\s+to|got\s+to|gotta|about\s+to|going\s+to|gonna|trying\s+to)\b"#

    static func transcriptGroundsProfileFact(userTranscript: String, profileFactText: String) -> Bool {
        guard containsMatch(of: selfReferencePattern, in: userTranscript),
              !containsMatch(of: questionOpeningPattern, in: userTranscript),
              !containsMatch(of: oneOffStatementPattern, in: userTranscript) else {
            return false
        }
        let specificFactKeyWords = ClickyMemoryKeyWords.keyWords(in: profileFactText)
            .filter { !ClickyMemoryKeyWords.isGenericKeyWord($0) }
        guard !specificFactKeyWords.isEmpty else {
            return false
        }
        let spokenKeyWords = ClickyMemoryKeyWords.keyWords(in: userTranscript)
        let spokenSpecificKeyWordCount = specificFactKeyWords.filter { spokenKeyWords.contains($0) }.count
        // At least half, so a light rewording by the model ("prefers short replies" for
        // "keep it short for me") still counts, while a fact made of unspoken words does not.
        return spokenSpecificKeyWordCount * 2 >= specificFactKeyWords.count
    }

    // MARK: - Forgetting

    // MARK: Lead-in and verbs

    /// Words that may open an utterance or a clause without changing what it asks.
    private static let requestFillerWords = #"(?:hey|hi|ok|okay|so|well|alright|right|um|uh|actually|clicky|yeah|yes|yep|sure|now|then|anyway|listen|look|and|also|but|first|next|finally|never\s*mind|nevermind)"#

    /// Polite ways to ask, such as "can you", "please", "i want you to", "i'd like you to".
    private static let politeRequestPhrases = #"(?:please|can\s+you|could\s+you|will\s+you|would\s+you|you\s+can|you\s+could|you\s+should|just|go\s+ahead\s+and|kindly|i\s+want\s+you\s+to|i\s+would\s+like\s+you\s+to|i['’]d\s+like\s+you\s+to|i\s+need\s+you\s+to|i['’]d\s+like\s+it\s+if\s+you\s+would|i['’]d\s+appreciate\s+it\s+if\s+you\s+would|i['’]m\s+asking\s+you\s+to|i\s+ask\s+you\s+to)"#

    /// A longer polite preface of up to six words that ends in "you could", "you can", "you to":
    /// "it would be great if you could ...", "i was wondering if you could ...". It may not contain a
    /// negation or a question word, so "i don't want you to forget my name" and "how can you
    /// forget my name" are not read as requests to forget.
    private static let wordyPolitePreface = #"(?:(?!(?:don['’]?t|do\s+not|never|not|no|won['’]?t|shouldn['’]?t|can['’]?t|cannot|without|how|what|why|when|where|which|who|is|are|does|did)\b)[a-z'’]+[,\s]+){0,6}?(?:you|clicky)[,\s]+(?:to|could|can|would|will|should|might|may)[,\s]+(?:please[,\s]+)?"#

    private static var requestLeadInPattern: String {
        #"^\W*(?:\#(requestFillerWords)[,.\s]+)*(?:(?:\#(politeRequestPhrases)|\#(wordyPolitePreface))[,\s]*)*"#
    }

    /// "forget ..." or "stop remembering ..." (also "don't remember ..." and "i don't want you to
    /// remember ..."). The verb must come first in its clause, so "don't forget to call mom" and
    /// "i forgot my keys" are never read as a request to forget.
    private static let forgetVerbPattern = #"(?:forget|stop\s+remembering|(?:i\s+)?(?:don['’]?t|do\s+not)\s+want\s+you\s+to\s+(?:remember|keep\s+remembering)|(?:don['’]?t|do\s+not)\s+(?:remember|keep\s+remembering)|no\s+longer\s+remember)\b"#

    /// Other verbs that mean "clear it". They count only when the object clearly belongs to memory
    /// ("wipe your memory", "delete my editor preference", "remove my editor from your memory"),
    /// never on their own: "delete that file" is not about Clicky.
    private static let wipeVerbPattern = #"(?:wipe|erase|delete|clear|reset|purge|empty|flush|remove|get\s+rid\s+of)\b"#

    /// Words that say the object is something Clicky remembers, required after the verbs that are
    /// not "forget". They are phrases about Clicky's own memory ("from your memory", "what you
    /// know about", "you saved"), because a bare "saved", "profile" or "preferences" is just as
    /// likely to be about a browser: "delete my saved passwords" and "reset my profile picture"
    /// are not requests to Clicky.
    private static let memoryMarkerPattern = #"\b(?:(?:from|in|out\s+of)\s+(?:(?:your|the|my)\s+)?(?:memory|memories)|(?:from|in|out\s+of|off)\s+(?:your|the)\s+(?:profile|notes?|records?|files?)|your\s+(?:memory|memories|profile|notes|records)|what\s+you\s+(?:know|remember|have|saved)|you\s+know\s+about|you(?:['’]ve|\s+have)?\s+(?:saved|stored|remembered|noted)|(?:you|clicky)\s+remember|remembered|on\s+file)\b"#

    /// "preference" counts as a memory marker only next to something Clicky actually remembers
    /// (an editor, a name, a shell, ...), so "delete my editor preference" works and "reset my
    /// display preferences" does not.
    private static func objectNamesAMemoryMarker(_ objectText: String) -> Bool {
        if containsMatch(of: memoryMarkerPattern, in: objectText) {
            return true
        }
        return containsMatch(of: #"\b(?:preferences?|profile\s+(?:entry|fact|data))\b"#, in: objectText)
            && !ClickyProfileSlots.slots(forForgetTarget: objectText).isEmpty
    }

    // MARK: Objects

    /// What follows the verb when it points back at the last thing saved.
    private static let previousMemoryReferencePattern = #"^(?:that|this|that\s+one|this\s+one|that\s+last\s+(?:thing|one)|what\s+i\s+(?:just\s+)?(?:said|told\s+you)|(?:(?:the|my|your)\s+)?(?:last|previous|latest|most\s+recent)\s+(?:thing|one|note|fact|item|memory|entry)(?:\s+(?:i\s+(?:just\s+)?(?:said|told\s+you)|you\s+(?:saved|noted|remembered)))?)$"#

    /// "forget it" and "forget about it" are ways of saying "never mind", not a request to delete.
    /// "forget it where is the run button" is a brush-off followed by a question.
    private static let nevermindIdiomPattern = #"^(?:(?:it|about\s+it)(?:\s|$)|i\s+asked$|i\s+said\s+anything$|i\s+said\s+that$|the\s+question$)"#

    /// A question or instruction in place of the thing to forget: "forget that where is the run
    /// button". Nothing is deleted.
    private static let questionOrInstructionStartPattern = #"^(?:where|what|how|why|when|who|which|can|could|do|does|is|are|should|would|will|tell|show|open|give|explain|help|go|click|press|find|search|look|take|make|write|read|turn)\b"#

    /// Spoken filler that may follow a forget request without changing what it means.
    private static let trailingFillerPattern = #"^[\s,;:.!?\-–—]*(?:(?:please|now|for\s+me|thanks|thank\s+you|very\s+much|so\s+much|a\s+lot|okay|ok|alright|clicky|right\s+now|again|pls|cheers|many\s+thanks|if\s+you\s+(?:could|can|don['’]?t\s+mind)|will\s+you|can\s+you|would\s+you|could\s+you|you\s+can|you\s+know|i\s+mean|and|then)[\s,;:.!?\-–—]*)*$"#

    /// What may follow a wipe request without turning it into something else.
    private static let wipeElaborationPattern = #"^[\s,;:.\-–—]*(?:including|except|but|besides|even|especially|apart\s+from|other\s+than|and\s+(?:then\s+)?(?:start|begin))\b"#

    /// What opens a second thing to forget: "and my shell", ", the dentist note".
    private static let anotherTargetPattern = #"^[\s,;&]*(?:and|plus|as\s+well\s+as|along\s+with)?\s*(?:also\s+)?(?:my|your|the|that|those|these|this|everything)\b"#

    /// A short bare noun after a comma or "and": "my editor, shell". It starts with no question or
    /// instruction word, so it is read as one more thing to forget.
    private static let anotherBareTargetPattern = #"^[\s,;&]*(?:and|plus|also)?\s*(?!(?:where|what|how|why|when|who|which|can|could|do|does|is|are|should|would|will|tell|show|open|give|explain|help|go|click|press|find|search|look|take|make|write|read|turn|thanks|thank|please|ok|okay|now|i|let|start|begin|keep|then|so|but)\b)[\w'’-]+(?:\s+[\w'’-]+){0,2}\s*$"#

    /// Words that, after "and", "but", "then" and the like, start a new request or a new target.
    /// Without one of them the joining word is just part of the thing being forgotten ("tabs and spaces").
    private static let breakFollowerPattern = #"(?:my|your|the|that|those|these|this|what|everything|all|any|a|an|some|please|forget|stop|delete|remove|erase|clear|wipe|reset|where|how|why|when|who|which|can|could|do|does|is|are|should|would|will|tell|show|open|give|explain|help|go|click|press|find|search|look|take|make|write|read|turn|remind|thanks|thank|also|i|let|start|begin|keep|including|except|even)\b"#

    // Pieces of the "forget everything" grammar.
    private static let whatYouKnowPhrase = #"(?:that\s+)?(?:you|u)(?:['’]ve)?\s+(?:ever\s+)?(?:currently\s+|now\s+|already\s+|still\s+)?(?:have\s+)?(?:know|remember|have|saved|stored|keep|kept|learned|learnt|noted|got)(?:\s+(?:about|on|of)\s+(?:me|us|myself))?"#
    private static let whatIToldYouPhrase = #"(?:that\s+)?i(?:['’]?ve|\s+have)?\s+(?:told|said|shown|taught|given|asked)(?:\s+(?:you|u))?(?:\s+(?:so\s+far|before|earlier|today|already))?"#
    /// "what i've told you" (or "what i told you so far") means everything. Plain "what i said" or
    /// "what i told you" means the last thing, which is handled as "forget that".
    private static let whatIHaveToldYouPhrase = #"(?:that\s+)?i(?:['’]ve|\s+have)\s+(?:told|said|shown|taught|given|asked)(?:\s+(?:you|u))?(?:\s+(?:so\s+far|before|earlier|today|already))?|(?:that\s+)?i\s+(?:told|said|showed|taught|gave)(?:\s+(?:you|u))?\s+(?:so\s+far|before|earlier|today|already)"#
    private static let whatWeDiscussedPhrase = #"(?:that\s+)?we(?:['’]?ve|\s+have)?\s+(?:talked|spoken|discussed|chatted)\s+about(?:\s+(?:so\s+far|before|earlier|today))?"#
    private static let startFreshSuffix = #"(?:\s+and\s+(?:then\s+)?(?:start|begin)\s+(?:fresh|over|again|from\s+scratch|anew))?"#

    /// Objects that mean "all of Clicky's memory", usable with any verb.
    private static var memoryObjectPattern: String {
        // "everything you know about me", "all the things i told you", "everything about me", "all of it",
        // "everything from your memory".
        let quantifiedEverything = #"(?:everything|all|anything|whatever)\s+(?:(?:of\s+)?(?:the\s+)?(?:things|stuff|facts|info|information|details|data)\s+)?(?:\#(whatYouKnowPhrase)|\#(whatIToldYouPhrase)|\#(whatWeDiscussedPhrase)|(?:about|on)\s+(?:me|us|myself)(?:\s+\#(whatYouKnowPhrase))?|(?:of\s+)?(?:it|that|this|them)|(?:from|in|out\s+of)\s+(?:your|the|my)\s+(?:memory|memories|profile|notes?|records?))"#
        // "what you know about me", "what i've told you so far".
        let whatYouKnow = #"what\s+(?:\#(whatYouKnowPhrase)|\#(whatIHaveToldYouPhrase))"#
        // "your memory", "clear memory", "my whole profile", "all my notes and profile". The words
        // memory, memories and brain need no "your", because nothing else is meant by them here;
        // notes, profile and the rest need a possessive so "the notes from today" is not a wipe.
        let memoryNouns = #"(?:all\s+)?(?:of\s+)?(?:(?:your|my|the|ur)\s+)?(?:whole\s+|entire\s+|long[\s-]term\s+)?(?:memory|memories|brain)"#
        let possessiveNouns = #"(?:all\s+)?(?:of\s+)?(?:your|my|the|ur)\s+(?:whole\s+|entire\s+)?(?:profile|notes?|saved\s+(?:notes|facts|info|data|memories)|facts|data|information|info|details|history|records?)"#
        let nounsWithTail = #"(?:\#(memoryNouns)|\#(possessiveNouns))(?:\s+(?:of|about|on)\s+(?:me|us))?(?:\s+and\s+(?:all\s+)?(?:(?:your|my|the)\s+)?(?:memory|memories|profile|notes?|facts|data))*"#
        return #"^(?:about\s+)?(?:\#(quantifiedEverything)|\#(whatYouKnow)|\#(nounsWithTail))\#(startFreshSuffix)$"#
    }

    /// Bare "everything" and similar, which only the verb "forget" (or "stop remembering") accepts.
    private static var bareEverythingAfterForgetPattern: String {
        #"^(?:about\s+)?(?:everything|all|anything|every\s*thing|all\s+of\s+(?:it|that|this|them)|all\s+(?:that|this|it)|it\s+all|me|myself|who\s+i\s+am|whatever\s+you\s+know)\#(startFreshSuffix)$"#
    }

    /// Bare "everything" for the other verbs ("clear everything", "wipe it all").
    private static var bareEverythingAfterWipeVerbPattern: String {
        #"^(?:everything|it\s+all|all\s+of\s+it)\#(startFreshSuffix)$"#
    }

    // MARK: Parsing a request

    /// Reads a request to change memory out of the transcript. Returns nil when the user did not
    /// ask to forget. The verb may open the utterance or any later clause ("my editor changed, so
    /// please forget the old one"); a request to forget counts as one request only when it is the
    /// whole of its clause plus filler. When a real question or instruction comes with it, the result is
    /// `.notExecutable`: "forget it, where's the run button" deletes nothing and the question is
    /// answered normally.
    static func forgetRequest(in userTranscript: String) -> ClickyForgetRequest? {
        for (clauseIndex, clauseText) in clauseStartSuffixes(of: userTranscript).enumerated() {
            guard let request = parseRequest(startingAtClause: clauseText) else {
                continue
            }
            // A question or instruction before the forget clause means the user asked for two things.
            if clauseIndex > 0, textBeforeClauseIsARealRequest(String(userTranscript.dropLast(clauseText.count))) {
                switch request {
                case .everything, .specificThing, .severalThings:
                    return .notExecutable(namesAMemoryObject: true)
                case .previouslySavedThing:
                    return .notExecutable(namesAMemoryObject: false)
                case .notExecutable:
                    return request
                }
            }
            return request
        }
        return nil
    }

    /// True when the utterance asks to change memory, whether or not the request could be carried
    /// out. The turn finisher uses this to stop the model from claiming it forgot something when
    /// the app deleted nothing. It is looser than `forgetRequest(in:)`: a forget verb anywhere that
    /// is not negated, not an infinitive ("i want to forget my ex") and not part of a question.
    static func transcriptMentionsChangingMemory(_ userTranscript: String) -> Bool {
        if forgetRequest(in: userTranscript) != nil {
            return true
        }
        if containsMatch(of: #"^\W*(?:how|why|when|where|which|who|whose|is|are|does|did|should|am)\b"#, in: userTranscript) {
            return false
        }
        guard let verbRegex = try? NSRegularExpression(pattern: #"\b(?:forget|stop\s+remembering)\b"#, options: [.caseInsensitive]) else {
            return false
        }
        let transcriptRange = NSRange(userTranscript.startIndex..., in: userTranscript)
        for verbMatch in verbRegex.matches(in: userTranscript, range: transcriptRange) {
            guard let verbRange = Range(verbMatch.range, in: userTranscript) else {
                continue
            }
            let textBeforeVerb = String(userTranscript[..<verbRange.lowerBound])
            let clauseBeforeVerb = textBeforeVerb.components(separatedBy: CharacterSet(charactersIn: ",.;:!?")).last ?? textBeforeVerb
            let isNegated = containsMatch(of: #"\b(?:don['’]?t|do\s+not|never|not|won['’]?t|can['’]?t|cannot|shouldn['’]?t|wouldn['’]?t|without|no)\b"#, in: clauseBeforeVerb)
            let isInfinitiveForTheSpeaker = containsMatch(of: #"(?<!\byou\s)(?<!\bclicky\s)\bto\s*$"#, in: clauseBeforeVerb)
            if !isNegated && !isInfinitiveForTheSpeaker {
                return true
            }
        }
        // "wipe your memory, then tell me the time": the other verbs count when they name memory.
        if let wipeRegex = try? NSRegularExpression(pattern: #"\b(?:wipe|erase|delete|remove|clear|reset)\b"#, options: [.caseInsensitive]) {
            for wipeMatch in wipeRegex.matches(in: userTranscript, range: transcriptRange) {
                guard let wipeRange = Range(wipeMatch.range, in: userTranscript) else {
                    continue
                }
                let textFromVerb = String(userTranscript[wipeRange.upperBound...])
                let clauseBeforeVerb = String(userTranscript[..<wipeRange.lowerBound]).components(separatedBy: CharacterSet(charactersIn: ",.;:!?")).last ?? ""
                let isNegated = containsMatch(of: #"\b(?:don['’]?t|do\s+not|never|not|won['’]?t|can['’]?t|cannot|shouldn['’]?t|wouldn['’]?t|without|no)\b"#, in: clauseBeforeVerb)
                if !isNegated && containsMatch(of: memoryMarkerPattern, in: textFromVerb) {
                    return true
                }
            }
        }
        return false
    }

    /// Kept so existing callers keep working.
    static func transcriptStartsWithForgetPhrase(_ userTranscript: String) -> Bool {
        transcriptMentionsChangingMemory(userTranscript)
    }

    /// The utterance from its start and from the start of every later clause: after a comma, full
    /// stop or similar, and after "so", "then", "but", "because" or "anyway".
    private static func clauseStartSuffixes(of userTranscript: String) -> [String] {
        var clauseStartIndexes: [String.Index] = [userTranscript.startIndex]
        if let clauseBreakRegex = try? NSRegularExpression(pattern: #"[,.;:!?]+\s*|\s+(?:so|then|but|because|anyway)\s+"#, options: [.caseInsensitive]) {
            let transcriptRange = NSRange(userTranscript.startIndex..., in: userTranscript)
            for clauseBreakMatch in clauseBreakRegex.matches(in: userTranscript, range: transcriptRange) {
                if let breakRange = Range(clauseBreakMatch.range, in: userTranscript), breakRange.upperBound < userTranscript.endIndex {
                    clauseStartIndexes.append(breakRange.upperBound)
                }
            }
        }
        return clauseStartIndexes.map { String(userTranscript[$0...]) }
    }

    /// A question or instruction before the forget clause: "where is the run button, and forget my editor".
    private static func textBeforeClauseIsARealRequest(_ textBeforeClause: String) -> Bool {
        if textBeforeClause.contains("?") {
            return true
        }
        return containsMatch(of: #"^\W*(?:(?:hey|hi|ok|okay|so|well|and|clicky|please)[,.\s]+)*(?:where|what|how|why|when|who|which|can|could|do|does|is|are|should|would|will|tell|show|open|give|explain|help|go|click|press|find|search|look|take|make|write|read|turn)\b"#, in: textBeforeClause)
    }

    /// Parses one clause that may start with a forget or wipe verb. Returns nil when it does not.
    private static func parseRequest(startingAtClause clauseText: String) -> ClickyForgetRequest? {
        let verbIsForget: Bool
        let remainderAfterVerb: String
        if let remainderAfterForgetVerb = remainder(afterLeadInAnd: forgetVerbPattern, in: clauseText) {
            verbIsForget = true
            remainderAfterVerb = remainderAfterForgetVerb
        } else if let remainderAfterWipeVerb = remainder(afterLeadInAnd: wipeVerbPattern, in: clauseText) {
            verbIsForget = false
            remainderAfterVerb = remainderAfterWipeVerb
        } else {
            return nil
        }

        let remainderText = removingTrailingFiller(from: trimmedForgetText(remainderAfterVerb))

        // "forget everything you know about me and start fresh": the whole remainder asks for a wipe.
        if requestsWipeOfEverything(remainderText, verbIsForget: verbIsForget) {
            return .everything
        }
        let (objectText, followingText) = splitAtFirstBreak(remainderText)
        // "forget everything you know about me, including my name" and "wipe your memory except my
        // name" still ask to clear everything (or most of it). Refusing is honest and deletes nothing.
        if !followingText.isEmpty,
           requestsWipeOfEverything(withoutLeadingForgetFiller(objectText), verbIsForget: verbIsForget),
           containsMatch(of: wipeElaborationPattern, in: followingText) {
            return .everything
        }

        // The other verbs ("delete that file") are only about memory when the words say so.
        if !verbIsForget && !objectNamesAMemoryMarker(objectText) {
            return nil
        }

        let normalizedObjectText = withoutMemoryPhrases(withoutLeadingForgetFiller(objectText))

        // Something is the target (or nothing is, as in "forget" alone); what follows decides whether
        // this is one clean request.
        let objectIsOnlyAPronounOrIdiom = objectText.isEmpty
            || containsMatch(of: previousMemoryReferencePattern, in: objectText)
            || containsMatch(of: previousMemoryReferencePattern, in: normalizedObjectText)
            || (verbIsForget && containsMatch(of: nevermindIdiomPattern, in: objectText))
        let objectNamesSomething = !objectIsOnlyAPronounOrIdiom
            && !normalizedObjectText.isEmpty
            && !containsMatch(of: questionOrInstructionStartPattern, in: normalizedObjectText)

        if !followingText.isEmpty && !containsMatch(of: trailingFillerPattern, in: followingText) {
            if objectNamesSomething {
                if anotherForgetClauseStarts(in: followingText)
                    || containsMatch(of: anotherTargetPattern, in: followingText)
                    || containsMatch(of: anotherBareTargetPattern, in: followingText) {
                    return .severalThings
                }
            }
            return .notExecutable(namesAMemoryObject: objectNamesSomething && objectLooksLikeSomethingAboutTheUser(normalizedObjectText))
        }

        if objectText.isEmpty || containsMatch(of: previousMemoryReferencePattern, in: objectText) {
            return .previouslySavedThing
        }
        if verbIsForget && containsMatch(of: nevermindIdiomPattern, in: objectText) {
            return .notExecutable(namesAMemoryObject: false)
        }
        if requestsWipeOfEverything(normalizedObjectText, verbIsForget: verbIsForget) {
            return .everything
        }
        if containsMatch(of: previousMemoryReferencePattern, in: normalizedObjectText) || (!verbIsForget && containsMatch(of: #"^(?:it|that|this|them)$"#, in: normalizedObjectText)) {
            return .previouslySavedThing
        }
        if normalizedObjectText.isEmpty || containsMatch(of: questionOrInstructionStartPattern, in: normalizedObjectText) {
            return .notExecutable(namesAMemoryObject: false)
        }
        return .specificThing(targetText: normalizedObjectText)
    }

    /// "my editor", "that i use vim", "the dentist note": something Clicky could have saved about the
    /// user. "the build error" is not, so a brush-off about it ("forget the build error, how do i
    /// fix the next one") is answered without a remark about memory.
    private static func objectLooksLikeSomethingAboutTheUser(_ objectText: String) -> Bool {
        containsMatch(of: #"\b(?:my|your|me|i|i['’]m|i['’]ve|our|what\s+you|everything|notes?|reminders?|preferences?|profile|memory|memories)\b"#, in: objectText)
            || !ClickyProfileSlots.slots(forForgetTarget: objectText).isEmpty
            || !ClickyProfileSlots.slots(forFactText: objectText).isEmpty
    }

    private static func anotherForgetClauseStarts(in followingText: String) -> Bool {
        let textAfterBreak = followingText.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n,;:.!?-–—&"))
        return remainder(afterLeadInAnd: forgetVerbPattern, in: textAfterBreak) != nil
            || remainder(afterLeadInAnd: wipeVerbPattern, in: textAfterBreak) != nil
    }

    private static func requestsWipeOfEverything(_ remainderText: String, verbIsForget: Bool) -> Bool {
        if containsMatch(of: memoryObjectPattern, in: remainderText) {
            return true
        }
        let bareEverythingPattern = verbIsForget ? bareEverythingAfterForgetPattern : bareEverythingAfterWipeVerbPattern
        return containsMatch(of: bareEverythingPattern, in: remainderText)
    }

    /// The text after the lead-in ("hey clicky, please") and the verb, or nil if the clause does
    /// not start that way.
    private static func remainder(afterLeadInAnd verbPattern: String, in clauseText: String) -> String? {
        guard let leadInAndVerbRegex = try? NSRegularExpression(
            pattern: requestLeadInPattern + verbPattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let clauseRange = NSRange(clauseText.startIndex..., in: clauseText)
        guard let leadInAndVerbMatch = leadInAndVerbRegex.firstMatch(in: clauseText, options: [.anchored], range: clauseRange),
              let remainderStartIndex = Range(leadInAndVerbMatch.range, in: clauseText)?.upperBound else {
            return nil
        }
        return String(clauseText[remainderStartIndex...])
    }

    private static func trimmedForgetText(_ rawText: String) -> String {
        rawText
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n,:;-–—.!?"))
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Strips trailing politeness before the target is matched: "forget my editor thank you very
    /// much" must find "my editor", not "my editor thank you very much".
    private static func removingTrailingFiller(from text: String) -> String {
        guard let trailingFillerRegex = try? NSRegularExpression(pattern: #"(?:[,\s]+(?:please|now|for\s+me|thanks|thank\s+you(?:\s+very\s+much|\s+so\s+much)?|thanks\s+a\s+lot|many\s+thanks|cheers|okay|ok|alright|pls|if\s+you\s+(?:could|can|don['’]?t\s+mind)|will\s+you|would\s+you|can\s+you|could\s+you|right\s+now|today|again|anymore|any\s+more|any\s+longer|ever\s+again|from\s+now\s+on|at\s+all|and|then))+$"#) else {
            return text
        }
        let withoutFiller = trailingFillerRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        return trimmedForgetText(withoutFiller)
    }

    /// Splits "my editor, how do i split the window" into the thing to forget and what follows.
    /// A comma, full stop or dash always breaks. A joining word ("and", "but", "then", ...) breaks
    /// only when a new request or target follows it, so "tabs and spaces" stays whole.
    private static func splitAtFirstBreak(_ text: String) -> (objectText: String, followingText: String) {
        let breakPattern = #"\s*(?:[,;:.!?]|\s[-–—]\s)\s*|\s+(?:and|then|but|also|so|because|now|okay|ok|anyway|while|including|except|besides|even|especially|plus)\s+(?=\#(breakFollowerPattern))"#
        guard let breakRegex = try? NSRegularExpression(pattern: breakPattern),
              let firstBreakMatch = breakRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let breakRange = Range(firstBreakMatch.range, in: text) else {
            return (text, "")
        }
        let objectText = String(text[..<breakRange.lowerBound])
        let followingText = String(text[breakRange.lowerBound...])
        return (trimmedForgetText(objectText), followingText)
    }

    /// Removes spoken filler before the thing to forget: "about my dentist" and "that i use vim"
    /// both mean the words after them.
    private static func withoutLeadingForgetFiller(_ objectText: String) -> String {
        guard !containsMatch(of: previousMemoryReferencePattern, in: objectText),
              let leadingFillerRegex = try? NSRegularExpression(pattern: #"^(?:about\s+(?=\S)|what\s+i\s+(?:said|told\s+you)\s+about\s+|the\s+fact\s+that\s+|that\s+(?=\S+\s+\S))+"#) else {
            return objectText
        }
        let withoutFiller = leadingFillerRegex.stringByReplacingMatches(
            in: objectText,
            range: NSRange(objectText.startIndex..., in: objectText),
            withTemplate: ""
        )
        return trimmedForgetText(withoutFiller)
    }

    /// Removes the words that only say "from Clicky's memory": "what you know about my editor" and
    /// "my editor from your memory" both mean "my editor".
    private static func withoutMemoryPhrases(_ objectText: String) -> String {
        var strippedText = objectText
        let memoryPhrasePatterns = [
            #"^(?:what|everything|all|whatever)\s+(?:that\s+)?(?:you|u)(?:['’]ve)?\s+(?:currently\s+|now\s+)?(?:know|remember|have|saved|stored|noted|learned|learnt|kept)\s+(?:about|on|of)\s+"#,
            #"\s+(?:from|in|out\s+of|off)\s+(?:(?:your|the|my)\s+)?(?:memory|memories)$"#,
            #"\s+(?:from|in|out\s+of|off)\s+(?:your|the|my)\s+(?:profile|notes?|records?|files?|data|database|brain|list)$"#,
            #"\s+that\s+you\s+(?:saved|stored|know|remember|noted|have\s+saved)$"#,
        ]
        for memoryPhrasePattern in memoryPhrasePatterns {
            guard let memoryPhraseRegex = try? NSRegularExpression(pattern: memoryPhrasePattern) else {
                continue
            }
            strippedText = memoryPhraseRegex.stringByReplacingMatches(
                in: strippedText,
                range: NSRange(strippedText.startIndex..., in: strippedText),
                withTemplate: ""
            )
        }
        return trimmedForgetText(strippedText)
    }

    // MARK: - Negated values

    /// The value the user says they no longer use: "i no longer use vim" gives "vim", "i stopped
    /// using tabs" gives "tabs", "i don't use zsh anymore" gives "zsh". Nil when the transcript is
    /// not that kind of statement. The turn finisher uses it to remove the stale fact in that slot.
    static func valueTheUserNoLongerUses(in userTranscript: String) -> String? {
        let negatedValuePatterns = [
            #"\#(firstPersonSubject)(?:['’]ve|\s+have)?\s+(?:no\s+longer|stopped|quit|gave\s+up|given\s+up|dropped|ditched|abandoned)\s+(?:on\s+)?(?:(?:using|writing|coding|programming|working\s+(?:in|with)|preferring|liking|use|write|code|program|prefer|like)\s+)?(.+)$"#,
            #"\bi(?:['’]m|\s+am)\s+(?:no\s+longer|not)\s+(?:using|writing|coding|programming)\s+(.+)$"#,
            #"\#(firstPersonSubject)\s*(?:do\s*not|don['’]?t)\s+(?:use|write|code|program|like|prefer)\s+(.+?)\s+(?:anymore|any\s+more|any\s+longer)\b"#,
        ]
        for negatedValuePattern in negatedValuePatterns {
            guard let negatedValueRegex = try? NSRegularExpression(pattern: negatedValuePattern, options: [.caseInsensitive]),
                  let negatedValueMatch = negatedValueRegex.firstMatch(in: userTranscript, range: NSRange(userTranscript.startIndex..., in: userTranscript)),
                  let valueRange = Range(negatedValueMatch.range(at: 1), in: userTranscript) else {
                continue
            }
            // Keep only the value itself: cut at "and", "but", "now", "anymore", and punctuation.
            var valueText = String(userTranscript[valueRange]).lowercased()
            if let valueEndRegex = try? NSRegularExpression(pattern: #"\s*(?:[,;.!?]|\s(?:and|but|now|anymore|any\s+more|any\s+longer|these\s+days|at\s+all|because|so)\b).*$"#) {
                valueText = valueEndRegex.stringByReplacingMatches(in: valueText, range: NSRange(valueText.startIndex..., in: valueText), withTemplate: "")
            }
            valueText = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let leadingArticleRegex = try? NSRegularExpression(pattern: #"^(?:the|a|an|my)\s+"#) {
                valueText = leadingArticleRegex.stringByReplacingMatches(in: valueText, range: NSRange(valueText.startIndex..., in: valueText), withTemplate: "")
            }
            if valueText.contains(where: { $0.isLetter || $0.isNumber }) {
                return valueText
            }
        }
        return nil
    }

    /// True when a candidate fact is itself a negation ("no longer uses vim"). When the user said
    /// they stopped using something, such a fact would save nothing useful, so it is dropped.
    static func factTextIsANegation(_ factText: String) -> Bool {
        containsMatch(of: #"\b(?:no\s+longer|anymore|any\s+longer|stopped|quit|gave\s+up|given\s+up|dropped|ditched|abandoned|used\s+to|formerly|previously)\b"#, in: factText)
    }

    // MARK: - Secrets

    /// Kept so existing callers keep working. The checks themselves live in `ClickySecretDetector`.
    static func textLooksLikeASecret(_ text: String) -> Bool {
        ClickySecretDetector.textLooksLikeASecret(text)
    }

    // MARK: - Matching

    private static func containsMatch(of pattern: String, in text: String, isCaseSensitive: Bool = false) -> Bool {
        let regexOptions: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
        guard let patternRegex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else {
            return false
        }
        return patternRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
