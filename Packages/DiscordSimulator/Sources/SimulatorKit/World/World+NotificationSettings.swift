import Foundation

/// Per-server notification settings (`user_guild_settings`): stored wire-shaped,
/// patched field by field like Discord, with channel overrides merged by channel.
extension World {
    /// Merges `PATCH /users/@me/guilds/settings` and returns every changed guild's full settings.
    func patchGuildSettings(_ userID: Snowflake, guilds patches: JSONObject) async throws -> [JSON] {
        var results: [JSON] = []
        for (guildText, patch) in patches {
            guard let guildID = Snowflake(guildText), guilds[guildID]?.members[userID] != nil else { throw WorldError.unknown("Guild", code: 10004) }
            guard let fields = patch.objectValue else { throw WorldError.invalidBody("guilds.\(guildText): not an object") }
            var settings = guildSettings(userID, guildID)
            for (key, value) in fields where key != "channel_overrides" { settings[key] = value }
            var overrides = settings["channel_overrides"]?.arrayValue ?? []
            for (channelText, change) in fields["channel_overrides"]?.objectValue ?? JSONObject() {
                guard let channelID = Snowflake(channelText), channels[channelID]?.guildID == guildID else {
                    throw WorldError.unknown("Channel", code: 10003)
                }
                let index = overrides.firstIndex { $0["channel_id"]?.stringValue == channelText }
                var override = index.flatMap { overrides[$0].objectValue } ?? Self.defaultChannelOverride(channelID)
                for (key, value) in change.objectValue ?? JSONObject() { override[key] = value }
                if let index { overrides[index] = .object(override) } else { overrides.append(.object(override)) }
            }
            settings["channel_overrides"] = .array(overrides)
            settings["version"] = .int((settings["version"]?.intValue ?? 0) + 1)
            guildSettings[userID, default: [:]][guildID] = settings
            await emit("USER_GUILD_SETTINGS_UPDATE", .object(settings), to: .users([userID]))
            results.append(.object(settings))
        }
        return results
    }

    /// Stored settings, or Discord's defaults for a server the user never configured.
    func guildSettings(_ userID: Snowflake, _ guildID: Snowflake) -> JSONObject {
        guildSettings[userID]?[guildID] ?? JSONObject([
            ("guild_id", guildID.json), ("suppress_everyone", false), ("suppress_roles", false),
            ("mute_scheduled_events", false), ("message_notifications", 1), ("flags", 0), ("mobile_push", true),
            ("muted", false), ("mute_config", .null), ("hide_muted_channels", false), ("channel_overrides", []),
            ("notify_highlights", 0), ("version", 0),
        ])
    }

    /// READY's `user_guild_settings.entries`: only servers the user changed.
    func renderGuildSettingsEntries(_ userID: Snowflake) -> [JSON] {
        (guildSettings[userID] ?? [:]).sorted { $0.key < $1.key }.map { .object($0.value) }
    }

    private static func defaultChannelOverride(_ channelID: Snowflake) -> JSONObject {
        JSONObject([("channel_id", channelID.json), ("message_notifications", 3), ("muted", false),
                    ("mute_config", .null), ("collapsed", false), ("flags", 0)])
    }
}
