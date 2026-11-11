import Foundation

nonisolated struct ClickyFinishedTurn {
    let parsedReply: ClickyParsedReply
    /// What text-to-speech reads aloud. It never confirms something that was not saved: a refused,
    /// dropped or failed save replaces a confirmation with an honest sentence. A forget request is
    /// answered with a fixed short sentence.
    let spokenText: String
    let savedNoteTexts: [String]
    /// Logged, never spoken: why a note write failed.
    let noteSaveErrorDescription: String?
    /// Profile facts now in the profile because of this reply (including ones it already held).
    let savedProfileFactTexts: [String]
    /// Logged, never spoken: why a profile write failed.
    let profileSaveErrorDescription: String?
    /// [PROFILE:] tags that were not saved: the user's words gave no permission, or something
    /// looked like a secret. Only a count is kept, so no fact text ends up in logs.
    let droppedProfileTagCount: Int
    /// Notes, profile facts and dictated notes refused because they looked like secrets.
    let secretRefusalCount: Int
    /// [NOTE:] tags dropped because the user never used save language.
    let droppedNoteTagCount: Int
    /// The profile already holds its hard limit of facts, so a new fact was refused.
    let profileWasFull: Bool
    /// Set when the user asked to forget something this turn.
    let forgetOutcome: ClickyForgetOutcome?
    /// What goes into conversation history: the spoken text plus a [NOTE:] tag for each saved note
    /// and a [PROFILE:] tag for each saved profile fact. Keeping the tags in history shows the
    /// model that tagging is the pattern it should continue.
    let historyAssistantText: String
}

/// The result of a spoken "forget ...", turned into the one short sentence Clicky speaks.
nonisolated struct ClickyForgetOutcome: Equatable {
    enum Kind: Equatable {
        case removed
        case noMatch
        /// Two or more saved items matched equally well, so nothing was removed.
        case ambiguous
        /// "forget my editor and my shell": several things at once, so nothing was removed.
        case severalTargets
        case failed
        /// "forget everything" is not honored by voice.
        case refusedToWipeEverything
    }

    let kind: Kind
    let removedProfileFactCount: Int
    let removedNoteCount: Int
    /// Logged, never spoken: why a removal failed.
    let errorDescription: String?

    /// What Clicky says about the request. A removal gets a short confirmation. Every request that
    /// could not be carried out says plainly that nothing was forgotten, then why: the user never
    /// hears silence, and never hears the model's claim of a removal that did not happen.
    var spokenSentence: String {
        switch kind {
        case .removed:
            return "okay, i've forgotten that."
        case .noMatch:
            return "i didn't forget anything. i don't have that saved."
        case .ambiguous:
            return "i didn't forget anything. i have two like that. say which one."
        case .severalTargets:
            return "i didn't forget anything. one at a time. say which one first."
        case .failed:
            return "sorry, i couldn't forget that."
        case .refusedToWipeEverything:
            return "i didn't forget anything. i can't wipe everything by voice."
        }
    }
}

