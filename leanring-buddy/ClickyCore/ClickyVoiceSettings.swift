import Foundation

// Clicky's voice (round 20, the voice picker): which ElevenLabs voice speaks and how fast, the body
// of the Worker's /tts request, the voice list the Worker's /voices route returns, the rows of the
// picker, and the names and limits of the cached samples. Pure, so every rule can be checked
// without the app or the network.
//
// The Worker side (the /voices route, the voice_id and speed fields of /tts, the fallback header) is
// the orchestrator's PR. The app builds to the contract: with nothing chosen and the normal speed,
// the /tts body is byte for byte the body Clicky has always sent, so the Worker's own default voice
// (ELEVENLABS_VOICE_ID) speaks exactly as before.
//
// Privacy: voice names and ids live only in `UserDefaults` and the voices cache file; a sample file
// holds only the fixed sentence. None of them reaches the model, a metrics line or the console.

// MARK: - The settings

/// The voice and the speed, as stored in three `UserDefaults` keys.
nonisolated struct ClickyVoiceSettings: Codable, Equatable, Sendable {
    /// The chosen ElevenLabs voice. nil means the Worker's default voice.
    var chosenVoiceID: String?
    /// The chosen voice's name, kept so the settings tab can say it before the list has loaded.
    var chosenVoiceName: String?
    /// One of `speedSteps`.
    var speedPercent: Int

    /// The five speeds the settings tab offers, slowest first.
    static let speedSteps = [80, 90, 100, 110, 120]
    /// The voice's own pace: no speed is sent at all.
    static let normalSpeedPercent = 100

    /// The speed range the app ever sends (the Worker clamps to the same range).
    static let minimumSpeed = 0.7
    static let maximumSpeed = 1.2

    /// Nothing chosen: the Worker's default voice at its own pace (today's /tts body).
    static let `default` = ClickyVoiceSettings(chosenVoiceID: nil, chosenVoiceName: nil, speedPercent: normalSpeedPercent)

    /// The step a stored or given percent stands for: one of the five steps, or the normal speed for
    /// anything else (a stored 95 reads as 100).
    static func speedStep(forPercent speedPercent: Int) -> Int {
        speedSteps.contains(speedPercent) ? speedPercent : normalSpeedPercent
    }

    /// The word of a step on the speed choice.
    static func speedStepTitle(forPercent speedPercent: Int) -> String {
        switch speedStep(forPercent: speedPercent) {
        case 80: return "slower"
        case 90: return "slow"
        case 110: return "fast"
        case 120: return "faster"
        default: return "normal"
        }
    }

    /// The hint under the speed row: what the step means as a factor of the voice's own pace.
    static func speedHint(forPercent speedPercent: Int) -> String {
        let stepPercent = speedStep(forPercent: speedPercent)
        guard stepPercent != normalSpeedPercent else {
            return "1.0 is the voice's own pace"
        }
        return String(format: "%.1f×", Double(stepPercent) / 100)
    }

    /// Keeps a speed inside 0.7...1.2. Something that is not a number is the normal pace.
    static func clampedSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1.0 }
        return min(max(speed, minimumSpeed), maximumSpeed)
    }

    /// The speed as a factor (1.1 for 110), or nil at the normal pace, when no speed is sent.
    var speedValue: Double? {
        let stepPercent = Self.speedStep(forPercent: speedPercent)
        guard stepPercent != Self.normalSpeedPercent else { return nil }
        return Self.clampedSpeed(Double(stepPercent) / 100)
    }

    /// The same speed as an exact decimal, the form the request body carries it in: JSON then reads
    /// "1.1", where the double would be written "1.1000000000000001". nil at the normal pace.
    var speedDecimalForRequestBody: Decimal? {
        let stepPercent = Self.speedStep(forPercent: speedPercent)
        guard stepPercent != Self.normalSpeedPercent else { return nil }
        let clampedPercent = min(max(stepPercent, Int(Self.minimumSpeed * 100)), Int(Self.maximumSpeed * 100))
        return Decimal(clampedPercent) / Decimal(100)
    }

    /// An ElevenLabs voice id the app may send: 1 to 64 characters, each a letter, a digit, "_" or "-".
    static func isUsableVoiceID(_ voiceID: String) -> Bool {
        let scalars = voiceID.unicodeScalars
        guard (1...64).contains(scalars.count) else { return false }
        return scalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
        }
    }

    /// The voice id the request carries: the chosen one when it is usable, else nothing (and the
    /// Worker's default voice speaks).
    var voiceIDToSend: String? {
        guard let chosenVoiceID, Self.isUsableVoiceID(chosenVoiceID) else { return nil }
        return chosenVoiceID
    }

    /// Whether a voice of the account is chosen (as opposed to the Worker's default).
    var hasChosenVoice: Bool {
        voiceIDToSend != nil
    }

    /// Settings read back from what is stored. An id that is not usable means nothing is chosen (and
    /// then the name means nothing either); the name is cleaned like a name from the list; a speed
    /// that is not a step is the normal pace.
    static func settings(storedVoiceID: Any?, storedVoiceName: Any?, storedSpeedPercent: Any?) -> ClickyVoiceSettings {
        // Only a whole number can be a step (a stored 110.5 is not 110).
        let storedWholePercent = (storedSpeedPercent as? NSNumber).flatMap { storedNumber -> Int? in
            storedNumber.doubleValue == storedNumber.doubleValue.rounded() ? storedNumber.intValue : nil
        }
        let speedPercent = speedStep(forPercent: storedWholePercent ?? normalSpeedPercent)
        guard let storedVoiceIDText = storedVoiceID as? String, isUsableVoiceID(storedVoiceIDText) else {
            return ClickyVoiceSettings(chosenVoiceID: nil, chosenVoiceName: nil, speedPercent: speedPercent)
        }
        let cleanedName = (storedVoiceName as? String).map { ClickyVoiceList.cleanedText($0) }
        return ClickyVoiceSettings(
            chosenVoiceID: storedVoiceIDText,
            chosenVoiceName: (cleanedName?.isEmpty ?? true) ? nil : cleanedName,
            speedPercent: speedPercent
        )
    }

    /// The line in the console when the voice settings change: fixed words and a number only, never a
    /// voice's name or id ("voice: chosen, speed: 110").
    var consoleWords: String {
        "voice: \(hasChosenVoice ? "chosen" : "default"), speed: \(Self.speedStep(forPercent: speedPercent))"
    }
}

