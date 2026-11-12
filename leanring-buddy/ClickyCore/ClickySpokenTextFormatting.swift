import Foundation

/// Removes markdown code and emphasis marks from text that is about to be spoken.
///
/// Why: the prompt asks for plain speech, but the model still sometimes writes code in backticks
/// or a word in asterisks (measured in round 10: one ordinary coding answer came back with
/// backticks). The voice reads those marks badly, so they are taken out in code as well. Only the
/// marks go; every word stays. Conversation history keeps the reply as the model wrote it.
///
/// `ClickyReplyTagParser` calls this while the reply still has its line breaks, because a heading
/// or list marker can only be told apart from an ordinary "#" or "-" at the start of a line.
nonisolated enum ClickySpokenTextFormatting {
    /// Returns `text` without code fences, backticks, `**bold**`, `__bold__`, `*emphasis*`, and
    /// without "#" heading marks or "- " list marks at the start of a line.
    ///
    /// Left alone on purpose: apostrophes, a lone asterisk in maths ("3 * 4", "3*4"), the power
    /// operator with nothing to pair with ("2 ** 3"), underscores inside identifiers
    /// ("user_name"), a "#" inside a word ("c#", "#12"), and a dash inside a sentence.
    static func removingMarkdownMarks(from text: String) -> String {
        var textWithoutMarks = text

        // A fence line is "```" or "```swift" on a line of its own. The whole line goes, language
        // name included, so the voice does not say "swift" before the code.
        textWithoutMarks = replacing(#"(?m)^[ \t]*`{3,}[ \t]*[A-Za-z0-9_+#.-]*[ \t]*$"#, in: textWithoutMarks, with: "")

        // Every other backtick: inline code, and fences written on one line with their code.
        // Removing each backtick on its own (not in pairs) means a cut-off reply with one unclosed
        // backtick is cleaned the same way as a whole one.
        textWithoutMarks = textWithoutMarks.replacingOccurrences(of: "`", with: "")

        // Heading marks ("## title") and list marks ("- item", "* item", "• item") at the start
        // of a line. A space must follow, so "-5" and "#12" are untouched.
        textWithoutMarks = replacing(#"(?m)^[ \t]*#{1,6}[ \t]+"#, in: textWithoutMarks, with: "")
        textWithoutMarks = replacing(#"(?m)^[ \t]*[-*•][ \t]+"#, in: textWithoutMarks, with: "")

        // **bold** and __bold__: only a pair that hugs its words on both sides. "2 ** 3" has
        // spaces around the marks and no partner, so it stays.
        textWithoutMarks = replacing(#"\*\*(?=\S)([^\n]+?)(?<=\S)\*\*"#, in: textWithoutMarks, with: "$1")
        textWithoutMarks = replacing(#"(?<![A-Za-z0-9_])__(?=\S)([^\n]+?)(?<=\S)__(?![A-Za-z0-9_])"#, in: textWithoutMarks, with: "$1")

        // *emphasis*: a pair that hugs its words and does not touch a letter, digit or another
        // asterisk on the outside. "3 * 4" (spaces inside) and "3*4*5" (digits outside) stay.
        textWithoutMarks = replacing(#"(?<![A-Za-z0-9_*])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![A-Za-z0-9_*])"#, in: textWithoutMarks, with: "$1")

        return textWithoutMarks
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
