import DiscordProtocol
import Foundation
@testable import SakuraCord
import Testing

@Suite("AppleMusicPresenceMonitorTests")
struct AppleMusicPresenceMonitorTests {
    @Test("Playing track creates listening activity with timestamps and assets")
    func testPlayingTrackCreatesListeningActivity() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let monitor = AppleMusicPresenceMonitor(
            coordinator: coordinator,
            nowProvider: { fixedDate }
        )

        let payload: [AnyHashable: Any] = [
            "Player State": "Playing",
            "Name": "Blinding Lights",
            "Artist": "The Weeknd",
            "Album": "After Hours",
            "Current Position": 45.0,
            "Total Time": 200000.0 // 200 seconds in ms
        ]

        let activity = await monitor.handlePlayerInfo(payload)
        #expect(activity != nil)
        #expect(activity?.name == "Apple Music")
        #expect(activity?.type == .listening)
        #expect(activity?.details == "Blinding Lights")
        #expect(activity?.state == "The Weeknd")
        #expect(activity?.assets?.largeImage == "apple_music")
        #expect(activity?.assets?.largeText == "After Hours")

        let expectedStartMs = Int64((1_700_000_000.0 - 45.0) * 1000)
        let expectedEndMs = expectedStartMs + 200_000
        #expect(activity?.timestamps?.start == expectedStartMs)
        #expect(activity?.timestamps?.end == expectedEndMs)

        let permitted = await coordinator.currentPermittedActivities()
        #expect(permitted.count == 1)
        #expect(permitted[.appleMusic]?.details == "Blinding Lights")
    }

    @Test("Paused or stopped track clears published activity")
    func testPausedOrStoppedTrackClearsActivity() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider)
        let monitor = AppleMusicPresenceMonitor(coordinator: coordinator)

        await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Levitating",
            "Artist": "Dua Lipa"
        ])
        #expect(await coordinator.currentPermittedActivities().count == 1)

        // Paused state
        let pausedResult = await monitor.handlePlayerInfo([
            "Player State": "Paused",
            "Name": "Levitating"
        ])
        #expect(pausedResult == nil)
        #expect(await coordinator.currentPermittedActivities().isEmpty)

        // Playing again
        await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Levitating",
            "Artist": "Dua Lipa"
        ])
        #expect(await coordinator.currentPermittedActivities().count == 1)

        // Stopped state
        let stoppedResult = await monitor.handlePlayerInfo([
            "Player State": "Stopped"
        ])
        #expect(stoppedResult == nil)
        #expect(await coordinator.currentPermittedActivities().isEmpty)
    }

    @Test("Missing or empty track title clears activity")
    func testEmptyTrackTitleClearsActivity() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider)
        let monitor = AppleMusicPresenceMonitor(coordinator: coordinator)

        await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "As It Was"
        ])
        #expect(await coordinator.currentPermittedActivities().count == 1)

        let result = await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "   "
        ])
        #expect(result == nil)
        #expect(await coordinator.currentPermittedActivities().isEmpty)
    }

    @Test("Track with missing optional metadata formats gracefully")
    func testMissingOptionalMetadata() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let monitor = AppleMusicPresenceMonitor(
            coordinator: coordinator,
            nowProvider: { fixedDate }
        )

        let result = await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Mystery Instrumental"
        ])

        #expect(result?.details == "Mystery Instrumental")
        #expect(result?.state == nil)
        #expect(result?.assets?.largeImage == "apple_music")
        #expect(result?.assets?.largeText == "Apple Music")
        #expect(result?.timestamps?.start != nil)
        #expect(result?.timestamps?.end == nil)
    }

    @Test("Privacy preference disables Apple Music presence")
    func testPrivacyPreferenceDisablesPresence() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(
            provider: provider,
            preferences: ActivityCoordinatorPreferences(isAppleMusicPresenceEnabled: false)
        )
        let monitor = AppleMusicPresenceMonitor(coordinator: coordinator)

        await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Don't Start Now",
            "Artist": "Dua Lipa"
        ])

        #expect(await coordinator.currentPermittedActivities().isEmpty)
    }

    @Test("Lifecycle start and stop unregisters cleanly")
    func testStartAndStopLifecycle() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider)
        let monitor = AppleMusicPresenceMonitor(coordinator: coordinator)

        monitor.start()
        await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Song",
            "Artist": "Artist"
        ])
        #expect(await coordinator.currentPermittedActivities().count == 1)

        monitor.stop()
        // Wait briefly for coordinator clear task
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await coordinator.currentPermittedActivities().isEmpty)
    }
}
