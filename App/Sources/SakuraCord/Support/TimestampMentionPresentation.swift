import Foundation
import MessageRendering
import SakuraCordModels

nonisolated enum TimestampMentionPresentation {
    static func tokens(in source: String) -> [DiscordTimestampToken] {
        guard source.contains("<t:") else { return [] }
        return RichMessageAttributedText.prepare(source: source).tokens.compactMap { token in
            guard case let .mention(mention) = token, mention.kind == .timestamp else { return nil }
            return DiscordTimestampToken(rawToken: mention.rawToken)
        }
    }

    static func labels(in source: String, at date: Date) -> [String: String] {
        tokens(in: source).reduce(into: [:]) { result, token in
            result[token.rawToken] = token.formatted(relativeTo: date)
        }
    }

    static func sources(in message: Message, replyContent: String?) -> [String] {
        var sources = [message.content]
        if let replyContent { sources.append(replyContent) }
        var embeds = message.embeds
        var components = message.components
        if let forwarded = message.forwardedSnapshot {
            sources.append(forwarded.content)
            embeds += forwarded.embeds
            components += forwarded.components
        }
        for embed in embeds {
            if let description = embed.description { sources.append(description) }
            sources += embed.fields.map(\.value)
            components += embed.components ?? []
        }
        sources += components.flatMap(\.textDisplayContents)
        return sources.filter { !tokens(in: $0).isEmpty }
    }

    static func refreshed(
        _ presentations: [String: MentionPresentation],
        source: String,
        at date: Date
    ) -> [String: MentionPresentation] {
        guard source.contains("<t:") else { return presentations }
        var result = presentations
        for case let .mention(mention) in RichMessageAttributedText.prepare(source: source).tokens {
            guard mention.kind == .timestamp,
                  let token = DiscordTimestampToken(rawToken: mention.rawToken) else { continue }
            result[mention.rawToken] = MentionPresentation(
                rawToken: mention.rawToken,
                label: token.formatted(relativeTo: date),
                target: .unresolved,
                isTimestamp: true
            )
        }
        return result
    }
}
