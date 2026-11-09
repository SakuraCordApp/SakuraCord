import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

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

struct ColonAutocompleteContext {
    private static let expression = RegularExpressionFactory.make(
        #"(?:^|\s)(:[A-Za-z0-9_+\-]*)$"#
    )

    let query: String
    let range: NSRange

    init?(text: String, selection: NSRange?) {
        let cursor = selection?.location ?? text.utf16.count
        guard selection?.length ?? 0 == 0, cursor <= text.utf16.count else { return nil }
        let prefix = (text as NSString).substring(to: cursor)
        guard
            let match = Self.expression.firstMatch(
                in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)
            ),
            match.range(at: 1).location != NSNotFound
        else { return nil }
        range = match.range(at: 1)
        query = String((prefix as NSString).substring(with: range).dropFirst())
        guard query.count >= 2 else { return nil }
    }
}

struct MentionAutocompleteContext {
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
    private static let expression = RegularExpressionFactory.make(
        #"(?:^|\s)([@#]([^\s@#]*))\z"#
    )

    enum Kind: Equatable { case member, channel }

    let kind: Kind
    let query: String
    let range: NSRange

    init?(text: String, selection: NSRange?) {
        let cursor = selection?.location ?? text.utf16.count
        guard selection?.length ?? 0 == 0, cursor <= text.utf16.count else { return nil }
        let prefix = (text as NSString).substring(to: cursor)
        if let match = Self.quotedChannelExpression.firstMatch(
            in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length)
        ), match.range(at: 1).location != NSNotFound,
        match.range(at: 2).location != NSNotFound {
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
            query = (prefix as NSString).substring(with: match.range(at: 2))
                .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        } else if let match = Self.expression.firstMatch(
            in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length)
        ), match.range(at: 1).location != NSNotFound,
        match.range(at: 2).location != NSNotFound {
            range = match.range(at: 1)
            let token = (prefix as NSString).substring(with: range)
            kind = token.first == "@" ? .member : .channel
            query = (prefix as NSString).substring(with: match.range(at: 2))
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
        let cursor = selection?.location ?? text.utf16.count
        guard selection?.length ?? 0 == 0, cursor <= text.utf16.count, let expression = Self.expressions[keyword]
        else { return nil }
        let prefix = (text as NSString).substring(to: cursor)
        guard let match = expression.firstMatch(
            in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length)
        ), match.range(at: 1).location != NSNotFound
        else { return nil }
        range = match.range(at: 1)
        query = (prefix as NSString).substring(with: match.range(at: 2))
    }
}

struct MentionAutocompleteSuggestion: Identifiable {
    let id: String
    let title: String
    let detail: String
    let value: String
    let target: MentionTarget
    var avatarURL: URL?
    var colorHex: UInt32?
    var member: Member?
    var systemImage: String?
}
