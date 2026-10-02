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
    private static let expression = RegularExpressionFactory.make(
        #"(?:^|\s)([@#]([^\s@#]*))$"#
    )

    enum Kind: Equatable { case member, channel }

    let kind: Kind
    let query: String
    let range: NSRange

    init?(text: String, selection: NSRange?) {
        let cursor = selection?.location ?? text.utf16.count
        guard selection?.length ?? 0 == 0, cursor <= text.utf16.count else { return nil }
        let prefix = (text as NSString).substring(to: cursor)
        guard let match = Self.expression.firstMatch(
            in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length)
        ), match.range(at: 1).location != NSNotFound,
        match.range(at: 2).location != NSNotFound
        else { return nil }
        range = match.range(at: 1)
        let token = (prefix as NSString).substring(with: range)
        kind = token.first == "@" ? .member : .channel
        query = (prefix as NSString).substring(with: match.range(at: 2))
    }
}

struct MentionAutocompleteSuggestion: Identifiable {
    enum Action: Equatable {
        case insert
        case chooseTimeFormat
        case chooseGame
    }

    let id: String
    let title: String
    let detail: String
    let value: String
    let target: MentionTarget
    var avatarURL: URL?
    var colorHex: UInt32?
    var member: Member?
    var systemImage: String?
    var action: Action = .insert
}
