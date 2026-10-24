import AppKit
import DiscordProtocol
import Foundation
import Observation
import ServiceManagement

nonisolated enum SettingsLaunchDestination: String, CaseIterable, Identifiable, Sendable {
    case lastVisitedConversation
    case accountPicker

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .lastVisitedConversation:
            LocalizedStringResource("Last open conversation", bundle: #bundle)
        case .accountPicker:
            LocalizedStringResource("Account picker", bundle: #bundle)
        }
    }
}

nonisolated enum SettingsLaunchAccountPolicy {
    static func presentsAccountPicker(
        destination: SettingsLaunchDestination,
        performanceAccountID: String?
    ) -> Bool {
        destination == .accountPicker && performanceAccountID == nil
    }

    static func handle(
        from handles: [CredentialHandle],
        performanceAccountID: String?,
        lastVisitedAccountID: String?,
        lastActiveAccountID: String?
    ) -> CredentialHandle? {
        if let performanceAccountID {
            return RestoredCredentialSelectionPolicy.handle(from: handles, preferredAccountID: performanceAccountID)
        }
        if let lastVisitedAccountID,
           let handle = handles.first(where: { $0.accountID == lastVisitedAccountID }) {
            return handle
        }
        return RestoredCredentialSelectionPolicy.handle(from: handles, preferredAccountID: lastActiveAccountID)
    }
}

nonisolated struct SettingsConversationRestoration: Codable, Equatable, Sendable {
    let accountID: String
    let guildID: String?
    let channelID: String
}

@MainActor
final class SettingsConversationRestorationStore {
    static let shared = SettingsConversationRestorationStore()

    private static let globalKey = "settings.lastVisitedConversation.v1"

    private let defaults: any PreferenceStoring
    private var pendingLaunchRestoration: SettingsConversationRestoration?

    init(defaults: any PreferenceStoring = PRBuildProfile.defaults) {
        self.defaults = defaults
    }

    func record(accountID: String, guildID: String?, channelID: String) {
        let restoration = SettingsConversationRestoration(
            accountID: accountID,
            guildID: guildID,
            channelID: channelID
        )
        persist(restoration, forKey: Self.globalKey)
    }

    func preferredAccountID(for destination: SettingsLaunchDestination) -> String? {
        guard destination == .lastVisitedConversation else { return nil }
        return restoration(forKey: Self.globalKey)?.accountID
    }

    func prepareLaunch(destination: SettingsLaunchDestination) {
        pendingLaunchRestoration = destination == .lastVisitedConversation
            ? restoration(forKey: Self.globalKey) : nil
    }

    func consumeLaunchRestoration(accountID: String?) -> SettingsConversationRestoration? {
        defer { pendingLaunchRestoration = nil }
        guard pendingLaunchRestoration?.accountID == accountID else { return nil }
        return pendingLaunchRestoration
    }

    private func restoration(forKey key: String) -> SettingsConversationRestoration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SettingsConversationRestoration.self, from: data)
    }

    private func persist(_ value: some Encodable, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class GeneralWindowRestorationStore {
    static let shared = GeneralWindowRestorationStore()

    private static let legacyMemberListVisibleKey = "settings.memberListVisible"
    private let defaults: any PreferenceStoring

    init(defaults: any PreferenceStoring = PRBuildProfile.defaults) {
        self.defaults = defaults
    }

    static func visibilityKey(for context: InspectorContext) -> String {
        switch context {
        case .server: legacyMemberListVisibleKey
        case .directMessage: "settings.directMessageProfileVisible"
        case .groupDirectMessage: "settings.groupDirectMessageMembersVisible"
        }
    }

    /// Conversation kinds saved before they had separate keys start from the shared
    /// member-list value, then keep their own copy so later changes stay independent.
    func loadInspectorVisibility() -> InspectorVisibility {
        let legacyValue = defaults.object(forKey: Self.legacyMemberListVisibleKey) as? Bool
        var visibility = InspectorVisibility()
        for context in InspectorContext.allCases {
            let key = Self.visibilityKey(for: context)
            if let value = defaults.object(forKey: key) as? Bool {
                visibility[context] = value
            } else if let legacyValue {
                visibility[context] = legacyValue
                defaults.set(legacyValue, forKey: key)
            }
        }
        return visibility
    }

    func recordInspectorVisibility(_ visibility: InspectorVisibility) {
        for context in InspectorContext.allCases {
            defaults.set(visibility[context], forKey: Self.visibilityKey(for: context))
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    func currentStatus() async -> SMAppService.Status
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    func currentStatus() async -> SMAppService.Status {
        await Task.detached(priority: .userInitiated) {
            SMAppService.mainApp.status
        }.value
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
@Observable
final class LaunchAtLoginController {
    private let service: any LaunchAtLoginServicing
    private(set) var status: SMAppService.Status?
    private var isRefreshing = false
    private(set) var isChanging = false
    private(set) var errorMessage: String?

    init(service: (any LaunchAtLoginServicing)? = nil) {
        self.service = service ?? SystemLaunchAtLoginService()
        status = nil
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }
    var isAvailable: Bool { status != nil && status != .notFound }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        status = await service.currentStatus()
    }

    func refreshIfNeeded() async {
        guard status == nil else { return }
        await refresh()
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isChanging, isAvailable else { return }
        errorMessage = nil
        if enabled, requiresApproval {
            errorMessage = "Approve SakuraCord under Login Items in System Settings, then refresh this status."
            return
        }
        isChanging = true
        defer { isChanging = false }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        status = await service.currentStatus()
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}

nonisolated enum GeneralQuitActivity: String, CaseIterable, Sendable {
    case call
    case screenShare
    case upload

    var title: String {
        switch self {
        case .call: "an active call"
        case .screenShare: "a screen share"
        case .upload: "an active upload"
        }
    }
}

nonisolated enum GeneralQuitConfirmationPolicy {
    static func shouldConfirm(isEnabled: Bool, activities: [GeneralQuitActivity]) -> Bool {
        isEnabled && !activities.isEmpty
    }
}

extension AppModel {
    var generalQuitActivities: [GeneralQuitActivity] {
        var activities: [GeneralQuitActivity] = []
        if activeVoiceChannel != nil {
            activities.append(.call)
        }
        if localApplicationStreamKey != nil {
            activities.append(.screenShare)
        }
        if activeAttachmentUploadCount > 0 || externalAttachmentUploadTask != nil || attachmentCompactionTask != nil {
            activities.append(.upload)
        }
        return activities
    }
}
