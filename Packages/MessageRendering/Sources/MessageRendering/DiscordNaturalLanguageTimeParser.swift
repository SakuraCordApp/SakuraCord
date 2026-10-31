import Foundation

public struct DiscordParsedTimeCandidate: Equatable, Sendable {
    public struct Option: Identifiable, Equatable, Sendable {
        public let id: String
        public let style: String?
        public let displayText: String
        public let markdownToken: String
        public let badgeText: String?

        public init(
            id: String,
            style: String?,
            displayText: String,
            markdownToken: String,
            badgeText: String? = nil
        ) {
            self.id = id
            self.style = style
            self.displayText = displayText
            self.markdownToken = markdownToken
            self.badgeText = badgeText
        }
    }

    public let date: Date
    public let options: [Option]

    public init(date: Date, options: [Option]) {
        self.date = date
        self.options = options
    }
}

public enum DiscordNaturalLanguageTimeParser {
    public static func candidates(
        for query: String,
        referenceDate: Date? = nil,
        now: Date = .now,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [DiscordParsedTimeCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("now") == .orderedSame {
            let target = referenceDate ?? now
            return [makeNowCandidate(targetDate: target, now: now, locale: locale, timeZone: timeZone, calendar: calendar)]
        }

        if let seconds = Int64(trimmed), seconds > 100_000_000, seconds < 100_000_000_000 {
            let date = Date(timeIntervalSince1970: TimeInterval(seconds))
            return [makeUnixCandidate(for: date, now: now, locale: locale, timeZone: timeZone, calendar: calendar)]
        }

        if let relativeDate = parseRelative(query: trimmed, now: now, calendar: calendar, timeZone: timeZone) {
            return [makeStandardCandidate(
                for: relativeDate,
                candidateIndex: 0,
                badgeText: nil,
                now: now,
                locale: locale,
                timeZone: timeZone,
                calendar: calendar
            )]
        }

        if let timeItems = parseTimeOfDay(query: trimmed, now: now, calendar: calendar, timeZone: timeZone) {
            return buildTimeOfDayCandidates(timeItems: timeItems, now: now, locale: locale, timeZone: timeZone, calendar: calendar)
        }

        let naturalDates = parseNaturalDates(query: trimmed, now: now, calendar: calendar, timeZone: timeZone)
        return naturalDates.enumerated().map { idx, item in
            makeStandardCandidate(
                for: item.date,
                candidateIndex: idx,
                badgeText: item.badge,
                now: now,
                locale: locale,
                timeZone: timeZone,
                calendar: calendar
            )
        }
    }

    private static func makeNowCandidate(
        targetDate: Date,
        now: Date,
        locale: Locale,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> DiscordParsedTimeCandidate {
        let seconds = Int64(targetDate.timeIntervalSince1970)
        let shortText = Date.FormatStyle(date: .numeric, time: .standard, locale: locale, calendar: calendar, timeZone: timeZone).format(targetDate)
        let datePart = Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone).format(targetDate)
        let timePart = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone).format(targetDate)
        let weekdayPart = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone).format(targetDate)

        let longText = "\(datePart) at \(timePart)"
        let fullText = "\(weekdayPart) at \(timePart)"
        let relativeText = DiscordTimestampFormatter.relativeText(for: targetDate, relativeTo: now, locale: locale)

