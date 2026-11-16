import Foundation

/// One skill file: short guidance for a kind of app or topic, loaded only when it matches the turn.
nonisolated struct ClickySkill: Equatable {
    /// Identifier from the "name" front matter key, such as "xcode".
    let skillName: String
    let description: String
    /// Lowercased exact bundle identifiers of the apps this skill is about.
    let applicationBundleIdentifiers: [String]
    /// Lowercased fragments matched against the frontmost app's display name.
    let applicationNameFragments: [String]
    /// Lowercased phrases matched as whole words in the user's transcript.
    let keywordPhrases: [String]
    /// Higher priority wins a tie in score.
    let priority: Int
    let bodyText: String
    let sourceFileName: String
    /// From the "always_include" front matter key. A skill like this teaches a reply format the
    /// user just asked for, so once it matches the turn it must not lose its place to app skills
    /// that score higher: it is included whatever its size, and (since the round 21 review) it uses
    /// none of the ordinary skills' room, so it never pushes an app skill out either.
    var isAlwaysIncludedWhenSelected: Bool = false
    /// From the "when_marks_on_screen" front matter key. The skill also matches the turn while
    /// Clicky's drawing is on the screen, whatever the user says, so the drawing can be edited.
    var isSelectedWhenDrawingMarksAreOnScreen: Bool = false
    /// From the "when_scene_on_screen" front matter key (round 21). The skill also matches the turn
    /// while a 3D scene is on the screen, so a part can be added to it.
    var isSelectedWhenSceneIsOnScreen: Bool = false
    /// From the "when_walkthrough_active" front matter key (round 21). The skill also matches the
    /// turn while a step-by-step walkthrough is in progress, so a "back" or "repeat" turn (whose
    /// words name no format) still has the step format in its prompt.
    var isSelectedWhileWalkthroughIsActive: Bool = false
}

/// Everything selection needs to know about the current turn. Plain strings only, so the logic
/// can be tested without AppKit.
nonisolated struct ClickySkillSelectionContext {
    let userTranscript: String
    let frontmostApplicationBundleIdentifier: String?
    let frontmostApplicationName: String?
    /// True while marks Clicky drew are still on the screen.
    var drawingMarksAreOnScreen: Bool = false
    /// True while a 3D scene Clicky built is on the screen (round 21).
    var sceneIsOnScreen: Bool = false
    /// True while a step-by-step walkthrough is in progress (round 21).
    var walkthroughIsActive: Bool = false
}

