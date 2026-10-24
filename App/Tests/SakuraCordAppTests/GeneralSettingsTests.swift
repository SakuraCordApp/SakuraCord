@testable import SakuraCord
import DiscordProtocol
import Foundation
import ServiceManagement
import Testing

@MainActor
@Test func `Launch at Login mirrors Service Management status and reverts errors`() async {
    let service = LaunchAtLoginServiceSpy(status: .notRegistered)
    let controller = LaunchAtLoginController(service: service)
    await controller.refresh()
    await controller.refreshIfNeeded()

    #expect(!controller.isEnabled)
    #expect(service.statusReadCount == 1)
    await controller.setEnabled(true)
    #expect(controller.isEnabled)
    #expect(service.registerCount == 1)

    service.nextError = GeneralSettingsTestError.denied
    await controller.setEnabled(false)
    #expect(controller.isEnabled)
    #expect(controller.errorMessage == GeneralSettingsTestError.denied.localizedDescription)

    service.status = .requiresApproval
    await controller.refresh()
    await controller.setEnabled(true)
    #expect(controller.isEnabled)
    #expect(controller.requiresApproval)
    #expect(service.registerCount == 1)
    #expect(controller.errorMessage != nil)
    controller.openSystemSettings()
    #expect(service.openSettingsCount == 1)
    await controller.setEnabled(false)
    #expect(!controller.isEnabled)
    #expect(!controller.requiresApproval)

    service.status = .notFound
    await controller.refresh()
    #expect(!controller.isAvailable)
}

@Test func `every launch destination selects its account boundary safely`() {
    let first = CredentialHandle(accountID: "100")
    let second = CredentialHandle(accountID: "200")
    let handles = [first, second]

    #expect(
        SettingsLaunchAccountPolicy.handle(
            from: handles,
            performanceAccountID: nil,
            lastVisitedAccountID: second.accountID,
            lastActiveAccountID: first.accountID
        ) == second
    )
    #expect(
        SettingsLaunchAccountPolicy.handle(
            from: handles,
            performanceAccountID: nil,
            lastVisitedAccountID: "removed-account",
            lastActiveAccountID: second.accountID
        ) == second
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
        destination: .lastVisitedConversation
    )
    #expect(
        store.consumeLaunchRestoration(accountID: "200")
            == SettingsConversationRestoration(
                accountID: "200",
                guildID: nil,
                channelID: "22"
            )
    )
    #expect(store.consumeLaunchRestoration(accountID: "100") == nil)

    store.prepareLaunch(
        destination: .lastVisitedConversation
    )
    #expect(store.consumeLaunchRestoration(accountID: "100") == nil)
    #expect(store.consumeLaunchRestoration(accountID: "200") == nil)

    store.prepareLaunch(destination: .accountPicker)
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
}

@MainActor
@Test func `General preferences export and reset safely`() {
    let defaults = InMemoryPreferences()
    defaults.set("preferredAccountLastLocation", forKey: "settings.launchDestination")
    defaults.set(false, forKey: "settings.showMainWindowAtLaunch")
    defaults.set(false, forKey: "settings.memberListVisible")
    let store = SettingsPreferenceStore(defaults: defaults)
    #expect(store.value(for: .launchDestination) == .string(SettingsLaunchDestination.lastVisitedConversation.rawValue))
    #expect(defaults.object(forKey: "settings.showMainWindowAtLaunch") == nil)
    store.set(.string(SettingsLaunchDestination.accountPicker.rawValue), for: .launchDestination)
    store.set(.bool(false), for: .confirmQuitActiveWork)

    #expect(
        store.export(scope: .appWide, page: .general).values[
            SettingsControlID.launchDestination.rawValue
        ] == .string(SettingsLaunchDestination.accountPicker.rawValue)
    )
    store.reset(scope: .appWide, page: .general)
    #expect(
        store.value(for: .launchDestination)
            == .string(SettingsLaunchDestination.lastVisitedConversation.rawValue)
    )
    #expect(store.value(for: .confirmQuitActiveWork) == .bool(true))

    let windowStore = GeneralWindowRestorationStore(defaults: defaults)
    var visibility = windowStore.loadInspectorVisibility()
    #expect(visibility == InspectorVisibility(server: false, directMessage: false, groupDirectMessage: false))
    visibility.server = true
    windowStore.recordInspectorVisibility(visibility)
    #expect(
        GeneralWindowRestorationStore(defaults: defaults).loadInspectorVisibility()
            == InspectorVisibility(server: true, directMessage: false, groupDirectMessage: false)
    )
}

@MainActor
@Test func `General catalog search reaches each scoped control`() {
    let expected: Set<SettingsControlID> = [
        .launchAtLogin,
        .launchDestination,
        .confirmQuitActiveWork,
        .sendWithReturn, .spellCheck, .automaticCorrection, .smartQuotes, .smartDashes, .emojiSkinTone,
    ]
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .general
            && expected.contains($0.id)
    }
    #expect(Set(controls.map(\.id)) == expected)
    #expect(controls.allSatisfy { $0.scope == .appWideLocal })

    let search = SettingsViewState()
    search.searchText = "autocorrect"
    #expect(search.searchResults.contains { $0.id == .automaticCorrection && $0.destination.page == .general })
    search.searchText = "login item"
    #expect(search.searchResults.contains { $0.id == .launchAtLogin })
}

@MainActor
private final class LaunchAtLoginServiceSpy: LaunchAtLoginServicing {
    var status: SMAppService.Status
    var nextError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0
    private(set) var statusReadCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func currentStatus() async -> SMAppService.Status {
        statusReadCount += 1
        return status
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

@MainActor
@Test func `General input preferences preserve existing values and reset independently of Privacy`() {
    let defaults = InMemoryPreferences()
    defaults.set(true, forKey: "settings.chat.spellCheck")
    defaults.set("dark", forKey: "emojiSkinTone")
    defaults.set(false, forKey: "settings.chat.typingIndicators")
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = GeneralInputSettingsStore(preferences: preferences)
    let privacyStore = PrivacySafetySettingsStore(preferences: preferences)

    var value = store.load()
    #expect(value.checksSpelling)
    #expect(value.emojiSkinTone == .dark)
    #expect(!privacyStore.load().sendsTypingIndicators)
    #expect(value.sendsWithReturn)
    value.sendsWithReturn = false
    value.usesSmartQuotes = true
    store.save(value)
    #expect(store.load() == value)
    let export = preferences.export(scope: .appWide, page: .general)
    #expect(export.values[SettingsControlID.sendWithReturn.rawValue] == .bool(false))
    #expect(export.values[SettingsControlID.spellCheck.rawValue] == .bool(true))
    #expect(export.values[SettingsControlID.emojiSkinTone.rawValue] == .string("dark"))
    #expect(export.values[SettingsControlID.privacyTypingIndicators.rawValue] == nil)

    preferences.reset(scope: .appWide, page: .general)
    #expect(store.load() == .defaults)
    #expect(!privacyStore.load().sendsTypingIndicators)
}
