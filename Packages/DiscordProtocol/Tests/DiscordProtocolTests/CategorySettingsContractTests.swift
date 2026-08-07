@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

extension ProviderRequestContractTests {
    @Test func `category collapsed state decodes from user guild settings`() throws {
        let data = Data(
            #"{"guild_id":"100","channel_overrides":[{"channel_id":"190","collapsed":true}]}"#.utf8
        )
        let settings = try JSONDecoder().decode(
            GatewayUserGuildSettingsDTO.self,
            from: data
        )
        #expect(settings.channelOverrides.first?.domain?.isCollapsed == true)
    }

    @Test func `category settings use one scoped bulk mutation per action`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
        let guildID = GuildID(rawValue: 100)
        let categoryID = ChannelID(rawValue: 190)

        try await provider.updateCategoryNotificationLevel(
            guildID: guildID,
            categoryID: categoryID,
            level: .nothing
        )
        #expect(RateLimitURLProtocol.guildNotificationRequestCount == 1)
        #expect(RateLimitURLProtocol.guildNotificationMethod == "PATCH")
        var guilds = RateLimitURLProtocol.guildNotificationBody?["guilds"]
            as? [String: Any]
        var guild = guilds?["100"] as? [String: Any]
        var overrides = guild?["channel_overrides"] as? [String: Any]
        var override = overrides?["190"] as? [String: Any]
        #expect((override?["message_notifications"] as? NSNumber)?.intValue == 2)
        #expect(override?.count == 1)

        let endTime = Date(timeIntervalSince1970: 1_785_420_000)
        try await provider.updateCategoryMute(
            guildID: guildID,
            categoryID: categoryID,
            isMuted: true,
            until: endTime
        )
        #expect(RateLimitURLProtocol.guildNotificationRequestCount == 2)
        guilds = RateLimitURLProtocol.guildNotificationBody?["guilds"]
            as? [String: Any]
        guild = guilds?["100"] as? [String: Any]
        overrides = guild?["channel_overrides"] as? [String: Any]
        override = overrides?["190"] as? [String: Any]
        #expect(override?["muted"] as? Bool == true)
        #expect(override?["collapsed"] == nil)
        let muteConfig = override?["mute_config"] as? [String: Any]
        #expect(muteConfig?["end_time"] as? String == "2026-07-30T14:00:00.000Z")

        try await provider.updateCategoryCollapsed(
            guildID: guildID,
            categoryID: categoryID,
            isCollapsed: false
        )
        #expect(RateLimitURLProtocol.guildNotificationRequestCount == 3)
        guilds = RateLimitURLProtocol.guildNotificationBody?["guilds"]
            as? [String: Any]
        guild = guilds?["100"] as? [String: Any]
        overrides = guild?["channel_overrides"] as? [String: Any]
        override = overrides?["190"] as? [String: Any]
        #expect(override?["collapsed"] as? Bool == false)
        #expect(override?.count == 1)

        try await provider.updateCategoryMute(
            guildID: guildID,
            categoryID: categoryID,
            isMuted: false,
            until: nil
        )
        #expect(RateLimitURLProtocol.guildNotificationRequestCount == 4)
        guilds = RateLimitURLProtocol.guildNotificationBody?["guilds"]
            as? [String: Any]
        guild = guilds?["100"] as? [String: Any]
        overrides = guild?["channel_overrides"] as? [String: Any]
        override = overrides?["190"] as? [String: Any]
        #expect(override?["muted"] as? Bool == false)
        #expect(override?["mute_config"] is NSNull)
        #expect(override?["collapsed"] == nil)
    }
}
