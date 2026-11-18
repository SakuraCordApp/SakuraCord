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
    /// default port, and its `.` and `..` path segments resolved. Escapes are
    /// decoded unless the character could hide or fake part of the address.
    static func displayText(_ link: Substring, url: URL) -> String {
        guard let schemeEnd = link.range(of: "://"),
              let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost
        else { return String(link) }
        var text = link[..<schemeEnd.lowerBound].lowercased() + "://" + host.lowercased()
        if let port = url.port, port != (url.scheme?.lowercased() == "https" ? 443 : 80) { text += ":\(port)" }
        let rest = link[schemeEnd.upperBound...].drop { !"/?#".contains($0) }
        let fragmentStart = rest.firstIndex(of: "#") ?? rest.endIndex
        let queryStart = rest[..<fragmentStart].firstIndex(of: "?") ?? fragmentStart
        text += displayed(resolvingDotSegments(rest[..<queryStart])[...], encoding: "`{}")
        // An empty query or fragment shows neither its `?` nor its `#`.
        let query = rest[queryStart ..< fragmentStart].dropFirst()
        if !query.isEmpty { text += "?" + displayed(query, encoding: "'") }
        let fragment = rest[fragmentStart...].dropFirst()
        if !fragment.isEmpty { text += "#" + displayed(fragment, encoding: "`") }
        return text
    }

    /// A path as `new URL` resolves it: `.` and `..` segments, also written
    /// with `%2e`, are dropped, a `..` with the segment before it, and an
    /// empty path is `/`.
    private static func resolvingDotSegments(_ path: Substring) -> String {
        var segments: [Substring] = []
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            let dots = part.lowercased().replacingOccurrences(of: "%2e", with: ".")
            if dots == ".." { _ = segments.popLast() } else if dots != "." { segments.append(part) }
            if dots == "." || dots == "..", index == parts.count - 1 { segments.append("") }
        }
        return "/" + segments.joined(separator: "/")
    }

    /// A path, query or fragment as `new URL` escapes `encoding` in it and
    /// Discord then decodes it, walking the decoded text beside the source.
    /// Hidden characters stay escaped, as does escaped ASCII other than what
    /// `encodeURIComponent` leaves as it is or Discord decodes: letters,
    /// digits and `"-<>_~!'()*.`. Where the escapes don't decode, Discord
    /// shows them as they are.
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
            // Once the escapes decode, every `%` in the source starts one.
            let isSourceEscape = source.first == "%" || source.first != scalar
            source = source.dropFirst(isSourceEscape ? 3 * String(scalar).utf8.count : 1)
            let staysEscaped = if !scalar.isASCII {
                hiddenScalars.contains { $0.contains(scalar.value) }
            } else {
                (isSourceEscape || encoding.unicodeScalars.contains(scalar))
                    && !scalar.properties.isAlphabetic && !("0" ... "9").contains(scalar)
                    && !#""-<>_~!'()*."#.unicodeScalars.contains(scalar)
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
