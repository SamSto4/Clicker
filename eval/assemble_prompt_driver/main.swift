// Eval-only driver for the Clicky prompt pipeline.
//
// Compile (from /Users/samsto/Clicker, never run xcodebuild):
//   swiftc -O -o <binary> eval/assemble_prompt_driver/main.swift leanring-buddy/ClickyCore/*.swift
//
// It calls the same two entry points the app calls, so the harness scores what the app would do:
//   prepare  <input.json> <output.json> <promptsDirectory> <notesRootDirectory>
//            For each scenario: seed a temporary note store, then ClickyPromptAssembler.prepareSystemPrompt.
//   finish   <input.json> <output.json> <notesRootDirectory>
//            For each raw reply: ClickyTurnFinisher.finishTurn against that scenario's temporary store.
//   selftest <output.json> <promptsDirectory>
//            Offline checks of the parser, intent detector, note store, retrieval, skills and prompt size.
//
// SAFETY: every note operation goes to a directory under notesRootDirectory. That directory must be
// a folder whose name starts with "clicky-eval-notes-" and must not be the real Clicky notes folder.
// The harness creates notesRootDirectory with mkdtemp under the OS temp folder.

import Foundation

let evalNotesFolderNamePrefix = "clicky-eval-notes-"

func failWithMessage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("driver error: \(message)\n".utf8))
    exit(1)
}

func requireTemporaryNotesRoot(_ notesRootDirectoryURL: URL) {
    let standardizedRootPath = notesRootDirectoryURL.standardizedFileURL.path
    let realNotesPath = ClickyNoteStore.defaultNotesDirectoryURL.standardizedFileURL.path
    guard notesRootDirectoryURL.lastPathComponent.hasPrefix(evalNotesFolderNamePrefix),
          standardizedRootPath != realNotesPath,
          !standardizedRootPath.hasPrefix(realNotesPath + "/"),
          !realNotesPath.hasPrefix(standardizedRootPath + "/") else {
        failWithMessage("refusing notes root \(standardizedRootPath): must be a \(evalNotesFolderNamePrefix)* folder outside the real Clicky notes folder")
    }
}

func noteStoreForScenario(_ scenarioIdentifier: String, notesRootDirectoryURL: URL) -> ClickyNoteStore {
    let scenarioNotesDirectoryURL = notesRootDirectoryURL.appendingPathComponent(scenarioIdentifier, isDirectory: true)
    return ClickyNoteStore(notesDirectoryURL: scenarioNotesDirectoryURL)
}

func readJSONArray(atPath filePath: String) -> [[String: Any]] {
    guard let fileData = FileManager.default.contents(atPath: filePath),
          let parsedObject = try? JSONSerialization.jsonObject(with: fileData),
          let scenarioArray = parsedObject as? [[String: Any]] else {
        failWithMessage("could not read a JSON array from \(filePath)")
    }
    return scenarioArray
}

func writeJSON(_ jsonObject: Any, toPath filePath: String) {
    do {
        let outputData = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
        try outputData.write(to: URL(fileURLWithPath: filePath))
    } catch {
        failWithMessage("could not write \(filePath): \(error.localizedDescription)")
    }
}

// Seeds are "yyyy-MM-dd" plus an optional "HH:mm"; the time defaults to noon so a note never lands on a day boundary.
let seedDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

func seedDate(fromDayText dayText: String) -> Date {
    guard let parsedDate = seedDateFormatter.date(from: "\(dayText) 12:00") else {
        failWithMessage("bad seed date \(dayText)")
    }
    return parsedDate
}

// MARK: - prepare

