import Foundation

/// The few things about the user that have exactly one current value. A new fact replaces an
/// older one only when both fill the same slot, so "uses xcode as their editor" replaces
/// "i use neovim as my editor", while "uses a small font in their editor" (about the editor, but
/// not which editor) replaces nothing.
nonisolated enum ClickyProfileSlot: String, CaseIterable, Equatable {
    /// How to address the user, or the user's name.
    case howToAddressTheUser
    case editor
    case indentationStyle
    case shell
    case mainLanguage
    /// The language the replies are written in ("answer me in spanish").
    case answerLanguage
    /// How long or detailed the replies are ("keep your answers short"). Kept apart from the
    /// language, so asking for spanish does not erase a request for short answers.
    case answerLength
    case operatingSystem

    /// The slot used to be one "answer style" slot. This name is kept so older callers still compile.
    static var answerStyle: ClickyProfileSlot { .answerLength }
}

/// Recognizes slots from phrase patterns. It is deliberately narrow, because a wrong replacement
/// or a wrong deletion loses something the user told Clicky:
/// - A fact about someone or something else (a dog, a coworker) is never in a slot about the user.
/// - A fact marked as an addition ("also uses emacs", "sometimes writes python") or as true only
///   in one setting ("uses windows at work", "writes python for scripts") is never in a slot, so
///   it is saved next to the plain fact instead of replacing it.
/// - A fact that fills several slots ("uses zsh and vim") fills each of them.
/// - A new fact worded with a strength word ("mostly uses windows") replaces nothing, because it
///   does not contradict a plain statement.
nonisolated enum ClickyProfileSlots {
    // MARK: - Shared pieces

    private static let editorNamePattern = "(?:vs\\s?code|vscode|visual\\s+studio(?:\\s+code)?|xcode|neovim|nvim|vim|emacs|helix|sublime(?:\\s+text)?|cursor|zed|intellij(?:\\s+idea)?|pycharm|webstorm|goland|rubymine|clion|rider|android\\s+studio|atom|nano|textmate|bbedit|windsurf|jetbrains|notepad\\+\\+|kate|geany|eclipse|netbeans|lapce)"

    private static let shellNamePattern = "(?:zsh|bash|fish|nushell|powershell|tcsh|ksh)"

    /// Programming languages whose names are not also ordinary words. "go" and "r" are left out on
    /// purpose ("i go by sam"); "golang" is in.
    private static let programmingLanguageNamePattern = "(?<![\\w+#])(?:swift|python|rust|java|kotlin|typescript|javascript|ruby|php|scala|elixir|haskell|dart|lua|zig|julia|golang|perl|clojure|ocaml|c\\+\\+|c#|objective[\\s-]c|f#)(?![\\w+#])"

    /// Spoken languages, for "answer me in spanish".
    private static let spokenLanguageNamePattern = "(?:english|spanish|french|german|italian|portuguese|dutch|swedish|norwegian|danish|finnish|polish|russian|ukrainian|turkish|arabic|hebrew|hindi|urdu|bengali|chinese|mandarin|cantonese|japanese|korean|vietnamese|thai|indonesian|greek|czech|romanian|hungarian|latin)"

    /// "switched to", "moved over to", "changed from vim to": the way an update is usually worded.
    /// It can introduce a new value in any slot, so the slot patterns below accept it as well as "uses".
    private static let switchedToPhrase = "(?:switch(?:ed|ing)?|mov(?:ed|ing)|chang(?:ed|ing)|migrat(?:ed|ing)|went|gone|going|settled)\\s+(?:over\\s+|back\\s+)?(?:from\\s+[\\w\\s+#.-]{1,30}?\\s+)?(?:to|on)"

    /// Lets a fact name several values in a row: "uses zsh and vim" fills both the shell slot and
    /// the editor slot, so each value pattern may be preceded by one earlier item and "and", "," or "&".
    private static let earlierListItemPattern = "(?:[\\w+#.-]+(?:\\s+[\\w+#.-]+)?\\s*(?:,|and|&)\\s+)?"

    /// Words that make a fact a side note instead of the main answer.
    private static let additiveMarkerPattern = "\\b(?:also|too|as\\s+well|sometimes|occasionally|additionally|besides|secondary|second|backup|alongside|now\\s+and\\s+then|from\\s+time\\s+to\\s+time|once\\s+in\\s+a\\s+while|on\\s+the\\s+side)\\b"

    /// Words that limit a fact to one setting, so it does not contradict the plain fact:
    /// "uses windows at work" says nothing about the machine at home.
    private static let scopeQualifierPattern = "\\b(?:at|for)\\s+(?:work|the\\s+office|my\\s+job|school|university|college|home|the\\s+gym|scripts?|scripting|fun|hobby|side\\s+projects?|personal\\s+projects?|testing|gaming|games)\\b|\\bon\\s+(?:my\\s+)?(?:work|personal|office|home)\\s+(?:laptop|machine|computer|pc|mac)\\b|\\bfor\\s+(?:quick|small|simple|one-off|throwaway)\\s+(?:scripts?|edits?|tasks?|jobs?|fixes)\\b|\\bwhen\\s+(?:i\\s+)?(?:am\\s+)?\\w+ing\\b"

    /// Strength words. A new fact that has one replaces nothing: "mostly uses windows" is not a
    /// correction of "uses macos". Older facts that have one can still be replaced.
    private static let strengthQualifierPattern = "\\b(?:mostly|mainly|primarily|usually|often|generally|typically|normally|largely|predominantly)\\b"

    /// People, pets and groups. A fact that mentions one is about them, not about the user.
    private static let otherSubjectPattern = "\\b(?:dog|dogs|cat|cats|pet|pets|puppy|kitten|boss|coworker|co-worker|colleague|wife|husband|partner|girlfriend|boyfriend|friend|friends|kid|kids|child|children|son|daughter|mom|mother|dad|father|brother|sister|roommate|neighbor|neighbour|manager|teacher|teammate|team|client|customer|company)\\b"

    // MARK: - Fact patterns

    private static let factPatternsBySlot: [(slot: ClickyProfileSlot, patterns: [String])] = [
        (.howToAddressTheUser, [
            "^\\s*(?:please\\s+)?call\\s+(?:me|the\\s+user|them)\\b",
            "\\b(?:people|everyone|everybody|friends|they|folks)\\s+calls?\\s+me\\b",
            "\\bmy\\s+(?:first\\s+|full\\s+|preferred\\s+|real\\s+)?name(?:['’]s|\\s+is|\\s*[:=])",
            "\\b(?:the\\s+)?user['’]?s\\s+(?:first\\s+|full\\s+|preferred\\s+)?name\\b",
            "\\b(?:their|his|her)\\s+(?:first\\s+|full\\s+|preferred\\s+)?name\\s+is\\b",
            // Also the bare third-person form the model often writes: "name is helix".
            "^\\s*(?:the\\s+)?(?:preferred\\s+|first\\s+|full\\s+)?name\\s*(?:is\\b|[:=-])",
            "\\b(?:goes|go)\\s+by\\s+(?!(?:bus|car|train|bike|foot|bicycle|metro|subway|plane|taxi|tram|ferry|air|road|rail)\\b)\\w",
            "\\bbe\\s+(?:called|addressed\\s+as|referred\\s+to\\s+as)\\b",
            "\\b(?:address|refer\\s+to)\\s+(?:me|the\\s+user|them)\\s+as\\b",
            "\\b(?:i\\s*am|i['’]?m|user\\s+is)\\s+(?:called|named|known\\s+as)\\b",
            "\\bnickname\\b",
        ]),
        (.editor, [
            "\\b(?:uses?|using|prefers?|edits?\\s+(?:in|with)|codes?\\s+(?:in|with)|works?\\s+(?:in|with)|writes?\\s+(?:code\\s+)?(?:in|with)|\(switchedToPhrase))\\s+(?:the\\s+)?\(earlierListItemPattern)\(editorNamePattern)\\b(?!\\s+(?:key\\s?bindings?|mode|motions?|plugins?|extensions?|config|settings|shortcuts?|themes?))",
            "\\b(?:editor|ide)\\b\\s*(?:of\\s+choice\\s+)?(?:is|are|=|:|to|now)\\b",
            "\\b(?:as|for)\\s+(?:my|their|his|her|the\\s+user['’]?s|our)\\s+(?:main\\s+|primary\\s+|default\\s+|code\\s+|text\\s+)?(?:editor|ide)\\b",
            "\\b(?:my|their|his|her|the\\s+user['’]?s)\\s+(?:main\\s+|primary\\s+|default\\s+|favou?rite\\s+|preferred\\s+)(?:code\\s+|text\\s+)?(?:editor|ide)\\b",
        ]),
        (.indentationStyle, [
            "\\bindent(?:ation|ing|s|ed)?\\b",
            "\\btabs?\\b.{0,30}\\bspaces?\\b",
            "\\bspaces?\\b.{0,30}\\btabs?\\b",
            "\\b(?:\\d+|one|two|three|four|eight)\\s+spaces?\\b",
            "\\b(?:prefers?|uses?|wants?|likes?)\\s+(?:hard\\s+|soft\\s+)?tabs\\b",
        ]),
        (.shell, [
            "\\b(?:uses?|using|runs?|running|prefers?|\(switchedToPhrase))\\s+(?:the\\s+)?\(earlierListItemPattern)\(shellNamePattern)\\b",
            "\\b\(shellNamePattern)\\s+shell\\b",
            "\\b(?:in|on|with|under)\\s+(?:the\\s+)?\(shellNamePattern)\\b",
            "\\bshell\\s+(?:is|=|:)\\b",
            "\\b(?:as|for)\\s+(?:my|their|his|her)\\s+(?:default\\s+|login\\s+)?shell\\b",
        ]),
        (.mainLanguage, [
            "\\b(?:main|primary|favou?rite|preferred|default|usual)\\s+(?:programming\\s+|coding\\s+)?language\\b",
            "\\b(?:writes?|codes?|programs?|develops?|works?)\\s+(?:(?:mostly|mainly|primarily|only|exclusively|ever)\\s+)*(?:in\\s+|with\\s+)?\(programmingLanguageNamePattern)",
            "\\bonly\\s+(?:ever\\s+)?(?:writes?|codes?|programs?)\\s+(?:in\\s+)?\(programmingLanguageNamePattern)",
            "\\b(?:uses?|prefers?)\\s+(?:mostly\\s+|mainly\\s+|primarily\\s+|only\\s+|exclusively\\s+)\(programmingLanguageNamePattern)",
            "\\b\(switchedToPhrase)\\s+(?:writing\\s+|coding\\s+|programming\\s+)?\(programmingLanguageNamePattern)",
        ]),
        (.answerLanguage, [
            "\\b(?:answers?|repl(?:y|ies)|respond(?:s|ing)?|responses?)\\b[^.;]{0,25}?\\b(?:in\\s+)?\(spokenLanguageNamePattern)\\b",
            "\\b\(spokenLanguageNamePattern)\\s+(?:answers?|replies|responses?)\\b",
            "(?<!\\bi\\s)\\b(?:speak|talk)\\s+(?:to\\s+me\\s+)?(?:in\\s+)?\(spokenLanguageNamePattern)\\b",
        ]),
        (.answerLength, [
            "\\b(?:short|shorter|brief|briefer|concise|terse|long|longer|lengthy|detailed|verbose|simple|simpler|plain|step[\\s-]by[\\s-]step|one[\\s-]sentence|casual|formal|technical)\\s+(?:answers?|repl(?:y|ies)|responses?|explanations?)\\b",
            "\\b(?:answers?|repl(?:y|ies)|responses?|explanations?)\\s+(?:short|brief|concise|long|detailed|simple)\\b",
            "\\b(?:answers?|repl(?:y|ies)|responses?)\\s+in\\s+(?:one|two|three|a\\s+few|short|brief|\\d+)\\b",
            "\\bkeeps?\\s+(?:your\\s+|the\\s+|all\\s+)?(?:answers?|repl(?:y|ies)|responses?|explanations?)\\b",
            "\\b(?:keep|be)\\s+(?:it\\s+)?(?:short|brief|concise|terse)\\b",
            "\\b(?:less|more)\\s+detail(?:ed)?\\b",
            "\\bone[\\s-]sentence\\b",
        ]),
        (.operatingSystem, [
            "\\b(?:uses?|using|runs?|running|on|\(switchedToPhrase))\\s+(?:a\\s+|an\\s+|the\\s+)?\(earlierListItemPattern)(?:mac(?:book)?(?:\\s+pro|\\s+air)?|mac\\s?os(?:\\s+\\w+)?|windows(?:\\s+\\d+)?|linux|ubuntu|debian|fedora|chromebook|chromeos)\\b",
            "\\b(?:operating\\s+system|os)\\s+(?:is|=|:)\\b",
            "\\b(?:their|my|his|her)\\s+(?:operating\\s+system|os)\\b",
        ]),
    ]

    // MARK: - Forget target patterns

    /// What a spoken "forget my <thing>" can name. Shorter than the fact patterns because the
    /// target is a noun phrase ("my editor"), not a sentence.
    private static let forgetTargetPatternsBySlot: [(slot: ClickyProfileSlot, patterns: [String])] = [
        (.howToAddressTheUser, [
            "\\b(?:my|your|the\\s+user['’]?s)\\s+(?:first\\s+|full\\s+|preferred\\s+|real\\s+)?name\\b",
            "\\bwhat\\s+you\\s+call\\s+me\\b",
            "\\bhow\\s+you\\s+(?:call|address)\\s+me\\b",
            "\\bmy\\s+nickname\\b",
        ]),
        (.editor, ["\\b(?:editor|ide)\\b"]),
        (.indentationStyle, ["\\bindent(?:ation|ing)?\\b", "\\btabs?\\b", "\\bspaces\\b"]),
        (.shell, ["\\bshell\\b"]),
        (.mainLanguage, ["\\b(?:main|primary|favou?rite|preferred|default|programming|coding)\\s+(?:programming\\s+|coding\\s+)?language\\b"]),
        // "my answer language" names the language slot and "my answer length" or "style" the length
        // slot; a plain "my answers" names both (see `slots(forForgetTarget:)`).
        (.answerLanguage, ["\\b(?:answers?|repl(?:y|ies)|responses?)\\s+language\\b", "\\blanguage\\b[^.;]{0,20}\\b(?:answers|replies|responses)\\b"]),
        (.answerLength, ["\\b(?:answers?|repl(?:y|ies)|responses?)\\s+(?:length|style|detail|format)\\b"]),
        (.operatingSystem, ["\\boperating\\s+system\\b", "\\bos\\b", "\\bmac\\s?os\\b", "\\bwindows\\b", "\\blinux\\b"]),
    ]

    // MARK: - Lookups

    private static let answerSlots: Set<ClickyProfileSlot> = [.answerLanguage, .answerLength]

    /// Every slot a saved or new fact fills. Empty when it is about someone else, is an addition,
    /// is limited to one setting, or fits no slot.
    static func slots(forFactText factText: String) -> Set<ClickyProfileSlot> {
        if containsMatch(of: otherSubjectPattern, in: factText)
            || containsMatch(of: additiveMarkerPattern, in: factText)
            || containsMatch(of: scopeQualifierPattern, in: factText) {
            return []
        }
        return Set(factPatternsBySlot.filter { slotAndPatterns in
            slotAndPatterns.patterns.contains { containsMatch(of: $0, in: factText) }
        }.map(\.slot))
    }

    /// The slot a fact fills when it fills exactly one, otherwise nil.
    static func slot(forFactText factText: String) -> ClickyProfileSlot? {
        let matchingSlots = slots(forFactText: factText)
        return matchingSlots.count == 1 ? matchingSlots.first : nil
    }

    /// Every slot a "forget my <thing>" names. A plain "my answers" names both answer slots.
    static func slots(forForgetTarget forgetTargetText: String) -> Set<ClickyProfileSlot> {
        if containsMatch(of: otherSubjectPattern, in: forgetTargetText) {
            return []
        }
        var namedSlots = Set(forgetTargetPatternsBySlot.filter { slotAndPatterns in
            slotAndPatterns.patterns.contains { containsMatch(of: $0, in: forgetTargetText) }
        }.map(\.slot))
        if namedSlots.isDisjoint(with: answerSlots),
           containsMatch(of: "\\b(?:answers?|repl(?:y|ies)|responses?)\\b", in: forgetTargetText) {
            namedSlots.formUnion(answerSlots)
        }
        return namedSlots
    }

    /// The slot a forget target names when it names exactly one, otherwise nil.
    static func slot(forForgetTarget forgetTargetText: String) -> ClickyProfileSlot? {
        let matchingSlots = slots(forForgetTarget: forgetTargetText)
        return matchingSlots.count == 1 ? matchingSlots.first : nil
    }

    /// How many different things a forget target names. The two answer slots count as one
    /// ("my answers"), so only targets like "my editor and shell" count as several.
    static func numberOfDifferentThingsNamed(byForgetTarget forgetTargetText: String) -> Int {
        let namedSlots = slots(forForgetTarget: forgetTargetText)
        let hasAnswerSlot = !namedSlots.isDisjoint(with: answerSlots)
        return namedSlots.subtracting(answerSlots).count + (hasAnswerSlot ? 1 : 0)
    }

    /// True when a new fact is allowed to replace older ones. A fact worded with a strength word
    /// ("mostly uses windows") is saved next to the plain fact instead.
    static func factMayReplaceOlderFacts(_ newFactText: String) -> Bool {
        !containsMatch(of: strengthQualifierPattern, in: newFactText)
    }

    /// True when the newer fact should replace the older one: the new fact may replace, fills at
    /// least one slot, and the older fact fills only slots that the new fact fills too. An older
    /// fact with an extra slot ("uses zsh and vim" against a new "uses fish") stays, so nothing
    /// the user said is lost, and the newer line wins by order.
    static func newFactReplacesOlderFact(newFactText: String, olderFactText: String) -> Bool {
        guard factMayReplaceOlderFacts(newFactText) else {
            return false
        }
        let newFactSlots = slots(forFactText: newFactText)
        let olderFactSlots = slots(forFactText: olderFactText)
        return !newFactSlots.isEmpty && !olderFactSlots.isEmpty && olderFactSlots.isSubset(of: newFactSlots)
    }

    /// True when both facts fill the same single slot.
    static func factsFillTheSameSlot(_ firstFactText: String, _ secondFactText: String) -> Bool {
        guard let firstSlot = slot(forFactText: firstFactText) else {
            return false
        }
        return firstSlot == slot(forFactText: secondFactText)
    }

    private static func containsMatch(of pattern: String, in text: String) -> Bool {
        guard let patternRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        return patternRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
