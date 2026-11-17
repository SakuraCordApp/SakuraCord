import Foundation

/// Scheduled events: creating and deleting them, interest, read state and counts.
enum ScheduledEventRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["POST /api/v9/guilds/{id}/scheduled-events"] = { context in
            let world = context.world
            let event = try await world.createScheduledEvent(in: try context.id(0), by: context.userID, body: try context.json)
            let rendered = await world.renderScheduledEvent(event)
            // A channel event's metadata is null in events but an empty object in this response.
            return .json(event.location == nil ? rendered.merging(["entity_metadata": .object(JSONObject())]) : rendered)
        }
        routes["DELETE /api/v9/guilds/{id}/scheduled-events/{id}"] = { context in
            try await context.world.deleteScheduledEvent(try context.id(1), in: try context.id(0), by: context.userID)
            return .empty
        }
        routes["PUT /api/v9/guilds/{id}/scheduled-events/{id}/users/@me"] = { context in
            let world = context.world
            let (guildID, eventID) = (try context.id(0), try context.id(1))
            try await world.setEventInterest(eventID, in: guildID, userID: context.userID, interested: true)
            let event = try await world.scheduledEvent(eventID, in: guildID)
            return .json(await world.renderEventRSVP(event, userID: context.userID))
        }
        routes["DELETE /api/v9/guilds/{id}/scheduled-events/{id}/users/@me"] = { context in
            try await context.world.setEventInterest(try context.id(1), in: try context.id(0), userID: context.userID, interested: false)
            return .empty
        }
        routes["GET /api/v9/guilds/{id}/scheduled-events/{id}/users/counts"] = { context in
            let event = try await context.world.scheduledEvent(try context.id(1), in: try context.id(0))
            return .json(.object(JSONObject([("guild_scheduled_event_count", .int(event.interested.count)),
                                             ("guild_scheduled_event_exception_counts", .object(JSONObject()))])))
        }
        routes["GET /api/v9/users/@me/scheduled-events"] = { context in
            let guildIDs = (context.request.query["guild_ids"] ?? []).compactMap(Snowflake.init)
            return .json(await context.world.eventRSVPs(context.userID, guildIDs: guildIDs))
        }
        routes["POST /api/v9/guilds/{id}/ack/1/{id}"] = { context in
            try await context.world.acknowledgeEvents(in: try context.id(0), through: try context.id(1), userID: context.userID)
            return .json(.object(JSONObject([("token", .null)])))
        }
    }
}
