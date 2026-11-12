import Foundation

/// What can be said about Claude's reply while it is still streaming in.
nonisolated enum ClickyReplyTextBeforeFirstTag: Equatable {
    /// No reply tag has opened yet, so the spoken part of the reply may still be growing.
    case firstTagNotOpenedYet
    /// A tag has opened, so everything before it can no longer change. `spokenText` is that part
    /// cleaned exactly the way `ClickyReplyTagParser` cleans spoken text. It is empty when the
    /// reply began with a tag, or when what came before the tag has nothing to say.
    case spokenTextIsComplete(spokenText: String)
}

/// Why the audio of a turn was, or was not, fetched ahead of time. Short fixed identifiers only,
/// because these go into the metrics log.
nonisolated enum ClickySpeechPrefetchOutcome: String, Equatable {
    /// The audio fetched while Claude was still writing tags was for exactly the final spoken
    /// text, so it was played without a second request.
    case used
    /// No early fetch happened: no reply tag was seen before the stream ended, or nothing came
    /// before the first tag.
    case notStarted
    /// The user's words were about saving, forgetting or secrets, so the spoken text is likely to
    /// be rewritten by `ClickyTurnFinisher`. Nothing was sent to text-to-speech early.
    case skippedForMemoryRequest
    /// An early fetch happened, but `ClickyTurnFinisher` decided on different spoken text, so the
    /// early audio was thrown away unplayed and the final text was fetched.
    case textChanged
    /// The early fetch failed, so the final text was fetched the normal way.
    case failed
}

/// The pure decisions behind fetching a reply's speech early. Foundation only, so they can be
/// tested without the app.
///
/// The safety rule behind all of it: nothing is ever played before `ClickyTurnFinisher` has
/// decided the final spoken text. An early fetch only downloads audio. The audio is played only if
/// the final text is exactly the text it was made from, so a refused save, a rewritten
/// confirmation or a removed false claim can never be heard.
nonisolated enum ClickySpeechPrefetch {
    /// The first reply tag opens with "[POINT", "[NOTE" or "[PROFILE" and a colon, the same shape
    /// `ClickyReplyTagParser` accepts. A stray "[" that is not a tag opening (as in "press [ to
    /// indent") does not count, and neither does a half-arrived "[POI".
    private static let replyTagOpeningPattern = #"\[\s*(?:POINT|NOTE|PROFILE)\s*:"#

    /// Looks at the reply text received so far. Once the first tag has opened, the words before it
    /// are the spoken answer and cannot change, even though the stream goes on writing tags.
    ///
    /// The text is run through the same parser the turn finisher uses, so it matches the finisher's
    /// spoken text whenever nothing else is added or removed (a trailing ".", extra spaces and a
    /// dangling "[" fragment are cleaned identically).
    static func replyTextBeforeFirstTag(in accumulatedReplyText: String) -> ClickyReplyTextBeforeFirstTag {
        guard let firstTagOpeningRange = accumulatedReplyText.range(
            of: replyTagOpeningPattern,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return .firstTagNotOpenedYet
        }

        let replyTextBeforeFirstTag = String(accumulatedReplyText[..<firstTagOpeningRange.lowerBound])
        let spokenText = ClickyReplyTagParser.parse(replyTextBeforeFirstTag).spokenText
        return .spokenTextIsComplete(spokenText: spokenText)
    }

    /// True when the reply so far holds a tag that sits between its sentences: a `[DRAW`, `[CARD`,
    /// `[ROW`, `[SCENE` or `[PART` tag. In such a reply the words before the first tag are not the whole spoken
    /// answer, so audio fetched for them would always be thrown away, and the early fetch is
    /// skipped. A half-arrived "[DRA" does not count yet; the next chunk settles it.
    static func replyHoldsTagsBetweenItsSentences(_ accumulatedReplyText: String) -> Bool {
        accumulatedReplyText.range(
            of: #"\[\s*(?:DRAW|CARD|ROW|SCENE|PART)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// False when the user's own words are about memory: a save command, a lasting fact or
    /// preference, forgetting, or anything that looks like a secret. In those turns the finisher
    /// often rewrites what is spoken ("i won't keep that."), so fetching early would send text to
    /// the speech service that the finisher is about to refuse. It could even echo a secret that
    /// the app will not remember. Those turns simply take the normal path.
    ///
    /// Only strict save language counts here, not the loose gate the finisher uses for note tags:
    /// that one matches the word "save" or "log" anywhere, so "where is the save button" would
    /// lose its early fetch for nothing. A loose-only match needs the model to write a tag first,
    /// and if it does, the exact-text check below still keeps the audio honest.
    static func transcriptAllowsSpeechPrefetch(_ userTranscript: String) -> Bool {
        let transcriptTouchesMemory = ClickyNoteIntentDetector.transcriptStartsWithSaveCommand(userTranscript)
            || ClickyNoteIntentDetector.explicitSaveRequestNoteText(in: userTranscript) != nil
            || ClickyProfileIntentDetector.transcriptStatesLastingFactOrPreference(userTranscript)
            || ClickyProfileIntentDetector.forgetRequest(in: userTranscript) != nil
            || ClickyProfileIntentDetector.transcriptMentionsChangingMemory(userTranscript)
            || ClickyProfileIntentDetector.valueTheUserNoLongerUses(in: userTranscript) != nil
            || ClickySecretDetector.textLooksLikeASecret(userTranscript)
        return !transcriptTouchesMemory
    }

    /// The only rule for playing early audio: it was made from exactly the final spoken text.
    /// Any difference at all (a word, a space, a full stop) means the early audio is discarded and
    /// the final text is fetched again.
    static func prefetchedAudioMatchesFinalSpokenText(prefetchedSpokenText: String?, finalSpokenText: String) -> Bool {
        guard let prefetchedSpokenText, !prefetchedSpokenText.isEmpty else {
            return false
        }
        return prefetchedSpokenText == finalSpokenText
    }
}
