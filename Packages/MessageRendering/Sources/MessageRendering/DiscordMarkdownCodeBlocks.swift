import Foundation

extension DiscordMarkdown {
    /// A code block as Discord's codeBlock rule reads it.
    struct CodeBlock {
        /// From the opening fence through the closing one.
        let range: Range<String.Index>
        let code: Range<String.Index>
        let language: String?
    }

    /// Message code blocks, which Discord's codeBlock rule,
    /// `` ^```(?:([a-z0-9_+\-.#]+?)\n)?\n*([^\n][^]*?)\n*``` ``, opens at
    /// any three backticks outside inline code, spoilers and masked links,
    /// even mid-line,
    /// and closes at the next three. A fence that nothing closes is text.
    /// Quote lines keep their code inline, and a `>>>` quote opens blocks
    /// only at a line's start, as message rendering reads them.
    static func codeBlocks(in source: String) -> [CodeBlock] {
        guard source.contains("```") else { return [] }
        var blocks: [CodeBlock] = []
        var cursor = source.startIndex
        var lineStart = cursor
        var lineEnd = cursor
        var isQuoteLine = false
        var isInMultilineQuote = false
        while cursor < source.endIndex {
            if cursor == lineStart {
                lineEnd = source[cursor...].firstIndex(of: "\n") ?? source.endIndex
                let line = source[cursor ..< lineEnd]
                let quote = quote(line, rules: .message)
                isQuoteLine = quote != nil || quoteContent(line) != nil
                isInMultilineQuote = isInMultilineQuote || quote?.isMultiline == true
            }
            switch source[cursor] {
            case "\n":
                cursor = source.index(after: cursor)
                lineStart = cursor
            case "\\":
                // An escape keeps the next mark, but not a letter, digit or space, literal.
                let next = source.index(after: cursor)
                let isEscape = next < lineEnd && !source[next].isWhitespace && !(source[next].isASCII && (source[next].isLetter || source[next].isNumber))
                cursor = source.index(cursor, offsetBy: isEscape ? 2 : 1)
            case "|" where source[cursor...].hasPrefix("||"):
                // Discord reads a spoiler, `\|\|([\s\S]+?)\|\|`, before the code in
                // it, which stays hidden. Message rendering pairs spoilers within
                // a line, so one that doesn't close on its line hides nothing.
                let contentStart = source.index(cursor, offsetBy: 2)
                let close = contentStart < lineEnd ? source.range(of: "||", range: source.index(after: contentStart) ..< lineEnd) : nil
                cursor = close?.upperBound ?? contentStart
            case "[":
                // Discord reads a masked link before the code in its label.
                cursor = markdownLinkTarget(in: source[..<lineEnd], at: cursor, collector: nil)?.end ?? source.index(after: cursor)
            case "`":
                if !isQuoteLine, !isInMultilineQuote || cursor == lineStart, let block = codeBlock(in: source, at: cursor) {
                    blocks.append(block)
                    cursor = block.range.upperBound
                } else {
                    cursor = inlineCode(in: source[..<lineEnd], at: cursor, collector: nil).end
                }
            default:
                cursor = source.index(after: cursor)
            }
            if cursor > lineEnd { lineEnd = source[cursor...].firstIndex(of: "\n") ?? source.endIndex }
        }
        return blocks
    }

    private static func codeBlock(in source: String, at start: String.Index) -> CodeBlock? {
        guard source[start...].hasPrefix("```") else { return nil }
        let fenceEnd = source.index(start, offsetBy: 3)
        let languageEnd = source[fenceEnd...].firstIndex { !($0.isASCII && ($0.isLetter || $0.isNumber || "_+-.#".contains($0))) }
        // The regex tries the language line first, then reads it as code.
        var openings: [(language: String?, end: String.Index)] = [(nil, fenceEnd)]
        if let languageEnd, languageEnd > fenceEnd, source[languageEnd] == "\n" {
            openings.insert((source[fenceEnd ..< languageEnd].lowercased(), source.index(after: languageEnd)), at: 0)
        }
        for opening in openings {
            guard let codeStart = source[opening.end...].firstIndex(where: { $0 != "\n" }),
                  let close = source.range(of: "```", range: source.index(after: codeStart) ..< source.endIndex)
            else { continue }
            var codeEnd = close.lowerBound
            while codeEnd > source.index(after: codeStart), source[source.index(before: codeEnd)] == "\n" {
                codeEnd = source.index(before: codeEnd)
            }
            return CodeBlock(range: start ..< close.upperBound, code: codeStart ..< codeEnd, language: opening.language)
        }
        return nil
    }
}
