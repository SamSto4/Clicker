import Foundation

// Round 18 (Jarvis actions): the pure rules that decide what a link, an app name or a shortcut name
// the model gave means. The link rule is the one gate between "opens at once" and "waits for the
// user's return or yes"; the matchers turn a spoken name into one installed app or one listed shortcut.
// Foundation only; nothing here opens or runs anything.

// MARK: - The link rule

nonisolated enum ClickyLinkClassification: Equatable {
    /// A plain link to a well-known site: it opens at once.
    case openAtOnce(URL)
    /// Any other http or https link: it is shown on the change card and opens only after the user confirms.
    case needsConfirmation(URL)
    /// Not a web link at all (or not a valid one). The text is the tool result.
    case refused(String)

    /// The link as a URL when it can be opened or queued.
    var url: URL? {
        switch self {
        case .openAtOnce(let url), .needsConfirmation(let url): return url
        case .refused: return nil
        }
    }
}

nonisolated enum ClickyLinkRule {
    /// The domains whose plain links open at once (a listed domain and every subdomain of it).
    static let wellKnownDomains: [String] = [
        "google.com", "youtube.com", "gmail.com", "github.com", "apple.com", "icloud.com",
        "wikipedia.org", "stackoverflow.com", "reddit.com", "x.com", "twitter.com", "linkedin.com",
        "facebook.com", "instagram.com", "whatsapp.com", "amazon.com", "netflix.com", "spotify.com",
        "notion.so", "figma.com", "slack.com", "zoom.us", "dropbox.com", "microsoft.com", "office.com",
        "outlook.com", "live.com", "anthropic.com", "claude.ai", "openai.com", "vercel.com",
        "supabase.com", "cloudflare.com", "stripe.com", "shopify.com", "canva.com", "duckduckgo.com",
        "bing.com", "discord.com", "twitch.tv", "medium.com",
    ]

    static let maximumPathSegments = 3
    static let maximumPathSegmentCharacters = 40
    private static let allowedPathSegmentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-")

    /// Decides what happens to a link. A link opens at once only when all of these hold: the scheme
    /// is http or https; it has a host, no user name or password, and no port other than the
    /// default; it has no query and no fragment; its path is empty, "/", or at most three segments of
    /// at most 40 letters, digits and `. _ ~ -`; and its host (lowercase, a leading "www." removed)
    /// is a listed domain or a subdomain of one. Every other http or https link is queued. Any other
    /// scheme is refused.
    static func classify(_ rawLinkText: String) -> ClickyLinkClassification {
        let trimmedText = rawLinkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return .refused(ClickyActionResultTexts.linkNotValid)
        }
        guard trimmedText.count <= ClickyActionLimits.maximumLinkCharacters else {
            return .refused(ClickyActionResultTexts.linkTooLong)
        }
        // Whitespace or a control character inside a link means it is not one link. Foundation would
        // quietly percent-encode it, which would hide what the user is asked to confirm.
        let hasWhitespaceOrControlCharacter = trimmedText.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
        }
        guard !hasWhitespaceOrControlCharacter else {
            return .refused(ClickyActionResultTexts.linkNotValid)
        }

        // "kbconnects.com" with no scheme at all is read as a https link. Anything that starts like a
        // scheme ("javascript:", "mailto:", "file:") keeps it and is refused below.
        let linkText = startsWithAScheme(trimmedText) ? trimmedText : "https://" + trimmedText
        guard let components = URLComponents(string: linkText), let scheme = components.scheme?.lowercased() else {
            return .refused(ClickyActionResultTexts.linkNotValid)
        }
        guard scheme == "http" || scheme == "https" else {
            return .refused(ClickyActionResultTexts.onlyWebLinks)
        }
        guard let host = components.host, !host.isEmpty, let url = components.url else {
            return .refused(ClickyActionResultTexts.linkNotValid)
        }

        if isAPlainLinkToAWellKnownSite(components: components, scheme: scheme, host: host) {
            return .openAtOnce(url)
        }
        return .needsConfirmation(url)
    }

    private static func startsWithAScheme(_ text: String) -> Bool {
        guard let colonIndex = text.firstIndex(of: ":") else {
            return false
        }
        let possibleScheme = text[..<colonIndex]
        guard let firstCharacter = possibleScheme.first, firstCharacter.isASCII, firstCharacter.isLetter else {
            return false
        }
        return possibleScheme.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "+" || character == "." || character == "-")
        }
    }

    private static func isAPlainLinkToAWellKnownSite(components: URLComponents, scheme: String, host: String) -> Bool {
        if components.user != nil || components.password != nil {
            return false
        }
        if let port = components.port, port != (scheme == "https" ? 443 : 80) {
            return false
        }
        // An empty query or fragment (a lone "?" or "#") counts as one: it is `non-nil` here.
        if components.percentEncodedQuery != nil || components.percentEncodedFragment != nil {
            return false
        }
        guard pathIsPlain(components.percentEncodedPath) else {
            return false
        }
        return hostIsWellKnown(host)
    }

    /// The raw (still percent-encoded) path is looked at, so an encoded slash or dot cannot hide.
    static func pathIsPlain(_ rawPath: String) -> Bool {
        if rawPath.isEmpty || rawPath == "/" {
            return true
        }
        guard rawPath.hasPrefix("/") else {
            return false
        }
        var segments = rawPath.dropFirst().components(separatedBy: "/")
        // One trailing slash ("/a/b/") is fine.
        if segments.count > 1, segments.last == "" {
            segments.removeLast()
        }
        guard segments.count <= maximumPathSegments else {
            return false
        }
        return segments.allSatisfy { segment in
            !segment.isEmpty
                && segment.count <= maximumPathSegmentCharacters
                && segment.unicodeScalars.allSatisfy { allowedPathSegmentCharacters.contains($0) }
                && segment.contains(where: { $0 != "." })
        }
    }

    static func hostIsWellKnown(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return wellKnownDomains.contains { domain in
            host == domain || host.hasSuffix("." + domain)
        }
    }

    /// The text of a link as the card and the history show it: the whole address.
    static func displayText(for url: URL) -> String {
        url.absoluteString
    }
}

