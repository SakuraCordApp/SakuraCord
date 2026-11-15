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
        try await updateGuildChannelOverride(guildID: guildID, channelID: channelID, override: override)
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
        try await updateGuildChannelOverride(
            guildID: guildID,
            channelID: categoryID,
            override: Self.notificationLevelSettings(level)
        )
    }

    func updateCategoryMute(
        guildID: GuildID,
        categoryID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        try await updateGuildChannelOverride(
            guildID: guildID,
            channelID: categoryID,
            override: Self.muteSettings(isMuted: isMuted, until: until)
        )
    }

    func updateCategoryCollapsed(
        guildID: GuildID,
        categoryID: ChannelID,
        isCollapsed: Bool
    ) async throws {
        try await updateGuildChannelOverride(
            guildID: guildID,
            channelID: categoryID,
            override: ["collapsed": .bool(isCollapsed)]
        )
    }

    /// Server channel pins and category overrides, including the collapsed
    /// state, use the current bulk user-guild settings route, scoped to
    /// exactly one guild and channel.
    internal func updateGuildChannelOverride(
        guildID: GuildID,
        channelID: ChannelID,
        override: [String: JSONValue]
    ) async throws {
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: [
                "channel_overrides": .object([
                    channelID.description: .object(override)
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
            override: Self.notificationLevelSettings(level)
        )
    }

    func updateGuildNotificationLevel(
        guildID: GuildID,
        level: MessageNotificationLevel
    ) async throws {
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: Self.notificationLevelSettings(level)
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

    internal static func notificationLevelSettings(_ level: MessageNotificationLevel) -> [String: JSONValue] {
        ["message_notifications": .number(Double(level.rawValue))]
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

extension DiscordRESTProvider {
    public func updateForumPostNotificationLevel(
        _ post: ForumPost,
        level: MessageNotificationLevel
    ) async throws {
        var settings = try await joinedThreadNotificationSettings(for: post)
        settings.flags = settings.flags(setting: level)
        try await patchThreadNotificationSettings(
            threadID: post.id,
            body: ["flags": .number(Double(settings.flags))]
        )
        updateCachedThreadNotificationSettings(settings, for: post)
    }

    public func updateForumPostMute(
        _ post: ForumPost,
        isMuted: Bool,
        until: Date?
    ) async throws {
        var settings = try await joinedThreadNotificationSettings(for: post)
        try await patchThreadNotificationSettings(threadID: post.id, body: Self.muteSettings(isMuted: isMuted, until: until))
        settings.setMuted(isMuted, until: until)
        updateCachedThreadNotificationSettings(settings, for: post)
    }

    func joinedThreadNotificationSettings(
        for post: ForumPost
    ) async throws -> ThreadNotificationSettings {
        if let cached = post.thread.parentID.flatMap({
            cachedForumPosts[$0]?[post.id]?.thread.notificationSettings
        }) ?? post.thread.notificationSettings {
            return cached
        }
        // The current Discord client joins an unjoined thread once before it
        // applies member-scoped notification settings.
        try await requestEmpty(
            "/channels/\(post.id)/thread-members/@me",
            method: "POST",
            query: [
                URLQueryItem(
                    name: "location",
                    value: "Change Notification Settings"
                )
            ]
        )
        let joined = ThreadNotificationSettings()
        updateCachedThreadNotificationSettings(joined, for: post)
        return joined
    }

    func patchThreadNotificationSettings(
        threadID: ChannelID,
        body: [String: JSONValue]
    ) async throws {
        try await requestEmpty(
            "/channels/\(threadID)/thread-members/@me/settings",
            method: "PATCH",
            body: body
        )
    }

    func updateCachedThreadNotificationSettings(
        _ settings: ThreadNotificationSettings,
        for post: ForumPost
    ) {
        guard let parentID = post.thread.parentID else { return }
        var cached = cachedForumPosts[parentID]?[post.id] ?? post
        cached.thread.notificationSettings = settings
        advanceThreadMembershipRevision(post.id)
        cachedForumPosts[parentID, default: [:]][post.id] = cached
        reconcileJoinedThread(cached.thread)
        publishForumPosts(parentID: parentID)
        publishActiveJoinedThreads()
    }
}
