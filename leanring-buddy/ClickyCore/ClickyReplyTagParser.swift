import Foundation

/// Where Claude asked the blue cursor to point. Coordinates are pixels of the labeled screenshot,
/// with the origin at the top-left corner of that image.
nonisolated struct ClickyPointTarget: Equatable {
    let x: Double
    let y: Double
    let label: String?
    /// 1-based screen number from the image label. nil means the cursor's own screen.
    let screenNumber: Int?
}

nonisolated struct ClickyParsedReply: Equatable {
    /// Text that is safe to hand to text-to-speech: no tags and no stray punctuation left behind by removed tags.
    let spokenText: String
    let pointTarget: ClickyPointTarget?
    let noteTexts: [String]
    /// Facts Claude wants to add to the user's profile. These are only candidates: the turn
    /// finisher saves them only if the user's own words allow it.
    let profileTexts: [String]
    /// [NOTE:] and [PROFILE:] tags that held no text. They save nothing, but the model may still
    /// have said it would remember, so the turn finisher needs to know they were written.
    let emptyMemoryTagCount: Int
}

/// Parses the bracketed tags Claude embeds in its replies: [POINT:...], [NOTE:...] and [PROFILE:...].
/// The chat pipeline and the onboarding demo both use this one grammar so they cannot drift apart.
nonisolated enum ClickyReplyTagParser {
    /// Notes are stored as single lines, so a longer note is cut here instead of being rejected.
    static let maximumNoteTagCountPerReply = 3

    /// A profile is tiny and always sent, so a reply can add at most two facts, each cut to 200 characters.
    static let maximumProfileTagCountPerReply = 2

    static func parse(_ rawReplyText: String) -> ClickyParsedReply {
        // Group 1 is the tag name, group 2 is everything after the colon. Brackets are excluded from
        // the body so one tag can never swallow the next tag.
        let completeTagRegex = try! NSRegularExpression(
            pattern: "\\[\\s*(POINT|NOTE|PROFILE)\\s*:([^\\[\\]]*)\\]",
            options: [.caseInsensitive]
        )

        let completeTagMatches = completeTagRegex.matches(in: rawReplyText, range: fullRange(of: rawReplyText))
        var lastPointTagBody: String?
        var noteTexts: [String] = []
        var profileTexts: [String] = []
        var emptyMemoryTagCount = 0

        for completeTagMatch in completeTagMatches {
            let tagName = substring(of: rawReplyText, range: completeTagMatch.range(at: 1)).uppercased()
            let tagBody = substring(of: rawReplyText, range: completeTagMatch.range(at: 2))
            if tagName == "POINT" {
                // If the model writes several POINT tags, the last one is the one it meant to end on.
                lastPointTagBody = tagBody
            } else if tagName == "NOTE", noteTexts.count < maximumNoteTagCountPerReply {
                let normalizedNoteText = ClickyNoteStore.normalizedSingleLineNoteText(tagBody)
                if normalizedNoteText.isEmpty {
                    emptyMemoryTagCount += 1
                } else {
                    noteTexts.append(normalizedNoteText)
                }
            } else if tagName == "PROFILE", profileTexts.count < maximumProfileTagCountPerReply {
                let normalizedProfileFactText = ClickyProfileStore.normalizedSingleLineFactText(tagBody)
                if normalizedProfileFactText.isEmpty {
                    emptyMemoryTagCount += 1
                } else {
                    profileTexts.append(normalizedProfileFactText)
                }
            }
        }

        // Every complete tag is removed from the spoken text, including NOTE and PROFILE tags past
        // their caps, so tag text is never read aloud.
        var spokenText = replacing(completeTagRegex, in: rawReplyText, with: " ")

        // A reply cut off by the token limit can end inside a tag, such as "[POINT:12,". Any
        // unclosed bracket at the very end is that fragment, so it is dropped before speaking.
        let truncatedTagFragmentRegex = try! NSRegularExpression(pattern: "\\[[^\\]]*\\z")
        spokenText = replacing(truncatedTagFragmentRegex, in: spokenText, with: " ")

        // Removing a tag can leave "button ." or "button. ." behind, which the voice would pause on.
        let spaceBeforePunctuationRegex = try! NSRegularExpression(pattern: "\\s+([.,!?;:])")
        spokenText = replacing(spaceBeforePunctuationRegex, in: spokenText, with: "$1")
        let repeatedSentencePunctuationRegex = try! NSRegularExpression(pattern: "([.!?])(?:\\s*[.!?,;:])+")
        spokenText = replacing(repeatedSentencePunctuationRegex, in: spokenText, with: "$1")

        let whitespaceRunRegex = try! NSRegularExpression(pattern: "\\s+")
        spokenText = replacing(whitespaceRunRegex, in: spokenText, with: " ")
        spokenText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A reply that was only a tag and a period would otherwise speak a lone ".".
        if !spokenText.contains(where: { $0.isLetter || $0.isNumber }) {
            spokenText = ""
        }

        let pointTarget = lastPointTagBody.flatMap { pointTarget(fromTagBody: $0) }
        return ClickyParsedReply(spokenText: spokenText, pointTarget: pointTarget, noteTexts: noteTexts, profileTexts: profileTexts, emptyMemoryTagCount: emptyMemoryTagCount)
    }

    /// Reads the body of one POINT tag, such as "120,40:save button:screen2".
    /// Returns nil for [POINT:none] and for bodies whose coordinates cannot be read.
    private static func pointTarget(fromTagBody tagBody: String) -> ClickyPointTarget? {
        let colonSeparatedComponents = tagBody
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let coordinateComponent = colonSeparatedComponents.first,
              coordinateComponent.lowercased() != "none" else {
            return nil
        }

        let coordinateStrings = coordinateComponent
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard coordinateStrings.count == 2,
              let x = Double(coordinateStrings[0]),
              let y = Double(coordinateStrings[1]),
              x.isFinite,
              y.isFinite else {
            return nil
        }

        // Everything after the coordinates is either a "screenN" suffix or part of the label.
        // The label may itself contain colons, so the label parts are rejoined.
        var parsedScreenNumber: Int?
        var labelComponents: [String] = []
        for trailingComponent in colonSeparatedComponents.dropFirst() where !trailingComponent.isEmpty {
            if let screenNumberFromComponent = screenNumber(fromComponent: trailingComponent) {
                parsedScreenNumber = screenNumberFromComponent
            } else {
                labelComponents.append(trailingComponent)
            }
        }
        let labelText = labelComponents.joined(separator: ":")
        return ClickyPointTarget(
            x: x,
            y: y,
            label: labelText.isEmpty ? nil : labelText,
            screenNumber: parsedScreenNumber
        )
    }

    /// Reads a "screen2" or "screen 2" suffix and returns the screen number.
    private static func screenNumber(fromComponent component: String) -> Int? {
        let screenNumberRegex = try! NSRegularExpression(
            pattern: "^screen\\s*(\\d+)$",
            options: [.caseInsensitive]
        )
        guard let screenNumberMatch = screenNumberRegex.firstMatch(in: component, range: fullRange(of: component)) else {
            return nil
        }
        return Int(substring(of: component, range: screenNumberMatch.range(at: 1)))
    }

    private static func fullRange(of text: String) -> NSRange {
        NSRange(text.startIndex..., in: text)
    }

    private static func substring(of text: String, range: NSRange) -> String {
        guard let swiftRange = Range(range, in: text) else {
            return ""
        }
        return String(text[swiftRange])
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: fullRange(of: text), withTemplate: template)
    }
}
