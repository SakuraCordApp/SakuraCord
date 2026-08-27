import Foundation
import SwiftUI

nonisolated enum AppColorScheme: String, CaseIterable, Identifiable, Sendable {
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

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
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

nonisolated struct AppearanceSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(
        colorScheme: .system,
        accentColor: .blurple,
        composerBarAppearance: .defaultStyle
    )

    var colorScheme: AppColorScheme
    var accentColor: AccentColorChoice
    var composerBarAppearance: ComposerBarAppearance
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
        let accentColor: AccentColorChoice
        if case let .string(rawValue) = preferences.value(for: .accentColor) {
            if let storedAccentColor = AccentColorChoice(rawValue: rawValue) {
                accentColor = storedAccentColor
            } else {
                accentColor = .blurple
                preferences.set(.string(accentColor.rawValue), for: .accentColor)
            }
        } else {
            accentColor = .blurple
        }
        let appearance: ComposerBarAppearance
        if case let .string(rawValue) = preferences.value(for: .composerBarAppearance) {
            appearance = ComposerBarAppearance(rawValue: rawValue) ?? .defaultStyle
        } else {
            appearance = .defaultStyle
        }
        return AppearanceSettingsSnapshot(
            colorScheme: colorScheme,
            accentColor: accentColor,
            composerBarAppearance: appearance
        )
    }

    func save(_ value: AppearanceSettingsSnapshot) {
        preferences.set(
            .string(value.colorScheme.rawValue),
            for: .appColorScheme
        )
        preferences.set(
            .string(value.accentColor.rawValue),
            for: .accentColor
        )
        preferences.set(
            .string(value.composerBarAppearance.rawValue),
            for: .composerBarAppearance
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
        let accentColorChanged = appearanceSettings.accentColor != value.accentColor
        SakuraCordAccentColor.apply(value.accentColor)
        appearanceSettings = value
        if colorSchemeChanged || accentColorChanged {
            timelinePresentationRevision &+= 1
        }
        if persists {
            AppearanceSettingsStore.shared.save(value)
        }
    }
}
