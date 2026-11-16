import Foundation

extension ParityRun {
    /// Creating, editing and deleting guild channels; a bot joining and leaving; autocomplete; an OAuth2 token's identity.
    mutating func guildChannels(_ target: Targets, me: Snowflake) async throws {
        let world = simulator.world
        let base = "/api/v9/guilds/\(target.guild)"
        let category = await world.visibleChannels(in: try world.guild(target.guild), for: me).first { $0.type == .category }?.id

        await flowStart()
        var body = JSONObject([("type", 0), ("name", "parity temp"), ("permission_overwrites", [])])
        if let category { body["parent_id"] = .string(category.description) }
        let text = try await rest("POST", "\(base)/channels", body: .object(body))
        let forum = try await rest("POST", "\(base)/channels", body: ["name": "parity forum", "type": 15, "topic": "parity"])
        for created in [text, forum] {
            if let id = created["id"]?.stringValue { _ = try await rest("DELETE", "/api/v9/channels/\(id)") }
        }
        await flowEnd(nil)

        let users = await world.users
        let guild = try await world.guild(target.guild)
        guard let bot = guild.members.keys.sorted().first(where: { users[$0]?.bot == true }) else { return }
        await flowStart()
        try await world.removeMember(bot, from: target.guild)
        try await world.addMember(bot, to: target.guild)
        _ = try await rest("POST", "/api/v9/interactions", body: .object(JSONObject([
            ("type", 4), ("application_id", .string(bot.description)), ("guild_id", .string(target.guild.description)),
            ("channel_id", .string(target.channel.description)), ("session_id", "parity"), ("nonce", .string(nonce())),
            ("data", .object(JSONObject([("type", 1), ("name", "gamenight"), ("options", [["type": 3, "name": "game", "value": "ca", "focused": true]])]))),
        ])))
        await flowEnd(nil)

        if let token = await world.servers.oauthGrants[me]?.values.first?.accessToken {
            let saved = self.token
            self.token = "Bearer \(token)"
            _ = try await rest("GET", "/api/v9/oauth2/@me")
            self.token = saved
        }
    }
}

extension ParityRun {
    /// Editing a text channel and its permission overwrites, a voice-channel event, onboarding answers, and an AutoMod block.
    mutating func channelSettingsAndAutoMod(_ target: Targets, me: Snowflake) async throws {
        let world = simulator.world
        let guild = try await world.guild(target.guild)
        let channels = await world.visibleChannels(in: guild, for: me)
        guard let voice = channels.first(where: { $0.type == .voice }), let role = guild.roles.first(where: { $0.id != guild.id && !$0.managed })
        else { throw WorldError.invalidBody("target server needs a voice channel and a role") }
        let channel = "/api/v9/channels/\(target.channel)"

        await flowStart()
        let original = await world.channels[target.channel]?.name ?? "general"
        _ = try await rest("PATCH", channel, body: ["name": "parity-renamed", "type": 0, "topic": "parity topic", "bitrate": 64_000,
                                                    "user_limit": 0, "nsfw": false, "flags": 0, "rate_limit_per_user": 0])
        _ = try await rest("PATCH", channel, body: ["name": .string(original), "topic": ""])
        _ = try await rest("PUT", "\(channel)/permissions/\(role.id)", body: ["id": .string(role.id.description), "type": 0, "allow": "0", "deny": "0"])
        _ = try await rest("PUT", "\(channel)/permissions/\(role.id)", body: ["id": .string(role.id.description), "type": 0, "allow": "0", "deny": "64"])
        _ = try await rest("DELETE", "\(channel)/permissions/\(role.id)")
        let event = try await rest("POST", "/api/v9/guilds/\(target.guild)/scheduled-events", body: .object(JSONObject([
            ("name", "parity hangout"), ("description", ""), ("privacy_level", 2),
            ("scheduled_start_time", World.timestamp(world.clock.now.addingTimeInterval(3_600))), ("entity_type", 2),
            ("channel_id", .string(voice.id.description)), ("recurrence_rule", .null),
        ])))
        if let id = event["id"]?.stringValue { _ = try await rest("DELETE", "/api/v9/guilds/\(target.guild)/scheduled-events/\(id)") }
        await flowEnd(nil)

        guard let garden = await world.guilds.values.first(where: { $0.name == "Linden Street Garden" }),
              let option = await world.servers.onboarding[garden.id]?["prompts"]?.arrayValue?.first?["options"]?.arrayValue?.first?["id"],
              let gardenChat = await world.visibleChannels(in: garden, for: me).first(where: { $0.type == .text })
        else { throw WorldError.invalidBody("demo garden has no onboarding") }
        await flowStart()
        _ = try await rest("PUT", "/api/v9/guilds/\(garden.id)/onboarding-responses", body: .object(JSONObject([
            ("onboarding_responses", [option]), ("onboarding_prompts_seen", .object(JSONObject())),
            ("onboarding_responses_seen", .object(JSONObject())),
        ])))
        _ = try await rest("GET", "/api/v9/guilds/\(garden.id)/onboarding")
        _ = try await rest("POST", "/api/v9/channels/\(gardenChat.id)/messages", body: .object(JSONObject([
            ("content", "is roundup ok on the paths?"), ("nonce", .string(nonce())), ("tts", false), ("flags", 0),
        ])))
        await flowEnd(nil)
    }
}
