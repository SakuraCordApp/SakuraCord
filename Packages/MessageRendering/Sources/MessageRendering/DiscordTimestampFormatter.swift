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
        let months = monthSpan(from: min(date, now), to: max(date, now), timeZone: timeZone)
        // Each unit rounds the whole span, as moment's durations do, and is
        // used below its threshold.
        let units: [(Calendar.Component, (amount: Double, below: Double))] = [
            (.second, (duration, 60)), (.minute, (duration / 60, 60)), (.hour, (duration / 3_600, 22)),
            (.day, (duration / 86_400, 26)), (.month, (months, 11)),
        ]
        let (unit, count) = units.first { $0.1.amount.rounded() < $0.1.below } ?? (.year, (months / 12, 0))
        var components = DateComponents()
        components.setValue(Int(max(count.amount.rounded(), unit == .second ? 0 : 1)) * (interval < 0 ? -1 : 1), for: unit)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(from: components)
    }

    /// moment's month count: whole calendar months from the earlier date in
    /// local time, then the remainder at 146,097 days per 4,800 months.
    private static func monthSpan(from start: Date, to end: Date, timeZone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var months = (calendar.component(.year, from: end) - calendar.component(.year, from: start)) * 12
            + calendar.component(.month, from: end) - calendar.component(.month, from: start)
        var anchor = calendar.date(byAdding: .month, value: months, to: start) ?? start
        if anchor > end {
            months -= 1
            anchor = calendar.date(byAdding: .month, value: months, to: start) ?? start
        }
        return Double(months) + end.timeIntervalSince(anchor) / 86_400 * 4_800 / 146_097
    }
}
