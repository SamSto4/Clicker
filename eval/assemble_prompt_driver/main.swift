// Eval-only driver for the Clicky prompt pipeline.
//
// Compile (from /Users/samsto/Clicker, never run xcodebuild):
//   swiftc -swift-version 5 -O -o <binary> eval/assemble_prompt_driver/main.swift leanring-buddy/ClickyCore/*.swift
//
// It calls the same two entry points the app calls, so the harness scores what the app would do:
//   prepare  <input.json> <output.json> <promptsDirectory> <notesRootDirectory>
//            For each scenario: seed a temporary note store and (round 4B) a temporary profile.md
//            (`seedProfileFacts` through ClickyProfileStore.saveFact, or `seedProfileFileContents` written
//            verbatim for hand-edited files), then ClickyPromptAssembler.prepareSystemPrompt with both stores.
//   finish   <input.json> <output.json> <notesRootDirectory>
//            For each raw reply: ClickyTurnFinisher.finishTurn against that scenario's temporary note and
//            profile stores (optional `previousAssistantHistoryText` for "forget that"). Reports what the
//            real gate saved or removed, plus the profile and note texts left in the stores afterwards.
//   intent   <input.json> <output.json>
//            (round 4B) For each `transcript`: the intent detectors' verdicts only (lasting fact, secret,
//            forget request, note save text, note save intent, recall). No files are touched.
//   selftest <output.json> <promptsDirectory>
//            Offline checks of the parser, intent detectors, note and profile stores, retrieval, skills, prompt size
//            and (round 6) the draw, card and row tags.
//
// Round 6 (drawing and the explanation card): `prepare` and `finish` both accept `seedDrawTagTexts`, a list
// of earlier reply texts whose [DRAW:...], [CARD:...] and [ROW:...] tags are parsed with ClickyDrawTagParser
// and applied to a ClickyDrawingBoard, one reply after the other. `prepare` passes the resulting marks to the
// assembler as `drawingMarksOnScreen` (so the prompt carries the app's own "marks on screen" text); `finish`
// rebuilds the same board, parses the new reply with ClickyDrawTagParser (with the row count of the card on
// screen, as the app does), applies its commands, and reports the commands, the dropped tag count and the
// board before and after. The harness scores those records and never re-implements the grammar.
//
// Round 14 (old screen context): `prepare` also reads the optional `screenContextNow` and
// `screenContextOfHistory` objects, each `{ "app": "...", "windowTitle": "..." }`. The window title of
// "now" becomes the turn context's `frontmostWindowTitle` (so the "right now" block gets its title line;
// the app of "now" is the `appName` the harness already sends as the frontmost app). The pair for the
// history becomes `screenOfLastExchange`, which is what the app records with the last exchange of the
// conversation history; when it differs from the screen now, the assembler adds the "earlier in this
// conversation" note to the dynamic block. Without the objects the prompt is exactly what it was.
//
// Round 16 (memories from chats): `prepare` also reads the optional `memories` array of the input,
// `[{ "text": "...", "date": "2026-11-10" }]`, and seeds it into a temporary memories store (a folder
// next to the scenario's notes folder) with the dates given, so the prompt gets exactly the memories
// section the app would build for that question (`includedMemoryTexts` in the output lists the lines
// that were selected). A new mode, `compact`, shows the compaction without any network call:
//   compact  <input.json> <output.json|-> <promptsDirectory>
//            For each record `{ id, exchanges: [{ user, clicky }], alreadyCompactedExchangeCount?,
//            existingMemoryTexts?, existingProfileFactTexts?, modelOutput? }`: the app's own decision
//            (nothing new, skipped as too short, or compact), the exact request body the app would send to
//            the Worker (`requestBody`, and the same as one line of JSON text in `requestBodyJSON`; both
//            carry the real system prompt from the prompts folder, and the `<known>` list the app builds
//            from `existingProfileFactTexts` and `existingMemoryTexts`, shown in `knownTexts`), and, when `modelOutput` is given, the
//            lines the app's validator would keep for that output (`keptMemoryTexts`) with counts of what
//            it dropped or ignored. The grader can send `requestBody` through the Worker itself and feed
//            the answer back as `modelOutput`. "-" as the output path prints to standard output.
//
// Round 17 (file editing): `prepare` also reads the optional `editableFolders` (folder names) with `files`
// (`[{ path, content }]`, seeded into a temporary folder like the `tool` mode below) and `frontmostDocument`;
// with a non-empty `editableFolders` the output record also carries `tools` (the tools array exactly as the
// app sends it), `filesSectionText`, `frontmostDocumentLine`, `filesRootPath`, `folderPaths` and `maxTokens`,
// and `systemPromptText` and `dynamicSystemPromptText` hold the "files you may change" section. Two new
// modes, both without any network call.
//   tool        <input.json> <output.json> <notesRootDirectory>
//               For each record `{ id, editableFolders?: ["project"], files?: [{ path, content }],
//               frontmostDocument?: "project/Foo.swift", toolName, input }` (or `calls: [{ toolName, input }]`
//               to run several tools one after the other in one turn): the editable folders and files are
//               seeded into a temporary folder under notesRootDirectory (`<id>-files`; the folder names default
//               to ["project"], a file path is relative to that temporary root and starts with a folder name,
//               otherwise it goes into the first folder; the text "{root}" inside a tool input is replaced by
//               the temporary root's path), then the app's own `ClickyFileToolTurnSession` runs the tool(s).
//               Output per record: `results` (each `{ toolName, resultText, isError }`; `resultText` and
//               `isError` of the first are repeated at the top level), `queuedChanges` (action, relative path,
//               summary, the diff lines the change card shows, hidden line count), `toolCallCount`,
//               `bytesRead`, and the folder state after (`filesAfter`: every file below the root and its
//               text), which shows that nothing was written. A grader can feed `resultText` to the model as
//               the tool_result of a real loop through the Worker.
//   finish-files <input.json> <output.json>
//               For each record `{ id, spokenText, queuedChangeCount, usedFileTools, transcript? }`: the text
//               after the honesty rule (`ClickyFileEditingHonesty`) and, when `transcript` is given, what
//               the words mean to a pending change (`confirm`, `cancel`, `undo` or null).
//
// SAFETY: every note and profile operation goes to a directory under notesRootDirectory. That directory must be
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

/// The profile sits in the same temporary folder as the scenario's daily notes, as it does in the app
/// (profile.md next to the day files).
func profileStoreForScenario(_ scenarioIdentifier: String, notesRootDirectoryURL: URL) -> ClickyProfileStore {
    let scenarioNotesDirectoryURL = notesRootDirectoryURL.appendingPathComponent(scenarioIdentifier, isDirectory: true)
    return ClickyProfileStore(profileDirectoryURL: scenarioNotesDirectoryURL)
}

/// The memories of a scenario sit in a folder next to the scenario's notes folder (never inside it, so
/// the notes folder stays what the app's notes folder is: daily files and profile.md).
func memoryStoreForScenario(_ scenarioIdentifier: String, notesRootDirectoryURL: URL) -> ClickyMemoryStore {
    let scenarioMemoriesDirectoryURL = notesRootDirectoryURL.appendingPathComponent("\(scenarioIdentifier)-memories", isDirectory: true)
    return ClickyMemoryStore(memoriesDirectoryURL: scenarioMemoriesDirectoryURL)
}

/// The raw profile file, so a scoring step can check that no secret value reached the disk.
func profileFileContents(of profileStore: ClickyProfileStore) -> String? {
    try? String(contentsOf: profileStore.profileFileURL, encoding: .utf8)
}

