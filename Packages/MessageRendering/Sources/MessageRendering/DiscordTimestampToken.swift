import Foundation

public struct DiscordTimestampToken: Hashable, Sendable {
    public enum Style: String, CaseIterable, Hashable, Sendable {
        case shortTime = "t"
        case mediumTime = "T"
        case shortDate = "d"
        case longDate = "D"
        case longDateShortTime = "f"
        case fullDateShortTime = "F"
        case shortDateShortTime = "s"
        case shortDateMediumTime = "S"
        case relative = "R"
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
              components.count == 1 || Style(rawValue: String(components[1])) != nil
        else { return nil }
        self.seconds = seconds
        style = components.count == 2
            ? Style(rawValue: String(components[1])) ?? .longDateShortTime
            : .longDateShortTime
    }

    public var rawToken: String { "<t:\(seconds):\(style.rawValue)>" }

    public func formatted(
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        relativeTo now: Date = .now
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        if style == .relative {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: now)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch style {
        case .shortTime: formatter.dateStyle = .none; formatter.timeStyle = .short
        case .mediumTime: formatter.dateStyle = .none; formatter.timeStyle = .medium
        case .shortDate: formatter.dateStyle = .short; formatter.timeStyle = .none
        case .longDate: formatter.dateStyle = .long; formatter.timeStyle = .none
        case .longDateShortTime: formatter.dateStyle = .long; formatter.timeStyle = .short
        case .fullDateShortTime: formatter.dateStyle = .full; formatter.timeStyle = .short
        case .shortDateShortTime: formatter.dateStyle = .short; formatter.timeStyle = .short
        case .shortDateMediumTime: formatter.dateStyle = .short; formatter.timeStyle = .medium
        case .relative: break
        }
        return formatter.string(from: date)
    }
}
