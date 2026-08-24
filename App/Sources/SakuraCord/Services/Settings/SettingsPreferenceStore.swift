import CoreTransferable
import Foundation
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
            id: .showChannelHeader,
            page: .interface,
            storage: .appWide(key: "settings.interface.showChannelHeader"),
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
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatAutomaticCorrection,
            page: .chat,
            storage: .appWide(key: "settings.chat.automaticCorrection"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatSmartQuotes,
            page: .chat,
            storage: .appWide(key: "settings.chat.smartQuotes"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: .chatSmartDashes,
            page: .chat,
            storage: .appWide(key: "settings.chat.smartDashes"),
            defaultValue: .bool(true)
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
            id: .notificationEnabled,
            page: .notifications,
            storage: .appWide(key: "notifications.enabled"),
            defaultValue: .bool(true),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .notificationPreview,
            page: .notifications,
            storage: .appWide(key: "notifications.preview"),
            defaultValue: .string("full"),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .notificationSound,
            page: .notifications,
            storage: .appWide(key: "notifications.sound"),
            defaultValue: .bool(true),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .notificationDockBadge,
            page: .notifications,
            storage: .appWide(key: "notifications.dockBadge"),
            defaultValue: .bool(true),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .notificationQuietHours,
            page: .notifications,
            storage: .appWide(key: "notifications.quietHours"),
            defaultValue: .bool(false),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .notificationQuietStart,
            page: .notifications,
            storage: .appWide(key: "notifications.quietStart"),
            defaultValue: .integer(22),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .notificationQuietEnd,
            page: .notifications,
            storage: .appWide(key: "notifications.quietEnd"),
            defaultValue: .integer(8),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .voiceInputDevice,
            page: .voiceVideo,
            storage: .appWide(key: "voiceInputDeviceUID"),
            defaultValue: .string(""),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .voiceOutputDevice,
            page: .voiceVideo,
            storage: .appWide(key: "voiceOutputDeviceUID"),
            defaultValue: .string(""),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .voiceCamera,
            page: .voiceVideo,
            storage: .appWide(key: "voiceCameraUID"),
            defaultValue: .string(""),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .voiceInputVolume,
            page: .voiceVideo,
            storage: .appWide(key: "voiceInputVolume"),
            defaultValue: .double(1),
            resets: false
        ),
        SettingsPreferenceRegistration(
            id: .voiceOutputVolume,
            page: .voiceVideo,
            storage: .appWide(key: "voiceOutputVolume"),
            defaultValue: .double(1),
            resets: false
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
            page: .general,
            storage: .appWide(key: AppUpdateReleaseTrack.preferenceKey),
            defaultValue: .string(AppUpdateReleaseTrack.regular.rawValue),
            resets: false
        ),
    ])

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
