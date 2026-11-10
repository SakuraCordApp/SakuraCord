import DiscordProtocol
import Foundation
import SakuraCordModels
@testable import SakuraCord
import Testing

@Suite("AppleMusicPresenceMonitorTests")
struct AppleMusicPresenceMonitorTests {
    private final class TimeBox: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    @Test("Playing track creates listening activity with timestamps and assets")
    func testPlayingTrackCreatesListeningActivity() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider, preferences: .enabledAll)
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
        #expect(activity?.assets?.largeImage == "apple_music" || activity?.assets?.largeImage?.hasPrefix("https://") == true)
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
        let coordinator = ActivityCoordinator(provider: provider, preferences: .enabledAll)
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

    @Test("Resuming paused track retains elapsed position instead of starting at zero")
    func testResumingPausedTrackRetainsPosition() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider, preferences: .enabledAll)

        let timeBox = TimeBox(Date(timeIntervalSince1970: 1_700_000_000))
        let monitor = AppleMusicPresenceMonitor(
            coordinator: coordinator,
            nowProvider: { timeBox.date }
        )

        // 1. Play track starting at position 30s
        let initialActivity = await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Starboy",
            "Artist": "The Weeknd",
            "Current Position": 30.0,
            "Total Time": 240000.0
        ])
        #expect(initialActivity != nil)
        let initialStart = initialActivity?.timestamps?.start
        #expect(initialStart == Int64((1_700_000_000.0 - 30.0) * 1000))

        // 2. Play for 20 seconds
        timeBox.date = timeBox.date.addingTimeInterval(20) // elapsed is now 50s

        // 3. Pause
        let pausedActivity = await monitor.handlePlayerInfo([
            "Player State": "Paused",
            "Name": "Starboy",
            "Artist": "The Weeknd"
        ])
        #expect(pausedActivity == nil)

        // 4. Stay paused for 10 seconds
        timeBox.date = timeBox.date.addingTimeInterval(10)

        // 5. Resume playing where notification omits Current Position (defaults to 0)
        let resumedActivity = await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Starboy",
            "Artist": "The Weeknd",
            "Total Time": 240000.0
        ])
        #expect(resumedActivity != nil)

        // The resumed start timestamp should reflect the 50s elapsed playback, NOT 0s
        let expectedResumedStart = Int64((timeBox.date.timeIntervalSince1970 - 50.0) * 1000)
        #expect(resumedActivity?.timestamps?.start == expectedResumedStart)
    }

    @Test("Spotify payload correctly parses app name and playback position")
    func testSpotifyPayloadParsing() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider, preferences: .enabledAll)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let monitor = AppleMusicPresenceMonitor(
            coordinator: coordinator,
            nowProvider: { fixedDate }
        )

        let spotifyPayload: [AnyHashable: Any] = [
            "Player State": "Playing",
            "Name": "Flowers",
            "Artist": "Miley Cyrus",
            "Album": "Endless Summer Vacation",
            "Playback Position": 65.0,
            "Duration": 200400.0,
            "Track ID": "spotify:track:4DHsvvY3y6N9N0"
        ]

        let activity = await monitor.handlePlayerInfo(spotifyPayload)
        #expect(activity != nil)
        #expect(activity?.name == "Spotify")
        #expect(activity?.details == "Flowers")
        #expect(activity?.state == "Miley Cyrus")
        #expect(activity?.assets?.largeText == "Endless Summer Vacation")

        let expectedStartMs = Int64((1_700_000_000.0 - 65.0) * 1000)
        #expect(activity?.timestamps?.start == expectedStartMs)
    }

    @Test("Missing or empty track title clears activity")
    func testEmptyTrackTitleClearsActivity() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider, preferences: .enabledAll)
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
        let coordinator = ActivityCoordinator(provider: provider, preferences: .enabledAll)
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
        #expect(result?.assets?.largeImage == "apple_music" || result?.assets?.largeImage?.hasPrefix("https://") == true)
        #expect(result?.assets?.largeText == "Apple Music")
        #expect(result?.timestamps?.start != nil)
        #expect(result?.timestamps?.end == nil)
    }

    @Test("Privacy preference disables Apple Music presence")
    func testPrivacyPreferenceDisablesPresence() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(
            provider: provider,
            preferences: ActivityCoordinatorPreferences(isActivitySharingEnabled: true, isAppleMusicPresenceEnabled: false)
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
        let coordinator = ActivityCoordinator(provider: provider, preferences: .enabledAll)
        let monitor = AppleMusicPresenceMonitor(coordinator: coordinator)

        monitor.start()
        await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Song",
            "Artist": "Artist"
        ])
        #expect(await coordinator.currentPermittedActivities().count == 1)

        monitor.stop()
        let cleared = await eventually { await coordinator.currentPermittedActivities().isEmpty }
        #expect(cleared)
    }

    @Test("Scrubbing track updates timeline position via position query")
    func testScrubbingTrackUpdatesTimeline() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider, preferences: .enabledAll)

        let timeBox = TimeBox(Date(timeIntervalSince1970: 1_700_000_000))
        let positionBox = TimeBox(Date(timeIntervalSince1970: 10))

        let monitor = AppleMusicPresenceMonitor(
            coordinator: coordinator,
            nowProvider: { timeBox.date },
            positionQueryProvider: { _ in positionBox.date.timeIntervalSince1970 }
        )

        // 1. Initial play at 10s
        let initial = await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Blinding Lights",
            "Artist": "The Weeknd",
            "Current Position": 10.0,
            "Total Time": 200000.0
        ])
        #expect(initial != nil)
        #expect(initial?.timestamps?.start == Int64((1_700_000_000.0 - 10.0) * 1000))

        // 2. Play 10s naturally (elapsed is 20s, player position is 20s)
        timeBox.date = timeBox.date.addingTimeInterval(10)
        positionBox.date = Date(timeIntervalSince1970: 20)

        // 3. User scrubs forward to 120s!
        positionBox.date = Date(timeIntervalSince1970: 120)

        // Resumed/drift notification without explicit position key
        let scrubbed = await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Blinding Lights",
            "Artist": "The Weeknd",
            "Total Time": 200000.0
        ])
        #expect(scrubbed != nil)
        let expectedScrubbedStart = Int64((timeBox.date.timeIntervalSince1970 - 120.0) * 1000)
        #expect(scrubbed?.timestamps?.start == expectedScrubbedStart)
    }

    @Test("Current user activity is properly injected into member list rows and cached stores")
    @MainActor
    func testCurrentUserActivityInMemberList() async {
        let model = AppModel(launchMode: .offlineTesting)
        await model.start()
        guard model.currentUser?.id != nil else {
            #expect(Bool(false), "Current user must be present in offline testing")
            return
        }

        let activity = OutgoingActivityPayload(
            name: "Apple Music",
            type: .listening,
            details: "Starboy",
            state: "The Weeknd"
        )

        // 1. Apply activity
        model.applyCurrentUserActivity(activity)
        #expect(model.currentUserActivity?.details == "Starboy")
        #expect(model.isCurrentUserListeningToMusic == true)
        #expect(model.currentUserActivityDisplayText == "Starboy")

        // 2. Member list restored for a guild (e.g. from server snapshot where member has no activity)
        let rawMember = Member(
            user: model.currentUser!,
            roleName: "Member",
            status: .online
        )
        #expect(rawMember.activityText == nil)
        #expect(rawMember.isListeningToMusic == false)

        // 3. membersWithCurrentStatus should inject current user activity
        let decorated = model.memberWithCurrentStatus(rawMember)
        #expect(decorated.status == model.currentStatus)
        #expect(decorated.activityText == "Starboy")
        #expect(decorated.isListeningToMusic == true)
        #expect(decorated.richActivity?.name == "Apple Music")
        #expect(decorated.richActivity?.details == "Starboy")
        #expect(decorated.memberListActivityText == "Starboy")

        // 4. Custom status priority in member list
        var memberWithCustom = rawMember
        memberWithCustom.customStatus = "Coding"
        let decoratedWithCustom = model.memberWithCurrentStatus(memberWithCustom)
        #expect(decoratedWithCustom.activityText == "Starboy")
        #expect(decoratedWithCustom.isListeningToMusic == true)
        #expect(decoratedWithCustom.memberListActivityText == "Coding")
        #expect(decoratedWithCustom.memberListShowsMusicSeparator == true)

        // 5. Clearing activity clears member row activity
        model.applyCurrentUserActivity(nil)
        let cleared = model.memberWithCurrentStatus(rawMember)
        #expect(cleared.activityText == nil)
        #expect(cleared.isListeningToMusic == false)
        #expect(cleared.richActivity == nil)
    }

    @Test("Game rich presence displays game name in member list instead of party state")
    @MainActor
    func testGameRichPresenceDisplayTextPrioritizesGameName() async {
        let model = AppModel(launchMode: .offlineTesting)
        await model.start()
        guard model.currentUser != nil else { return }

        let gameActivity = OutgoingActivityPayload(
            name: "Essential Mod",
            type: .playing,
            details: "Minecraft 1.21.11",
            state: "On Server"
        )
        model.applyCurrentUserActivity(gameActivity)
        #expect(model.currentUserActivityDisplayText == "Playing Essential Mod")

        let rawMember = Member(
            user: model.currentUser!,
            roleName: "Member",
            status: .online
        )
        let decorated = model.memberWithCurrentStatus(rawMember)
        #expect(decorated.activityText == "Playing Essential Mod")
        #expect(decorated.memberListActivityText == "Playing Essential Mod")
    }

    @Test("Extreme or non-finite duration does not cause integer overflow or crash")
    func testExtremeDurationDoesNotOverflow() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider, preferences: .enabledAll)
        let monitor = AppleMusicPresenceMonitor(coordinator: coordinator)

        let payload = await monitor.handlePlayerInfo([
            "Player State": "Playing",
            "Name": "Infinite Track",
            "Artist": "Cosmos",
            "Duration": NSNumber(value: 1e300)
        ])
        #expect(payload != nil)
        #expect(payload?.timestamps?.start != nil)
        #expect(payload?.timestamps?.end == nil)
    }

    @Test("Spotify long track over 10 minutes retains end timestamp")
    func testSpotifyLongTrackRetainsEndTimestamp() async {
        let provider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: provider, preferences: .enabledAll)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let monitor = AppleMusicPresenceMonitor(
            coordinator: coordinator,
            nowProvider: { fixedDate }
        )

        let spotifyPayload: [AnyHashable: Any] = [
            "Player State": "Playing",
            "Name": "All Too Well (10 Minute Version)",
            "Artist": "Taylor Swift",
            "Album": "Red (Taylor's Version)",
            "Playback Position": 30.0,
            "Duration": 720000.0,
            "Track ID": "spotify:track:5enxwA8aAbwZbf5ncge5vh"
        ]

        let activity = await monitor.handlePlayerInfo(spotifyPayload)
        #expect(activity != nil)
        #expect(activity?.name == "Spotify")
        let expectedStartMs = Int64((1_700_000_000.0 - 30.0) * 1000)
        let expectedEndMs = expectedStartMs + 720_000
        #expect(activity?.timestamps?.start == expectedStartMs)
        #expect(activity?.timestamps?.end == expectedEndMs)
    }
}
