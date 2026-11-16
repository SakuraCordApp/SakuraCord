import Foundation

nonisolated enum NativeEmojiSkinTone: String, CaseIterable, Identifiable, Sendable {
    case standard
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    /// The picker's stored tone, shared by autocomplete and quick reactions.
    static var preferred: NativeEmojiSkinTone {
        NativeEmojiSkinTone(rawValue: UserDefaults.standard.string(forKey: "emojiSkinTone") ?? "") ?? .standard
    }

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .standard: "Default"
        case .light: "Light"
        case .mediumLight: "Medium light"
        case .medium: "Medium"
        case .mediumDark: "Medium dark"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "👋"
        case .light: "👋🏻"
        case .mediumLight: "👋🏼"
        case .medium: "👋🏽"
        case .mediumDark: "👋🏾"
        case .dark: "👋🏿"
        }
    }
}