/// Turns the raw model reply into what the app speaks, what it saves, and what goes into history.
///
/// The rule behind all of it: memory never says something false. A confirmation is spoken only for
/// a save that happened, "forgotten" only for a removal that happened, and "i won't keep that"
/// only when nothing was written.
nonisolated enum ClickyTurnFinisher {
    /// Spoken when a note could not be written, so the user is never told a false "noted".
    static let noteSaveFailureSpokenSentence = "i couldn't save that note."

    /// Spoken when a profile fact could not be written, for the same reason.
    static let profileSaveFailureSpokenSentence = "i couldn't save that."

    /// The confirmation spoken when a profile fact was saved and the model's own confirmation is
    /// missing, too long, or announces the value that was replaced.
    static let profileSaveDefaultConfirmationSpokenSentence = "got it, i'll remember that."

    /// Spoken when the model tried to save something that looks like a secret.
    static let secretNotKeptSpokenSentence = "i won't keep that."

    /// Spoken when the profile holds its hard limit of facts.
    static let profileFullSpokenSentence = "my profile is full. forget something first."

    /// Spoken when a tag the model wrote was dropped because the user's words gave no permission,
    /// and the reply would otherwise have confirmed it.
    static let nothingWasSavedSpokenSentence = "i didn't save that."

    /// Spoken when a request to change memory was recognised but not carried out, and nothing more
    /// specific can be said.
    static let nothingWasForgottenSpokenSentence = "i didn't forget anything."

    /// Spoken after the user says they stopped using something and the stale fact was removed.
    static let staleFactRemovedSpokenSentence = "okay, i've forgotten that."

    /// A confirmation of a save may be at most this many words.
    static let maximumConfirmationWordCount = 6

    static func finishTurn(
        rawReplyText: String,
        userTranscript: String,
        noteStore: ClickyNoteStore,
        profileStore: ClickyProfileStore? = nil,
        previousAssistantHistoryText: String? = nil,
        now: Date = Date()
    ) -> ClickyFinishedTurn {
        let parsedReply = ClickyReplyTagParser.parse(rawReplyText)

        // A forget request is read from the transcript alone and handled here, not by the model,
        // so the removal and the spoken answer always agree. A forget turn saves nothing.
        var forgetOutcome: ClickyForgetOutcome?
        var forgetRequestThatWasNotExecuted: ClickyForgetRequest?
        if let forgetRequest = ClickyProfileIntentDetector.forgetRequest(in: userTranscript) {
            if case .notExecutable = forgetRequest {
                forgetRequestThatWasNotExecuted = forgetRequest
            } else {
                forgetOutcome = performForgetRequest(
                    forgetRequest,
                    noteStore: noteStore,
                    profileStore: profileStore,
                    previousAssistantHistoryText: previousAssistantHistoryText
                )
            }
        }
        let isForgetTurn = forgetOutcome != nil

        var saveSummary = MemorySaveSummary()
        if !isForgetTurn {
            saveSummary.emptyTagCount = parsedReply.emptyMemoryTagCount

            // "i no longer use vim": the stale fact in that slot goes, and a fact that only repeats
            // the negation ("no longer uses vim") is not saved.
            let noLongerUsedValue = ClickyProfileIntentDetector.valueTheUserNoLongerUses(in: userTranscript)
            if let profileStore, let noLongerUsedValue,
               case .removed(let removedFactTexts) = profileStore.removeSlotFacts(namingValue: noLongerUsedValue) {
                saveSummary.staleFactsRemovedCount = removedFactTexts.count
            }
            if let profileStore {
                saveProfileFacts(
                    parsedReply: parsedReply,
                    userTranscript: userTranscript,
                    userSaidTheyStoppedUsingSomething: noLongerUsedValue != nil,
                    profileStore: profileStore,
                    into: &saveSummary
                )
            }
            saveNotes(parsedReply: parsedReply, userTranscript: userTranscript, noteStore: noteStore, now: now, into: &saveSummary)
        }

        // A request to change memory that was not carried out must never be answered with the
        // model's claim that it was ("okay, forgotten"). How the reply is worded depends on why.
        let forgetClaimPolicy = ForgetClaimPolicy(
            isForgetTurn: isForgetTurn,
            notExecutedRequest: forgetRequestThatWasNotExecuted,
            transcriptMentionsChangingMemory: ClickyProfileIntentDetector.transcriptMentionsChangingMemory(userTranscript)
        )

        let spokenText = spokenText(
            parsedReply: parsedReply,
            forgetOutcome: forgetOutcome,
            saveSummary: saveSummary,
            forgetClaimPolicy: forgetClaimPolicy
        )

        let savedProfileFactTexts = saveSummary.savedProfileFacts.map(\.text)
        let historyPieces = [spokenText]
            + saveSummary.savedNoteTexts.map { "[NOTE:\($0)]" }
            + savedProfileFactTexts.map { "[PROFILE:\($0)]" }
        let historyAssistantText = historyPieces
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return ClickyFinishedTurn(
            parsedReply: parsedReply,
            spokenText: spokenText,
            savedNoteTexts: saveSummary.savedNoteTexts,
            noteSaveErrorDescription: saveSummary.noteSaveErrorDescription,
            savedProfileFactTexts: savedProfileFactTexts,
            profileSaveErrorDescription: saveSummary.profileSaveErrorDescription,
            droppedProfileTagCount: saveSummary.droppedProfileTagCount + saveSummary.profileTagsRefusedAsSecretCount,
            secretRefusalCount: saveSummary.secretRefusalCount,
            droppedNoteTagCount: saveSummary.droppedNoteTagCount,
            profileWasFull: saveSummary.profileIsFull,
            forgetOutcome: forgetOutcome,
            historyAssistantText: historyAssistantText
        )
    }

    // MARK: - Saving

    private struct SavedProfileFact {
        let text: String
        /// Older facts in the same slot that this one replaced.
        let replacedFactTexts: [String]
    }

    /// Everything that happened to this turn's candidate saves, used to word the spoken reply.
    private struct MemorySaveSummary {
        var savedProfileFacts: [SavedProfileFact] = []
        var savedNoteTexts: [String] = []
        /// Candidates (profile tags, note tags, dictated notes) refused because they, or what the
        /// user said, looked like a secret.
        var secretRefusalCount = 0
        /// How many of those refusals were [PROFILE:] tags, for the dropped-tag count.
        var profileTagsRefusedAsSecretCount = 0
        var droppedProfileTagCount = 0
        var droppedNoteTagCount = 0
        /// Tags that held no text at all.
        var emptyTagCount = 0
        /// Older facts removed because the user said they no longer use the value they named.
        var staleFactsRemovedCount = 0
        var profileIsFull = false
        var profileSaveErrorDescription: String?
        var noteSaveErrorDescription: String?

        /// True when saving a fact replaced an older one, so memory did change this turn.
        var replacedAFactThisTurn: Bool {
            savedProfileFacts.contains { !$0.replacedFactTexts.isEmpty }
        }

        var somethingWasSaved: Bool {
            !savedProfileFacts.isEmpty || !savedNoteTexts.isEmpty
        }

        /// Tags the model wrote that the user's own words did not allow.
        var droppedWithoutPermissionCount: Int {
            droppedProfileTagCount + droppedNoteTagCount + emptyTagCount
        }

        /// True when something was tried and did not happen, so a confirmation would be false.
        var somethingWasAttemptedAndNotSaved: Bool {
            secretRefusalCount > 0 || droppedWithoutPermissionCount > 0 || profileIsFull
                || profileSaveErrorDescription != nil || noteSaveErrorDescription != nil
        }
    }

    /// Saves the model's [PROFILE:] facts, but only when the user's own words allow it.
    /// - Secrets are checked first and always win: if the transcript or the fact looks like a
    ///   password, key, code or card number, nothing is saved.
    /// - Otherwise the transcript must state a lasting fact or preference, or the user must have
    ///   spoken the fact's own words about themselves. Screen text can make the model write a
    ///   tag, but it cannot make the user say those words, so it cannot save.
    private static func saveProfileFacts(parsedReply: ClickyParsedReply, userTranscript: String, userSaidTheyStoppedUsingSomething: Bool, profileStore: ClickyProfileStore, into saveSummary: inout MemorySaveSummary) {
        guard !parsedReply.profileTexts.isEmpty else {
            return
        }

        let transcriptLooksLikeASecret = ClickySecretDetector.textLooksLikeASecret(userTranscript)
        let transcriptStatesLastingFact = ClickyProfileIntentDetector.transcriptStatesLastingFactOrPreference(userTranscript)

        for profileCandidateText in parsedReply.profileTexts {
            if transcriptLooksLikeASecret || ClickySecretDetector.textLooksLikeASecret(profileCandidateText) {
                saveSummary.secretRefusalCount += 1
                saveSummary.profileTagsRefusedAsSecretCount += 1
                continue
            }
            // Either the user used a known lasting-statement phrasing, or the fact's own words
            // were spoken by the user about themselves ("change my name to helix").
            let userWordsAllowThisFact = transcriptStatesLastingFact
                || ClickyProfileIntentDetector.transcriptGroundsProfileFact(userTranscript: userTranscript, profileFactText: profileCandidateText)
            guard userWordsAllowThisFact else {
                saveSummary.droppedProfileTagCount += 1
                continue
            }
            // "no longer uses vim" would only repeat what the removal above already did.
            if userSaidTheyStoppedUsingSomething && ClickyProfileIntentDetector.factTextIsANegation(profileCandidateText) {
                saveSummary.droppedProfileTagCount += 1
                continue
            }

            switch profileStore.saveFact(text: profileCandidateText) {
            case .saved(let savedFactText, let replacedFactTexts):
                saveSummary.savedProfileFacts.append(SavedProfileFact(text: savedFactText, replacedFactTexts: replacedFactTexts))
            case .alreadyKnown(let knownFactText):
                saveSummary.savedProfileFacts.append(SavedProfileFact(text: knownFactText, replacedFactTexts: []))
            case .rejectedBecauseEmpty:
                saveSummary.droppedProfileTagCount += 1
            case .rejectedBecauseProfileIsFull:
                saveSummary.profileIsFull = true
                return
            case .failed(let errorDescription):
                saveSummary.profileSaveErrorDescription = errorDescription
                return
            }
        }
    }

    /// Saves this turn's notes. Claude's [NOTE:] tags count only when the user used save language;
    /// if there are none, the note the user dictated is saved directly, so a forgotten tag still
    /// saves the note. Every candidate goes through the same two checks as profile facts:
    /// - A note essentially the same as a profile fact just saved is skipped (one statement
    ///   produced both a [PROFILE:] and a [NOTE:]; only the profile keeps it).
    /// - A secret is refused, whether it came from a tag or from the dictated fallback.
    private static func saveNotes(parsedReply: ClickyParsedReply, userTranscript: String, noteStore: ClickyNoteStore, now: Date, into saveSummary: inout MemorySaveSummary) {
        var candidateNoteTexts: [String] = []
        if ClickyNoteIntentDetector.transcriptMentionsSavingIntent(userTranscript) {
            candidateNoteTexts = parsedReply.noteTexts
        } else {
            saveSummary.droppedNoteTagCount += parsedReply.noteTexts.count
        }
        if candidateNoteTexts.isEmpty,
           let dictatedNoteText = ClickyNoteIntentDetector.explicitSaveRequestNoteText(in: userTranscript) {
            candidateNoteTexts = [dictatedNoteText]
        }

        let transcriptLooksLikeASecret = ClickySecretDetector.textLooksLikeASecret(userTranscript)
        let savedProfileFactTexts = saveSummary.savedProfileFacts.map(\.text)

        // "remember my password is hunter2": a save command that carries a secret is refused out
        // loud even when no note text could be pulled out of it and the model wrote no tag, so the
        // model's own "got it" cannot stand.
        if candidateNoteTexts.isEmpty, saveSummary.savedProfileFacts.isEmpty, transcriptLooksLikeASecret,
           ClickyNoteIntentDetector.transcriptStartsWithSaveCommand(userTranscript) {
            saveSummary.secretRefusalCount += 1
        }

        for candidateNoteText in candidateNoteTexts {
            if savedProfileFactTexts.contains(where: { ClickyMemoryKeyWords.textsAreEssentiallyTheSame($0, candidateNoteText) }) {
                continue
            }
            if transcriptLooksLikeASecret || ClickySecretDetector.textLooksLikeASecret(candidateNoteText) {
                saveSummary.secretRefusalCount += 1
                continue
            }
            do {
                let savedNote = try noteStore.saveNote(text: candidateNoteText, savedAt: now)
                saveSummary.savedNoteTexts.append(savedNote.text)
            } catch {
                saveSummary.noteSaveErrorDescription = error.localizedDescription
                break
            }
        }
    }

    // MARK: - Forgetting

    private static func performForgetRequest(
        _ forgetRequest: ClickyForgetRequest,
        noteStore: ClickyNoteStore,
        profileStore: ClickyProfileStore?,
        previousAssistantHistoryText: String?
    ) -> ClickyForgetOutcome {
        switch forgetRequest {
        case .everything:
            return ClickyForgetOutcome(kind: .refusedToWipeEverything, removedProfileFactCount: 0, removedNoteCount: 0, errorDescription: nil)

        case .severalThings:
            return ClickyForgetOutcome(kind: .severalTargets, removedProfileFactCount: 0, removedNoteCount: 0, errorDescription: nil)

        case .notExecutable:
            // The caller handles these before this function; nothing is removed.
            return ClickyForgetOutcome(kind: .noMatch, removedProfileFactCount: 0, removedNoteCount: 0, errorDescription: nil)

        case .specificThing(let forgetTargetText):
            // "my editor and shell" names two things even without a second "my".
            if ClickyProfileSlots.numberOfDifferentThingsNamed(byForgetTarget: forgetTargetText) >= 2 {
                return ClickyForgetOutcome(kind: .severalTargets, removedProfileFactCount: 0, removedNoteCount: 0, errorDescription: nil)
            }
            // Where to look: a target that says "note" or "reminder" is a note, one that says
            // "profile", "preference" or "fact" is a profile fact. With neither word the profile is
            // searched first and the notes only if the profile has nothing on the subject. At most
            // one thing is ever removed ("forget the vim note" must not also remove "i use vim").
            let scope = forgetScope(of: forgetTargetText)
            var profileRemovalResult: ClickyMemoryRemovalResult = .noMatch
            if scope != .notesOnly {
                profileRemovalResult = profileStore?.removeFacts(matchingForgetTarget: forgetTargetText) ?? .noMatch
            }
            var noteRemovalResult: ClickyMemoryRemovalResult = .noMatch
            if scope == .notesOnly || (scope == .profileOrNotes && profileRemovalResult == .noMatch) {
                noteRemovalResult = noteStore.removeNotes(matchingForgetTarget: forgetTargetText)
            }
            return forgetOutcome(profileRemovalResult: profileRemovalResult, noteRemovalResult: noteRemovalResult)

        case .previouslySavedThing:
            // "forget that" means what the last turn saved. Its [PROFILE:] and [NOTE:] tags are kept
            // in history, so the exact saved texts are known.
            let previousReply = ClickyReplyTagParser.parse(previousAssistantHistoryText ?? "")
            if previousReply.profileTexts.isEmpty && previousReply.noteTexts.isEmpty {
                // Nothing was saved last turn, so "that" does not point at anything. Deleting a guessed
                // fact would lose the user's data on an ambiguous command, so remove nothing and say so;
                // the user can name what to forget ("forget my editor").
                return forgetOutcome(profileRemovalResult: .noMatch, noteRemovalResult: .noMatch)
            }
            let profileRemovalResult: ClickyMemoryRemovalResult = previousReply.profileTexts.isEmpty
                ? .noMatch
                : (profileStore?.removeFacts(withExactTexts: previousReply.profileTexts) ?? .noMatch)
            let noteRemovalResult: ClickyMemoryRemovalResult = previousReply.noteTexts.isEmpty
                ? .noMatch
                : noteStore.removeNotes(withExactTexts: previousReply.noteTexts)
            return forgetOutcome(profileRemovalResult: profileRemovalResult, noteRemovalResult: noteRemovalResult)
        }
    }

    private enum ForgetScope {
        case notesOnly
        case profileOnly
        /// No marker word: the profile first, then the notes if the profile has no match.
        case profileOrNotes
    }

    private static func forgetScope(of forgetTargetText: String) -> ForgetScope {
        let mentionsNotes = forgetTargetText.range(of: "\\b(?:notes?|reminders?)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        let mentionsProfile = forgetTargetText.range(of: "\\b(?:profile|preferences?|facts?)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        if mentionsNotes && !mentionsProfile {
            return .notesOnly
        }
        if mentionsProfile && !mentionsNotes {
            return .profileOnly
        }
        return .profileOrNotes
    }

    /// Combines the profile and note removals into one outcome: a failure wins, then a removal,
    /// then an ambiguity (nothing was removed, the user must say which), then no match.
    private static func forgetOutcome(profileRemovalResult: ClickyMemoryRemovalResult, noteRemovalResult: ClickyMemoryRemovalResult) -> ClickyForgetOutcome {
        var removedProfileFactCount = 0
        var removedNoteCount = 0
        var failureDescription: String?
        var wasAmbiguous = false

        switch profileRemovalResult {
        case .removed(let removedTexts):
            removedProfileFactCount = removedTexts.count
        case .noMatch:
            break
        case .ambiguous:
            wasAmbiguous = true
        case .failed(let errorDescription):
            failureDescription = errorDescription
        }
        switch noteRemovalResult {
        case .removed(let removedTexts):
            removedNoteCount = removedTexts.count
        case .noMatch:
            break
        case .ambiguous:
            wasAmbiguous = true
        case .failed(let errorDescription):
            failureDescription = failureDescription ?? errorDescription
        }

        let outcomeKind: ClickyForgetOutcome.Kind
        if failureDescription != nil {
            outcomeKind = .failed
        } else if removedProfileFactCount + removedNoteCount > 0 {
            outcomeKind = .removed
        } else if wasAmbiguous {
            outcomeKind = .ambiguous
        } else {
            outcomeKind = .noMatch
        }
        return ClickyForgetOutcome(
            kind: outcomeKind,
            removedProfileFactCount: removedProfileFactCount,
            removedNoteCount: removedNoteCount,
            errorDescription: failureDescription
        )
    }

    // MARK: - Forget claims

    /// What to do about a model reply that may claim a removal when the request to change memory
    /// was not carried out.
    private struct ForgetClaimPolicy {
        enum Mode {
            /// Not a request to change memory: replies that mention deleting or erasing are left alone.
            case leaveReplyAlone
            /// A brush-off ("forget it, where's the run button"): claims are removed, nothing is added.
            case stripClaimsOnly
            /// A named thing was not forgotten because a question or another request came with it:
            /// claims are removed and the reply says nothing was forgotten.
            case stripClaimsAndSayNothingWasForgotten
            /// The phrasing was not understood well enough to act: claims are removed, and if the
            /// reply had one (or said nothing else) it says nothing was forgotten.
            case stripClaimsAndSayNothingWasForgottenIfClaimed
        }

        let mode: Mode

        init(isForgetTurn: Bool, notExecutedRequest: ClickyForgetRequest?, transcriptMentionsChangingMemory: Bool) {
            if isForgetTurn {
                mode = .leaveReplyAlone
            } else if case .notExecutable(let namesAMemoryObject)? = notExecutedRequest {
                mode = namesAMemoryObject ? .stripClaimsAndSayNothingWasForgotten : .stripClaimsOnly
            } else if transcriptMentionsChangingMemory {
                mode = .stripClaimsAndSayNothingWasForgottenIfClaimed
            } else {
                mode = .leaveReplyAlone
            }
        }
    }

    // MARK: - Spoken text

    /// What text-to-speech reads aloud.
    ///
    /// - A forget request is answered with its own short sentence, whatever the model wrote.
    /// - When something was saved, the confirmation is at most six words and does not announce a
    ///   replaced value; a missing profile confirmation is added.
    /// - When a save was attempted and did not happen (a secret, no spoken permission, a full
    ///   profile, a failed write), the model's confirmation is removed, so the user never hears a
    ///   save that did not happen. A real answer in the same reply is kept. Then an honest sentence
    ///   follows: "i won't keep that.", "my profile is full. forget something first.", "i couldn't
    ///   save that.", or "i didn't save that.".
    private static func spokenText(
        parsedReply: ClickyParsedReply,
        forgetOutcome: ClickyForgetOutcome?,
        saveSummary: MemorySaveSummary,
        forgetClaimPolicy: ForgetClaimPolicy
    ) -> String {
        if let forgetOutcome {
            return forgetOutcome.spokenSentence
        }

        var replySentences = splitIntoSentences(parsedReply.spokenText)
        var replyWasEdited = false
        var closingSentences: [String] = []

        // Nothing was removed this turn, so no sentence may say something was. The check applies to
        // every request to change memory that was not carried out.
        if forgetClaimPolicy.mode != .leaveReplyAlone {
            let sentencesWithoutForgetClaims = replySentences.filter { !sentenceClaimsToHaveForgotten($0) }
            let removedAForgetClaim = sentencesWithoutForgetClaims.count != replySentences.count
            if removedAForgetClaim {
                replySentences = sentencesWithoutForgetClaims
                replyWasEdited = true
            }
            switch forgetClaimPolicy.mode {
            case .leaveReplyAlone:
                break
            case .stripClaimsOnly:
                // A brush-off such as "forget it": the reply is just a plain acknowledgement.
                if replySentences.isEmpty && removedAForgetClaim {
                    replySentences = ["okay."]
                }
            case .stripClaimsAndSayNothingWasForgotten:
                if saveSummary.replacedAFactThisTurn == false {
                    closingSentences.append(nothingWasForgottenSpokenSentence)
                }
            case .stripClaimsAndSayNothingWasForgottenIfClaimed:
                if removedAForgetClaim || replySentences.isEmpty {
                    closingSentences.append(nothingWasForgottenSpokenSentence)
                }
            }
        }

        if saveSummary.secretRefusalCount > 0 {
            closingSentences.append(secretNotKeptSpokenSentence)
        }
        if saveSummary.profileIsFull {
            closingSentences.append(profileFullSpokenSentence)
        }
        if saveSummary.noteSaveErrorDescription != nil {
            closingSentences.append(noteSaveFailureSpokenSentence)
        }
        if saveSummary.profileSaveErrorDescription != nil {
            closingSentences.append(profileSaveFailureSpokenSentence)
        }

        if saveSummary.somethingWasSaved {
            let sentencesBeforeStandardizing = replySentences
            replySentences = sentencesWithAcceptableSaveConfirmation(replySentences, saveSummary: saveSummary)
            replyWasEdited = replyWasEdited || replySentences != sentencesBeforeStandardizing
        }

        if saveSummary.somethingWasAttemptedAndNotSaved || (saveSummary.staleFactsRemovedCount > 0 && !saveSummary.somethingWasSaved) {
            // The model's own refusal ("i can't keep that") is dropped, because the app's sentence
            // says it once and exactly.
            if saveSummary.secretRefusalCount > 0 {
                let sentencesBeforeDroppingRefusals = replySentences
                replySentences = replySentences.filter { !sentenceRefusesToSave($0) }
                replyWasEdited = replyWasEdited || replySentences != sentencesBeforeDroppingRefusals
            }

            if !saveSummary.somethingWasSaved {
                var removedAConfirmation = false
                replySentences = replySentences.filter { replySentence in
                    if sentenceIsAPureConfirmation(replySentence) {
                        removedAConfirmation = true
                        return false
                    }
                    return true
                }
                let keptSentenceStillClaimsASave = replySentences.contains { sentenceContainsConfirmationWord($0) }
                replyWasEdited = replyWasEdited || removedAConfirmation

                // The user said they stopped using something and the stale fact was removed: say that.
                if saveSummary.staleFactsRemovedCount > 0 {
                    closingSentences.append(staleFactRemovedSpokenSentence)
                }

                // A tag was dropped for lack of spoken permission and nothing else explains it: say so
                // when the reply claimed a save, or when the reply said nothing else.
                let nothingElseExplainsIt = closingSentences.isEmpty
                if nothingElseExplainsIt, saveSummary.droppedWithoutPermissionCount > 0,
                   removedAConfirmation || keptSentenceStillClaimsASave || replySentences.isEmpty {
                    closingSentences.append(nothingWasSavedSpokenSentence)
                }
            }
        }

        if !replyWasEdited && closingSentences.isEmpty {
            return parsedReply.spokenText
        }
        return (replySentences + closingSentences)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Makes the spoken confirmation of a successful save acceptable: one confirmation, at most six
    /// words, that does not announce the value a replace removed. A profile fact with no
    /// confirmation at all gets the standard one, so nothing is learned silently.
    private static func sentencesWithAcceptableSaveConfirmation(_ replySentences: [String], saveSummary: MemorySaveSummary) -> [String] {
        let savedFactTexts = saveSummary.savedProfileFacts.map(\.text)
        let savedKeyWords = savedFactTexts.reduce(into: Set<String>()) { runningKeyWords, savedFactText in
            runningKeyWords.formUnion(ClickyMemoryKeyWords.keyWords(in: savedFactText))
        }
        // Key words that belonged to a replaced fact and not to the new one: the old value.
        let replacedKeyWords = saveSummary.savedProfileFacts
            .flatMap(\.replacedFactTexts)
            .reduce(into: Set<String>()) { runningKeyWords, replacedFactText in
                runningKeyWords.formUnion(ClickyMemoryKeyWords.keyWords(in: replacedFactText))
            }
        let oldValueKeyWords = replacedKeyWords.subtracting(savedKeyWords)

        var sentencesWithOneConfirmation: [String] = []
        var confirmationWasPlaced = false
        for replySentence in replySentences {
            let sentenceKeyWords = ClickyMemoryKeyWords.keyWords(in: replySentence)
            let sentenceAnnouncesOldValue = !oldValueKeyWords.isEmpty
                && !sentenceKeyWords.isDisjoint(with: oldValueKeyWords)
                && (sentenceContainsConfirmationWord(replySentence) || sentenceAnnouncesAChange(replySentence) || sentenceIsAPureConfirmation(replySentence))
            // A long sentence that says "remember" and repeats the saved fact is a confirmation too.
            let sentenceRestatesSavedFact = sentenceContainsConfirmationWord(replySentence)
                && !sentenceKeyWords.isDisjoint(with: savedKeyWords)

            guard sentenceIsAPureConfirmation(replySentence) || sentenceAnnouncesOldValue || sentenceRestatesSavedFact else {
                sentencesWithOneConfirmation.append(replySentence)
                continue
            }
            // Only the first confirmation is kept; a second one would say the same thing twice.
            guard !confirmationWasPlaced else {
                continue
            }
            let confirmationIsAcceptable = wordCount(of: replySentence) <= maximumConfirmationWordCount && !sentenceAnnouncesOldValue
            sentencesWithOneConfirmation.append(confirmationIsAcceptable ? replySentence : profileSaveDefaultConfirmationSpokenSentence)
            confirmationWasPlaced = true
        }

        if !confirmationWasPlaced,
           !saveSummary.savedProfileFacts.isEmpty,
           !sentencesWithOneConfirmation.contains(where: { sentenceContainsConfirmationWord($0) }) {
            sentencesWithOneConfirmation.append(profileSaveDefaultConfirmationSpokenSentence)
        }
        return sentencesWithOneConfirmation
    }

    // MARK: - Sentence helpers

    /// Splits a reply into sentences at a full stop, question mark or exclamation mark that is
    /// followed by a space, so "version 3.5" stays whole.
    private static func splitIntoSentences(_ text: String) -> [String] {
        guard let sentenceBreakRegex = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+"#) else {
            return text.isEmpty ? [] : [text]
        }
        let separator = "\u{1F}"
        let markedText = sentenceBreakRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: separator
        )
        return markedText
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func containsNegation(_ sentence: String) -> Bool {
        // "i won't forget" is a promise to remember, so it is read before the negation check.
        let sentenceWithoutPromise = sentence.lowercased().replacingOccurrences(of: "won't forget", with: "").replacingOccurrences(of: "won’t forget", with: "")
        return sentenceWithoutPromise.range(
            of: #"\b(?:won['’]?t|will\s+not|can['’]?t|cannot|couldn['’]?t|didn['’]?t|did\s+not|don['’]?t|do\s+not|not|never|unable)\b"#,
            options: .regularExpression
        ) != nil
    }

    /// A sentence that is only a confirmation: it opens with "got it", "noted", "i'll remember",
    /// "i've saved", "will do" and so on (after optional "okay," or "sure,"). Removing or
    /// shortening such a sentence never loses an answer.
    private static func sentenceIsAPureConfirmation(_ sentence: String) -> Bool {
        if containsNegation(sentence) {
            return false
        }
        let confirmationOpeningPattern = #"^\W*(?:(?:ok|okay|sure(?:\s+thing)?|alright|all\s+right|yes|yep|yeah|cool|great|perfect|no\s+problem|of\s+course|absolutely|certainly|understood|thanks|thank\s+you)[,.\s!]+)*(?:got\s+it|noted|i['’]?ll\s+(?:remember|keep|make\s+a\s+note|note)|i\s+will\s+(?:remember|keep)|i['’]?ve\s+(?:noted|saved|stored|added|made\s+a\s+note)|i\s+have\s+(?:noted|saved|stored)|will\s+do|saved|stored|added|remembered|remembering|done|that['’]?s\s+(?:saved|noted)|i\s+can\s+remember|i\s+won['’]?t\s+forget)"#
        if sentence.range(of: confirmationOpeningPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        let isVeryShort = wordCount(of: sentence) <= 2
        return isVeryShort && sentence.range(of: #"^\W*(?:ok|okay|sure|done|alright|yep|yes|right)\W*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func sentenceContainsConfirmationWord(_ sentence: String) -> Bool {
        if containsNegation(sentence) {
            return false
        }
        return sentence.range(
            of: #"\b(?:got\s+it|noted|remember|remembered|saved|stored|will\s+do|keep\s+that|won['’]?t\s+forget|added)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func sentenceAnnouncesAChange(_ sentence: String) -> Bool {
        sentence.range(
            of: #"\b(?:switch|switching|switched|chang|updat|replac|instead|no\s+longer|used\s+to|from\s+\w+\s+to)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// "i can't keep that", "i won't save that": the model refusing for itself.
    private static func sentenceRefusesToSave(_ sentence: String) -> Bool {
        sentence.range(
            of: #"\b(?:won['’]?t|will\s+not|can['’]?t|cannot|not\s+going\s+to|don['’]?t|shouldn['’]?t)\s+(?:keep|save|store|remember|write)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// A sentence that says memory was changed: "forgotten", "deleted", "removed", "erased",
    /// "cleared", "i'll forget it", "i won't remember that anymore". "i didn't forget anything" is
    /// the opposite and is not a claim.
    private static func sentenceClaimsToHaveForgotten(_ sentence: String) -> Bool {
        let promiseToStopRemembering = #"\b(?:i['’]?ll|i\s+will)\s+(?:forget|stop\s+remembering)\b|\b(?:won['’]?t|will\s+not|no\s+longer)\s+(?:remember|keep)\b"#
        if sentence.range(of: promiseToStopRemembering, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if containsNegation(sentence) {
            return false
        }
        return sentence.range(
            of: #"\b(?:forgot|forgotten|forgetting|removed|deleted|erased|wiped|cleared|purged)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
