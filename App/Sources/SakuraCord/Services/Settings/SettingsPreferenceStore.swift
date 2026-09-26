import Foundation
import MediaPipeline

nonisolated enum SettingsPreferenceValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case strings([String])

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case bool
        case integer
        case double
        case string
        case strings
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .bool:
            self = try .bool(container.decode(Bool.self, forKey: .value))
        case .integer:
            self = try .integer(container.decode(Int.self, forKey: .value))
        case .double:
            self = try .double(container.decode(Double.self, forKey: .value))
        case .string:
            self = try .string(container.decode(String.self, forKey: .value))
        case .strings:
            self = try .strings(container.decode([String].self, forKey: .value))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .bool(value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(ValueType.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .double(value):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .string(value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .strings(value):
            try container.encode(ValueType.strings, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    var defaultsValue: Any {
        switch self {
        case let .bool(value): value
        case let .integer(value): value
        case let .double(value): value
        case let .string(value): value
        case let .strings(value): value
        }
    }

    func accepts(_ value: Any) -> SettingsPreferenceValue? {
        switch self {
        case .bool:
            (value as? Bool).map(Self.bool)
        case .integer:
            (value as? Int).map(Self.integer)
        case .double:
            if let value = value as? Double {
                .double(value)
            } else if let value = value as? Float {
                .double(Double(value))
            } else {
                nil
            }
        case .string:
            (value as? String).map(Self.string)
        case .strings:
            (value as? [String]).map(Self.strings)
        }
    }
}

nonisolated enum SettingsPreferenceStorage: Hashable, Sendable {
    case appWide(key: String)
    case accountLocal(key: String)
}

nonisolated struct SettingsPreferenceRegistration: Identifiable, Sendable {
    let id: SettingsControlID
    let page: SettingsPageID
    let storage: SettingsPreferenceStorage
    let defaultValue: SettingsPreferenceValue
    let exports: Bool
    let resets: Bool

    init(
        id: SettingsControlID,
        page: SettingsPageID,
        storage: SettingsPreferenceStorage,
        defaultValue: SettingsPreferenceValue,
        exports: Bool = true,
        resets: Bool = true
    ) {
        self.id = id
        self.page = page
        self.storage = storage
        self.defaultValue = defaultValue
        self.exports = exports
        self.resets = resets
    }
}

nonisolated struct SettingsPreferenceRegistry: Sendable {
    let registrations: [SettingsPreferenceRegistration]

    static let foundation = SettingsPreferenceRegistry(registrations: [
        SettingsPreferenceRegistration(
            id: .memberListVisibility, page: .interface,
            storage: .appWide(key: "settings.memberListVisible"), defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .launchDestination,
            page: .general,
            storage: .appWide(key: "settings.launchDestination"),
            defaultValue: .string(SettingsLaunchDestination.lastVisitedConversation.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .confirmQuitActiveWork,
            page: .general,
            storage: .appWide(key: "settings.confirmQuitActiveWork"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .appColorScheme,
            page: .appearance,
            storage: .appWide(key: "settings.appearance.colorScheme"),
            defaultValue: .string(AppColorScheme.system.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .windowOpacity,
            page: .appearance,
            storage: .appWide(key: "settings.appearance.windowOpacity"),
            defaultValue: .double(AppearanceSettingsSnapshot.defaultWindowOpacity)
        ),
        SettingsPreferenceRegistration(
            id: .legacyAccentColorMigration,
            page: .appearance,
            storage: .appWide(key: "settings.appearance.accentColor"),
            defaultValue: .string(LegacyAccentColorChoice.blurple.rawValue),
            exports: false
        ),
        SettingsPreferenceRegistration(
            id: .themeDesigner,
            page: .appearance,
            storage: .appWide(key: "settings.appearance.customGradientTheme"),
            defaultValue: .string(SakuraCordGradientTheme.defaultTheme.storageValue)
        ),
        SettingsPreferenceRegistration(
            id: .composerBarAppearance,
            page: .interface,
            storage: .appWide(key: "settings.appearance.composerBar"),
            defaultValue: .string(ComposerBarAppearance.defaultStyle.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .messageAppearance,
            page: .interface,
            storage: .appWide(key: "settings.appearance.messages"),
            defaultValue: .string(MessageAppearance.defaultStyle.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .messageDensity,
            page: .interface,
            storage: .appWide(key: "settings.appearance.messageDensity"),
            defaultValue: .double(
                AppearanceSettingsSnapshot.defaults.messageSpacing
            )
        ),
        SettingsPreferenceRegistration(
            id: .timestampFormat,
            page: .interface,
            storage: .appWide(key: "settings.interface.timestampFormat"),
            defaultValue: .string(InterfaceTimestampFormat.system.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .alwaysShowTimestamps, page: .interface,
            storage: .appWide(key: "settings.interface.alwaysShowTimestamps"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .roleColorDisplay, page: .accessibility,
            storage: .appWide(key: "settings.accessibility.roleColorDisplay"),
            defaultValue: .string(RoleColorDisplay.inNames.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .composerIcons, page: .interface,
            storage: .appWide(key: "settings.appearance.composerIcons"),
            defaultValue: .string(ComposerIconLayout.defaults.storageValue)
        ),
        SettingsPreferenceRegistration(
            id: .timestampSeconds,
            page: .interface,
            storage: .appWide(key: "settings.interface.timestampSeconds"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .underlineLinks,
            page: .accessibility,
            storage: .appWide(key: "settings.interface.underlineLinks"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .sendWithReturn,
            page: .general,
            storage: .appWide(key: "settings.chat.sendWithReturn"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .spellCheck,
            page: .general,
            storage: .appWide(key: "settings.chat.spellCheck"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .automaticCorrection,
            page: .general,
            storage: .appWide(key: "settings.chat.automaticCorrection"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .smartQuotes,
            page: .general,
            storage: .appWide(key: "settings.chat.smartQuotes"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .smartDashes,
            page: .general,
            storage: .appWide(key: "settings.chat.smartDashes"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .removeMediaMetadata,
            page: .privacySafety,
            storage: .appWide(key: "settings.privacy.removeMediaMetadata"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .anonymiseFileNames,
            page: .privacySafety,
            storage: .appWide(key: PrivacySafetySettingsStore.anonymiseFileNamesKey),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .privacyTypingIndicators,
            page: .privacySafety,
            storage: .appWide(key: "settings.chat.typingIndicators"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .emojiSkinTone,
            page: .general,
            storage: .appWide(key: "emojiSkinTone"),
            defaultValue: .string(NativeEmojiSkinTone.standard.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .translationEnabled, page: .features,
            storage: .appWide(key: "settings.translation.enabled"), defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .translationMessageLanguage, page: .features,
            storage: .appWide(key: "settings.translation.messageLanguage"), defaultValue: .string("")
        ),
        SettingsPreferenceRegistration(
            id: .translationDraftLanguage, page: .features,
            storage: .appWide(key: "settings.translation.draftLanguage"), defaultValue: .string("en")
        ),
        SettingsPreferenceRegistration(
            id: .channelManagement, page: .features,
            storage: .appWide(key: "settings.features.channelManagement"), defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .showHiddenChannels, page: .features,
            storage: .appWide(key: "settings.features.showHiddenChannels"), defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .fakeNitroEmojis, page: .features,
            storage: .appWide(key: "settings.features.fakeNitroEmojis"), defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .fakeNitroStickers, page: .features,
            storage: .appWide(key: "settings.features.fakeNitroStickers"), defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .fakeNitroSoundboard, page: .features,
            storage: .appWide(key: "settings.features.fakeNitroSoundboard"), defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .fakeNitroStreamQuality, page: .features,
            storage: .appWide(key: "settings.features.fakeNitroStreamQuality"), defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .attachmentCompactionPrompt, page: .features,
            storage: .appWide(key: "settings.attachments.attachmentCompactionPrompt"), defaultValue: .string(AttachmentHandlingPolicy.ask.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .attachmentExternalUploadPrompt, page: .features,
            storage: .appWide(key: "settings.attachments.attachmentExternalUploadPrompt"), defaultValue: .string(AttachmentHandlingPolicy.ask.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .attachmentExternalProvider, page: .features,
            storage: .appWide(key: "settings.attachments.externalProvider"), defaultValue: .string(ExternalAttachmentHostingService.litterbox.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .attachmentCompactionQuality, page: .features,
            storage: .appWide(key: "settings.attachments.attachmentCompactionQuality"), defaultValue: .string(AttachmentCompactionOptions.Quality.balanced.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .localStorageLimit,
            page: .storageDownloads,
            storage: .appWide(key: "mediaCacheLimit"),
            defaultValue: .integer(2_147_483_648)
        ),
        SettingsPreferenceRegistration(
            id: .mediaCacheLastCleared,
            page: .storageDownloads,
            storage: .appWide(key: "settings.storage.mediaCacheLastCleared"),
            defaultValue: .double(0),
            exports: false,
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .downloadFolderBookmark,
            page: .storageDownloads,
            storage: .appWide(key: "settings.storage.downloadFolderBookmark"),
            defaultValue: .string(""),
            exports: false
        ),
        SettingsPreferenceRegistration(
            id: .downloadFolderName,
            page: .storageDownloads,
            storage: .appWide(key: "settings.storage.downloadFolderName"),
            defaultValue: .string(""),
            exports: false
        ),
        SettingsPreferenceRegistration(
            id: .revealCompletedDownloads,
            page: .storageDownloads,
            storage: .appWide(key: "settings.storage.revealCompletedDownloads"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .notificationEnabled,
            page: .notifications,
            storage: .appWide(key: "notifications.enabled"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationPreview,
            page: .notifications,
            storage: .appWide(key: "notifications.preview"),
            defaultValue: .string(NotificationPreviewStyle.full.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .notificationSound,
            page: .notifications,
            storage: .appWide(key: "notifications.sound"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationDockBadge,
            page: .notifications,
            storage: .appWide(key: "notifications.dockBadge"),
            defaultValue: .string(NotificationDockBadgeStyle.mentions.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .notificationDirectMessages,
            page: .notifications,
            storage: .appWide(key: "notifications.events.directMessages"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationGroupDirectMessages,
            page: .notifications,
            storage: .appWide(key: "notifications.events.groupDirectMessages"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationMentions,
            page: .notifications,
            storage: .appWide(key: "notifications.events.mentions"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationReplies,
            page: .notifications,
            storage: .appWide(key: "notifications.events.replies"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationIncomingCalls,
            page: .notifications,
            storage: .appWide(key: "notifications.events.incomingCalls"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationServerActivity,
            page: .notifications,
            storage: .appWide(key: "notifications.events.serverActivity"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationSuppressCurrent,
            page: .notifications,
            storage: .appWide(key: "notifications.suppressCurrentConversation"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationGroupBursts,
            page: .notifications,
            storage: .appWide(key: "notifications.groupByConversation"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationClearWhenRead,
            page: .notifications,
            storage: .appWide(key: "notifications.clearWhenRead"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceInputDevice,
            page: .voiceVideo,
            storage: .appWide(key: "voiceInputDeviceUID"),
            defaultValue: .string("")
        ),
        SettingsPreferenceRegistration(
            id: .voiceOutputDevice,
            page: .voiceVideo,
            storage: .appWide(key: "voiceOutputDeviceUID"),
            defaultValue: .string("")
        ),
        SettingsPreferenceRegistration(
            id: .voiceCamera,
            page: .voiceVideo,
            storage: .appWide(key: "voiceCameraUID"),
            defaultValue: .string("")
        ),
        SettingsPreferenceRegistration(
            id: .voiceInputVolume,
            page: .voiceVideo,
            storage: .appWide(key: "voiceInputVolume"),
            defaultValue: .double(1)
        ),
        SettingsPreferenceRegistration(
            id: .voiceOutputVolume,
            page: .voiceVideo,
            storage: .appWide(key: "voiceOutputVolume"),
            defaultValue: .double(1)
        ),
        SettingsPreferenceRegistration(
            id: .voiceJoinMuted,
            page: .voiceVideo,
            storage: .appWide(key: "voice.joinMuted"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .voiceJoinDeafened,
            page: .voiceVideo,
            storage: .appWide(key: "voice.joinDeafened"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .voiceFeedbackSounds,
            page: .voiceVideo,
            storage: .appWide(key: "voice.feedbackSounds"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceRememberCamera,
            page: .voiceVideo,
            storage: .appWide(key: "voice.remembersCamera"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceMirrorPreview,
            page: .voiceVideo,
            storage: .appWide(key: "voice.mirrorsLocalPreview"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceJoinCameraOff,
            page: .voiceVideo,
            storage: .appWide(key: "voice.joinsWithCameraOff"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceScreenShareQuality,
            page: .voiceVideo,
            storage: .appWide(key: "voice.screenShare.quality"),
            defaultValue: .string(ScreenShareQuality.p720.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .voiceScreenShareFrameRate,
            page: .voiceVideo,
            storage: .appWide(key: "voice.screenShare.frameRate"),
            defaultValue: .integer(ScreenShareFrameRate.fps30.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .voiceScreenShareAudio,
            page: .voiceVideo,
            storage: .appWide(key: "voice.screenShare.includesAudio"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceScreenSharePointer,
            page: .voiceVideo,
            storage: .appWide(key: "voice.screenShare.showsPointer"),
            defaultValue: .bool(true)
        ),

        SettingsPreferenceRegistration(
            id: .accessibilityDisableOwnCosmetics,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.disableOwnCosmetics"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableProfileEffects,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.disableProfileEffects"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableNameplates,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.disableNameplates"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableAvatarDecorations,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.disableAvatarDecorations"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableProfileFrames,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.disableProfileFrames"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableNameStyles,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.disableNameStyles"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableProfileGradients,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.disableProfileGradients"),
            defaultValue: .bool(false)
        ),

        SettingsPreferenceRegistration(
            id: .accessibilityAnnounceTimestamp,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.announceTimestamp"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityAnnounceEdited,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.announceEdited"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityAnnounceReactions,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.announceReactions"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityAnnounceAttachmentTypes,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.announceAttachmentTypes"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityAnnounceNewMessages,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.announceNewMessages"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .externalLinkProtection,
            page: .privacySafety,
            storage: .appWide(key: "settings.privacy.externalLinkConfirmationPolicy"),
            defaultValue: .string(ExternalLinkConfirmationPolicy.untrustedDomains.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .trustedDomains,
            page: .privacySafety,
            storage: .appWide(key: "settings.privacy.trustedDomains"),
            defaultValue: .strings([]),
            exports: false
        ),
        SettingsPreferenceRegistration(
            id: .diagnosticConnectionMetrics,
            page: .diagnostics,
            storage: .appWide(key: DiagnosticsPreferences.capturesConnectionMetricsKey),
            defaultValue: .bool(false),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .diagnosticDetailedPayloads,
            page: .diagnostics,
            storage: .appWide(key: DiagnosticsPreferences.capturesDetailedPayloadsKey),
            defaultValue: .bool(false),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .diagnosticPanicSave,
            page: .diagnostics,
            storage: .appWide(key: DiagnosticsPreferences.enablesPanicSaveKey),
            defaultValue: .bool(true),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .diagnosticDiskCapture,
            page: .diagnostics,
            storage: .appWide(key: DiagnosticsPreferences.savesDiagnosticsToDiskKey),
            defaultValue: .bool(false),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .updateReleaseTrack,
            page: .softwareUpdates,
            storage: .appWide(key: AppUpdateReleaseTrack.preferenceKey),
            defaultValue: .string(AppUpdateReleaseTrack.regular.rawValue),
            resets: false
        ),
    ] + KeyboardShortcutAction.allCases.map { action in
        SettingsPreferenceRegistration(
            id: action.controlID,
            page: .keyboardShortcuts,
            storage: .appWide(key: "settings.shortcuts.\(action.rawValue)"),
            defaultValue: .string(action.defaultShortcut?.storageValue ?? "")
        )
    })

    init(registrations: [SettingsPreferenceRegistration]) {
        let ids = registrations.map(\.id)
        precondition(Set(ids).count == ids.count, "Settings preference IDs must be unique.")
        self.registrations = registrations
    }

    func registration(_ id: SettingsControlID) -> SettingsPreferenceRegistration? {
        registrations.first { $0.id == id }
    }

    func registrations(
        page: SettingsPageID? = nil,
        storageScope: SettingsLocalPreferenceScope? = nil
    ) -> [SettingsPreferenceRegistration] {
        registrations.filter { registration in
            let matchesPage = page == nil || registration.page == page
            let matchesScope = switch (storageScope, registration.storage) {
            case (nil, _): true
            case (.appWide, .appWide): true
            case (.accountLocal, .accountLocal): true
            default: false
            }
            return matchesPage && matchesScope
        }
    }
}

nonisolated enum SettingsLocalPreferenceScope: String, Codable, Sendable {
    case appWide = "app-wide"
    case accountLocal = "account-local"
}

nonisolated struct SettingsPreferenceExport: Codable, Equatable, Sendable {
    static let schema = "dev.sakuracord.settings-preferences"
    static let currentVersion = 1

    let schema: String
    let version: Int
    let scope: SettingsLocalPreferenceScope
    let page: SettingsPageID?
    let values: [String: SettingsPreferenceValue]

    init(
        scope: SettingsLocalPreferenceScope,
        page: SettingsPageID?,
        values: [String: SettingsPreferenceValue]
    ) {
        schema = Self.schema
        version = Self.currentVersion
        self.scope = scope
        self.page = page
        self.values = values
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

final class SettingsPreferenceStore {
    static let shared = SettingsPreferenceStore()

    private static let accountValuesKey = "dev.sakuracord.account-local-preferences-v1"

    let registry: SettingsPreferenceRegistry
    private let defaults: any PreferenceStoring

    init(
        registry: SettingsPreferenceRegistry = .foundation,
        defaults: any PreferenceStoring = UserDefaults.standard
    ) {
        self.registry = registry
        self.defaults = defaults
        // Retire removed preferences while retaining the member-list visibility itself.
        for key in [
            "settings.showMainWindowAtLaunch",
            "settings.rememberMemberListVisibility",
            "settings.confirmDiscardComposer",
            "settings.reopenLastActiveAccount",
            "settings.preferredLaunchAccountID",
            "settings.accountConversationLocations.v1",
            "settings.interface.groupingIntervalMinutes",
            "settings.interface.showActivityDetails",
            "settings.interface.messageActionVisibility",
            "settings.accessibility.motionOverride",
            "settings.accessibility.reduceAnimatedEmoji",
            "settings.accessibility.reduceAnimatedStickers",
            "settings.accessibility.reduceGIFs",
            "settings.accessibility.reduceAnimatedAvatars",
            "settings.accessibility.reduceDecorations",
            "settings.accessibility.reduceTransitions",
            "settings.accessibility.reduceAnimatedContent",
            "settings.accessibility.increaseContrast",
            "settings.accessibility.largerTargets",
        ] {
            defaults.removeObject(forKey: key)
        }
        let launchDestinationKey = "settings.launchDestination"
        if let rawValue = defaults.object(forKey: launchDestinationKey) as? String,
           SettingsLaunchDestination(rawValue: rawValue) == nil {
            defaults.removeObject(forKey: launchDestinationKey)
        }
        let legacyRoleKey = "settings.interface.showRoleColors"
        let roleKey = "settings.accessibility.roleColorDisplay"
        if defaults.object(forKey: roleKey) == nil,
           let enabled = defaults.object(forKey: legacyRoleKey) as? Bool {
            defaults.set(enabled ? RoleColorDisplay.inNames.rawValue : RoleColorDisplay.hidden.rawValue, forKey: roleKey)
        }
        defaults.removeObject(forKey: legacyRoleKey)
    }

    func value(
        for id: SettingsControlID,
        accountID: String? = nil
    ) -> SettingsPreferenceValue? {
        guard let registration = registry.registration(id) else { return nil }
        switch registration.storage {
        case let .appWide(key):
            guard let stored = defaults.object(forKey: key) else {
                return registration.defaultValue
            }
            return registration.defaultValue.accepts(stored) ?? registration.defaultValue
        case let .accountLocal(key):
            guard let accountID else { return registration.defaultValue }
            return accountValues()[accountID]?[key] ?? registration.defaultValue
        }
    }

    func containsStoredValue(
        for id: SettingsControlID,
        accountID: String? = nil
    ) -> Bool {
        guard let registration = registry.registration(id) else { return false }
        return switch registration.storage {
        case let .appWide(key):
            defaults.object(forKey: key) != nil
        case let .accountLocal(key):
            accountID.flatMap { accountValues()[$0]?[key] } != nil
        }
    }

    func set(
        _ value: SettingsPreferenceValue,
        for id: SettingsControlID,
        accountID: String? = nil
    ) {
        guard let registration = registry.registration(id),
              registration.defaultValue.accepts(value.defaultsValue) != nil
        else { return }

        switch registration.storage {
        case let .appWide(key):
            defaults.set(value.defaultsValue, forKey: key)
        case let .accountLocal(key):
            guard let accountID else { return }
            var values = accountValues()
            values[accountID, default: [:]][key] = value
            persistAccountValues(values)
        }
    }

    func reset(
        scope: SettingsLocalPreferenceScope,
        page: SettingsPageID? = nil,
        accountID: String? = nil
    ) {
        let registrations = registry.registrations(page: page, storageScope: scope)
            .filter(\.resets)
        switch scope {
        case .appWide:
            for registration in registrations {
                guard case let .appWide(key) = registration.storage else { continue }
                defaults.removeObject(forKey: key)
            }
        case .accountLocal:
            guard let accountID else { return }
            var values = accountValues()
            for registration in registrations {
                guard case let .accountLocal(key) = registration.storage else { continue }
                values[accountID]?[key] = nil
            }
            if values[accountID]?.isEmpty == true {
                values[accountID] = nil
            }
            persistAccountValues(values)
        }
    }

    func export(
        scope: SettingsLocalPreferenceScope,
        page: SettingsPageID? = nil,
        accountID: String? = nil
    ) -> SettingsPreferenceExport {
        let registrations = registry.registrations(page: page, storageScope: scope)
            .filter(\.exports)
        var values: [String: SettingsPreferenceValue] = [:]
        for registration in registrations {
            guard let value = value(for: registration.id, accountID: accountID) else { continue }
            values[registration.id.rawValue] = value
        }
        return SettingsPreferenceExport(scope: scope, page: page, values: values)
    }

    private func accountValues() -> [String: [String: SettingsPreferenceValue]] {
        guard let data = defaults.data(forKey: Self.accountValuesKey),
              let values = try? JSONDecoder().decode(
                  [String: [String: SettingsPreferenceValue]].self,
                  from: data
              )
        else { return [:] }
        return values
    }

    private func persistAccountValues(
        _ values: [String: [String: SettingsPreferenceValue]]
    ) {
        guard !values.isEmpty else {
            defaults.removeObject(forKey: Self.accountValuesKey)
            return
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.accountValuesKey)
    }
}
