import Foundation

private enum MessageRegularExpression {
    static func make(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid checked-in regular expression: \(error)")
        }
    }
}

public struct RenderedEmoji: Codable, Hashable, Sendable {
    private static let tokenExpression = MessageRegularExpression.make(
        #"^<(a?):([A-Za-z0-9_]+):([0-9]+)>$"#
    )

    public var id: String
    public var name: String
    public var isAnimated: Bool
    public var rawToken: String

    public init?(rawToken: String) {
        let range = NSRange(rawToken.startIndex ..< rawToken.endIndex, in: rawToken)
        guard let match = Self.tokenExpression.firstMatch(in: rawToken, range: range),
              let animationRange = Range(match.range(at: 1), in: rawToken),
              let nameRange = Range(match.range(at: 2), in: rawToken),
              let idRange = Range(match.range(at: 3), in: rawToken)
        else { return nil }
        id = String(rawToken[idRange])
        name = String(rawToken[nameRange])
        isAnimated = rawToken[animationRange] == "a"
        self.rawToken = rawToken
    }

    public var imageURL: URL? {
        URL(
            string:
            "https://cdn.discordapp.com/emojis/\(id).\(isAnimated ? "gif" : "png")?size=96&quality=lossless"
        )
    }
}

public struct RenderedMention: Codable, Hashable, Sendable {
    private static let tokenExpression = MessageRegularExpression.make(
        #"^<(@!?|@&|#)([0-9]+)>$"#
    )

    public enum Kind: String, Codable, Hashable, Sendable {
        case user, role, channel, channelLink, message
    }

    public static let tokenPattern = #"<@!?[0-9]+>|<@&[0-9]+>|<#[0-9]+>|https?://(?:(?:canary|ptb|www)\.)?discord(?:app)?\.com/channels/(?:@me|[0-9]+)/[0-9]+(?:/[0-9]+)?"#

    public var id: String
    public var kind: Kind
    public var rawToken: String
    public var messageGuildID: String?
    public var messageChannelID: String?

    public init?(rawToken: String) {
        let range = NSRange(rawToken.startIndex ..< rawToken.endIndex, in: rawToken)
        if let match = Self.tokenExpression.firstMatch(in: rawToken, range: range),
           let prefixRange = Range(match.range(at: 1), in: rawToken),
           let idRange = Range(match.range(at: 2), in: rawToken)
        {
            id = String(rawToken[idRange])
            kind = switch rawToken[prefixRange] {
            case "@&": .role
            case "#": .channel
            default: .user
            }
            self.rawToken = rawToken
            messageGuildID = nil
            messageChannelID = nil
            return
        }

        guard let url = URL(string: rawToken),
              url.scheme == "https" || url.scheme == "http",
              let host = url.host?.lowercased(),
              Self.messageLinkHosts.contains(host)
        else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard (3 ... 4).contains(components.count),
              components[0] == "channels",
              components[1] == "@me" || UInt64(components[1]) != nil,
              UInt64(components[2]) != nil,
              components.count == 3 || UInt64(components[3]) != nil
        else { return nil }
        id = components.count == 4 ? components[3] : components[2]
        kind = components.count == 4 ? .message : .channelLink
        self.rawToken = rawToken
        messageGuildID = components[1] == "@me" ? nil : components[1]
        messageChannelID = components[2]
    }

    private static let messageLinkHosts: Set<String> = [
        "discord.com", "www.discord.com", "canary.discord.com", "ptb.discord.com",
        "discordapp.com", "www.discordapp.com", "canary.discordapp.com", "ptb.discordapp.com"
    ]
}

public struct MessageDocument: Hashable, Sendable {
    private static let tokenExpression = MessageRegularExpression.make(
        #"<a?:[A-Za-z0-9_]+:[0-9]+>|"# + RenderedMention.tokenPattern
    )

    public static let maximumJumboEmojiCount = 27

    public enum Segment: Hashable, Sendable {
        case markdown(String)
        case customEmoji(RenderedEmoji)
        case mention(RenderedMention)
    }

    public var source: String
    public var segments: [Segment]
    public var isEmojiOnly: Bool

    public init(source: String) {
        self.source = source
        segments = Self.tokenize(source)
        isEmojiOnly = Self.detectEmojiOnly(source: source, segments: segments)
    }

    private static func tokenize(_ source: String) -> [Segment] {
        let matches = tokenExpression.matches(
            in: source, range: NSRange(source.startIndex ..< source.endIndex, in: source)
        )
        guard !matches.isEmpty else { return source.isEmpty ? [] : [.markdown(source)] }
        var result: [Segment] = []
        var cursor = source.startIndex
        for match in matches {
            guard let range = Range(match.range, in: source) else { continue }
            if cursor < range.lowerBound {
                result.append(.markdown(String(source[cursor ..< range.lowerBound])))
            }
            let token = String(source[range])
            if let emoji = RenderedEmoji(rawToken: token) {
                result.append(.customEmoji(emoji))
            } else if let mention = RenderedMention(rawToken: token) {
                result.append(.mention(mention))
            } else {
                result.append(.markdown(token))
            }
            cursor = range.upperBound
        }
        if cursor < source.endIndex {
            result.append(.markdown(String(source[cursor...])))
        }
        return result
    }

    private static func detectEmojiOnly(source: String, segments: [Segment]) -> Bool {
        var emojiCount = 0
        for segment in segments {
            switch segment {
            case let .markdown(value):
                for character in value where !character.isWhitespace {
                    guard isDisplayedEmoji(character) else { return false }
                    emojiCount += 1
                    guard emojiCount <= maximumJumboEmojiCount else { return false }
                }
            case .mention:
                return false
            case .customEmoji:
                emojiCount += 1
                guard emojiCount <= maximumJumboEmojiCount else { return false }
            }
        }
        return emojiCount > 0
    }

    private static func isDisplayedEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        return scalars.contains { $0.properties.isEmojiPresentation }
            || scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
            || (scalars.count > 1 && scalars.contains { $0.properties.isEmoji })
    }
}

@MainActor
public final class MessageDocumentCache {
    public static let shared = MessageDocumentCache()
    private let values = NSCache<NSString, MessageDocumentBox>()

    private init() {
        values.countLimit = 2000
        values.totalCostLimit = 12 * 1024 * 1024
    }

    public func document(for source: String) -> MessageDocument {
        let key = source as NSString
        if let cached = values.object(forKey: key) {
            return cached.value
        }
        let document = MessageDocument(source: source)
        values.setObject(MessageDocumentBox(document), forKey: key, cost: source.utf8.count)
        return document
    }
}

private final class MessageDocumentBox: NSObject {
    let value: MessageDocument
    init(_ value: MessageDocument) {
        self.value = value
    }
}
