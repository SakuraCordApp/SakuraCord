@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

extension DirectMessageProviderContractTests {
    @Test func `updating activity dispatches gateway presence opcode 3 with serialized payload`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 1))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }

        let provider = session.provider
        let socket = session.socket

        let initialOpcode3Count = await socket.sentPayloadCount(opcode: 3)

        let activity = OutgoingActivityPayload(
            name: "Apple Music",
            type: .listening,
            details: "Song Title",
            state: "Artist Name",
            timestamps: ActivityTimestamps(start: 1700000000000, end: 1700000200000),
            assets: ActivityAssets(largeImage: "apple_music_logo", largeText: "Album Name"),
            applicationId: "com.apple.Music"
        )

        try await provider.updateActivity(activity, sourceID: "apple_music")

        #expect(await socket.sentPayloadCount(opcode: 3) == initialOpcode3Count + 1)
        let presenceData = try #require(await socket.sentPayload(opcode: 3))
        let presenceJson = try #require(JSONSerialization.jsonObject(with: presenceData) as? [String: Any])
        let payloadDict = try #require(presenceJson["d"] as? [String: Any])
        #expect(payloadDict["status"] as? String == "online")

        let activities = try #require(payloadDict["activities"] as? [[String: Any]])
        #expect(activities.count == 1)
        let first = activities[0]
        #expect(first["name"] as? String == "Apple Music")
        #expect(first["type"] as? Int == 2)
        #expect(first["details"] as? String == "Song Title")
        #expect(first["state"] as? String == "Artist Name")
        #expect((first["timestamps"] as? [String: Any])?["start"] as? Int64 == 1700000000000)
        #expect((first["timestamps"] as? [String: Any])?["end"] as? Int64 == 1700000200000)
        #expect((first["assets"] as? [String: Any])?["large_image"] as? String == "apple_music_logo")
        #expect((first["assets"] as? [String: Any])?["large_text"] as? String == "Album Name")
        #expect(first["application_id"] as? String == "com.apple.Music")

        let active = await provider.currentActivities()
        #expect(active["apple_music"] == activity)
    }

    @Test func `multiple activities sort by priority rank so games precede background listening`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 1))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }

        let provider = session.provider
        let socket = session.socket

        let musicActivity = OutgoingActivityPayload(
            name: "Apple Music",
            type: .listening,
            details: "Song Title"
        )
        try await provider.updateActivity(musicActivity, sourceID: "apple_music")

        let gameActivity = OutgoingActivityPayload(
            name: "Minecraft",
            type: .playing,
            details: "Mining Diamonds"
        )
        try await provider.updateActivity(gameActivity, sourceID: "rpc:game")

        let presenceData = try #require(await socket.sentPayload(opcode: 3))
        let presenceJson = try #require(JSONSerialization.jsonObject(with: presenceData) as? [String: Any])
        let payloadDict = try #require(presenceJson["d"] as? [String: Any])
        let activities = try #require(payloadDict["activities"] as? [[String: Any]])

        #expect(activities.count == 2)
        // Playing (rank 1) must precede Listening (rank 5)
        #expect(activities[0]["name"] as? String == "Minecraft")
        #expect(activities[0]["type"] as? Int == 0)
        #expect(activities[1]["name"] as? String == "Apple Music")
        #expect(activities[1]["type"] as? Int == 2)
    }

    @Test func `clearing activity removes it from gateway presence payload`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 1))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }

        let provider = session.provider
        let socket = session.socket

        let musicActivity = OutgoingActivityPayload(name: "Apple Music", type: .listening)
        let gameActivity = OutgoingActivityPayload(name: "Minecraft", type: .playing)

        try await provider.updateActivity(musicActivity, sourceID: "music")
        try await provider.updateActivity(gameActivity, sourceID: "game")

        // Clear specific source
        try await provider.clearActivities(sourceID: "music")
        let presence1 = try #require(await socket.sentPayload(opcode: 3))
        let json1 = try #require(JSONSerialization.jsonObject(with: presence1) as? [String: Any])
        let d1 = try #require(json1["d"] as? [String: Any])
        let activities1 = try #require(d1["activities"] as? [[String: Any]])
        #expect(activities1.count == 1)
        #expect(activities1[0]["name"] as? String == "Minecraft")

        // Clear all remaining sources
        try await provider.clearActivities(sourceID: nil)
        let presence2 = try #require(await socket.sentPayload(opcode: 3))
        let json2 = try #require(JSONSerialization.jsonObject(with: presence2) as? [String: Any])
        let d2 = try #require(json2["d"] as? [String: Any])
        let activities2 = try #require(d2["activities"] as? [[String: Any]])
        #expect(activities2.isEmpty)
        #expect(await provider.currentActivities().isEmpty)
    }

    @Test func `updating activity with nil clears that source`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 1))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }

        let provider = session.provider
        let socket = session.socket

        try await provider.updateActivity(OutgoingActivityPayload(name: "Sonora", type: .listening), sourceID: "player")
        #expect(await provider.currentActivities().count == 1)

        try await provider.updateActivity(nil, sourceID: "player")
        #expect(await provider.currentActivities().isEmpty)

        let presence = try #require(await socket.sentPayload(opcode: 3))
        let json = try #require(JSONSerialization.jsonObject(with: presence) as? [String: Any])
        let payloadDict = try #require(json["d"] as? [String: Any])
        let activities = try #require(payloadDict["activities"] as? [[String: Any]])
        #expect(activities.isEmpty)
    }
}
