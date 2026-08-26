import Foundation

nonisolated enum InterfaceMessageDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case balanced
    case compact

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .comfortable: LocalizedStringResource("Comfortable", bundle: #bundle)
        case .balanced: LocalizedStringResource("Balanced", bundle: #bundle)
        case .compact: LocalizedStringResource("Compact", bundle: #bundle)
        }
    }

    var avatarDiameter: CGFloat {
        switch self {
        case .comfortable: 38
        case .balanced: 34
        case .compact: 30
        }
    }

    var horizontalInset: CGFloat {
        switch self {
        case .comfortable: 14
        case .balanced: 12
        case .compact: 10
        }
    }

    var columnGap: CGFloat {
        switch self {
        case .comfortable: 12
        case .balanced: 10
        case .compact: 8
        }
    }

    var groupSeparation: CGFloat {
        switch self {
        case .comfortable: 12
        case .balanced: 8
        case .compact: 4
        }
    }

    var highlightInset: CGFloat {
        switch self {
        case .comfortable: 3
        case .balanced: 2
        case .compact: 1
        }
    }

    var authorToContentSpacing: CGFloat {
        switch self {
        case .comfortable: 4
        case .balanced: 2
        case .compact: 0
        }
    }

    var compactContentHeight: CGFloat {
        switch self {
        case .comfortable: 18
        case .balanced: 17
        case .compact: 16
        }
    }
}

nonisolated enum InterfaceSidebarDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .comfortable: LocalizedStringResource("Comfortable", bundle: #bundle)
        case .compact: LocalizedStringResource("Compact", bundle: #bundle)
        }
    }

    var minimumRowHeight: CGFloat {
        switch self {
        case .comfortable: 24
        case .compact: 19
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
    static let messageTextSizeRange = 12.0 ... 22.0
    static let interfaceTextSizeRange = 11.0 ... 18.0
    static let groupingIntervalRange = 1 ... 30

    static let defaults = Self(
        messageDensity: .comfortable,
        sidebarDensity: .comfortable,
        messageTextSize: 15,
        interfaceTextSize: 13,
        timestampFormat: .system,
        includesTimestampSeconds: false,
        groupingIntervalMinutes: 7,
        underlinesLinks: false,
        showsMemberList: true,
        showsActivityDetails: true,
        messageActionVisibility: .onHover,
        showsRoleColors: true
    )

    var messageDensity: InterfaceMessageDensity
    var sidebarDensity: InterfaceSidebarDensity
    var messageTextSize: Double
    var interfaceTextSize: Double
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
        messageTextSize = messageTextSize.clamped(to: Self.messageTextSizeRange)
        interfaceTextSize = interfaceTextSize.clamped(to: Self.interfaceTextSizeRange)
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
        value.messageDensity = enumValue(.messageDensity) ?? value.messageDensity
        value.sidebarDensity = enumValue(.sidebarDensity) ?? value.sidebarDensity
        value.messageTextSize = doubleValue(.messageTextSize) ?? value.messageTextSize
        value.interfaceTextSize = doubleValue(.interfaceTextSize) ?? value.interfaceTextSize
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
        preferences.set(.string(value.messageDensity.rawValue), for: .messageDensity)
        preferences.set(.string(value.sidebarDensity.rawValue), for: .sidebarDensity)
        preferences.set(.double(value.messageTextSize), for: .messageTextSize)
        preferences.set(.double(value.interfaceTextSize), for: .interfaceTextSize)
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

    private func doubleValue(_ id: SettingsControlID) -> Double? {
        guard case let .double(value) = preferences.value(for: id) else { return nil }
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
            value.messageDensity != previousValue.messageDensity
                || value.messageTextSize != previousValue.messageTextSize
                || value.timestampFormat != previousValue.timestampFormat
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
