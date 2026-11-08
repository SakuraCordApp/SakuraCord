import Foundation

public struct DiscordTimestampToken: Hashable, Sendable {
    public enum Style: String, CaseIterable, Hashable, Identifiable, Sendable {
        case shortTime = "t"
        case mediumTime = "T"
        case shortDate = "d"
        case longDate = "D"
        case longDateShortTime = "f"
        case fullDateShortTime = "F"
        case shortDateShortTime = "s"
        case shortDateMediumTime = "S"
        case relative = "R"

        public var id: String { rawValue }
    }

    public let seconds: Int64
    public let style: Style

    public init(seconds: Int64, style: Style) {
        self.seconds = seconds
        self.style = style
    }

    public init?(rawToken: String) {
        guard rawToken.hasPrefix("<t:"), rawToken.hasSuffix(">") else { return nil }
        let components = rawToken.dropFirst(3).dropLast()
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(components.count),
              let seconds = Int64(components[0]),
              let style = components.count == 2 ? Style(rawValue: String(components[1])) : .longDateShortTime
        else { return nil }
        self.seconds = seconds
        self.style = style
    }

    public var rawToken: String { "<t:\(seconds):\(style.rawValue)>" }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

    public func formatted(
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        relativeTo now: Date = .now
    ) -> String {
        DiscordTimestampFormatter.string(for: date, style: style, relativeTo: now, locale: locale, timeZone: timeZone)
    }
}