func forgetOutcomeRecord(_ forgetOutcome: ClickyForgetOutcome?) -> Any {
    guard let forgetOutcome else {
        return NSNull()
    }
    let kindName: String
    switch forgetOutcome.kind {
    case .removed: kindName = "removed"
    case .noMatch: kindName = "noMatch"
    case .ambiguous: kindName = "ambiguous"
    case .severalTargets: kindName = "severalTargets"
    case .failed: kindName = "failed"
    case .refusedToWipeEverything: kindName = "refusedToWipeEverything"
    }
    return [
        "kind": kindName,
        "removedProfileFactCount": forgetOutcome.removedProfileFactCount,
        "removedNoteCount": forgetOutcome.removedNoteCount,
        "errorDescription": forgetOutcome.errorDescription ?? NSNull(),
        "spokenSentence": forgetOutcome.spokenSentence,
    ] as [String: Any]
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
        // "-" prints to standard output (used by the `compact` mode).
        if filePath == "-" {
            FileHandle.standardOutput.write(outputData)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
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

// MARK: - drawing (round 6)

func drawingPointRecord(_ point: ClickyDrawingPoint) -> [String: Any] {
    ["x": point.x, "y": point.y]
}

func explanationCardRowRecord(_ row: ClickyExplanationCardRow) -> [String: Any] {
    var partTexts: [String] = []
    switch row {
    case .text(let text):
        partTexts = [text]
    case .boxes(let inputTexts, let resultText):
        partTexts = inputTexts + (resultText.map { [$0] } ?? [])
    case .flow(let nodeTexts):
        partTexts = nodeTexts
    case .timeline(let points):
        partTexts = points.map { "\($0.whenText)=\($0.whatText)" }
    }
    return ["rowKind": row.tagKindName, "partTexts": partTexts, "canonicalTagBody": row.canonicalTagBody]
}

/// One shape as plain numbers and text, in screenshot pixels, exactly as the app's parser read it.
func drawingShapeRecord(_ shape: ClickyDrawingShape) -> [String: Any] {
    switch shape {
    case .arrow(let tail, let head):
        return ["shapeKind": "arrow", "tail": drawingPointRecord(tail), "head": drawingPointRecord(head)]
    case .circle(let center, let radius):
        return ["shapeKind": "circle", "center": drawingPointRecord(center), "radius": radius]
    case .box(let topLeftCorner, let size):
        return ["shapeKind": "box", "topLeftCorner": drawingPointRecord(topLeftCorner), "width": size.width, "height": size.height]
    case .underline(let start, let end):
        return ["shapeKind": "underline", "start": drawingPointRecord(start), "end": drawingPointRecord(end)]
    case .highlight(let topLeftCorner, let size):
        return ["shapeKind": "highlight", "topLeftCorner": drawingPointRecord(topLeftCorner), "width": size.width, "height": size.height]
    case .label(let topLeftCorner, let text):
        return ["shapeKind": "label", "topLeftCorner": drawingPointRecord(topLeftCorner), "text": text]
    case .stickyNote(let topLeftCorner, let text):
        return ["shapeKind": "sticky", "topLeftCorner": drawingPointRecord(topLeftCorner), "text": text]
    case .callout(let target, let text, let calloutNumber):
        return ["shapeKind": "callout", "target": drawingPointRecord(target), "text": text, "calloutNumber": calloutNumber]
    case .explanationCard(let card):
        return ["shapeKind": "card", "title": card.title, "rows": card.rows.map { explanationCardRowRecord($0) }]
    case .scene(let scene):
        // Round 11: a simple 3D scene. Only its size is reported; the visual rubric does not score scenes yet.
        return ["shapeKind": "scene", "title": scene.title, "partCount": scene.parts.count]
    }
}

func drawCommandRecord(_ parsedDrawCommand: ClickyParsedDrawCommand) -> [String: Any] {
    var commandRecord: [String: Any] = ["spokenFractionBeforeTag": parsedDrawCommand.spokenFractionBeforeTag]
    switch parsedDrawCommand.command {
    case .addMark(let shape, let screenNumber):
        commandRecord["commandKind"] = "addMark"
        commandRecord["shape"] = drawingShapeRecord(shape)
        commandRecord["screenNumber"] = screenNumber ?? NSNull()
    case .eraseMark(let markIdentifier):
        commandRecord["commandKind"] = "eraseMark"
        commandRecord["markIdentifier"] = markIdentifier
    case .undoNewestMark:
        commandRecord["commandKind"] = "undoNewestMark"
    case .clearAllMarks:
        commandRecord["commandKind"] = "clearAllMarks"
    case .addCardRow(let row):
        commandRecord["commandKind"] = "addCardRow"
        commandRecord["row"] = explanationCardRowRecord(row)
    case .addScenePart:
        commandRecord["commandKind"] = "addScenePart"
    }
    return commandRecord
}

func drawingMarkRecord(_ mark: ClickyDrawingMark) -> [String: Any] {
    [
        "markIdentifier": mark.markIdentifier,
        "shape": drawingShapeRecord(mark.shape),
        "screenNumber": mark.screenNumber ?? NSNull(),
    ]
}

func rowCountOfExplanationCard(on drawingBoard: ClickyDrawingBoard) -> Int? {
    guard let cardMark = drawingBoard.explanationCardMark, case .explanationCard(let card) = cardMark.shape else {
        return nil
    }
    return card.rows.count
}

/// The board as it would be after the earlier replies in `seedDrawTagTexts`, each parsed and applied the way
/// the app does it for a reply (ClickyDrawTagParser.parse with the row count of the card on the board, then
/// ClickyDrawingBoard.apply for every accepted command).
func drawingBoard(fromSeedDrawTagTexts seedDrawTagTexts: [String]) -> ClickyDrawingBoard {
    var drawingBoard = ClickyDrawingBoard()
    for seedDrawTagText in seedDrawTagTexts {
        let parsedSeedReply = ClickyDrawTagParser.parse(
            seedDrawTagText,
            rowCountOfCardAlreadyOnScreen: rowCountOfExplanationCard(on: drawingBoard)
        )
        if parsedSeedReply.ignoredDrawTagCount > 0 {
            failWithMessage("a seed draw tag was rejected by the app's parser: \(seedDrawTagText)")
        }
        for parsedSeedCommand in parsedSeedReply.commands {
            _ = drawingBoard.apply(parsedSeedCommand.command)
        }
    }
    return drawingBoard
}

/// The marks as the app hands them to the assembler (ClickyDrawingOverlayController.drawingMarksForPrompt):
/// with one screen the list carries no screen number; with several, every mark carries the number of the
/// screenshot it is on, and a mark drawn without `:screenN` is on the cursor's screen, which is screen 1.
func drawingMarksForPrompt(on drawingBoard: ClickyDrawingBoard, screenCount: Int) -> [ClickyDrawingMark] {
    drawingBoard.marks.map { markOnBoard in
        ClickyDrawingMark(
            markNumber: markOnBoard.markNumber,
            shape: markOnBoard.shape,
            screenNumber: screenCount > 1 ? (markOnBoard.screenNumber ?? 1) : nil
        )
    }
}


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

        // Round 4B: seed the scenario's profile. `seedProfileFacts` goes through the store's own
        // saveFact (so dedupe and subject replacement apply, as they would for facts the app saved);
        // `seedProfileFileContents` is written verbatim, for hand-edited or malformed files.
        let profileStore = profileStoreForScenario(scenarioIdentifier, notesRootDirectoryURL: notesRootDirectoryURL)
        if let seedProfileFileContents = scenarioInput["seedProfileFileContents"] as? String {
            do {
                try FileManager.default.createDirectory(at: profileStore.profileDirectoryURL, withIntermediateDirectories: true)
                try seedProfileFileContents.write(to: profileStore.profileFileURL, atomically: true, encoding: .utf8)
            } catch {
                failWithMessage("seeding the profile file failed for \(scenarioIdentifier): \(error.localizedDescription)")
            }
        }
        for seedProfileFactText in (scenarioInput["seedProfileFacts"] as? [String]) ?? [] {
            if case .failed(let errorDescription) = profileStore.saveFact(text: seedProfileFactText) {
                failWithMessage("seeding a profile fact failed for \(scenarioIdentifier): \(errorDescription)")
            }
        }

        // Round 16: seed the scenario's memories (`[{ "text", "date" }]`, oldest first) through the store's
        // own add, so the lines are normalised and limited exactly as the app's would be. Without the
        // array there is no memories store, and the prompt is exactly what it was.
        let seedMemories = scenarioInput["memories"] as? [[String: String]]
        let memoryStore = memoryStoreForScenario(scenarioIdentifier, notesRootDirectoryURL: notesRootDirectoryURL)
        for seedMemory in seedMemories ?? [] {
            guard let memoryText = seedMemory["text"], let dayText = seedMemory["date"] else {
                failWithMessage("seed memory needs text and date (\(scenarioIdentifier))")
            }
            if case .failed(let errorDescription) = memoryStore.addMemories(texts: [memoryText], sourceChatID: nil, createdAt: seedDate(fromDayText: dayText)) {
                failWithMessage("seeding a memory failed for \(scenarioIdentifier): \(errorDescription)")
            }
        }

        // Round 6: the marks that are on the screen when this turn starts (empty for an ordinary scenario,
        // which then gets exactly the prompt it got before drawing existed).
        let seededDrawingBoard = drawingBoard(fromSeedDrawTagTexts: (scenarioInput["seedDrawTagTexts"] as? [String]) ?? [])
        let drawingMarksOnScreen = drawingMarksForPrompt(on: seededDrawingBoard, screenCount: screenCount)

        // Round 14: the window title of the screen now, and the screen the last exchange of the history
        // was on (the app records it with each exchange; here the harness states it for the scenario).
        // Both are built with the app's own `ClickyScreenDescription` so cleaning and comparing are the app's.
        let screenContextNow = scenarioInput["screenContextNow"] as? [String: Any]
        let screenContextOfHistory = scenarioInput["screenContextOfHistory"] as? [String: Any]
        let screenOfLastExchange = screenContextOfHistory.flatMap { screenContextOfHistoryObject in
            ClickyScreenDescription.describing(
                applicationName: screenContextOfHistoryObject["app"] as? String,
                rawWindowTitle: screenContextOfHistoryObject["windowTitle"] as? String
            )
        }

        // Round 17: with a non-empty `editableFolders` the turn is a file-editing turn. The folders and
        // `files` are seeded into a temporary folder, the turn context gets the folders (and the open
        // document, `frontmostDocument`, a path relative to the temporary root) exactly as the app gives
        // them, and the output carries the tools array and the section the app would send. Without it the
        // record is exactly what it was.
        var turnContext = ClickyTurnContext(
            userTranscript: userTranscript,
            frontmostApplicationBundleIdentifier: applicationBundleIdentifier,
            frontmostApplicationName: applicationName,
            screenCount: screenCount,
            currentDate: Date(),
            drawingMarksOnScreen: drawingMarksOnScreen,
            frontmostWindowTitle: screenContextNow?["windowTitle"] as? String,
            screenOfLastExchange: screenOfLastExchange
        )
        var fileEditingOutputFields: [String: Any] = [:]
        if let editableFolderNames = scenarioInput["editableFolders"] as? [String], !editableFolderNames.isEmpty {
            let workspace = seedFilesWorkspace(
                scenarioIdentifier: scenarioIdentifier,
                editableFolderNames: editableFolderNames,
                files: (scenarioInput["files"] as? [[String: Any]]) ?? [],
                notesRootDirectoryURL: notesRootDirectoryURL
            )
            let frontmostDocumentPath = (scenarioInput["frontmostDocument"] as? String).map {
                workspace.rootDirectoryURL.appendingPathComponent($0).path
            }
            let pathPolicy = ClickyFilePathPolicy(
                allowedFolderPaths: workspace.editableFolderURLs.map(\.path),
                homeDirectoryPath: workspace.homeDirectoryPath,
                frontmostDocumentPath: frontmostDocumentPath
            )
            turnContext.editableFolders = pathPolicy.allowedFolderURLs.map {
                ClickyEditableFolderDescription(name: ClickyEditableFolders.displayName(forFolderPath: $0.path), path: $0.path)
            }
            turnContext.frontmostDocumentInEditableFolder = ClickyFileEditingPromptSection.frontmostDocumentDescription(
                documentPath: frontmostDocumentPath,
                policy: pathPolicy
            )
            fileEditingOutputFields = [
                "tools": ClickyFileToolDefinitions.toolsArray(),
                "filesSectionText": ClickyFileEditingPromptSection.sectionText(for: turnContext.editableFolders) ?? NSNull(),
                "frontmostDocumentLine": ClickyFileEditingPromptSection.frontmostDocumentLine(for: turnContext.frontmostDocumentInEditableFolder) ?? NSNull(),
                "filesRootPath": workspace.rootDirectoryURL.path,
                "folderPaths": workspace.editableFolderURLs.map(\.path),
                // What the request carries beyond today's: 8000 output tokens and the tools, no tool_choice.
                "maxTokens": ClickyFileEditingLimits.maximumOutputTokensWithTools,
            ]
        }

        let preparedPrompt = ClickyPromptAssembler.prepareSystemPrompt(
            for: turnContext,
            promptsDirectoryURL: promptsDirectoryURL,
            noteStore: noteStore,
            profileStore: profileStore,
            memoryStore: seedMemories == nil ? nil : memoryStore
        )
        outputRecords.append([
            "id": scenarioIdentifier,
            "systemPromptText": preparedPrompt.systemPromptText,
            // Round 4B: the facts the assembler put in the prompt, and every fact the file holds.
            "includedProfileFactTexts": preparedPrompt.includedProfileFactTexts,
            "profileFactTextsInFile": profileStore.loadFactTexts(),
            // The two halves the app sends as separate system blocks (round 4A), plus the exact
            // block array the app builds from them, so the harness can send what the app sends.
            "staticSystemPromptText": preparedPrompt.staticSystemPromptText,
            "dynamicSystemPromptText": preparedPrompt.dynamicSystemPromptText,
            "systemBlocks": ClickySystemPromptBlocks.makeSystemBlocks(
                staticText: preparedPrompt.staticSystemPromptText,
                dynamicText: preparedPrompt.dynamicSystemPromptText
            ),
            "selectedSkillNames": preparedPrompt.selectedSkillNames,
            "includedNoteTexts": preparedPrompt.includedNotes.map(\.text),
            // Round 16: the memory lines the assembler selected for this question (empty when none
            // was relevant, and then the prompt has no memories section), and every memory in the store.
            "includedMemoryTexts": preparedPrompt.includedMemories.map(\.text),
            "memoryTextsInStore": seedMemories == nil ? [] : memoryStore.loadMemories().map(\.text),
            // Round 6: the seeded marks, and the lines the app's "marks on screen" section lists for them.
            "drawingMarksOnScreen": drawingMarksOnScreen.map { drawingMarkRecord($0) },
            "drawingMarksOnScreenLineTexts": drawingMarksOnScreen.map { ClickyDrawingMarksOnScreenText.lineText(for: $0) },
        ].merging(fileEditingOutputFields) { current, _ in current })
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
        let noteStore = noteStoreForScenario(scenarioIdentifier, notesRootDirectoryURL: notesRootDirectoryURL)
        let profileStore = profileStoreForScenario(scenarioIdentifier, notesRootDirectoryURL: notesRootDirectoryURL)
        // The app passes the last exchange's assistant text so "forget that" can find what it saved.
        let previousAssistantHistoryText = replyInput["previousAssistantHistoryText"] as? String
        let profileFactTextsBefore = profileStore.loadFactTexts()
        let finishedTurn = ClickyTurnFinisher.finishTurn(
            rawReplyText: rawReplyText,
            userTranscript: userTranscript,
            noteStore: noteStore,
            profileStore: profileStore,
            previousAssistantHistoryText: previousAssistantHistoryText
        )
        // Round 6: the draw, card and row tags of the reply, read the way CompanionManager reads them: with
        // the row count of the card that is on the screen, then applied to the board in order.
        var drawingBoardForReply = drawingBoard(fromSeedDrawTagTexts: (replyInput["seedDrawTagTexts"] as? [String]) ?? [])
        let drawingMarksBeforeReply = drawingBoardForReply.marks
        let parsedDrawReply = ClickyDrawTagParser.parse(
            rawReplyText,
            rowCountOfCardAlreadyOnScreen: rowCountOfExplanationCard(on: drawingBoardForReply)
        )
        var drawCommandsThatChangedNothingCount = 0
        for parsedDrawCommand in parsedDrawReply.commands {
            if case .nothingChanged = drawingBoardForReply.apply(parsedDrawCommand.command) {
                drawCommandsThatChangedNothingCount += 1
            }
        }
        let drawHistoryAssistantText = ClickyDrawTagParser.historyAssistantText(
            rawReplyText: rawReplyText,
            finishedSpokenText: finishedTurn.spokenText,
            finishedHistoryAssistantText: finishedTurn.historyAssistantText,
            rowCountOfCardAlreadyOnScreen: rowCountOfExplanationCard(on: drawingBoard(fromSeedDrawTagTexts: (replyInput["seedDrawTagTexts"] as? [String]) ?? []))
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
            // Round 4B: profile tags Claude wrote (before the gate), what the real gate saved, what it
            // dropped, any forget outcome, and the state of both stores after the turn. Scoring uses
            // the "after" fields, so a tag the gate dropped is never counted as a save.
            "modelProfileTexts": finishedTurn.parsedReply.profileTexts,
            "savedProfileFactTexts": finishedTurn.savedProfileFactTexts,
            "droppedProfileTagCount": finishedTurn.droppedProfileTagCount,
            // Round 4C: refusals on every save path, dropped note tags, and the 100-fact hard limit.
            "secretRefusalCount": finishedTurn.secretRefusalCount,
            "droppedNoteTagCount": finishedTurn.droppedNoteTagCount,
            "profileWasFull": finishedTurn.profileWasFull,
            "profileSaveErrorDescription": finishedTurn.profileSaveErrorDescription ?? NSNull(),
            "forgetOutcome": forgetOutcomeRecord(finishedTurn.forgetOutcome),
            "profileFactTextsBefore": profileFactTextsBefore,
            "profileFactTextsAfter": profileStore.loadFactTexts(),
            "profileFileContentsAfter": profileFileContents(of: profileStore) ?? NSNull(),
            "noteTextsAfter": noteStore.loadAllNotes().map(\.text),
            // Round 6: what ClickyDrawTagParser accepted and dropped, and the board before and after.
            "drawCommands": parsedDrawReply.commands.map { drawCommandRecord($0) },
            "ignoredDrawTagCount": parsedDrawReply.ignoredDrawTagCount,
            "drawCommandsThatChangedNothingCount": drawCommandsThatChangedNothingCount,
            "drawingMarksBeforeReply": drawingMarksBeforeReply.map { drawingMarkRecord($0) },
            "drawingMarksAfterReply": drawingBoardForReply.marks.map { drawingMarkRecord($0) },
            "drawHistoryAssistantText": drawHistoryAssistantText,
        ])
    }
    writeJSON(outputRecords, toPath: outputPath)
}

