import Foundation

extension ParityRun {
    /// Scheduled events (one somewhere else; no capture has a voice-channel event) in a server the account owns, a moderator nickname,
    /// role events, and a moderator clearing reactions, deleting messages in bulk and renaming a sound.
    mutating func eventsAndModeration(_ target: Targets, me: Snowflake) async throws {
        let world = simulator.world
        let guild = try await world.guild(target.guild)
        guard guild.ownerID == me else { throw WorldError.invalidBody("the target server must be the account's own") }
        let base = "/api/v9/guilds/\(target.guild)"
        let start = world.clock.now.addingTimeInterval(86_400)

        await flowStart()
        let event = try await rest("POST", "\(base)/scheduled-events", body: .object(JSONObject([
            ("name", "parity event"), ("description", ""), ("privacy_level", 2), ("scheduled_start_time", World.timestamp(start)),
            ("scheduled_end_time", World.timestamp(start.addingTimeInterval(7_200))), ("entity_type", 3), ("channel_id", .null),
            ("entity_metadata", ["location": "the porch"]), ("recurrence_rule", .null),
        ])))
        let eventID = event["id"]?.stringValue ?? ""
        _ = try await rest("GET", "/api/v9/users/@me/scheduled-events?guild_ids=\(target.guild)")
        _ = try await rest("GET", "\(base)/scheduled-events/\(eventID)/users/counts")
        _ = try await rest("POST", "/api/v9/channels/\(target.channel)/invites", body: ["max_age": 604_800, "max_uses": 0])
        _ = try await rest("POST", "\(base)/ack/1/\(eventID)", body: .object(JSONObject()))
        _ = try await rest("DELETE", "\(base)/scheduled-events/\(eventID)/users/@me")
        _ = try await rest("PUT", "\(base)/scheduled-events/\(eventID)/users/@me", body: ["response": 1])
        if let id = Snowflake(eventID) { try await world.updateScheduledEvent(id, in: target.guild, by: me, status: 2, name: nil) }
        _ = try await rest("DELETE", "\(base)/scheduled-events/\(eventID)")
        await flowEnd(nil)

        await flowStart()
        _ = try await rest("PATCH", "\(base)/members/\(target.otherUser)", body: ["nick": "neighbour"])
        _ = try await rest("PATCH", "\(base)/members/\(target.otherUser)", body: ["nick": ""])
        _ = try await rest("GET", "\(base)/roles")
        _ = try await rest("GET", "\(base)/channels")
        let role = Role(id: await world.nextID(), name: "parity role", color: 0x3d7ea6, position: 1, permissions: .everyoneDefault)
        try await world.saveRole(role, in: target.guild)
        var renamed = role
        renamed.name = "parity role (renamed)"
        try await world.saveRole(renamed, in: target.guild)
        try await world.saveRole(nil, deleting: role.id, in: target.guild)
        await flowEnd(nil)

        // A moderator clearing one emoji's reactions, then all of them, then deleting messages in bulk.
        await flowStart()
        var posted: [Snowflake] = []
        for text in ["parity purge one", "parity purge two"] {
            posted.append(try await world.sendMessage(MessageDraft(content: text), as: target.otherUser, in: target.channel, checkPermissions: false).id)
        }
        for emoji in ["👍", "🎉"] {
            try await world.react(posted[0], in: target.channel, by: target.otherUser, emojiName: emoji, emojiID: nil, burst: false)
        }
        try await world.clearReactions(posted[0], in: target.channel, emojiKey: "👍", by: me)
        try await world.clearReactions(posted[0], in: target.channel, emojiKey: nil, by: me)
        try await world.bulkDeleteMessages(posted, in: target.channel, by: me)
        if let sound = guild.soundboardSounds.first {
            try await world.updateSoundboardSound(sound.name, in: target.guild, newName: "parity sound", emoji: nil, volume: nil)
        }
        await flowEnd(nil)
    }
}
