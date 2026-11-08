import Foundation
@testable import MessageRendering
import Testing

/// A misread `@time` query sends a timestamp for the wrong moment. Expected
/// readings were recorded from Discord on Sunday 8 November 2026, 05:10:13
/// Berlin time.
private let discordReadings: [(String, [String])] = [
    ("5pm", ["timeOnly 2026-11-08 17:00", "today 2026-11-08 17:00"]),
    ("5", ["timeOnly 2026-11-08 05:00", "tomorrow 2026-11-09 05:00", "today 2026-11-08 05:00"]),
    ("midnight", ["timeOnly 2026-11-09 00:00", "- 2026-11-09 00:00"]),
    ("tomorrow 5pm", ["- 2026-11-09 17:00"]),
    ("tomorrow", ["- 2026-11-09 05:10"]),
    ("in 2 hours", ["- 2026-11-08 07:10:13"]),
    ("in 3 days at 5pm", ["- 2026-11-11 17:00"]),
    ("friday", ["thisWeek 2026-11-13 12:00", "lastWeek 2026-11-06 12:00"]),
    ("next sunday", ["- 2026-11-15 12:00"]),
    ("dec 25 5pm", ["thisYear 2026-12-25 17:00"]),
    ("24 october 5pm", ["nextYear 2027-10-24 17:00", "thisYear 2026-10-24 17:00"]),
    ("3/4", ["- 2027-03-04 12:00"]),
    ("31/12", ["thisYear 2026-12-31 12:00"]),
    ("5pm est", ["timeOnly 2026-11-08 23:00", "today 2026-11-08 23:00"]),
    ("in 5", []),
    ("13pm", []),
    ("2/30", []),
    ("in 2000000000000000000 weeks", []),
]

@Test(arguments: discordReadings)
func `time queries read as Discord reads them`(query: String, expected: [String]) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-08T04:10:13Z"))
    let format = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day().dateSeparator(.dash)
        .time(includingFractionalSeconds: false).timeSeparator(.colon)
    let readings = DiscordNaturalLanguageTimeParser.suggestions(for: query, now: now, calendar: calendar).map { suggestion in
        var time = format.format(suggestion.date).replacingOccurrences(of: "T", with: " ")
        if time.hasSuffix(":00") { time.removeLast(3) }
        return "\(suggestion.reading.map { "\($0)" } ?? "-") \(time)"
    }
    #expect(readings == expected)
}
