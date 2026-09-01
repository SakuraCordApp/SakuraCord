import Foundation
import SakuraCordModels

nonisolated struct MessageSearchToken: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case from(userID: UserID, username: String, displayName: String)
        case channel(channelID: ChannelID, name: String)
        case mentions(userID: UserID, username: String, displayName: String)
        case contentType(MessageSearchContentType)
        case authorType(MessageSearchAuthorType)
        case pinned(Bool)
        case before(value: String, boundary: MessageID)
        case after(value: String, boundary: MessageID)
    }

    let kind: Kind

    var id: String { canonicalSyntax }

    var title: String {
        switch kind {
        case .from(_, _, let displayName): "From: \(displayName)"
        case .channel(_, let name): "In: \(name)"
        case .mentions(_, _, let displayName): "Mentions: \(displayName)"
        case .contentType(let value): "Has: \(value.rawValue.capitalized)"
        case .authorType(let value): "Author: \(value.rawValue.capitalized)"
        case .pinned(let value): value ? "Pinned" : "Not pinned"
        case .before(let value, _): "Before: \(value)"
        case .after(let value, _): "After: \(value)"
        }
    }

    var canonicalSyntax: String {
        switch kind {
        case .from(_, let username, _): "from:\(Self.quotedIfNeeded(username))"
        case .channel(_, let name): "in:\(Self.quotedIfNeeded(name))"
        case .mentions(_, let username, _): "mentions:\(Self.quotedIfNeeded(username))"
        case .contentType(let value): "has:\(value.rawValue)"
        case .authorType(let value): "author_type:\(value.rawValue)"
        case .pinned(let value): "pinned:\(value)"
        case .before(let value, _): "before:\(value)"
        case .after(let value, _): "after:\(value)"
        }
    }

    var filters: MessageSearchFilters {
        switch kind {
        case .from(let userID, _, _):
            MessageSearchFilters(authorIDs: [userID])
        case .channel(let channelID, _):
            MessageSearchFilters(channelIDs: [channelID])
        case .mentions(let userID, _, _):
            MessageSearchFilters(mentionedUserIDs: [userID])
        case .contentType(let value):
            MessageSearchFilters(contentTypes: [value])
        case .authorType(let value):
            MessageSearchFilters(authorTypes: [value])
        case .pinned(let value):
            MessageSearchFilters(pinned: value)
        case .before(_, let boundary):
            MessageSearchFilters(maximumMessageID: boundary)
        case .after(_, let boundary):
            MessageSearchFilters(minimumMessageID: boundary)
        }
    }

    private static func quotedIfNeeded(_ value: String) -> String {
        value.contains(where: \.isWhitespace)
            ? "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
            : value
    }
}

