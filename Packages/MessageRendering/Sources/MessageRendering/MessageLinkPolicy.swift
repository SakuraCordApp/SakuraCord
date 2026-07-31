import Foundation
import SakuraCordModels

public enum MessageLinkDestination: Hashable, Sendable {
    case discordChannel(guildID: GuildID?, channelID: ChannelID)
    case web(URL)
}

public enum MessageLinkPolicy {
    public static func destination(
        for url: URL
    ) -> MessageLinkDestination? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else { return nil }
        let channel = discordChannelDestination(for: url)
        if scheme == "https", let channel {
            return channel
        }
        return .web(url)
    }

    public static func allowedURL(from rawValue: String) -> URL? {
        let value = angleBracketDestinationContent(from: rawValue) ?? rawValue
        guard let url = URL(string: value),
              destination(for: url) != nil
        else { return nil }
        return url
    }

    private static func angleBracketDestinationContent(
        from rawValue: String
    ) -> String? {
        guard rawValue.first == "<", rawValue.last == ">" else { return nil }
        let value = rawValue.dropFirst().dropLast()
        guard !value.isEmpty,
              !value.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" })
        else { return nil }
        return String(value)
    }

    private static func discordChannelDestination(
        for url: URL
    ) -> MessageLinkDestination? {
        guard let host = url.host?.lowercased(),
              discordHosts.contains(host)
        else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 3,
              components[0] == "channels",
              components[1] == "@me" || UInt64(components[1]) != nil,
              let channelID = ChannelID(components[2])
        else { return nil }
        let guildID = components[1] == "@me"
            ? nil
            : GuildID(components[1])
        return .discordChannel(guildID: guildID, channelID: channelID)
    }

    private static let discordHosts: Set<String> = [
        "discord.com", "www.discord.com", "canary.discord.com", "ptb.discord.com",
        "discordapp.com", "www.discordapp.com", "canary.discordapp.com",
        "ptb.discordapp.com"
    ]
}
