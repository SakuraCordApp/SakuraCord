import AppKit
import Foundation
import SakuraCordModels

nonisolated enum AppColorScheme: String, CaseIterable, Hashable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .system:
            LocalizedStringResource("System", bundle: #bundle)
        case .light:
            LocalizedStringResource("Light", bundle: #bundle)
        case .dark:
            LocalizedStringResource("Dark", bundle: #bundle)
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    func appearanceName(increasesContrast: Bool) -> NSAppearance.Name? {
        switch self {
        case .system:
            nil
        case .light:
            increasesContrast ? .accessibilityHighContrastAqua : .aqua
        case .dark:
            increasesContrast ? .accessibilityHighContrastDarkAqua : .darkAqua
        }
    }
}

@MainActor
final class AppAppearanceController: NSObject {
    static let shared = AppAppearanceController()

    private var selection = AppColorScheme.system

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    func apply(_ selection: AppColorScheme) {
        self.selection = selection
        applyCurrentAppearance()
    }

    @objc
    private func accessibilityDisplayOptionsDidChange(_: Notification) {
        applyCurrentAppearance()
    }

    private func applyCurrentAppearance() {
        let name = selection.appearanceName(
            increasesContrast: NSWorkspace.shared
                .accessibilityDisplayShouldIncreaseContrast
        )
        let appearance = name.flatMap(NSAppearance.init(named:))
        guard NSApplication.shared.appearance?.name != appearance?.name else {
            return
        }
        NSApplication.shared.appearance = appearance
    }
}

nonisolated enum ComposerBarAppearance: String, CaseIterable, Identifiable, Sendable {
    case defaultStyle = "default"
    case legacy

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .defaultStyle:
            LocalizedStringResource("Default", bundle: #bundle)
        case .legacy:
            LocalizedStringResource("Legacy", bundle: #bundle)
        }
    }
}

nonisolated enum MessageAppearance: String, CaseIterable, Identifiable, Sendable {
    case defaultStyle = "default"
    case bubbles

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .defaultStyle:
            LocalizedStringResource("Default", bundle: #bundle)
        case .bubbles:
            LocalizedStringResource("Bubbles", bundle: #bundle)
        }
    }
}

nonisolated struct AppearanceSettingsSnapshot: Equatable, Sendable {
    static let defaultWindowOpacity = 1.0
    static let windowOpacityRange = 0.0 ... 1.0
    static let defaultMessageSpacing = 6.0
    static let messageSpacingRange = 0.0 ... 12.0

    static let defaults = Self(
        colorScheme: .system,
        composerBarAppearance: .defaultStyle,
        serverMessageAppearance: .defaultStyle,
        messageSpacing: defaultMessageSpacing
    )

    var composerIcons: ComposerIconLayout = .defaults
    var interfaceSize: Double = InterfaceScale.defaultFactor
    var windowOpacity: Double = defaultWindowOpacity
    var colorScheme: AppColorScheme
    var composerBarAppearance: ComposerBarAppearance
    var directMessageAppearance: MessageAppearance = .defaultStyle
    var groupMessageAppearance: MessageAppearance = .defaultStyle
    var serverMessageAppearance: MessageAppearance
    var messageSpacing: Double

    func messageAppearance(for kind: ChannelKindValue?) -> MessageAppearance {
        switch kind {
        case .directMessage: directMessageAppearance
        case .groupDirectMessage: groupMessageAppearance
        default: serverMessageAppearance
        }
    }

    mutating func normalize() {
        windowOpacity = Self.normalizedWindowOpacity(windowOpacity)
        messageSpacing = Self.normalizedMessageSpacing(messageSpacing)
        interfaceSize = InterfaceScale.normalized(interfaceSize)
    }

    static func normalizedWindowOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWindowOpacity }
        return min(max(value, windowOpacityRange.lowerBound), windowOpacityRange.upperBound)
    }

    static func normalizedMessageSpacing(_ value: Double) -> Double {
        min(
            max(value, messageSpacingRange.lowerBound),
            messageSpacingRange.upperBound
        )
    }
}