        return DiscordParsedTimeCandidate(
            date: targetDate,
            options: [
                .init(id: "now-T", style: "T", displayText: shortText, markdownToken: "<t:\(seconds):T>"),
                .init(id: "now-f", style: "f", displayText: longText, markdownToken: "<t:\(seconds):f>"),
                .init(id: "now-F", style: "F", displayText: fullText, markdownToken: "<t:\(seconds):F>"),
                .init(id: "now-R", style: "R", displayText: relativeText, markdownToken: "<t:\(seconds):R>")
            ]
        )
    }

    private static func makeUnixCandidate(
        for date: Date,
        now: Date,
        locale: Locale,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> DiscordParsedTimeCandidate {
        let seconds = Int64(date.timeIntervalSince1970)
        let shortTime = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let longTime = Date.FormatStyle(date: .omitted, time: .standard, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let shortDate = Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let longDate = Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let weekdayPart = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let longDateTime = "\(longDate) at \(shortTime)"
        let fullDateTime = "\(weekdayPart) at \(shortTime)"
        let relative = DiscordTimestampFormatter.relativeText(for: date, relativeTo: now, locale: locale)

        return DiscordParsedTimeCandidate(
            date: date,
            options: [
                .init(id: "unix-t", style: "t", displayText: shortTime, markdownToken: "<t:\(seconds):t>"),
                .init(id: "unix-T", style: "T", displayText: longTime, markdownToken: "<t:\(seconds):T>"),
                .init(id: "unix-d", style: "d", displayText: shortDate, markdownToken: "<t:\(seconds):d>"),
                .init(id: "unix-D", style: "D", displayText: longDate, markdownToken: "<t:\(seconds):D>"),
                .init(id: "unix-f", style: "f", displayText: longDateTime, markdownToken: "<t:\(seconds):f>"),
                .init(id: "unix-F", style: "F", displayText: fullDateTime, markdownToken: "<t:\(seconds):F>"),
                .init(id: "unix-R", style: "R", displayText: relative, markdownToken: "<t:\(seconds):R>")
            ]
        )
    }

    private static func makeStandardCandidate(
        for date: Date,
        candidateIndex: Int,
        badgeText: String?,
        now: Date,
        locale: Locale,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> DiscordParsedTimeCandidate {
        let seconds = Int64(date.timeIntervalSince1970)
        let shortDateTime = Date.FormatStyle(date: .numeric, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let datePart = Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let timePart = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let weekdayPart = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone).format(date)

        let longDateTime = "\(datePart) at \(timePart)"
        let fullDateTime = "\(weekdayPart) at \(timePart)"
        let relativeText = DiscordTimestampFormatter.relativeText(for: date, relativeTo: now, locale: locale)

        let options: [DiscordParsedTimeCandidate.Option] = [
            .init(
                id: "c\(candidateIndex)-f-short",
                style: "f",
                displayText: shortDateTime,
                markdownToken: "<t:\(seconds):f>",
                badgeText: badgeText
            ),
            .init(
                id: "c\(candidateIndex)-f-long",
                style: "f",
                displayText: longDateTime,
                markdownToken: "<t:\(seconds):f>"
            ),
            .init(
                id: "c\(candidateIndex)-F",
                style: "F",
                displayText: fullDateTime,
                markdownToken: "<t:\(seconds):F>"
            ),
            .init(
                id: "c\(candidateIndex)-R",
                style: "R",
                displayText: relativeText,
                markdownToken: "<t:\(seconds):R>"
            )
        ]

        return DiscordParsedTimeCandidate(date: date, options: options)
    }

    private struct TimeDayItem {
        let date: Date
        let badge: String
    }

    private static func buildTimeOfDayCandidates(
        timeItems: (timeOnly: Date, occurrences: [TimeDayItem]),
        now: Date,
        locale: Locale,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> [DiscordParsedTimeCandidate] {
        var result: [DiscordParsedTimeCandidate] = []
        let seconds = Int64(timeItems.timeOnly.timeIntervalSince1970)
        let timeText = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone).format(timeItems.timeOnly)

        result.append(DiscordParsedTimeCandidate(
            date: timeItems.timeOnly,
            options: [
                .init(id: "time-only-t", style: "t", displayText: timeText, markdownToken: "<t:\(seconds):t>", badgeText: "Time only")
            ]
        ))

        for (idx, item) in timeItems.occurrences.enumerated() {
            result.append(makeStandardCandidate(
                for: item.date,
                candidateIndex: idx + 1,
                badgeText: item.badge,
                now: now,
                locale: locale,
                timeZone: timeZone,
                calendar: calendar
            ))
        }

        return result
    }

    private static func parseTimeOfDay(
        query: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> (timeOnly: Date, occurrences: [TimeDayItem])? {
        let pattern = #"^(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(am|pm)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              let hourRange = Range(match.range(at: 1), in: query),
              var hour = Int(query[hourRange])
        else { return nil }

        var minute = 0
        if match.range(at: 2).location != NSNotFound,
           let minRange = Range(match.range(at: 2), in: query),
           let parsedMinute = Int(query[minRange]) {
            minute = parsedMinute
        }

        var second = 0
        if match.range(at: 3).location != NSNotFound,
           let secRange = Range(match.range(at: 3), in: query),
           let parsedSecond = Int(query[secRange]) {
            second = parsedSecond
        }

        if match.range(at: 4).location != NSNotFound,
           let ampmRange = Range(match.range(at: 4), in: query) {
            let ampm = query[ampmRange].lowercased()
            if ampm == "pm", hour < 12 { hour += 12 }
            if ampm == "am", hour == 12 { hour = 0 }
        } else if hour > 24 || minute > 59 || second > 59 {
            return nil
        }

        var components = calendar.dateComponents(in: timeZone, from: now)
        components.hour = hour
        components.minute = minute
        components.second = second

        guard let targetToday = calendar.date(from: components) else { return nil }

        if targetToday < now {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: targetToday) ?? targetToday
            return (
                timeOnly: targetToday,
                occurrences: [
                    TimeDayItem(date: tomorrow, badge: "Tomorrow"),
                    TimeDayItem(date: targetToday, badge: "Today")
                ]
            )
        } else {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: targetToday) ?? targetToday
            return (
                timeOnly: targetToday,
                occurrences: [
                    TimeDayItem(date: targetToday, badge: "Today"),
                    TimeDayItem(date: yesterday, badge: "Yesterday")
                ]
            )
        }
    }

    private static func parseRelative(
        query: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        let lower = query.lowercased()
        if let date = parseNamedRelativeDay(lower: lower, now: now, calendar: calendar, timeZone: timeZone) {
            return date
        }
        if let date = parseRelativeOffset(lower: lower, now: now, calendar: calendar) {
            return date
        }
        if let date = parseWeekday(lower: lower, now: now, calendar: calendar, timeZone: timeZone) {
            return date
        }
        return nil
    }

    private static func parseNamedRelativeDay(
        lower: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        let dayOffset: Int
        if lower == "today" {
            dayOffset = 0
        } else if lower == "tomorrow" {
            dayOffset = 1
        } else if lower == "yesterday" {
            dayOffset = -1
        } else {
            return nil
        }

        guard let target = dayOffset == 0 ? now : calendar.date(byAdding: .day, value: dayOffset, to: now) else {
            return nil
        }
        var comp = calendar.dateComponents(in: timeZone, from: target)
        comp.hour = 12
        comp.minute = 0
        comp.second = 0
        return calendar.date(from: comp) ?? target
    }

    private static func parseRelativeOffset(
        lower: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let inPattern = #"^in\s+(?:(\d+)|(a|an))\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks|mo|month|months|y|yr|yrs|year|years)$"#
        let agoPattern = #"^(?:(\d+)|(a|an))\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks|mo|month|months|y|yr|yrs|year|years)\s+ago$"#

        if let regex = try? NSRegularExpression(pattern: inPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            let val = match.range(at: 1).location != NSNotFound
                ? (Range(match.range(at: 1), in: lower).flatMap { Int(lower[$0]) } ?? 1)
                : 1
            if let unitRange = Range(match.range(at: 3), in: lower) {
                return resolveOffset(value: val, unit: String(lower[unitRange]), sign: 1, now: now, calendar: calendar)
            }
        }

        if let regex = try? NSRegularExpression(pattern: agoPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            let val = match.range(at: 1).location != NSNotFound
                ? (Range(match.range(at: 1), in: lower).flatMap { Int(lower[$0]) } ?? 1)
                : 1
            if let unitRange = Range(match.range(at: 3), in: lower) {
                return resolveOffset(value: val, unit: String(lower[unitRange]), sign: -1, now: now, calendar: calendar)
            }
        }

        return nil
    }

    private static func parseWeekday(
        lower: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        let weekdayPattern = #"^(?:(next|this|last)\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)$"#
        guard let regex = try? NSRegularExpression(pattern: weekdayPattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let nameRange = Range(match.range(at: 2), in: lower) else {
            return nil
        }

        let modifier = match.range(at: 1).location != NSNotFound
            ? Range(match.range(at: 1), in: lower).map { String(lower[$0]) }
            : nil
        let weekdayName = String(lower[nameRange])
        let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
        guard let targetWeekday = weekdays[weekdayName] else { return nil }

        let currentWeekday = calendar.component(.weekday, from: now)
        var diff = targetWeekday - currentWeekday
        if modifier == "last" {
            if diff >= 0 { diff -= 7 }
        } else if modifier == "next" {
            if diff <= 0 { diff += 7 }
            diff += 7
        } else if diff <= 0 {
            diff += 7
        }

        guard let targetDate = calendar.date(byAdding: .day, value: diff, to: now) else { return nil }
        var comp = calendar.dateComponents(in: timeZone, from: targetDate)
        comp.hour = 12
        comp.minute = 0
        comp.second = 0
        return calendar.date(from: comp) ?? targetDate
    }

    private static func resolveOffset(
        value: Int,
        unit: String,
        sign: Int,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let delta = sign * value
        switch unit {
        case "s", "sec", "secs", "second", "seconds":
            return calendar.date(byAdding: .second, value: delta, to: now)
        case "m", "min", "mins", "minute", "minutes":
            return calendar.date(byAdding: .minute, value: delta, to: now)
        case "h", "hr", "hrs", "hour", "hours":
            return calendar.date(byAdding: .hour, value: delta, to: now)
        case "d", "day", "days":
            return calendar.date(byAdding: .day, value: delta, to: now)
        case "w", "wk", "wks", "week", "weeks":
            return calendar.date(byAdding: .day, value: delta * 7, to: now)
        case "mo", "month", "months":
            return calendar.date(byAdding: .month, value: delta, to: now)
        case "y", "yr", "yrs", "year", "years":
            return calendar.date(byAdding: .year, value: delta, to: now)
        default:
            return nil
        }
    }

    private struct ParsedNaturalDate {
        let date: Date
        let badge: String?
    }

    private static func parseNaturalDates(
        query: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> [ParsedNaturalDate] {
        var baseDate: Date?
        let hasExplicitYear = query.range(of: #"\b(19\d\d|20\d\d)\b"#, options: .regularExpression) != nil

        let fallbackFormats = [
            "d MMMM yyyy", "d MMM yyyy", "MMMM d yyyy", "MMM d yyyy",
            "d MMMM", "d MMM", "MMMM d", "MMM d",
            "d/M/yyyy HH:mm:ss", "d/M/yyyy HH:mm", "d/M/yyyy h:mm a", "d/M/yyyy",
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd h:mm a", "yyyy-MM-dd",
            "d-M-yyyy HH:mm", "d-M-yyyy", "d.M.yyyy", "yyyy/MM/dd", "M/d/yyyy", "M/d"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in fallbackFormats {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: query) {
                baseDate = parsed
                break
            }
        }

        if baseDate == nil,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(query.startIndex..., in: query)
            let matches = detector.matches(in: query, range: range)
            baseDate = matches.first?.date
        }

        guard var date = baseDate else { return [] }

        var comp = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        comp.timeZone = timeZone
        if !hasExplicitYear {
            comp.year = calendar.component(.year, from: now)
        }

        let hasExplicitTime = query.range(
            of: #"(?:\b\d{1,2}:\d{2}\b|\b(?:am|pm)\b)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if !hasExplicitTime {
            comp.hour = 12
            comp.minute = 0
            comp.second = 0
        }

        guard let resolvedDate = calendar.date(from: comp) else { return [] }
        date = resolvedDate

        if hasExplicitYear {
            return [ParsedNaturalDate(date: date, badge: nil)]
        }

        if date < now {
            let future = calendar.date(byAdding: .year, value: 1, to: date) ?? date
            return [
                ParsedNaturalDate(date: future, badge: "Next year"),
                ParsedNaturalDate(date: date, badge: "This year")
            ]
        } else {
            let past = calendar.date(byAdding: .year, value: -1, to: date) ?? date
            return [
                ParsedNaturalDate(date: date, badge: "This year"),
                ParsedNaturalDate(date: past, badge: "Last year")
            ]
        }
    }
}
