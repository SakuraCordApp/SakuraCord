import Foundation

nonisolated enum InterfaceTypographyMetrics {
    static let messageTextSize: CGFloat = 15
    static let interfaceTextSize: CGFloat = 13
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

nonisolated enum InterfaceMessageActionVisibility: String, CaseIterable, Identifiable, Sendable {
    case onHover
    case always

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .onHover: LocalizedStringResource("On hover", bundle: #bundle)
        case .always: LocalizedStringResource("Always visible", bundle: #bundle)
        }
    }
}

nonisolated struct InterfaceSettingsSnapshot: Equatable, Sendable {
    static let groupingIntervalRange = 1 ... 30

    static let defaults = Self(
        timestampFormat: .system,
        includesTimestampSeconds: false,
        groupingIntervalMinutes: 7,
        underlinesLinks: false,
        showsMemberList: true,
        showsActivityDetails: true,
        messageActionVisibility: .onHover,
        showsRoleColors: true
    )

    var timestampFormat: InterfaceTimestampFormat
    var includesTimestampSeconds: Bool
    var groupingIntervalMinutes: Int
    var underlinesLinks: Bool
    var showsMemberList: Bool
    var showsActivityDetails: Bool
    var messageActionVisibility: InterfaceMessageActionVisibility
    var showsRoleColors: Bool

    var groupingInterval: TimeInterval {
        TimeInterval(groupingIntervalMinutes * 60)
    }

    mutating func normalize() {
        groupingIntervalMinutes = groupingIntervalMinutes.clamped(
            to: Self.groupingIntervalRange
        )
    }
}

nonisolated enum InterfaceTimestampFormatter {
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
        value.groupingIntervalMinutes = integerValue(.groupingInterval)
            ?? value.groupingIntervalMinutes
        value.underlinesLinks = boolValue(.underlineLinks) ?? value.underlinesLinks
        value.showsMemberList = boolValue(.showMemberList) ?? value.showsMemberList
        value.showsActivityDetails = boolValue(.showActivityDetails)
            ?? value.showsActivityDetails
        value.messageActionVisibility = enumValue(.messageActionVisibility)
            ?? value.messageActionVisibility
        value.showsRoleColors = boolValue(.showRoleColors) ?? value.showsRoleColors
        value.normalize()
        return value
    }

    func save(_ value: InterfaceSettingsSnapshot) {
        preferences.set(.string(value.timestampFormat.rawValue), for: .timestampFormat)
        preferences.set(.bool(value.includesTimestampSeconds), for: .timestampSeconds)
        preferences.set(.integer(value.groupingIntervalMinutes), for: .groupingInterval)
        preferences.set(.bool(value.underlinesLinks), for: .underlineLinks)
        preferences.set(.bool(value.showsMemberList), for: .showMemberList)
        preferences.set(.bool(value.showsActivityDetails), for: .showActivityDetails)
        preferences.set(
            .string(value.messageActionVisibility.rawValue),
            for: .messageActionVisibility
        )
        preferences.set(.bool(value.showsRoleColors), for: .showRoleColors)
    }

    private func boolValue(_ id: SettingsControlID) -> Bool? {
        guard case let .bool(value) = preferences.value(for: id) else { return nil }
        return value
    }

    private func integerValue(_ id: SettingsControlID) -> Int? {
        guard case let .integer(value) = preferences.value(for: id) else { return nil }
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
        var value = proposedValue
        value.normalize()
        let previousValue = interfaceSettings
        let groupingChanged =
            value.groupingIntervalMinutes
                != previousValue.groupingIntervalMinutes
        let timelinePresentationChanged =
            value.timestampFormat != previousValue.timestampFormat
                || value.includesTimestampSeconds
                    != previousValue.includesTimestampSeconds
                || value.underlinesLinks != previousValue.underlinesLinks
                || value.showsRoleColors != previousValue.showsRoleColors
        let memberListChanged = value.showsMemberList != showInspector
        interfaceSettings = value
        if persists {
            InterfaceSettingsStore.shared.save(value)
        }
        if memberListChanged {
            showInspector = value.showsMemberList
        }
        if groupingChanged {
            messageRows = MessageGrouping.rows(
                for: messages,
                continuationInterval: value.groupingInterval
            )
            publishMessageRowsUpdate(invalidatesAllRows: true)
            threadMessageRows = MessageGrouping.rows(
                for: threadMessages,
                continuationInterval: value.groupingInterval
            )
            publishThreadMessageRowsPresentationUpdate(
                changedMessageIDs: Set(threadMessages.map(\.id))
            )
        }
        if timelinePresentationChanged {
            invalidateTimelinePresentation()
        }
    }
}

private nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