@MainActor
final class AppearanceSettingsStore {
    static let shared = AppearanceSettingsStore()

    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> AppearanceSettingsSnapshot {
        let colorScheme: AppColorScheme
        if case let .string(rawValue) = preferences.value(for: .appColorScheme) {
            colorScheme = AppColorScheme(rawValue: rawValue) ?? .system
        } else {
            colorScheme = .system
        }
        let appearance: ComposerBarAppearance
        if case let .string(rawValue) = preferences.value(for: .composerBarAppearance) {
            appearance = ComposerBarAppearance(rawValue: rawValue) ?? .defaultStyle
        } else {
            appearance = .defaultStyle
        }
        func messageAppearance(_ id: SettingsControlID) -> MessageAppearance {
            guard case let .string(rawValue) = preferences.value(for: id) else { return .defaultStyle }
            return MessageAppearance(rawValue: rawValue) ?? .defaultStyle
        }
        let messageSpacing: Double
        if case let .double(value) = preferences.value(for: .messageDensity) {
            messageSpacing = value
        } else {
            messageSpacing = AppearanceSettingsSnapshot.defaults.messageSpacing
        }
        var value = AppearanceSettingsSnapshot(
            colorScheme: colorScheme,
            composerBarAppearance: appearance,
            directMessageAppearance: messageAppearance(.directMessageAppearance),
            groupMessageAppearance: messageAppearance(.groupMessageAppearance),
            serverMessageAppearance: messageAppearance(.messageAppearance),
            messageSpacing: messageSpacing
        )
        if case let .string(stored) = preferences.value(for: .composerIcons) {
            value.composerIcons = ComposerIconLayout(storageValue: stored)
        }
        if case let .double(stored) = preferences.value(for: .windowOpacity) {
            value.windowOpacity = stored
        }
        if case let .double(stored) = preferences.value(for: .interfaceSize) {
            value.interfaceSize = stored
        }
        value.normalize()
        return value
    }

    func save(_ value: AppearanceSettingsSnapshot) {
        preferences.set(
            .double(AppearanceSettingsSnapshot.normalizedWindowOpacity(value.windowOpacity)),
            for: .windowOpacity
        )
        preferences.set(.string(value.composerIcons.storageValue), for: .composerIcons)
        preferences.set(
            .string(value.colorScheme.rawValue),
            for: .appColorScheme
        )
        preferences.set(
            .string(value.composerBarAppearance.rawValue),
            for: .composerBarAppearance
        )
        preferences.set(
            .string(value.serverMessageAppearance.rawValue),
            for: .messageAppearance
        )
        preferences.set(.string(value.directMessageAppearance.rawValue), for: .directMessageAppearance)
        preferences.set(.string(value.groupMessageAppearance.rawValue), for: .groupMessageAppearance)
        preferences.set(
            .double(AppearanceSettingsSnapshot.normalizedMessageSpacing(
                value.messageSpacing
            )),
            for: .messageDensity
        )
        preferences.set(
            .double(InterfaceScale.normalized(value.interfaceSize)),
            for: .interfaceSize
        )
    }
}

@MainActor
extension AppModel {
    func messageAppearance(for channelID: ChannelID) -> MessageAppearance {
        if appearanceSettings.directMessageAppearance == appearanceSettings.serverMessageAppearance,
           appearanceSettings.groupMessageAppearance == appearanceSettings.serverMessageAppearance {
            return appearanceSettings.serverMessageAppearance
        }
        // Most rows belong to the selected channel; avoid searching the workspace for each one.
        let channel = selectedChannel?.id == channelID
            ? selectedChannel
            : messagePresentationChannelsByID[channelID]
        return appearanceSettings.messageAppearance(for: channel?.kind)
    }

    func applyAppearanceSettings(
        _ value: AppearanceSettingsSnapshot,
        persists: Bool = true
    ) {
        var value = value
        value.normalize()
        let colorSchemeChanged = appearanceSettings.colorScheme != value.colorScheme
        let messagePresentationChanged =
            appearanceSettings.serverMessageAppearance != value.serverMessageAppearance
                || appearanceSettings.directMessageAppearance != value.directMessageAppearance
                || appearanceSettings.groupMessageAppearance != value.groupMessageAppearance
                || appearanceSettings.messageSpacing != value.messageSpacing
                || appearanceSettings.interfaceSize != value.interfaceSize
        if colorSchemeChanged {
            AppAppearanceController.shared.apply(value.colorScheme)
        }
        InterfaceScale.shared.update(value.interfaceSize)
        appearanceSettings = value
        if colorSchemeChanged || messagePresentationChanged {
            timelinePresentationRevision &+= 1
        }
        if persists {
            AppearanceSettingsStore.shared.save(value)
        }
    }
}
