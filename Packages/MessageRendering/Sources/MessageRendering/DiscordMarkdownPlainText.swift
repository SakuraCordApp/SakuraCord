/// Discord's inline rules for plain text: escapes, emoji names, and the
/// word boundary that closes `_` emphasis.
extension DiscordMarkdown {
    /// The plain text at `cursor` and where it ends: an escaped character
    /// without its backslash, one character, or, where `readsEmoji`, a known
    /// `:name:` as its emoji. A custom emoji or mention token is read whole
    /// first, as Discord's rules for them come before its emoji rule.
    static func plainText(in source: Substring, at cursor: String.Index, readsEmoji: Bool) -> (text: String, end: String.Index) {
        let next = source.index(after: cursor)
        if source[cursor] == "\\", next < source.endIndex {
            return (String(source[next]), source.index(after: next))
        }
        if readsEmoji, source[cursor] == "<", let end = MessageDocument.tokenEnd(in: source, at: cursor) {
            return (String(source[cursor ..< end]), end)
        }
        if readsEmoji, let shortcode = DiscordEmojiNames.shortcode(in: source, at: cursor) {
            return shortcode
        }
        return (String(source[cursor]), next)
    }

    /// The close of Discord's `_` emphasis, `_((?:__|\\[\s\S]|[^\\_])+?)_\b`:
    /// the first lone `_`, which must end a word, so `snake_case` and
    /// `:heart_eyes:` stay as they are.
    static func underscoreEmphasisClose(in source: Substring, after contentStart: String.Index) -> Range<String.Index>? {
        var cursor = contentStart
        while let mark = source[cursor...].firstIndex(where: { $0 == "\\" || $0 == "_" }) {
            let next = source.index(after: mark)
            let endsWord = next == source.endIndex
                || !(source[next].isASCII && (source[next].isLetter || source[next].isNumber || source[next] == "_"))
            if source[mark] == "_", mark > contentStart, endsWord { return mark ..< next }
            // An escape holds the next character; `__` is text inside it.
            guard next < source.endIndex, source[mark] == "\\" || source[next] == "_" else { return nil }
            cursor = source.index(after: next)
        }
        return nil
    }
}
