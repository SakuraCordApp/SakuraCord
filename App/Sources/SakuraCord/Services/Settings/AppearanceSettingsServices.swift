import AppKit
import Foundation

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
    static let defaultMessageSpacing = 6.0
    static let messageSpacingRange = 0.0 ... 12.0

    static let defaults = Self(
        colorScheme: .system,
        composerBarAppearance: .defaultStyle,
        messageAppearance: .defaultStyle,
        messageSpacing: defaultMessageSpacing
    )

    var colorScheme: AppColorScheme
    var composerBarAppearance: ComposerBarAppearance
    var messageAppearance: MessageAppearance
    var messageSpacing: Double

    mutating func normalize() {
        messageSpacing = Self.normalizedMessageSpacing(messageSpacing)
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
        let messageAppearance: MessageAppearance
        if case let .string(rawValue) = preferences.value(for: .messageAppearance) {
            messageAppearance = MessageAppearance(rawValue: rawValue) ?? .defaultStyle
        } else {
            messageAppearance = .defaultStyle
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
            messageAppearance: messageAppearance,
            messageSpacing: messageSpacing
        )
        value.normalize()
        return value
    }

    func save(_ value: AppearanceSettingsSnapshot) {
        preferences.set(
            .string(value.colorScheme.rawValue),
            for: .appColorScheme
        )
        preferences.set(
            .string(value.composerBarAppearance.rawValue),
            for: .composerBarAppearance
        )
        preferences.set(
            .string(value.messageAppearance.rawValue),
            for: .messageAppearance
        )
        preferences.set(
            .double(AppearanceSettingsSnapshot.normalizedMessageSpacing(
                value.messageSpacing
            )),
            for: .messageDensity
        )
    }
}

@MainActor
extension AppModel {
    func applyAppearanceSettings(
        _ value: AppearanceSettingsSnapshot,
        persists: Bool = true
    ) {
        let colorSchemeChanged = appearanceSettings.colorScheme != value.colorScheme
        let messagePresentationChanged =
            appearanceSettings.messageAppearance != value.messageAppearance
                || appearanceSettings.messageSpacing != value.messageSpacing
        if colorSchemeChanged {
            AppAppearanceController.shared.apply(value.colorScheme)
        }
        appearanceSettings = value
        if colorSchemeChanged || messagePresentationChanged {
            timelinePresentationRevision &+= 1
        }
        if persists {
            AppearanceSettingsStore.shared.save(value)
        }
    }
}
