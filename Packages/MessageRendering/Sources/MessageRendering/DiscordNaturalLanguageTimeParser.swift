import Foundation

/// One date the `@time` menu offers, with the formats Discord lists for it.
public struct DiscordTimeSuggestion: Equatable, Sendable {
    /// Why a query has more than one reading, shown beside its first format.
    public enum Reading: Equatable, Sendable {
        case timeOnly, today, tomorrow, thisWeek, lastWeek, thisYear, nextYear
    }

    public let date: Date
    public let reading: Reading?
    public let styles: [DiscordTimestampToken.Style]

    public func token(_ style: DiscordTimestampToken.Style) -> DiscordTimestampToken {
        DiscordTimestampToken(seconds: Int64(date.timeIntervalSince1970.rounded(.down)), style: style)
    }
}

/// Reads the English phrases Discord's `@time` accepts: times of day, day
/// words, weekdays, month days and dates, and `in N units` / `N units ago`.
/// Anything else has no reading, so the menu stays empty as Discord's does.
public enum DiscordNaturalLanguageTimeParser {
    public static func suggestions(
        for query: String, now: Date, calendar: Calendar = .autoupdatingCurrent
    ) -> [DiscordTimeSuggestion] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words != ["now"] else { return [moment(now)] }
        let parser = Parser(now: now, calendar: calendar)
        // `5pm est` is that wall time in that zone, on the local day.
        if words.count > 1, let abbreviation = words.last?.uppercased(),
           TimeZone.abbreviationDictionary[abbreviation] != nil, let zone = TimeZone(abbreviation: abbreviation) {
            var zoned = parser
            zoned.zoneShift = TimeInterval(calendar.timeZone.secondsFromGMT(for: now) - zone.secondsFromGMT(for: now))
            if let readings = zoned.dated(Array(words.dropLast())) { return readings }
        }
        return parser.relative(words) ?? parser.period(words) ?? parser.dated(words) ?? []
    }

    /// A precise instant keeps its seconds, which Discord shows in the
    /// first format; a resolved day or time does not.
    static func moment(_ date: Date, reading: DiscordTimeSuggestion.Reading? = nil) -> DiscordTimeSuggestion {
        let hasSeconds = Int(date.timeIntervalSince1970.rounded(.down)) % 60 != 0
        return DiscordTimeSuggestion(
            date: date,
            reading: reading,
            styles: [hasSeconds ? .shortDateMediumTime : .shortDateShortTime, .longDateShortTime, .fullDateShortTime, .relative]
        )
    }
}

private struct TimeOfDay {
    let hour: Int
    let minute: Int
}

private struct Parser {
    let now: Date
    let calendar: Calendar
    /// Moves a wall time typed with a zone suffix to that zone.
    var zoneShift: TimeInterval = 0

    /// `in 2 hours`, `in 2h`, `in a week`, `3 days ago`, `in 3 days at 5pm`.
    func relative(_ words: [String]) -> [DiscordTimeSuggestion]? {
        var words = words
        let sign: Double
        if words.first == "in" {
            sign = 1
            words.removeFirst()
        } else if words.last == "ago" {
            sign = -1
            words.removeLast()
        } else {
            return nil
        }
        if let glued = words.first, let split = glued.firstIndex(where: \.isLetter), split != glued.startIndex,
           Double(glued[..<split]) != nil {
            words.replaceSubrange(0 ..< 1, with: [String(glued[..<split]), String(glued[split...])])
        }
        guard words.count >= 2,
              let amount = ["a": 1, "an": 1][words[0]] ?? Double(words[0]), amount.isFinite, amount >= 0,
              let unit = Self.units[words[1]]
        else { return nil }
        let timeWords = Array(words.dropFirst(words.count > 2 && words[2] == "at" ? 3 : 2))
        let time = timeWords.isEmpty ? nil : Self.time(timeWords.joined())
        guard timeWords.isEmpty || time != nil else { return nil }
        let date: Date?
        switch unit {
        case .second, .minute, .hour:
            guard time == nil else { return nil }
            let seconds = sign * amount * (unit == .second ? 1 : unit == .minute ? 60 : 3_600)
            date = Self.instant(now.timeIntervalSince1970 + seconds)
        case .day, .weekOfYear:
            let days = sign * amount * (unit == .day ? 1 : 7)
            guard days == days.rounded(), abs(days) < 3_000_000 else { return nil }
            date = calendar.date(byAdding: .day, value: Int(days), to: minuteStart(now)).flatMap { at(time, on: $0) }
        default:
            guard time == nil, amount == amount.rounded(), amount < 300_000 else { return nil }
            date = calendar.date(byAdding: unit, value: Int(sign * amount), to: minuteStart(now))
        }
        return date.map { [DiscordNaturalLanguageTimeParser.moment($0)] }
    }