// MARK: - The /tts request body

nonisolated enum ClickyTextToSpeechRequestBody {
    static let modelID = "eleven_flash_v2_5"
    static let stability = 0.5
    static let similarityBoost = 0.75

    /// The Worker adds this header (value "1") when it spoke with its default voice because the voice
    /// asked for is not in the account's list (or the id was malformed).
    static let voiceFallbackHeaderName = "X-Clicky-Voice-Fallback"

    /// The body of a /tts request. With the default settings it holds exactly today's three fields
    /// (`text`, `model_id`, `voice_settings` with `stability` and `similarity_boost`). A usable chosen
    /// voice adds `voice_id` (the Worker takes it out and puts it in the ElevenLabs path); a speed
    /// other than the normal pace adds `voice_settings.speed`. Nothing else is ever added.
    static func make(text: String, voiceSettings: ClickyVoiceSettings) -> [String: Any] {
        var voiceSettingsField: [String: Any] = [
            "stability": stability,
            "similarity_boost": similarityBoost,
        ]
        if let speedDecimal = voiceSettings.speedDecimalForRequestBody {
            voiceSettingsField["speed"] = speedDecimal
        }
        var requestBody: [String: Any] = [
            "text": text,
            "model_id": modelID,
            "voice_settings": voiceSettingsField,
        ]
        if let voiceID = voiceSettings.voiceIDToSend {
            requestBody["voice_id"] = voiceID
        }
        return requestBody
    }

    /// Whether a response's fallback header says the Worker's default voice spoke instead.
    static func responseUsedDefaultVoiceAsFallback(fallbackHeaderValue: String?) -> Bool {
        fallbackHeaderValue?.trimmingCharacters(in: .whitespaces) == "1"
    }
}

