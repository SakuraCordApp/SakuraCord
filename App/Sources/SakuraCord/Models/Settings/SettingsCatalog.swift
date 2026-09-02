import Foundation

nonisolated enum SettingsPageID: String, CaseIterable, Codable, Identifiable, Sendable {
    case myAccount
    case general
    case appearance
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
    static let appearanceTheme = Self(rawValue: "appearance-theme")
    static let interfaceMessages = Self(rawValue: "interface-messages")
    static let interfaceTime = Self(rawValue: "interface-time")
    static let interfaceVisibility = Self(rawValue: "interface-visibility")
    static let interfacePreview = Self(rawValue: "interface-preview")
    static let interfaceLocalData = Self(rawValue: "interface-local-data")
    static let chatComposer = Self(rawValue: "chat-composer")
    static let chatMessages = Self(rawValue: "chat-messages")
    static let chatMedia = Self(rawValue: "chat-media")
    static let chatEmoji = Self(rawValue: "chat-emoji")
    static let chatLocalData = Self(rawValue: "chat-local-data")
    static let softwareUpdates = Self(rawValue: "software-updates")
    static let notificationDelivery = Self(rawValue: "notification-delivery")
    static let notificationEvents = Self(rawValue: "notification-events")
    static let notificationQuietHours = Self(rawValue: "notification-quiet-hours")
    static let notificationLocalData = Self(rawValue: "notification-local-data")
    static let voiceDevices = Self(rawValue: "voice-devices")
    static let voiceLevels = Self(rawValue: "voice-levels")
    static let voiceCallDefaults = Self(rawValue: "voice-call-defaults")
    static let voiceCamera = Self(rawValue: "voice-camera")
    static let voiceScreenShare = Self(rawValue: "voice-screen-share")
    static let voicePermissions = Self(rawValue: "voice-permissions")
    static let voiceLocalData = Self(rawValue: "voice-local-data")
    static let accessibilityMotion = Self(rawValue: "accessibility-motion")
    static let accessibilityReadability = Self(rawValue: "accessibility-readability")
    static let accessibilityVoiceOver = Self(rawValue: "accessibility-voiceover")
    static let accessibilityLocalData = Self(rawValue: "accessibility-local-data")
    static let shortcutNavigation = Self(rawValue: "shortcut-navigation")
    static let shortcutMessaging = Self(rawValue: "shortcut-messaging")
    static let shortcutVoiceVideo = Self(rawValue: "shortcut-voice-video")
    static let shortcutLocalData = Self(rawValue: "shortcut-local-data")
    static let privacyDiscordActivity = Self(rawValue: "privacy-discord-activity")
    static let privacyLinksServices = Self(rawValue: "privacy-links-services")
    static let privacyLocalData = Self(rawValue: "privacy-local-data")
    static let localStorage = Self(rawValue: "local-storage")
    static let storageDownloads = Self(rawValue: "storage-downloads")
    static let diagnosticsStatus = Self(rawValue: "diagnostics-status")
    static let diagnosticsSupport = Self(rawValue: "diagnostics-support")
    static let apiDiagnostics = Self(rawValue: "api-diagnostics")
    static let aboutVersion = Self(rawValue: "about-version")
    static let aboutLinks = Self(rawValue: "about-links")
    static let aboutAcknowledgements = Self(rawValue: "about-acknowledgements")
    static let aboutLegal = Self(rawValue: "about-legal")
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
    static let appColorScheme = Self(rawValue: "appearance.color-scheme")
    static let legacyAccentColorMigration = Self(rawValue: "appearance.accent-color")
    static let themeDesigner = Self(rawValue: "appearance.theme-designer")
    static let composerBarAppearance = Self(rawValue: "appearance.composer-bar")
    static let messageAppearance = Self(rawValue: "appearance.messages")
    static let messageDensity = Self(rawValue: "appearance.message-density")
    static let resetMessageAppearance = Self(rawValue: "interface.reset-message-appearance")
    static let timestampFormat = Self(rawValue: "interface.timestamp-format")
    static let timestampSeconds = Self(rawValue: "interface.timestamp-seconds")
    static let groupingInterval = Self(rawValue: "interface.grouping-interval")
    static let underlineLinks = Self(rawValue: "interface.underline-links")
    static let showMemberList = Self(rawValue: "interface.show-member-list")
    static let showActivityDetails = Self(rawValue: "interface.show-activity-details")
    static let messageActionVisibility = Self(rawValue: "interface.message-actions")
    static let showRoleColors = Self(rawValue: "interface.show-role-colors")
    static let interfacePreview = Self(rawValue: "interface.preview")
    static let exportInterfaceSettings = Self(rawValue: "interface.export")
    static let resetInterfaceSettings = Self(rawValue: "interface.reset")
    static let sendWithReturn = Self(rawValue: "chat.send-with-return")
    static let chatSpellCheck = Self(rawValue: "chat.spell-check")
    static let chatAutomaticCorrection = Self(rawValue: "chat.automatic-correction")
    static let chatSmartQuotes = Self(rawValue: "chat.smart-quotes")
    static let chatSmartDashes = Self(rawValue: "chat.smart-dashes")
    static let chatTypingIndicators = Self(rawValue: "chat.typing-indicators")
    static let chatFocusComposerOnTyping = Self(rawValue: "chat.focus-composer-on-typing")
    static let chatCharacterCounter = Self(rawValue: "chat.character-counter")
    static let chatDiscardConfirmationLink = Self(rawValue: "chat.discard-confirmation-link")
    static let chatReadAcknowledgement = Self(rawValue: "chat.read-acknowledgement")
    static let chatEditedMarkers = Self(rawValue: "chat.edited-markers")
    static let chatExpandEmbeds = Self(rawValue: "chat.expand-embeds")
    static let chatSpoilerReveal = Self(rawValue: "chat.spoiler-reveal")
    static let chatInternalDiscordLinks = Self(rawValue: "chat.internal-discord-links")
    static let chatAutoplayGIFs = Self(rawValue: "chat.autoplay-gifs")
    static let chatAutoplayStickers = Self(rawValue: "chat.autoplay-stickers")
    static let chatAutoplayVideos = Self(rawValue: "chat.autoplay-videos")
    static let chatLinkPreviews = Self(rawValue: "chat.link-previews")
    static let chatInlineMediaSize = Self(rawValue: "chat.inline-media-size")
    static let reduceAnimatedMedia = Self(rawValue: "chat.reduce-animated-media")
    static let chatEmojiSkinTone = Self(rawValue: "chat.emoji-skin-tone")
    static let chatEmojiSource = Self(rawValue: "chat.emoji-source")
    static let chatEmojiPrivacyLink = Self(rawValue: "chat.emoji-privacy-link")
    static let chatExport = Self(rawValue: "chat.export")
    static let chatReset = Self(rawValue: "chat.reset")
    static let updateReleaseTrack = Self(rawValue: "software-updates.release-track")
    static let updateAutomaticChecks = Self(rawValue: "software-updates.automatic-checks")
    static let updateAutomaticDownloads = Self(rawValue: "software-updates.automatic-downloads")
    static let checkForUpdates = Self(rawValue: "software-updates.check-now")
    static let updateChangelog = Self(rawValue: "software-updates.changelog")
    static let aboutVersionInformation = Self(rawValue: "about.version-information")
    static let aboutCheckForUpdates = Self(rawValue: "about.check-for-updates")
    static let aboutChangelog = Self(rawValue: "about.changelog")
    static let aboutWebsite = Self(rawValue: "about.website")
    static let aboutRoadmap = Self(rawValue: "about.roadmap")
    static let aboutSource = Self(rawValue: "about.source")
    static let aboutSupport = Self(rawValue: "about.support")
    static let aboutAcknowledgements = Self(rawValue: "about.acknowledgements")
    static let aboutDisclaimer = Self(rawValue: "about.disclaimer")
    static let localStorageLimit = Self(rawValue: "storage.local-storage-limit")
    static let localStorageUsage = Self(rawValue: "storage.local-storage-usage")
    static let mediaCacheClear = Self(rawValue: "storage.media-cache-clear")
    static let mediaCacheLastCleared = Self(rawValue: "storage.media-cache-last-cleared")
    static let downloadFolderBookmark = Self(rawValue: "storage.download-folder-bookmark")
    static let downloadFolderName = Self(rawValue: "storage.download-folder-name")
    static let revealCompletedDownloads = Self(rawValue: "storage.reveal-completed-downloads")
    static let clearAllAccountDrafts = Self(rawValue: "storage.clear-all-drafts")
    static let diagnosticsStatusOverview = Self(rawValue: "diagnostics.status-overview")
    static let diagnosticsRefresh = Self(rawValue: "diagnostics.refresh")
    static let diagnosticsSupportPreview = Self(rawValue: "diagnostics.support-preview")
    static let diagnosticsSupportCopy = Self(rawValue: "diagnostics.support-copy")
    static let diagnosticsSupportExport = Self(rawValue: "diagnostics.support-export")
    static let diagnosticsOpenFolder = Self(rawValue: "diagnostics.open-folder")
    static let notificationPermission = Self(rawValue: "notifications.system-permission")
    static let notificationEnabled = Self(rawValue: "notifications.enabled")
    static let notificationPreview = Self(rawValue: "notifications.preview")
    static let notificationSound = Self(rawValue: "notifications.sound")
    static let notificationDockBadge = Self(rawValue: "notifications.dock-badge")
    static let notificationFocus = Self(rawValue: "notifications.focus")
    static let notificationDirectMessages = Self(rawValue: "notifications.direct-messages")
    static let notificationGroupDirectMessages = Self(rawValue: "notifications.group-direct-messages")
    static let notificationMentions = Self(rawValue: "notifications.mentions")
    static let notificationReplies = Self(rawValue: "notifications.replies")
    static let notificationIncomingCalls = Self(rawValue: "notifications.incoming-calls")
    static let notificationServerActivity = Self(rawValue: "notifications.server-activity")
    static let notificationOnlyInBackground = Self(rawValue: "notifications.only-in-background")
    static let notificationSuppressCurrent = Self(rawValue: "notifications.suppress-current")
    static let notificationGroupBursts = Self(rawValue: "notifications.group-bursts")
    static let notificationClearWhenRead = Self(rawValue: "notifications.clear-when-read")
    static let notificationCallsBypassSuppression = Self(rawValue: "notifications.calls-bypass-suppression")
    static let notificationQuietHours = Self(rawValue: "notifications.quiet-hours")
    static let notificationQuietDays = Self(rawValue: "notifications.quiet-days")
    static let notificationQuietStart = Self(rawValue: "notifications.quiet-start")
    static let notificationQuietEnd = Self(rawValue: "notifications.quiet-end")
    static let notificationWeekendQuietStart = Self(rawValue: "notifications.weekend-quiet-start")
    static let notificationWeekendQuietEnd = Self(rawValue: "notifications.weekend-quiet-end")
    static let notificationAllowDirectMessages = Self(rawValue: "notifications.allow-direct-messages")
    static let notificationAllowCalls = Self(rawValue: "notifications.allow-calls")
    static let notificationDiscordOwnership = Self(rawValue: "notifications.discord-ownership")
    static let notificationExport = Self(rawValue: "notifications.export")
    static let notificationReset = Self(rawValue: "notifications.reset")
    static let voiceInputDevice = Self(rawValue: "voice-video.input-device")
    static let voiceOutputDevice = Self(rawValue: "voice-video.output-device")
    static let voiceCamera = Self(rawValue: "voice-video.camera")
    static let voiceInputVolume = Self(rawValue: "voice-video.input-volume")
    static let voiceOutputVolume = Self(rawValue: "voice-video.output-volume")
    static let voiceRefreshDevices = Self(rawValue: "voice-video.refresh-devices")
    static let voiceMicrophoneTest = Self(rawValue: "voice-video.microphone-test")
    static let voiceSpeakerTest = Self(rawValue: "voice-video.speaker-test")
    static let voiceJoinMuted = Self(rawValue: "voice-video.join-muted")
    static let voiceJoinDeafened = Self(rawValue: "voice-video.join-deafened")
    static let voiceFeedbackSounds = Self(rawValue: "voice-video.feedback-sounds")
    static let voiceCameraPreview = Self(rawValue: "voice-video.camera-preview")
    static let voiceMirrorPreview = Self(rawValue: "voice-video.mirror-preview")
    static let voiceRememberCamera = Self(rawValue: "voice-video.remember-camera")
    static let voiceJoinCameraOff = Self(rawValue: "voice-video.join-camera-off")
    static let voiceScreenShareQuality = Self(rawValue: "voice-video.share-quality")
    static let voiceScreenShareFrameRate = Self(rawValue: "voice-video.share-frame-rate")
    static let voiceScreenShareAudio = Self(rawValue: "voice-video.share-audio")
    static let voiceScreenSharePointer = Self(rawValue: "voice-video.share-pointer")
    static let voiceMicrophonePermission = Self(rawValue: "voice-video.microphone-permission")
    static let voiceCameraPermission = Self(rawValue: "voice-video.camera-permission")
    static let voiceScreenPermission = Self(rawValue: "voice-video.screen-permission")
    static let voiceExport = Self(rawValue: "voice-video.export")
    static let voiceReset = Self(rawValue: "voice-video.reset")
    static let accessibilityMotionOverride = Self(rawValue: "accessibility.motion-override")
    static let accessibilityReduceAnimatedContent = Self(rawValue: "accessibility.reduce-animated-content")
    static let accessibilityReduceAnimatedEmoji = Self(rawValue: "accessibility.reduce-animated-emoji")
    static let accessibilityReduceAnimatedStickers = Self(rawValue: "accessibility.reduce-animated-stickers")
    static let accessibilityReduceGIFs = Self(rawValue: "accessibility.reduce-gifs")
    static let accessibilityReduceAnimatedAvatars = Self(rawValue: "accessibility.reduce-animated-avatars")
    static let accessibilityReduceDecorations = Self(rawValue: "accessibility.reduce-decorations")
    static let accessibilityReduceTransitions = Self(rawValue: "accessibility.reduce-transitions")
    static let accessibilityIncreaseContrast = Self(rawValue: "accessibility.increase-contrast")
    static let accessibilityLargerTargets = Self(rawValue: "accessibility.larger-targets")
    static let accessibilityUnderlineLinks = Self(rawValue: "accessibility.underline-links")
    static let accessibilityMessageActions = Self(rawValue: "accessibility.message-actions")
    static let accessibilityAnnounceTimestamp = Self(rawValue: "accessibility.announce-timestamp")
    static let accessibilityAnnounceEdited = Self(rawValue: "accessibility.announce-edited")
    static let accessibilityAnnounceReactions = Self(rawValue: "accessibility.announce-reactions")
    static let accessibilityAnnounceAttachmentTypes = Self(rawValue: "accessibility.announce-attachment-types")
    static let accessibilityAnnounceNewMessages = Self(rawValue: "accessibility.announce-new-messages")
    static let accessibilityExport = Self(rawValue: "accessibility.export")
    static let accessibilityReset = Self(rawValue: "accessibility.reset")
    static let shortcutExport = Self(rawValue: "keyboard-shortcuts.export")
    static let shortcutReset = Self(rawValue: "keyboard-shortcuts.reset")
    static let privacyTypingIndicators = Self(rawValue: "privacy.typing-indicators")
    static let privacyReadAcknowledgements = Self(rawValue: "privacy.read-acknowledgements")
    static let externalLinkProtection = Self(rawValue: "privacy.external-link-protection")
    static let trustedDomains = Self(rawValue: "privacy.trusted-domains")
    static let clearMessageSearches = Self(rawValue: "privacy.clear-message-searches")
    static let clearDestinationHistory = Self(rawValue: "privacy.clear-destination-history")
    static let clearEmojiRanking = Self(rawValue: "privacy.clear-emoji-ranking")
    static let clearDrafts = Self(rawValue: "privacy.clear-drafts")
    static let privacyNotificationPreviews = Self(rawValue: "privacy.notification-previews")
    static let privacyExport = Self(rawValue: "privacy.export")
    static let privacyReset = Self(rawValue: "privacy.reset")
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
            .appearance, group: .preferences, title: "Appearance", image: "circle.lefthalf.filled",
            help: "Choose how SakuraCord's interface looks.",
            keywords: ["appearance", "look", "style", "accent", "color", "theme"]
        ),
        page(
            .interface, group: .preferences, title: "Interface", image: "macwindow",
            help: "Choose message appearance, timestamps, grouping, links, member-list, and role presentation.",
            keywords: ["messages", "bubbles", "density", "composer", "input bar", "clock", "timestamp", "roles", "member list", "links", "grouping", "message actions"]
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
            help: "Choose call devices, levels, tests, and share defaults.",
            keywords: ["microphone", "speaker", "camera", "audio", "video", "screen share"]
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
            .privacySafety, group: .dataSecurity, title: "Privacy", image: "hand.raised",
            help: "Control local privacy, external links, and scoped data clearing.",
            keywords: ["links", "security", "typing indicators", "read receipts", "clear data"]
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
            .softwareUpdates, group: .sakuraCord, title: "Updates", image: "arrow.triangle.2.circlepath",
            help: "Manage signed SakuraCord update checks, downloads, and release tracks.",
            keywords: ["update", "release", "regular", "nightly", "Sparkle", "version"]
        ),
        page(
            .extensions, group: .sakuraCord, title: "Extensions", image: "puzzlepiece.extension",
            help: "Learn about SakuraCord's future sandboxed extension system.",
            keywords: ["plugins", "permissions", "sandbox", "sandboxing", "SDK", "host"]
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
            .appColorScheme,
            page: .appearance,
            section: .appearanceTheme,
            label: "Appearance",
            help: "Follow the system appearance or choose SakuraCord's light or dark appearance.",
            keywords: ["appearance", "theme", "system", "light", "dark", "mode", "sun", "moon"],
            scope: .appWideLocal
        ),
        control(
            .themeDesigner,
            page: .appearance,
            section: .appearanceTheme,
            label: "Theme Designer",
            help: "Create a theme with color, intensity, brightness, and randomisation controls.",
            keywords: ["gradient", "theme", "designer", "color", "intensity", "brightness", "randomise"],
            scope: .appWideLocal
        ),
        control(
            .messageAppearance,
            page: .interface,
            section: .interfaceMessages,
            label: "Messages",
            help: "Choose SakuraCord's default message layout or conversation bubbles.",
            keywords: ["messages", "bubbles", "iMessage", "chat", "layout", "default"],
            scope: .appWideLocal
        ),
        control(
            .messageDensity,
            page: .interface,
            section: .interfaceMessages,
            label: "Density",
            help: "Adjust the vertical spacing between messages.",
            keywords: ["messages", "density", "spacing", "compact", "comfortable"],
            scope: .appWideLocal
        ),
        control(
            .composerBarAppearance,
            page: .interface,
            section: .interfaceMessages,
            label: "Input bar",
            help: "Choose the current split input bar or SakuraCord's legacy unified input bar.",
            keywords: ["composer", "message input", "default", "legacy", "pill"],
            scope: .appWideLocal
        ),
        control(
            .resetMessageAppearance,
            page: .interface,
            section: .interfaceMessages,
            label: "Reset to Defaults",
            help: "Restore the default message layout, density, and input bar without changing other Interface settings.",
            keywords: ["messages", "defaults", "restore", "reset", "density", "input bar"],
            scope: .appWideLocal,
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
            page: .chat,
            section: .chatComposer,
            label: "Press Return to send messages",
            help: "Choose whether Return sends and Shift-Return inserts a newline, or Return inserts a newline and Command-Return sends.",
            keywords: ["enter", "newline", "composer", "command return", "shift return"],
            scope: .appWideLocal
        ),
        control(
            .chatSpellCheck, page: .chat, section: .chatComposer,
            label: "Check spelling while typing",
            help: "Use AppKit's continuous spell checker in the real message composer.",
            keywords: ["spellcheck", "spelling", "typo"], scope: .appWideLocal
        ),
        control(
            .chatAutomaticCorrection, page: .chat, section: .chatComposer,
            label: "Correct spelling automatically",
            help: "Allow the native text system to apply spelling corrections in the composer.",
            keywords: ["autocorrect", "correction", "typing"], scope: .appWideLocal
        ),
        control(
            .chatSmartQuotes, page: .chat, section: .chatComposer,
            label: "Smart quotes",
            help: "Allow the native text system to substitute typographic quotation marks.",
            keywords: ["curly quotes", "quotation", "substitution"], scope: .appWideLocal
        ),
        control(
            .chatSmartDashes, page: .chat, section: .chatComposer,
            label: "Smart dashes",
            help: "Allow the native text system to substitute typographic dashes.",
            keywords: ["em dash", "hyphen", "substitution"], scope: .appWideLocal
        ),
        control(
            .chatTypingIndicators, page: .chat, section: .chatComposer,
            label: "Send typing indicators",
            help: "Tell Discord when you are composing a normal message. Disabling this cancels pending local typing signals.",
            keywords: ["typing status", "privacy", "indicator"], scope: .appWideLocal
        ),
        control(
            .chatFocusComposerOnTyping, page: .chat, section: .chatComposer,
            label: "Focus composer when typing begins",
            help: "Move printable typing to the composer only when another editable field, menu, overlay, or assisted interaction does not own input.",
            keywords: ["type to focus", "keyboard", "first responder"], scope: .appWideLocal
        ),
        control(
            .chatCharacterCounter, page: .chat, section: .chatComposer,
            label: "Character limit",
            help: "Show the live character count only within 200 characters of the effective Discord message limit.",
            keywords: ["2000", "4000", "counter", "length"], owner: .appModel,
            scope: .mixed, persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .chatDiscardConfirmationLink, page: .chat, section: .chatComposer,
            label: "Composer discard confirmation",
            help: "Open the single confirmation preference in General Settings.",
            keywords: ["draft", "unsent", "confirm", "discard"],
            scope: .appWideLocal, persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .chatReadAcknowledgement, page: .chat, section: .chatMessages,
            label: "Mark messages read",
            help: "Automatically acknowledge meaningfully visible content or wait for an explicit Mark Read action. Discord synchronizes the unread result to other clients.",
            keywords: ["read receipt", "ack", "unread", "manual", "read state"],
            scope: .appWideLocal
        ),
        control(
            .chatEditedMarkers, page: .chat, section: .chatMessages,
            label: "Show edited markers",
            help: "Show Discord's edited state beside message timestamps.",
            keywords: ["modified", "timestamp", "edited"], scope: .appWideLocal
        ),
        control(
            .chatExpandEmbeds, page: .chat, section: .chatMessages,
            label: "Expand embeds by default",
            help: "Show rich Discord embeds in the timeline by default.",
            keywords: ["collapse", "rich embed", "card"], scope: .appWideLocal
        ),
        control(
            .chatSpoilerReveal, page: .chat, section: .chatMessages,
            label: "Reveal spoilers",
            help: "Reveal spoilers with a click, only with Option-click, or without concealment.",
            keywords: ["hidden content", "option click", "always reveal"], scope: .appWideLocal
        ),
        control(
            .chatInternalDiscordLinks, page: .chat, section: .chatMessages,
            label: "Open Discord links in SakuraCord",
            help: "Navigate resolvable Discord channel links internally; other links continue to use the system browser.",
            keywords: ["discord.com/channels", "internal link", "browser"], scope: .appWideLocal
        ),
        control(
            .chatAutoplayGIFs, page: .chat, section: .chatMedia,
            label: "Autoplay GIFs",
            help: "Animate inline GIF and animated-image media when motion is permitted.",
            keywords: ["animated images", "GIF", "playback"], scope: .appWideLocal
        ),
        control(
            .chatAutoplayStickers, page: .chat, section: .chatMedia,
            label: "Autoplay animated stickers",
            help: "Animate APNG, GIF, and Lottie stickers when motion is permitted.",
            keywords: ["sticker animation", "Lottie", "APNG"], scope: .appWideLocal
        ),
        control(
            .chatAutoplayVideos, page: .chat, section: .chatMedia,
            label: "Autoplay inline videos",
            help: "Play Discord GIFV and other explicitly inline-autoplay video previews when motion is permitted.",
            keywords: ["video playback", "GIFV", "loop"], scope: .appWideLocal
        ),
        control(
            .chatLinkPreviews, page: .chat, section: .chatMedia,
            label: "Show automatic link previews",
            help: "Show Discord-generated preview embeds for links in message content.",
            keywords: ["unfurl", "URL preview", "rich link"], scope: .appWideLocal
        ),
        control(
            .chatInlineMediaSize, page: .chat, section: .chatMedia,
            label: "Inline media size",
            help: "Bound inline media to a compact, medium, or large Mac-appropriate width.",
            keywords: ["image size", "attachment width", "preview size"], scope: .appWideLocal
        ),
        control(
            .reduceAnimatedMedia,
            page: .chat,
            section: .chatMedia,
            label: "Reduce animated media",
            help: "Pause optional animated media. macOS Reduce Motion and the broader Accessibility preference take precedence.",
            keywords: ["GIF", "animation", "motion", "reduce motion", "Accessibility"],
            scope: .appWideLocal
        ),
        control(
            .chatEmojiSkinTone, page: .chat, section: .chatEmoji,
            label: "Default emoji skin tone",
            help: "Choose the app-wide skin-tone modifier used by the native emoji picker.",
            keywords: ["modifier", "hand", "tone", "emoji"], scope: .appWideLocal
        ),
        control(
            .chatEmojiSource, page: .chat, section: .chatEmoji,
            label: "Emoji favorites and frequency",
            help: "Report whether Discord-synchronized ordering or SakuraCord's local fallback is currently available.",
            keywords: ["favorites", "frequent", "frecency", "source"], owner: .appModel,
            scope: .mixed, persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .chatEmojiPrivacyLink, page: .chat, section: .chatEmoji,
            label: "Manage Local Emoji Data",
            help: "Open Privacy to clear SakuraCord's local emoji recents and learned ranking.",
            keywords: ["recent emoji", "history", "frequency", "ranking", "clear"],
            owner: .appModel, scope: .appWideLocal, persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .chatExport, page: .chat, section: .chatLocalData,
            label: "Export Chat Settings",
            help: "Export registered app-wide Chat preferences as versioned JSON.",
            keywords: ["backup", "JSON", "save preferences"],
            scope: .appWideLocal, persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .chatReset, page: .chat, section: .chatLocalData,
            label: "Reset Chat Settings",
            help: "Restore registered Chat preferences without changing drafts, credentials, or Discord state.",
            keywords: ["defaults", "restore", "clear chat preferences"],
            scope: .appWideLocal, persistence: .appPreferences, reset: .categoryAction
        ),
        control(
            .updateReleaseTrack,
            page: .softwareUpdates,
            section: .softwareUpdates,
            label: "Release track",
            help: "Choose the signed Regular or Nightly update feed.",
            keywords: ["regular", "nightly", "channel"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .updateAutomaticChecks,
            page: .softwareUpdates,
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
            page: .softwareUpdates,
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
            .checkForUpdates,
            page: .softwareUpdates,
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
            .updateChangelog,
            page: .softwareUpdates,
            section: .softwareUpdates,
            label: "Open Changelog",
            help: "Show the release notes included with SakuraCord.",
            keywords: ["release notes", "version history"],
            scope: .appWideLocal,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .localStorageLimit,
            page: .storageDownloads,
            section: .localStorage,
            label: "Local Storage Limit",
            help: "Set the shared maximum size for drafts and disposable media.",
            keywords: ["disk", "storage", "limit", "drafts", "media"],
            scope: .appWideLocal
        ),
        control(
            .localStorageUsage, page: .storageDownloads, section: .localStorage,
            label: "Local Storage Usage",
            help: "Measure the combined space used by drafts and disposable media.",
            keywords: ["bytes", "size", "drafts", "media"], owner: .appModel,
            scope: .appWideLocal, persistence: .sessionOnly, reset: .notApplicable
        ),
        control(
            .mediaCacheClear, page: .storageDownloads, section: .localStorage,
            label: "Clear Media Cache",
            help: "Clear disposable disk media after confirmation without removing visible in-memory media.",
            keywords: ["delete", "purge", "free space"], owner: .appModel,
            scope: .appWideLocal, persistence: .notApplicable, reset: .categoryAction
        ),
        control(
            .downloadFolderName, page: .storageDownloads,
            section: .storageDownloads, label: "Default Download Folder",
            help: "Choose the sandbox-authorized default folder used by direct media saves.",
            keywords: ["directory", "location", "choose"], owner: .macOS,
            scope: .appWideLocal, persistence: .appPreferences,
            reset: .categoryAction
        ),
        control(
            .revealCompletedDownloads, page: .storageDownloads,
            section: .storageDownloads, label: "Reveal Completed Downloads",
            help: "Select successfully saved media in Finder.",
            keywords: ["Finder", "show", "completed"], scope: .appWideLocal
        ),
        control(
            .clearAllAccountDrafts, page: .storageDownloads,
            section: .localStorage, label: "Clear Drafts",
            help: "Delete local drafts for every saved account after confirmation and return their allocation to the media cache.",
            keywords: ["delete", "unsent", "all accounts"], owner: .appModel,
            scope: .mixed, persistence: .notApplicable, reset: .categoryAction
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
            scope: .appWideLocal
        ),
        control(
            .notificationPreview,
            page: .notifications,
            section: .notificationDelivery,
            label: "Notification previews",
            help: "Choose how much message information appears in notifications.",
            keywords: ["sender", "hidden", "privacy"],
            scope: .appWideLocal
        ),
        control(
            .notificationSound,
            page: .notifications,
            section: .notificationDelivery,
            label: "Play sound",
            help: "Use Notification Center's standard sound so macOS sound and Focus policy remain authoritative.",
            keywords: ["audio", "alert", "Focus"],
            scope: .appWideLocal
        ),
        control(
            .notificationDockBadge,
            page: .notifications,
            section: .notificationDelivery,
            label: "Dock badge",
            help: "Show unread mentions, reliably projected unread conversations, or no Dock badge.",
            keywords: ["badge", "mentions", "unread conversations", "off"],
            scope: .appWideLocal
        ),
        control(
            .notificationFocus, page: .notifications, section: .notificationDelivery,
            label: "macOS Focus",
            help: "SakuraCord uses standard active notifications and never elevates messages or calls above the user's Focus policy.",
            keywords: ["Do Not Disturb", "DND", "interruption level", "system"],
            owner: .macOS, scope: .appWideLocal,
            persistence: .systemManaged, reset: .notApplicable
        ),
        control(
            .notificationDirectMessages, page: .notifications, section: .notificationEvents,
            label: "Direct messages", help: "Allow eligible one-to-one direct messages.",
            keywords: ["DM", "private message"], scope: .appWideLocal
        ),
        control(
            .notificationGroupDirectMessages, page: .notifications,
            section: .notificationEvents, label: "Group direct messages",
            help: "Allow eligible group-DM messages.",
            keywords: ["group DM", "private group"], scope: .appWideLocal
        ),
        control(
            .notificationMentions, page: .notifications, section: .notificationEvents,
            label: "Mentions", help: "Allow eligible direct, role, and everyone mentions.",
            keywords: ["@mention", "role", "everyone"], scope: .appWideLocal
        ),
        control(
            .notificationReplies, page: .notifications, section: .notificationEvents,
            label: "Replies", help: "Allow eligible replies to one of your messages.",
            keywords: ["reply", "response"], scope: .appWideLocal
        ),
        control(
            .notificationIncomingCalls, page: .notifications, section: .notificationEvents,
            label: "Incoming calls", help: "Allow native alerts for newly ringing private calls.",
            keywords: ["call", "ring", "voice"], scope: .appWideLocal
        ),
        control(
            .notificationServerActivity, page: .notifications, section: .notificationEvents,
            label: "Server activity", help: "Allow ordinary server messages already eligible under Discord's notification settings.",
            keywords: ["guild", "all messages", "server"], scope: .appWideLocal
        ),
        control(
            .notificationOnlyInBackground, page: .notifications,
            section: .notificationEvents, label: "Notify only in the background",
            help: "Suppress ordinary alerts while SakuraCord is active.",
            keywords: ["foreground", "active app", "background"], scope: .appWideLocal
        ),
        control(
            .notificationSuppressCurrent, page: .notifications,
            section: .notificationEvents, label: "Suppress the current conversation",
            help: "Do not alert for a conversation already presented at its newest message.",
            keywords: ["open channel", "visible", "current chat"], scope: .appWideLocal
        ),
        control(
            .notificationGroupBursts, page: .notifications,
            section: .notificationEvents, label: "Group bursts by conversation",
            help: "Assign a native Notification Center thread to each account and conversation.",
            keywords: ["thread", "stack", "deduplicate", "group"], scope: .appWideLocal
        ),
        control(
            .notificationClearWhenRead, page: .notifications,
            section: .notificationEvents, label: "Clear notifications when read",
            help: "Remove delivered and pending message notifications when their conversation is acknowledged.",
            keywords: ["dismiss", "mark read", "remove delivered"], scope: .appWideLocal
        ),
        control(
            .notificationCallsBypassSuppression, page: .notifications,
            section: .notificationEvents, label: "Let calls bypass message suppression",
            help: "Allow enabled calls through background-only and current-conversation suppression. Quiet hours and macOS Focus still apply.",
            keywords: ["call exception", "urgent", "foreground"], scope: .appWideLocal
        ),
        control(
            .notificationQuietHours,
            page: .notifications,
            section: .notificationQuietHours,
            label: "Quiet hours",
            help: "Suppress ordinary local notifications during a configured time range.",
            keywords: ["schedule", "do not disturb"],
            scope: .appWideLocal
        ),
        control(
            .notificationQuietDays, page: .notifications,
            section: .notificationQuietHours, label: "Enabled days",
            help: "Choose the local calendar days on which quiet hours begin.",
            keywords: ["Monday", "weekdays", "weekend", "calendar"], scope: .appWideLocal
        ),
        control(
            .notificationQuietStart,
            page: .notifications,
            section: .notificationQuietHours,
            label: "Weekday quiet start",
            help: "Choose when Monday-through-Friday quiet hours begin.",
            keywords: ["schedule", "start time", "weekday"], scope: .appWideLocal
        ),
        control(
            .notificationQuietEnd,
            page: .notifications,
            section: .notificationQuietHours,
            label: "Weekday quiet end",
            help: "Choose when Monday-through-Friday quiet hours end.",
            keywords: ["schedule", "end time", "weekday"], scope: .appWideLocal
        ),
        control(
            .notificationWeekendQuietStart, page: .notifications,
            section: .notificationQuietHours, label: "Weekend quiet start",
            help: "Choose when Saturday-and-Sunday quiet hours begin.",
            keywords: ["schedule", "start time", "weekend"], scope: .appWideLocal
        ),
        control(
            .notificationWeekendQuietEnd, page: .notifications,
            section: .notificationQuietHours, label: "Weekend quiet end",
            help: "Choose when Saturday-and-Sunday quiet hours end.",
            keywords: ["schedule", "end time", "weekend"], scope: .appWideLocal
        ),
        control(
            .notificationAllowDirectMessages, page: .notifications,
            section: .notificationQuietHours, label: "Allow direct messages",
            help: "Let enabled direct-message and group-DM events through quiet hours.",
            keywords: ["quiet exception", "DM"], scope: .appWideLocal
        ),
        control(
            .notificationAllowCalls, page: .notifications,
            section: .notificationQuietHours, label: "Allow incoming calls",
            help: "Let enabled incoming-call alerts through quiet hours.",
            keywords: ["quiet exception", "ring"], scope: .appWideLocal
        ),
        control(
            .notificationDiscordOwnership, page: .notifications,
            section: .notificationEvents, label: "Discord notification controls",
            help: "Server, category, channel, mention-suppression, and mute-duration controls remain in their existing context menus and synchronize through Discord.",
            keywords: ["server mute", "channel mute", "notification level", "right click"],
            owner: .discord, scope: .discordSynchronized,
            persistence: .discordManaged, reset: .notApplicable
        ),
        control(
            .notificationExport, page: .notifications,
            section: .notificationLocalData, label: "Export Notification Settings",
            help: "Export registered app-wide Notification preferences as versioned JSON.",
            keywords: ["backup", "JSON", "save preferences"], scope: .appWideLocal,
            persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .notificationReset, page: .notifications,
            section: .notificationLocalData, label: "Reset Notification Settings",
            help: "Restore SakuraCord's local Notification preferences without changing macOS authorization or Discord settings.",
            keywords: ["defaults", "restore", "clear preferences"], scope: .appWideLocal,
            persistence: .appPreferences, reset: .categoryAction
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
            .voiceRefreshDevices, page: .voiceVideo, section: .voiceDevices,
            label: "Refresh devices",
            help: "Rescan microphones, speakers, and cameras and recover unavailable saved routes.",
            keywords: ["rescan", "missing device", "fallback"],
            owner: .appModel, scope: .appWideLocal,
            persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .voiceMicrophoneTest, page: .voiceVideo, section: .voiceLevels,
            label: "Test microphone",
            help: "Show the selected microphone’s live level without recording or retaining samples.",
            keywords: ["mic check", "meter", "input test"],
            owner: .appModel, scope: .appWideLocal,
            persistence: .sessionOnly, reset: .notApplicable
        ),
        control(
            .voiceSpeakerTest, page: .voiceVideo, section: .voiceLevels,
            label: "Test speaker",
            help: "Play a temporary test tone through the selected output until stopped.",
            keywords: ["headphones", "output test", "tone"],
            owner: .appModel, scope: .appWideLocal,
            persistence: .sessionOnly, reset: .notApplicable
        ),
        control(
            .voiceJoinMuted, page: .voiceVideo, section: .voiceCallDefaults,
            label: "Join calls muted",
            help: "Start the next call with microphone transmission muted without changing the current call.",
            keywords: ["mute on join", "microphone default"], scope: .appWideLocal
        ),
        control(
            .voiceJoinDeafened, page: .voiceVideo, section: .voiceCallDefaults,
            label: "Join calls deafened",
            help: "Start the next call with call playback deafened without changing the current call.",
            keywords: ["deafen on join", "speaker default"], scope: .appWideLocal
        ),
        control(
            .voiceFeedbackSounds, page: .voiceVideo, section: .voiceCallDefaults,
            label: "Play call feedback sounds",
            help: "Play local sounds for joins, leaves, mute, deafen, video, and sharing events.",
            keywords: ["join sound", "leave sound", "mute sound"], scope: .appWideLocal
        ),
        control(
            .voiceCameraPreview, page: .voiceVideo, section: .voiceCamera,
            label: "Camera preview",
            help: "Preview the selected camera locally until the preview is explicitly stopped.",
            keywords: ["webcam test", "video preview"],
            owner: .appModel, scope: .appWideLocal,
            persistence: .sessionOnly, reset: .notApplicable
        ),
        control(
            .voiceMirrorPreview, page: .voiceVideo, section: .voiceCamera,
            label: "Mirror my local preview",
            help: "Mirror only the local self-view; transmitted video remains unchanged.",
            keywords: ["flip camera", "self view"], scope: .appWideLocal
        ),
        control(
            .voiceRememberCamera, page: .voiceVideo, section: .voiceCamera,
            label: "Remember selected camera",
            help: "Restore the selected camera on the next launch; disabling this removes the saved camera identifier.",
            keywords: ["save camera", "forget webcam"], scope: .appWideLocal
        ),
        control(
            .voiceJoinCameraOff, page: .voiceVideo, section: .voiceCamera,
            label: "Join calls with camera off",
            help: "Keep video off when entering the next call without changing the current camera state.",
            keywords: ["video off", "camera on join"], scope: .appWideLocal
        ),
        control(
            .voiceScreenShareQuality, page: .voiceVideo, section: .voiceScreenShare,
            label: "Screen share quality",
            help: "Choose the initial resolution target for the next screen share.",
            keywords: ["720p", "1080p", "1440p", "source"], scope: .appWideLocal
        ),
        control(
            .voiceScreenShareFrameRate, page: .voiceVideo, section: .voiceScreenShare,
            label: "Screen share frame rate",
            help: "Choose the initial frame rate for the next screen share.",
            keywords: ["FPS", "15", "30", "60"], scope: .appWideLocal
        ),
        control(
            .voiceScreenShareAudio, page: .voiceVideo, section: .voiceScreenShare,
            label: "Include system audio",
            help: "Include system audio by default when preparing the next share.",
            keywords: ["share sound", "capture audio"], scope: .appWideLocal
        ),
        control(
            .voiceScreenSharePointer, page: .voiceVideo, section: .voiceScreenShare,
            label: "Show pointer",
            help: "Include the pointer by default in the next screen-share capture.",
            keywords: ["cursor", "mouse"], scope: .appWideLocal
        ),
        control(
            .voiceMicrophonePermission, page: .voiceVideo, section: .voicePermissions,
            label: "Microphone permission",
            help: "Report the microphone authorization currently managed by macOS.",
            keywords: ["privacy", "permission", "denied"],
            owner: .macOS, scope: .appWideLocal,
            persistence: .systemManaged, reset: .notApplicable
        ),
        control(
            .voiceCameraPermission, page: .voiceVideo, section: .voicePermissions,
            label: "Camera permission",
            help: "Report the camera authorization currently managed by macOS.",
            keywords: ["privacy", "webcam permission", "denied"],
            owner: .macOS, scope: .appWideLocal,
            persistence: .systemManaged, reset: .notApplicable
        ),
        control(
            .voiceScreenPermission, page: .voiceVideo, section: .voicePermissions,
            label: "Screen recording permission",
            help: "Report whether macOS currently permits screen and system-audio capture.",
            keywords: ["privacy", "screen recording", "system audio"],
            owner: .macOS, scope: .appWideLocal,
            persistence: .systemManaged, reset: .notApplicable
        ),
        control(
            .voiceExport, page: .voiceVideo, section: .voiceLocalData,
            label: "Export Voice & Video Settings",
            help: "Export registered app-wide Voice & Video preferences as versioned JSON.",
            keywords: ["backup", "JSON", "save preferences"], scope: .appWideLocal,
            persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .voiceReset, page: .voiceVideo, section: .voiceLocalData,
            label: "Reset Voice & Video Settings",
            help: "Restore local call and share defaults without changing macOS permissions or live call controls.",
            keywords: ["defaults", "restore", "clear preferences"], scope: .appWideLocal,
            persistence: .appPreferences, reset: .categoryAction
        ),
        control(
            .accessibilityMotionOverride, page: .accessibility,
            section: .accessibilityMotion, label: "Motion preference",
            help: "Follow macOS Reduce Motion or always reduce optional motion in SakuraCord.",
            keywords: ["system setting", "override", "reduce motion", "animation"],
            scope: .appWideLocal
        ),
        control(
            .accessibilityReduceAnimatedContent, page: .accessibility,
            section: .accessibilityMotion, label: "Reduce animated content",
            help: "Pause all optional animated content while preserving static previews and controls.",
            keywords: ["master", "animation", "pause media", "motion"],
            scope: .appWideLocal
        ),
        control(
            .accessibilityReduceAnimatedEmoji, page: .accessibility,
            section: .accessibilityMotion, label: "Reduce animated emoji",
            help: "Pause animated custom emoji in messages, reactions, pickers, and member activity.",
            keywords: ["custom emoji", "reaction", "activity"], scope: .appWideLocal
        ),
        control(
            .accessibilityReduceAnimatedStickers, page: .accessibility,
            section: .accessibilityMotion, label: "Reduce animated stickers",
            help: "Pause animated image and Lottie stickers while retaining their first frame.",
            keywords: ["Lottie", "APNG", "sticker animation"], scope: .appWideLocal
        ),
        control(
            .accessibilityReduceGIFs, page: .accessibility,
            section: .accessibilityMotion, label: "Reduce GIFs and animated images",
            help: "Pause GIF, APNG, and animated-image playback in content and pickers.",
            keywords: ["GIF", "APNG", "animated image"], scope: .appWideLocal
        ),
        control(
            .accessibilityReduceAnimatedAvatars, page: .accessibility,
            section: .accessibilityMotion, label: "Reduce animated avatars",
            help: "Pause animated user and application avatars.",
            keywords: ["profile picture", "user icon"], scope: .appWideLocal
        ),
        control(
            .accessibilityReduceDecorations, page: .accessibility,
            section: .accessibilityMotion, label: "Reduce profile decorations",
            help: "Pause animated avatar decorations, banners, and nameplates.",
            keywords: ["avatar decoration", "banner", "nameplate"], scope: .appWideLocal
        ),
        control(
            .accessibilityReduceTransitions, page: .accessibility,
            section: .accessibilityMotion, label: "Reduce nonessential transitions",
            help: "Present SakuraCord overlays and ornamental state changes without animated transitions.",
            keywords: ["overlay", "fade", "window animation"], scope: .appWideLocal
        ),
        control(
            .accessibilityIncreaseContrast, page: .accessibility,
            section: .accessibilityReadability, label: "Increase contrast",
            help: "Increase separation between colors in SakuraCord's rendered native interface when macOS is using standard contrast.",
            keywords: ["readability", "high contrast", "semantic colors"], scope: .appWideLocal
        ),
        control(
            .accessibilityLargerTargets, page: .accessibility,
            section: .accessibilityReadability, label: "Use larger message action targets",
            help: "Increase the hit area of compact message action controls without duplicating their commands.",
            keywords: ["button size", "motor", "click target", "toolbar"], scope: .appWideLocal
        ),
        control(
            .accessibilityUnderlineLinks, page: .accessibility,
            section: .accessibilityReadability, label: "Underline links",
            help: "Open the canonical Interface control for link underlining.",
            keywords: ["hyperlink", "URL", "not color alone"], owner: .appModel,
            scope: .appWideLocal, persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .accessibilityMessageActions, page: .accessibility,
            section: .accessibilityReadability, label: "Always-visible message actions",
            help: "Open the canonical Interface control for message action visibility.",
            keywords: ["hover", "reply", "toolbar", "visible controls"], owner: .appModel,
            scope: .appWideLocal, persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .accessibilityAnnounceTimestamp, page: .accessibility,
            section: .accessibilityVoiceOver, label: "Include timestamps",
            help: "Include each message timestamp in its VoiceOver row summary.",
            keywords: ["VoiceOver", "time", "message metadata"], scope: .appWideLocal
        ),
        control(
            .accessibilityAnnounceEdited, page: .accessibility,
            section: .accessibilityVoiceOver, label: "Include edited status",
            help: "Announce when a message has been edited.",
            keywords: ["VoiceOver", "modified", "message metadata"], scope: .appWideLocal
        ),
        control(
            .accessibilityAnnounceReactions, page: .accessibility,
            section: .accessibilityVoiceOver, label: "Include reaction counts",
            help: "Include the total reaction count in a message's VoiceOver row summary.",
            keywords: ["VoiceOver", "emoji", "reaction metadata"], scope: .appWideLocal
        ),
        control(
            .accessibilityAnnounceAttachmentTypes, page: .accessibility,
            section: .accessibilityVoiceOver, label: "Include attachment types",
            help: "Summarize image, video, audio, and file attachment types for VoiceOver.",
            keywords: ["VoiceOver", "media", "file type"], scope: .appWideLocal
        ),
        control(
            .accessibilityAnnounceNewMessages, page: .accessibility,
            section: .accessibilityVoiceOver, label: "Announce new messages",
            help: "While VoiceOver is running, announce grouped incoming-message counts without speaking message content or sender identity.",
            keywords: ["VoiceOver", "live messages", "privacy", "throttle"], scope: .appWideLocal
        ),
        control(
            .accessibilityExport, page: .accessibility,
            section: .accessibilityLocalData, label: "Export Accessibility Settings",
            help: "Export registered app-wide Accessibility preferences as versioned JSON.",
            keywords: ["backup", "JSON", "save preferences"], scope: .appWideLocal,
            persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .accessibilityReset, page: .accessibility,
            section: .accessibilityLocalData, label: "Reset Accessibility Settings",
            help: "Restore SakuraCord accessibility preferences without changing macOS accessibility settings.",
            keywords: ["defaults", "restore", "system settings"], scope: .appWideLocal,
            persistence: .appPreferences, reset: .categoryAction
        ),
        control(
            .diagnosticsStatusOverview,
            page: .diagnostics,
            section: .diagnosticsStatus,
            label: "Subsystem Status",
            help: "Show current non-identifying account, Gateway, voice, device, notification, cache, update, and permission health.",
            keywords: ["health", "connection", "Gateway", "voice", "permissions"],
            owner: .appModel,
            scope: .mixed,
            persistence: .sessionOnly,
            reset: .notApplicable
        ),
        control(
            .diagnosticsRefresh,
            page: .diagnostics,
            section: .diagnosticsStatus,
            label: "Refresh Status",
            help: "Refresh system permissions, selected-device availability, notification authorization, cache state, and log count without polling.",
            keywords: ["reload", "checking", "current"],
            owner: .appModel,
            scope: .mixed,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .diagnosticsSupportPreview,
            page: .diagnostics,
            section: .diagnosticsSupport,
            label: "Support Summary",
            help: "Preview fixed non-identifying app, macOS, Mac hardware, feature-health, permission, and diagnostic-mode fields.",
            keywords: ["version", "macOS", "chip", "memory", "storage", "track"],
            owner: .appModel,
            scope: .mixed,
            persistence: .sessionOnly,
            reset: .notApplicable
        ),
        control(
            .diagnosticsSupportCopy,
            page: .diagnostics,
            section: .diagnosticsSupport,
            label: "Copy Support Summary",
            help: "Copy the sanitized support summary as JSON.",
            keywords: ["clipboard", "support", "JSON"],
            owner: .macOS,
            scope: .mixed,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .diagnosticsSupportExport,
            page: .diagnostics,
            section: .diagnosticsSupport,
            label: "Export Support Summary",
            help: "Export the sanitized support summary as a private JSON file.",
            keywords: ["save", "support", "JSON", "private"],
            owner: .appModel,
            scope: .mixed,
            persistence: .notApplicable,
            reset: .notApplicable
        ),
        control(
            .diagnosticsOpenFolder,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Open Diagnostics Folder",
            help: "Open the managed diagnostics directory when it exists.",
            keywords: ["Finder", "Application Support", "logs"],
            owner: .macOS,
            scope: .appWideLocal,
            persistence: .systemManaged,
            reset: .notApplicable
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
            persistence: .appPreferences,
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
    ] + aboutControls + KeyboardShortcutAction.allCases.map { action in
        SettingsControlMetadata(
            id: action.controlID,
            destination: SettingsDestination(
                page: .keyboardShortcuts,
                section: action.group.settingsSection
            ),
            label: action.title,
            help: action.help,
            keywords: action.keywords,
            owner: .applicationPreferences,
            scope: .appWideLocal,
            persistence: .appPreferences,
            resetCapability: .registeredLocalValue,
            availability: .available
        )
    } + [
        control(
            .shortcutExport, page: .keyboardShortcuts,
            section: .shortcutLocalData, label: "Export Keyboard Shortcuts",
            help: "Export app-wide shortcut assignments as versioned JSON.",
            keywords: ["backup", "JSON", "save shortcuts"], scope: .appWideLocal,
            persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .shortcutReset, page: .keyboardShortcuts,
            section: .shortcutLocalData, label: "Reset All Keyboard Shortcuts",
            help: "Restore every shortcut to SakuraCord's defaults.",
            keywords: ["defaults", "restore", "clear shortcuts"], scope: .appWideLocal,
            persistence: .appPreferences, reset: .categoryAction
        ),
        control(
            .privacyTypingIndicators, page: .privacySafety,
            section: .privacyDiscordActivity, label: "Send Typing Indicators",
            help: "Send Discord typing events while composing.",
            keywords: ["typing status", "Discord", "composer"],
            scope: .appWideLocal, persistence: .appPreferences, reset: .notApplicable
        ),
        control(
            .privacyReadAcknowledgements, page: .privacySafety,
            section: .privacyDiscordActivity, label: "Automatically Mark Messages as Read",
            help: "Acknowledge visible messages automatically; turn this off to require an explicit Mark Read action.",
            keywords: ["read receipt", "unread", "manual", "automatic"], owner: .appModel,
            scope: .mixed, persistence: .appPreferences, reset: .notApplicable
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
            .clearMessageSearches, page: .privacySafety,
            section: .privacyLocalData, label: "Clear Current Message Search",
            help: "Clear the current in-memory message-search query, filters, and results without deleting Discord messages.",
            keywords: ["query", "results", "filters", "local"], owner: .appModel,
            scope: .accountLocal, persistence: .sessionOnly, reset: .categoryAction
        ),
        control(
            .clearDestinationHistory, page: .privacySafety,
            section: .privacyLocalData, label: "Clear Recent Destinations",
            help: "Clear the account-scoped recent list shared by Quick Switch and forwarding.",
            keywords: ["history", "frecency", "channels", "forward"], owner: .appModel,
            scope: .accountLocal, persistence: .accountPreferences, reset: .categoryAction
        ),
        control(
            .clearEmojiRanking, page: .privacySafety,
            section: .privacyLocalData, label: "Clear Local Emoji Learning",
            help: "Clear SakuraCord's local emoji recents and usage counts without changing Discord ordering or favorites.",
            keywords: ["recents", "frequency", "learned", "ranking"], owner: .appModel,
            scope: .appWideLocal, persistence: .appPreferences, reset: .categoryAction
        ),
        control(
            .clearDrafts, page: .privacySafety,
            section: .privacyLocalData, label: "Manage Local Drafts",
            help: "Open the canonical account draft summaries and clearing controls in Storage & Downloads.",
            keywords: ["unsent", "composer", "delete", "account", "storage"], owner: .appModel,
            scope: .accountLocal, persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .privacyNotificationPreviews, page: .privacySafety,
            section: .privacyLocalData, label: "Notification Previews",
            help: "Open the single notification-preview privacy control.",
            keywords: ["lock screen", "sender", "message content"], owner: .applicationPreferences,
            scope: .appWideLocal, persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .privacyExport, page: .privacySafety,
            section: .privacyLocalData, label: "Export Privacy Preferences",
            help: "Export registered local Privacy preferences without credentials or private content.",
            keywords: ["JSON", "backup", "inspect"], scope: .appWideLocal,
            persistence: .notApplicable, reset: .notApplicable
        ),
        control(
            .privacyReset, page: .privacySafety,
            section: .privacyLocalData, label: "Reset Privacy Preferences",
            help: "Restore registered Privacy preferences without clearing local content or Discord data.",
            keywords: ["defaults", "restore"], scope: .appWideLocal,
            persistence: .appPreferences, reset: .categoryAction
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
