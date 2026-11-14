import Foundation

nonisolated extension SettingsCatalog {
    static let profilesPage = page(
        .profiles, group: .account, title: "Edit Profile", image: "pencil.circle.fill",
        help: "Customize your active Discord account's main and per-server profiles.",
        keywords: ["profile", "avatar", "banner", "nameplate", "decoration", "font", "display name", "bio", "pronouns", "server profile", "profile effect", "frame", "gradient", "Nitro"]
    )

    static let myAccountPage = page(
        .myAccount, group: .account, title: "Manage Account", image: "person.crop.circle",
        help: "View your active Discord account.",
        keywords: ["account", "profile", "username", "display name"]
    )

    static let myAccountControls: [SettingsControlMetadata] = [
        control(.accountUsername, page: .myAccount, section: .accountIdentity,
                label: "Username", help: "View your Discord username.", keywords: ["account name"]),
        control(.accountEmail, page: .myAccount, section: .accountIdentity,
                label: "Email", help: "View or reveal your account's email address.", keywords: ["email address"]),
        control(.accountPhone, page: .myAccount, section: .accountIdentity,
                label: "Phone Number", help: "View or reveal your account's phone number.", keywords: ["telephone", "mobile"]),
        control(.accountMFA, page: .myAccount, section: .accountIdentity,
                label: "Multi-Factor Authentication", help: "Check whether multi-factor authentication is enabled.", keywords: ["MFA", "2FA", "security"]),
        control(.accountDevices, page: .myAccount, section: .accountIdentity,
                label: "Logged-in Devices", help: "View your account's device sessions and their last activity.", keywords: ["sessions", "devices", "logins"]),
    ]
}
