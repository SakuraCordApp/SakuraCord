import Foundation

struct SlashCommandQuery {
    let query: String

    init?(text: String, selection: NSRange?) {
        guard text.hasPrefix("/"), !text.contains(where: \.isNewline) else { return nil }
        if let selection {
            guard selection.length == 0, selection.location == text.utf16.count else { return nil }
        }
        query = String(text.dropFirst())
    }
}

/// The text before a collapsed caret, which every typed-token context below
/// matches against; nil while text is selected.
struct ComposerCaretPrefix {
    let text: String
    let cursor: Int

    init?(text: String, selection: NSRange?) {
        let cursor = selection?.location ?? text.utf16.count
        guard selection?.length ?? 0 == 0, cursor <= text.utf16.count else { return nil }
        self.text = (text as NSString).substring(to: cursor)
        self.cursor = cursor
    }

    func firstMatch(_ expression: NSRegularExpression) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    func substring(with range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }
}

struct ColonAutocompleteContext {
    private static let expression = RegularExpressionFactory.make(
        #"(?:^|\s)(:[A-Za-z0-9_+\-]*)$"#
    )

    let query: String
    let range: NSRange

    init?(text: String, selection: NSRange?) {
        guard let prefix = ComposerCaretPrefix(text: text, selection: selection),
              let match = prefix.firstMatch(Self.expression)
        else { return nil }
        range = match.range(at: 1)
        query = String(prefix.substring(with: range).dropFirst())
        guard query.count >= 2 else { return nil }
    }
}

struct ClosedColonAutocompleteContext {
    private static let expression = RegularExpressionFactory.make(
        #"(?:^|\s)(:([A-Za-z0-9_+\-]{2,}):)$"#
    )

    let query: String
    let range: NSRange

    init?(text: String, selection: NSRange?) {
        guard let prefix = ComposerCaretPrefix(text: text, selection: selection),
              let match = prefix.firstMatch(Self.expression)
        else { return nil }
        range = match.range(at: 1)
        query = prefix.substring(with: match.range(at: 2))
    }
}

struct MentionAutocompleteContext: Equatable {
    // Discord's `#"…"` channel mention escapes quotes and backslashes with a
    // backslash. Both token expressions end at `\z`, not `$`, which also
    // matches before a trailing line break and would let a suggestion replace
    // text the caret has already left.
    private static let quotedChannelExpression = RegularExpressionFactory.make(
        #"(?:^|\s)(#["“”]((?:\\.|[^"“”\\\v])*(\\?))(["“”]?))\z"#
    )
    private static let quotedSuffixExpression = RegularExpressionFactory.make(
        #"^(?:\\.|[^"“”\\\v])*["“”]"#
    )
    private static let channelExpression = RegularExpressionFactory.make(
        #"(?:^|\s)(#([^\s@#]*))\z"#
    )
    private static let memberExpression = RegularExpressionFactory.make(
        #"(?:^|\s)(@(?!(?:time|game)\s)([^\s\v@#][^\v@#]{0,31}|))\z"#
    )

    enum Kind: Equatable { case member, channel }

    let kind: Kind
    let query: String
    let range: NSRange

    /// The suggestion list's heading for what is typed.
    var heading: String {
        kind == .member
            ? MentionAutocompleteSuggestionFactory.memberHeading(query: query)
            : MentionAutocompleteSuggestionFactory.channelHeading(query: query)
    }

    init?(text: String, selection: NSRange?) {
        guard let prefix = ComposerCaretPrefix(text: text, selection: selection) else { return nil }
        let cursor = prefix.cursor
        if let match = prefix.firstMatch(Self.quotedChannelExpression) {
            var tokenRange = match.range(at: 1)
            if match.range(at: 4).length == 0, cursor < text.utf16.count {
                // A backslash just before the caret escapes the suffix's first
                // character, which therefore cannot close the token; a line
                // break ends the token instead.
                let suffix = (text as NSString).substring(from: cursor)
                let escaped = match.range(at: 3).length == 0 ? nil : suffix.first
                let escapedLength = escaped?.utf16.count ?? 0
                if escaped?.isNewline != true, let suffixMatch = Self.quotedSuffixExpression.firstMatch(
                    in: suffix,
                    range: NSRange(location: escapedLength, length: (suffix as NSString).length - escapedLength)
                ) {
                    tokenRange.length += escapedLength + suffixMatch.range.length
                }
            }
            range = tokenRange
            kind = .channel
            query = prefix.substring(with: match.range(at: 2))
                .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        } else if let match = prefix.firstMatch(Self.channelExpression) {
            range = match.range(at: 1)
            kind = .channel
            query = prefix.substring(with: match.range(at: 2))
        } else if let match = prefix.firstMatch(Self.memberExpression) {
            range = match.range(at: 1)
            kind = .member
            query = prefix.substring(with: match.range(at: 2))
        } else {
            return nil
        }
    }
}

/// Text typed after the line's last `@game ` or `@time `, which filters
/// that keyword's menu as a command argument filters its options. A later
/// keyword starts its own query.
struct KeywordMentionContext {
    enum Keyword: String, CaseIterable {
        case game, time
    }

    private static let expressions = Dictionary(uniqueKeysWithValues: Keyword.allCases.map { keyword in
        let anyKeyword = Keyword.allCases.map(\.rawValue).joined(separator: "|")
        return (keyword, RegularExpressionFactory.make(
            #"(?:^|\s)(@\#(keyword.rawValue) ((?:(?!(?<=\s)@(?:\#(anyKeyword)) )[^\v])*))\z"#
        ))
    })

    let query: String
    let range: NSRange

    init?(_ keyword: Keyword, text: String, selection: NSRange?) {
        guard let prefix = ComposerCaretPrefix(text: text, selection: selection),
              let expression = Self.expressions[keyword],
              let match = prefix.firstMatch(expression)
        else { return nil }
        range = match.range(at: 1)
        query = prefix.substring(with: match.range(at: 2))
    }
}
