@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

struct DirectMessagePinSettingsTests {
    @Test func `remote unpin clears omitted flags while retaining other override settings`() throws {
        // Sanitized USER_GUILD_SETTINGS_UPDATE shapes captured from the official client.
        let pinned = Data(#"""
        {"guild_id":null,"channel_overrides":[{
          "channel_id":"200","collapsed":false,"flags":2048,
          "message_notifications":3,"muted":true,
          "mute_config":{"end_time":"2026-09-18T22:10:34.227000+00:00","selected_time_window":3600}
        }],"version":4178}
        """#.utf8)
        let unpinned = Data(#"""
        {"guild_id":null,"channel_overrides":[{
          "channel_id":"200","collapsed":false,
          "message_notifications":3,"muted":true,
          "mute_config":{"end_time":"2026-09-18T22:10:34.227000+00:00","selected_time_window":3600}
        }],"version":4179}
        """#.utf8)
        let decoder = JSONDecoder()
        let baseline = try decoder.decode(GatewayUserGuildSettingsDTO.self, from: pinned).domain
        let original = try #require(baseline.channelOverrides.first)
        #expect(original.isPinnedDirectMessage)

        let update = try decoder.decode(GatewayUserGuildSettingsDTO.self, from: unpinned)
        let settings = update.domain(merging: baseline)
        var expected = original
        expected.flags = 0
        #expect(settings.guildID == nil)
        #expect(settings.channelOverrides == [expected])

        let partial = try decoder.decode(
            GatewayUserGuildSettingsDTO.self, from: Data(#"{"guild_id":null}"#.utf8)
        )
        #expect(partial.domain(merging: baseline).channelOverrides == [original])

        let removed = try decoder.decode(
            GatewayUserGuildSettingsDTO.self,
            from: Data(#"{"guild_id":null,"channel_overrides":[]}"#.utf8)
        )
        #expect(removed.domain(merging: baseline).channelOverrides.isEmpty)
    }
}