nonisolated enum MessageSearchTokenParser {
    struct Result: Equatable, Sendable {
        let tokens: [MessageSearchToken]
        let text: String
    }

    static func parse(
        _ input: String,
        users: [User],
        channels: [Channel],
        calendar: Calendar = .current
    ) -> Result {
        var semanticTokens: [MessageSearchToken] = []
        var textTokens: [String] = []
        for rawToken in lexicalTokens(in: input) {
            guard let token = semanticToken(
                from: rawToken,
                users: users,
                channels: channels,
                calendar: calendar
            ) else {
                textTokens.append(rawToken)
                continue
            }
            if !semanticTokens.contains(token) {
                semanticTokens.append(token)
            }
        }
        return Result(tokens: semanticTokens, text: textTokens.joined(separator: " "))
    }

    static func serialize(tokens: [MessageSearchToken], text: String) -> String {
        (tokens.map(\.canonicalSyntax) + [text])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func semanticToken(
        from rawToken: String,
        users: [User],
        channels: [Channel],
        calendar: Calendar
    ) -> MessageSearchToken? {
        guard let separator = rawToken.firstIndex(of: ":") else { return nil }
        let name = rawToken[..<separator].lowercased()
        let rawValue = String(rawToken[rawToken.index(after: separator)...])
        let value = unquoted(rawValue)
        guard !value.isEmpty else { return nil }

        switch name {
        case "from", "mentions":
            return userToken(name: name, value: value, users: users)
        case "in":
            guard let channel = resolvedChannel(value, channels: channels) else { return nil }
            return MessageSearchToken(kind: .channel(channelID: channel.id, name: channel.name))
        case "has":
            guard let type = MessageSearchContentType(rawValue: value.lowercased()) else {
                return nil
            }
            return MessageSearchToken(kind: .contentType(type))
        case "author_type", "authortype", "type":
            guard let type = MessageSearchAuthorType(rawValue: value.lowercased()) else {
                return nil
            }
            return MessageSearchToken(kind: .authorType(type))
        case "pinned":
            return pinnedToken(value)
        case "before", "after":
            return dateToken(name: name, value: value, calendar: calendar)
        default:
            return nil
        }
    }

    private static func userToken(
        name: String,
        value: String,
        users: [User]
    ) -> MessageSearchToken? {
        guard let user = resolvedUser(value, users: users) else { return nil }
        let kind: MessageSearchToken.Kind = name == "from"
            ? .from(userID: user.id, username: user.username, displayName: user.displayName)
            : .mentions(userID: user.id, username: user.username, displayName: user.displayName)
        return MessageSearchToken(kind: kind)
    }

    private static func pinnedToken(_ value: String) -> MessageSearchToken? {
        switch value.lowercased() {
        case "true", "yes": MessageSearchToken(kind: .pinned(true))
        case "false", "no": MessageSearchToken(kind: .pinned(false))
        default: nil
        }
    }

    private static func dateToken(
        name: String,
        value: String,
        calendar: Calendar
    ) -> MessageSearchToken? {
        guard let date = date(value, calendar: calendar) else { return nil }
        let start = calendar.startOfDay(for: date)
        if name == "before" {
            return MessageSearchToken(kind: .before(
                value: isoDate(date, calendar: calendar),
                boundary: .messageSearchBoundary(at: start)
            ))
        }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else {
            return nil
        }
        return MessageSearchToken(kind: .after(
            value: isoDate(date, calendar: calendar),
            boundary: .messageSearchBoundary(at: nextDay)
        ))
    }

    static func lexicalTokens(in input: String) -> [String] {
        var values: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in input {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quoted {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                current.append(character)
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty {
                    values.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { values.append(current) }
        return values
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return value
        }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func resolvedUser(_ value: String, users: [User]) -> User? {
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        if let rawValue = UInt64(normalized) {
            return users.first { $0.id.rawValue == rawValue }
        }
        return users.first {
            $0.username.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || $0.displayName.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private static func resolvedChannel(_ value: String, channels: [Channel]) -> Channel? {
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if let rawValue = UInt64(normalized) {
            return channels.first { $0.id.rawValue == rawValue }
        }
        return channels.first {
            $0.name.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private static func date(_ value: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func isoDate(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

nonisolated enum MessageSearchClipboardSerialization {
    static func canonicalSelection(
        editorString: String,
        selectedRange: NSRange,
        tokens: [MessageSearchToken]
    ) -> String? {
        let source = editorString as NSString
        guard selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              NSMaxRange(selectedRange) <= source.length
        else { return nil }
        let objectCharacter: unichar = 0xFFFC
        let tokenOffset = (0 ..< selectedRange.location).reduce(into: 0) { count, index in
            if source.character(at: index) == objectCharacter { count += 1 }
        }
        let selected = NSMutableString(string: source.substring(with: selectedRange))
        var replacements: [(NSRange, String)] = []
        var tokenIndex = tokenOffset
        for index in 0 ..< selected.length where selected.character(at: index) == objectCharacter {
            guard tokens.indices.contains(tokenIndex) else { break }
            replacements.append((
                NSRange(location: index, length: 1),
                tokens[tokenIndex].canonicalSyntax
            ))
            tokenIndex += 1
        }
        for replacement in replacements.reversed() {
            selected.replaceCharacters(in: replacement.0, with: " \(replacement.1) ")
        }
        return (selected as String)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
