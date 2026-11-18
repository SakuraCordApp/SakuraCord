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
    /// any three backticks outside inline code, even mid-line, and closes
    /// at the next three. A fence that nothing closes is text. Quote lines
    /// keep their code inline, as message rendering reads them.
    static func codeBlocks(in source: String) -> [CodeBlock] {
        guard source.contains("```") else { return [] }
        var blocks: [CodeBlock] = []
        var cursor = source.startIndex
        var lineStart: String.Index? = cursor
        var lineEnd = cursor
        var isQuoteLine = false
        while cursor < source.endIndex {
            if cursor == lineStart {
                lineEnd = source[cursor...].firstIndex(of: "\n") ?? source.endIndex
                isQuoteLine = quote(source[cursor ..< lineEnd], rules: .message) != nil || quoteContent(source[cursor ..< lineEnd]) != nil
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
            case "`":
                if !isQuoteLine, let block = codeBlock(in: source, at: cursor) {
                    blocks.append(block)
                    cursor = block.range.upperBound
                    lineEnd = source[cursor...].firstIndex(of: "\n") ?? source.endIndex
                } else {
                    cursor = inlineCode(in: source[..<lineEnd], at: cursor, collector: nil).end
                }
            default:
                cursor = source.index(after: cursor)
            }
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
