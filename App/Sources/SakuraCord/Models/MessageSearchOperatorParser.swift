import Foundation
import SakuraCordModels

nonisolated struct MessageSearchParsedInput: Equatable, Sendable {
    let content: String
    let filters: MessageSearchFilters
}

nonisolated extension MessageSearchFilters {
    func merging(_ other: Self) -> Self {
        Self(
            authorIDs: merged(authorIDs, other.authorIDs),
            channelIDs: merged(channelIDs, other.channelIDs),
            mentionedUserIDs: merged(mentionedUserIDs, other.mentionedUserIDs),
            contentTypes: merged(contentTypes, other.contentTypes),
            authorTypes: merged(authorTypes, other.authorTypes),
            pinned: other.pinned ?? pinned,
            minimumMessageID: other.minimumMessageID ?? minimumMessageID,
            maximumMessageID: other.maximumMessageID ?? maximumMessageID
        )
    }

    private func merged<Value: Equatable>(
        _ existing: [Value],
        _ additional: [Value]
    ) -> [Value] {
        additional.reduce(into: existing) { values, value in
            if !values.contains(value) {
                values.append(value)
            }
        }
    }
}

nonisolated enum MessageSearchOperatorParser {
    static func parse(
        _ input: String,
        filters initialFilters: MessageSearchFilters,
        users: [User],
        channels: [Channel],
        calendar: Calendar = .current
    ) -> MessageSearchParsedInput {
        var filters = initialFilters
        var contentTokens: [String] = []

        for token in tokens(in: input) {
            guard let separator = token.firstIndex(of: ":") else {
                contentTokens.append(token)
                continue
            }
            let name = token[..<separator].lowercased()
            let rawValue = token[token.index(after: separator)...]
            let value = unquoted(String(rawValue))
            guard !value.isEmpty,
                  apply(
                      name: name,
                      value: value,
                      filters: &filters,
                      users: users,
                      channels: channels,
                      calendar: calendar
                  )
            else {
                contentTokens.append(token)
                continue
            }
        }

        return MessageSearchParsedInput(
            content: contentTokens.joined(separator: " "),
            filters: filters
        )
    }

    private static func apply(
        name: String,
        value: String,
        filters: inout MessageSearchFilters,
        users: [User],
        channels: [Channel],
        calendar: Calendar
    ) -> Bool {
        switch name {
        case "from":
            return applyAuthor(value, users: users, filters: &filters)
        case "in":
            return applyChannel(value, channels: channels, filters: &filters)
        case "mentions":
            return applyMention(value, users: users, filters: &filters)
        case "has":
            return applyContentTypes(value, filters: &filters)
        case "author_type", "authortype", "type":
            return applyAuthorTypes(value, filters: &filters)
        case "pinned":
            return applyPinned(value, filters: &filters)
        case "before":
            return applyBefore(value, calendar: calendar, filters: &filters)
        case "after":
            return applyAfter(value, calendar: calendar, filters: &filters)
        default:
            return false
        }
    }

    private static func applyAuthor(
        _ value: String,
        users: [User],
        filters: inout MessageSearchFilters
    ) -> Bool {
        guard let user = user(value, in: users) else { return false }
        appendUnique(user.id, to: &filters.authorIDs)
        return true
    }

    private static func applyChannel(
        _ value: String,
        channels: [Channel],
        filters: inout MessageSearchFilters
    ) -> Bool {
        guard let channel = channel(value, in: channels) else { return false }
        appendUnique(channel.id, to: &filters.channelIDs)
        return true
    }

    private static func applyMention(
        _ value: String,
        users: [User],
        filters: inout MessageSearchFilters
    ) -> Bool {
        guard let user = user(value, in: users) else { return false }
        appendUnique(user.id, to: &filters.mentionedUserIDs)
        return true
    }

    private static func applyContentTypes(
        _ value: String,
        filters: inout MessageSearchFilters
    ) -> Bool {
        let types = value.split(separator: ",").compactMap {
            MessageSearchContentType(rawValue: $0.lowercased())
        }
        guard !types.isEmpty else { return false }
        for type in types {
            appendUnique(type, to: &filters.contentTypes)
        }
        return true
    }

    private static func applyAuthorTypes(
        _ value: String,
        filters: inout MessageSearchFilters
    ) -> Bool {
        let types = value.split(separator: ",").compactMap {
            MessageSearchAuthorType(rawValue: $0.lowercased())
        }
        guard !types.isEmpty else { return false }
        for type in types {
            appendUnique(type, to: &filters.authorTypes)
        }
        return true
    }

    private static func applyPinned(
        _ value: String,
        filters: inout MessageSearchFilters
    ) -> Bool {
        switch value.lowercased() {
        case "true", "yes":
            filters.pinned = true
        case "false", "no":
            filters.pinned = false
        default:
            return false
        }
        return true
    }

    private static func applyBefore(
        _ value: String,
        calendar: Calendar,
        filters: inout MessageSearchFilters
    ) -> Bool {
        guard let date = date(value, calendar: calendar) else { return false }
        filters.maximumMessageID = .messageSearchBoundary(
            at: calendar.startOfDay(for: date)
        )
        return true
    }

    private static func applyAfter(
        _ value: String,
        calendar: Calendar,
        filters: inout MessageSearchFilters
    ) -> Bool {
        guard let date = date(value, calendar: calendar),
              let nextDay = calendar.date(
                  byAdding: .day,
                  value: 1,
                  to: calendar.startOfDay(for: date)
              )
        else { return false }
        filters.minimumMessageID = .messageSearchBoundary(at: nextDay)
        return true
    }

    private static func tokens(in input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        for character in input {
            if character == "\"" {
                isQuoted.toggle()
                current.append(character)
            } else if character.isWhitespace, !isQuoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2,
              value.first == "\"",
              value.last == "\""
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func user(_ value: String, in users: [User]) -> User? {
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        if let rawValue = UInt64(normalized) {
            return users.first { $0.id.rawValue == rawValue }
        }
        return users.first {
            $0.displayName.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
                || $0.username.compare(
                    normalized,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
        }
    }

    private static func channel(_ value: String, in channels: [Channel]) -> Channel? {
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if let rawValue = UInt64(normalized) {
            return channels.first { $0.id.rawValue == rawValue }
        }
        return channels.first {
            $0.name.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }
    }

    private static func date(_ value: String, calendar: Calendar) -> Date? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        let requested = DateComponents(
            year: components[0],
            month: components[1],
            day: components[2]
        )
        guard let date = calendar.date(from: requested) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved == requested ? date : nil
    }

    private static func appendUnique<Value: Equatable>(
        _ value: Value,
        to values: inout [Value]
    ) {
        if !values.contains(value) {
            values.append(value)
        }
    }
}