    /// `next week`, `last month`, `this year`.
    func period(_ words: [String]) -> [DiscordTimeSuggestion]? {
        guard words.count == 2, let offset = ["next": 1, "last": -1, "this": 0][words[0]],
              let unit = ["week": Calendar.Component.weekOfYear, "month": .month, "year": .year][words[1]],
              let date = calendar.date(byAdding: unit, value: offset, to: minuteStart(now))
        else { return nil }
        return [DiscordNaturalLanguageTimeParser.moment(date)]
    }

    /// A day phrase, weekday or date with an optional time, or a time alone.
    /// `oct 12` is a date before `12` is a time.
    func dated(_ words: [String]) -> [DiscordTimeSuggestion]? {
        for (rest, time) in [(words, nil)] + timeSplits(words) {
            if let suggestions = rest.isEmpty ? time.flatMap(timeOfDay) : day(rest, time: time) {
                return suggestions
            }
        }
        return nil
    }

    private func day(_ words: [String], time: TimeOfDay?) -> [DiscordTimeSuggestion]? {
        if words == ["tonight"], time == nil {
            return at(TimeOfDay(hour: 22, minute: 0), on: now).map { [DiscordNaturalLanguageTimeParser.moment($0)] }
        }
        if let offset = ["today": 0, "tomorrow": 1, "yesterday": -1][words.joined(separator: " ")] {
            let day = calendar.date(byAdding: .day, value: offset, to: minuteStart(now))
            return day.flatMap { at(time, on: $0) }.map { [DiscordNaturalLanguageTimeParser.moment($0)] }
        }
        return weekday(words, time: time ?? Self.noon) ?? monthDay(words, time: time ?? Self.noon)
    }

