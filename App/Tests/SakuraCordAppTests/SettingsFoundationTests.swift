@testable import SakuraCord
import Foundation
import Testing

@MainActor
@Test func `settings catalog has stable unique destinations and complete metadata`() {
    let catalog = SettingsCatalog.foundation

    #expect(catalog.pages.map(\.id) == SettingsPageID.allCases)
    #expect(Set(catalog.pages.map(\.id)).count == catalog.pages.count)
    #expect(
        Set(catalog.pages.map(\.overviewControlID)).count
            == catalog.pages.count
    )
    #expect(Set(catalog.controls.map(\.id)).count == catalog.controls.count)
    #expect(
        Set(catalog.pages.map(\.group))
            == Set(SettingsSidebarGroupID.allCases)
    )

    for control in catalog.controls {
        #expect(catalog.pages.contains { $0.id == control.destination.page })
        #expect(control.destination.section != nil)
        #expect(control.owner.rawValue.isEmpty == false)
        #expect(control.persistence.rawValue.isEmpty == false)
    }

    let registeredIDs = Set(
        SettingsPreferenceRegistry.foundation.registrations.map(\.id)
    )
    for control in catalog.controls
        where control.resetCapability == .registeredLocalValue
    {
        #expect(registeredIDs.contains(control.id))
    }
}

@MainActor
@Test func `settings search routes synonyms to stable controls`() {
    let state = SettingsViewState()

    state.searchText = "microphone gain"
    let inputVolume = state.searchResults.first { $0.id == .voiceInputVolume }
    #expect(inputVolume?.destination.page == .voiceVideo)
    #expect(inputVolume?.destination.section == .voiceLevels)

    #expect(state.activateFirstSearchResult())
    #expect(state.selectedPage == .voiceVideo)
    #expect(state.revealRequest?.controlID == .voiceInputVolume)
    #expect(state.highlightedControlID == .voiceInputVolume)
    #expect(state.searchText.isEmpty)

    state.searchText = "no setting matches this phrase"
    #expect(!state.activateFirstSearchResult())
    #expect(state.selectedPage == .voiceVideo)

    state.searchText = "hotkeys"
    #expect(state.searchResults.first?.destination.page == .keyboardShortcuts)

    for query in ["Extensions", "plugins", "permissions", "sandboxing"] {
        state.searchText = query
        #expect(
            state.searchResults.contains {
                $0.id == .overview(.extensions)
                    && $0.destination.page == .extensions
            }
        )
    }
}

@MainActor
@Test func `registered preference export and reset stay scoped and omit unknown values`() throws {
    let appValueID = SettingsControlID(rawValue: "test.app-value")
    let accountValueID = SettingsControlID(rawValue: "test.account-value")
    let registry = SettingsPreferenceRegistry(registrations: [
        SettingsPreferenceRegistration(
            id: appValueID,
            page: .chat,
            storage: .appWide(key: "test.app-value"),
            defaultValue: .bool(true)
        ),
        SettingsPreferenceRegistration(
            id: accountValueID,
            page: .chat,
            storage: .accountLocal(key: "test.account-value"),
            defaultValue: .string("default")
        ),
    ])
    let defaults = InMemoryPreferences()
    defaults.set("credential-secret", forKey: "unregistered.credential")
    let store = SettingsPreferenceStore(registry: registry, defaults: defaults)

    store.set(.bool(false), for: appValueID)
    store.set(.string("first"), for: accountValueID, accountID: "account-a")
    store.set(.string("second"), for: accountValueID, accountID: "account-b")

    let appExport = store.export(scope: .appWide, page: .chat)
    #expect(appExport.schema == SettingsPreferenceExport.schema)
    #expect(appExport.version == SettingsPreferenceExport.currentVersion)
    #expect(appExport.values == [appValueID.rawValue: .bool(false)])

    let accountExport = store.export(
        scope: .accountLocal,
        page: .chat,
        accountID: "account-a"
    )
    #expect(accountExport.values == [accountValueID.rawValue: .string("first")])
    let encoded = try accountExport.encodedData()
    let encodedText = try #require(String(data: encoded, encoding: .utf8))
    #expect(!encodedText.contains("credential-secret"))
    #expect(!encodedText.contains("account-a"))
    #expect(!encodedText.contains("second"))

    store.reset(scope: .accountLocal, page: .chat, accountID: "account-a")
    #expect(store.value(for: accountValueID, accountID: "account-a") == .string("default"))
    #expect(store.value(for: accountValueID, accountID: "account-b") == .string("second"))

    store.reset(scope: .appWide, page: .chat)
    #expect(store.value(for: appValueID) == .bool(true))
    #expect(defaults.string(forKey: "unregistered.credential") == "credential-secret")
}
