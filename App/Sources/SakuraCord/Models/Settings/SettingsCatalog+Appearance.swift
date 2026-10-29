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
            .matchBackgroundToPrimaryColor,
            page: .appearance,
            section: .appearanceTheme,
            label: "Use primary color in background gradients",
            help: "Include the primary color in the background. When disabled, use colors 2 onwards unless there is only one color.",
            keywords: ["background", "primary", "color", "colour", "match"],
            scope: .appWideLocal
        ),
        control(
            .overrideMacOSAccent,
            page: .appearance,
            section: .appearanceTheme,
            label: "Override macOS accent",
            help: "Use the Theme Designer accent even when macOS has a specific accent selected. Requires restarting SakuraCord.",
            keywords: ["accent", "color", "colour", "override", "system", "macos", "tint", "restart"],
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
