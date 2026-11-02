import Foundation

/// Recognizes complete Discord attachment URLs eligible for expiry refresh.
public enum DiscordAttachmentLink {
    /// Discord's attachment hosts and path, used only to classify a complete URL.
    /// The filename and query may hold any URL characters, so a percent-encoded
    /// name still counts.
    private static let expression = MessageRegularExpression.make(
        #"https://(?:[A-Za-z0-9-]+\.)*(?:(?:media|images)(?:-[A-Za-z0-9]+)?\.discordapp\.net|cdn(?:-[A-Za-z0-9]+)?\.discordapp\.com)"#
            + #"/(?:attachments|ephemeral-attachments)/\d+/\d+/[^/?#\s]+(?:\?[^#\s]*)?"#
    )

    private static let refreshLeadTime: TimeInterval = 60 * 60

    /// Whether a URL is exactly a Discord attachment link.
    public static func matches(_ url: URL) -> Bool {
        let value = url.absoluteString
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        return expression.firstMatch(in: value, options: .anchored, range: range)?.range == range
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
