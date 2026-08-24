import Foundation

nonisolated enum SettingsPageID: String, CaseIterable, Codable, Identifiable, Sendable {
    case myAccount
    case general
    case interface
    case chat
    case notifications
    case voiceVideo
    case accessibility
    case keyboardShortcuts
    case privacySafety
    case storageDownloads
    case diagnostics
    case softwareUpdates
    case extensions
    case about

    var id: String { rawValue }
}

nonisolated enum SettingsSidebarGroupID: String, CaseIterable, Identifiable, Sendable {
    case account
    case preferences
    case dataSecurity
    case sakuraCord

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .account:
            LocalizedStringResource("Account", bundle: #bundle)
        case .preferences:
            LocalizedStringResource("Preferences", bundle: #bundle)
        case .dataSecurity:
            LocalizedStringResource("Data & Security", bundle: #bundle)
        case .sakuraCord:
            LocalizedStringResource("SakuraCord", bundle: #bundle)
        }
    }
}

nonisolated struct SettingsSectionID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}

nonisolated struct SettingsControlID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}

nonisolated struct SettingsDestination: Hashable, Codable, Sendable {
    let page: SettingsPageID
    let section: SettingsSectionID?

    init(page: SettingsPageID, section: SettingsSectionID? = nil) {
        self.page = page
        self.section = section
    }
}

nonisolated enum SettingsValueScope: String, Codable, Sendable {
    case appWideLocal
    case accountLocal
    case discordSynchronized
    case mixed

    var title: LocalizedStringResource {
        switch self {
        case .appWideLocal:
            LocalizedStringResource(
                "App-wide on this Mac",
                bundle: #bundle,
                comment: "Settings scope label for a preference shared by all accounts on this Mac."
            )
        case .accountLocal:
            LocalizedStringResource(
                "Selected account on this Mac",
                bundle: #bundle,
                comment: "Settings scope label for a local preference belonging to one account."
            )
        case .discordSynchronized:
            LocalizedStringResource(
                "Synchronized by Discord",
                bundle: #bundle,
                comment: "Settings scope label for a preference stored by Discord."
            )
        case .mixed:
            LocalizedStringResource(
                "Local and Discord-controlled",
                bundle: #bundle,
                comment: "Settings scope label for a page containing both local and Discord-controlled values."
            )
        }
    }
}

nonisolated enum SettingsResetCapability: String, Codable, Sendable {
    case registeredLocalValue
    case categoryAction
    case notApplicable
}

nonisolated enum SettingsValueOwner: String, Codable, Sendable {
    case applicationPreferences
    case accountPreferences
    case appModel
    case macOS
    case sparkle
    case discord
}

nonisolated enum SettingsPersistence: String, Codable, Sendable {
    case appPreferences
    case accountPreferences
    case sessionOnly
    case systemManaged
    case discordManaged
    case notApplicable
}

nonisolated enum SettingsAvailability: Equatable, Sendable {
    case available
    case unavailable(LocalizedStringResource)
}

nonisolated struct SettingsPageMetadata: Identifiable, Sendable {
    let id: SettingsPageID
    let group: SettingsSidebarGroupID
    let title: LocalizedStringResource
    let systemImage: String
    let help: LocalizedStringResource
    let keywords: [LocalizedStringResource]
    let overviewControlID: SettingsControlID
}

nonisolated struct SettingsControlMetadata: Identifiable, Sendable {
    let id: SettingsControlID
    let destination: SettingsDestination
    let label: LocalizedStringResource
    let help: LocalizedStringResource
    let keywords: [LocalizedStringResource]
    let owner: SettingsValueOwner
    let scope: SettingsValueScope
    let persistence: SettingsPersistence
    let resetCapability: SettingsResetCapability
    let availability: SettingsAvailability
}

nonisolated struct SettingsCatalog: Sendable {
    let pages: [SettingsPageMetadata]
    let controls: [SettingsControlMetadata]

    static let foundation = SettingsCatalog(
        pages: SettingsCatalog.foundationPages,
        controls: SettingsCatalog.foundationControls
    )

    func page(_ id: SettingsPageID) -> SettingsPageMetadata {
        pages.first { $0.id == id } ?? pages[0]
    }

    func pages(in group: SettingsSidebarGroupID) -> [SettingsPageMetadata] {
        pages.filter { $0.group == group }
    }
}

