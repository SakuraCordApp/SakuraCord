import Foundation

/// A bare Discord CDN attachment URL that message text presents as its file name.
public struct DiscordAttachmentLink: Hashable, Sendable {
    public let url: URL
    public let name: String

    /// Matches Discord's `attachmentLink` markdown rule. The rule is anchored only at its start,
    /// so a trailing remainder such as `%20name.png` or `#fragment` stays ordinary text.
    private static let expression = MessageRegularExpression.make(
        #"https://(?:[A-Za-z0-9-]+\.)*(?:(?:media|images)(?:-[A-Za-z0-9]+)?\.discordapp\.net|cdn(?:-[A-Za-z0-9]+)?\.discordapp\.com)"#
            + #"/(?:attachments|ephemeral-attachments)/\d+/\d+/([A-Za-z0-9._-]*[A-Za-z0-9_-])(?:\?[A-Za-z0-9?&=_-]*)?"#
    )

    private static let refreshLeadTime: TimeInterval = 60 * 60

    /// Returns the attachment link beginning at the start of `source` and the index after it.
    public static func prefix(
        of source: Substring
    ) -> (link: DiscordAttachmentLink, endIndex: String.Index)? {
        guard source.hasPrefix("https://") else { return nil }
        let range = NSRange(source.startIndex ..< source.endIndex, in: source.base)
        guard let match = expression.firstMatch(in: source.base, options: .anchored, range: range),
              let matchRange = Range(match.range, in: source.base),
              let nameRange = Range(match.range(at: 1), in: source.base),
              let url = URL(string: String(source.base[matchRange]))
        else { return nil }
        return (DiscordAttachmentLink(url: url, name: String(source.base[nameRange])), matchRange.upperBound)
    }

    /// Whether a URL is exactly a Discord attachment link.
    public static func matches(_ url: URL) -> Bool {
        let value = url.absoluteString
        return prefix(of: value[...])?.endIndex == value.endIndex
    }

    /// Discord refreshes a link that is unsigned or whose hexadecimal `ex` expiry is within an hour.
    public static func needsRefresh(_ url: URL, now: Date) -> Bool {
        guard let expiry = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "ex" })?.value
            .flatMap({ UInt64($0, radix: 16) })
        else { return true }
        return Date(timeIntervalSince1970: TimeInterval(expiry)) <= now.addingTimeInterval(refreshLeadTime)
    }
}
