@testable import SakuraCord
import DiscordProtocol
import Foundation
import ServiceManagement
import Testing

@MainActor
@Test func `Launch at Login mirrors Service Management status and reverts errors`() {
    let service = LaunchAtLoginServiceSpy(status: .notRegistered)
    let controller = LaunchAtLoginController(service: service)

    #expect(!controller.isEnabled)
    controller.setEnabled(true)
    #expect(controller.isEnabled)
    #expect(service.registerCount == 1)

    service.nextError = GeneralSettingsTestError.denied
    controller.setEnabled(false)
    #expect(controller.isEnabled)
    #expect(controller.errorMessage == GeneralSettingsTestError.denied.localizedDescription)

    service.status = .requiresApproval
    controller.refresh()
    controller.setEnabled(true)
    #expect(!controller.isEnabled)
    #expect(controller.requiresApproval)
    #expect(service.registerCount == 1)
    #expect(controller.errorMessage != nil)
    controller.openSystemSettings()
    #expect(service.openSettingsCount == 1)

    service.status = .notFound
    controller.refresh()
    #expect(!controller.isAvailable)
}

@Test func `every launch destination selects its account boundary safely`() {
    let first = CredentialHandle(accountID: "100")
    let second = CredentialHandle(accountID: "200")
    let handles = [first, second]

    #expect(
        SettingsLaunchAccountPolicy.handle(
            from: handles,
            destination: .lastVisitedConversation,
            performanceAccountID: nil,
            lastVisitedAccountID: second.accountID,
            reopensLastActiveAccount: true,
            lastActiveAccountID: first.accountID,
            preferredLaunchAccountID: first.accountID
        ) == second
    )
    #expect(
        SettingsLaunchAccountPolicy.handle(
            from: handles,
            destination: .preferredAccountLastLocation,
            performanceAccountID: nil,
            lastVisitedAccountID: second.accountID,
            reopensLastActiveAccount: false,
            lastActiveAccountID: second.accountID,
            preferredLaunchAccountID: first.accountID
        ) == first
    )
    #expect(
        SettingsLaunchAccountPolicy.presentsAccountPicker(
            destination: .accountPicker,
            performanceAccountID: nil
        )
    )
    #expect(
        !SettingsLaunchAccountPolicy.presentsAccountPicker(
            destination: .accountPicker,
            performanceAccountID: second.accountID
        )
    )
}

@MainActor
@Test func `conversation restoration stays account scoped and consumes once`() {
    let store = SettingsConversationRestorationStore(
        defaults: InMemoryPreferences()
    )
    store.record(accountID: "100", guildID: "10", channelID: "11")
    store.record(accountID: "200", guildID: nil, channelID: "22")

    #expect(
        store.preferredAccountID(for: .lastVisitedConversation) == "200"
    )
    store.prepareLaunch(
        destination: .preferredAccountLastLocation,
        selectedAccountID: "100"
    )
    #expect(
        store.consumeLaunchRestoration(accountID: "100")
            == SettingsConversationRestoration(
                accountID: "100",
                guildID: "10",
                channelID: "11"
            )
    )
    #expect(store.consumeLaunchRestoration(accountID: "100") == nil)

    store.prepareLaunch(
        destination: .lastVisitedConversation,
        selectedAccountID: "100"
    )
    #expect(store.consumeLaunchRestoration(accountID: "100") == nil)
    #expect(store.consumeLaunchRestoration(accountID: "200") == nil)

    store.prepareLaunch(destination: .accountPicker, selectedAccountID: "100")
    #expect(store.consumeLaunchRestoration(accountID: "100") == nil)
}

@MainActor
@Test func `General confirmation policies prompt only for meaningful active work`() {
    #expect(
        !GeneralQuitConfirmationPolicy.shouldConfirm(
            isEnabled: true,
            activities: []
        )
    )
    #expect(
        GeneralQuitConfirmationPolicy.shouldConfirm(
            isEnabled: true,
            activities: [.call]
        )
    )
    #expect(
        !GeneralQuitConfirmationPolicy.shouldConfirm(
            isEnabled: false,
            activities: [.call, .screenShare, .upload]
        )
    )
    #expect(
        !GeneralComposerDiscardPolicy.shouldConfirmEdit(
            isEnabled: true,
            original: "unchanged",
            current: "unchanged"
        )
    )
    #expect(
        GeneralComposerDiscardPolicy.shouldConfirmEdit(
            isEnabled: true,
            original: "before",
            current: "after"
        )
    )
    #expect(
        !GeneralComposerDiscardPolicy.shouldConfirmUnsentContent(
            isEnabled: true,
            itemCount: 0
        )
    )
    #expect(
        GeneralComposerDiscardPolicy.shouldConfirmUnsentContent(
            isEnabled: true,
            itemCount: 1
        )
    )
}

@MainActor
@Test func `General preferences and Settings disclosure restore safely`() {
    let defaults = InMemoryPreferences()
    let store = SettingsPreferenceStore(defaults: defaults)
    store.set(.string(SettingsLaunchDestination.accountPicker.rawValue), for: .launchDestination)
    store.set(.bool(false), for: .showMainWindowAtLaunch)
    store.set(.bool(false), for: .confirmQuitActiveWork)

    #expect(
        store.export(scope: .appWide, page: .general).values[
            SettingsControlID.launchDestination.rawValue
        ] == .string(SettingsLaunchDestination.accountPicker.rawValue)
    )
    store.reset(scope: .appWide, page: .general)
    #expect(
        store.value(for: .launchDestination)
            == .string(SettingsLaunchDestination.preferredAccountLastLocation.rawValue)
    )
    #expect(store.value(for: .showMainWindowAtLaunch) == .bool(true))
    #expect(store.value(for: .confirmQuitActiveWork) == .bool(true))

    let viewState = SettingsViewState()
    viewState.restoreExpandedGroups(from: "account,removed-group")
    #expect(viewState.expandedGroups == [.account])
    viewState.navigate(
        to: SettingsDestination(page: .general, section: .confirmations),
        controlID: .confirmQuitActiveWork
    )
    #expect(viewState.expandedGroups.contains(.preferences))

    let windowStore = GeneralWindowRestorationStore(defaults: defaults)
    #expect(windowStore.memberListIsVisible)
    windowStore.recordMemberListVisibility(false)
    #expect(!windowStore.memberListIsVisible)
}

@MainActor
@Test func `General catalog search reaches each scoped control`() {
    let expected: Set<SettingsControlID> = [
        .launchAtLogin,
        .launchDestination,
        .showMainWindowAtLaunch,
        .rememberMemberListVisibility,
        .confirmQuitActiveWork,
        .confirmDiscardComposer,
    ]
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .general
            && expected.contains($0.id)
    }
    #expect(Set(controls.map(\.id)) == expected)
    #expect(controls.allSatisfy { $0.scope == .appWideLocal })

    let search = SettingsViewState()
    search.searchText = "login item"
    #expect(search.searchResults.contains { $0.id == .launchAtLogin })
    search.searchText = "discard unsent attachments"
    #expect(search.searchResults.contains { $0.id == .confirmDiscardComposer })
    search.searchText = "member inspector restore"
    #expect(search.searchResults.contains { $0.id == .rememberMemberListVisibility })
}

@MainActor
private final class LaunchAtLoginServiceSpy: LaunchAtLoginServicing {
    var status: SMAppService.Status
    var nextError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        status = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

private enum GeneralSettingsTestError: LocalizedError {
    case denied

    var errorDescription: String? { "Login item change denied" }
}