nonisolated extension SettingsSectionID {
    static let accountIdentity = Self(rawValue: "account-identity")
    static let accountLaunch = Self(rawValue: "account-launch")
    static let accountLocalData = Self(rawValue: "account-local-data")
    static let startupRestoration = Self(rawValue: "startup-restoration")
    static let confirmations = Self(rawValue: "confirmations")
    static let interfaceDensity = Self(rawValue: "interface-density")
    static let interfaceTypography = Self(rawValue: "interface-typography")
    static let interfaceTime = Self(rawValue: "interface-time")
    static let interfaceVisibility = Self(rawValue: "interface-visibility")
    static let interfacePreview = Self(rawValue: "interface-preview")
    static let interfaceLocalData = Self(rawValue: "interface-local-data")
    static let messagesAndMedia = Self(rawValue: "messages-and-media")
    static let softwareUpdates = Self(rawValue: "software-updates")
    static let notificationDelivery = Self(rawValue: "notification-delivery")
    static let notificationQuietHours = Self(rawValue: "notification-quiet-hours")
    static let voiceDevices = Self(rawValue: "voice-devices")
    static let voiceLevels = Self(rawValue: "voice-levels")
    static let mediaCache = Self(rawValue: "media-cache")
    static let apiDiagnostics = Self(rawValue: "api-diagnostics")
}

nonisolated extension SettingsControlID {
    static func overview(_ page: SettingsPageID) -> Self {
        Self(rawValue: "\(page.rawValue).overview")
    }

    static let selectedAccount = Self(rawValue: "my-account.selected-account")
    static let switchAccount = Self(rawValue: "my-account.switch-account")
    static let addAccount = Self(rawValue: "my-account.add-account")
    static let reopenLastAccount = Self(rawValue: "my-account.reopen-last-account")
    static let preferredLaunchAccount = Self(rawValue: "my-account.preferred-launch-account")
    static let removeSavedSession = Self(rawValue: "my-account.remove-saved-session")
    static let exportAccountPreferences = Self(rawValue: "my-account.export-preferences")
    static let resetAccountPreferences = Self(rawValue: "my-account.reset-preferences")
    static let launchAtLogin = Self(rawValue: "general.launch-at-login")
    static let launchDestination = Self(rawValue: "general.launch-destination")
    static let showMainWindowAtLaunch = Self(rawValue: "general.show-main-window")
    static let rememberMemberListVisibility = Self(rawValue: "general.remember-member-list")
    static let confirmQuitActiveWork = Self(rawValue: "general.confirm-quit-active-work")
    static let confirmDiscardComposer = Self(rawValue: "general.confirm-discard-composer")
    static let messageDensity = Self(rawValue: "interface.message-density")
    static let sidebarDensity = Self(rawValue: "interface.sidebar-density")
    static let messageTextSize = Self(rawValue: "interface.message-text-size")
    static let interfaceTextSize = Self(rawValue: "interface.interface-text-size")
    static let resetInterfaceTextSizes = Self(rawValue: "interface.reset-text-sizes")
    static let timestampFormat = Self(rawValue: "interface.timestamp-format")
    static let timestampSeconds = Self(rawValue: "interface.timestamp-seconds")
    static let groupingInterval = Self(rawValue: "interface.grouping-interval")
    static let underlineLinks = Self(rawValue: "interface.underline-links")
    static let showMemberList = Self(rawValue: "interface.show-member-list")
    static let showChannelHeader = Self(rawValue: "interface.show-channel-header")
    static let showActivityDetails = Self(rawValue: "interface.show-activity-details")
    static let messageActionVisibility = Self(rawValue: "interface.message-actions")
    static let showRoleColors = Self(rawValue: "interface.show-role-colors")
    static let interfacePreview = Self(rawValue: "interface.preview")
    static let exportInterfaceSettings = Self(rawValue: "interface.export")
    static let resetInterfaceSettings = Self(rawValue: "interface.reset")
    static let sendWithReturn = Self(rawValue: "chat.send-with-return")
    static let reduceAnimatedMedia = Self(rawValue: "accessibility.reduce-animated-media")
    static let updateReleaseTrack = Self(rawValue: "software-updates.release-track")
    static let updateAutomaticChecks = Self(rawValue: "software-updates.automatic-checks")
    static let updateAutomaticDownloads = Self(rawValue: "software-updates.automatic-downloads")
    static let updateStatus = Self(rawValue: "software-updates.status")
    static let checkForUpdates = Self(rawValue: "software-updates.check-now")
    static let mediaCacheLimit = Self(rawValue: "storage.media-cache-limit")
    static let notificationPermission = Self(rawValue: "notifications.system-permission")
    static let notificationEnabled = Self(rawValue: "notifications.enabled")
    static let notificationPreview = Self(rawValue: "notifications.preview")
    static let notificationSound = Self(rawValue: "notifications.sound")
    static let notificationDockBadge = Self(rawValue: "notifications.dock-badge")
    static let notificationQuietHours = Self(rawValue: "notifications.quiet-hours")
    static let notificationQuietStart = Self(rawValue: "notifications.quiet-start")
    static let notificationQuietEnd = Self(rawValue: "notifications.quiet-end")
    static let voiceInputDevice = Self(rawValue: "voice-video.input-device")
    static let voiceOutputDevice = Self(rawValue: "voice-video.output-device")
    static let voiceCamera = Self(rawValue: "voice-video.camera")
    static let voiceInputVolume = Self(rawValue: "voice-video.input-volume")
    static let voiceOutputVolume = Self(rawValue: "voice-video.output-volume")
    static let diagnosticDetailedPayloads = Self(rawValue: "diagnostics.detailed-payloads")
    static let diagnosticDiskCapture = Self(rawValue: "diagnostics.disk-capture")
    static let diagnosticRetainedEntries = Self(rawValue: "diagnostics.retained-entries")
    static let diagnosticExport = Self(rawValue: "diagnostics.export-api-logs")
    static let diagnosticClear = Self(rawValue: "diagnostics.clear-api-logs")
}

