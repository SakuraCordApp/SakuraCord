import Foundation

nonisolated extension SettingsControlID {
    static let themeBrightness = Self(rawValue: "theme.brightness")
    static let themeSaturation = Self(rawValue: "theme.saturation")
    static let themeIntensity = Self(rawValue: "theme.intensity")
    static let themeColors = Self(rawValue: "theme.colors")
    static let themeAddColor = Self(rawValue: "theme.add-color")
    static let themeRemoveColor = Self(rawValue: "theme.remove-color")
    static let themeRandomize = Self(rawValue: "theme.randomize")
    static let themeCopy = Self(rawValue: "theme.copy")
}

nonisolated extension SettingsCatalog {
    static let themeDetailControls: [SettingsControlMetadata] = [
        control(.themeBrightness, page: .appearance, section: .appearanceTheme,
                label: "Theme Brightness", help: "Adjust theme brightness.", keywords: []),
        control(.themeSaturation, page: .appearance, section: .appearanceTheme,
                label: "Theme Saturation", help: "Adjust theme saturation.", keywords: []),
        control(.themeIntensity, page: .appearance, section: .appearanceTheme,
                label: "Theme Intensity", help: "Adjust gradient intensity.", keywords: []),
        control(.themeColors, page: .appearance, section: .appearanceTheme,
                label: "Gradient Colors", help: "Choose gradient colors.", keywords: []),
        control(.themeAddColor, page: .appearance, section: .appearanceTheme,
                label: "Add Gradient Color", help: "Add a color to the gradient.", keywords: []),
        control(.themeRemoveColor, page: .appearance, section: .appearanceTheme,
                label: "Remove Gradient Color", help: "Remove a color from the gradient.", keywords: []),
        control(.themeRandomize, page: .appearance, section: .appearanceTheme,
                label: "Randomise Theme", help: "Generate a random theme.", keywords: []),
        control(.themeCopy, page: .appearance, section: .appearanceTheme,
                label: "Copy Theme", help: "Copy a link to share the current theme.", keywords: []),
    ]
}
