import Foundation

/// Discord's timestamp styles: `d` and `s` print the year in full, and
/// `R` follows moment.js, which counts up to 25 days before it says
/// "a month", and up to 21 hours before it says "a day".
enum DiscordTimestampFormatter {
    static func string(
        for date: Date, style: DiscordTimestampToken.Style, relativeTo now: Date,
        locale: Locale, timeZone: TimeZone
    ) -> String {
        if style == .relative { return relative(date, to: now, locale: locale) }
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

    private static func relative(_ date: Date, to now: Date, locale: Locale) -> String {
        let interval = date.timeIntervalSince(now)
        let duration = abs(interval)
        // Each unit rounds the whole interval, as moment's durations do.
        // Seconds in each unit, and the count below which moment uses it.
        let units: [(Calendar.Component, (seconds: Double, below: Double))] = [
            (.second, (1, 60)), (.minute, (60, 60)), (.hour, (3_600, 22)), (.day, (86_400, 26)), (.month, (2_629_746, 11)),
        ]
        let (unit, amount) = units.lazy
            .map { ($0.0, (duration / $0.1.seconds).rounded(), $0.1.below) }
            .first { $0.1 < $0.2 }
            .map { ($0.0, $0.1) } ?? (.year, (duration / 31_556_952).rounded())
        var components = DateComponents()
        components.setValue(Int(max(amount, unit == .second ? 0 : 1)) * (interval < 0 ? -1 : 1), for: unit)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(from: components)
    }
}