// MARK: - compact (round 16: offline, zero API calls)

func memoryValidationRecord(_ validationResult: ClickyMemoryValidationResult) -> [String: Any] {
    [
        "keptMemoryTexts": validationResult.keptTexts,
        "ignoredLineCount": validationResult.ignoredLineCount,
        "droppedAsEmptyCount": validationResult.droppedAsEmptyCount,
        "droppedAsSecretCount": validationResult.droppedAsSecretCount,
        "droppedAsDuplicateCount": validationResult.droppedAsDuplicateCount,
        "droppedBeyondLimitCount": validationResult.droppedBeyondLimitCount,
        "cutLineCount": validationResult.cutLineCount,
    ]
}

/// What the app would do with a chat that ended, without asking any model: its decision, the exact
/// request body (built by the app's own `ClickyMemoryCompaction.makeRequestBody`, the same call the
/// runner makes), and the validation of a model output the harness supplies.
func runCompact(inputPath: String, outputPath: String, promptsDirectoryPath: String) {
    let promptsDirectoryURL = URL(fileURLWithPath: promptsDirectoryPath, isDirectory: true)
    let systemPromptText = ClickyMemoryCompaction.loadSystemPromptText(promptsDirectoryURL: promptsDirectoryURL)
    var outputRecords: [[String: Any]] = []

    for compactInput in readJSONArray(atPath: inputPath) {
        guard let recordIdentifier = compactInput["id"] as? String else {
            failWithMessage("compact input needs id")
        }
        // The exchanges of the chat as the app stores them (typed or spoken makes no difference to the
        // request). Timestamps are only there to make the chat well formed.
        let exchangeInputs = (compactInput["exchanges"] as? [[String: Any]]) ?? []
        let storedExchanges = exchangeInputs.enumerated().map { exchangeIndex, exchangeInput in
            ClickyChatExchange(
                userText: (exchangeInput["user"] as? String) ?? "",
                inputMode: .typed,
                replyDisplayText: (exchangeInput["clicky"] as? String) ?? "",
                replyHistoryText: (exchangeInput["clicky"] as? String) ?? "",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(exchangeIndex) * 30)
            )
        }
        var chatToCompact = ClickyChat(createdAt: Date(timeIntervalSince1970: 1_700_000_000), project: ClickyChatProject.unknown, exchanges: storedExchanges)
        chatToCompact.memoryCompactedExchangeCount = (compactInput["alreadyCompactedExchangeCount"] as? Int) ?? 0

        var outputRecord: [String: Any] = ["id": recordIdentifier]
        switch ClickyMemoryCompactionPlanner.decision(for: chatToCompact) {
        case .nothingNew:
            outputRecord["decision"] = "nothingNew"
        case .skippedAsTooShort(let coveringExchangeCount):
            outputRecord["decision"] = "skippedAsTooShort"
            outputRecord["coveringExchangeCount"] = coveringExchangeCount
        case .compact(let exchangesInRequest, let coveringExchangeCount):
            outputRecord["decision"] = "compact"
            outputRecord["coveringExchangeCount"] = coveringExchangeCount
            outputRecord["exchangeCountInRequest"] = exchangesInRequest.count
            // The `<known>` list the app sends: the record's profile facts and memories, picked by the
            // app's own `knownTexts` (memories get today's date; their date only breaks ties).
            let existingMemoriesForKnownList = ((compactInput["existingMemoryTexts"] as? [String]) ?? []).map { memoryText in
                ClickyMemory(id: UUID(), text: memoryText, createdAt: Date(), sourceChatID: nil)
            }
            let knownTexts = ClickyMemoryCompaction.knownTexts(
                profileFactTexts: (compactInput["existingProfileFactTexts"] as? [String]) ?? [],
                memories: existingMemoriesForKnownList,
                forExchanges: exchangesInRequest,
                now: Date()
            )
            outputRecord["knownTexts"] = knownTexts
            let requestBody = ClickyMemoryCompaction.makeRequestBody(forExchanges: exchangesInRequest, knownTexts: knownTexts, systemPromptText: systemPromptText)
            outputRecord["requestBody"] = requestBody
            if let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody, options: [.sortedKeys]),
               let requestBodyJSONText = String(data: requestBodyData, encoding: .utf8) {
                outputRecord["requestBodyJSON"] = requestBodyJSONText
            }
        }

        if let modelOutput = compactInput["modelOutput"] as? String {
            let validationResult = ClickyMemoryOutputValidator.validate(
                modelOutput: modelOutput,
                existingMemoryTexts: (compactInput["existingMemoryTexts"] as? [String]) ?? [],
                existingProfileFactTexts: (compactInput["existingProfileFactTexts"] as? [String]) ?? []
            )
            outputRecord["validation"] = memoryValidationRecord(validationResult)
            outputRecord["keptMemoryTexts"] = validationResult.keptTexts
        }
        outputRecords.append(outputRecord)
    }
    writeJSON(outputRecords, toPath: outputPath)
}