nonisolated enum ClickyWebSearchURL {
    /// A Google search for `query`, built by hand so every character that is not a letter, a digit or
    /// one of `- . _ ~` is percent-encoded (including `&`, `=`, `+` and `#`, which would otherwise
    /// change the address).
    static func url(forQuery rawQuery: String) -> URL? {
        let cleanedQuery = ClickyActionText.collapsedToOneLine(rawQuery)
        guard !cleanedQuery.isEmpty else {
            return nil
        }
        let unreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encodedQuery = cleanedQuery.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) else {
            return nil
        }
        return URL(string: "https://www.google.com/search?q=" + encodedQuery)
    }
}

// MARK: - App names

nonisolated struct ClickyInstalledApplication: Equatable, Sendable {
    /// The bundle's folder name without ".app".
    let displayName: String
    let path: String
}

nonisolated enum ClickyAppNameMatchResult: Equatable {
    case match(ClickyInstalledApplication)
    case noMatch(closeNames: [String])
    case ambiguous(names: [String])
}

nonisolated enum ClickyAppNameMatcher {
    /// What people say for an app whose name is not what they say. Keys and values are in the
    /// comparison form (lowercase, no accents, no ".app").
    static let aliases: [String: String] = [
        "vs code": "visual studio code",
        "vscode": "visual studio code",
        "code": "visual studio code",
        "chrome": "google chrome",
        "settings": "system settings",
        "system preferences": "system settings",
        "preferences": "system settings",
        "zoom": "zoom.us",
        "word": "microsoft word",
        "excel": "microsoft excel",
        "powerpoint": "microsoft powerpoint",
        "outlook": "microsoft outlook",
        "teams": "microsoft teams",
        "edge": "microsoft edge",
        "brave": "brave browser",
        "app store": "app store",
        "terminal": "terminal",
        "iterm": "iterm",
    ]

    /// Folders searched one level deep for ".app" bundles (never inside a bundle). The leading "~/"
    /// is the user's home folder.
    static let searchFolderPaths = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "~/Applications",
    ]

    static func match(requestedName: String, installedApplications: [ClickyInstalledApplication]) -> ClickyAppNameMatchResult {
        let applications = deduplicated(installedApplications)
        let queries = comparisonQueries(forRequestedName: requestedName)
        guard let firstQuery = queries.first, !firstQuery.isEmpty else {
            return .noMatch(closeNames: [])
        }
        let normalizedNames = applications.map { ClickyActionText.normalizedForComparison($0.displayName) }

        // An exact name wins over any prefix.
        for query in queries {
            if let exactIndex = normalizedNames.firstIndex(of: query) {
                return .match(applications[exactIndex])
            }
        }
        for query in queries {
            let prefixMatchIndexes = normalizedNames.indices.filter { normalizedNames[$0].hasPrefix(query) }
            if prefixMatchIndexes.count == 1 {
                return .match(applications[prefixMatchIndexes[0]])
            }
            if prefixMatchIndexes.count > 1 {
                let names = prefixMatchIndexes.map { applications[$0].displayName }.sorted(by: alphabetically)
                return .ambiguous(names: Array(names.prefix(ClickyActionLimits.maximumCloseNamesInResult)))
            }
        }
        return .noMatch(closeNames: closeNames(forQuery: firstQuery, applications: applications, normalizedNames: normalizedNames))
    }

    /// The request as typed, then with a leading "the" and a trailing "app" taken off, each followed
    /// by what an alias makes of it. Duplicates are left out, the order is kept.
    private static func comparisonQueries(forRequestedName requestedName: String) -> [String] {
        var normalizedRequest = ClickyActionText.normalizedForComparison(requestedName)
        if normalizedRequest.hasSuffix(".app") {
            normalizedRequest = String(normalizedRequest.dropLast(4))
        }
        var variants = [normalizedRequest]
        var trimmedVariant = normalizedRequest
        if trimmedVariant.hasPrefix("the ") {
            trimmedVariant = String(trimmedVariant.dropFirst(4))
        }
        if trimmedVariant.hasSuffix(" app") {
            trimmedVariant = String(trimmedVariant.dropLast(4))
        }
        variants.append(trimmedVariant)

        var queries: [String] = []
        for variant in variants where !variant.isEmpty {
            // The alias first: "code" means Visual Studio Code, not the first app that starts with "code".
            if let aliasTarget = aliases[variant], !queries.contains(aliasTarget) {
                queries.append(aliasTarget)
            }
            if !queries.contains(variant) {
                queries.append(variant)
            }
        }
        return queries
    }

    private static func deduplicated(_ applications: [ClickyInstalledApplication]) -> [ClickyInstalledApplication] {
        var seenNames = Set<String>()
        var uniqueApplications: [ClickyInstalledApplication] = []
        for application in applications {
            let normalizedName = ClickyActionText.normalizedForComparison(application.displayName)
            if seenNames.insert(normalizedName).inserted {
                uniqueApplications.append(application)
            }
        }
        return uniqueApplications
    }

    private static func closeNames(
        forQuery query: String,
        applications: [ClickyInstalledApplication],
        normalizedNames: [String]
    ) -> [String] {
        var scoredNames: [(score: Int, name: String)] = []
        for index in applications.indices {
            let normalizedName = normalizedNames[index]
            if query.count >= 2 && normalizedName.contains(query) {
                scoredNames.append((0, applications[index].displayName))
            } else if query.count >= 3 && normalizedName.hasPrefix(String(query.prefix(3))) {
                scoredNames.append((1, applications[index].displayName))
            } else {
                let distance = ClickyEditDistance.distance(between: query, and: normalizedName)
                if distance <= max(2, query.count / 3) {
                    scoredNames.append((2 + distance, applications[index].displayName))
                }
            }
        }
        scoredNames.sort { first, second in
            first.score != second.score ? first.score < second.score : alphabetically(first.name, second.name)
        }
        return Array(scoredNames.prefix(ClickyActionLimits.maximumCloseNamesInResult).map(\.name))
    }

    private static func alphabetically(_ first: String, _ second: String) -> Bool {
        first.localizedCaseInsensitiveCompare(second) == .orderedAscending
    }
}

