import Foundation

nonisolated extension SettingsCatalog {
    static let privacySafetyPage = page(
        .privacySafety, group: .dataSecurity, title: "Privacy", image: "hand.raised",
        help: "Control local privacy, external links, and scoped data clearing.",
        keywords: ["links", "security", "typing indicators", "clear data", "ignore", "ignored accounts", "block", "blocked accounts"]
    )

    static let privacySafetyControls: [SettingsControlMetadata] = [
        control(.blockedAccounts, page: .privacySafety, section: .privacyRelationships, label: "Blocked Accounts",
                help: "Manage accounts you have blocked on Discord.", keywords: ["block", "unblock", "people", "relationships"],
                owner: .appModel, scope: .discordSynchronized, persistence: .discordManaged, reset: .notApplicable),
        control(.ignoredAccounts, page: .privacySafety, section: .privacyRelationships, label: "Ignored Accounts",
                help: "Manage accounts you have ignored on Discord.", keywords: ["ignore", "unignore", "people", "relationships"],
                owner: .appModel, scope: .discordSynchronized, persistence: .discordManaged, reset: .notApplicable),
        control(
            .removeMediaMetadata, page: .privacySafety,
            section: .privacyDiscordActivity, label: "Remove metadata from images and videos",
            help: "Remove location, camera and other personal metadata before Discord or external uploads, preserving media quality.",
            keywords: ["GPS", "EXIF", "location", "photos", "metadata", "attachments", "uploads"],
            scope: .appWideLocal, persistence: .appPreferences, reset: .registeredLocalValue
        ),
        control(
            .anonymiseFileNames, page: .privacySafety,
            section: .privacyDiscordActivity, label: "Anonymise file names",
            help: "Replace uploaded file names with random names, keeping file extensions and spoiler markers.",
            keywords: ["anonymous", "anonymize", "randomise", "randomize", "filename", "attachments", "uploads"],
            scope: .appWideLocal, persistence: .appPreferences, reset: .registeredLocalValue
        ),
        control(
            .privacyTypingIndicators, page: .privacySafety,
            section: .privacyDiscordActivity, label: "Send Typing Indicators",
            help: "Send Discord typing events while composing.",
            keywords: ["typing status", "Discord", "composer"],
            scope: .appWideLocal, persistence: .appPreferences, reset: .registeredLocalValue
        ),
        control(
            .externalLinkProtection, page: .privacySafety,
            section: .privacyLinksServices,
            label: "Ask Permission When Opening External Links",
            help: "Choose whether SakuraCord asks before opening untrusted domains, all external links, or no external links.",
            keywords: ["URL", "domain", "phishing", "warning", "browser", "confirm"],
            scope: .appWideLocal, persistence: .appPreferences,
            reset: .registeredLocalValue
        ),
        control(
            .trustedDomains, page: .privacySafety,
            section: .privacyLinksServices, label: "Manage Trusted Domains",
            help: "Search, add, or remove exact domains that can open without confirmation under the default policy.",
            keywords: ["URL", "domain", "allow list", "trusted", "browser"],
            scope: .appWideLocal, persistence: .appPreferences,
            reset: .registeredLocalValue
        ),
        control(
            .clearLocalActivity, page: .privacySafety,
            section: .privacyLocalData, label: "Clear Local Activity",
            help: "Clear the current account's recent Quick Switch and forwarding destinations plus app-wide local emoji recents and learned usage.",
            keywords: ["history", "frecency", "forward", "quick switch", "recent emoji", "learning"],
            owner: .appModel, scope: .accountAndAppWideLocal,
            persistence: .notApplicable, reset: .categoryAction
        ),
    ]
}
