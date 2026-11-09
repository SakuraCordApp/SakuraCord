@testable import DiscordProtocol
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

struct ActivityCoordinatorTests {
    @Test func `coordinator publishes permitted activity to provider`() async throws {
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)

        let music = OutgoingActivityPayload(
            name: "Apple Music",
            type: .listening,
            details: "Song Name",
            state: "Artist Name"
        )

        await coordinator.setActivity(music, for: .appleMusic)

        #expect(await coordinator.isSourceActive(.appleMusic))
        let activitiesOnProvider = await mockProvider.currentActivities()
        #expect(activitiesOnProvider["apple_music"] == music)
    }

    @Test func `clearing activity removes it from coordinator and provider`() async throws {
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)

        let rpcActivity = OutgoingActivityPayload(
            name: "VS Code",
            type: .playing,
            details: "Editing Code"
        )
        let source = ActivitySource.localRPC(sourceID: "vscode-1", clientID: "123456", processID: 999)

        await coordinator.setActivity(rpcActivity, for: source)
        #expect(await coordinator.isSourceActive(source))
        #expect(await mockProvider.currentActivities()[source.sourceID] == rpcActivity)

        await coordinator.clearActivity(for: source)
        #expect(await coordinator.isSourceActive(source) == false)
        #expect(await mockProvider.currentActivities()[source.sourceID] == nil)
    }

    @Test func `master privacy toggle suppresses all activities from publishing`() async throws {
        let mockProvider = MockChatProvider()
        var prefs = ActivityCoordinatorPreferences()
        prefs = .enabledAll
        prefs.isActivitySharingEnabled = false
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: prefs)

        let music = OutgoingActivityPayload(name: "Apple Music", type: .listening)
        await coordinator.setActivity(music, for: .appleMusic)

        // Activity is registered in coordinator, but suppressed from provider
        #expect(await coordinator.isSourceActive(.appleMusic))
        #expect(await coordinator.currentPermittedActivities().isEmpty)
        #expect(await mockProvider.currentActivities().isEmpty)

        // Re-enabling sharing publishes the registered activity immediately
        prefs.isActivitySharingEnabled = true
        await coordinator.updatePreferences(prefs)

        #expect(await coordinator.currentPermittedActivities().count == 1)
        #expect(await mockProvider.currentActivities()["apple_music"] == music)
    }

    @Test func `source specific privacy toggles filter out respective sources`() async throws {
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)

        let music = OutgoingActivityPayload(name: "Apple Music", type: .listening)
        let rpc = OutgoingActivityPayload(name: "Modrinth", type: .playing)
        let rpcSource = ActivitySource.localRPC(sourceID: "modrinth", clientID: "777", processID: nil)

        await coordinator.setActivity(music, for: .appleMusic)
        await coordinator.setActivity(rpc, for: rpcSource)

        #expect(await mockProvider.currentActivities().count == 2)

        // Disable Apple Music presence
        var prefs = await coordinator.currentPreferences()
        prefs.isAppleMusicPresenceEnabled = false
        await coordinator.updatePreferences(prefs)

        let activitiesAfterFilter = await mockProvider.currentActivities()
        #expect(activitiesAfterFilter["apple_music"] == nil)
        #expect(activitiesAfterFilter[rpcSource.sourceID] == rpc)

        // Disable Local RPC presence as well
        prefs.isLocalRPCEnabled = false
        await coordinator.updatePreferences(prefs)

        #expect(await mockProvider.currentActivities().isEmpty)
    }

    @Test func `swapping provider re-synchronizes active permitted activities`() async throws {
        let initialProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: initialProvider, preferences: .enabledAll)

        let music = OutgoingActivityPayload(name: "Apple Music", type: .listening)
        await coordinator.setActivity(music, for: .appleMusic)
        #expect(await initialProvider.currentActivities().count == 1)

        let newProvider = MockChatProvider()
        #expect(await newProvider.currentActivities().isEmpty)

        await coordinator.setProvider(newProvider)
        #expect(await newProvider.currentActivities()["apple_music"] == music)
    }
}
