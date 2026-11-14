import Foundation

nonisolated extension SettingsControlID {
    static let profileName = Self(rawValue: "profiles.name")
    static let profilePronouns = Self(rawValue: "profiles.pronouns")
    static let profileBio = Self(rawValue: "profiles.bio")
    static let profileStatus = Self(rawValue: "profiles.status")
    static let profileWidgets = Self(rawValue: "profiles.widgets")
    static let profileAvatar = Self(rawValue: "profiles.avatar")
    static let profileAvatarDecoration = Self(rawValue: "profiles.avatar-decoration")
    static let profileBanner = Self(rawValue: "profiles.banner")
    static let profileBannerColor = Self(rawValue: "profiles.banner-color")
    static let profileThemePrimary = Self(rawValue: "profiles.theme-primary")
    static let profileThemeAccent = Self(rawValue: "profiles.theme-accent")
    static let profileNameplate = Self(rawValue: "profiles.nameplate")
    static let profileNameStyle = Self(rawValue: "profiles.name-style")
    static let profileEffect = Self(rawValue: "profiles.effect")
    static let profileFrame = Self(rawValue: "profiles.frame")
}

nonisolated extension SettingsSectionID {
    static let profileCustomization = Self(rawValue: "profiles")
}

nonisolated extension SettingsCatalog {
    static let profilesControls: [SettingsControlMetadata] = [
        control(.profileName, page: .profiles, section: .profileCustomization,
                label: "Display Name", help: "Edit your display name or server nickname.", keywords: []),
        control(.profilePronouns, page: .profiles, section: .profileCustomization,
                label: "Pronouns", help: "Edit the pronouns shown on your profile.", keywords: []),
        control(.profileBio, page: .profiles, section: .profileCustomization,
                label: "About Me", help: "Edit your profile biography.", keywords: []),
        control(.profileStatus, page: .profiles, section: .profileCustomization,
                label: "Custom Status", help: "Edit your custom status and its expiration.", keywords: []),
        control(.profileWidgets, page: .profiles, section: .profileCustomization,
                label: "Profile Widgets", help: "Add and arrange profile widgets.", keywords: []),
        control(.profileAvatar, page: .profiles, section: .profileCustomization,
                label: "Avatar", help: "Choose your profile avatar.", keywords: []),
        control(.profileAvatarDecoration, page: .profiles, section: .profileCustomization,
                label: "Avatar Decoration", help: "Choose an avatar decoration.", keywords: []),
        control(.profileBanner, page: .profiles, section: .profileCustomization,
                label: "Banner", help: "Choose your profile banner.", keywords: []),
        control(.profileBannerColor, page: .profiles, section: .profileCustomization,
                label: "Banner Color", help: "Choose your banner color.", keywords: []),
        control(.profileThemePrimary, page: .profiles, section: .profileCustomization,
                label: "Primary Profile Color", help: "Choose the primary profile theme color.", keywords: []),
        control(.profileThemeAccent, page: .profiles, section: .profileCustomization,
                label: "Accent Profile Color", help: "Choose the accent profile theme color.", keywords: []),
        control(.profileNameplate, page: .profiles, section: .profileCustomization,
                label: "Nameplate", help: "Choose a nameplate.", keywords: []),
        control(.profileNameStyle, page: .profiles, section: .profileCustomization,
                label: "Display Name Style", help: "Customize your display name style.", keywords: []),
        control(.profileEffect, page: .profiles, section: .profileCustomization,
                label: "Profile Effect", help: "Choose a profile effect.", keywords: []),
        control(.profileFrame, page: .profiles, section: .profileCustomization,
                label: "Profile Frame", help: "Choose a profile frame.", keywords: []),
    ]
}