// MARK: - intent (offline, zero API calls, no files)

func forgetRequestRecord(_ forgetRequest: ClickyForgetRequest?) -> Any {
    guard let forgetRequest else {
        return NSNull()
    }
    switch forgetRequest {
    case .previouslySavedThing:
        return ["kind": "previouslySavedThing"]
    case .everything:
        return ["kind": "everything"]
    case .specificThing(let targetText):
        return ["kind": "specificThing", "targetText": targetText]
    case .severalThings:
        return ["kind": "severalThings"]
    case .notExecutable(let namesAMemoryObject):
        // Round 4D: a memory-change phrase that came with a question or was only a brush-off.
        // Nothing is removed for it.
        return ["kind": "notExecutable", "namesAMemoryObject": namesAMemoryObject]
    }
}

/// Reports what the intent detectors decide for each transcript, so phrasing variants can be checked
/// in bulk without a model reply or a store.
func runIntent(inputPath: String, outputPath: String) {
    var outputRecords: [[String: Any]] = []
    for intentInput in readJSONArray(atPath: inputPath) {
        guard let transcript = intentInput["transcript"] as? String else {
            failWithMessage("intent input needs transcript")
        }
        outputRecords.append([
            "id": intentInput["id"] as? String ?? transcript,
            "transcript": transcript,
            "statesLastingFactOrPreference": ClickyProfileIntentDetector.transcriptStatesLastingFactOrPreference(transcript),
            "looksLikeASecret": ClickyProfileIntentDetector.textLooksLikeASecret(transcript),
            "forgetRequest": forgetRequestRecord(ClickyProfileIntentDetector.forgetRequest(in: transcript)),
            "noteSaveText": ClickyNoteIntentDetector.explicitSaveRequestNoteText(in: transcript) ?? NSNull(),
            "noteSavingIntent": ClickyNoteIntentDetector.transcriptMentionsSavingIntent(transcript),
            "asksToRecallNotes": ClickyNoteIntentDetector.transcriptAsksToRecallNotes(transcript),
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
    // Round 6: the base prompt grew from 849 to 1,247 words when it started teaching drawing on the screen
    // and the explanation card (the keyword-triggered draw skill was folded into it). The guard is raised to
    // 1,300 so it still catches further growth; the old limit was 875.
    check("prompt: base at most 1300 words", baseWordCount <= 1300, "\(baseWordCount) words")
    let approximateTokenCount = xcodePrompt.systemPromptText.count / 4
    // Round 6: raised from 2,000 with the larger base prompt (about 2,530 by this estimate at the time).
    check("prompt: assembled xcode prompt about 2.7k tokens or less (chars/4)", approximateTokenCount <= 2700, "about \(approximateTokenCount) tokens")

    // Round 4A: static and dynamic system prompt parts, and the two-block `system` array.
    let baseFileText = ((try? String(contentsOf: skillsDirectoryURL.appendingPathComponent("clicky_base_system_prompt.md"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    check("blocks: static part is the trimmed base prompt file", xcodePrompt.staticSystemPromptText == baseFileText && !baseFileText.isEmpty)
    check("blocks: static part identical across different turn contexts", xcodePrompt.staticSystemPromptText == safariWeatherPrompt.staticSystemPromptText && xcodePrompt.staticSystemPromptText == emptyStorePrompt.staticSystemPromptText)
    check("blocks: dynamic part differs between contexts", xcodePrompt.dynamicSystemPromptText != safariWeatherPrompt.dynamicSystemPromptText)
    check("blocks: dynamic part is never empty in the app (right-now block)", !xcodePrompt.dynamicSystemPromptText.isEmpty && !safariWeatherPrompt.dynamicSystemPromptText.isEmpty)
    check("blocks: combined text == static + separator + dynamic", xcodePrompt.systemPromptText == xcodePrompt.staticSystemPromptText + ClickyPromptAssembler.systemPromptSectionSeparator + xcodePrompt.dynamicSystemPromptText)
    check("blocks: static part carries no date or app name", !xcodePrompt.staticSystemPromptText.contains("right now:") && !xcodePrompt.staticSystemPromptText.contains("com.apple.dt.Xcode"))
    let twoBlocks = ClickySystemPromptBlocks.makeSystemBlocks(staticText: xcodePrompt.staticSystemPromptText, dynamicText: xcodePrompt.dynamicSystemPromptText)
    let firstBlockCacheControl = twoBlocks.first?["cache_control"] as? [String: String]
    check("blocks: two blocks, cached static first, uncached dynamic second",
          twoBlocks.count == 2
          && twoBlocks[0]["type"] as? String == "text"
          && twoBlocks[0]["text"] as? String == xcodePrompt.staticSystemPromptText
          && firstBlockCacheControl == ["type": "ephemeral"]
          && twoBlocks[1]["type"] as? String == "text"
          && twoBlocks[1]["text"] as? String == xcodePrompt.dynamicSystemPromptText
          && twoBlocks[1]["cache_control"] == nil
          && Set(twoBlocks[0].keys) == Set(["type", "text", "cache_control"])
          && Set(twoBlocks[1].keys) == Set(["type", "text"]),
          "\(twoBlocks.map { Array($0.keys).sorted() })")
    let oneBlockEmpty = ClickySystemPromptBlocks.makeSystemBlocks(staticText: xcodePrompt.staticSystemPromptText, dynamicText: "")
    let oneBlockWhitespace = ClickySystemPromptBlocks.makeSystemBlocks(staticText: xcodePrompt.staticSystemPromptText, dynamicText: " \n\t ")
    check("blocks: blank dynamic part sends one cached block", oneBlockEmpty.count == 1 && oneBlockWhitespace.count == 1 && (oneBlockEmpty[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])
    check("blocks: blank static part is left out", ClickySystemPromptBlocks.makeSystemBlocks(staticText: "  ", dynamicText: "x").count == 1)
    // Both parts must survive a JSON round trip unchanged (the driver hands them to the harness as JSON).
    let roundTripData = (try? JSONSerialization.data(withJSONObject: twoBlocks)) ?? Data()
    let roundTripBlocks = ((try? JSONSerialization.jsonObject(with: roundTripData)) as? [[String: Any]]) ?? []
    check("blocks: JSON round trip preserves both texts", roundTripBlocks.count == 2 && roundTripBlocks[0]["text"] as? String == xcodePrompt.staticSystemPromptText && roundTripBlocks[1]["text"] as? String == xcodePrompt.dynamicSystemPromptText)
    // Static block must clear the model's minimum cacheable prefix (512 tokens on Sonnet 5.5) by a wide margin.
    check("blocks: static part is at least 2400 chars (well above 512 tokens)", xcodePrompt.staticSystemPromptText.count >= 2400, "\(xcodePrompt.staticSystemPromptText.count) chars")

    // Round 4B: PROFILE tag grammar.
    let profileTagParse = ClickyReplyTagParser.parse("got it, i'll remember that. [PROFILE:i use neovim as my editor] [POINT:none]")
    check("profile parser: PROFILE tag parsed and stripped", profileTagParse.profileTexts == ["i use neovim as my editor"] && profileTagParse.spokenText == "got it, i'll remember that." && profileTagParse.pointTarget == nil, "\(profileTagParse)")
    let profileCapParse = ClickyReplyTagParser.parse("[PROFILE:a1] [PROFILE:b2] [PROFILE:c3]")
    check("profile parser: cap of 2, all tags stripped", profileCapParse.profileTexts.count == 2 && !profileCapParse.spokenText.uppercased().contains("PROFILE"), "\(profileCapParse)")
    let truncatedProfileParse = ClickyReplyTagParser.parse("got it. [PROFILE:i use neo")
    check("profile parser: truncated PROFILE fragment stripped", truncatedProfileParse.profileTexts.isEmpty && truncatedProfileParse.spokenText == "got it.", "\(truncatedProfileParse)")
    let longProfileParse = ClickyReplyTagParser.parse("ok. [PROFILE:\(String(repeating: "y", count: 300))]")
    check("profile parser: fact capped at 200 chars", (longProfileParse.profileTexts.first?.count ?? 0) == 200, "\(longProfileParse.profileTexts.first?.count ?? -1)")

    // Round 4B: the profile gate. A tag saves only with spoken lasting-fact language, never on a secret.
    let profileGateStore = ClickyProfileStore(profileDirectoryURL: temporaryRootURL.appendingPathComponent("profile-gate", isDirectory: true))
    let profileGateNoteStore = ClickyNoteStore(notesDirectoryURL: temporaryRootURL.appendingPathComponent("profile-gate", isDirectory: true))
    let ungatedProfileTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "sure. [PROFILE:the user prefers python] [POINT:none]", userTranscript: "what's this page about", noteStore: profileGateNoteStore, profileStore: profileGateStore)
    check("profile gate: tag without spoken lasting-fact language is dropped", ungatedProfileTurn.savedProfileFactTexts.isEmpty && ungatedProfileTurn.droppedProfileTagCount == 1 && profileGateStore.loadFactTexts().isEmpty, "\(ungatedProfileTurn.savedProfileFactTexts)")
    let savedProfileTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "got it, i'll remember that. [PROFILE:i use neovim as my editor] [POINT:none]", userTranscript: "i use neovim as my editor", noteStore: profileGateNoteStore, profileStore: profileGateStore)
    check("profile gate: spoken lasting fact saves, history keeps the tag", savedProfileTurn.savedProfileFactTexts == ["i use neovim as my editor"] && profileGateStore.loadFactTexts() == ["i use neovim as my editor"] && savedProfileTurn.historyAssistantText.contains("[PROFILE:i use neovim as my editor]") && savedProfileTurn.spokenText == "got it, i'll remember that.", "\(savedProfileTurn.savedProfileFactTexts) | \(savedProfileTurn.historyAssistantText)")
    let silentSaveTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "tabs it is. [PROFILE:i prefer tabs over spaces] [POINT:none]", userTranscript: "i prefer tabs over spaces", noteStore: profileGateNoteStore, profileStore: profileGateStore)
    check("profile gate: a save the reply did not confirm gets a spoken confirmation", silentSaveTurn.spokenText.contains("i'll remember that"), silentSaveTurn.spokenText)
    let secretProfileTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "got it, i'll remember that. [PROFILE:anthropic key sk-ant-FAKEFAKEFAKE1234] [POINT:none]", userTranscript: "i always use sk-ant-FAKEFAKEFAKE1234 as my anthropic key", noteStore: profileGateNoteStore, profileStore: profileGateStore)
    check("profile gate: secret-looking fact is not saved and clicky says it won't keep it", !profileGateStore.loadFactTexts().contains { $0.contains("FAKEFAKE") } && secretProfileTurn.droppedProfileTagCount == 1 && secretProfileTurn.spokenText == "i won't keep that.", "\(secretProfileTurn.spokenText) | \(profileGateStore.loadFactTexts())")
    let passwordProfileTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "noted. [PROFILE:password is hunter2]", userTranscript: "i always use hunter2 as my password", noteStore: profileGateNoteStore, profileStore: profileGateStore)
    check("profile gate: password keyword blocks the save", !profileGateStore.loadFactTexts().contains { $0.contains("hunter2") } && passwordProfileTurn.spokenText.contains("i won't keep that"), "\(profileGateStore.loadFactTexts())")

    // Round 4B: replacement by subject, dedupe, forget variants.
    let replaceTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "got it, i'll remember that. [PROFILE:i use vs code as my editor now]", userTranscript: "i switched, i use vs code as my editor now", noteStore: profileGateNoteStore, profileStore: profileGateStore)
    let factsAfterReplace = profileGateStore.loadFactTexts()
    check("profile store: new editor fact replaces old editor fact, unrelated fact stays", !factsAfterReplace.contains("i use neovim as my editor") && factsAfterReplace.contains("i use vs code as my editor now") && factsAfterReplace.contains("i prefer tabs over spaces") && replaceTurn.savedProfileFactTexts.count == 1, "\(factsAfterReplace)")
    let forgetSpecificTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "okay. [POINT:none]", userTranscript: "forget my editor", noteStore: profileGateNoteStore, profileStore: profileGateStore)
    check("forget: 'forget my editor' removes only the editor fact", forgetSpecificTurn.forgetOutcome?.kind == .removed && profileGateStore.loadFactTexts() == ["i prefer tabs over spaces"] && forgetSpecificTurn.spokenText == "okay, i've forgotten that.", "\(profileGateStore.loadFactTexts()) | \(forgetSpecificTurn.spokenText)")
    let forgetEverythingTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "okay. [POINT:none]", userTranscript: "forget everything", noteStore: profileGateNoteStore, profileStore: profileGateStore)
    check("forget: 'forget everything' is refused and removes nothing", forgetEverythingTurn.forgetOutcome?.kind == .refusedToWipeEverything && profileGateStore.loadFactTexts() == ["i prefer tabs over spaces"], "\(profileGateStore.loadFactTexts())")
    let forgetThatNothingTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "okay. [POINT:none]", userTranscript: "forget that", noteStore: profileGateNoteStore, profileStore: profileGateStore, previousAssistantHistoryText: "the run button is top left. ")
    check("forget: 'forget that' with nothing saved last turn removes nothing", forgetThatNothingTurn.forgetOutcome?.kind == .noMatch && profileGateStore.loadFactTexts() == ["i prefer tabs over spaces"] && forgetThatNothingTurn.spokenText == "i didn't forget anything. i don't have that saved.", "\(profileGateStore.loadFactTexts()) | \(forgetThatNothingTurn.spokenText)")
    let forgetThatAfterSaveTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "okay. [POINT:none]", userTranscript: "forget that", noteStore: profileGateNoteStore, profileStore: profileGateStore, previousAssistantHistoryText: "got it, i'll remember that. [PROFILE:i prefer tabs over spaces]")
    check("forget: 'forget that' right after a save removes exactly that fact", forgetThatAfterSaveTurn.forgetOutcome?.kind == .removed && profileGateStore.loadFactTexts().isEmpty, "\(profileGateStore.loadFactTexts())")
    let dontForgetTurn = ClickyTurnFinisher.finishTurn(rawReplyText: "got it, noted. [NOTE:buy milk on the way home]", userTranscript: "don't forget to buy milk on the way home", noteStore: profileGateNoteStore, profileStore: profileGateStore)
    check("forget: 'don't forget to ...' is a note save, not a forget", dontForgetTurn.forgetOutcome == nil && dontForgetTurn.savedNoteTexts == ["buy milk on the way home"], "\(String(describing: dontForgetTurn.forgetOutcome)) | \(dontForgetTurn.savedNoteTexts)")

    // Round 4B: injection budget with 25 facts, file untouched.
    let budgetProfileStore = ClickyProfileStore(profileDirectoryURL: temporaryRootURL.appendingPathComponent("profile-budget", isDirectory: true))
    try? FileManager.default.createDirectory(at: budgetProfileStore.profileDirectoryURL, withIntermediateDirectories: true)
    let twentyFiveFactLines = (1...25).map { "- fact number \($0) about something distinct \(String(repeating: "x", count: 40))" }
    try? ("# Clicky profile\n\n" + twentyFiveFactLines.joined(separator: "\n") + "\n").write(to: budgetProfileStore.profileFileURL, atomically: true, encoding: .utf8)
    let budgetedFacts = budgetProfileStore.factTextsWithinInjectionBudget()
    let budgetedCharacterCount = budgetedFacts.reduce(0) { $0 + $1.count + ClickyProfileStore.injectedLineOverheadCharacterCount }
    check("profile budget: 25 facts inject at most 20 and 1000 chars, newest kept", budgetedFacts.count <= 20 && budgetedCharacterCount <= 1000 && budgetedFacts.last?.hasPrefix("fact number 25") == true && budgetProfileStore.loadFactTexts().count == 25, "count \(budgetedFacts.count), chars \(budgetedCharacterCount)")

    // Round 6: draw, card and row tags through the app's parsers and board.
    let drawSampleReplyText = "the search field is up here. [DRAW:circle:640,52:38] and this is the run button. [DRAW:callout:150,46:run button] [POINT:none]"
    let drawSampleFinishedTurn = ClickyTurnFinisher.finishTurn(rawReplyText: drawSampleReplyText, userTranscript: "circle the search field", noteStore: profileGateNoteStore, profileStore: profileGateStore)
    check("draw: tags never reach the spoken text", drawSampleFinishedTurn.spokenText == "the search field is up here. and this is the run button.", drawSampleFinishedTurn.spokenText)
    let drawSampleParsedReply = ClickyDrawTagParser.parse(drawSampleReplyText)
    check("draw: two commands accepted, none ignored, POINT none kept", drawSampleParsedReply.commands.count == 2 && drawSampleParsedReply.ignoredDrawTagCount == 0 && drawSampleFinishedTurn.parsedReply.pointTarget == nil, "\(drawSampleParsedReply.commands.count) / \(drawSampleParsedReply.ignoredDrawTagCount)")
    let nineCircleReplyText = (1...9).map { "[DRAW:circle:\($0 * 10),50:20]" }.joined(separator: " ")
    let nineCircleParsedReply = ClickyDrawTagParser.parse(nineCircleReplyText)
    check("draw: ninth draw tag is dropped by the per-reply limit", nineCircleParsedReply.commands.count == ClickyDrawTagParser.maximumDrawTagCountPerReply && nineCircleParsedReply.ignoredDrawTagCount == 1, "\(nineCircleParsedReply.commands.count) / \(nineCircleParsedReply.ignoredDrawTagCount)")
    let malformedDrawParsedReply = ClickyDrawTagParser.parse("here. [DRAW:circle:640] [ROW:text:no card to go on] [POINT:none]")
    check("draw: malformed tag and a row without a card are ignored", malformedDrawParsedReply.commands.isEmpty && malformedDrawParsedReply.ignoredDrawTagCount == 2, "\(malformedDrawParsedReply.commands.count) / \(malformedDrawParsedReply.ignoredDrawTagCount)")
    let cardSampleParsedReply = ClickyDrawTagParser.parse("here's how. [CARD:how it works] first. [ROW:flow:guess > compare > adjust] then. [ROW:boxes:a|b -> c] [POINT:none]")
    var cardSampleBoard = ClickyDrawingBoard()
    for cardSampleCommand in cardSampleParsedReply.commands {
        _ = cardSampleBoard.apply(cardSampleCommand.command)
    }
    check("card: one card with two rows lands on the board", cardSampleParsedReply.commands.count == 3 && rowCountOfExplanationCard(on: cardSampleBoard) == 2, "\(cardSampleParsedReply.commands.count) / \(String(describing: rowCountOfExplanationCard(on: cardSampleBoard)))")
    let seededBoard = drawingBoard(fromSeedDrawTagTexts: ["[DRAW:circle:150,46:20] [DRAW:box:10,125:210,34]", "[CARD:how it works] [ROW:flow:guess > compare]"])
    check("draw seed: three marks m1, m2, m3 with a one-row card", seededBoard.marks.map(\.markIdentifier) == ["m1", "m2", "m3"] && rowCountOfExplanationCard(on: seededBoard) == 1, "\(seededBoard.marks.map(\.markIdentifier))")
    let rowOnSeededCardParsedReply = ClickyDrawTagParser.parse("added. [ROW:text:one more line] [POINT:none]", rowCountOfCardAlreadyOnScreen: rowCountOfExplanationCard(on: seededBoard))
    check("draw seed: a lone row goes on the card that is on screen", rowOnSeededCardParsedReply.commands.count == 1 && rowOnSeededCardParsedReply.ignoredDrawTagCount == 0)
    let marksOnScreenSectionText = ClickyDrawingMarksOnScreenText.sectionText(for: drawingMarksForPrompt(on: seededBoard, screenCount: 1)) ?? ""
    check("draw seed: marks on screen text lists every id and no screen number with one screen", marksOnScreenSectionText.contains("m1: circle at 150,46 radius 20") && marksOnScreenSectionText.contains("m3: card titled") && !marksOnScreenSectionText.contains("(screen"), marksOnScreenSectionText)
    let twoScreenMarksOnScreenSectionText = ClickyDrawingMarksOnScreenText.sectionText(for: drawingMarksForPrompt(on: seededBoard, screenCount: 2)) ?? ""
    check("draw seed: with two screens every mark carries its screen", twoScreenMarksOnScreenSectionText.contains("m1: circle at 150,46 radius 20 (screen 1)"), twoScreenMarksOnScreenSectionText)
    let ordinaryTurnPrompt = ClickyPromptAssembler.prepareSystemPrompt(
        for: ClickyTurnContext(userTranscript: "what is a closure", frontmostApplicationBundleIdentifier: "com.apple.dt.Xcode", frontmostApplicationName: "Xcode", screenCount: 1, currentDate: Date()),
        promptsDirectoryURL: URL(fileURLWithPath: promptsDirectoryPath, isDirectory: true), noteStore: profileGateNoteStore, profileStore: nil
    )
    check("draw: an ordinary turn's prompt has no marks on screen section", !ordinaryTurnPrompt.systemPromptText.contains("marks on screen ("))

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

