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

nonisolated struct SettingsPreferenceRegistration: Identifiable, Sendable {
    let id: SettingsControlID
    let page: SettingsPageID
    /// The app-wide UserDefaults key.
    let key: String
    let defaultValue: SettingsPreferenceValue
    let exports: Bool
    let resets: Bool

    init(
        id: SettingsControlID,
        page: SettingsPageID,
        key: String,
        defaultValue: SettingsPreferenceValue,
        exports: Bool = true,
        resets: Bool = true
    ) {
        self.id = id
        self.page = page
        self.key = key
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
            key: "settings.memberListVisible", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .directMessageProfileVisibility, page: .interface,
            key: "settings.directMessageProfileVisible", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .groupDirectMessageMembersVisibility, page: .interface,
            key: "settings.groupDirectMessageMembersVisible", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .launchDestination,
            page: .general,
            key: "settings.launchDestination",
            defaultValue: .string(SettingsLaunchDestination.lastVisitedConversation.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .confirmQuitActiveWork,
            page: .general,
            key: "settings.confirmQuitActiveWork",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .appColorScheme,
            page: .appearance,
            key: "settings.appearance.colorScheme",
            defaultValue: .string(AppColorScheme.system.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .windowOpacity,
            page: .appearance,
            key: "settings.appearance.windowOpacity",
            defaultValue: .double(AppearanceSettingsSnapshot.defaultWindowOpacity)
        ),
        SettingsPreferenceRegistration(
            id: .legacyAccentColorMigration,
            page: .appearance,
            key: "settings.appearance.accentColor",
            defaultValue: .string(LegacyAccentColorChoice.blurple.rawValue),
            exports: false
        ),
        SettingsPreferenceRegistration(
            id: .themeDesigner,
            page: .appearance,
            key: "settings.appearance.customGradientTheme",
            defaultValue: .string(SakuraCordGradientTheme.defaultTheme.storageValue)
        ),
        SettingsPreferenceRegistration(
            id: .composerBarAppearance,
            page: .interface,
            key: "settings.appearance.composerBar",
            defaultValue: .string(ComposerBarAppearance.defaultStyle.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .messageAppearance,
            page: .interface,
            key: "settings.appearance.serverMessages",
            defaultValue: .string(MessageAppearance.defaultStyle.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .directMessageAppearance, page: .interface,
            key: "settings.appearance.directMessages",
            defaultValue: .string(MessageAppearance.defaultStyle.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .groupMessageAppearance, page: .interface,
            key: "settings.appearance.groupMessages",
            defaultValue: .string(MessageAppearance.defaultStyle.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .messageFontSize,
            page: .interface,
            key: "settings.appearance.messageFontSize",
            defaultValue: .double(InterfaceTypographyMetrics.defaultMessageTextSize)
        ),
        SettingsPreferenceRegistration(
            id: .messageDensity,
            page: .interface,
            key: "settings.appearance.messageDensity",
            defaultValue: .double(
                AppearanceSettingsSnapshot.defaults.messageSpacing
            )
        ),
        SettingsPreferenceRegistration(
            id: .interfaceSize,
            page: .interface,
            key: "settings.interface.size",
            defaultValue: .double(InterfaceScale.defaultFactor)
        ),
        SettingsPreferenceRegistration(
            id: .timestampFormat,
            page: .interface,
            key: "settings.interface.timestampFormat",
            defaultValue: .string(InterfaceTimestampFormat.system.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .alwaysShowTimestamps, page: .interface,
            key: "settings.interface.alwaysShowTimestamps",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .roleColorDisplay, page: .accessibility,
            key: "settings.accessibility.roleColorDisplay",
            defaultValue: .string(RoleColorDisplay.inNames.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .composerIcons, page: .interface,
            key: "settings.appearance.composerIcons",
            defaultValue: .string(ComposerIconLayout.defaults.storageValue)
        ),
        SettingsPreferenceRegistration(
            id: .timestampSeconds,
            page: .interface,
            key: "settings.interface.timestampSeconds",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .underlineLinks,
            page: .accessibility,
            key: "settings.interface.underlineLinks",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .sendWithReturn,
            page: .general,
            key: "settings.chat.sendWithReturn",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .replyMentionsAuthor, page: .general,
            key: "settings.chat.replyMentionsAuthor",
            defaultValue: .bool(true), exports: false, resets: false
        ),
        SettingsPreferenceRegistration(
            id: .spellCheck,
            page: .general,
            key: "settings.chat.spellCheck",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .automaticCorrection,
            page: .general,
            key: "settings.chat.automaticCorrection",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .smartQuotes,
            page: .general,
            key: "settings.chat.smartQuotes",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .smartDashes,
            page: .general,
            key: "settings.chat.smartDashes",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .removeMediaMetadata,
            page: .privacySafety,
            key: "settings.privacy.removeMediaMetadata",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .anonymiseFileNames,
            page: .privacySafety,
            key: PrivacySafetySettingsStore.anonymiseFileNamesKey,
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .privacyTypingIndicators,
            page: .privacySafety,
            key: "settings.chat.typingIndicators",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .emojiSkinTone,
            page: .general,
            key: "emojiSkinTone",
            defaultValue: .string(NativeEmojiSkinTone.standard.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .translationEnabled, page: .features,
            key: "settings.translation.enabled", defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .translationMessageLanguage, page: .features,
            key: "settings.translation.messageLanguage", defaultValue: .string("")
        ),
        SettingsPreferenceRegistration(
            id: .translationDraftLanguage, page: .features,
            key: "settings.translation.draftLanguage", defaultValue: .string("en")
        ),
        SettingsPreferenceRegistration(
            id: .readAllButton, page: .features,
            key: "settings.features.readAllButton", defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .channelManagement, page: .features,
            key: "settings.features.channelManagement", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .showHiddenChannels, page: .features,
            key: "settings.features.showHiddenChannels", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .fakeNitroEmojis, page: .features,
            key: "settings.features.fakeNitroEmojis", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .fakeNitroStickers, page: .features,
            key: "settings.features.fakeNitroStickers", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .fakeNitroSoundboard, page: .features,
            key: "settings.features.fakeNitroSoundboard", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .fakeNitroStreamQuality, page: .features,
            key: "settings.features.fakeNitroStreamQuality", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .unlimitedFavorites, page: .features,
            key: "settings.features.unlimitedFavorites", defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .voiceMessageRecording, page: .features,
            key: "settings.features.voiceMessageRecording", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .messageHoverActions, page: .features,
            key: "settings.features.messageHoverActions", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .scrollToBottomButton, page: .features,
            key: "settings.features.scrollToBottomButton", defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .attachmentCompactionPrompt, page: .features,
            key: "settings.attachments.attachmentCompactionPrompt", defaultValue: .string(AttachmentHandlingPolicy.ask.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .attachmentExternalUploadPrompt, page: .features,
            key: "settings.attachments.attachmentExternalUploadPrompt", defaultValue: .string(AttachmentHandlingPolicy.ask.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .attachmentExternalProvider, page: .features,
            key: "settings.attachments.externalProvider", defaultValue: .string(ExternalAttachmentHostingService.litterbox.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .attachmentCompactionQuality, page: .features,
            key: "settings.attachments.attachmentCompactionQuality", defaultValue: .string(AttachmentCompactionOptions.Quality.balanced.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .localStorageLimit,
            page: .storageDownloads,
            key: "mediaCacheLimit",
            defaultValue: .integer(2_147_483_648)
        ),
        SettingsPreferenceRegistration(
            id: .mediaCacheLastCleared,
            page: .storageDownloads,
            key: "settings.storage.mediaCacheLastCleared",
            defaultValue: .double(0),
            exports: false,
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .downloadFolderBookmark,
            page: .storageDownloads,
            key: "settings.storage.downloadFolderBookmark",
            defaultValue: .string(""),
            exports: false
        ),
        SettingsPreferenceRegistration(
            id: .downloadFolderName,
            page: .storageDownloads,
            key: "settings.storage.downloadFolderName",
            defaultValue: .string(""),
            exports: false
        ),
        SettingsPreferenceRegistration(
            id: .revealCompletedDownloads,
            page: .storageDownloads,
            key: "settings.storage.revealCompletedDownloads",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .notificationEnabled,
            page: .notifications,
            key: NotificationPreferenceKeys.enabled,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationPreview,
            page: .notifications,
            key: NotificationPreferenceKeys.preview,
            defaultValue: .string(NotificationPreviewStyle.full.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .notificationSound,
            page: .notifications,
            key: NotificationPreferenceKeys.sound,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationMessageSound,
            page: .notifications,
            key: NotificationSoundKeys.messageSoundID,
            defaultValue: .string(NotificationSoundLibrary.bundledID)
        ),
        SettingsPreferenceRegistration(
            id: .notificationCallRingtone,
            page: .notifications,
            key: NotificationSoundKeys.callRingtoneID,
            defaultValue: .string(NotificationSoundLibrary.bundledID)
        ),
        SettingsPreferenceRegistration(
            id: .notificationDockBadge,
            page: .notifications,
            key: NotificationPreferenceKeys.dockBadge,
            defaultValue: .string(NotificationDockBadgeStyle.mentions.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .notificationDirectMessages,
            page: .notifications,
            key: NotificationPreferenceKeys.directMessages,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationGroupDirectMessages,
            page: .notifications,
            key: NotificationPreferenceKeys.groupDirectMessages,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationMentions,
            page: .notifications,
            key: NotificationPreferenceKeys.mentions,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationReplies,
            page: .notifications,
            key: NotificationPreferenceKeys.replies,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationIncomingCalls,
            page: .notifications,
            key: NotificationPreferenceKeys.incomingCalls,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationServerActivity,
            page: .notifications,
            key: NotificationPreferenceKeys.serverActivity,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationSuppressCurrent,
            page: .notifications,
            key: NotificationPreferenceKeys.suppressCurrentConversation,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationGroupBursts,
            page: .notifications,
            key: NotificationPreferenceKeys.groupByConversation,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationClearWhenRead,
            page: .notifications,
            key: NotificationPreferenceKeys.clearWhenRead,
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceInputDevice,
            page: .voiceVideo,
            key: "voiceInputDeviceUID",
            defaultValue: .string("")
        ),
        SettingsPreferenceRegistration(
            id: .voiceOutputDevice,
            page: .voiceVideo,
            key: "voiceOutputDeviceUID",
            defaultValue: .string("")
        ),
        SettingsPreferenceRegistration(
            id: .voiceCamera,
            page: .voiceVideo,
            key: "voiceCameraUID",
            defaultValue: .string("")
        ),
        SettingsPreferenceRegistration(
            id: .voiceInputVolume,
            page: .voiceVideo,
            key: "voiceInputVolume",
            defaultValue: .double(1)
        ),
        SettingsPreferenceRegistration(
            id: .voiceOutputVolume,
            page: .voiceVideo,
            key: "voiceOutputVolume",
            defaultValue: .double(1)
        ),
        SettingsPreferenceRegistration(
            id: .voiceJoinMuted,
            page: .voiceVideo,
            key: "voice.joinMuted",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .voiceJoinDeafened,
            page: .voiceVideo,
            key: "voice.joinDeafened",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .voiceFeedbackSounds,
            page: .voiceVideo,
            key: "voice.feedbackSounds",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceRememberCamera,
            page: .voiceVideo,
            key: "voice.remembersCamera",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceMirrorPreview,
            page: .voiceVideo,
            key: "voice.mirrorsLocalPreview",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceJoinCameraOff,
            page: .voiceVideo,
            key: "voice.joinsWithCameraOff",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceScreenShareQuality,
            page: .voiceVideo,
            key: "voice.screenShare.quality",
            defaultValue: .string(ScreenShareQuality.p720.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .voiceScreenShareFrameRate,
            page: .voiceVideo,
            key: "voice.screenShare.frameRate",
            defaultValue: .integer(ScreenShareFrameRate.fps30.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .voiceScreenShareAudio,
            page: .voiceVideo,
            key: "voice.screenShare.includesAudio",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .voiceScreenSharePointer,
            page: .voiceVideo,
            key: "voice.screenShare.showsPointer",
            defaultValue: .bool(true)
        ),

        SettingsPreferenceRegistration(
            id: .accessibilityDisableSendAnimations,
            page: .accessibility,
            key: "settings.accessibility.disableMessageSendingAnimations",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableAllAnimations,
            page: .accessibility,
            key: "settings.accessibility.disableAllAnimations",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableSidebarAnimations,
            page: .accessibility,
            key: "settings.accessibility.disableSidebarAnimations",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableSideChatAnimations,
            page: .accessibility,
            key: "settings.accessibility.disableSideChatAnimations",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableOverlayAnimations,
            page: .accessibility,
            key: "settings.accessibility.disableOverlayAnimations",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableOwnCosmetics,
            page: .accessibility,
            key: "settings.accessibility.disableOwnCosmetics",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableProfileEffects,
            page: .accessibility,
            key: "settings.accessibility.disableProfileEffects",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableNameplates,
            page: .accessibility,
            key: "settings.accessibility.disableNameplates",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableAvatarDecorations,
            page: .accessibility,
            key: "settings.accessibility.disableAvatarDecorations",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableProfileFrames,
            page: .accessibility,
            key: "settings.accessibility.disableProfileFrames",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableNameStyles,
            page: .accessibility,
            key: "settings.accessibility.disableNameStyles",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityDisableProfileGradients,
            page: .accessibility,
            key: "settings.accessibility.disableProfileGradients",
            defaultValue: .bool(false)
        ),

        SettingsPreferenceRegistration(
            id: .accessibilityDisableServerTags,
            page: .accessibility,
            key: "settings.accessibility.disableServerTags",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityAnnounceTimestamp,
            page: .accessibility,
            key: "settings.accessibility.announceTimestamp",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityAnnounceEdited,
            page: .accessibility,
            key: "settings.accessibility.announceEdited",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityAnnounceReactions,
            page: .accessibility,
            key: "settings.accessibility.announceReactions",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityAnnounceAttachmentTypes,
            page: .accessibility,
            key: "settings.accessibility.announceAttachmentTypes",
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityAnnounceNewMessages,
            page: .accessibility,
            key: "settings.accessibility.announceNewMessages",
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .externalLinkProtection,
            page: .privacySafety,
            key: "settings.privacy.externalLinkConfirmationPolicy",
            defaultValue: .string(ExternalLinkConfirmationPolicy.untrustedDomains.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .trustedDomains,
            page: .privacySafety,
            key: "settings.privacy.trustedDomains",
            defaultValue: .strings(ExternalLinkTrustedDomain.defaults),
            exports: false
        ),
        SettingsPreferenceRegistration(
            id: .diagnosticConnectionMetrics,
            page: .diagnostics,
            key: DiagnosticsPreferences.capturesConnectionMetricsKey,
            defaultValue: .bool(false),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .diagnosticDetailedPayloads,
            page: .diagnostics,
            key: DiagnosticsPreferences.capturesDetailedPayloadsKey,
            defaultValue: .bool(false),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .diagnosticPanicSave,
            page: .diagnostics,
            key: DiagnosticsPreferences.enablesPanicSaveKey,
            defaultValue: .bool(true),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .diagnosticDiskCapture,
            page: .diagnostics,
            key: DiagnosticsPreferences.savesDiagnosticsToDiskKey,
            defaultValue: .bool(false),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .updateReleaseTrack,
            page: .softwareUpdates,
            key: AppUpdateReleaseTrack.preferenceKey,
            defaultValue: .string(AppUpdateReleaseTrack.regular.rawValue),
            resets: false
        ),
    ] + KeyboardShortcutAction.allCases.map { action in
        SettingsPreferenceRegistration(
            id: action.controlID,
            page: .keyboardShortcuts,
            key: "settings.shortcuts.\(action.rawValue)",
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

    func registrations(page: SettingsPageID? = nil) -> [SettingsPreferenceRegistration] {
        registrations.filter { page == nil || $0.page == page }
    }
}

final class SettingsPreferenceStore {
    static let shared = SettingsPreferenceStore()

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
        let legacyRoleKey = "settings.interface.showRoleColors"
        let roleKey = "settings.accessibility.roleColorDisplay"
        if defaults.object(forKey: roleKey) == nil,
           let enabled = defaults.object(forKey: legacyRoleKey) as? Bool {
            defaults.set(enabled ? RoleColorDisplay.inNames.rawValue : RoleColorDisplay.hidden.rawValue, forKey: roleKey)
        }
        defaults.removeObject(forKey: legacyRoleKey)
        let legacyMessagesKey = "settings.appearance.messages"
        if let raw = defaults.object(forKey: legacyMessagesKey) as? String,
           MessageAppearance(rawValue: raw) != nil {
            for id: SettingsControlID in [.messageAppearance, .directMessageAppearance, .groupMessageAppearance]
                where !containsStoredValue(for: id) {
                set(.string(raw), for: id)
            }
        }
        defaults.removeObject(forKey: legacyMessagesKey)
        seedTrustedDomains()
    }

    /// This marker is not registered: resets restore defaults without re-running migration.
    private func seedTrustedDomains() {
        let key = "settings.privacy.trustedDomains.seeded.v1"
        guard defaults.object(forKey: key) as? Bool != true,
              registry.registration(.trustedDomains) != nil,
              !ExternalLinkTrustedDomain.defaults.isEmpty
        else { return }
        let existing: [String] = if case let .strings(domains) = value(for: .trustedDomains) {
            domains
        } else {
            []
        }
        set(
            .strings(ExternalLinkTrustedDomain.normalizedList(existing + ExternalLinkTrustedDomain.defaults)),
            for: .trustedDomains
        )
        defaults.set(true, forKey: key)
    }

    /// The stored value, or the default when nothing valid is stored.
    func value(for id: SettingsControlID) -> SettingsPreferenceValue {
        guard let registration = registry.registration(id) else {
            preconditionFailure("\(id.rawValue) has no registered preference.")
        }
        guard let stored = defaults.object(forKey: registration.key).flatMap(registration.defaultValue.accepts),
              registration.accepts(stored)
        else { return registration.defaultValue }
        return stored
    }

    func bool(_ id: SettingsControlID) -> Bool {
        guard case let .bool(stored) = value(for: id) else { preconditionFailure("\(id.rawValue) is not a Bool.") }
        return stored
    }

    func integer(_ id: SettingsControlID) -> Int {
        guard case let .integer(stored) = value(for: id) else { preconditionFailure("\(id.rawValue) is not an Int.") }
        return stored
    }

    func double(_ id: SettingsControlID) -> Double {
        guard case let .double(stored) = value(for: id) else { preconditionFailure("\(id.rawValue) is not a Double.") }
        return stored
    }

    func string(_ id: SettingsControlID) -> String {
        guard case let .string(stored) = value(for: id) else { preconditionFailure("\(id.rawValue) is not a String.") }
        return stored
    }

    /// A stored string as the value it names. The registration validates the raw value.
    func rawValue<Value: RawRepresentable>(_ id: SettingsControlID) -> Value where Value.RawValue == String {
        guard let value = Value(rawValue: string(id)) else {
            preconditionFailure("\(id.rawValue) does not validate \(Value.self).")
        }
        return value
    }

    func containsStoredValue(for id: SettingsControlID) -> Bool {
        guard let registration = registry.registration(id) else { return false }
        return defaults.object(forKey: registration.key) != nil
    }

    func set(_ value: SettingsPreferenceValue, for id: SettingsControlID) {
        guard let registration = registry.registration(id),
              registration.defaultValue.accepts(value.defaultsValue) != nil
        else { return }
        defaults.set(value.defaultsValue, forKey: registration.key)
    }

    func reset(page: SettingsPageID? = nil) {
        for registration in registry.registrations(page: page) where registration.resets {
            defaults.removeObject(forKey: registration.key)
        }
    }

    /// The exportable values, by control ID.
    func export(page: SettingsPageID? = nil) -> [String: SettingsPreferenceValue] {
        let registrations = registry.registrations(page: page)
            .filter(\.exports)
        var values: [String: SettingsPreferenceValue] = [:]
        for registration in registrations {
            let value = value(for: registration.id)
            // A custom sound is a machine-local file bookmark, like the download folder,
            // so only its ID would travel and Import would silently restore Default.
            if value == .string(NotificationSoundLibrary.customID) { continue }
            values[registration.id.rawValue] = value
        }
        return values
    }
}
