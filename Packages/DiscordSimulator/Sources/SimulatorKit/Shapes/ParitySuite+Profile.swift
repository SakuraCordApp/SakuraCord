import Foundation

/// Profile editing, relationships and the expression pickers, as the official client drives them.
extension ParityRun {
    mutating func profileEditing(_ target: Targets, me: Snowflake) async throws {
        let world = simulator.world
        _ = try await rest("GET", "/api/v9/users/@me/avatars")
        await flowStart()
        _ = try await rest("PATCH", "/api/v9/users/@me", body: ["global_name": "Wren ✿"])
        _ = try await rest("PATCH", "/api/v9/users/%40me/profile", body: ["pronouns": "they/them"])
        _ = try await rest("PATCH", "/api/v9/guilds/\(target.guild)/members/@me", body: ["nick": "porch wren"])
        _ = try await rest("PATCH", "/api/v9/guilds/\(target.guild)/members/@me", body: ["nick": .null])
        if let tagGuild = await world.users[me]?.primaryGuild?["identity_guild_id"]?.stringValue {
            _ = try await rest("PUT", "/api/v9/users/@me/clan", body: .object(JSONObject([
                ("identity_guild_id", .string(tagGuild)), ("identity_enabled", true),
            ])))
        }
        _ = try await rest("PUT", "/api/v9/users/@me/widgets", body: ["widgets": [["data": ["type": "favorite_games", "games": [["game_id": "1200000000000000001"]]]]]])
        await flowEnd(nil)

        guard let friend = await world.relationships[me]?.values.first(where: { $0.type == .friend })?.userID else {
            throw WorldError.invalidBody("scenario has no friend")
        }
        await flowStart()
        _ = try await rest("PATCH", "/api/v9/users/@me/relationships/\(friend)", body: ["nickname": "neighbour"])
        _ = try await rest("PATCH", "/api/v9/users/@me/relationships/\(friend)", body: ["nickname": .null])
        _ = try await rest("PUT", "/api/v9/users/@me/relationships/\(friend)/ignore")
        _ = try await rest("DELETE", "/api/v9/users/@me/relationships/\(friend)/ignore")
        await flowEnd(nil)
    }

    mutating func expressionPickers(_ target: Targets) async throws {
        _ = try await rest("GET", "/api/v9/gifs/trending?locale=en-GB&media_format=webm")
        _ = try await rest("GET", "/api/v9/gifs/search?q=cozy&media_format=webm&locale=en-GB")
        _ = try await rest("GET", "/api/v9/gifs/trending-gifs?media_format=webm&locale=en-GB")
        _ = try await rest("POST", "/api/v9/gifs/select", body: ["id": "cozy-1", "q": "cozy"])
        _ = try await rest("GET", "/api/v9/guilds/\(target.guild)/emojis")
        _ = try await rest("GET", "/api/v9/sticker-packs?locale=en-GB")
        _ = try await rest("GET", "/api/v9/soundboard-default-sounds")
        _ = try await rest("GET", "/api/v9/users/\(target.otherUser)/application-identities?with_disabled=true")
        await flowStart()
        try await gateway?.send(.object(JSONObject([("op", 31), ("d", .object(JSONObject([("guild_ids", [.string(target.guild.description)])])))])))
        await flowEnd(nil)

        await flowStart()
        let poll = try await postMessage(in: target.channel, "", [
            ("poll", .object(JSONObject([("question", ["text": "parity expire?"]), ("answers", [["poll_media": ["text": "a"]], ["poll_media": ["text": "b"]]]),
                                         ("allow_multiselect", false), ("duration", 24), ("layout_type", 1)]))),
        ])
        if let id = poll["id"]?.stringValue { _ = try await rest("POST", "/api/v9/channels/\(target.channel)/polls/\(id)/expire") }
        await flowEnd(nil)
    }
}
