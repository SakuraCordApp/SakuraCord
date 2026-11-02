@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

extension ProviderRequestContractTests {
    @Test func `bulk read acknowledgement preserves the first party body pacing and request budget`() async throws {
        RateLimitURLProtocol.reset()
        let provider = makeProvider()
        let readStates = (0 ..< 201).map { offset in
            BulkReadStateAcknowledgement(
                channelID: ChannelID(rawValue: UInt64(200 + offset)),
                messageID: MessageID(rawValue: UInt64(500 + offset))
            )
        }

        try await provider.acknowledgeBulk(readStates)

        #expect(RateLimitURLProtocol.bulkAckRequestCount == 3)
        let requests = RateLimitURLProtocol.bulkAckRequests.withLock { $0 }
        #expect(requests.map(\.method) == ["POST", "POST", "POST"])
        for (previous, next) in zip(requests, requests.dropFirst()) {
            #expect(previous.startedAt.duration(to: next.startedAt) >= .seconds(1))
        }
        let batches = RateLimitURLProtocol.bulkAckBodies.compactMap {
            $0["read_states"] as? [[String: Any]]
        }
        #expect(batches.map(\.count) == [100, 100, 1])
        #expect(batches.first?.first?["channel_id"] as? String == "200")
        #expect(batches.first?.first?["message_id"] as? String == "500")
        #expect((batches.first?.first?["read_state_type"] as? NSNumber)?.intValue == 0)
    }

    @Test(arguments: [400, 429])
    func `bulk read acknowledgement stops at a rejected batch without replay`(status: Int) async throws {
        RateLimitURLProtocol.reset()
        RateLimitURLProtocol.bulkAckStatuses = [204, status]
        let provider = makeProvider()
        let readStates = (0 ..< 101).map { offset in
            BulkReadStateAcknowledgement(
                channelID: ChannelID(rawValue: UInt64(200 + offset)),
                messageID: MessageID(rawValue: UInt64(500 + offset))
            )
        }

        await #expect(throws: ChatProviderError.self) {
            try await provider.acknowledgeBulk(readStates)
        }
        #expect(RateLimitURLProtocol.bulkAckRequestCount == 2)
    }

    @Test func `guild notification mutations use one partial bulk settings entry`() async throws {
        RateLimitURLProtocol.reset()
        let provider = makeProvider()
        let guildID = GuildID(rawValue: 100)

        try await provider.updateGuildNotificationLevel(
            guildID: guildID,
            level: .allMessages
        )
        #expect(RateLimitURLProtocol.guildNotificationRequestCount == 1)
        #expect(RateLimitURLProtocol.guildNotificationMethod == "PATCH")
        var guilds = RateLimitURLProtocol.guildNotificationBody?["guilds"] as? [String: Any]
        var settings = guilds?["100"] as? [String: Any]
        #expect((settings?["message_notifications"] as? NSNumber)?.intValue == 0)
        #expect(settings?["muted"] == nil)

        let endTime = Date(timeIntervalSince1970: 1_785_420_000)
        try await provider.updateGuildMute(
            guildID: guildID,
            isMuted: true,
            until: endTime
        )
        #expect(RateLimitURLProtocol.guildNotificationRequestCount == 2)
        guilds = RateLimitURLProtocol.guildNotificationBody?["guilds"] as? [String: Any]
        settings = guilds?["100"] as? [String: Any]
        #expect(settings?["muted"] as? Bool == true)
        let muteConfig = settings?["mute_config"] as? [String: Any]
        #expect(muteConfig?["end_time"] as? String == "2026-07-30T14:00:00.000Z")

        try await provider.updateGuildMute(
            guildID: guildID,
            isMuted: false,
            until: nil
        )
        #expect(RateLimitURLProtocol.guildNotificationRequestCount == 3)
        guilds = RateLimitURLProtocol.guildNotificationBody?["guilds"] as? [String: Any]
        settings = guilds?["100"] as? [String: Any]
        #expect(settings?["muted"] as? Bool == false)
        #expect(settings?["mute_config"] is NSNull)

        let toggleExpectations: [GuildNotificationToggleExpectation] = [
            .init(.suppressEveryone, true, key: "suppress_everyone", value: 1),
            .init(.suppressRoles, true, key: "suppress_roles", value: 1),
            .init(.suppressHighlights, true, key: "notify_highlights", value: 1),
            .init(.suppressHighlights, false, key: "notify_highlights", value: 0),
            .init(.muteScheduledEvents, true, key: "mute_scheduled_events", value: 1),
            .init(.mobilePush, false, key: "mobile_push", value: 0),
            .init(.hideMutedChannels, true, key: "hide_muted_channels", value: 1),
            .init(.hideMutedChannels, false, key: "hide_muted_channels", value: 0),
        ]
        for (index, expectation) in toggleExpectations.enumerated() {
            try await provider.updateGuildNotificationToggle(
                guildID: guildID,
                toggle: expectation.toggle,
                isEnabled: expectation.isEnabled
            )
            #expect(RateLimitURLProtocol.guildNotificationRequestCount == index + 4)
            guilds = RateLimitURLProtocol.guildNotificationBody?["guilds"] as? [String: Any]
            settings = guilds?["100"] as? [String: Any]
            #expect(settings?.count == 1)
            #expect((settings?[expectation.key] as? NSNumber)?.intValue == expectation.value)
        }

        RateLimitURLProtocol.guildNotificationStatus = 429
        await #expect(throws: ChatProviderError.self) {
            try await provider.updateGuildNotificationLevel(
                guildID: guildID,
                level: .nothing
            )
        }
        #expect(RateLimitURLProtocol.guildNotificationRequestCount == 12)
    }

    private func makeProvider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        return DiscordRESTProvider(
            credentials: ServerContractCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
    }
}

private struct GuildNotificationToggleExpectation {
    var toggle: GuildNotificationToggle
    var isEnabled: Bool
    var key: String
    var value: Int

    init(
        _ toggle: GuildNotificationToggle,
        _ isEnabled: Bool,
        key: String,
        value: Int
    ) {
        self.toggle = toggle
        self.isEnabled = isEnabled
        self.key = key
        self.value = value
    }
}

private actor ServerContractCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("test-session-credential-value".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        [CredentialHandle(accountID: "1")]
    }
}
