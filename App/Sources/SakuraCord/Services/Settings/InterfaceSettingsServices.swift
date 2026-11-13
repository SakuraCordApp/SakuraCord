import Foundation
import Observation
import Synchronization

nonisolated enum InterfaceTypographyMetrics {
    static let defaultMessageTextSize: CGFloat = 15
    static let messageTextSizeRange: ClosedRange<CGFloat> = 12 ... 24
    static let interfaceTextSize: CGFloat = 13

    /// The Message Font Size preference, before Interface Size scaling.
    static var messageTextSize: CGFloat { MessageTextSize.shared.value }

    static func updateMessageTextSize(_ value: CGFloat) {
        MessageTextSize.shared.update(normalizedMessageTextSize(value))
    }

    static func normalizedMessageTextSize(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultMessageTextSize }
        return min(max(value.rounded(), messageTextSizeRange.lowerBound), messageTextSizeRange.upperBound)
    }

    /// Scales a message-content size designed for the default message text.
    /// Small text keeps 10 pt, unless it already started smaller.
    static func message(_ size: CGFloat) -> CGFloat {
        max(messageLength(size), min(size, 10))
    }

    /// Scales a length around message text, such as the composer's padding,
    /// in proportion to it.
    static func messageLength(_ value: CGFloat) -> CGFloat {
        value * messageTextSize / defaultMessageTextSize
    }
}

/// Reads are thread-safe for off-main timeline layout and are tracked by
/// Observation, so SwiftUI chrome sized from message text, such as the
/// composer, updates when the size changes.
private nonisolated final class MessageTextSize: Observable, Sendable {
    static let shared = MessageTextSize()

    private let registrar = ObservationRegistrar()
    private let storage = Mutex(InterfaceTypographyMetrics.defaultMessageTextSize)

    var value: CGFloat {
        registrar.access(self, keyPath: \.value)
        return storage.withLock { $0 }
    }

    func update(_ value: CGFloat) {
        guard storage.withLock({ $0 }) != value else { return }
        registrar.withMutation(of: self, keyPath: \.value) {
            storage.withLock { $0 = value }
        }
    }
}

nonisolated enum InterfaceTimestampFormat: String, CaseIterable, Identifiable, Sendable {
    case system
    case twelveHour
    case twentyFourHour

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .system: LocalizedStringResource("System", bundle: #bundle)
        case .twelveHour: LocalizedStringResource("12-hour", bundle: #bundle)
        case .twentyFourHour: LocalizedStringResource("24-hour", bundle: #bundle)
        }
    }
}

nonisolated struct InterfaceSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(timestampFormat: .system, includesTimestampSeconds: false)

    var timestampFormat: InterfaceTimestampFormat
    var includesTimestampSeconds: Bool
    var alwaysShowsTimestamps = false
}

nonisolated enum InterfaceTimestampFormatter {
    static func messageText(
        for date: Date,
        now: Date = .now,
        format: InterfaceTimestampFormat,
        includesSeconds: Bool,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let time = text(
            for: date,
            format: format,
            includesSeconds: includesSeconds,
            locale: locale,
            timeZone: timeZone,
            calendar: calendar
        )
        var calendar = calendar
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return String(localized: "Yesterday at \(time)", bundle: #bundle, locale: locale)
        }
        let fullDate = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ).day(.twoDigits).month(.twoDigits).year().format(date)
        return "\(fullDate), \(time)"
    }

    static func text(
        for date: Date,
        format: InterfaceTimestampFormat,
        includesSeconds: Bool,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        switch format {
        case .system:
            var style = Date.FormatStyle(
                date: .omitted,
                time: includesSeconds ? .standard : .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            )
            style.capitalizationContext = .unknown
            return style.format(date)
        case .twelveHour:
            return verbatim(
                date,
                clock: .twelveHour,
                includesSeconds: includesSeconds,
                locale: locale,
                timeZone: timeZone,
                calendar: calendar
            )
        case .twentyFourHour:
            return verbatim(
                date,
                clock: .twentyFourHour,
                includesSeconds: includesSeconds,
                locale: locale,
                timeZone: timeZone,
                calendar: calendar
            )
        }
    }

    private static func verbatim(
        _ date: Date,
        clock: Date.FormatStyle.Symbol.VerbatimHour.Clock,
        includesSeconds: Bool,
        locale: Locale,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> String {
        let hour: Date.FormatStyle.Symbol.VerbatimHour = .defaultDigits(
            clock: clock,
            hourCycle: clock == .twelveHour ? .oneBased : .zeroBased
        )
        let format: Date.FormatString
        if clock == .twelveHour {
            format = includesSeconds
                ? "\(hour: hour):\(minute: .twoDigits):\(second: .twoDigits) \(dayPeriod: .standard(.abbreviated))"
                : "\(hour: hour):\(minute: .twoDigits) \(dayPeriod: .standard(.abbreviated))"
        } else {
            format = includesSeconds
                ? "\(hour: hour):\(minute: .twoDigits):\(second: .twoDigits)"
                : "\(hour: hour):\(minute: .twoDigits)"
        }
        return Date.VerbatimFormatStyle(
            format: format,
            locale: locale,
            timeZone: timeZone,
            calendar: calendar
        ).format(date)
    }
}

@MainActor
final class InterfaceSettingsStore {
    static let shared = InterfaceSettingsStore()

    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> InterfaceSettingsSnapshot {
        var value = InterfaceSettingsSnapshot.defaults
        value.timestampFormat = enumValue(.timestampFormat) ?? value.timestampFormat
        value.includesTimestampSeconds = boolValue(.timestampSeconds)
            ?? value.includesTimestampSeconds
        value.alwaysShowsTimestamps = boolValue(.alwaysShowTimestamps) ?? false
        return value
    }

    func save(_ value: InterfaceSettingsSnapshot) {
        preferences.set(.string(value.timestampFormat.rawValue), for: .timestampFormat)
        preferences.set(.bool(value.includesTimestampSeconds), for: .timestampSeconds)
        preferences.set(.bool(value.alwaysShowsTimestamps), for: .alwaysShowTimestamps)
    }

    private func boolValue(_ id: SettingsControlID) -> Bool? {
        guard case let .bool(value) = preferences.value(for: id) else { return nil }
        return value
    }

    private func enumValue<Value: RawRepresentable>(
        _ id: SettingsControlID
    ) -> Value? where Value.RawValue == String {
        guard case let .string(value) = preferences.value(for: id) else { return nil }
        return Value(rawValue: value)
    }
}

@MainActor
extension AppModel {
    func applyInterfaceSettings(
        _ proposedValue: InterfaceSettingsSnapshot,
        persists: Bool = true
    ) {
        guard proposedValue != interfaceSettings else { return }
        interfaceSettings = proposedValue
        if persists {
            InterfaceSettingsStore.shared.save(proposedValue)
        }
        invalidateTimelinePresentation()
    }
}
