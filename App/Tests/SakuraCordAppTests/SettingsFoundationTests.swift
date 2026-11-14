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
    }
}

@MainActor
@Test func `settings search routes synonyms to stable controls`() throws {
    let state = SettingsViewState()

    state.searchText = "microphone gain"
    let inputVolume = state.searchResults.first { $0.id == .voiceInputVolume }
    #expect(inputVolume?.destination.page == .voiceVideo)
    #expect(inputVolume?.destination.section == .voiceLevels)

    #expect(state.activateFirstSearchResult())
    #expect(state.selectedPage == .voiceVideo)
    #expect(state.revealRequest?.controlID == .voiceInputVolume)
    #expect(state.highlightedControlID == .voiceInputVolume)
    #expect(state.sectionID(for: .voiceInputVolume) == .voiceLevels)
    #expect(state.searchText.isEmpty)

    state.searchText = "no setting matches this phrase"
    #expect(!state.activateFirstSearchResult())
    #expect(state.selectedPage == .voiceVideo)

    state.searchText = "hotkeys"
    #expect(state.searchResults.first?.destination.page == .keyboardShortcuts)

    state.searchText = "typing"
    let typingIDs = state.searchResults.map(\.id)
    try #require(typingIDs.count > 1)
    #expect(state.selectedSearchResultID == typingIDs.first)
    state.moveSearchSelection(by: 1)
    #expect(state.selectedSearchResultID == typingIDs[1])
    state.moveSearchSelection(by: -1)
    #expect(state.selectedSearchResultID == typingIDs[0])
    state.moveSearchSelection(by: -1)
    #expect(state.selectedSearchResultID == typingIDs.last)
    #expect(state.activateSelectedSearchResult())
    #expect(state.revealRequest?.controlID == typingIDs.last)
    #expect(state.searchText.isEmpty)
    #expect(state.selectedSearchResultID == nil)

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
@Test func `registered preference export and reset stay scoped and omit unknown values`() {
    let appValueID = SettingsControlID(rawValue: "test.app-value")
    let registry = SettingsPreferenceRegistry(registrations: [
        SettingsPreferenceRegistration(
            id: appValueID,
            page: .general,
            key: "test.app-value",
            defaultValue: .bool(true)
        ),
    ])
    let defaults = InMemoryPreferences()
    defaults.set("credential-secret", forKey: "unregistered.credential")
    let store = SettingsPreferenceStore(registry: registry, defaults: defaults)

    store.set(.bool(false), for: appValueID)
    #expect(store.export(page: .general) == [appValueID.rawValue: .bool(false)])

    store.reset(page: .general)
    #expect(store.value(for: appValueID) == .bool(true))
    #expect(defaults.string(forKey: "unregistered.credential") == "credential-secret")
}
