import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func updateChannelPin(
        guildID: GuildID?,
        channelID: ChannelID,
        flags: UInt64
    ) async throws {
        let override: [String: JSONValue] = ["flags": .number(Double(flags))]
        guard let guildID else {
            try await updateChannelNotificationSettings(
                guildID: nil,
                channelID: channelID,
                override: override
            )
            return
        }
        // The first-party channel pin saves a server override through the bulk
        // route, unlike its per-guild route for DMs.
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: ["channel_overrides": .object([channelID.description: .object(override)])]
        )
    }

    internal func updateGuildNotificationSettings(
        guildID: GuildID,
        settings: [String: JSONValue]
    ) async throws {
        // The current first-party client sends one partial guild entry through
        // the bulk user-guild settings route and reconciles the accepted value
        // through USER_GUILD_SETTINGS_UPDATE.
        try await requestEmpty(
            "/users/@me/guilds/settings",
            method: "PATCH",
            body: [
                "guilds": .object([
                    guildID.description: .object(settings),
                ])
            ]
        )
    }

    func updateChannelMute(
        guildID: GuildID?,
        channelID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        try await updateChannelNotificationSettings(
            guildID: guildID,
            channelID: channelID,
            override: Self.muteSettings(isMuted: isMuted, until: until)
        )
    }

    internal func updateChannelNotificationSettings(
        guildID: GuildID?,
        channelID: ChannelID,
        override: [String: JSONValue]
    ) async throws {
        // Discord's current client PATCHes a partial channel override keyed by
        // channel ID. Keep this as a single, centrally scheduled mutation and
        // rely on USER_GUILD_SETTINGS_UPDATE for authoritative reconciliation.
        try await requestEmpty(
            "/users/@me/guilds/\(guildID?.description ?? "@me")/settings",
            method: "PATCH",
            body: [
                "channel_overrides": .object([
                    channelID.description: .object(override)
                ])
            ]
        )
    }

    func updateCategoryNotificationLevel(
        guildID: GuildID,
        categoryID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {
        try await updateCategoryNotificationSettings(
            guildID: guildID,
            categoryID: categoryID,
            override: [
                "message_notifications": .number(Double(level.rawValue))
            ]
        )
    }

    func updateCategoryMute(
        guildID: GuildID,
        categoryID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        try await updateCategoryNotificationSettings(
            guildID: guildID,
            categoryID: categoryID,
            override: Self.muteSettings(isMuted: isMuted, until: until)
        )
    }

    func updateCategoryCollapsed(
        guildID: GuildID,
        categoryID: ChannelID,
        isCollapsed: Bool
    ) async throws {
        try await updateCategoryNotificationSettings(
            guildID: guildID,
            categoryID: categoryID,
            override: ["collapsed": .bool(isCollapsed)]
        )
    }

    internal func updateCategoryNotificationSettings(
        guildID: GuildID,
        categoryID: ChannelID,
        override: [String: JSONValue]
    ) async throws {
        // Category overrides and their collapsed state use the current bulk
        // user-guild settings route, scoped to exactly one guild/category.
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: [
                "channel_overrides": .object([
                    categoryID.description: .object(override)
                ])
            ]
        )
    }

    func updateChannelNotificationLevel(
        guildID: GuildID?,
        channelID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {
        try await updateChannelNotificationSettings(
            guildID: guildID,
            channelID: channelID,
            override: [
                "message_notifications": .number(Double(level.rawValue))
            ]
        )
    }

    func updateGuildNotificationLevel(
        guildID: GuildID,
        level: MessageNotificationLevel
    ) async throws {
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: [
                "message_notifications": .number(Double(level.rawValue))
            ]
        )
    }

    func updateGuildMute(
        guildID: GuildID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: Self.muteSettings(isMuted: isMuted, until: until)
        )
    }

    func updateGuildNotificationToggle(
        guildID: GuildID,
        toggle: GuildNotificationToggle,
        isEnabled: Bool
    ) async throws {
        let setting: (key: String, value: JSONValue) = switch toggle {
        case .suppressEveryone:
            ("suppress_everyone", .bool(isEnabled))
        case .suppressRoles:
            ("suppress_roles", .bool(isEnabled))
        case .suppressHighlights:
            (
                "notify_highlights",
                .number(Double(
                    isEnabled
                        ? GuildHighlightNotificationLevel.disabled.rawValue
                        : GuildHighlightNotificationLevel.inherit.rawValue
                ))
            )
        case .muteScheduledEvents:
            ("mute_scheduled_events", .bool(isEnabled))
        case .mobilePush:
            ("mobile_push", .bool(isEnabled))
        case .hideMutedChannels:
            ("hide_muted_channels", .bool(isEnabled))
        }
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: [setting.key: setting.value]
        )
    }

    /// A mute change: `muted`, with `mute_config` holding a timed mute's end
    /// and null otherwise.
    internal static func muteSettings(isMuted: Bool, until: Date?) -> [String: JSONValue] {
        var settings: [String: JSONValue] = ["muted": .bool(isMuted), "mute_config": .null]
        if isMuted, let until {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            settings["mute_config"] = .object(["end_time": .string(formatter.string(from: until))])
        }
        return settings
    }
}
