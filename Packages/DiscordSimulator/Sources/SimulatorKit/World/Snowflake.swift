import Foundation

/// Discord IDs: milliseconds since the Discord epoch in the top 42 bits,
/// then worker, process and an increment.
public struct Snowflake: Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let discordEpochMilliseconds: Int64 = 1_420_070_400_000

    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public init?(_ text: String) {
        guard let value = UInt64(text) else { return nil }
        rawValue = value
    }

    public init(date: Date, increment: UInt64) {
        let milliseconds = UInt64(max(0, Int64(date.timeIntervalSince1970 * 1000) - Self.discordEpochMilliseconds))
        rawValue = (milliseconds << 22) | (1 << 17) | (increment & 0xFFF)
    }

    public var date: Date {
        Date(timeIntervalSince1970: Double(Int64(rawValue >> 22) + Self.discordEpochMilliseconds) / 1000)
    }

    public var description: String { String(rawValue) }
    public var json: JSON { .string(description) }

    public static func < (lhs: Snowflake, rhs: Snowflake) -> Bool { lhs.rawValue < rhs.rawValue }

    /// A Discord ID, or a dcap alias (`id_123`) standing in for one in captures.
    public static func looksLike(_ text: String) -> Bool {
        if text.hasPrefix("id_") { return text.count > 3 && text.dropFirst(3).allSatisfy(\.isASCIIDigit) }
        return (15 ... 21).contains(text.count) && text.allSatisfy(\.isASCIIDigit)
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
