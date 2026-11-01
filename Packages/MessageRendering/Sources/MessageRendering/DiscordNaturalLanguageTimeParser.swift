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

        if let combinedDate = parseCombined(query: trimmed, now: referenceDate ?? now, calendar: calendar, timeZone: timeZone) {
            return [makeStandardCandidate(
                for: combinedDate,
                candidateIndex: 0,
                badgeText: nil,
                now: now,
                locale: locale,
                timeZone: timeZone,
                calendar: calendar
            )]
        }

        if let relativeDate = parseRelative(query: trimmed, now: referenceDate ?? now, calendar: calendar, timeZone: timeZone) {
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
        let longDate = Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let shortTime = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let weekdayPart = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone).format(date)
        let longDateTime = "\(longDate) at \(shortTime)"
        let fullDateTime = "\(weekdayPart) at \(shortTime)"
        let relative = DiscordTimestampFormatter.relativeText(for: date, relativeTo: now, locale: locale)

        let prefix = "cand-\(candidateIndex)"
        return DiscordParsedTimeCandidate(
            date: date,
            options: [
                .init(id: "\(prefix)-f-short", style: "f", displayText: shortDateTime, markdownToken: "<t:\(seconds):f>", badgeText: badgeText),
                .init(id: "\(prefix)-f-long", style: "f", displayText: longDateTime, markdownToken: "<t:\(seconds):f>"),
                .init(id: "\(prefix)-F-full", style: "F", displayText: fullDateTime, markdownToken: "<t:\(seconds):F>"),
                .init(id: "\(prefix)-R-rel", style: "R", displayText: relative, markdownToken: "<t:\(seconds):R>")
            ]
        )
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

    private struct ParsedTimeOfDay {
        let hour: Int
        let minute: Int
        let second: Int
    }

    private static func extractTimeOfDay(
        from text: String
    ) -> ParsedTimeOfDay? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.lowercased().hasPrefix("at ")
            ? String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
        let pattern = #"^(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(am|pm)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let hourRange = Range(match.range(at: 1), in: cleaned),
              var hour = Int(cleaned[hourRange])
        else { return nil }

        var minute = 0
        if match.range(at: 2).location != NSNotFound,
           let minRange = Range(match.range(at: 2), in: cleaned),
           let parsedMinute = Int(cleaned[minRange]) {
            minute = parsedMinute
        }

        var second = 0
        if match.range(at: 3).location != NSNotFound,
           let secRange = Range(match.range(at: 3), in: cleaned),
           let parsedSecond = Int(cleaned[secRange]) {
            second = parsedSecond
        }

        if match.range(at: 4).location != NSNotFound,
           let ampmRange = Range(match.range(at: 4), in: cleaned) {
            let ampm = cleaned[ampmRange].lowercased()
            if ampm == "pm", hour < 12 { hour += 12 }
            if ampm == "am", hour == 12 { hour = 0 }
        } else if hour > 24 || minute > 59 || second > 59 {
            return nil
        }

        return ParsedTimeOfDay(hour: hour, minute: minute, second: second)
    }

    private static func parseTimeOfDay(
        query: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> (timeOnly: Date, occurrences: [TimeDayItem])? {
        guard let time = extractTimeOfDay(from: query) else { return nil }

        var components = calendar.dateComponents(in: timeZone, from: now)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second

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

    private static func parseCombined(
        query: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = parseDayWithTime(lower: lower, now: now, calendar: calendar, timeZone: timeZone) {
            return date
        }
        if let date = parseYearWithDate(lower: lower, now: now, calendar: calendar, timeZone: timeZone) {
            return date
        }
        if let date = parseWeekdayWithTime(lower: lower, now: now, calendar: calendar, timeZone: timeZone) {
            return date
        }
        if let date = parseRelativeDayOffsetWithTime(lower: lower, now: now, calendar: calendar, timeZone: timeZone) {
            return date
        }
        return nil
    }

    private static let namedDayPhrases: [(phrase: String, offset: Int)] = [
        ("day before yesterday", -2),
        ("day after tomorrow", 2),
        ("tomorrow", 1),
        ("yesterday", -1),
        ("next day", 1),
        ("last day", -1),
        ("today", 0)
    ]

    private static func parseDayWithTime(
        lower: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        for item in namedDayPhrases {
            var timeCandidate: String?
            if lower.hasPrefix(item.phrase + " ") {
                timeCandidate = String(lower.dropFirst(item.phrase.count))
            } else if lower.hasSuffix(" " + item.phrase) {
                timeCandidate = String(lower.dropLast(item.phrase.count))
            }

            guard let timeStr = timeCandidate,
                  let time = extractTimeOfDay(from: timeStr)
            else { continue }

            let baseDate = item.offset == 0
                ? now
                : (calendar.date(byAdding: .day, value: item.offset, to: now) ?? now)

            var comp = calendar.dateComponents(in: timeZone, from: baseDate)
            comp.hour = time.hour
            comp.minute = time.minute
            comp.second = time.second
            return calendar.date(from: comp)
        }
        return nil
    }

    private struct ParsedDateComponents {
        let month: Int
        let day: Int
        let hour: Int?
        let minute: Int?
        let second: Int?
    }

    private static func parseDateComponents(
        from query: String,
        timeZone: TimeZone
    ) -> ParsedDateComponents? {
        let fallbackFormats = [
            "d MMMM yyyy", "d MMM yyyy", "MMMM d yyyy", "MMM d yyyy",
            "d MMMM", "d MMM", "MMMM d", "MMM d",
            "d/M/yyyy HH:mm:ss", "d/M/yyyy HH:mm", "d/M/yyyy h:mm a", "d/M/yyyy",
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd h:mm a", "yyyy-MM-dd",
            "d-M-yyyy HH:mm", "d-M-yyyy", "d.M.yyyy", "yyyy/MM/dd", "M/d/yyyy", "M/d",
            "d MMMM HH:mm", "d MMM HH:mm", "MMMM d HH:mm", "MMM d HH:mm",
            "d MMMM h:mm a", "d MMM h:mm a", "MMMM d h:mm a", "MMM d h:mm a",
            "d MMMM ha", "d MMM ha", "MMMM d ha", "MMM d ha"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var parsedDate: Date?
        for format in fallbackFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: query) {
                parsedDate = date
                break
            }
        }

        if parsedDate == nil,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(query.startIndex..., in: query)
            parsedDate = detector.matches(in: query, range: range).first?.date
        }

        guard let date = parsedDate else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comp = cal.dateComponents([.month, .day, .hour, .minute, .second], from: date)
        guard let month = comp.month, let day = comp.day else { return nil }

        let hasExplicitTime = query.range(
            of: #"(?:\b\d{1,2}:\d{2}\b|\b(?:am|pm)\b|\b\d{1,2}(?:am|pm)\b)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil

        if hasExplicitTime {
            return ParsedDateComponents(month: month, day: day, hour: comp.hour, minute: comp.minute, second: comp.second)
        } else {
            return ParsedDateComponents(month: month, day: day, hour: nil, minute: nil, second: nil)
        }
    }

    private static func parseYearWithDate(
        lower: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        let pattern = #"^(?:(next|last|this)\s+year\s+(.+)|(.+?)\s+(next|last|this)\s+year)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower))
        else { return nil }

        let modStr: String
        let datePart: String
        if match.range(at: 1).location != NSNotFound,
           let modRange = Range(match.range(at: 1), in: lower),
           let partRange = Range(match.range(at: 2), in: lower) {
            modStr = String(lower[modRange]).lowercased()
            datePart = String(lower[partRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if match.range(at: 3).location != NSNotFound,
                  let partRange = Range(match.range(at: 3), in: lower),
                  let modRange = Range(match.range(at: 4), in: lower) {
            modStr = String(lower[modRange]).lowercased()
            datePart = String(lower[partRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }

        let yearOffset: Int
        switch modStr {
        case "next": yearOffset = 1
        case "last": yearOffset = -1
        default: yearOffset = 0
        }

        guard let parsed = parseDateComponents(from: datePart, timeZone: timeZone) else { return nil }
        let currentYear = calendar.component(.year, from: now)
        var comp = DateComponents()
        comp.year = currentYear + yearOffset
        comp.month = parsed.month
        comp.day = parsed.day
        comp.hour = parsed.hour ?? 12
        comp.minute = parsed.minute ?? 0
        comp.second = parsed.second ?? 0
        comp.timeZone = timeZone
        return calendar.date(from: comp)
    }

    private static func parseWeekdayWithTime(
        lower: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        let prefixPattern = #"^(?:(next|this|last)\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\s+(.+)$"#
        if let regex = try? NSRegularExpression(pattern: prefixPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let dayRange = Range(match.range(at: 2), in: lower),
           let timeRange = Range(match.range(at: 3), in: lower) {
            let modifier = match.range(at: 1).location != NSNotFound
                ? Range(match.range(at: 1), in: lower).map { String(lower[$0]) }
                : nil
            let weekdayName = String(lower[dayRange])
            let weekdayQuery = modifier.map { "\($0) \(weekdayName)" } ?? weekdayName
            let timeStr = String(lower[timeRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard let weekdayDate = parseWeekday(lower: weekdayQuery, now: now, calendar: calendar, timeZone: timeZone),
                  let time = extractTimeOfDay(from: timeStr)
            else { return nil }

            var comp = calendar.dateComponents(in: timeZone, from: weekdayDate)
            comp.hour = time.hour
            comp.minute = time.minute
            comp.second = time.second
            return calendar.date(from: comp)
        }

        let suffixPattern = #"^(.+?)\s+(?:on\s+)?(?:(next|this|last)\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)$"#
        if let regex = try? NSRegularExpression(pattern: suffixPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let timeRange = Range(match.range(at: 1), in: lower),
           let dayRange = Range(match.range(at: 3), in: lower) {
            let modifier = match.range(at: 2).location != NSNotFound
                ? Range(match.range(at: 2), in: lower).map { String(lower[$0]) }
                : nil
            let weekdayName = String(lower[dayRange])
            let weekdayQuery = modifier.map { "\($0) \(weekdayName)" } ?? weekdayName
            let timeStr = String(lower[timeRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard let weekdayDate = parseWeekday(lower: weekdayQuery, now: now, calendar: calendar, timeZone: timeZone),
                  let time = extractTimeOfDay(from: timeStr)
            else { return nil }

            var comp = calendar.dateComponents(in: timeZone, from: weekdayDate)
            comp.hour = time.hour
            comp.minute = time.minute
            comp.second = time.second
            return calendar.date(from: comp)
        }

        return nil
    }

    private static func parseRelativeDayOffsetWithTime(
        lower: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        let pattern = #"^in\s+(\d+)\s+days?\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let daysRange = Range(match.range(at: 1), in: lower),
              let days = Int(lower[daysRange]),
              let timeRange = Range(match.range(at: 2), in: lower),
              let time = extractTimeOfDay(from: String(lower[timeRange]))
        else { return nil }

        guard let baseDate = calendar.date(byAdding: .day, value: days, to: now) else { return nil }
        var comp = calendar.dateComponents(in: timeZone, from: baseDate)
        comp.hour = time.hour
        comp.minute = time.minute
        comp.second = time.second
        return calendar.date(from: comp)
    }

    private static func parseRelative(
        query: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = parseNamedRelative(lower: lower, now: now, calendar: calendar, timeZone: timeZone) {
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

    private static let namedRelativeDayOffsets: [String: Int] = [
        "today": 0,
        "tomorrow": 1,
        "yesterday": -1,
        "day after tomorrow": 2,
        "day before yesterday": -2,
        "next day": 1,
        "last day": -1,
        "next week": 7,
        "last week": -7,
        "this week": 0
    ]

    private static let namedRelativeMonthOffsets: [String: Int] = [
        "next month": 1,
        "last month": -1,
        "this month": 0
    ]

    private static let namedRelativeYearOffsets: [String: Int] = [
        "next year": 1,
        "last year": -1,
        "this year": 0
    ]

    private static func parseNamedRelative(
        lower: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        var target: Date?
        if let days = namedRelativeDayOffsets[lower] {
            target = days == 0 ? now : calendar.date(byAdding: .day, value: days, to: now)
        } else if let months = namedRelativeMonthOffsets[lower] {
            target = months == 0 ? now : calendar.date(byAdding: .month, value: months, to: now)
        } else if let years = namedRelativeYearOffsets[lower] {
            target = years == 0 ? now : calendar.date(byAdding: .year, value: years, to: now)
        }

        guard let resolved = target else { return nil }
        var comp = calendar.dateComponents(in: timeZone, from: resolved)
        comp.hour = 12
        comp.minute = 0
        comp.second = 0
        return calendar.date(from: comp) ?? resolved
    }

    private static func parseRelativeOffset(
        lower: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let inPattern = #"^in\s+(?:(\d+)|(a|an))\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks|mo|month|months|y|yr|yrs|year|years)?$"#
        let agoPattern = #"^(?:(\d+)|(a|an))\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks|mo|month|months|y|yr|yrs|year|years)?\s+ago$"#

        if let regex = try? NSRegularExpression(pattern: inPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            let val = match.range(at: 1).location != NSNotFound
                ? (Range(match.range(at: 1), in: lower).flatMap { Int(lower[$0]) } ?? 1)
                : 1
            let unit = match.range(at: 3).location != NSNotFound
                ? Range(match.range(at: 3), in: lower).map { String(lower[$0]) } ?? "m"
                : "m"
            return resolveOffset(value: val, unit: unit, sign: 1, now: now, calendar: calendar)
        }

        if let regex = try? NSRegularExpression(pattern: agoPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            let val = match.range(at: 1).location != NSNotFound
                ? (Range(match.range(at: 1), in: lower).flatMap { Int(lower[$0]) } ?? 1)
                : 1
            let unit = match.range(at: 3).location != NSNotFound
                ? Range(match.range(at: 3), in: lower).map { String(lower[$0]) } ?? "m"
                : "m"
            return resolveOffset(value: val, unit: unit, sign: -1, now: now, calendar: calendar)
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
        let lower = query.lowercased()
        if lower.starts(with: "in ") || lower.hasSuffix(" ago")
            || lower.contains("yesterday") || lower.contains("tomorrow") || lower.contains("today")
            || lower.contains("next") || lower.contains("last") {
            return []
        }

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
            parsedDateMatches(detector: detector, query: query, range: range, outDate: &baseDate)
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

    private static func parsedDateMatches(
        detector: NSDataDetector,
        query: String,
        range: NSRange,
        outDate: inout Date?
    ) {
        let matches = detector.matches(in: query, range: range)
        outDate = matches.first?.date
    }
}
