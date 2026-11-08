import Foundation

/// Discord's timestamp styles: `d` and `s` print the year in full, and
/// `R` follows moment.js, which counts up to 25 days before it says
/// "a month", and up to 21 hours before it says "a day".
enum DiscordTimestampFormatter {
    static func string(
        for date: Date, style: DiscordTimestampToken.Style, relativeTo now: Date,
        locale: Locale, timeZone: TimeZone
    ) -> String {
        if style == .relative { return relative(date, to: now, locale: locale, timeZone: timeZone) }
        let parts: (Date.FormatStyle.DateStyle, Date.FormatStyle.TimeStyle) = switch style {
        case .shortTime: (.omitted, .shortened)
        case .mediumTime: (.omitted, .standard)
        case .shortDate: (.numeric, .omitted)
        case .longDate: (.long, .omitted)
        case .longDateShortTime: (.long, .shortened)
        case .fullDateShortTime: (.complete, .shortened)
        case .shortDateShortTime: (.numeric, .shortened)
        case .shortDateMediumTime: (.numeric, .standard)
        case .relative: (.omitted, .omitted)
        }
        return Date.FormatStyle(date: parts.0, time: parts.1, locale: locale, timeZone: timeZone).format(date)
    }

    private static func relative(_ date: Date, to now: Date, locale: Locale, timeZone: TimeZone) -> String {
        let interval = date.timeIntervalSince(now)
        let duration = abs(interval)
        // moment rounds each unit and uses it while the rounded count is
        // below its threshold: 60 s, 60 min, 22 h, 26 d, 11 months.
        let (unit, count): (Calendar.Component, Double) = switch duration {
        case ..<59.5: (.second, duration)
        case ..<(59.5 * 60): (.minute, duration / 60)
        case ..<(21.5 * 3_600): (.hour, duration / 3_600)
        case ..<(25.5 * 86_400): (.day, duration / 86_400)
        default: monthsOrYears(from: min(date, now), to: max(date, now), timeZone: timeZone)
        }
        var components = DateComponents()
        components.setValue(Int(max(count.rounded(), unit == .second ? 0 : 1)) * (interval < 0 ? -1 : 1), for: unit)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(from: components)
    }

    /// moment's month count: whole calendar months from the earlier date in
    /// local time, then the remainder at 146,097 days per 4,800 months; years
    /// from 11 months.
    private static func monthsOrYears(from start: Date, to end: Date, timeZone: TimeZone) -> (Calendar.Component, Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var months = (calendar.component(.year, from: end) - calendar.component(.year, from: start)) * 12
            + calendar.component(.month, from: end) - calendar.component(.month, from: start)
        var anchor = calendar.date(byAdding: .month, value: months, to: start) ?? start
        if anchor > end {
            months -= 1
            anchor = calendar.date(byAdding: .month, value: months, to: start) ?? start
        }
        let count = Double(months) + end.timeIntervalSince(anchor) / 86_400 * 4_800 / 146_097
        return count < 10.5 ? (.month, count) : (.year, count / 12)
    }
}