// MARK: - The voice list

/// One voice of the account, as the Worker's /voices route lists it (text cleaned).
nonisolated struct ClickyVoice: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// ElevenLabs' word: premade, cloned, generated, professional, or another word. nil when absent.
    let category: String?
    let labels: [String: String]

    /// Voices the account made itself: cloned and generated ones.
    var isYours: Bool {
        guard let category else { return false }
        return ["cloned", "generated"].contains(category.lowercased())
    }

    /// Professional voices, most likely added to the account from ElevenLabs' voice library rather
    /// than made by Sam (12 of the account's 35 voices on 14 Nov 2026).
    var isProfessional: Bool {
        category?.lowercased() == "professional"
    }

    var isPremade: Bool {
        category?.lowercased() == "premade"
    }

    /// The word for the voice's kind: "yours" (cloned, generated), "pro" (professional), "premade",
    /// or nothing for any other category.
    var categoryWord: String? {
        if isYours { return "yours" }
        if isProfessional { return "pro" }
        if isPremade { return "premade" }
        return nil
    }

    /// The small grey line under the name: the accent, gender and age labels that exist, then the
    /// "descriptive" label ("description" when there is no "descriptive"; the account's voices carry
    /// "descriptive", 31 of 35 on 14 Nov 2026, and none "description"), then the category word,
    /// joined with " · ".
    var subtitle: String {
        func labelText(_ labelKey: String) -> String? {
            guard let labelValue = labels[labelKey], !labelValue.isEmpty else { return nil }
            return labelValue
        }
        var subtitleParts = ["accent", "gender", "age"].compactMap { labelText($0) }
        if let describingWords = labelText("descriptive") ?? labelText("description") {
            subtitleParts.append(describingWords)
        }
        if let categoryWord {
            subtitleParts.append(categoryWord)
        }
        return subtitleParts.joined(separator: " · ")
    }

    /// The order of the groups: the account's own voices, then the professional ones, then the
    /// premade ones, anything else last.
    fileprivate var groupOrder: Int {
        if isYours { return 0 }
        if isProfessional { return 1 }
        if isPremade { return 2 }
        return 3
    }
}

