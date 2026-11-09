import Foundation

/// One date the `@time` menu offers, with the formats Discord lists for it.
public struct DiscordTimeSuggestion: Equatable, Sendable {
    /// Why a query has more than one reading, shown beside its first format.
    public enum Reading: Equatable, Sendable {
        case timeOnly, today, tomorrow, thisWeek, nextWeek, lastWeek, thisYear, nextYear
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
        var readings: [DiscordTimeSuggestion]?
        // `5pm est` is that wall time in that zone, on the local day.
        if words.count > 1, let hours = words.last.flatMap(zoneOffset),
           let zone = TimeZone(secondsFromGMT: Int(hours * 3_600)) {
            var zoned = parser
            zoned.wallTimeZone = zone
            readings = zoned.dated(Array(words.dropLast()))
        }
        readings = readings ?? parser.relative(words) ?? parser.period(words) ?? parser.dated(words)
        // JavaScript dates, and so Discord timestamps, end 8.64e12 seconds
        // either side of 1970.
        guard let readings, readings.allSatisfy({ abs($0.date.timeIntervalSince1970) <= 8.64e12 }) else { return [] }
        return readings
    }

    /// Every number a phrase may contain: ASCII digits, at most one decimal
    /// point, and at most `digits` digits before it, so no amount, year or
    /// offset can overflow later arithmetic.
    static func number(_ text: some StringProtocol, digits: Int, fraction: Bool = false) -> Double? {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, (1 ... digits).contains(whole.count),
              parts.count == 1 || (fraction && !parts[1].isEmpty && parts[1].count <= 6),
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        return Double(text)
    }

    /// `est`, `gmt+2`, `utc-5:30`. Abbreviations name fixed offsets, so
    /// `5pm est` is UTC−5 in summer too.
    private static func zoneOffset(_ word: String) -> Double? {
        if let hours = zoneOffsets[word] { return hours }
        guard word.hasPrefix("gmt") || word.hasPrefix("utc"), let sign = word.dropFirst(3).first, "+-".contains(sign)
        else { return nil }
        let parts = word.dropFirst(4).split(separator: ":", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count), let hours = number(parts[0], digits: 2), hours <= 14,
              let minutes = parts.count == 2 ? number(parts[1], digits: 2) : 0, minutes < 60
        else { return nil }
        return (sign == "-" ? -1 : 1) * (hours + minutes / 60)
    }

    private static let zoneOffsets: [String: Double] = [
        "utc": 0, "gmt": 0, "wet": 0, "west": 1, "bst": 1, "cet": 1, "cest": 2, "eet": 2, "eest": 3,
        "msk": 3, "ist": 5.5, "sgt": 8, "hkt": 8, "jst": 9, "kst": 9, "aest": 10, "aedt": 11, "nzst": 12, "nzdt": 13,
        "hst": -10, "akst": -9, "akdt": -8, "pst": -8, "pdt": -7, "mst": -7, "mdt": -6,
        "cst": -6, "cdt": -5, "est": -5, "edt": -4, "ast": -4, "adt": -3, "nst": -3.5, "ndt": -2.5,
    ]

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
    /// The zone of a wall time typed with a zone suffix, on the local day.
    var wallTimeZone: TimeZone?

