import Foundation

/// Discord's block quotes, and its inline code in rules without code
/// blocks, such as a bio's, where it is the only code and may span lines.
extension DiscordMarkdown {
    /// A line's quote, as Discord's blockQuote rule reads it: `>>> ` quotes
    /// the rest of the text and `> ` its line, each without its marker and
    /// one space. A bio's marker may follow spaces, as the rule allows;
    /// message rendering reads markers at the line start.
    static func quote(_ line: Substring, rules: Rules) -> (content: Substring, isMultiline: Bool)? {
        let marker = rules.contains(.indentedQuotes) ? line.drop { $0 == " " } : line
        if marker.hasPrefix(">>> ") { return (marker.dropFirst(4), true) }
        if marker.hasPrefix("> ") { return (marker.dropFirst(2), false) }
        return nil
    }

    /// Each `` `code` `` span in rules without code blocks, backticks
    /// included, skipping escaped characters as inline parsing does. Code
    /// closes within the block it opens in, as Discord parses a block's
    /// content on its own.
    static func inlineCodeSpans(_ source: String, rules: Rules) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var cursor = source.startIndex
        // A `>>>` quote starts at the first line, outside code, that opens one.
        var multilineQuote = source.endIndex
        while cursor < source.endIndex {
            if multilineQuote == source.endIndex,
               cursor == source.startIndex || source[source.index(before: cursor)] == "\n",
               quote(source[cursor...], rules: rules)?.isMultiline == true {
                multilineQuote = cursor
            }
            if source[cursor] == "\\" {
                cursor = source.index(cursor, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
            } else if source[cursor] == "`" {
                let block = source[..<blockEnd(source, containing: cursor, rules: rules, multilineQuote: multilineQuote)]
                let code = inlineCode(in: block, at: cursor, collector: nil)
                if code.code != nil { spans.append(cursor ..< code.end) }
                cursor = code.end
            } else {
                cursor = source.index(after: cursor)
            }
        }
        return spans
    }

    /// Source lines, except that inline code spanning lines stays in the
    /// line it starts on, as Discord parses it before line breaks.
    static func linesOutsideInlineCode(_ source: String, rules: Rules) -> [Substring] {
        var lines: [Substring] = []
        var lineStart = source.startIndex
        var spans = inlineCodeSpans(source, rules: rules)[...]
        for newline in source.indices where source[newline] == "\n" {
            while let span = spans.first, span.upperBound <= newline { spans.removeFirst() }
            if let span = spans.first, span.contains(newline) { continue }
            lines.append(source[lineStart ..< newline])
            lineStart = source.index(after: newline)
        }
        lines.append(source[lineStart...])
        return lines
    }
}
