import Foundation

nonisolated enum SettingsPageID: String, CaseIterable, Codable, Identifiable, Sendable {
    case profiles
    case myAccount
    case general
    case interface
    case appearance
    case notifications
    case voiceVideo
    case accessibility
    case keyboardShortcuts
    case features
    case privacySafety
    case storageDownloads
    case diagnostics
    case softwareUpdates
    case extensions
    case importExport
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
    case accountAndAppWideLocal
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
        case .accountAndAppWideLocal:
            LocalizedStringResource(
                "Selected account and app-wide on this Mac",
                bundle: #bundle,
                comment: "Settings scope label for an action affecting both the selected account and app-wide local data."
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
    static let startupRestoration = Self(rawValue: "startup-restoration")
    static let confirmations = Self(rawValue: "confirmations")
    static let appearanceTheme = Self(rawValue: "appearance-theme")
    static let interfaceMessages = Self(rawValue: "interface-messages")
    static let interfaceInputBar = Self(rawValue: "interface-input-bar")
    static let interfaceTime = Self(rawValue: "interface-time")
    static let generalTextInput = Self(rawValue: "general-text-input")
    static let generalEmoji = Self(rawValue: "general-emoji")
    static let featuresChannels = Self(rawValue: "features-channels")
    static let featuresFakeNitro = Self(rawValue: "features-fake-nitro")
    static let featuresAttachments = Self(rawValue: "features-attachments")
    static let featuresTranslation = Self(rawValue: "features-translation")
    static let softwareUpdates = Self(rawValue: "software-updates")
    static let notificationDelivery = Self(rawValue: "notification-delivery")
    static let notificationEvents = Self(rawValue: "notification-events")
    static let notificationLocalData = Self(rawValue: "notification-local-data")
    static let voiceDevices = Self(rawValue: "voice-devices")
    static let voiceLevels = Self(rawValue: "voice-levels")
    static let voiceCallDefaults = Self(rawValue: "voice-call-defaults")
    static let voiceCamera = Self(rawValue: "voice-camera")
    static let voiceScreenShare = Self(rawValue: "voice-screen-share")
    static let voicePermissions = Self(rawValue: "voice-permissions")
    static let voiceLocalData = Self(rawValue: "voice-local-data")
    static let accessibilityCosmetics = Self(rawValue: "accessibility-cosmetics")
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

    static let accountUsername = Self(rawValue: "my-account.username")
    static let accountEmail = Self(rawValue: "my-account.email")
    static let accountPhone = Self(rawValue: "my-account.phone")
    static let accountMFA = Self(rawValue: "my-account.mfa")
    static let accountDevices = Self(rawValue: "my-account.devices")
    static let selectedAccount = Self(rawValue: "my-account.selected-account")
    static let switchAccount = Self(rawValue: "my-account.switch-account")
    static let addAccount = Self(rawValue: "my-account.add-account")
    static let removeSavedSession = Self(rawValue: "my-account.remove-saved-session")
    static let launchAtLogin = Self(rawValue: "general.launch-at-login")
    static let launchDestination = Self(rawValue: "general.launch-destination")
    static let confirmQuitActiveWork = Self(rawValue: "general.confirm-quit-active-work")
    static let appColorScheme = Self(rawValue: "appearance.color-scheme")
    static let windowOpacity = Self(rawValue: "appearance.window-opacity")
    static let legacyAccentColorMigration = Self(rawValue: "appearance.accent-color")
    static let themeDesigner = Self(rawValue: "appearance.theme-designer")
    static let resetTheme = Self(rawValue: "appearance.reset-theme")
    static let composerBarAppearance = Self(rawValue: "appearance.composer-bar")
    static let messageAppearance = Self(rawValue: "appearance.messages")
    static let messageDensity = Self(rawValue: "appearance.message-density")
    static let resetMessageAppearance = Self(rawValue: "interface.reset-message-appearance")
    static let timestampFormat = Self(rawValue: "interface.timestamp-format")
    static let composerIcons = Self(rawValue: "appearance.composer-icons")
    static let alwaysShowTimestamps = Self(rawValue: "interface.always-show-timestamps")
    static let roleColorDisplay = Self(rawValue: "accessibility.role-colors")
    static let timestampSeconds = Self(rawValue: "interface.timestamp-seconds")
    static let underlineLinks = Self(rawValue: "interface.underline-links")
    // Preserve exported identifiers when moving these controls to General.
    static let sendWithReturn = Self(rawValue: "chat.send-with-return")
    static let spellCheck = Self(rawValue: "chat.spell-check")
    static let automaticCorrection = Self(rawValue: "chat.automatic-correction")
    static let smartQuotes = Self(rawValue: "chat.smart-quotes")
    static let smartDashes = Self(rawValue: "chat.smart-dashes")
    static let emojiSkinTone = Self(rawValue: "chat.emoji-skin-tone")
    static let channelManagement = Self(rawValue: "features.channel-management")
    static let showHiddenChannels = Self(rawValue: "features.show-hidden-channels")
    static let fakeNitroEmojis = Self(rawValue: "features.fake-nitro-emojis")
    static let fakeNitroStickers = Self(rawValue: "features.fake-nitro-stickers")
    static let fakeNitroSoundboard = Self(rawValue: "features.fake-nitro-soundboard")
    static let fakeNitroStreamQuality = Self(rawValue: "features.fake-nitro-stream-quality")
    static let attachmentCompactionPrompt = Self(rawValue: "attachments.compaction-prompt")
    static let attachmentExternalUploadPrompt = Self(rawValue: "attachments.external-upload-prompt")
    static let attachmentExternalProvider = Self(rawValue: "attachments.external-provider")
    static let attachmentCompactionQuality = Self(rawValue: "attachments.compaction-quality")
    static let translationProvider = Self(rawValue: "translation.provider")
    static let translationServer = Self(rawValue: "translation.libretranslate-server")
    static let translationAPIKey = Self(rawValue: "translation.api-key")
    static let translationMessageLanguage = Self(rawValue: "translation.message-language")
    static let translationDraftLanguage = Self(rawValue: "translation.draft-language")
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
    static let aboutSponsor = Self(rawValue: "about.sponsor")
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
    static let notificationDirectMessages = Self(rawValue: "notifications.direct-messages")
    static let notificationGroupDirectMessages = Self(rawValue: "notifications.group-direct-messages")
    static let notificationMentions = Self(rawValue: "notifications.mentions")
    static let notificationReplies = Self(rawValue: "notifications.replies")
    static let notificationIncomingCalls = Self(rawValue: "notifications.incoming-calls")
    static let notificationServerActivity = Self(rawValue: "notifications.server-activity")
    static let notificationSuppressCurrent = Self(rawValue: "notifications.suppress-current")
    static let notificationGroupBursts = Self(rawValue: "notifications.group-bursts")
    static let notificationClearWhenRead = Self(rawValue: "notifications.clear-when-read")
    static let notificationReset = Self(rawValue: "notifications.reset")
    static let voiceInputDevice = Self(rawValue: "voice-video.input-device")
    static let voiceOutputDevice = Self(rawValue: "voice-video.output-device")
    static let voiceCamera = Self(rawValue: "voice-video.camera")
    static let voiceInputVolume = Self(rawValue: "voice-video.input-volume")
    static let voiceOutputVolume = Self(rawValue: "voice-video.output-volume")
    static let voiceRefreshDevices = Self(rawValue: "voice-video.refresh-devices")
    static let voiceMicrophoneTest = Self(rawValue: "voice-video.microphone-test")
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
    static let voiceReset = Self(rawValue: "voice-video.reset")
    static let accessibilityDisableOwnCosmetics = Self(rawValue: "accessibility.disable-own-cosmetics")
    static let accessibilityDisableProfileEffects = Self(rawValue: "accessibility.disable-profile-effects")
    static let accessibilityDisableNameplates = Self(rawValue: "accessibility.disable-nameplates")
    static let accessibilityDisableAvatarDecorations = Self(rawValue: "accessibility.disable-avatar-decorations")
    static let accessibilityDisableProfileFrames = Self(rawValue: "accessibility.disable-profile-frames")
    static let accessibilityDisableNameStyles = Self(rawValue: "accessibility.disable-name-styles")
    static let accessibilityDisableProfileGradients = Self(rawValue: "accessibility.disable-profile-gradients")
    static let accessibilityAnnounceTimestamp = Self(rawValue: "accessibility.announce-timestamp")
    static let accessibilityAnnounceEdited = Self(rawValue: "accessibility.announce-edited")
    static let accessibilityAnnounceReactions = Self(rawValue: "accessibility.announce-reactions")
    static let accessibilityAnnounceAttachmentTypes = Self(rawValue: "accessibility.announce-attachment-types")
    static let accessibilityAnnounceNewMessages = Self(rawValue: "accessibility.announce-new-messages")
    static let accessibilityReset = Self(rawValue: "accessibility.reset")
    static let shortcutReset = Self(rawValue: "keyboard-shortcuts.reset")
    static let removeMediaMetadata = Self(rawValue: "privacy.remove-media-metadata")
    static let anonymiseFileNames = Self(rawValue: "privacy.anonymise-file-names")
    static let privacyTypingIndicators = Self(rawValue: "privacy.typing-indicators")
    static let externalLinkProtection = Self(rawValue: "privacy.external-link-protection")
    static let trustedDomains = Self(rawValue: "privacy.trusted-domains")
    static let clearLocalActivity = Self(rawValue: "privacy.clear-local-activity")
    static let diagnosticConnectionMetrics = Self(rawValue: "diagnostics.connection-metrics")
    static let diagnosticDetailedPayloads = Self(rawValue: "diagnostics.detailed-payloads")
    static let diagnosticPanicSave = Self(rawValue: "diagnostics.panic-save")
    static let diagnosticDiskCapture = Self(rawValue: "diagnostics.disk-capture")
    static let diagnosticRetainedEntries = Self(rawValue: "diagnostics.retained-entries")
    static let diagnosticExport = Self(rawValue: "diagnostics.export-api-logs")
    static let diagnosticClear = Self(rawValue: "diagnostics.clear-api-logs")
}

nonisolated extension SettingsCatalog {
    static let extensionsPage = page(
        .extensions, group: .sakuraCord, title: "Extensions", image: "puzzlepiece.extension",
        help: "Learn about SakuraCord's future sandboxed extension system.",
        keywords: ["plugins", "permissions", "sandbox", "sandboxing", "SDK", "host"]
    )

    static let foundationPages: [SettingsPageMetadata] = [
        profilesPage,
        myAccountPage,
        generalPage,
        interfacePage,
        appearancePage,
        notificationsPage,
        voiceVideoPage,
        accessibilityPage,
        keyboardShortcutsPage,
        featuresPage,
        privacySafetyPage,
        storageDownloadsPage,
        diagnosticsPage,
        softwareUpdatesPage,
        extensionsPage,
        importExportPage,
        aboutPage,
    ]

    static let foundationControls: [SettingsControlMetadata] =
        myAccountControls
        + profilesControls
        + themeDetailControls
        + transferControls
        + generalControls
        + featuresControls
        + appearanceControls
        + interfaceControls
        + softwareUpdatesControls
        + storageDownloadsControls
        + notificationsControls
        + voiceVideoControls
        + accessibilityControls
        + diagnosticsControls
        + aboutControls
        + keyboardShortcutsControls
        + privacySafetyControls

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