// MARK: - Round 17: file editing (tool and finish-files modes)

/// The temporary folders a record's files live in.
struct EvalFilesWorkspace {
    let rootDirectoryURL: URL
    let editableFolderURLs: [URL]
    let homeDirectoryPath: String
}

func seedFilesWorkspace(
    scenarioIdentifier: String,
    editableFolderNames: [String]?,
    files: [[String: Any]],
    notesRootDirectoryURL: URL
) -> EvalFilesWorkspace {
    requireTemporaryNotesRoot(notesRootDirectoryURL)
    let rootDirectoryURL = notesRootDirectoryURL.appendingPathComponent("\(scenarioIdentifier)-files", isDirectory: true)
    let folderNames = editableFolderNames ?? ["project"]
    var editableFolderURLs: [URL] = []
    for folderName in folderNames {
        let folderURL = rootDirectoryURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            failWithMessage("could not create \(folderURL.path): \(error.localizedDescription)")
        }
        editableFolderURLs.append(folderURL)
    }
    for seededFile in files {
        guard let relativePath = seededFile["path"] as? String, let content = seededFile["content"] as? String else {
            failWithMessage("a seeded file needs path and content (\(scenarioIdentifier))")
        }
        let firstPathComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
        let pathBelowRoot = folderNames.contains(firstPathComponent) ? relativePath : "\(folderNames.first ?? "project")/\(relativePath)"
        let fileURL = rootDirectoryURL.appendingPathComponent(pathBelowRoot)
        // A seeded file must stay inside the temporary root: no absolute path and no ".." part.
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            failWithMessage("a seeded file path leaves the temporary root: \(relativePath)")
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            failWithMessage("could not seed \(fileURL.path): \(error.localizedDescription)")
        }
    }
    return EvalFilesWorkspace(
        rootDirectoryURL: rootDirectoryURL,
        editableFolderURLs: editableFolderURLs,
        homeDirectoryPath: rootDirectoryURL.appendingPathComponent("home").path
    )
}

