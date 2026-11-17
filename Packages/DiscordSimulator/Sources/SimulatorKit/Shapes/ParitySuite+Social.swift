import Foundation

/// Friends, group DMs, the Mentions tab, the server profile and expression changes, as captured.
extension ParityRun {
    /// What the signed-in person does to their own account: profile, pickers, friends and groups, settings, mentions.
    mutating func accountFlows(_ target: Targets, me: Snowflake) async throws {
        try await profileEditing(target, me: me)
        try await expressionPickers(target)
        try await friendsAndGroups(target, me: me)
        try await privacySettingRoundTrip()
        try await mentionsAndServerProfile(target, me: me)
    }

    mutating func friendsAndGroups(_ target: Targets, me: Snowflake) async throws {
        let world = simulator.world
        let friends = (await world.relationships[me] ?? [:]).values.filter { $0.type == .friend }.map(\.userID).sorted()
        guard friends.count >= 3 else { throw WorldError.invalidBody("scenario needs three friends") }
        // Unfriend someone, then take them through every other relationship and back to friends.
        let stranger = friends[0]
        let path = "/api/v9/users/@me/relationships"
        await flowStart()
        _ = try await rest("DELETE", "\(path)/\(stranger)")
        _ = try await rest("PUT", "\(path)/\(stranger)/ignore")
        _ = try await rest("DELETE", "\(path)/\(stranger)/ignore")
        _ = try await rest("PUT", "\(path)/\(stranger)", body: ["type": 2])
        _ = try await rest("DELETE", "\(path)/\(stranger)")
        _ = try await rest("PUT", "\(path)/\(stranger)", body: .object(JSONObject()))
        _ = try await rest("DELETE", "\(path)/\(stranger)")
        guard let username = await world.users[stranger]?.username else { throw WorldError.unknown("User", code: 10013) }
        _ = try await rest("POST", path, body: ["username": .string(username), "discriminator": .null])
        _ = try await rest("DELETE", "\(path)/\(stranger)")
        try await world.putRelationship(stranger, with: me, type: nil)
        _ = try await rest("PUT", "\(path)/\(stranger)", body: ["confirm_stranger_request": false])
        _ = try await rest("POST", path, body: ["username": "nobody.by.this.name", "discriminator": .null])
        await flowEnd(nil)

        await flowStart()
        let group = try await rest("POST", "/api/v9/users/@me/channels", body: ["recipients": [.string(friends[1].description), .string(friends[2].description)]])
        if let id = group["id"]?.stringValue {
            _ = try await rest("PATCH", "/api/v9/channels/\(id)", body: ["name": "parity group"])
            _ = try await rest("DELETE", "/api/v9/channels/\(id)/recipients/\(friends[2])")
            _ = try await rest("PUT", "/api/v9/channels/\(id)/recipients/\(friends[2])")
            _ = try await rest("DELETE", "/api/v9/channels/\(id)")
        }
        await flowEnd(nil)
    }

    /// The message-request filter toggle: the client sends the whole privacy section (field 8);
    /// it must come back as sent, with the data version moved on.
    mutating func privacySettingRoundTrip() async throws {
        let path = "/api/v9/users/@me/settings-proto/1"
        let before = try await rest("GET", path)["settings"]?.stringValue.flatMap { Data(base64Encoded: $0) } ?? Data()
        let privacy = Protobuf.field(8, Protobuf.field(17, Data([0x08, 0x01])))
        await flowStart()
        let after = try await rest("PATCH", path, body: ["settings": .string(privacy.base64EncodedString())])["settings"]?.stringValue
            .flatMap { Data(base64Encoded: $0) } ?? Data()
        await flowEnd(nil)
        func section(_ settings: Data, _ number: UInt64) -> Data? { ProtobufMerge.fields(settings)?.first { $0.number == number }?.bytes }
        if section(after, 8) != privacy || section(after, 1) == section(before, 1) {
            report.sequenceFailures.append("settings-proto: privacy section or data version did not round-trip")
        }
    }

    mutating func mentionsAndServerProfile(_ target: Targets, me: Snowflake) async throws {
        let world = simulator.world
        await flowStart()
        let mentions = try await rest("GET", "/api/v9/users/@me/mentions?limit=25&roles=true&everyone=true")
        if let first = mentions.arrayValue?.first?["id"]?.stringValue { _ = try await rest("DELETE", "/api/v9/users/@me/mentions/\(first)") }
        _ = try await rest("PATCH", "/api/v9/guilds/\(target.guild)/profile/%40me", body: ["pronouns": "they/them"])
        let other = target.otherUser
        try await world.changeEmoji("paritymoji", in: target.guild, by: other, adding: true)
        try await world.changeEmoji("paritymoji", in: target.guild, by: other, adding: false)
        try await world.changeSticker("parity sticker", in: target.guild, adding: true)
        try await world.changeSticker("parity sticker", in: target.guild, adding: false)
        try await world.addSoundboardSound("parity sound", emoji: nil, in: target.guild, by: other)
        try await world.removeSoundboardSound("parity sound", in: target.guild)
        await flowEnd(nil)
    }
}
