import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let preferenceKey = "appearanceMode"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
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