    /// Discord offers the time alone, then its next and, once passed, its
    /// earlier occurrence today.
    private func timeOfDay(_ time: TimeOfDay) -> [DiscordTimeSuggestion]? {
        guard let today = at(time, on: now) else { return nil }
        let timeOnly = DiscordTimeSuggestion(date: today, reading: .timeOnly, styles: [.shortTime])
        if time.hour == 24 {
            return [timeOnly, DiscordNaturalLanguageTimeParser.moment(today)]
        }
        guard today < now, let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return [timeOnly, DiscordNaturalLanguageTimeParser.moment(today, reading: .today)]
        }
        return [
            timeOnly,
            DiscordNaturalLanguageTimeParser.moment(tomorrow, reading: .tomorrow),
            DiscordNaturalLanguageTimeParser.moment(today, reading: .today),
        ]
    }

    /// `friday` reads as this week's and last week's; `next friday` names
    /// the coming one, a week out when that is today.
    private func weekday(_ words: [String], time: TimeOfDay) -> [DiscordTimeSuggestion]? {
        var words = words
        let modifier = ["this", "next", "last"].contains(words.first) ? words.removeFirst() : nil
        guard words.count == 1, let weekday = Self.weekdays[words[0]],
              let today = at(time, on: now)
        else { return nil }
        let ahead = (weekday - calendar.component(.weekday, from: now) + 7) % 7
        guard let coming = calendar.date(byAdding: .day, value: ahead, to: today) else { return nil }
        if modifier == "next", ahead == 0 {
            return calendar.date(byAdding: .day, value: 7, to: coming).map { [DiscordNaturalLanguageTimeParser.moment($0)] }
        }
        var readings = [DiscordNaturalLanguageTimeParser.moment(coming, reading: .thisWeek)]
        if modifier == "last" || (modifier == nil && ahead != 0),
           let previous = calendar.date(byAdding: .day, value: -7, to: coming) {
            readings.append(DiscordNaturalLanguageTimeParser.moment(previous, reading: .lastWeek))
        }
        return readings
    }

    /// `dec 25`, `25 december`, `november 8th`, `3/4`, `3/4/2026`,
    /// `2026-12-31`. A written date already past offers next year first.
    private func monthDay(_ words: [String], time: TimeOfDay) -> [DiscordTimeSuggestion]? {
        let isNumeric = words.count == 1
        guard let parsed = isNumeric ? Self.numericDate(words[0]) : Self.writtenDate(words.filter { $0 != "of" }),
              let month = parsed.month, let day = parsed.day
        else { return nil }
        let year = parsed.year
        let currentYear = calendar.component(.year, from: now)
        func date(in year: Int) -> Date? {
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.day, from: date) == day, calendar.component(.month, from: date) == month
            else { return nil }
            return at(time, on: date)
        }
        if let year { return date(in: year).map { [DiscordNaturalLanguageTimeParser.moment($0)] } }
        guard let thisYear = date(in: currentYear) else { return nil }
        if thisYear >= now { return [DiscordNaturalLanguageTimeParser.moment(thisYear, reading: .thisYear)] }
        guard let nextYear = date(in: currentYear + 1) else { return nil }
        if isNumeric { return [DiscordNaturalLanguageTimeParser.moment(nextYear)] }
        return [
            DiscordNaturalLanguageTimeParser.moment(nextYear, reading: .nextYear),
            DiscordNaturalLanguageTimeParser.moment(thisYear, reading: .thisYear),
        ]
    }

    /// `3/4` is March 4, `31/12` December 31, `2026-12-31` year first.
    private static func numericDate(_ word: String) -> DateComponents? {
        let parts = word.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." }).map { Int($0) }
        guard (2 ... 3).contains(parts.count), !parts.contains(nil) else { return nil }
        let numbers = parts.compactMap { $0 }
        if numbers[0] > 999 {
            return numbers.count == 3 ? DateComponents(year: numbers[0], month: numbers[1], day: numbers[2]) : nil
        }
        let (month, day) = numbers[0] > 12 ? (numbers[1], numbers[0]) : (numbers[0], numbers[1])
        return DateComponents(year: numbers.count == 3 ? numbers[2] : nil, month: month, day: day)
    }

    /// `dec 25`, `25 december 2027`, `november 8th`.
    private static func writtenDate(_ words: [String]) -> DateComponents? {
        var month: Int?
        var day: Int?
        var year: Int?
        for word in words {
            if let index = months.firstIndex(where: { word.count >= 3 && $0.hasPrefix(word) }) {
                guard month == nil else { return nil }
                month = index + 1
            } else if let number = Int(word.trimmingCharacters(in: CharacterSet(charactersIn: "stndrh"))) {
                if day == nil, number <= 31 { day = number } else if year == nil, number > 999 { year = number } else { return nil }
            } else {
                return nil
            }
        }
        return DateComponents(year: year, month: month, day: day)
    }

    /// Readings of a time of day at either end of the phrase: `5pm`, `5 pm`,
    /// `at 17:30`, `noon`, `midnight`.
    private func timeSplits(_ words: [String]) -> [([String], TimeOfDay?)] {
        var splits: [([String], TimeOfDay?)] = []
        for count in [2, 1] where words.count >= count {
            if let time = Self.time(words.suffix(count).joined()) {
                var rest = Array(words.dropLast(count))
                if rest.last == "at" { rest.removeLast() }
                splits.append((rest, time))
            }
            if words.count > count, let time = Self.time(words.prefix(count).joined()) {
                var rest = Array(words.dropFirst(count))
                if rest.first == "on" { rest.removeFirst() }
                splits.append((rest, time))
            }
        }
        if words.first == "at", let time = Self.time(words.dropFirst().joined()) { splits.append(([], time)) }
        return splits
    }

    private static func time(_ text: String) -> TimeOfDay? {
        if text == "noon" { return noon }
        if text == "midnight" { return TimeOfDay(hour: 24, minute: 0) }
        var digits = Substring(text)
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where digits.hasSuffix(suffix) {
            meridiem = suffix
            digits = digits.dropLast(suffix.count)
            break
        }
        let parts = digits.split(separator: ":", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts[0].count <= 2, parts.count == 1 || parts[1].count == 2,
              var hour = Int(parts[0]), let minute = parts.count == 2 ? Int(parts[1]) : 0, minute < 60
        else { return nil }
        if let meridiem {
            guard (1 ... 12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0)
        } else {
            guard hour < 24 || (hour == 24 && minute == 0) else { return nil }
        }
        return TimeOfDay(hour: hour, minute: minute)
    }

    /// `time` on `day`, or `day` itself without one. Hour 24 is the next
    /// midnight.
    private func at(_ time: TimeOfDay?, on day: Date) -> Date? {
        guard let time else { return day }
        let start = calendar.startOfDay(for: day)
        let date = time.hour == 24
            ? calendar.date(byAdding: .day, value: 1, to: start)
            : calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: start)
        return date?.addingTimeInterval(zoneShift)
    }

    private func minuteStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    /// JavaScript dates, and so Discord timestamps, end 8.64e12 seconds
    /// either side of 1970.
    private static func instant(_ seconds: Double) -> Date? {
        abs(seconds) <= 8.64e12 ? Date(timeIntervalSince1970: seconds) : nil
    }

    private static let noon = TimeOfDay(hour: 12, minute: 0)
    private static let months = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]
    private static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6, "saturday": 7, "sat": 7,
    ]
    private static let units: [String: Calendar.Component] = {
        var units: [String: Calendar.Component] = [:]
        for (names, unit) in [
            (["s", "sec", "secs", "second", "seconds"], Calendar.Component.second),
            (["m", "min", "mins", "minute", "minutes"], .minute),
            (["h", "hr", "hrs", "hour", "hours"], .hour),
            (["d", "day", "days"], .day),
            (["w", "wk", "wks", "week", "weeks"], .weekOfYear),
            (["mo", "month", "months"], .month),
            (["y", "yr", "yrs", "year", "years"], .year),
        ] {
            for name in names { units[name] = unit }
        }
        return units
    }()
}
