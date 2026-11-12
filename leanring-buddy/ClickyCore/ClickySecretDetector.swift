import Foundation

/// Decides whether a piece of text looks like a secret, so it is never written to the profile or
/// the daily notes. It is applied to every save path (profile tags, note tags, and the dictated
/// note fallback), both to what the user said and to the text the model wants to save.
///
/// The detector refuses on a VALUE, not on a topic. "my password is hunter2" is refused;
/// "i changed my password yesterday", "i use a password manager" and "the pin for the meeting room
/// is on the door" are ordinary notes and are kept. Two kinds of evidence are used:
/// - A secret keyword ("password", "pin", "api key", "door code", "combination", ...) followed by a
///   value: after "is", "are", "was", ":", "=" or "-", or directly when the value looks like a code.
///   A short list of benign values (weak, expired, saved in the manager, on the sticky note, ...)
///   is not a value.
/// - Credential shapes that are secret whatever the wording: provider keys, tokens, private-key
///   headers, IBANs, card numbers that pass the Luhn check, social security numbers, long
///   random-looking strings, and keys read out letter by letter or digit by digit.
///
/// A false refusal is the safe failure: the user hears "i won't keep that" and can say the
/// non-secret part again. A false acceptance writes a password to a plain text file.
nonisolated enum ClickySecretDetector {
    // MARK: - Keywords that need a value

    /// What must follow a keyword for the text to count as a secret.
    private enum SecretValueRequirement {
        /// Any value that is not benign: "the root pw is toor".
        case anyValue
        /// A value that looks like a code or token ("abc123def", "4471"). Used for words that are
        /// also ordinary nouns ("key", "token", "secret", "pass"), so "the key is under the mat"
        /// and "the pass is open" stay ordinary.
        case credentialLookingToken
        /// A user name and password pair: "root slash toor", "root/toor", "sam and hunter2".
        case loginLikeValue
        /// A value that contains a digit, such as a lock combination ("10 20 30"). "the combination
        /// of vim and tmux is great" is not one.
        case valueWithDigits
    }

    private struct SecretKeywordRule {
        let keywordPattern: String
        let valueRequirement: SecretValueRequirement
    }

    private static let secretKeywordRules: [SecretKeywordRule] = [
        // Passwords and pass codes.
        SecretKeywordRule(keywordPattern: #"pass\s?words?|pass\s?codes?|pass\s?phrases?|passwd|pwd|pw"#, valueRequirement: .anyValue),
        // PINs. "pin code" and "pin number" read the same as "pin".
        SecretKeywordRule(keywordPattern: #"pin(?:\s+(?:codes?|numbers?))?"#, valueRequirement: .anyValue),
        // Door, alarm, gate, safe, garage and similar codes and combinations.
        SecretKeywordRule(keywordPattern: #"(?:door|gate|alarm|safe|garage|locker|padlock|vault|keypad|entry|building|lock|front\s+door|wifi|wi-fi|house|apartment|office|shed|gym)\s+(?:codes?|combinations?|combos?|pass\s?codes?|pins?)"#, valueRequirement: .anyValue),
        // "the code to get into the building", "the code for the shed". "key combination" is a
        // keyboard shortcut, not a lock.
        SecretKeywordRule(keywordPattern: #"codes?\s+(?:to|for|of)\s+(?:get(?:ting)?\s+(?:in|into|inside)\s+|enter(?:ing)?\s+|open(?:ing)?\s+|unlock(?:ing)?\s+|access(?:ing)?\s+)?(?:the|my|our|a)\s+(?:\w+\s+)?(?:door|gate|safe|alarm|garage|locker|lock|padlock|vault|building|house|apartment|office|shed|gym|phone|laptop|card|bank|account|wifi|wi-fi|router)"#, valueRequirement: .anyValue),
        SecretKeywordRule(keywordPattern: #"(?<!key\s)(?<!keyboard\s)(?<!shortcut\s)(?<!button\s)combinations?"#, valueRequirement: .valueWithDigits),
        // "the garage opens with 1234": the value comes right after "opens with".
        SecretKeywordRule(keywordPattern: #"(?:door|gate|garage|safe|alarm|lock|building|locker|padlock|vault|house|shed)\s+(?:opens?|unlocks?|opened|unlocked)\s+with"#, valueRequirement: .credentialLookingToken),
        // Keys and tokens with a qualifier that makes them secret.
        SecretKeywordRule(keywordPattern: #"(?:api|secret|private|ssh|signing|encryption|access|auth|authentication|bearer|refresh|session|license|licence|product|activation|serial|wifi|wi-fi|wpa|master|recovery|backup)\s+(?:keys?|tokens?)|api[_-]?keys?|client\s+secret"#, valueRequirement: .anyValue),
        // Codes that unlock or verify something.
        SecretKeywordRule(keywordPattern: #"(?:security|verification|unlock|activation|confirmation|recovery|backup|login|sign[\s-]?in|one[\s-]time|2fa|two[\s-]factor|access)\s+(?:codes?|phrases?)|otp"#, valueRequirement: .anyValue),
        // Recovery and seed phrases.
        SecretKeywordRule(keywordPattern: #"(?:seed|recovery|backup|secret)\s+(?:phrases?|words?)|mnemonic|wallet\s+(?:seed|keys?|phrases?|passwords?)"#, valueRequirement: .anyValue),
        // Security questions and their answers.
        SecretKeywordRule(keywordPattern: #"maiden\s+name|security\s+(?:question\s+)?answers?|(?:first|childhood)\s+pet['’]?s?\s+name|name\s+of\s+my\s+(?:first|childhood)\s+pet"#, valueRequirement: .anyValue),
        // Payment and identity numbers.
        SecretKeywordRule(keywordPattern: #"card\s+number|cvv|cvc|ssn|social(?:\s+security)?(?:\s+number)?|account\s+numbers?|iban|routing\s+number|sort\s+code|(?:passport|driver['’]?s?\s+licen[sc]e|tax\s+id|tax\s+file|national\s+insurance|national\s+id)\s+(?:number|no\.?|id)"#, valueRequirement: .anyValue),
        SecretKeywordRule(keywordPattern: #"credentials?"#, valueRequirement: .anyValue),
        // Plain nouns that are secret only when the value looks like a code.
        SecretKeywordRule(keywordPattern: #"pass|keys?|tokens?|secret"#, valueRequirement: .credentialLookingToken),
        SecretKeywordRule(keywordPattern: #"logins?"#, valueRequirement: .loginLikeValue),
    ]

    /// Values that follow a keyword but are not a secret because they say where the secret is kept
    /// or what is being done with it: "in the safe", "on the sticky note", "with the manager".
    /// A value that starts this way is never a secret, however long it is.
    private static let benignPlacementStartPattern = #"^(?:in|on|under|behind|beside|near|inside|outside|at|by|from|for|to|with|via|through|within|across|above|below|next\s+to|saved|stored|kept|managed|handled|documented|described|explained|listed|synced|syncing|used\s+for|required\s+for|needed\s+for|set\s+to\s+expire|supposed|going|getting|being)\b"#

    /// Short descriptions of a secret rather than the secret: "weak", "expired", "too short". They
    /// count as benign only when they are all of the value, or are followed by a joining word
    /// ("weak and too short"). A longer value that merely starts with one ("correct horse battery
    /// staple") is a pass phrase.
    private static let benignDescriptionStartPattern = #"^(?:weak|strong|too\s+(?:short|long|simple|weak|easy|obvious)|expired|expiring|changing|changed|reset|resetting|compromised|leaked|available|missing|blank|empty|null|none|unset|required|optional|needed|due|overdue|wrong|incorrect|invalid|correct|fine|ok|okay|hard|easy|long|short|simple|complex|secure|insecure|good|bad|great|nice|awesome|boring|fun|busy|quiet|important|popular|open|closed|blocked|clear|steep|high|narrow|a\s+secret|the\s+same|same|different|old|n/a|unknown|private|public|shared|hidden|visible|lost|forgotten|pending|rotated|rotating|updated|updating|working|broken|slow|down|up|stuck|locked|disabled|enabled|active|inactive|too|very|really|so|quite|pretty|not)\b"#

    /// Words that join a description to more description: "weak and too short", "expired so i reset it".
    private static let benignDescriptionConnectors: Set<String> = [
        "and", "but", "because", "so", "too", "enough", "now", "again", "yet", "since", "if", "when", "until", "for", "in", "on", "at", "to", "by", "anyway",
    ]

    // MARK: - Shapes that are secret whatever the wording

    private static let alwaysSecretShapePatterns: [String] = [
        // Anthropic and OpenAI style keys: sk-ant-..., sk-proj-...
        #"\bsk-[A-Za-z0-9_\-]{6,}"#,
        // Payment provider keys: pk_live_..., rk_test_...
        #"\b(?:pk|rk)_(?:live|test)_[A-Za-z0-9]{6,}"#,
        // GitHub and Slack tokens.
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{10,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{10,}"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{6,}"#,
        // AWS and Google keys.
        #"\bAKIA[0-9A-Z]{12,}"#,
        #"\bAIza[0-9A-Za-z_\-]{16,}"#,
        // JSON web tokens.
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}"#,
        // PEM private keys.
        #"-----BEGIN[A-Z ]*PRIVATE KEY-----"#,
        // Long hexadecimal strings, such as hashes used as secrets.
        #"\b[0-9a-fA-F]{32,}\b"#,
        // Any long single token that mixes letters and digits.
        #"\b(?=[A-Za-z0-9_\-]*[0-9])(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}\b"#,
        // Social security numbers written with dashes or spaces.
        #"\b\d{3}[ -]\d{2}[ -]\d{4}\b"#,
        // Keys read out digit by digit ("one two three four five six seven eight") or letter by
        // letter ("a b c d e f g h"), and the start of a dictated provider key ("s k dash ...").
        #"(?:\b(?:zero|one|two|three|four|five|six|seven|eight|nine)\b[\s,.\-]*){8,}"#,
        #"(?:\b[a-z]\b[\s,.\-]+){7,}\b[a-z]\b"#,
        #"\bs\s*k\s+(?:dash|hyphen|minus)\b"#,
        #"\bg\s*h\s*p\s+(?:underscore|dash)\b"#,
    ]

    /// Shapes that depend on upper and lower case: a long base64-looking token has both, plus a digit.
    private static let caseSensitiveSecretShapePatterns: [String] = [
        #"(?=[A-Za-z0-9+/_\-]*[A-Z])(?=[A-Za-z0-9+/_\-]*[a-z])(?=[A-Za-z0-9+/_\-]*\d)[A-Za-z0-9+/_\-]{32,}={0,2}"#,
    ]

    /// An IBAN: two letters, two check digits, then up to 30 letters or digits, written together
    /// or in groups of four. Matches are then checked for length and digit count so an ordinary
    /// word followed by a number is not mistaken for one.
    private static let ibanShapePattern = #"\b[A-Za-z]{2}\d{2}(?:[ ]?[A-Za-z0-9]{4}){2,7}(?:[ ]?[A-Za-z0-9]{1,4})?\b"#

    /// Digit runs that could be a card number: 13 to 19 digits, single spaces or dashes allowed
    /// between them.
    private static let cardLikeDigitRunPattern = #"\b(?:\d[ -]?){12,18}\d\b"#

    // MARK: - Public checks

    static func textLooksLikeASecret(_ text: String) -> Bool {
        for secretShapePattern in alwaysSecretShapePatterns where containsMatch(of: secretShapePattern, in: text) {
            return true
        }
        for secretShapePattern in caseSensitiveSecretShapePatterns where containsMatch(of: secretShapePattern, in: text, isCaseSensitive: true) {
            return true
        }
        if containsIBANShape(in: text) || containsLuhnValidCardNumber(in: text) {
            return true
        }
        return secretKeywordRules.contains { keywordIsFollowedBySecretValue($0, in: text) }
    }

    /// The shape rules alone, for the text of a file (round 17). The keyword-plus-value rules
    /// (`secretKeywordRules`) were tuned for spoken sentences and would flag ordinary source lines
    /// such as `let appTokenHeaderName = "X-Clicky-App-Token"`, so they are left out here. What is
    /// left is what a credential looks like whatever the wording around it: provider key shapes,
    /// JWTs, private key blocks, long hex or base64 tokens, Luhn-valid card numbers and IBANs.
    /// `textLooksLikeASecret` is unchanged and still runs these same shape rules first.
    static func textHoldsCredentialShape(_ text: String) -> Bool {
        for secretShapePattern in alwaysSecretShapePatterns where containsMatch(of: secretShapePattern, in: text) {
            return true
        }
        for secretShapePattern in caseSensitiveSecretShapePatterns where containsMatch(of: secretShapePattern, in: text, isCaseSensitive: true) {
            return true
        }
        return containsIBANShape(in: text) || containsLuhnValidCardNumber(in: text)
    }

    /// A card number has a known first digit and a Luhn checksum. Requiring both keeps long numbers
    /// that are not cards (a timestamp, an order or employee id) from being refused, while a real
    /// card number is still caught, with or without spaces or dashes.
    static func containsLuhnValidCardNumber(in text: String) -> Bool {
        guard let digitRunRegex = try? NSRegularExpression(pattern: cardLikeDigitRunPattern) else {
            return false
        }
        let textRange = NSRange(text.startIndex..., in: text)
        for digitRunMatch in digitRunRegex.matches(in: text, range: textRange) {
            guard let digitRunRange = Range(digitRunMatch.range, in: text) else {
                continue
            }
            let digitsOnly = String(text[digitRunRange]).filter(\.isNumber)
            let firstDigitCouldStartACard = "23456".contains(digitsOnly.first ?? "0")
            if (13...19).contains(digitsOnly.count), firstDigitCouldStartACard, passesLuhnCheck(digitsOnly) {
                return true
            }
        }
        return false
    }

    /// The Luhn checksum: starting from the right, double every second digit (subtracting 9 when
    /// the result is above 9), and the total must be a multiple of 10.
    static func passesLuhnCheck(_ digitsOnly: String) -> Bool {
        var runningTotal = 0
        var shouldDoubleThisDigit = false
        for digitCharacter in digitsOnly.reversed() {
            guard let digitValue = digitCharacter.wholeNumberValue else {
                return false
            }
            var valueToAdd = digitValue
            if shouldDoubleThisDigit {
                valueToAdd *= 2
                if valueToAdd > 9 {
                    valueToAdd -= 9
                }
            }
            runningTotal += valueToAdd
            shouldDoubleThisDigit.toggle()
        }
        return !digitsOnly.isEmpty && runningTotal % 10 == 0
    }

    // MARK: - IBAN

    private static func containsIBANShape(in text: String) -> Bool {
        guard let ibanRegex = try? NSRegularExpression(pattern: ibanShapePattern) else {
            return false
        }
        for ibanMatch in ibanRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let ibanRange = Range(ibanMatch.range, in: text) else {
                continue
            }
            let compactCandidate = String(text[ibanRange]).filter { !$0.isWhitespace }
            let digitCount = compactCandidate.filter(\.isNumber).count
            if (15...34).contains(compactCandidate.count), digitCount >= 6 {
                return true
            }
        }
        return false
    }

    // MARK: - Keyword followed by a value

    private static func keywordIsFollowedBySecretValue(_ rule: SecretKeywordRule, in text: String) -> Bool {
        guard let keywordRegex = try? NSRegularExpression(
            pattern: #"\b(?:"# + rule.keywordPattern + #")\b"#,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        for keywordMatch in keywordRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let keywordRange = Range(keywordMatch.range, in: text) else {
                continue
            }
            let clauseTail = clauseText(startingAt: keywordRange.upperBound, in: text)
            if clauseTailHoldsSecretValue(clauseTail, requirement: rule.valueRequirement) {
                return true
            }
        }
        return false
    }

    /// The text from the end of the keyword to the end of its sentence.
    private static func clauseText(startingAt startIndex: String.Index, in text: String) -> String {
        var clauseEndIndex = text.endIndex
        var characterIndex = startIndex
        while characterIndex < text.endIndex {
            let character = text[characterIndex]
            let nextIndex = text.index(after: characterIndex)
            let isSentenceEnd = character == ";" || character == "!" || character == "?" || character == "\n"
                || (character == "." && (nextIndex == text.endIndex || text[nextIndex].isWhitespace))
            if isSentenceEnd {
                clauseEndIndex = characterIndex
                break
            }
            characterIndex = nextIndex
        }
        return String(text[startIndex..<clauseEndIndex])
    }

    /// "is hunter2", ": hunter2", "= hunter2", "- hunter2", "for the cabin is pine42". A short
    /// prepositional phrase may sit between the keyword and "is" ("the pin for my card is 4821").
    private static let valueAfterSeparatorPattern = #"^(?:\s+(?:for|to|on|of|at|in|from)\s+(?:the\s+|my\s+|our\s+|a\s+|an\s+)?[\w'’-]+(?:\s+[\w'’-]+){0,2}?)?(?:(?:\s+(?:is|are|was|were|will\s+be)\b|['’]s\b)\s*[:=-]?\s*|\s*[:=]\s*|\s*[-–—]\s+)(.+)$"#

    private static func clauseTailHoldsSecretValue(_ clauseTail: String, requirement: SecretValueRequirement) -> Bool {
        if let separatorRegex = try? NSRegularExpression(pattern: valueAfterSeparatorPattern, options: [.caseInsensitive]),
           let separatorMatch = separatorRegex.firstMatch(in: clauseTail, range: NSRange(clauseTail.startIndex..., in: clauseTail)),
           let valueRange = Range(separatorMatch.range(at: 1), in: clauseTail) {
            return valueIsASecret(String(clauseTail[valueRange]), requirement: requirement)
        }

        // No "is": the keyword is directly followed by something that looks like a code ("pin 4471").
        let tailWords = clauseTail.split(whereSeparator: { $0.isWhitespace })
        guard clauseTail.first?.isWhitespace == true, let firstWord = tailWords.first else {
            return false
        }
        if requirement == .valueWithDigits {
            return firstWord.contains(where: \.isNumber)
        }
        return tokenLooksLikeACredential(String(firstWord))
    }

    private static func valueIsASecret(_ rawValueText: String, requirement: SecretValueRequirement) -> Bool {
        let valueText = rawValueText.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n.,;:!?\"'()[]"))
        guard valueText.contains(where: { $0.isLetter || $0.isNumber }) else {
            return false
        }
        let valueWords = valueText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if containsMatch(of: benignPlacementStartPattern, in: valueText) {
            return false
        }
        if containsMatch(of: benignDescriptionStartPattern, in: valueText) {
            let secondWord = valueWords.count > 1 ? valueWords[1].lowercased() : nil
            if valueWords.count <= 2 || (secondWord.map { benignDescriptionConnectors.contains($0) } ?? false) {
                return false
            }
        }
        // "reviewed weekly", "audited quarterly": what is done to the secret, not the secret.
        if let firstValueWord = valueWords.first, valueWords.count >= 2,
           firstValueWord.count >= 5, firstValueWord.lowercased().hasSuffix("ed") {
            return false
        }

        switch requirement {
        case .anyValue:
            return true
        case .credentialLookingToken:
            return tokenLooksLikeACredential(valueWords.first ?? "")
        case .loginLikeValue:
            return valueLooksLikeALogin(valueText)
        case .valueWithDigits:
            return valueText.contains(where: \.isNumber)
        }
    }

    /// "root slash toor", "root/toor", "sam:hunter2", "sam and my password", or a code-like token.
    private static func valueLooksLikeALogin(_ valueText: String) -> Bool {
        if valueText.contains("/") || valueText.contains(":") {
            return true
        }
        if containsMatch(of: #"\b(?:slash|colon|dash)\b"#, in: valueText) {
            return true
        }
        if containsMatch(of: #"\band\s+(?:the\s+|my\s+)?(?:pass|password|pw)\b"#, in: valueText) {
            return true
        }
        return valueText.split(whereSeparator: { $0.isWhitespace }).contains { tokenLooksLikeACredential(String($0)) }
    }

    /// A token that looks like a code rather than a word: four or more digits ("4471"), letters
    /// mixed with a digit ("hunter2"), or a long token with mixed case and a digit or separator.
    private static func tokenLooksLikeACredential(_ rawToken: String) -> Bool {
        let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]"))
        let digitCount = token.filter(\.isNumber).count
        let letterCount = token.filter(\.isLetter).count
        if digitCount >= 4 {
            return true
        }
        if digitCount >= 1 && letterCount >= 1 && token.count >= 4 {
            return true
        }
        let hasUppercase = token.contains(where: \.isUppercase)
        let hasLowercase = token.contains(where: \.isLowercase)
        let hasSeparatorOrDigit = digitCount >= 1 || token.contains("_") || token.contains("-")
        return token.count >= 10 && hasUppercase && hasLowercase && hasSeparatorOrDigit
    }

    private static func containsMatch(of pattern: String, in text: String, isCaseSensitive: Bool = false) -> Bool {
        let regexOptions: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
        guard let patternRegex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else {
            return false
        }
        return patternRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
