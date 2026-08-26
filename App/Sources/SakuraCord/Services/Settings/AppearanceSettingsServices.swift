import Foundation

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
    static let defaults = Self(composerBarAppearance: .defaultStyle)

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
        let appearance: ComposerBarAppearance
        if case let .string(rawValue) = preferences.value(for: .composerBarAppearance) {
            appearance = ComposerBarAppearance(rawValue: rawValue) ?? .defaultStyle
        } else {
            appearance = .defaultStyle
        }
        return AppearanceSettingsSnapshot(composerBarAppearance: appearance)
    }

    func save(_ value: AppearanceSettingsSnapshot) {
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
        appearanceSettings = value
        if persists {
            AppearanceSettingsStore.shared.save(value)
        }
    }
}
