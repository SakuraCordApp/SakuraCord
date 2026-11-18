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

    /// The text Discord shows for a bare or `<…>` link: the link as `new URL`
    /// reads it, without credentials, with a lowercase or punycode host, no
    /// default port and at least a `/` path. Escapes are decoded unless the
    /// character could hide or fake part of the address.
    static func displayText(_ link: Substring, url: URL) -> String {
        guard let schemeEnd = link.range(of: "://"),
              let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost
        else { return String(link) }
        var text = link[..<schemeEnd.lowerBound].lowercased() + "://" + host.lowercased()
        if let port = url.port, port != (url.scheme?.lowercased() == "https" ? 443 : 80) { text += ":\(port)" }
        let rest = link[schemeEnd.upperBound...].drop { !"/?#".contains($0) }
        let fragmentStart = rest.firstIndex(of: "#") ?? rest.endIndex
        let queryStart = rest[..<fragmentStart].firstIndex(of: "?") ?? fragmentStart
        let path = rest[..<queryStart]
        text += path.isEmpty ? "/" : displayed(path, encoding: "`{}")
        // An empty query or fragment shows neither its `?` nor its `#`.
        if rest[queryStart ..< fragmentStart].count > 1 {
            text += "?" + displayed(rest[rest.index(after: queryStart) ..< fragmentStart], encoding: "'")
        }
        if rest[fragmentStart...].count > 1 { text += "#" + displayed(rest[rest.index(after: fragmentStart)...], encoding: "`") }
        return text
    }

    /// A path, query or fragment as `new URL` encodes it and Discord then
    /// decodes it, walking the decoded text beside the source: `encoding` and
    /// hidden characters stay escaped, as do escaped ASCII characters other
    /// than letters, digits and `"-<>_~`. Where the escapes don't decode,
    /// Discord shows them as they are.
    private static func displayed(_ component: Substring, encoding: String) -> String {
        func escaped(_ scalar: Unicode.Scalar) -> String {
            String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }
        guard let decoded = component.removingPercentEncoding else {
            return component.unicodeScalars.map {
                $0.isASCII && !encoding.unicodeScalars.contains($0) ? String($0) : escaped($0)
            }.joined()
        }
        var source = component.unicodeScalars[...]
        var result = ""
        for scalar in decoded.unicodeScalars {
            let wasEscaped = source.first != scalar
            source = source.dropFirst(wasEscaped ? 3 * String(scalar).utf8.count : 1)
            let staysEscaped = if !scalar.isASCII {
                hiddenScalars.contains { $0.contains(scalar.value) }
            } else if wasEscaped {
                !scalar.properties.isAlphabetic && !("0" ... "9").contains(scalar) && !#""-<>_~"#.unicodeScalars.contains(scalar)
            } else {
                encoding.unicodeScalars.contains(scalar)
            }
            result += staysEscaped ? escaped(scalar) : String(scalar)
        }
        return result
    }

    /// The invisible, spacing, bidirectional and padlock characters Discord
    /// shows escaped in a link.
    private static let hiddenScalars: [ClosedRange<UInt32>] = [
        133 ... 133, 160 ... 160, 173 ... 173, 847 ... 847, 1536 ... 1541, 1564 ... 1564, 1757 ... 1757, 1807 ... 1807,
        2274 ... 2274, 4447 ... 4448, 5760 ... 5760, 6068 ... 6069, 6155 ... 6158, 8192 ... 8207, 8232 ... 8239,
        8287 ... 8303, 10240 ... 10240, 12288 ... 12288, 12644 ... 12644, 65024 ... 65039, 65279 ... 65279,
        65440 ... 65440, 65520 ... 65531, 69821 ... 69821, 69837 ... 69837, 78896 ... 78904, 113824 ... 113827,
        119155 ... 119162, 128271 ... 128272, 128274 ... 128275, 917504 ... 921599,
    ]

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
