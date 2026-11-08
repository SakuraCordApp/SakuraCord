import Foundation
@testable import MessageRendering
import Testing

/// A misread `@time` query sends a timestamp for the wrong moment. Expected
/// readings follow what Discord offered for the same phrases on Sunday
/// 8 November 2026 in Berlin, shifted to 05:10:13.
private let discordReadings: [(String, [String])] = [
    ("5pm", ["timeOnly 2026-11-08 17:00", "today 2026-11-08 17:00"]),
    ("5", ["timeOnly 2026-11-08 05:00", "tomorrow 2026-11-09 05:00", "today 2026-11-08 05:00"]),
    ("midnight", ["timeOnly 2026-11-09 00:00", "- 2026-11-09 00:00"]),
    ("tomorrow 5pm", ["- 2026-11-09 17:00"]),
    ("tomorrow", ["- 2026-11-09 05:15"]),
    ("last month", ["- 2026-10-08 06:15"]),
    ("in 1 day 2 hours", ["- 2026-11-09 07:10:13"]),
    ("jan 1", ["- 2027-01-01 12:00"]),
    ("5pm pdt", ["timeOnly 2026-11-09 01:00", "- 2026-11-09 01:00"]),
    ("tues", []),
    ("in 2 hours", ["- 2026-11-08 07:10:13"]),
    ("in 3 days at 5pm", ["- 2026-11-11 17:00"]),
    ("friday", ["thisWeek 2026-11-13 12:00", "lastWeek 2026-11-06 12:00"]),
    ("next sunday", ["- 2026-11-15 12:00"]),
    ("last sunday", ["thisWeek 2026-11-08 12:00", "lastWeek 2026-11-01 12:00"]),
    ("last sunday 00:00", ["thisWeek 2026-11-08 00:00", "lastWeek 2026-11-01 00:00"]),
    ("dec 25 midnight", ["thisYear 2026-12-26 00:00"]),
    ("dec 25 5pm", ["thisYear 2026-12-25 17:00"]),
    ("24 october 5pm", ["nextYear 2027-10-24 17:00", "thisYear 2026-10-24 17:00"]),
    ("3/4", ["- 2027-03-04 12:00"]),
    ("31/12", ["thisYear 2026-12-31 12:00"]),
    ("5pm est", ["timeOnly 2026-11-08 23:00", "today 2026-11-08 23:00"]),
    ("in 5", []),
    ("13pm", []),
    ("2/30", []),
    ("in 2000000000000000000 weeks", []),
    ("in 299999 years", []),
    ("5pm utc+-999999999999999999999", []),
    ("dec 25 9999999999", []),
]

/// The same moment for an account whose weeks start on Monday.
private let mondayWeekReadings: [(String, [String])] = [
    ("friday", ["nextWeek 2026-11-13 12:00", "thisWeek 2026-11-06 12:00"]),
    ("sunday", ["thisWeek 2026-11-08 12:00"]),
    ("monday", ["- 2026-11-09 12:00"]),
    ("thursday", ["nextWeek 2026-11-12 12:00", "thisWeek 2026-11-05 12:00"]),
    ("last mon", ["nextWeek 2026-11-09 12:00", "thisWeek 2026-11-02 12:00"]),
]

@Test(arguments: discordReadings)
func `time queries read as Discord reads them`(query: String, expected: [String]) throws {
    #expect(try readings(of: query, firstWeekday: 1) == expected)
}

@Test(arguments: mondayWeekReadings)
func `weekday labels follow the account's first weekday`(query: String, expected: [String]) throws {
    #expect(try readings(of: query, firstWeekday: 2) == expected)
}

private func readings(of query: String, firstWeekday: Int) throws -> [String] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = firstWeekday
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-08T04:10:13Z"))
    let format = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day().dateSeparator(.dash)
        .time(includingFractionalSeconds: false).timeSeparator(.colon)
    return DiscordNaturalLanguageTimeParser.suggestions(for: query, now: now, calendar: calendar).map { suggestion in
        var time = format.format(suggestion.date).replacingOccurrences(of: "T", with: " ")
        if time.hasSuffix(":00") { time.removeLast(3) }
        return "\(suggestion.reading.map { "\($0)" } ?? "-") \(time)"
    }
}

/// A relative timestamp that counts months differently from Discord shows
/// readers a different span than the sender saw.
@Test(arguments: [
    ("2026-02-01T12:00:00Z", "2026-03-17T12:00:00Z", "in 2 months"),
    ("2026-02-28T12:00:00Z", "2026-01-31T12:00:00Z", "1 month ago"),
    ("2026-11-08T05:10:13Z", "2026-11-08T06:00:13Z", "in 50 minutes"),
    ("2026-11-08T00:00:00Z", "2028-05-08T00:00:00Z", "in 2 years"),
])
func relativeTimestamps(now: String, date: String, expected: String) throws {
    let parse = { (text: String) in try #require(ISO8601DateFormatter().date(from: text)) }
    let text = DiscordTimestampFormatter.string(
        for: try parse(date), style: .relative, relativeTo: try parse(now),
        locale: Locale(identifier: "en_US"), timeZone: .gmt
    )
    #expect(text == expected)
}
