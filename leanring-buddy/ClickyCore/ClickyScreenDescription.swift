import Foundation

// Which screen an exchange was about, in words, and what Clicky tells the model when the screen
// is not the one the earlier messages were about.
//
// Clicky keeps the conversation as text and sends only the current screenshots, so after the user
// switches tab, window or app the model used to apologise for (or remark on) the switch. The
// fix is to record the screen of every exchange, compare it with the screen now, and add a short
// note to the per-turn prompt block when they differ. Everything here is pure: the window title
// is read elsewhere (`ClickyChatProjectContextReader`) and the note is placed by
// `ClickyPromptAssembler`.

/// The screen a turn happened on: the app and the title of its frontmost window. The title is
/// already cleaned (see `ClickyWindowTitleText`); it is nil for an app that has no window title or
/// when the title could not be read. Stored with each chat exchange, so it is Codable.
nonisolated struct ClickyScreenDescription: Codable, Equatable {
    let applicationName: String
    let windowTitle: String?

    /// The description of a screen from what was read, with the same cleaning for every user of
    /// it (the prompt line, the note, the comparison and the chat file). nil when the app's name is
    /// unknown, because a screen with no app cannot be compared with anything.
    static func describing(applicationName: String?, rawWindowTitle: String?) -> ClickyScreenDescription? {
        guard let cleanedApplicationName = ClickyWindowTitleText.cleanedApplicationName(from: applicationName) else {
            return nil
        }
        return ClickyScreenDescription(
            applicationName: cleanedApplicationName,
            windowTitle: ClickyWindowTitleText.cleanedWindowTitle(from: rawWindowTitle)
        )
    }
}

/// How a window title (or an app name) is made safe to put in the prompt. A window title is text
/// that a web page, a document or a terminal chose, shown on screen but not written by the user,
/// so it is treated as untrusted: one line, no square brackets (a title cannot spell out a reply
/// tag such as `[POINT:...]`), no straight double quotes (it is quoted when it is shown), and at
/// most 80 characters.
nonisolated enum ClickyWindowTitleText {
    static let maximumWindowTitleCharacterCount = 80
    static let maximumApplicationNameCharacterCount = 60

    /// Marks that say a document has unsaved changes. They change while the user types, without
    /// the screen changing, so they are dropped before titles are shown or compared. Only these,
    /// only at the edge of the title: a dash in the middle ("samsto — zsh — 110x34") stays.
    ///   - a trailing " — Edited", " – Edited" or " - Edited" (macOS document windows), any case;
    ///   - a leading "• ", "● " or "* ", and a trailing " •" or " ●" (editors that mark a changed file).
    static let trailingEditedSuffixes = [" — Edited", " – Edited", " - Edited", " •", " ●"]
    static let leadingEditedPrefixes = ["• ", "● ", "* "]

    /// The title as it may enter the prompt and the chat file: one line, no square brackets, inner
    /// double quotes turned into single quotes, edited markers dropped, cut to 80 characters (the
    /// last of them an ellipsis when it was cut). nil when nothing is left. Running it on its own
    /// output changes nothing, so every place that needs the clean title can call it.
    static func cleanedWindowTitle(from rawWindowTitle: String?) -> String? {
        guard let rawWindowTitle else { return nil }
        var cleanedTitle = singleLineWithoutBracketsOrDoubleQuotes(rawWindowTitle)
        cleanedTitle = droppingEditedMarkers(from: cleanedTitle)
        cleanedTitle = cut(cleanedTitle, toCharacterCount: maximumWindowTitleCharacterCount)
        return cleanedTitle.isEmpty ? nil : cleanedTitle
    }

    /// Whether a raw title carries one of the edited markers above (round 17: a file open in an
    /// editor with unsaved changes). It reads the same markers `cleanedWindowTitle` drops, so the two
    /// can never disagree about what counts as a marker.
    static func titleCarriesEditedMarker(_ rawWindowTitle: String?) -> Bool {
        guard let rawWindowTitle else { return false }
        let titleBeforeDroppingMarkers = singleLineWithoutBracketsOrDoubleQuotes(rawWindowTitle)
        return droppingEditedMarkers(from: titleBeforeDroppingMarkers) != titleBeforeDroppingMarkers
    }

    /// An app name gets the same cleaning, without the edited markers.
    static func cleanedApplicationName(from rawApplicationName: String?) -> String? {
        guard let rawApplicationName else { return nil }
        let cleanedName = cut(
            singleLineWithoutBracketsOrDoubleQuotes(rawApplicationName),
            toCharacterCount: maximumApplicationNameCharacterCount
        )
        return cleanedName.isEmpty ? nil : cleanedName
    }

    /// A clean title in double quotes, for the prompt.
    static func quoted(_ cleanedText: String) -> String {
        "\"\(cleanedText)\""
    }

    // MARK: - Steps

    /// Every kind of whitespace, line break and control character becomes one space, square
    /// brackets are removed, straight double quotes become single quotes, and the result is trimmed.
    private static func singleLineWithoutBracketsOrDoubleQuotes(_ text: String) -> String {
        var cleanedScalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "[" || scalar == "]" {
                continue
            }
            if scalar == "\"" {
                cleanedScalars.append("'")
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                cleanedScalars.append(" ")
            } else {
                cleanedScalars.append(scalar)
            }
        }
        let wordsOfText = String(cleanedScalars).split(separator: " ", omittingEmptySubsequences: true)
        return wordsOfText.joined(separator: " ")
    }

    /// Takes the edited markers off both ends, again and again until none is left ("• file — Edited").
    private static func droppingEditedMarkers(from title: String) -> String {
        var titleWithoutMarkers = title
        var droppedAMarker = true
        while droppedAMarker {
            droppedAMarker = false
            for trailingSuffix in trailingEditedSuffixes {
                if let trailingSuffixRange = titleWithoutMarkers.range(of: trailingSuffix, options: [.caseInsensitive, .anchored, .backwards]) {
                    titleWithoutMarkers.removeSubrange(trailingSuffixRange)
                    titleWithoutMarkers = titleWithoutMarkers.trimmingCharacters(in: .whitespaces)
                    droppedAMarker = true
                }
            }
            for leadingPrefix in leadingEditedPrefixes where titleWithoutMarkers.hasPrefix(leadingPrefix) {
                titleWithoutMarkers = String(titleWithoutMarkers.dropFirst(leadingPrefix.count))
                    .trimmingCharacters(in: .whitespaces)
                droppedAMarker = true
            }
            // A title that is only a marker ("•", "●", "*") has no word after it for the prefix
            // rule to see.
            if ["•", "●", "*"].contains(titleWithoutMarkers) {
                titleWithoutMarkers = ""
                droppedAMarker = true
            }
        }
        return titleWithoutMarkers
    }

    /// At most `maximumCharacterCount` characters; when text is cut, the last character is an
    /// ellipsis so the model can tell the title goes on. A cut text is never longer than the limit
    /// and cutting it again changes nothing.
    private static func cut(_ text: String, toCharacterCount maximumCharacterCount: Int) -> String {
        guard text.count > maximumCharacterCount else { return text }
        let textBeforeEllipsis = String(text.prefix(maximumCharacterCount - 1))
            .trimmingCharacters(in: .whitespaces)
        return textBeforeEllipsis + "…"
    }
}