/// Loads skill files from a folder and picks the few that apply to a turn.
nonisolated enum ClickySkillLibrary {
    /// An app match is a strong signal, so it outweighs a keyword hit.
    static let applicationMatchScore = 100
    static let keywordMatchScore = 40
    /// Caps how much text the ordinary skills (the app and topic skills) add to one turn. A skill
    /// that would exceed the cap is skipped whole, never cut in half.
    ///
    /// Round 20's number, counted over the ordinary skills only. The always-included format skills
    /// (`skill_draw.md`, `skill_card.md` and `skill_scene.md`, round 21) come on top and use none of
    /// it, so a turn that selects no format skill selects exactly what round 20 selected, and a
    /// format skill can never push an app skill out. Round 21 first had one shared cap of 7,000,
    /// counted after the format skills' bodies: that let a plain question select more app skills
    /// than round 20 did, and with all three format skills on the screen it still pushed an app
    /// skill out (the round 21 review).
    static let maximumOrdinarySkillBodyCharacterCountPerTurn = 2500
    /// The "name" of the skill file that teaches the [DRAW:...] reply format (round 21: the format
    /// lives in `skill_draw.md` again, together with the spotlight and the walkthrough steps).
    static let drawSkillName = "draw"
    /// The "name" of the skill file that teaches the explanation card (round 21).
    static let cardSkillName = "card"
    /// The "name" of the skill file that teaches the simple 3D scene (round 21).
    static let sceneSkillName = "scene"

    private struct ScoredSkill {
        let skill: ClickySkill
        let score: Int
    }

    /// Parses one skill file. The file starts with a front matter block between "---" lines,
    /// followed by the body. Returns nil for a malformed file, which the caller then skips.
    static func parseSkill(fromMarkdown markdownText: String, fileName: String) -> ClickySkill? {
        let lines = markdownText.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingDelimiterLineIndex = lines.dropFirst().firstIndex(where: { line in
                  line.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return nil
        }

        var frontMatterValuesByKey: [String: String] = [:]
        for frontMatterLine in lines[1..<closingDelimiterLineIndex] {
            guard let firstColonIndex = frontMatterLine.firstIndex(of: ":") else {
                continue
            }
            // Only the first colon splits key from value, so values may contain colons.
            let frontMatterKey = frontMatterLine[..<firstColonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let frontMatterValue = frontMatterLine[frontMatterLine.index(after: firstColonIndex)...].trimmingCharacters(in: .whitespaces)
            frontMatterValuesByKey[frontMatterKey] = frontMatterValue
        }

        let skillName = frontMatterValuesByKey["name"] ?? ""
        let bodyText = lines[(closingDelimiterLineIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillName.isEmpty, !bodyText.isEmpty else {
            return nil
        }

        return ClickySkill(
            skillName: skillName,
            description: frontMatterValuesByKey["description"] ?? "",
            applicationBundleIdentifiers: commaSeparatedLowercasedValues(frontMatterValuesByKey["apps"]),
            applicationNameFragments: commaSeparatedLowercasedValues(frontMatterValuesByKey["app_names"]),
            keywordPhrases: commaSeparatedLowercasedValues(frontMatterValuesByKey["keywords"]),
            priority: Int(frontMatterValuesByKey["priority"] ?? "") ?? 0,
            bodyText: bodyText,
            sourceFileName: fileName,
            isAlwaysIncludedWhenSelected: frontMatterValueIsTrue(frontMatterValuesByKey["always_include"]),
            isSelectedWhenDrawingMarksAreOnScreen: frontMatterValueIsTrue(frontMatterValuesByKey["when_marks_on_screen"]),
            isSelectedWhenSceneIsOnScreen: frontMatterValueIsTrue(frontMatterValuesByKey["when_scene_on_screen"]),
            isSelectedWhileWalkthroughIsActive: frontMatterValueIsTrue(frontMatterValuesByKey["when_walkthrough_active"])
        )
    }

    /// Loads every file named skill_*.md in the folder. Malformed files are logged and skipped so
    /// one bad file never removes the others.
    static func loadSkills(fromDirectory skillsDirectoryURL: URL) -> [ClickySkill] {
        let fileURLsInDirectory = (try? FileManager.default.contentsOfDirectory(
            at: skillsDirectoryURL,
            includingPropertiesForKeys: nil
        )) ?? []

        var loadedSkills: [ClickySkill] = []
        for fileURL in fileURLsInDirectory.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard fileURL.lastPathComponent.hasPrefix("skill_"), fileURL.pathExtension == "md" else {
                continue
            }
            guard let markdownText = try? String(contentsOf: fileURL, encoding: .utf8),
                  let parsedSkill = parseSkill(fromMarkdown: markdownText, fileName: fileURL.lastPathComponent) else {
                print("⚠️ skipped malformed skill file \(fileURL.lastPathComponent)")
                continue
            }
            loadedSkills.append(parsedSkill)
        }
        return loadedSkills
    }

    /// Picks at most `maxSkillCount` skills, best first. A skill is eligible when the frontmost app
    /// matches it (100 points) or the transcript contains one of its keywords (40 points).
    /// Ties go to higher priority, then to name order, so the result is deterministic.
    ///
    /// A skill marked "always_include" that is eligible is taken whatever its rank and size, and
    /// counts towards neither `maxSkillCount` nor the character cap: the other skills are chosen
    /// exactly as they would be without it. With no such skill eligible, the selection is exactly
    /// what it always was.
    static func selectSkills(from availableSkills: [ClickySkill], for selectionContext: ClickySkillSelectionContext, maxSkillCount: Int = 2) -> [ClickySkill] {
        // Keyword matching compares whole words, so both sides are reduced to space-separated words.
        // Padding with spaces stops "ide" from matching inside "video".
        let normalizedTranscriptWords = " " + normalizedWordsText(selectionContext.userTranscript) + " "
        let frontmostBundleIdentifier = selectionContext.frontmostApplicationBundleIdentifier?.lowercased()
        let frontmostApplicationName = selectionContext.frontmostApplicationName?.lowercased()

        let scoredSkills: [ScoredSkill] = availableSkills.compactMap { skill in
            var score = 0
            if matchesFrontmostApplication(skill, bundleIdentifier: frontmostBundleIdentifier, applicationName: frontmostApplicationName) {
                score += applicationMatchScore
            }
            let transcriptContainsKeyword = skill.keywordPhrases.contains { keywordPhrase in
                normalizedTranscriptWords.contains(" " + normalizedWordsText(keywordPhrase) + " ")
            }
            if transcriptContainsKeyword {
                score += keywordMatchScore
            }
            // Marks on screen count like a keyword: the user may say only "remove the second one".
            // Round 21: so do a 3D scene on the screen ("add the wheels") and a walkthrough in
            // progress ("back"), for the skills that ask for them.
            let matchesWhatIsOnScreenOrInProgress =
                (skill.isSelectedWhenDrawingMarksAreOnScreen && selectionContext.drawingMarksAreOnScreen)
                || (skill.isSelectedWhenSceneIsOnScreen && selectionContext.sceneIsOnScreen)
                || (skill.isSelectedWhileWalkthroughIsActive && selectionContext.walkthroughIsActive)
            if !transcriptContainsKeyword && matchesWhatIsOnScreenOrInProgress {
                score += keywordMatchScore
            }
            return score > 0 ? ScoredSkill(skill: skill, score: score) : nil
        }

        let rankedSkills = scoredSkills.sorted { firstScoredSkill, secondScoredSkill in
            if firstScoredSkill.score != secondScoredSkill.score {
                return firstScoredSkill.score > secondScoredSkill.score
            }
            if firstScoredSkill.skill.priority != secondScoredSkill.skill.priority {
                return firstScoredSkill.skill.priority > secondScoredSkill.skill.priority
            }
            return firstScoredSkill.skill.skillName < secondScoredSkill.skill.skillName
        }

        // Skills that must be included are taken whatever their size. Only the ordinary skills count
        // towards the cap, so they are chosen exactly as they would be without the others.
        var selectedSkills: [ClickySkill] = []
        var selectedOrdinarySkillCount = 0
        var accumulatedOrdinaryBodyCharacterCount = 0
        for rankedSkill in rankedSkills {
            if rankedSkill.skill.isAlwaysIncludedWhenSelected {
                selectedSkills.append(rankedSkill.skill)
                continue
            }
            guard selectedOrdinarySkillCount < maxSkillCount else {
                continue
            }
            if accumulatedOrdinaryBodyCharacterCount + rankedSkill.skill.bodyText.count > maximumOrdinarySkillBodyCharacterCountPerTurn {
                continue
            }
            selectedSkills.append(rankedSkill.skill)
            selectedOrdinarySkillCount += 1
            accumulatedOrdinaryBodyCharacterCount += rankedSkill.skill.bodyText.count
        }
        return selectedSkills
    }

    private static func frontMatterValueIsTrue(_ rawValue: String?) -> Bool {
        let normalizedValue = rawValue?.trimmingCharacters(in: .whitespaces).lowercased()
        return normalizedValue == "true" || normalizedValue == "yes"
    }

    private static func matchesFrontmostApplication(_ skill: ClickySkill, bundleIdentifier: String?, applicationName: String?) -> Bool {
        if let bundleIdentifier, skill.applicationBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        if let applicationName, skill.applicationNameFragments.contains(where: { fragment in
            !fragment.isEmpty && applicationName.contains(fragment)
        }) {
            return true
        }
        return false
    }

    private static func commaSeparatedLowercasedValues(_ rawValue: String?) -> [String] {
        guard let rawValue else {
            return []
        }
        return rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func normalizedWordsText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
