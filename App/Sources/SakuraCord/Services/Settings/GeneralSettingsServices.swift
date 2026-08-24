import AppKit
import DiscordProtocol
import Foundation
import Observation
import ServiceManagement

nonisolated enum SettingsLaunchDestination: String, CaseIterable, Identifiable, Sendable {
    case lastVisitedConversation
    case preferredAccountLastLocation
    case accountPicker

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .lastVisitedConversation:
            LocalizedStringResource("Last visited conversation", bundle: #bundle)
        case .preferredAccountLastLocation:
            LocalizedStringResource("Preferred account's last location", bundle: #bundle)
        case .accountPicker:
            LocalizedStringResource("Account picker", bundle: #bundle)
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .lastVisitedConversation:
            LocalizedStringResource(
                "Reopens the last conversation used across all saved accounts.",
                bundle: #bundle
            )
        case .preferredAccountLastLocation:
            LocalizedStringResource(
                "Uses the launch account chosen in My Account, then restores its last accessible conversation.",
                bundle: #bundle
            )
        case .accountPicker:
            LocalizedStringResource(
                "Shows saved accounts without contacting Discord until you choose one.",
                bundle: #bundle
            )
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
        destination: SettingsLaunchDestination,
        performanceAccountID: String?,
        lastVisitedAccountID: String?,
        reopensLastActiveAccount: Bool,
        lastActiveAccountID: String?,
        preferredLaunchAccountID: String?
    ) -> CredentialHandle? {
        if let performanceAccountID {
            return RestoredCredentialSelectionPolicy.handle(
                from: handles,
                preferredAccountID: performanceAccountID
            )
        }
        if destination == .lastVisitedConversation,
           let lastVisitedAccountID
        {
            return RestoredCredentialSelectionPolicy.handle(
                from: handles,
                preferredAccountID: lastVisitedAccountID
            )
        }
        return SettingsAccountLaunchPolicy.handle(
            from: handles,
            reopensLastActiveAccount: reopensLastActiveAccount,
            lastActiveAccountID: lastActiveAccountID,
            preferredLaunchAccountID: preferredLaunchAccountID
        )
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
    private static let accountsKey = "settings.accountConversationLocations.v1"

    private let defaults: any PreferenceStoring
    private var pendingLaunchRestoration: SettingsConversationRestoration?

    init(defaults: any PreferenceStoring = UserDefaults.standard) {
        self.defaults = defaults
    }

    func record(accountID: String, guildID: String?, channelID: String) {
        let restoration = SettingsConversationRestoration(
            accountID: accountID,
            guildID: guildID,
            channelID: channelID
        )
        persist(restoration, forKey: Self.globalKey)
        var accounts = accountRestorations()
        accounts[accountID] = restoration
        persist(accounts, forKey: Self.accountsKey)
    }

    func preferredAccountID(for destination: SettingsLaunchDestination) -> String? {
        guard destination == .lastVisitedConversation else { return nil }
        return restoration(forKey: Self.globalKey)?.accountID
    }

    func prepareLaunch(
        destination: SettingsLaunchDestination,
        selectedAccountID: String
    ) {
        switch destination {
        case .lastVisitedConversation:
            pendingLaunchRestoration = restoration(forKey: Self.globalKey)
        case .preferredAccountLastLocation:
            pendingLaunchRestoration = accountRestorations()[selectedAccountID]
        case .accountPicker:
            pendingLaunchRestoration = nil
        }
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

    private func accountRestorations() -> [String: SettingsConversationRestoration] {
        guard let data = defaults.data(forKey: Self.accountsKey) else { return [:] }
        return (try? JSONDecoder().decode(
            [String: SettingsConversationRestoration].self,
            from: data
        )) ?? [:]
    }

    private func persist(_ value: some Encodable, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class GeneralWindowRestorationStore {
    static let shared = GeneralWindowRestorationStore()

    private static let memberListVisibleKey = "settings.memberListVisible"
    private let defaults: any PreferenceStoring

    init(defaults: any PreferenceStoring = UserDefaults.standard) {
        self.defaults = defaults
    }

    var memberListIsVisible: Bool {
        guard let value = defaults.object(forKey: Self.memberListVisibleKey) as? Bool else {
            return true
        }
        return value
    }

    func recordMemberListVisibility(_ isVisible: Bool) {
        defaults.set(isVisible, forKey: Self.memberListVisibleKey)
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }

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
    private(set) var status: SMAppService.Status
    private(set) var isChanging = false
    private(set) var errorMessage: String?

    init(service: (any LaunchAtLoginServicing)? = nil) {
        let service = service ?? SystemLaunchAtLoginService()
        self.service = service
        status = service.status
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }
    var isAvailable: Bool { status != .notFound }

    var statusDescription: LocalizedStringResource {
        switch status {
        case .notRegistered:
            LocalizedStringResource("Not registered", bundle: #bundle)
        case .enabled:
            LocalizedStringResource("Registered and enabled by macOS", bundle: #bundle)
        case .requiresApproval:
            LocalizedStringResource("Approval required in System Settings", bundle: #bundle)
        case .notFound:
            LocalizedStringResource("The main-app login service is unavailable in this build", bundle: #bundle)
        @unknown default:
            LocalizedStringResource("Unknown macOS login-item status", bundle: #bundle)
        }
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        guard !isChanging, isAvailable else { return }
        errorMessage = nil
        if enabled, requiresApproval {
            errorMessage = "Approve SakuraCord under Login Items in System Settings, then refresh this status."
            return
        }
        isChanging = true
        defer {
            status = service.status
            isChanging = false
        }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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

nonisolated enum GeneralComposerDiscardPolicy {
    static func shouldConfirmEdit(
        isEnabled: Bool,
        original: String,
        current: String
    ) -> Bool {
        isEnabled && current != original
    }

    static func shouldConfirmUnsentContent(isEnabled: Bool, itemCount: Int) -> Bool {
        isEnabled && itemCount > 0
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
        if externalAttachmentUploadTask != nil || externalAttachmentUploadPresentation != nil {
            activities.append(.upload)
        }
        return activities
    }
}
