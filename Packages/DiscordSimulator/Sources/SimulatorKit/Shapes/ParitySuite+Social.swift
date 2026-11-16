import Foundation

/// Friends, group DMs, the Mentions tab, the server profile and expression changes, as captured.
extension ParityRun {
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
