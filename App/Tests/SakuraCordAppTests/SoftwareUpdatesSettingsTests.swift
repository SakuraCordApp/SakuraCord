import Testing
@testable import SakuraCord

@MainActor
@Test("Software Updates owns all updater controls and General owns none")
func softwareUpdatesCatalogOwnership() {
    let expected: Set<SettingsControlID> = [
        .updateReleaseTrack,
        .updateAutomaticChecks,
        .updateAutomaticDownloads,
        .updateStatus,
        .updateLastSuccessfulCheck,
        .checkForUpdates,
    ]
    let updateControls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .softwareUpdates && expected.contains($0.id)
    }
    let generalUpdateControls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .general && expected.contains($0.id)
    }

    #expect(Set(updateControls.map(\.id)) == expected)
    #expect(generalUpdateControls.isEmpty)

    let search = SettingsViewState()
    search.searchText = "last successful appcast"
    #expect(search.searchResults.contains { $0.id == .updateLastSuccessfulCheck })
    search.searchText = "nightly release channel"
    #expect(search.searchResults.contains { $0.id == .updateReleaseTrack })
}