func substitutingRootPlaceholder(in value: Any, rootPath: String) -> Any {
    if let text = value as? String {
        return text.replacingOccurrences(of: "{root}", with: rootPath)
    }
    if let array = value as? [Any] {
        return array.map { substitutingRootPlaceholder(in: $0, rootPath: rootPath) }
    }
    if let dictionary = value as? [String: Any] {
        return dictionary.mapValues { substitutingRootPlaceholder(in: $0, rootPath: rootPath) }
    }
    return value
}

func diffLineRecord(_ diffLine: ClickyDiffLine) -> [String: Any] {
    let kindName: String
    switch diffLine.kind {
    case .context: kindName = "context"
    case .added: kindName = "added"
    case .removed: kindName = "removed"
    case .hunkSeparator: kindName = "separator"
    }
    return [
        "kind": kindName,
        "text": diffLine.text,
        "oldLineNumber": diffLine.oldLineNumber ?? NSNull(),
        "newLineNumber": diffLine.newLineNumber ?? NSNull(),
    ]
}

func fileChangeRecord(_ change: ClickyFileChange) -> [String: Any] {
    let cardContent = ClickyChangeCardContent.make(for: [change])
    return [
        "action": change.action.rawValue,
        "relativePath": change.relativePath,
        "summary": change.summary,
        "historyLine": ClickyChangeHistoryText.proposalLine(for: change),
        "diffLines": change.diffPreviewLines.map(diffLineRecord),
        "hiddenDiffLineCount": change.hiddenDiffLineCount,
        "noteText": cardContent.sections.first?.noteText ?? NSNull(),
    ]
}