/// The account's voices and the Worker's default voice, as returned by POST /voices (and kept on disk
/// so the picker shows at once next time, even offline).
nonisolated struct ClickyVoiceList: Codable, Equatable, Sendable {
    var voices: [ClickyVoice]
    /// The Worker's default voice (ELEVENLABS_VOICE_ID). It may be missing from `voices`.
    var defaultVoiceID: String?
    /// When the Worker answered.
    var fetchedAt: Date

    // The same key names as the Worker's answer, so the cache file is read by the same tolerant
    // `decode` as the answer itself.
    private enum CodingKeys: String, CodingKey {
        case voices
        case defaultVoiceID = "defaultVoiceId"
        case fetchedAt
    }

    /// Every name, category, label key and label value is cut to this many characters.
    static let maximumTextLength = 60

    /// One line with no square brackets, at most 60 characters: line breaks, tabs and other control
    /// characters become spaces, runs of spaces become one, and the ends are trimmed.
    static func cleanedText(_ rawText: String) -> String {
        var cleanedScalars = String.UnicodeScalarView()
        var previousScalarWasSpace = false
        for scalar in rawText.unicodeScalars {
            if scalar == "[" || scalar == "]" {
                continue
            }
            let isSpaceLike = CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
            if isSpaceLike {
                if !previousScalarWasSpace {
                    cleanedScalars.append(" ")
                }
                previousScalarWasSpace = true
            } else {
                cleanedScalars.append(scalar)
                previousScalarWasSpace = false
            }
        }
        let oneLineText = String(cleanedScalars).trimmingCharacters(in: .whitespaces)
        guard oneLineText.count > maximumTextLength else {
            return oneLineText
        }
        return String(oneLineText.prefix(maximumTextLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Reads the Worker's answer (or the cache file), tolerantly:
    /// - a body that is not a JSON object is nil (the app then keeps what it has);
    /// - a missing or malformed `voices` is an empty list;
    /// - an entry without a string `id` and `name`, with an id the app could not send, or with a name
    ///   that is empty once cleaned, is skipped;
    /// - `category` is optional; `labels` keeps only string values;
    /// - every text is cleaned (one line, no brackets, at most 60 characters);
    /// - `defaultVoiceId` is kept only when it is a usable id;
    /// - `fetchedAt` comes from the cache file, or is the given moment for an answer of the Worker.
    static func decode(_ data: Data, fetchedAt: Date = Date()) -> ClickyVoiceList? {
        guard let rootObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let voiceEntries = rootObject["voices"] as? [Any] ?? []
        var decodedVoices: [ClickyVoice] = []
        var seenVoiceIDs = Set<String>()
        for voiceEntry in voiceEntries {
            guard let voiceObject = voiceEntry as? [String: Any],
                  let voiceID = voiceObject["id"] as? String,
                  ClickyVoiceSettings.isUsableVoiceID(voiceID),
                  let rawName = voiceObject["name"] as? String else {
                continue
            }
            let cleanedName = cleanedText(rawName)
            // A second entry with the same id would make two rows that choose the same voice.
            guard !cleanedName.isEmpty, !seenVoiceIDs.contains(voiceID) else { continue }
            seenVoiceIDs.insert(voiceID)
            let cleanedCategory = (voiceObject["category"] as? String).map { cleanedText($0) }
            var cleanedLabels: [String: String] = [:]
            for (labelKey, labelValue) in voiceObject["labels"] as? [String: Any] ?? [:] {
                guard let labelText = labelValue as? String else { continue }
                let cleanedLabelKey = cleanedText(labelKey)
                let cleanedLabelText = cleanedText(labelText)
                guard !cleanedLabelKey.isEmpty, !cleanedLabelText.isEmpty else { continue }
                cleanedLabels[cleanedLabelKey] = cleanedLabelText
            }
            decodedVoices.append(ClickyVoice(
                id: voiceID,
                name: cleanedName,
                category: (cleanedCategory?.isEmpty ?? true) ? nil : cleanedCategory,
                labels: cleanedLabels
            ))
        }
        let defaultVoiceID = (rootObject["defaultVoiceId"] as? String).flatMap { ClickyVoiceSettings.isUsableVoiceID($0) ? $0 : nil }
        let storedFetchedAt = (rootObject["fetchedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ClickyVoiceList(voices: decodedVoices, defaultVoiceID: defaultVoiceID, fetchedAt: storedFetchedAt ?? fetchedAt)
    }

    func containsVoice(withID voiceID: String?) -> Bool {
        guard let voiceID else { return false }
        return voices.contains { $0.id == voiceID }
    }

    /// The order the picker lists them in: the chosen voice first, then the account's own voices,
    /// the professional ones, the premade ones (anything else last), then by name (and by id among
    /// equal names, so the order never wobbles).
    func sorted(chosenVoiceID: String?) -> [ClickyVoice] {
        voices.sorted { firstVoice, secondVoice in
            let firstIsChosen = firstVoice.id == chosenVoiceID
            let secondIsChosen = secondVoice.id == chosenVoiceID
            if firstIsChosen != secondIsChosen {
                return firstIsChosen
            }
            if firstVoice.groupOrder != secondVoice.groupOrder {
                return firstVoice.groupOrder < secondVoice.groupOrder
            }
            let firstLowercasedName = firstVoice.name.lowercased()
            let secondLowercasedName = secondVoice.name.lowercased()
            if firstLowercasedName != secondLowercasedName {
                return firstLowercasedName < secondLowercasedName
            }
            return firstVoice.id < secondVoice.id
        }
    }
}

// MARK: - The picker's rows

/// One row of the voice picker in the settings tab.
nonisolated struct ClickyVoicePickerRow: Equatable, Sendable, Identifiable {
    /// The voice's id, or `ClickyVoicePickerRows.workerDefaultRowIdentifier` for the "default
    /// (worker)" row.
    let id: String
    let title: String
    let subtitle: String
    /// The Worker's default voice: the row shows a "default" tag.
    let isWorkerDefaultVoice: Bool
    let isChosen: Bool
    /// What choosing the row stores. nil for the Worker's default voice (in the list or in its own
    /// row): nothing is chosen then, and the /tts body is today's.
    let voiceIDToChoose: String?
    let voiceNameToChoose: String?
    /// The voice id the row's sample is cached under (the Worker's default voice id for the default
    /// row, or "default" when no list has given one).
    let sampleCacheVoiceID: String
}

nonisolated enum ClickyVoicePickerRows {
    static let workerDefaultRowIdentifier = "worker-default"
    static let workerDefaultRowTitle = "default (worker)"
    static let workerDefaultRowSubtitle = "the voice the worker speaks with"

    /// The rows of the picker. The Worker's default voice is always one row and choosing it stores
    /// nothing (so going back to the default always sends today's body): it is the voice's own row
    /// with a "default" tag when the voice is in the list, and a "default (worker)" row first when it
    /// is not, when the list does not name it, when the list is empty or when no list has loaded.
    /// With nothing chosen, that row carries the chosen mark and comes first.
    static func rows(voiceList: ClickyVoiceList?, chosenVoiceID: String?) -> [ClickyVoicePickerRow] {
        let defaultVoiceID = voiceList?.defaultVoiceID
        let usableChosenVoiceID = chosenVoiceID.flatMap { ClickyVoiceSettings.isUsableVoiceID($0) ? $0 : nil }
        func isTheWorkersDefaultChosen() -> Bool {
            usableChosenVoiceID == nil || usableChosenVoiceID == defaultVoiceID
        }

        var pickerRows: [ClickyVoicePickerRow] = []
        let defaultVoiceIsListed = voiceList?.containsVoice(withID: defaultVoiceID) ?? false
        if !defaultVoiceIsListed {
            pickerRows.append(ClickyVoicePickerRow(
                id: workerDefaultRowIdentifier,
                title: workerDefaultRowTitle,
                subtitle: workerDefaultRowSubtitle,
                isWorkerDefaultVoice: false,
                isChosen: isTheWorkersDefaultChosen(),
                voiceIDToChoose: nil,
                voiceNameToChoose: nil,
                sampleCacheVoiceID: ClickyVoiceSample.sampleCacheVoiceID(forWorkerDefaultVoiceID: defaultVoiceID)
            ))
        }

        // With nothing chosen the Worker's default voice is the one speaking, so it sorts first.
        let voiceIDSortedFirst = usableChosenVoiceID ?? defaultVoiceID
        for voice in voiceList?.sorted(chosenVoiceID: voiceIDSortedFirst) ?? [] {
            let isWorkerDefaultVoice = voice.id == defaultVoiceID
            pickerRows.append(ClickyVoicePickerRow(
                id: voice.id,
                title: voice.name,
                subtitle: voice.subtitle,
                isWorkerDefaultVoice: isWorkerDefaultVoice,
                isChosen: isWorkerDefaultVoice ? isTheWorkersDefaultChosen() : voice.id == usableChosenVoiceID,
                voiceIDToChoose: isWorkerDefaultVoice ? nil : voice.id,
                voiceNameToChoose: isWorkerDefaultVoice ? nil : voice.name,
                sampleCacheVoiceID: voice.id
            ))
        }
        return pickerRows
    }

    /// The hint under "voice": the chosen voice's name (known even before the list loads), or the
    /// Worker's default.
    static func hintText(chosenVoiceID: String?, chosenVoiceName: String?) -> String {
        guard let chosenVoiceID, ClickyVoiceSettings.isUsableVoiceID(chosenVoiceID) else {
            return "the worker's default"
        }
        guard let chosenVoiceName, !chosenVoiceName.isEmpty else {
            return "a voice of your account"
        }
        return chosenVoiceName
    }
}

// MARK: - Notices of the voice picker

nonisolated enum ClickyVoicePickerNotices {
    /// The chosen voice is gone from the account: the Worker spoke with its default, and the choice
    /// was cleared. Shown in the VOICE section until the next pick (nothing is spoken about it).
    static let chosenVoiceFellBackToDefault = "that voice is no longer in the account, so i'm using the default."
    /// A sample (or an older turn) asked for a voice that is not the chosen one and is gone too.
    static let otherVoiceIsNoLongerInTheAccount = "that voice is no longer in the account. press refresh to update the list."
    /// No list could be loaded and none was kept from before.
    static let couldNotLoadTheVoices = "couldn't load the voices. check the worker."
    /// A refresh failed while an older list is shown.
    static let couldNotRefreshTheVoices = "couldn't refresh the voices, so this is the last list."
    /// A sample could not be fetched (offline, the Worker refused).
    static let couldNotFetchTheSample = "couldn't fetch that sample. check the worker."
}

/// How far the loading of the voice list has come.
nonisolated enum ClickyVoiceListFetchState: Equatable, Sendable {
    case notStarted
    case loading
    case loaded
    case failed
}

/// What a row's sample button shows.
nonisolated enum ClickyVoiceSamplePlaybackState: Equatable, Sendable {
    case idle
    /// The sample of this row is being fetched.
    case loading(rowIdentifier: String)
    /// The sample of this row is playing.
    case playing(rowIdentifier: String)

    var rowIdentifier: String? {
        switch self {
        case .idle:
            return nil
        case .loading(let rowIdentifier), .playing(let rowIdentifier):
            return rowIdentifier
        }
    }
}

/// A row's own view of the sample state.
nonisolated enum ClickyVoiceSampleRowState: Equatable, Sendable {
    case idle
    case loading
    case playing

    static func state(forRowIdentifier rowIdentifier: String, in playbackState: ClickyVoiceSamplePlaybackState) -> ClickyVoiceSampleRowState {
        switch playbackState {
        case .idle:
            return .idle
        case .loading(let loadingRowIdentifier):
            return loadingRowIdentifier == rowIdentifier ? .loading : .idle
        case .playing(let playingRowIdentifier):
            return playingRowIdentifier == rowIdentifier ? .playing : .idle
        }
    }
}

// MARK: - Samples

nonisolated enum ClickyVoiceSample {
    /// The sentence every sample says. Fixed (never the persona's name), so one file per voice and
    /// speed is enough, and a sample file never holds anything but this sentence.
    static let sentence = "hi, i'm clicky. this is how i sound."

    /// At most this many sample files are kept; the oldest go first.
    static let maximumCachedSamples = 40

    static let sampleFileExtension = "mp3"

    /// The word a sample of the Worker's default is cached under while no list has named the voice.
    static let workerDefaultWithoutListCacheWord = "default"

    /// The Worker's default voice's samples are cached under its id, so a changed Worker default gets
    /// its own file once the list names it, and under "default" while no list ever has.
    static func sampleCacheVoiceID(forWorkerDefaultVoiceID workerDefaultVoiceID: String?) -> String {
        guard let workerDefaultVoiceID, ClickyVoiceSettings.isUsableVoiceID(workerDefaultVoiceID) else {
            return workerDefaultWithoutListCacheWord
        }
        return workerDefaultVoiceID
    }

    /// "<voice id>-<speed percent>-<model id>.mp3", with only letters, digits, "_" and "-" kept from
    /// the id and the model (so a name can never point outside the samples folder).
    static func cacheFileName(voiceID: String, speedPercent: Int, modelID: String) -> String {
        let filteredVoiceID = fileNameSafeText(voiceID)
        let filteredModelID = fileNameSafeText(modelID)
        return "\(filteredVoiceID.isEmpty ? workerDefaultWithoutListCacheWord : filteredVoiceID)-\(speedPercent)-\(filteredModelID).\(sampleFileExtension)"
    }

    private static func fileNameSafeText(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
        }))
    }
}

/// The sample files on disk: one small mp3 per voice and speed, in
/// ~/Library/Application Support/Clicky/Voices/Samples (a temporary folder in a self test).
nonisolated enum ClickyVoiceSampleCache {
    /// The sample's audio, or nil when it is not cached. A sample that is played again counts as
    /// new (its modification date is moved to now), so the ones in use are the last to be pruned.
    static func cachedSampleAudio(fileName: String, inDirectory samplesDirectoryURL: URL, now: Date = Date()) -> Data? {
        let sampleFileURL = samplesDirectoryURL.appendingPathComponent(fileName)
        guard let sampleAudio = try? Data(contentsOf: sampleFileURL), !sampleAudio.isEmpty else {
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: sampleFileURL.path)
        return sampleAudio
    }

    /// Writes a sample (the folder is made first). Returns whether it was written.
    @discardableResult
    static func storeSampleAudio(_ sampleAudio: Data, fileName: String, inDirectory samplesDirectoryURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: samplesDirectoryURL, withIntermediateDirectories: true)
            try sampleAudio.write(to: samplesDirectoryURL.appendingPathComponent(fileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Removes the oldest sample files (by modification date, then by name) until at most
    /// `maximumCount` are left. Only sample files ("*.mp3") are counted or removed; anything else
    /// in the folder is left alone. Returns the names removed.
    @discardableResult
    static func pruneSamples(inDirectory samplesDirectoryURL: URL, keepingAtMost maximumCount: Int = ClickyVoiceSample.maximumCachedSamples) -> [String] {
        let fileManager = FileManager.default
        guard let fileNames = try? fileManager.contentsOfDirectory(atPath: samplesDirectoryURL.path) else {
            return []
        }
        let sampleFiles: [(name: String, modifiedAt: Date)] = fileNames
            .filter { ($0 as NSString).pathExtension.lowercased() == ClickyVoiceSample.sampleFileExtension }
            .map { fileName in
                let attributes = try? fileManager.attributesOfItem(atPath: samplesDirectoryURL.appendingPathComponent(fileName).path)
                return (fileName, (attributes?[.modificationDate] as? Date) ?? .distantPast)
            }
        guard sampleFiles.count > maximumCount else {
            return []
        }
        let oldestFirst = sampleFiles.sorted { first, second in
            first.modifiedAt != second.modifiedAt ? first.modifiedAt < second.modifiedAt : first.name < second.name
        }
        var removedFileNames: [String] = []
        for sampleFile in oldestFirst.prefix(sampleFiles.count - max(0, maximumCount)) {
            if (try? fileManager.removeItem(at: samplesDirectoryURL.appendingPathComponent(sampleFile.name))) != nil {
                removedFileNames.append(sampleFile.name)
            }
        }
        return removedFileNames
    }
}

// MARK: - The voices folder

/// The voice list on disk: ~/Library/Application Support/Clicky/Voices/voices.json (a temporary
/// folder in a panel self test), with the samples in a "Samples" folder next to it.
nonisolated enum ClickyVoiceListCache {
    static let voiceListFileName = "voices.json"
    static let samplesFolderName = "Samples"

    static var defaultVoicesDirectoryURL: URL {
        let applicationSupportDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportDirectoryURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("Voices", isDirectory: true)
    }

    static func samplesDirectoryURL(inVoicesDirectory voicesDirectoryURL: URL) -> URL {
        voicesDirectoryURL.appendingPathComponent(samplesFolderName, isDirectory: true)
    }

    /// The kept list, read with the same tolerant `ClickyVoiceList.decode` as the Worker's answer.
    /// nil when there is none or it cannot be read.
    static func loadVoiceList(fromVoicesDirectory voicesDirectoryURL: URL) -> ClickyVoiceList? {
        guard let cachedData = try? Data(contentsOf: voicesDirectoryURL.appendingPathComponent(voiceListFileName)) else {
            return nil
        }
        return ClickyVoiceList.decode(cachedData)
    }

    /// Keeps the list for next time: pretty JSON with sorted keys and an ISO date, written atomically.
    @discardableResult
    static func saveVoiceList(_ voiceList: ClickyVoiceList, toVoicesDirectory voicesDirectoryURL: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let encodedList = try encoder.encode(voiceList)
            try FileManager.default.createDirectory(at: voicesDirectoryURL, withIntermediateDirectories: true)
            try encodedList.write(to: voicesDirectoryURL.appendingPathComponent(voiceListFileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
