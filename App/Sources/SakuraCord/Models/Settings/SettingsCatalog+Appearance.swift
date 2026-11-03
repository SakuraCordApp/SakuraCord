import Foundation

nonisolated extension SettingsCatalog {
    static let appearancePage = page(
        .appearance, group: .preferences, title: "Theme", image: "paintbrush.fill",
        help: "Choose how SakuraCord's interface looks.",
        keywords: ["appearance", "look", "style", "accent", "color", "theme"]
    )

    static let appearanceControls: [SettingsControlMetadata] = [
        control(
            .appColorScheme,
            page: .appearance,
            section: .appearanceTheme,
            label: "Appearance",
            help: "Follow the system appearance or choose SakuraCord's light or dark appearance.",
            keywords: ["appearance", "theme", "system", "light", "dark", "mode", "sun", "moon"],
            scope: .appWideLocal
        ),
        control(
            .windowOpacity,
            page: .appearance,
            section: .appearanceTheme,
            label: "Window Opacity",
            help: "Adjust the strength of the theme over a blurred, tinted window background.",
            keywords: ["window", "transparency", "transparent", "opacity", "background"],
            scope: .appWideLocal
        ),
        control(
            .themeDesigner,
            page: .appearance,
            section: .appearanceTheme,
            label: "Theme Designer",
            help: "Create a theme with color, saturation, intensity, brightness, and randomisation controls.",
            keywords: ["gradient", "theme", "designer", "color", "saturation", "intensity", "brightness", "hex", "randomise"],
            scope: .appWideLocal
        ),
        control(
            .resetTheme,
            page: .appearance,
            section: .appearanceTheme,
            label: "Reset to Defaults",
            help: "Restore the default appearance, window opacity, and theme colors.",
            keywords: ["theme", "appearance", "defaults", "restore", "reset", "opacity", "colors"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
    ]
}