/// Every file below `rootDirectoryURL` and its text, so a grader can see that a proposal wrote nothing.
func fileTextsBelow(_ rootDirectoryURL: URL) -> [String: String] {
    var fileTexts: [String: String] = [:]
    guard let enumerator = FileManager.default.enumerator(at: rootDirectoryURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return fileTexts
    }
    let rootPath = rootDirectoryURL.standardizedFileURL.path
    for case let fileURL as URL in enumerator {
        guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(rootPath.count + 1))
        fileTexts[relativePath] = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(not text)"
    }
    return fileTexts
}

func runTool(inputPath: String, outputPath: String, notesRootPath: String) {
    let notesRootDirectoryURL = URL(fileURLWithPath: notesRootPath, isDirectory: true)
    requireTemporaryNotesRoot(notesRootDirectoryURL)
    var outputRecords: [[String: Any]] = []

    for toolRecord in readJSONArray(atPath: inputPath) {
        guard let scenarioIdentifier = toolRecord["id"] as? String else {
            failWithMessage("tool input needs id")
        }
        let workspace = seedFilesWorkspace(
            scenarioIdentifier: scenarioIdentifier,
            editableFolderNames: toolRecord["editableFolders"] as? [String],
            files: (toolRecord["files"] as? [[String: Any]]) ?? [],
            notesRootDirectoryURL: notesRootDirectoryURL
        )
        let frontmostDocumentPath = (toolRecord["frontmostDocument"] as? String).map {
            workspace.rootDirectoryURL.appendingPathComponent($0).path
        }
        let pathPolicy = ClickyFilePathPolicy(
            allowedFolderPaths: workspace.editableFolderURLs.map(\.path),
            homeDirectoryPath: workspace.homeDirectoryPath,
            frontmostDocumentPath: frontmostDocumentPath
        )
        let toolSession = ClickyFileToolTurnSession(policy: pathPolicy)

        var toolCalls: [[String: Any]] = (toolRecord["calls"] as? [[String: Any]]) ?? []
        if toolCalls.isEmpty, let toolName = toolRecord["toolName"] as? String {
            toolCalls = [["toolName": toolName, "input": (toolRecord["input"] as? [String: Any]) ?? [:]]]
        }
        var callResults: [[String: Any]] = []
        for toolCall in toolCalls {
            guard let toolName = toolCall["toolName"] as? String else {
                failWithMessage("a tool call needs toolName (\(scenarioIdentifier))")
            }
            let rawInput = (toolCall["input"] as? [String: Any]) ?? [:]
            let input = substitutingRootPlaceholder(in: rawInput, rootPath: workspace.rootDirectoryURL.path) as? [String: Any] ?? rawInput
            let toolResult = toolSession.execute(toolName: toolName, input: input)
            callResults.append(["toolName": toolName, "resultText": toolResult.text, "isError": toolResult.isError])
        }

        var outputRecord: [String: Any] = [
            "id": scenarioIdentifier,
            "results": callResults,
            "queuedChanges": toolSession.queuedChanges.map(fileChangeRecord),
            "toolCallCount": toolSession.toolCallCount,
            "bytesRead": toolSession.bytesRead,
            "rootPath": workspace.rootDirectoryURL.path,
            "folderPaths": workspace.editableFolderURLs.map(\.path),
            "filesAfter": fileTextsBelow(workspace.rootDirectoryURL),
        ]
        if let firstResult = callResults.first {
            outputRecord["resultText"] = firstResult["resultText"]
            outputRecord["isError"] = firstResult["isError"]
        }
        outputRecords.append(outputRecord)
    }
    writeJSON(outputRecords, toPath: outputPath)
}

