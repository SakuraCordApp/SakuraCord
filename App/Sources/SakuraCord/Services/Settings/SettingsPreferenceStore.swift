import CoreTransferable
import Foundation
import MediaPipeline
import UniformTypeIdentifiers

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
            id: .reopenLastAccount,
            page: .myAccount,
            storage: .appWide(key: "settings.reopenLastActiveAccount"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .preferredLaunchAccount,
            page: .myAccount,
            storage: .appWide(key: "settings.preferredLaunchAccountID"),
            defaultValue: .string("")
        ),
        SettingsPreferenceRegistration(
            id: .launchDestination,
            page: .general,
            storage: .appWide(key: "settings.launchDestination"),
            defaultValue: .string(SettingsLaunchDestination.preferredAccountLastLocation.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .showMainWindowAtLaunch,
            page: .general,
            storage: .appWide(key: "settings.showMainWindowAtLaunch"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .rememberMemberListVisibility,
            page: .general,
            storage: .appWide(key: "settings.rememberMemberListVisibility"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .confirmQuitActiveWork,
            page: .general,
            storage: .appWide(key: "settings.confirmQuitActiveWork"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .confirmDiscardComposer,
            page: .general,
            storage: .appWide(key: "settings.confirmDiscardComposer"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .appColorScheme,
            page: .appearance,
            storage: .appWide(key: "settings.appearance.colorScheme"),
            defaultValue: .string(AppColorScheme.system.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .gradientTheme,
            page: .appearance,
            storage: .appWide(key: "settings.appearance.gradientTheme"),
            defaultValue: .string(SakuraCordThemePreset.system.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .customGradientTheme,
            page: .appearance,
            storage: .appWide(key: "settings.appearance.customGradientTheme"),
            defaultValue: .string(SakuraCordGradientTheme.defaultCustom.storageValue)
        ),
        SettingsPreferenceRegistration(
            id: .composerBarAppearance,
            page: .appearance,
            storage: .appWide(key: "settings.appearance.composerBar"),
            defaultValue: .string(ComposerBarAppearance.defaultStyle.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .messageDensity,
            page: .interface,
            storage: .appWide(key: "settings.interface.messageDensity"),
            defaultValue: .string(InterfaceMessageDensity.comfortable.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .sidebarDensity,
            page: .interface,
            storage: .appWide(key: "settings.interface.sidebarDensity"),
            defaultValue: .string(InterfaceSidebarDensity.comfortable.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .messageTextSize,
            page: .interface,
            storage: .appWide(key: "settings.interface.messageTextSize"),
            defaultValue: .double(15)
        ),
        SettingsPreferenceRegistration(
            id: .interfaceTextSize,
            page: .interface,
            storage: .appWide(key: "settings.interface.interfaceTextSize"),
            defaultValue: .double(13)
        ),
        SettingsPreferenceRegistration(
            id: .timestampFormat,
            page: .interface,
            storage: .appWide(key: "settings.interface.timestampFormat"),
            defaultValue: .string(InterfaceTimestampFormat.system.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .timestampSeconds,
            page: .interface,
            storage: .appWide(key: "settings.interface.timestampSeconds"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .groupingInterval,
            page: .interface,
            storage: .appWide(key: "settings.interface.groupingIntervalMinutes"),
            defaultValue: .integer(7)
        ),
        SettingsPreferenceRegistration(
            id: .underlineLinks,
            page: .interface,
            storage: .appWide(key: "settings.interface.underlineLinks"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .showMemberList,
            page: .interface,
            storage: .appWide(key: "settings.memberListVisible"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .showActivityDetails,
            page: .interface,
            storage: .appWide(key: "settings.interface.showActivityDetails"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .messageActionVisibility,
            page: .interface,
            storage: .appWide(key: "settings.interface.messageActionVisibility"),
            defaultValue: .string(InterfaceMessageActionVisibility.onHover.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .showRoleColors,
            page: .interface,
            storage: .appWide(key: "settings.interface.showRoleColors"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .sendWithReturn,
            page: .chat,
            storage: .appWide(key: "sendWithReturn"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatSpellCheck,
            page: .chat,
            storage: .appWide(key: "settings.chat.spellCheck"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .chatAutomaticCorrection,
            page: .chat,
            storage: .appWide(key: "settings.chat.automaticCorrection"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .chatSmartQuotes,
            page: .chat,
            storage: .appWide(key: "settings.chat.smartQuotes"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .chatSmartDashes,
            page: .chat,
            storage: .appWide(key: "settings.chat.smartDashes"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .chatTypingIndicators,
            page: .chat,
            storage: .appWide(key: "settings.chat.typingIndicators"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatFocusComposerOnTyping,
            page: .chat,
            storage: .appWide(key: "settings.chat.focusComposerOnTyping"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatReadAcknowledgement,
            page: .chat,
            storage: .appWide(key: "settings.chat.readAcknowledgement"),
            defaultValue: .string(ChatReadAcknowledgementMode.automatic.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .chatEditedMarkers,
            page: .chat,
            storage: .appWide(key: "settings.chat.editedMarkers"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatExpandEmbeds,
            page: .chat,
            storage: .appWide(key: "settings.chat.expandEmbeds"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatSpoilerReveal,
            page: .chat,
            storage: .appWide(key: "settings.chat.spoilerReveal"),
            defaultValue: .string(ChatSpoilerRevealMode.click.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .chatInternalDiscordLinks,
            page: .chat,
            storage: .appWide(key: "settings.chat.internalDiscordLinks"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatAutoplayGIFs,
            page: .chat,
            storage: .appWide(key: "settings.chat.autoplayGIFs"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatAutoplayStickers,
            page: .chat,
            storage: .appWide(key: "settings.chat.autoplayStickers"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatAutoplayVideos,
            page: .chat,
            storage: .appWide(key: "settings.chat.autoplayVideos"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatLinkPreviews,
            page: .chat,
            storage: .appWide(key: "settings.chat.linkPreviews"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatInlineMediaSize,
            page: .chat,
            storage: .appWide(key: "settings.chat.inlineMediaSize"),
            defaultValue: .string(ChatInlineMediaSize.medium.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .reduceAnimatedMedia,
            page: .chat,
            storage: .appWide(key: "reduceAnimatedMedia"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .chatEmojiSkinTone,
            page: .chat,
            storage: .appWide(key: "emojiSkinTone"),
            defaultValue: .string(NativeEmojiSkinTone.standard.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .mediaCacheLimit,
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
            id: .downloadLocationMode,
            page: .storageDownloads,
            storage: .appWide(key: "settings.storage.downloadLocationMode"),
            defaultValue: .string(DownloadLocationMode.askEveryTime.rawValue)
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
            id: .downloadCollisionPolicy,
            page: .storageDownloads,
            storage: .appWide(key: "settings.storage.downloadCollisionPolicy"),
            defaultValue: .string(
                DownloadFilenameCollisionPolicy.automaticallyRename.rawValue
            )
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
            id: .notificationOnlyInBackground,
            page: .notifications,
            storage: .appWide(key: "notifications.onlyInBackground"),
            defaultValue: .bool(false)
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
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .notificationClearWhenRead,
            page: .notifications,
            storage: .appWide(key: "notifications.clearWhenRead"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationCallsBypassSuppression,
            page: .notifications,
            storage: .appWide(key: "notifications.callsBypassMessageSuppression"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .notificationQuietHours,
            page: .notifications,
            storage: .appWide(key: "notifications.quietHours"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .notificationQuietDays,
            page: .notifications,
            storage: .appWide(key: "notifications.quietDays"),
            defaultValue: .strings((1 ... 7).map(String.init))
        ),
        SettingsPreferenceRegistration(
            id: .notificationQuietStart,
            page: .notifications,
            storage: .appWide(key: "notifications.quietStart"),
            defaultValue: .integer(22 * 60)
        ),
        SettingsPreferenceRegistration(
            id: .notificationQuietEnd,
            page: .notifications,
            storage: .appWide(key: "notifications.quietEnd"),
            defaultValue: .integer(8 * 60)
        ),
        SettingsPreferenceRegistration(
            id: .notificationWeekendQuietStart,
            page: .notifications,
            storage: .appWide(key: "notifications.weekendQuietStart"),
            defaultValue: .integer(22 * 60)
        ),
        SettingsPreferenceRegistration(
            id: .notificationWeekendQuietEnd,
            page: .notifications,
            storage: .appWide(key: "notifications.weekendQuietEnd"),
            defaultValue: .integer(8 * 60)
        ),
        SettingsPreferenceRegistration(
            id: .notificationAllowDirectMessages,
            page: .notifications,
            storage: .appWide(key: "notifications.allowDirectMessagesDuringQuietHours"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .notificationAllowCalls,
            page: .notifications,
            storage: .appWide(key: "notifications.allowCallsDuringQuietHours"),
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
            defaultValue: .string(ScreenShareQuality.p1080.rawValue)
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
            id: .accessibilityMotionOverride,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.motionOverride"),
            defaultValue: .string(AccessibilityMotionOverride.followMacOS.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityReduceAnimatedContent,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.reduceAnimatedContent"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityReduceAnimatedEmoji,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.reduceAnimatedEmoji"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityReduceAnimatedStickers,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.reduceAnimatedStickers"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityReduceGIFs,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.reduceGIFs"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityReduceAnimatedAvatars,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.reduceAnimatedAvatars"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityReduceDecorations,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.reduceDecorations"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityReduceTransitions,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.reduceTransitions"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityIncreaseContrast,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.increaseContrast"),
            defaultValue: .bool(false)
        ),
        SettingsPreferenceRegistration(
            id: .accessibilityLargerTargets,
            page: .accessibility,
            storage: .appWide(key: "settings.accessibility.largerTargets"),
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
            id: .externalUploaderPolicy,
            page: .privacySafety,
            storage: .appWide(key: "settings.privacy.externalUploaderPolicy"),
            defaultValue: .string(ExternalUploaderOfferPolicy.ask.rawValue)
        ),
        SettingsPreferenceRegistration(
            id: .diagnosticDiskCapture,
            page: .diagnostics,
            storage: .appWide(key: "saveAPIDiagnosticsToDisk"),
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

nonisolated struct SettingsPreferenceExportFile: Transferable, Sendable {
    let export: SettingsPreferenceExport

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { file in
            try file.export.encodedData()
        }
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
