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
}

/// Everything selection needs to know about the current turn. Plain strings only, so the logic
/// can be tested without AppKit.
nonisolated struct ClickySkillSelectionContext {
    let userTranscript: String
    let frontmostApplicationBundleIdentifier: String?
    let frontmostApplicationName: String?
}

/// Loads skill files from a folder and picks the few that apply to a turn.
nonisolated enum ClickySkillLibrary {
    /// An app match is a strong signal, so it outweighs a keyword hit.
    static let applicationMatchScore = 100
    static let keywordMatchScore = 40
    /// Caps how much skill text one turn adds. A skill that would exceed the cap is skipped whole,
    /// never cut in half.
    static let maximumSkillBodyCharacterCountPerTurn = 2500

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
            sourceFileName: fileName
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

        var selectedSkills: [ClickySkill] = []
        var accumulatedBodyCharacterCount = 0
        for rankedSkill in rankedSkills {
            guard selectedSkills.count < maxSkillCount else {
                break
            }
            if accumulatedBodyCharacterCount + rankedSkill.skill.bodyText.count > maximumSkillBodyCharacterCountPerTurn {
                continue
            }
            selectedSkills.append(rankedSkill.skill)
            accumulatedBodyCharacterCount += rankedSkill.skill.bodyText.count
        }
        return selectedSkills
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
