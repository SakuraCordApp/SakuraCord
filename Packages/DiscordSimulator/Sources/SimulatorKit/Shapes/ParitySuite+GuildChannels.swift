import Foundation

extension ParityRun {
    /// Creating, editing and deleting guild channels; removing and installing a bot; autocomplete; an OAuth2 token's identity.
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

        let bot = try await targetBot(target)
        // Removing the bot, then adding it back through its OAuth2 link.
        await flowStart()
        _ = try await rest("DELETE", "/api/v9/guilds/\(target.guild)/members/\(bot)?reason=")
        let install = "client_id=\(bot)&scope=bot%20applications.commands"
        _ = try await rest("GET", "/api/v9/oauth2/authorize?\(install)&integration_type=0")
        _ = try await rest("POST", "/api/v9/oauth2/authorize?\(install)", body: .object(JSONObject([
            ("guild_id", .string(target.guild.description)), ("permissions", "0"), ("authorize", true), ("integration_type", 0),
            ("location_context", .object(JSONObject([("guild_id", .string(target.guild.description)),
                                                     ("channel_id", .string(target.channel.description)), ("channel_type", 0)]))),
        ])))
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
        _ = try await rest("POST", "/api/v9/guilds/\(garden.id)/onboarding-responses", body: .object(JSONObject([
            ("onboarding_responses", [option]), ("onboarding_prompts_seen", .object(JSONObject())),
            ("onboarding_responses_seen", .object(JSONObject())),
        ])))
        _ = try await rest("PUT", "/api/v9/guilds/\(garden.id)/onboarding-responses", body: .object(JSONObject([
            ("onboarding_responses", [option]), ("onboarding_prompts_seen", .object(JSONObject())),
            ("onboarding_responses_seen", .object(JSONObject())),
        ])))
        _ = try await rest("GET", "/api/v9/guilds/\(garden.id)/onboarding")
        _ = try await postMessage(in: gardenChat.id, "is roundup ok on the paths?")
        // An alert-only rule lets the message through and posts an AutoMod alert for the coordinators.
        _ = try await postMessage(in: gardenChat.id, "anyone want my plot for sale cheap?")
        await flowEnd(nil)
    }
}

extension ParityRun {
    /// Dragging a channel: the client sends the new positions of every channel that moves.
    mutating func reorderChannels(_ target: Targets, me: Snowflake) async throws {
        let world = simulator.world
        let channels = await world.visibleChannels(in: try world.guild(target.guild), for: me).filter { $0.type != .category }
            .sorted { $0.position < $1.position }
        guard channels.count >= 2 else { throw WorldError.invalidBody("target server needs two channels to reorder") }
        let (first, second) = (channels[0], channels[1])
        func positions(_ pairs: [(Channel, Int)]) -> JSON {
            .array(pairs.map { ["id": .string($0.0.id.description), "position": .int($0.1)] })
        }
        await flowStart()
        // Swap the top two, then put them back (a reorder by the same moderator folds into one audit entry).
        _ = try await rest("PATCH", "/api/v9/guilds/\(target.guild)/channels", body: positions([(second, first.position), (first, second.position)]))
        _ = try await rest("PATCH", "/api/v9/guilds/\(target.guild)/channels", body: positions([(first, first.position), (second, second.position)]))
        await flowEnd(nil)
    }
}