func runFinishFiles(inputPath: String, outputPath: String) {
    var outputRecords: [[String: Any]] = []
    for record in readJSONArray(atPath: inputPath) {
        guard let recordIdentifier = record["id"] as? String,
              let spokenText = record["spokenText"] as? String,
              let queuedChangeCount = record["queuedChangeCount"] as? Int else {
            failWithMessage("finish-files input needs id, spokenText, queuedChangeCount")
        }
        let usedFileTools = (record["usedFileTools"] as? Bool) ?? (queuedChangeCount > 0)
        var outputRecord: [String: Any] = [
            "id": recordIdentifier,
            "honestText": ClickyFileEditingHonesty.honestSpokenText(spokenText, queuedChangeCount: queuedChangeCount, usedFileTools: usedFileTools),
        ]
        if let transcript = record["transcript"] as? String {
            switch ClickyChangeConfirmationPhrases.intent(forTranscript: transcript) {
            case .confirm?: outputRecord["intent"] = "confirm"
            case .cancel?: outputRecord["intent"] = "cancel"
            case .undo?: outputRecord["intent"] = "undo"
            case nil: outputRecord["intent"] = NSNull()
            }
        }
        outputRecords.append(outputRecord)
    }
    writeJSON(outputRecords, toPath: outputPath)
}

// MARK: - entry point

let commandLineArguments = CommandLine.arguments
guard commandLineArguments.count >= 2 else {
    failWithMessage("usage: prepare|finish|intent|compact|tool|finish-files|selftest with arguments (see the header of main.swift)")
}
switch commandLineArguments[1] {
case "prepare" where commandLineArguments.count == 6:
    runPrepare(inputPath: commandLineArguments[2], outputPath: commandLineArguments[3], promptsDirectoryPath: commandLineArguments[4], notesRootPath: commandLineArguments[5])
case "finish" where commandLineArguments.count == 5:
    runFinish(inputPath: commandLineArguments[2], outputPath: commandLineArguments[3], notesRootPath: commandLineArguments[4])
case "compact" where commandLineArguments.count == 5:
    runCompact(inputPath: commandLineArguments[2], outputPath: commandLineArguments[3], promptsDirectoryPath: commandLineArguments[4])
case "intent" where commandLineArguments.count == 4:
    runIntent(inputPath: commandLineArguments[2], outputPath: commandLineArguments[3])
case "tool" where commandLineArguments.count == 5:
    runTool(inputPath: commandLineArguments[2], outputPath: commandLineArguments[3], notesRootPath: commandLineArguments[4])
case "finish-files" where commandLineArguments.count == 4:
    runFinishFiles(inputPath: commandLineArguments[2], outputPath: commandLineArguments[3])
case "selftest" where commandLineArguments.count == 4:
    runSelfTest(outputPath: commandLineArguments[2], promptsDirectoryPath: commandLineArguments[3])
default:
    failWithMessage("bad arguments for mode \(commandLineArguments[1])")
}