/// Whether the screen is not the one the earlier messages were about, and the note that tells the
/// model so.
nonisolated enum ClickyScreenChange {
    /// True only when both screens are known and they differ: another app, or the same app with
    /// another window title. Two cases are deliberately not a change:
    ///   - an unknown screen on either side (a chat from before screens were recorded, or an app
    ///     name that could not be read): there is nothing to compare, so no note;
    ///   - the same app when either title is unknown: a title that could not be read this turn (a
    ///     busy app, a timeout) must not turn a follow-up on the same screen into "another screen".
    /// Titles are cleaned again here, so a description that was stored by an older build or written
    /// by hand compares the same way as a fresh one.
    static func screenChanged(from screenOfLastExchange: ClickyScreenDescription?, to screenNow: ClickyScreenDescription?) -> Bool {
        guard let screenOfLastExchange, let screenNow else { return false }
        let earlierApplicationName = ClickyWindowTitleText.cleanedApplicationName(from: screenOfLastExchange.applicationName)
        let currentApplicationName = ClickyWindowTitleText.cleanedApplicationName(from: screenNow.applicationName)
        guard let earlierApplicationName, let currentApplicationName else { return false }
        if earlierApplicationName != currentApplicationName {
            return true
        }
        guard let earlierWindowTitle = ClickyWindowTitleText.cleanedWindowTitle(from: screenOfLastExchange.windowTitle),
              let currentWindowTitle = ClickyWindowTitleText.cleanedWindowTitle(from: screenNow.windowTitle) else {
            return false
        }
        return earlierWindowTitle != currentWindowTitle
    }

    /// The note for the per-turn prompt block, or nil when the screen did not change. It goes
    /// right after the "right now" block.
    static func noteText(screenOfLastExchange: ClickyScreenDescription?, screenNow: ClickyScreenDescription?) -> String? {
        guard screenChanged(from: screenOfLastExchange, to: screenNow),
              let screenOfLastExchange,
              let earlierScreenText = screenText(for: screenOfLastExchange) else {
            return nil
        }
        return """
        earlier in this conversation:
        - the earlier messages were about another screen: \(earlierScreenText). that screen is not shown now; the screenshots show only what is on screen now.
        - your earlier answers were right for that screen. never apologize for them, never say they were wrong, and never remark on the switch or on what is no longer visible. just answer.
        - answer about the screen now. if the question continues an earlier one, answer it from the conversation.
        """
    }

    /// `Terminal "samsto — zsh — 110x34"`, or just `Terminal` when the title is unknown.
    static func screenText(for screenDescription: ClickyScreenDescription) -> String? {
        guard let cleanedApplicationName = ClickyWindowTitleText.cleanedApplicationName(from: screenDescription.applicationName) else {
            return nil
        }
        guard let cleanedWindowTitle = ClickyWindowTitleText.cleanedWindowTitle(from: screenDescription.windowTitle) else {
            return cleanedApplicationName
        }
        return "\(cleanedApplicationName) \(ClickyWindowTitleText.quoted(cleanedWindowTitle))"
    }
}