private nonisolated extension SettingsCatalog {
    static let foundationPages: [SettingsPageMetadata] = [
        page(
            .myAccount, group: .account, title: "My Account", image: "person.crop.circle",
            help: "Inspect and manage saved Discord accounts and account-local SakuraCord preferences.",
            keywords: ["account", "profile", "login", "logout", "switch account"]
        ),
        page(
            .general, group: .preferences, title: "General", image: "gearshape",
            help: "Choose startup, restoration, and confirmation behavior.",
            keywords: ["startup", "launch", "restore", "confirmation", "quit"]
        ),
        page(
            .interface, group: .preferences, title: "Interface", image: "macwindow",
            help: "Adjust the density and readability of SakuraCord without changing its theme.",
            keywords: ["appearance", "density", "comfortable", "compact", "font", "text size", "clock", "timestamp", "roles", "member list"]
        ),
        page(
            .chat, group: .preferences, title: "Chat", image: "bubble.left.and.bubble.right",
            help: "Control composer, message, media, link, and emoji behavior.",
            keywords: ["message", "composer", "send", "typing", "draft", "emoji", "autoplay"]
        ),
        page(
            .notifications, group: .preferences, title: "Notifications", image: "bell",
            help: "Narrow local macOS notification delivery while preserving Discord server and channel settings.",
            keywords: ["alerts", "sound", "badge", "quiet hours", "permission", "preview"]
        ),
        page(
            .voiceVideo, group: .preferences, title: "Voice & Video", image: "waveform.and.mic",
            help: "Choose call devices, levels, tests, processing, and share defaults.",
            keywords: ["microphone", "speaker", "camera", "audio", "video", "screen share", "noise suppression"]
        ),
        page(
            .accessibility, group: .preferences, title: "Accessibility", image: "accessibility",
            help: "Tune motion, animated content, readability, interaction, and VoiceOver output.",
            keywords: ["reduce motion", "contrast", "animation", "VoiceOver", "keyboard", "larger targets"]
        ),
        page(
            .keyboardShortcuts, group: .preferences, title: "Keyboard Shortcuts", image: "keyboard",
            help: "Review and customize SakuraCord keyboard commands.",
            keywords: ["keys", "bindings", "hotkeys", "commands", "recorder"]
        ),
        page(
            .privacySafety, group: .dataSecurity, title: "Privacy & Safety", image: "hand.raised",
            help: "Control local privacy, external links, third-party uploads, and scoped data clearing.",
            keywords: ["links", "security", "typing indicators", "read receipts", "uploads", "clear data"]
        ),
        page(
            .storageDownloads, group: .dataSecurity, title: "Storage & Downloads", image: "internaldrive",
            help: "Manage media cache, downloads, drafts, and SakuraCord-owned temporary files.",
            keywords: ["cache", "disk", "folder", "downloads", "drafts", "clear cache"]
        ),
        page(
            .diagnostics, group: .dataSecurity, title: "Diagnostics", image: "stethoscope",
            help: "Inspect app status and export sanitized diagnostic information.",
            keywords: ["logs", "support", "status", "Gateway", "permissions", "export"]
        ),
        page(
            .softwareUpdates, group: .sakuraCord, title: "Software Updates", image: "arrow.triangle.2.circlepath",
            help: "Manage signed SakuraCord update checks, downloads, and release tracks.",
            keywords: ["update", "release", "regular", "nightly", "Sparkle", "version"]
        ),
        page(
            .extensions, group: .sakuraCord, title: "Extensions", image: "puzzlepiece.extension",
            help: "Learn about SakuraCord's future sandboxed extension system.",
            keywords: ["plugins", "permissions", "sandbox", "SDK", "host"]
        ),
        page(
            .about, group: .sakuraCord, title: "About", image: "info.circle",
            help: "View SakuraCord version, project links, acknowledgements, and update availability.",
            keywords: ["version", "build", "website", "source", "roadmap", "acknowledgements"]
        ),
    ]

    static let foundationControls: [SettingsControlMetadata] = [
        control(
            .selectedAccount,
            page: .myAccount,
            section: .accountIdentity,
            label: "Account to inspect",
            help: "Choose which saved account's local settings this page displays without changing the active Discord session.",
            keywords: ["selected account", "inspect", "profile", "saved account"],
            owner: .accountPreferences,
            scope: .accountLocal,
            persistence: .sessionOnly,
            reset: .notApplicable
        ),
        control(
            .switchAccount,
            page: .myAccount,
            section: .accountIdentity,
            label: "Switch to Account",
            help: "Replace the active workspace with the selected saved Discord session.",
            keywords: ["activate", "change account", "connect"],
            owner: .appModel,
            scope: .discordSynchronized,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .addAccount,
            page: .myAccount,
            section: .accountIdentity,
            label: "Add Account",
            help: "Open SakuraCord's existing Discord authentication flow.",
            keywords: ["login", "sign in", "QR", "another account"],
            owner: .appModel,
            scope: .discordSynchronized,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .reopenLastAccount,
            page: .myAccount,
            section: .accountLaunch,
            label: "Reopen the last active account",
            help: "Reconnect the account that was active most recently when SakuraCord launches.",
            keywords: ["startup", "launch", "restore", "last used"],
            scope: .appWideLocal
        ),
        control(
            .preferredLaunchAccount,
            page: .myAccount,
            section: .accountLaunch,
            label: "Preferred launch account",
            help: "Choose a fixed saved account to reconnect when SakuraCord launches.",
            keywords: ["startup account", "default account", "preferred account"],
            scope: .appWideLocal
        ),
        control(
            .removeSavedSession,
            page: .myAccount,
            section: .accountIdentity,
            label: "Log Out or Remove Saved Account",
            help: "Remove the selected account's saved session from macOS Keychain; an active account is disconnected first.",
            keywords: ["sign out", "disconnect", "forget account", "delete login", "Keychain"],
            owner: .appModel,
            scope: .mixed,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .exportAccountPreferences,
            page: .myAccount,
            section: .accountLocalData,
            label: "Export Local Preferences",
            help: "Export registered local preferences for only the selected account as versioned JSON.",
            keywords: ["backup", "JSON", "save settings", "account data"],
            owner: .accountPreferences,
            scope: .accountLocal,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .resetAccountPreferences,
            page: .myAccount,
            section: .accountLocalData,
            label: "Reset Local Preferences",
            help: "Reset only registered local preferences belonging to the selected account.",
            keywords: ["defaults", "clear settings", "restore"],
            owner: .accountPreferences,
            scope: .accountLocal,
            persistence: .accountPreferences,
            reset: .categoryAction
        ),
        control(
            .launchAtLogin,
            page: .general,
            section: .startupRestoration,
            label: "Launch at Login",
            help: "Ask macOS to launch SakuraCord after this user logs in.",
            keywords: ["startup", "login item", "open automatically", "Service Management"],
            owner: .macOS,
            scope: .appWideLocal,
            persistence: .systemManaged,
            reset: .notApplicable
        ),
        control(
            .launchDestination,
            page: .general,
            section: .startupRestoration,
            label: "Launch destination",
            help: "Choose which account and safely restored conversation SakuraCord opens at launch.",
            keywords: ["last conversation", "last location", "account picker", "startup page"],
            scope: .appWideLocal
        ),
        control(
            .showMainWindowAtLaunch,
            page: .general,
            section: .startupRestoration,
            label: "Show the main window at launch",
            help: "Present SakuraCord's main window immediately when the app launches.",
            keywords: ["background", "hidden", "window", "Dock"],
            scope: .appWideLocal
        ),
        control(
            .rememberMemberListVisibility,
            page: .general,
            section: .startupRestoration,
            label: "Remember member list visibility",
            help: "Restore whether the conversation member list was visible when SakuraCord last quit.",
            keywords: ["inspector", "members", "sidebar", "restore"],
            scope: .appWideLocal
        ),
        control(
            .confirmQuitActiveWork,
            page: .general,
            section: .confirmations,
            label: "Confirm quitting during active work",
            help: "Ask before quitting during a call, screen share, or active upload.",
            keywords: ["quit warning", "call", "screen share", "upload"],
            scope: .appWideLocal
        ),
        control(
            .confirmDiscardComposer,
            page: .general,
            section: .confirmations,
            label: "Confirm discarding composer changes",
            help: "Ask before discarding meaningful unsent attachments, command input, or edited message text.",
            keywords: ["draft", "unsent", "edit", "discard warning", "attachments"],
            scope: .appWideLocal
        ),
        control(
            .messageDensity,
            page: .interface,
            section: .interfaceDensity,
            label: "Message density",
            help: "Choose Comfortable, Balanced, or Compact message spacing.",
            keywords: ["compact", "comfortable", "balanced", "spacing", "cozy"],
            scope: .appWideLocal
        ),
        control(
            .sidebarDensity,
            page: .interface,
            section: .interfaceDensity,
            label: "Sidebar density",
            help: "Choose Comfortable or Compact channel-list spacing.",
            keywords: ["compact", "channel list", "sidebar rows", "spacing"],
            scope: .appWideLocal
        ),
        control(
            .messageTextSize,
            page: .interface,
            section: .interfaceTypography,
            label: "Message text size",
            help: "Adjust message text from 12 to 22 points.",
            keywords: ["font", "chat size", "larger text", "readability"],
            scope: .appWideLocal
        ),
        control(
            .interfaceTextSize,
            page: .interface,
            section: .interfaceTypography,
            label: "Interface text size",
            help: "Adjust sidebar, header, and member-list text from 11 to 18 points.",
            keywords: ["font", "UI size", "sidebar text", "member list"],
            scope: .appWideLocal
        ),
        control(
            .resetInterfaceTextSizes,
            page: .interface,
            section: .interfaceTypography,
            label: "Reset Text Sizes",
            help: "Restore message and interface text to their readable defaults.",
            keywords: ["default font", "restore size"],
            scope: .appWideLocal,
            persistence: .notApplicable,
            reset: .categoryAction
        ),
        control(
            .timestampFormat,
            page: .interface,
            section: .interfaceTime,
            label: "Timestamp format",
            help: "Use the locale-aware system clock or an explicit 12- or 24-hour clock.",
            keywords: ["clock", "time", "12 hour", "24 hour", "timestamp"],
            scope: .appWideLocal
        ),
        control(
            .timestampSeconds,
            page: .interface,
            section: .interfaceTime,
            label: "Show seconds in full timestamps",
            help: "Include seconds in expanded message timestamps and their accessibility value.",
            keywords: ["clock seconds", "precise time", "expanded timestamp"],
            scope: .appWideLocal
        ),
        control(
            .groupingInterval,
            page: .interface,
            section: .interfaceTime,
            label: "Consecutive-message grouping",
            help: "Choose how many minutes consecutive messages from one author remain grouped.",
            keywords: ["group interval", "continuation", "author", "minutes"],
            scope: .appWideLocal
        ),
        control(
            .underlineLinks,
            page: .interface,
            section: .interfaceVisibility,
            label: "Underline links",
            help: "Underline links in message content in addition to using the system link color.",
            keywords: ["URL", "hyperlink", "decoration", "readability"],
            scope: .appWideLocal
        ),
        control(
            .showMemberList,
            page: .interface,
            section: .interfaceVisibility,
            label: "Show member list",
            help: "Show the member inspector for ordinary conversations.",
            keywords: ["members", "people", "inspector", "right sidebar"],
            scope: .appWideLocal
        ),
        control(
            .showChannelHeader,
            page: .interface,
            section: .interfaceVisibility,
            label: "Show channel topic in header",
            help: "Show the selected channel topic beneath its name when Discord provides one.",
            keywords: ["topic", "header", "toolbar", "channel description"],
            scope: .appWideLocal
        ),
        control(
            .showActivityDetails,
            page: .interface,
            section: .interfaceVisibility,
            label: "Show activity and presence details",
            help: "Show member activity text and presence indicators in the member list.",
            keywords: ["presence", "status", "activity", "game", "member details"],
            scope: .appWideLocal
        ),
        control(
            .messageActionVisibility,
            page: .interface,
            section: .interfaceVisibility,
            label: "Message actions",
            help: "Reveal message actions on hover or keep an action affordance visible.",
            keywords: ["hover", "always visible", "reply", "reaction", "toolbar"],
            scope: .appWideLocal
        ),
        control(
            .showRoleColors,
            page: .interface,
            section: .interfaceVisibility,
            label: "Show Discord role colors",
            help: "Use role colors for member and message author names when Discord provides them.",
            keywords: ["roles", "author color", "member color", "Discord color"],
            scope: .appWideLocal
        ),
        control(
            .interfacePreview,
            page: .interface,
            section: .interfacePreview,
            label: "Interface preview",
            help: "Preview sidebar and message presentation without using Discord data.",
            keywords: ["sample", "live preview", "appearance"],
            owner: .appModel,
            scope: .appWideLocal,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .exportInterfaceSettings,
            page: .interface,
            section: .interfaceLocalData,
            label: "Export Interface Settings",
            help: "Export registered Interface preferences as versioned JSON.",
            keywords: ["backup", "JSON", "save preferences"],
            scope: .appWideLocal,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .resetInterfaceSettings,
            page: .interface,
            section: .interfaceLocalData,
            label: "Reset Interface Settings",
            help: "Restore registered Interface preferences without changing credentials or Discord state.",
            keywords: ["defaults", "restore", "clear interface preferences"],
            scope: .appWideLocal,
            persistence: .appPreferences,
            reset: .categoryAction
        ),
        control(
            .sendWithReturn,
            page: .general,
            section: .messagesAndMedia,
            label: "Press Return to send messages",
            help: "Choose whether Return sends a message or inserts a newline.",
            keywords: ["enter", "newline", "composer"],
            scope: .appWideLocal
        ),
        control(
            .reduceAnimatedMedia,
            page: .general,
            section: .messagesAndMedia,
            label: "Reduce animated media",
            help: "Reduce motion from animated images and media.",
            keywords: ["GIF", "animation", "motion"],
            scope: .appWideLocal
        ),
        control(
            .updateReleaseTrack,
            page: .general,
            section: .softwareUpdates,
            label: "Release track",
            help: "Choose the signed Regular or Nightly update feed.",
            keywords: ["regular", "nightly", "channel"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .updateAutomaticChecks,
            page: .general,
            section: .softwareUpdates,
            label: "Automatically check for updates",
            help: "Let SakuraCord periodically check its configured signed feed.",
            keywords: ["scheduled", "Sparkle"],
            owner: .sparkle,
            scope: .appWideLocal,
            persistence: .systemManaged,
            reset: .categoryAction
        ),
        control(
            .updateAutomaticDownloads,
            page: .general,
            section: .softwareUpdates,
            label: "Automatically download updates",
            help: "Download verified updates when Sparkle allows automatic updates.",
            keywords: ["download", "Sparkle"],
            owner: .sparkle,
            scope: .appWideLocal,
            persistence: .systemManaged,
            reset: .categoryAction
        ),
        control(
            .updateStatus,
            page: .general,
            section: .softwareUpdates,
            label: "Update status",
            help: "Show whether update checking is available in this build.",
            keywords: ["availability", "service"],
            owner: .sparkle,
            scope: .appWideLocal,
            persistence: .sessionOnly,
            reset: .notApplicable
        ),
        control(
            .checkForUpdates,
            page: .general,
            section: .softwareUpdates,
            label: "Check for Updates",
            help: "Ask the existing updater to check now.",
            keywords: ["update now", "new version"],
            owner: .sparkle,
            scope: .appWideLocal,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .mediaCacheLimit,
            page: .storageDownloads,
            section: .mediaCache,
            label: "Media cache",
            help: "Set the maximum local media cache size.",
            keywords: ["disk", "storage", "limit"],
            scope: .appWideLocal
        ),
        control(
            .notificationPermission,
            page: .notifications,
            section: .notificationDelivery,
            label: "System permission",
            help: "Show or request the current macOS notification authorization.",
            keywords: ["allow", "denied", "System Settings"],
            owner: .macOS,
            scope: .appWideLocal,
            persistence: .systemManaged,
            reset: .notApplicable
        ),
        control(
            .notificationEnabled,
            page: .notifications,
            section: .notificationDelivery,
            label: "Enable native notifications",
            help: "Allow eligible Discord events to appear as local macOS notifications.",
            keywords: ["alerts", "master"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .notificationPreview,
            page: .notifications,
            section: .notificationDelivery,
            label: "Notification previews",
            help: "Choose how much message information appears in notifications.",
            keywords: ["sender", "hidden", "privacy"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .notificationSound,
            page: .notifications,
            section: .notificationDelivery,
            label: "Play sound",
            help: "Play a sound for delivered native notifications.",
            keywords: ["audio", "alert"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .notificationDockBadge,
            page: .notifications,
            section: .notificationDelivery,
            label: "Show unread mentions in Dock",
            help: "Show unread mention count on SakuraCord's Dock icon.",
            keywords: ["badge", "mentions"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .notificationQuietHours,
            page: .notifications,
            section: .notificationQuietHours,
            label: "Quiet hours",
            help: "Suppress ordinary local notifications during a configured time range.",
            keywords: ["schedule", "do not disturb"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .notificationQuietStart,
            page: .notifications,
            section: .notificationQuietHours,
            label: "Quiet hours start",
            help: "Choose when the current quiet-hours range begins.",
            keywords: ["schedule", "start time"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .notificationQuietEnd,
            page: .notifications,
            section: .notificationQuietHours,
            label: "Quiet hours end",
            help: "Choose when the current quiet-hours range ends.",
            keywords: ["schedule", "end time"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .voiceInputDevice,
            page: .voiceVideo,
            section: .voiceDevices,
            label: "Input device",
            help: "Choose the microphone used by SakuraCord calls.",
            keywords: ["microphone", "system default"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .voiceOutputDevice,
            page: .voiceVideo,
            section: .voiceDevices,
            label: "Output device",
            help: "Choose the speaker or headphones used by SakuraCord calls.",
            keywords: ["speaker", "headphones", "system default"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .voiceCamera,
            page: .voiceVideo,
            section: .voiceDevices,
            label: "Camera",
            help: "Choose the camera used by SakuraCord calls.",
            keywords: ["webcam", "video"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .voiceInputVolume,
            page: .voiceVideo,
            section: .voiceLevels,
            label: "Input volume",
            help: "Adjust the microphone level applied by SakuraCord.",
            keywords: ["microphone", "gain"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .voiceOutputVolume,
            page: .voiceVideo,
            section: .voiceLevels,
            label: "Output volume",
            help: "Adjust call playback volume in SakuraCord.",
            keywords: ["speaker", "playback"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .diagnosticDetailedPayloads,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Capture detailed sanitized payloads",
            help: "Retain allowlisted protocol details after sensitive values are discarded.",
            keywords: ["API", "JSON", "redaction"],
            owner: .appModel,
            scope: .appWideLocal,
            persistence: .sessionOnly,
            reset: .categoryAction
        ),
        control(
            .diagnosticDiskCapture,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Save diagnostics to disk",
            help: "Write bounded private diagnostic sessions under Application Support.",
            keywords: ["logs", "capture", "files"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .diagnosticRetainedEntries,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Retained entries",
            help: "Show the number of sanitized diagnostic entries in memory.",
            keywords: ["count", "ring buffer"],
            owner: .appModel,
            scope: .appWideLocal,
            persistence: .sessionOnly,
            reset: .notApplicable
        ),
        control(
            .diagnosticExport,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Export API Logs",
            help: "Save the retained sanitized JSON Lines diagnostic log.",
            keywords: ["support", "JSONL", "save"],
            owner: .appModel,
            scope: .appWideLocal,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .diagnosticClear,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Clear Logs",
            help: "Clear retained and managed on-disk diagnostics without changing credentials or Discord state.",
            keywords: ["delete", "reset", "memory"],
            owner: .appModel,
            scope: .appWideLocal,
            persistence: .notApplicable,
            reset: .categoryAction
        ),
    ]

    static func page(
        _ id: SettingsPageID,
        group: SettingsSidebarGroupID,
        title: String.LocalizationValue,
        image: String,
        help: String.LocalizationValue,
        keywords: [String.LocalizationValue]
    ) -> SettingsPageMetadata {
        SettingsPageMetadata(
            id: id,
            group: group,
            title: LocalizedStringResource(title, bundle: #bundle),
            systemImage: image,
            help: LocalizedStringResource(help, bundle: #bundle),
            keywords: keywords.map { LocalizedStringResource($0, bundle: #bundle) },
            overviewControlID: .overview(id)
        )
    }

    static func control(
        _ id: SettingsControlID,
        page: SettingsPageID,
        section: SettingsSectionID,
        label: String.LocalizationValue,
        help: String.LocalizationValue,
        keywords: [String.LocalizationValue],
        owner: SettingsValueOwner = .applicationPreferences,
        scope: SettingsValueScope,
        persistence: SettingsPersistence = .appPreferences,
        reset: SettingsResetCapability = .registeredLocalValue,
        availability: SettingsAvailability = .available
    ) -> SettingsControlMetadata {
        SettingsControlMetadata(
            id: id,
            destination: SettingsDestination(page: page, section: section),
            label: LocalizedStringResource(label, bundle: #bundle),
            help: LocalizedStringResource(help, bundle: #bundle),
            keywords: keywords.map { LocalizedStringResource($0, bundle: #bundle) },
            owner: owner,
            scope: scope,
            persistence: persistence,
            resetCapability: reset,
            availability: availability
        )
    }
}