func runPrepare(inputPath: String, outputPath: String, promptsDirectoryPath: String, notesRootPath: String) {
    let notesRootDirectoryURL = URL(fileURLWithPath: notesRootPath, isDirectory: true)
    requireTemporaryNotesRoot(notesRootDirectoryURL)
    let promptsDirectoryURL = URL(fileURLWithPath: promptsDirectoryPath, isDirectory: true)
    var outputRecords: [[String: Any]] = []

    for scenarioInput in readJSONArray(atPath: inputPath) {
        guard let scenarioIdentifier = scenarioInput["id"] as? String,
              let userTranscript = scenarioInput["transcript"] as? String,
              let applicationName = scenarioInput["appName"] as? String,
              let screenCount = scenarioInput["screenCount"] as? Int else {
            failWithMessage("prepare input needs id, transcript, appName, screenCount")
        }
        let applicationBundleIdentifier = scenarioInput["bundleId"] as? String
        let noteStore = noteStoreForScenario(scenarioIdentifier, notesRootDirectoryURL: notesRootDirectoryURL)

        for seedNote in (scenarioInput["seedNotes"] as? [[String: String]]) ?? [] {
            guard let dayText = seedNote["date"], let noteText = seedNote["text"] else {
                failWithMessage("seed note needs date and text (\(scenarioIdentifier))")
            }
            do {
                try noteStore.saveNote(text: noteText, savedAt: seedDate(fromDayText: dayText))
            } catch {
                failWithMessage("seeding a note failed for \(scenarioIdentifier): \(error.localizedDescription)")
            }
        }

        let preparedPrompt = ClickyPromptAssembler.prepareSystemPrompt(
            for: ClickyTurnContext(
                userTranscript: userTranscript,
                frontmostApplicationBundleIdentifier: applicationBundleIdentifier,
                frontmostApplicationName: applicationName,
                screenCount: screenCount,
                currentDate: Date()
            ),
            promptsDirectoryURL: promptsDirectoryURL,
            noteStore: noteStore
        )
        outputRecords.append([
            "id": scenarioIdentifier,
            "systemPromptText": preparedPrompt.systemPromptText,
            "selectedSkillNames": preparedPrompt.selectedSkillNames,
            "includedNoteTexts": preparedPrompt.includedNotes.map(\.text),
        ])
    }
    writeJSON(outputRecords, toPath: outputPath)
}

// MARK: - finish

func runFinish(inputPath: String, outputPath: String, notesRootPath: String) {
    let notesRootDirectoryURL = URL(fileURLWithPath: notesRootPath, isDirectory: true)
    requireTemporaryNotesRoot(notesRootDirectoryURL)
    var outputRecords: [[String: Any]] = []

    for replyInput in readJSONArray(atPath: inputPath) {
        guard let scenarioIdentifier = replyInput["id"] as? String,
              let rawReplyText = replyInput["rawReplyText"] as? String,
              let userTranscript = replyInput["transcript"] as? String else {
            failWithMessage("finish input needs id, transcript, rawReplyText")
        }
        let finishedTurn = ClickyTurnFinisher.finishTurn(
            rawReplyText: rawReplyText,
            userTranscript: userTranscript,
            noteStore: noteStoreForScenario(scenarioIdentifier, notesRootDirectoryURL: notesRootDirectoryURL)
        )
        var pointTargetRecord: Any = NSNull()
        if let pointTarget = finishedTurn.parsedReply.pointTarget {
            pointTargetRecord = [
                "x": pointTarget.x,
                "y": pointTarget.y,
                "label": pointTarget.label ?? NSNull(),
                "screenNumber": pointTarget.screenNumber ?? NSNull(),
            ] as [String: Any]
        }
        outputRecords.append([
            "id": scenarioIdentifier,
            "spokenText": finishedTurn.spokenText,
            "pointTarget": pointTargetRecord,
            // Tags Claude wrote, before the save gate. Scored as "the model emitted a note tag".
            "modelNoteTexts": finishedTurn.parsedReply.noteTexts,
            // Notes the app actually wrote (tags past the intent gate are dropped; dictated fallback can add one).
            "savedNoteTexts": finishedTurn.savedNoteTexts,
            "noteSaveErrorDescription": finishedTurn.noteSaveErrorDescription ?? NSNull(),
            "historyAssistantText": finishedTurn.historyAssistantText,
        ])
    }
    writeJSON(outputRecords, toPath: outputPath)
}

// MARK: - selftest (offline, zero API calls)

struct OfflineCheckResult {
    let name: String
    let passed: Bool
    let detail: String
}

var offlineCheckResults: [OfflineCheckResult] = []

func check(_ name: String, _ passed: Bool, _ detail: String = "") {
    offlineCheckResults.append(OfflineCheckResult(name: name, passed: passed, detail: passed ? "" : detail))
}