nonisolated enum ClickyEditDistance {
    /// The number of single-character edits between two strings.
    static func distance(between firstText: String, and secondText: String) -> Int {
        let firstCharacters = Array(firstText)
        let secondCharacters = Array(secondText)
        if firstCharacters.isEmpty { return secondCharacters.count }
        if secondCharacters.isEmpty { return firstCharacters.count }
        var previousRow = Array(0...secondCharacters.count)
        for firstIndex in 1...firstCharacters.count {
            var currentRow = [firstIndex]
            for secondIndex in 1...secondCharacters.count {
                let substitutionCost = firstCharacters[firstIndex - 1] == secondCharacters[secondIndex - 1] ? 0 : 1
                currentRow.append(min(
                    previousRow[secondIndex] + 1,
                    currentRow[secondIndex - 1] + 1,
                    previousRow[secondIndex - 1] + substitutionCost
                ))
            }
            previousRow = currentRow
        }
        return previousRow[secondCharacters.count]
    }
}

// MARK: - Shortcut names

nonisolated enum ClickyShortcutNameMatchResult: Equatable {
    /// The shortcut's exact listed name.
    case match(String)
    case noMatch(closeNames: [String])
}

nonisolated enum ClickyShortcutNameMatcher {
    /// The name must match a listed name exactly, apart from case. A shortcut runs things on the
    /// user's behalf, so nothing is guessed: a near miss gives close names for the model to ask about.
    static func match(requestedName: String, availableNames: [String]) -> ClickyShortcutNameMatchResult {
        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .noMatch(closeNames: [])
        }
        if availableNames.contains(trimmedName) {
            return .match(trimmedName)
        }
        let lowercasedRequest = trimmedName.lowercased()
        if let caseInsensitiveMatch = availableNames.first(where: { $0.lowercased() == lowercasedRequest }) {
            return .match(caseInsensitiveMatch)
        }

        let normalizedRequest = ClickyActionText.normalizedForComparison(trimmedName)
        var scoredNames: [(score: Int, name: String)] = []
        for availableName in availableNames {
            let normalizedName = ClickyActionText.normalizedForComparison(availableName)
            if normalizedName.contains(normalizedRequest) || normalizedRequest.contains(normalizedName) {
                scoredNames.append((0, availableName))
            } else {
                let distance = ClickyEditDistance.distance(between: normalizedRequest, and: normalizedName)
                if distance <= max(2, normalizedRequest.count / 3) {
                    scoredNames.append((1 + distance, availableName))
                }
            }
        }
        scoredNames.sort { first, second in
            first.score != second.score ? first.score < second.score : first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }
        return .noMatch(closeNames: Array(scoredNames.prefix(ClickyActionLimits.maximumCloseNamesInResult).map(\.name)))
    }
}

nonisolated enum ClickyShortcutListParser {
    /// The names in the output of `shortcuts list`: one per line, trimmed, empty lines and repeats
    /// left out. The exact output format was not checked against a real run (no command was run
    /// while building this); one name per line is what the tool's documentation describes.
    static func names(fromOutput output: String) -> [String] {
        var seenNames = Set<String>()
        var names: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, seenNames.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }
}

/// Remembers the listed shortcut names for 60 seconds, so a "list, then run" exchange does not run
/// `shortcuts list` twice. The clock is a parameter so the rule can be checked with explicit times.
nonisolated struct ClickyShortcutNameCache {
    private var cachedNames: [String]?
    private var cachedAt: Date?

    init() {}

    func names(at moment: Date) -> [String]? {
        guard let cachedNames, let cachedAt,
              moment >= cachedAt,
              moment.timeIntervalSince(cachedAt) < ClickyActionLimits.shortcutListCacheSeconds else {
            return nil
        }
        return cachedNames
    }

    mutating func store(_ names: [String], at moment: Date) {
        cachedNames = names
        cachedAt = moment
    }
}