    /// `in 2 hours`, `in 30m`, `in half an hour`, `in 1 day 2 hours`,
    /// `2 days ago`, `in 3 days at 5pm`. Whole days and longer keep the
    /// clock rounded to the quarter hour; anything finer is exact.
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
        words = words.flatMap(Self.splitAmount)
        var calendarOffset = DateComponents(year: 0, month: 0, day: 0)
        var seconds = 0.0
        var index = 0
        while index + 1 < words.count {
            var amount = ["a": 1, "an": 1][words[index]]
                ?? DiscordNaturalLanguageTimeParser.number(words[index], digits: 7, fraction: true)
            if words[index] == "half", ["a", "an"].contains(words[index + 1]) {
                amount = 0.5
                index += 1
            }
            guard let amount, index + 1 < words.count,
                  let unit = Self.units[words[index + 1]]
            else { break }
            switch unit {
            case .second, .minute, .hour:
                seconds += amount * (unit == .second ? 1 : unit == .minute ? 60 : 3_600)
            case .day, .weekOfYear:
                let days = amount * (unit == .day ? 1 : 7)
                if days == days.rounded() { calendarOffset.day! += Int(days) } else { seconds += days * 86_400 }
            default:
                guard amount == amount.rounded() else { return nil }
                calendarOffset.setValue(calendarOffset.value(for: unit)! + Int(amount), for: unit)
            }
            index += 2
        }
        guard index > 0 else { return nil }
        let rest = Array(words[index...])
        let time = rest.isEmpty ? nil : Self.time(rest.drop { $0 == "at" }.joined())
        guard rest.isEmpty || time != nil, time == nil || seconds == 0 else { return nil }
        for component in [Calendar.Component.year, .month, .day] {
            calendarOffset.setValue(calendarOffset.value(for: component)! * Int(sign), for: component)
        }
        let date = Self.utc.date(byAdding: calendarOffset, to: seconds == 0 ? quarterHour(now) : now)
            .map { $0.addingTimeInterval(sign * seconds) }
        return date.flatMap { at(time, on: $0) }.map(Self.single)
    }

    /// `next week`, `last month`, `next year`; `this month` and `this year`
    /// are their first day at noon, and `this week` is noon, as Discord reads them.
    func period(_ words: [String]) -> [DiscordTimeSuggestion]? {
        guard words.count == 2,
              let unit = ["week": Calendar.Component.weekOfYear, "month": .month, "year": .year][words[1]]
        else { return nil }
        switch words[0] {
        case "next", "last":
            let date = Self.utc.date(byAdding: unit, value: words[0] == "next" ? 1 : -1, to: quarterHour(now))
            return date.map(Self.single)
        case "this":
            guard unit != .weekOfYear else { return timeOfDay(Self.noon) }
            return calendar.dateInterval(of: unit, for: now).flatMap { at(Self.noon, on: $0.start) }
                .map(Self.single)
        default:
            return nil
        }
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
        if words == ["tonight"] {
            return at(time ?? TimeOfDay(hour: 22, minute: 0), on: now).map(Self.single)
        }
        if words == ["this", "weekend"] || words == ["weekend"] {
            return weekday(["this", "saturday"], time: time ?? Self.noon)
        }
        if let offset = ["today": 0, "tomorrow": 1, "yesterday": -1][words.joined(separator: " ")] {
            let day = time == nil
                ? Self.utc.date(byAdding: .day, value: offset, to: quarterHour(now))
                : calendar.date(byAdding: .day, value: offset, to: now)
            return day.flatMap { at(time, on: $0) }.map(Self.single)
        }
        return weekday(words, time: time ?? Self.noon) ?? monthDay(words, time: time ?? Self.noon)
    }

    /// Discord offers the time alone, then its next occurrence and, once
    /// passed, today's.
    private func timeOfDay(_ time: TimeOfDay) -> [DiscordTimeSuggestion]? {
        guard let today = at(time, on: now) else { return nil }
        let timeOnly = DiscordTimeSuggestion(date: today, reading: .timeOnly, styles: [.shortTime])
        guard today < now, let tomorrow = calendar.date(byAdding: .day, value: 1, to: now).flatMap({ at(time, on: $0) }) else {
            return [timeOnly] + labelled([today], in: .day)
        }
        return [timeOnly] + labelled([tomorrow, today], in: .day)
    }

    /// `friday` reads as the coming one, and also the previous one when that
    /// is nearer; `next friday` is the coming one, a week out when that is
    /// today.
    private func weekday(_ words: [String], time: TimeOfDay) -> [DiscordTimeSuggestion]? {
        var words = words
        let modifier = ["this", "next", "last"].contains(words.first) ? words.removeFirst() : nil
        guard words.count == 1, let weekday = Self.weekdays[words[0]] else { return nil }
        let ahead = (weekday - calendar.component(.weekday, from: now) + 7) % 7
        let coming = modifier == "next" && ahead == 0 ? 7 : ahead
        // The previous one is offered too when it is the nearer.
        let offersPrevious = modifier == "last" || (modifier == nil && 7 - ahead < ahead)
        let offsets = offersPrevious ? [coming, ahead == 0 ? -7 : ahead - 7] : [coming]
        // Pick the day first: a zoned time keeps its offset across a DST change here.
        let dates = offsets.compactMap { calendar.date(byAdding: .day, value: $0, to: now).flatMap { at(time, on: $0) } }
        return dates.count == offsets.count ? labelled(dates, in: .weekOfYear) : nil
    }

    /// Discord names each reading's day, week or year relative to now;
    /// a lone reading is named only when it is the current one.
    private func labelled(_ dates: [Date], in period: Calendar.Component) -> [DiscordTimeSuggestion] {
        dates.map { date in
            let offset = calendar.dateInterval(of: period, for: now).flatMap { current in
                calendar.dateInterval(of: period, for: date).flatMap {
                    calendar.dateComponents([period], from: current.start, to: $0.start).value(for: period)
                }
            }
            let reading: DiscordTimeSuggestion.Reading? = switch (period, offset) {
            case (.day, 0): .today
            case (.day, 1): .tomorrow
            case (.weekOfYear, 0): .thisWeek
            case (.weekOfYear, 1): .nextWeek
            case (.weekOfYear, -1): .lastWeek
            case (.year, 0): .thisYear
            case (.year, 1): .nextYear
            default: nil
            }
            let isCurrent = offset == 0
            return DiscordNaturalLanguageTimeParser.moment(date, reading: dates.count > 1 || isCurrent ? reading : nil)
        }
    }

    /// `dec 25`, `25th dec`, `3/4`, `12/25/2026`, `2026-12-31`, `december
    /// 2026`. A date already past this year reads as next year's, and also
    /// this year's when that is the nearer.
    private func monthDay(_ words: [String], time: TimeOfDay) -> [DiscordTimeSuggestion]? {
        guard let parsed = words.count == 1 ? Self.numericDate(words[0]) : Self.writtenDate(words),
              let month = parsed.month, let day = parsed.day
        else { return nil }
        func date(in year: Int) -> Date? {
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.day, from: date) == day, calendar.component(.month, from: date) == month
            else { return nil }
            return at(time, on: date)
        }
        if let year = parsed.year { return date(in: year).map(Self.single) }
        let currentYear = calendar.component(.year, from: now)
        guard let thisYear = date(in: currentYear) else { return nil }
        if thisYear >= now { return labelled([thisYear], in: .year) }
        guard let nextYear = date(in: currentYear + 1) else { return nil }
        let offersThisYear = now.timeIntervalSince(thisYear) < nextYear.timeIntervalSince(now)
        return labelled(offersThisYear ? [nextYear, thisYear] : [nextYear], in: .year)
    }

    /// `3/4` is March 4, `31/12` December 31, `2026-12-31` year first.
    private static func numericDate(_ word: String) -> DateComponents? {
        let parts = word.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." })
            .map { DiscordNaturalLanguageTimeParser.number($0, digits: 6).map(Int.init) }
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
            } else if let number = DiscordNaturalLanguageTimeParser
                .number(word.trimmingCharacters(in: CharacterSet(charactersIn: "stndrh")), digits: 6).map(Int.init) {
                if day == nil, number <= 31 { day = number } else if year == nil, number > 999 { year = number } else { return nil }
            } else {
                return nil
            }
        }
        guard month != nil, day != nil || year != nil else { return nil }
        return DateComponents(year: year, month: month, day: day ?? 1)
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
        // `1.30pm` takes a dot only with a meridiem; `1.30` is a date.
        let parts = digits.split(separator: meridiem == nil ? ":" : (digits.contains(".") ? "." : ":"), omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts[0].count <= 2, parts.count == 1 || parts[1].count == 2,
              var hour = Int(parts[0]), let minute = parts.count == 2 ? Int(parts[1]) : 0, minute < 60
        else { return nil }
        if let meridiem {
            guard (meridiem.hasPrefix("p") ? 1 : 0) ... 12 ~= hour else { return nil }
            hour = hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0)
        } else {
            guard hour < 24 || (hour == 24 && minute == 0) else { return nil }
        }
        return TimeOfDay(hour: hour, minute: minute)
    }

    /// `time` on `day`, or `day` itself without one. Hour 24 is the next
    /// midnight.
    /// One unlabelled reading.
    private static func single(_ date: Date) -> [DiscordTimeSuggestion] {
        [DiscordNaturalLanguageTimeParser.moment(date)]
    }

    private func at(_ time: TimeOfDay?, on day: Date) -> Date? {
        guard let time else { return day }
        var wallCalendar = calendar
        wallCalendar.timeZone = wallTimeZone ?? calendar.timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour % 24
        components.minute = time.minute
        guard let date = wallCalendar.date(from: components) else { return nil }
        return time.hour == 24 ? wallCalendar.date(byAdding: .day, value: 1, to: date) : date
    }

    /// Discord moves whole-day phrases to the nearest quarter hour.
    private func quarterHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 900).rounded() * 900)
    }

    /// `30m` and `2h` are an amount and a unit.
    private static func splitAmount(_ word: String) -> [String] {
        guard let split = word.firstIndex(where: \.isLetter), split != word.startIndex,
              DiscordNaturalLanguageTimeParser.number(word[..<split], digits: 7, fraction: true) != nil
        else { return [word] }
        return [String(word[..<split]), String(word[split...])]
    }

    /// Discord adds days, months and years to the instant, not the wall clock.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private static let noon = TimeOfDay(hour: 12, minute: 0)
    private static let months = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]
    private static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3,
        "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5,
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
