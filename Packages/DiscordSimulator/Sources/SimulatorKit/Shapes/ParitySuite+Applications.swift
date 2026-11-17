import Foundation

extension ParityRun {
    /// Command catalogues, the command behind a bot reply, OAuth2 consent and authorized apps, member
    /// requests by ID, and widget configs.
    mutating func applications(_ target: Targets) async throws {
        let world = simulator.world
        let bot = try await targetBot(target)
        _ = try await rest("GET", "/api/v9/channels/\(target.channel)/application-command-index")
        _ = try await rest("GET", "/api/v9/applications/\(bot)/application-command-index")
        if let reply = await world.channels[target.channel]?.messages.last(where: { $0.interaction?.type == 2 }) {
            _ = try await rest("GET", "/api/v9/channels/\(target.channel)/messages/\(reply.id)/interaction-data")
        }

        let query = "client_id=\(bot)&response_type=code&scope=identify&state=parity"
        _ = try await rest("GET", "/api/v9/oauth2/authorize?\(query)&integration_type=1")
        let context: JSON = ["guild_id": "10000", "channel_id": "10000", "channel_type": 10_000]
        await flowStart()
        _ = try await rest("POST", "/api/v9/oauth2/authorize?\(query)", body: ["authorize": true, "location_context": context])
        _ = try await rest("POST", "/api/v9/oauth2/authorize?\(query)", body: ["authorize": true, "location_context": context])
        _ = try await rest("POST", "/api/v9/oauth2/authorize?\(query)",
                           body: ["permissions": "0", "authorize": false, "integration_type": 1, "location_context": context])
        try await gateway?.send(.object(JSONObject([("op", 8), ("d", .object(JSONObject([
            ("guild_id", [.string(target.guild.description)]), ("query", .null), ("limit", .null),
            ("user_ids", [.string(target.otherUser.description), .string(Snowflake(date: Date(), increment: 1).description)]), ("presences", false),
        ])))])))
        await flowEnd(nil)
        _ = try await rest("GET", "/api/v9/oauth2/tokens")
        _ = try await rest("GET", "/api/v9/widget-configs/featured")
        _ = try await rest("GET", "/api/v9/widget-configs/developer")
        _ = try await rest("GET", "/api/v9/applications/\(bot)/widget-configs")
    }
}
