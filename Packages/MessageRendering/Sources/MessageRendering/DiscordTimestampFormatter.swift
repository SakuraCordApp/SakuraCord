import Foundation

public enum DiscordTimestampFormatter {
    public static func formatted(
        seconds: Int64,
        style: String?,
        now: Date = .now,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        switch style {
        case "t":
            var format = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
            format.capitalizationContext = .unknown
            return format.format(date)
        case "T":
            var format = Date.FormatStyle(date: .omitted, time: .standard, locale: locale, calendar: calendar, timeZone: timeZone)
            format.capitalizationContext = .unknown
            return format.format(date)
        case "d":
            var format = Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
            format.capitalizationContext = .unknown
            return format.format(date)
        case "D":
            var format = Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
            format.capitalizationContext = .unknown
            return format.format(date)
        case "f", nil:
            var format = Date.FormatStyle(date: .long, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
            format.capitalizationContext = .unknown
            return format.format(date)
        case "F":
            var format = Date.FormatStyle(date: .complete, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
            format.capitalizationContext = .unknown
            return format.format(date)
        case "s":
            var format = Date.FormatStyle(date: .numeric, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
            format.capitalizationContext = .unknown
            return format.format(date)
        case "S":
            var format = Date.FormatStyle(date: .numeric, time: .standard, locale: locale, calendar: calendar, timeZone: timeZone)
            format.capitalizationContext = .unknown
            return format.format(date)
        case "R":
            return relativeText(for: date, relativeTo: now, locale: locale)
        default:
            var format = Date.FormatStyle(date: .long, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
            format.capitalizationContext = .unknown
            return format.format(date)
        }
    }

    public static func formatted(
        date: Date,
        style: String?,
        now: Date = .now,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        formatted(seconds: Int64(date.timeIntervalSince1970), style: style, now: now, locale: locale, timeZone: timeZone, calendar: calendar)
    }

    public static func tooltip(
        seconds: Int64,
        style: String?,
        now: Date = .now,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        if style == "R" {
            var format = Date.FormatStyle(date: .complete, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
            format.capitalizationContext = .unknown
            return format.format(date)
        } else {
            return relativeText(for: date, relativeTo: now, locale: locale)
        }
    }

    public static func tooltip(
        date: Date,
        style: String?,
        now: Date = .now,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        tooltip(seconds: Int64(date.timeIntervalSince1970), style: style, now: now, locale: locale, timeZone: timeZone, calendar: calendar)
    }

    public static func relativeText(
        for date: Date,
        relativeTo now: Date = .now,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        let diff = Int(date.timeIntervalSince(now))
        let absDiff = abs(diff)
        if absDiff >= 7 * 86400, absDiff < 26 * 86400 {
            return formatter.localizedString(from: DateComponents(day: diff / 86400))
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