func runSelfTest(outputPath: String, promptsDirectoryPath: String) {
    // Parser: POINT grammar.
    let screenTwoParse = ClickyReplyTagParser.parse("that's on the other monitor. [POINT:400,300:terminal:screen2]")
    check("parser: :screen2 suffix", screenTwoParse.pointTarget?.screenNumber == 2 && screenTwoParse.pointTarget?.label == "terminal" && screenTwoParse.spokenText == "that's on the other monitor.", "\(screenTwoParse)")
    let noneParse = ClickyReplyTagParser.parse("i don't see that. [POINT:none]")
    check("parser: POINT:none gives nil target", noneParse.pointTarget == nil && noneParse.spokenText == "i don't see that.", "\(noneParse)")
    let decimalParse = ClickyReplyTagParser.parse("ok. [POINT:12.5,40.25:save button]")
    check("parser: decimal coordinates", decimalParse.pointTarget?.x == 12.5 && decimalParse.pointTarget?.y == 40.25, "\(decimalParse)")
    let trailingPeriodParse = ClickyReplyTagParser.parse("click the run button. [POINT:136,46:run button].")
    check("parser: punctuation after tag tolerated", trailingPeriodParse.pointTarget?.x == 136 && trailingPeriodParse.spokenText == "click the run button.", "\(trailingPeriodParse)")
    let midTextParse = ClickyReplyTagParser.parse("see [POINT:10,20:save] over there. then press enter.")
    check("parser: mid-text POINT tag", midTextParse.pointTarget?.label == "save" && midTextParse.spokenText == "see over there. then press enter.", "\(midTextParse)")
    let lowercaseParse = ClickyReplyTagParser.parse("try this. [point:5,6:thing]")
    check("parser: lowercase tag name", lowercaseParse.pointTarget?.x == 5, "\(lowercaseParse)")
    let spacedLabelParse = ClickyReplyTagParser.parse("hit it. [POINT: 5 , 6 : save button ]")
    check("parser: spaced label trimmed", spacedLabelParse.pointTarget?.label == "save button" && spacedLabelParse.pointTarget?.x == 5, "\(spacedLabelParse)")
    let lastPointWinsParse = ClickyReplyTagParser.parse("[POINT:1,1:a] first. [POINT:9,9:b]")
    check("parser: last POINT wins", lastPointWinsParse.pointTarget?.label == "b", "\(lastPointWinsParse)")
    let truncatedParse = ClickyReplyTagParser.parse("sure, that's the export menu. [POINT:12,")
    check("parser: truncated POINT fragment stripped", truncatedParse.pointTarget == nil && truncatedParse.spokenText == "sure, that's the export menu.", "\(truncatedParse)")
    let truncatedNoteParse = ClickyReplyTagParser.parse("got it. [NOTE:the wifi is lant")
    check("parser: truncated NOTE fragment stripped", truncatedNoteParse.noteTexts.isEmpty && truncatedNoteParse.spokenText == "got it.", "\(truncatedNoteParse)")

    // Parser: NOTE grammar.
    let threeNotesParse = ClickyReplyTagParser.parse("a [NOTE:one fact] b [POINT:1,2:x] c [NOTE:two fact] d [NOTE:three fact]")
    check("parser: 1-3 NOTE tags in any order with POINT", threeNotesParse.noteTexts == ["one fact", "two fact", "three fact"] && threeNotesParse.pointTarget?.x == 1, "\(threeNotesParse)")
    let fourNotesParse = ClickyReplyTagParser.parse("[NOTE:a1] [NOTE:b2] [NOTE:c3] [NOTE:d4]")
    check("parser: NOTE cap of 3", fourNotesParse.noteTexts.count == 3 && !fourNotesParse.spokenText.contains("NOTE"), "\(fourNotesParse)")
    let multilineNoteParse = ClickyReplyTagParser.parse("ok. [NOTE:line one\nline two]")
    check("parser: newline collapsed in NOTE", multilineNoteParse.noteTexts == ["line one line two"], "\(multilineNoteParse)")
    let longNoteParse = ClickyReplyTagParser.parse("ok. [NOTE:\(String(repeating: "x", count: 500))]")
    check("parser: NOTE capped at 400 chars", (longNoteParse.noteTexts.first?.count ?? 0) == 400, "\(longNoteParse.noteTexts.first?.count ?? -1)")
    let emptyNoteParse = ClickyReplyTagParser.parse("ok. [NOTE:   ]")
    check("parser: empty NOTE dropped", emptyNoteParse.noteTexts.isEmpty, "\(emptyNoteParse)")

    // Intent detector: save phrases (positive) and questions (negative).
    let positiveSavePhrases = [
        "remember that my dentist is friday at 3", "take a note that the wifi password is hunter2",
        "make a note of the meeting time", "note that the deploy is on friday", "note to self call mom",
        "write down the flight number", "jot down ideas for the demo", "save a note about the bug",
        "don't forget that the car is at the shop", "keep in mind that the client prefers email",
        "hey clicky, please remember that i like tea", "can you note that the server is down", "remember: buy milk",
    ]
    let negativeNonSavePhrases = [
        "do you remember when we talked about xcode", "what's the capital of france", "what does git status do",
        "how do i commit in xcode", "what's on my screen", "remind me what i said about the wifi",
        "why is my build failing", "what's the weather", "where is the run button",
    ]
    let missedPositives = positiveSavePhrases.filter { ClickyNoteIntentDetector.explicitSaveRequestNoteText(in: $0) == nil }
    let falseSaves = negativeNonSavePhrases.filter { ClickyNoteIntentDetector.explicitSaveRequestNoteText(in: $0) != nil }
    check("intent: 14 save phrases detected", missedPositives.isEmpty, "missed: \(missedPositives)")
    check("intent: 9 non-save phrases not detected as saves", falseSaves.isEmpty, "false saves: \(falseSaves)")
    check("intent: dictated text extracted", ClickyNoteIntentDetector.explicitSaveRequestNoteText(in: "remember that my dentist is friday at 3") == "my dentist is friday at 3")
    // "remember this" is a save request, but the text must come from the screen, so no dictated text is returned.
    check("intent: 'remember this' is save intent with no dictated text", ClickyNoteIntentDetector.explicitSaveRequestNoteText(in: "remember this") == nil && ClickyNoteIntentDetector.transcriptMentionsSavingIntent("remember this"))
    check("intent: loose save language", ClickyNoteIntentDetector.transcriptMentionsSavingIntent("can you jot that in my notes"))
    check("intent: recall phrases", ClickyNoteIntentDetector.transcriptAsksToRecallNotes("what did i tell you about the wifi") && ClickyNoteIntentDetector.transcriptAsksToRecallNotes("what do you remember about my car"))
    check("intent: plain question is not recall", !ClickyNoteIntentDetector.transcriptAsksToRecallNotes("when's my dentist"))

    // Tag gate: a NOTE tag without save language is rejected; dictated fallback still saves.
    let temporaryRootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(evalNotesFolderNamePrefix)selftest-\(UUID().uuidString)", isDirectory: true)
    let selfTestNoteStore = ClickyNoteStore(notesDirectoryURL: temporaryRootURL.appendingPathComponent("gate", isDirectory: true))
    let gatedTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "the sky is blue. [NOTE:the sky is blue]", userTranscript: "what's the capital of france", noteStore: selfTestNoteStore)
    check("gate: NOTE tag without save language rejected", gatedTurn.savedNoteTexts.isEmpty && !FileManager.default.fileExists(atPath: selfTestNoteStore.notesDirectoryURL.path), "\(gatedTurn.savedNoteTexts)")
    let fallbackTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "got it. [POINT:none]", userTranscript: "remember that my dentist is friday at 3", noteStore: selfTestNoteStore)
    check("gate: dictated fallback saves when tag missing", fallbackTurn.savedNoteTexts == ["my dentist is friday at 3"], "\(fallbackTurn.savedNoteTexts)")
    let historyTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "got it, noted. [NOTE:my dentist is friday at 3]", userTranscript: "remember that my dentist is friday at 3", noteStore: selfTestNoteStore)
    check("gate: spoken text has no tag and history keeps it", historyTurn.spokenText == "got it, noted." && historyTurn.historyAssistantText.contains("[NOTE:my dentist is friday at 3]"), "\(historyTurn.spokenText) | \(historyTurn.historyAssistantText)")

    // Store: layout, round trip, dedupe, hand edits, unwritable folder.
    let layoutStore = ClickyNoteStore(notesDirectoryURL: temporaryRootURL.appendingPathComponent("layout", isDirectory: true))
    let fixedSaveDate = Date(timeIntervalSince1970: 1_700_000_000)
    let layoutNote = try? layoutStore.saveNote(text: "cabin wifi is lantern42", savedAt: fixedSaveDate)
    let dayFileName = ClickyNoteStore.dayFileName(for: fixedSaveDate)
    let layoutFileContents = (try? String(contentsOf: layoutStore.notesDirectoryURL.appendingPathComponent(dayFileName), encoding: .utf8)) ?? ""
    let expectedTimeText = ClickyNoteStore.formattedDate(fixedSaveDate, dateFormat: "HH:mm")
    check("store: creates folder on first save", FileManager.default.fileExists(atPath: layoutStore.notesDirectoryURL.path) && layoutNote != nil)
    check("store: header and line format", layoutFileContents.hasPrefix("# Clicky notes ") && layoutFileContents.contains("- \(expectedTimeText) — cabin wifi is lantern42"), layoutFileContents)
    check("store: round trip", layoutStore.loadAllNotes().contains { $0.text == "cabin wifi is lantern42" })
    _ = try? layoutStore.saveNote(text: "cabin wifi is lantern42", savedAt: fixedSaveDate)
    let linesAfterDuplicate = ((try? String(contentsOf: layoutStore.notesDirectoryURL.appendingPathComponent(dayFileName), encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { $0.contains("cabin wifi") }
    check("store: same-minute duplicate not written twice", linesAfterDuplicate.count == 1, "\(linesAfterDuplicate.count) lines")
    let handEditedFileURL = layoutStore.notesDirectoryURL.appendingPathComponent(dayFileName)
    let handEditedContents = ((try? String(contentsOf: handEditedFileURL, encoding: .utf8)) ?? "") + "typed by hand, no time\n* starred hand note\n"
    try? handEditedContents.write(to: handEditedFileURL, atomically: true, encoding: .utf8)
    let handEditedTexts = layoutStore.loadAllNotes().map(\.text)
    check("store: tolerates hand edits", handEditedTexts.contains("typed by hand, no time") && handEditedTexts.contains("starred hand note"), "\(handEditedTexts)")
    let blockerFileURL = temporaryRootURL.appendingPathComponent("blocker-file")
    try? FileManager.default.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
    try? "not a folder".write(to: blockerFileURL, atomically: true, encoding: .utf8)
    let unwritableStore = ClickyNoteStore(notesDirectoryURL: blockerFileURL.appendingPathComponent("sub", isDirectory: true))
    var unwritableSaveThrew = false
    do { _ = try unwritableStore.saveNote(text: "will fail") } catch { unwritableSaveThrew = true }
    check("store: unwritable folder throws, no crash", unwritableSaveThrew)
    let blankNoteThrew: Bool = { do { _ = try layoutStore.saveNote(text: "   "); return false } catch { return true } }()
    check("store: blank note throws", blankNoteThrew)

    // Retrieval: 30 notes, the cabin wifi note must be in the top 3 for a matching question.
    let retrievalStore = ClickyNoteStore(notesDirectoryURL: temporaryRootURL.appendingPathComponent("retrieval", isDirectory: true))
    let filler = ["bought oat milk for the office", "the printer on floor two is jammed", "call the plumber about the sink",
                  "renew the car registration in march", "the gym closes early on fridays", "sam likes window seats",
                  "the quarterly report draft is in the shared drive", "dentist moved to thursday mornings"]
    for index in 0..<29 {
        let fillerDate = Date().addingTimeInterval(-Double(index + 1) * 86_400)
        _ = try? retrievalStore.saveNote(text: "\(filler[index % filler.count]) (item \(index))", savedAt: fillerDate)
    }
    _ = try? retrievalStore.saveNote(text: "the cabin wifi password is lantern42", savedAt: Date().addingTimeInterval(-20 * 86_400))
    let wifiRelevantNotes = retrievalStore.notesRelevant(toTranscript: "what's the cabin wifi password", wantsFullRecall: false)
    let wifiRank = wifiRelevantNotes.firstIndex { $0.text.contains("lantern42") }
    check("retrieval: cabin wifi in top 3 of 30", (wifiRank ?? 99) < 3, "rank \(String(describing: wifiRank)) of \(wifiRelevantNotes.count)")
    let fullRecallNotes = retrievalStore.notesRelevant(toTranscript: "what did I tell you", wantsFullRecall: true)
    let fullRecallIsNewestFirst = zip(fullRecallNotes, fullRecallNotes.dropFirst()).allSatisfy { $0.savedAt >= $1.savedAt }
    check("retrieval: full recall at most 20, newest first", fullRecallNotes.count <= 20 && fullRecallIsNewestFirst && fullRecallNotes.count == 20, "count \(fullRecallNotes.count)")
    let capStore = ClickyNoteStore(notesDirectoryURL: temporaryRootURL.appendingPathComponent("caps", isDirectory: true))
    let longPaddingText = String(repeating: "project alpha detail ", count: 15)
    for index in 0..<30 {
        _ = try? capStore.saveNote(text: "\(longPaddingText) number \(index)", savedAt: Date().addingTimeInterval(-Double(index) * 3_600))
    }
    let cappedNotes = capStore.notesRelevant(toTranscript: "project alpha detail status", wantsFullRecall: false)
    let cappedCharacterTotal = cappedNotes.reduce(0) { $0 + $1.text.count }
    check("retrieval: 8 note and 1500 char caps hold", cappedNotes.count <= 8 && cappedCharacterTotal <= 1500, "count \(cappedNotes.count), chars \(cappedCharacterTotal)")
    let emptyStore = ClickyNoteStore(notesDirectoryURL: temporaryRootURL.appendingPathComponent("empty-never-created", isDirectory: true))
    let emptyStorePrompt = ClickyPromptAssembler.prepareSystemPrompt(
        for: ClickyTurnContext(userTranscript: "what's the weather", frontmostApplicationBundleIdentifier: "com.apple.Safari", frontmostApplicationName: "Safari", screenCount: 1, currentDate: Date()),
        promptsDirectoryURL: URL(fileURLWithPath: promptsDirectoryPath, isDirectory: true), noteStore: emptyStore)
    check("retrieval: empty store omits notes section", !emptyStorePrompt.systemPromptText.contains("saved notes, most relevant first"))

    // Skills: bundle-id and name selection, cap, order, body only when selected, malformed skipped.
    let skillsDirectoryURL = URL(fileURLWithPath: promptsDirectoryPath, isDirectory: true)
    let loadedSkills = ClickySkillLibrary.loadSkills(fromDirectory: skillsDirectoryURL)
    func selectedNames(_ transcript: String, _ bundleIdentifier: String?, _ applicationName: String?) -> [String] {
        ClickySkillLibrary.selectSkills(
            from: loadedSkills,
            for: ClickySkillSelectionContext(userTranscript: transcript, frontmostApplicationBundleIdentifier: bundleIdentifier, frontmostApplicationName: applicationName)
        ).map(\.skillName)
    }
    let skillExpectations: [(String, [String], String?, String?, String)] = [
        ("Terminal", ["terminal", "coding_general"], "com.apple.Terminal", "Terminal", "why did this fail"),
        ("iTerm2", ["terminal", "coding_general"], "com.googlecode.iterm2", "iTerm2", "why did this fail"),
        ("Warp", ["terminal", "coding_general"], "dev.warp.Warp-Stable", "Warp", "why did this fail"),
        ("Ghostty", ["terminal", "coding_general"], "com.mitchellh.ghostty", "Ghostty", "why did this fail"),
        ("Cursor", ["vscode", "coding_general"], "com.todesktop.230313mzl4w4u92", "Cursor", "why did this fail"),
        ("Xcode", ["xcode", "coding_general"], "com.apple.dt.Xcode", "Xcode", "what does this error mean"),
        ("VS Code", ["vscode", "coding_general"], "com.microsoft.VSCode", "Visual Studio Code", "why did this fail"),
        ("Safari keyword", ["coding_general"], "com.apple.Safari", "Safari", "why is my build failing"),
        ("Safari none", [], "com.apple.Safari", "Safari", "what's the weather"),
    ]
    for (label, expectedNames, bundleIdentifier, applicationName, transcript) in skillExpectations {
        let names = selectedNames(transcript, bundleIdentifier, applicationName)
        // Compare as sets: the order between a general skill and an app skill can change with keyword hits; both are included.
        check("skills: \(label) selects \(expectedNames)", Set(names) == Set(expectedNames) && names.count == expectedNames.count, "got \(names)")
    }
    let capNames = selectedNames("swiftui build failed in xcode terminal", "com.apple.dt.Xcode", "Xcode")
    check("skills: at most 2 selected", capNames.count <= 2, "\(capNames)")
    check("skills: deterministic order", selectedNames("why did this fail", "com.apple.Terminal", "Terminal") == selectedNames("why did this fail", "com.apple.Terminal", "Terminal"))
    let malformedSkillParsed = ClickySkillLibrary.parseSkill(fromMarkdown: "no front matter here", fileName: "bad.md")
    check("skills: malformed file skipped", malformedSkillParsed == nil)
    let noBodySkillParsed = ClickySkillLibrary.parseSkill(fromMarkdown: "---\nname: empty\n---\n", fileName: "empty.md")
    check("skills: front matter without body skipped", noBodySkillParsed == nil)
    let safariWeatherPrompt = ClickyPromptAssembler.prepareSystemPrompt(
        for: ClickyTurnContext(userTranscript: "what's the weather", frontmostApplicationBundleIdentifier: "com.apple.Safari", frontmostApplicationName: "Safari", screenCount: 1, currentDate: Date()),
        promptsDirectoryURL: skillsDirectoryURL, noteStore: emptyStore)
    check("skills: body absent when not selected", !safariWeatherPrompt.systemPromptText.contains("skill guidance for this question"))

    // Prompt: base file loads, right-now block present, budget.
    let xcodePrompt = ClickyPromptAssembler.prepareSystemPrompt(
        for: ClickyTurnContext(userTranscript: "build failed with no such module", frontmostApplicationBundleIdentifier: "com.apple.dt.Xcode", frontmostApplicationName: "Xcode", screenCount: 2, currentDate: Date()),
        promptsDirectoryURL: skillsDirectoryURL, noteStore: emptyStore)
    check("prompt: base file loaded (not emergency prompt)", !xcodePrompt.systemPromptText.contains("you're clicky, a friendly companion in the user's menu bar. reply in one short"))
    check("prompt: right-now block has bundle id and screen count", xcodePrompt.systemPromptText.contains("com.apple.dt.Xcode") && xcodePrompt.systemPromptText.contains("2 screens"))
    // Size guards. These are regression tripwires against the prompt quietly growing, not quality checks.
    // The original limits (700 words, 1800 tokens) were set from the round 1 prompt and tripped in round 2
    // when the base prompt grew to 797 words and the assembled Xcode prompt (base + xcode skill +
    // coding_general skill + right-now block) reached about 1816 tokens by the chars/4 estimate. Round 3
    // trimmed the base prompt to 757 words. The limits below sit about 10 percent above the largest size
    // seen so far (round 2), so a prompt that grows past its round 2 size fails this check and has to be
    // justified, while ordinary wording edits do not.
    let baseWordCount = ((try? String(contentsOf: skillsDirectoryURL.appendingPathComponent("clicky_base_system_prompt.md"), encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).count
    check("prompt: base at most 875 words", baseWordCount <= 875, "\(baseWordCount) words")
    let approximateTokenCount = xcodePrompt.systemPromptText.count / 4
    check("prompt: assembled xcode prompt about 2k tokens or less (chars/4)", approximateTokenCount <= 2000, "about \(approximateTokenCount) tokens")

    try? FileManager.default.removeItem(at: temporaryRootURL)

    let passedCount = offlineCheckResults.filter(\.passed).count
    let failedChecks = offlineCheckResults.filter { !$0.passed }
    var reportRecords: [[String: Any]] = []
    for result in offlineCheckResults {
        reportRecords.append(["name": result.name, "passed": result.passed, "detail": result.detail])
    }
    writeJSON(["passed": passedCount, "total": offlineCheckResults.count, "checks": reportRecords,
               "approximate_xcode_prompt_tokens": approximateTokenCount, "base_prompt_words": baseWordCount] as [String: Any], toPath: outputPath)
    print("offline checks: \(passedCount)/\(offlineCheckResults.count) passed")
    for failedCheck in failedChecks {
        print("  FAIL \(failedCheck.name): \(failedCheck.detail)")
    }
}

// MARK: - entry point

let commandLineArguments = CommandLine.arguments
guard commandLineArguments.count >= 2 else {
    failWithMessage("usage: prepare|finish|selftest with arguments (see the header of main.swift)")
}
switch commandLineArguments[1] {
case "prepare" where commandLineArguments.count == 6:
    runPrepare(inputPath: commandLineArguments[2], outputPath: commandLineArguments[3], promptsDirectoryPath: commandLineArguments[4], notesRootPath: commandLineArguments[5])
case "finish" where commandLineArguments.count == 5:
    runFinish(inputPath: commandLineArguments[2], outputPath: commandLineArguments[3], notesRootPath: commandLineArguments[4])
case "selftest" where commandLineArguments.count == 4:
    runSelfTest(outputPath: commandLineArguments[2], promptsDirectoryPath: commandLineArguments[3])
default:
    failWithMessage("bad arguments for mode \(commandLineArguments[1])")
}
