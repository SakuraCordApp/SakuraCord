import Foundation

/// Scheduled messages: Discord stores the request and sends it at the chosen time.
enum ScheduledMessageRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/users/@me/scheduled-messages"] = { context in
            let world = context.world
            var list: [JSON] = []
            for scheduled in await world.scheduledMessages(of: context.userID) { list.append(await world.renderScheduledMessage(scheduled)) }
            return .json(.array(list))
        }
        routes["POST /api/v9/users/@me/scheduled-messages"] = { context in
            let scheduled = try await context.world.scheduleMessage(try context.json.objectValue ?? JSONObject(), by: context.userID)
            return .json(await context.world.renderScheduledMessage(scheduled))
        }
        routes["PATCH /api/v9/users/@me/scheduled-messages/{id}"] = { context in
            let scheduled = try await context.world.editScheduledMessage(try context.id(0), by: context.userID,
                                                                         patch: try context.json.objectValue ?? JSONObject())
            return .json(await context.world.renderScheduledMessage(scheduled))
        }
        routes["DELETE /api/v9/users/@me/scheduled-messages/{id}"] = { context in
            try await context.world.cancelScheduledMessage(try context.id(0), by: context.userID)
            return .empty
        }
        routes["POST /api/v9/users/@me/scheduled-messages/{id}/send"] = { context in
            let message = try await context.world.sendScheduledMessage(try context.id(0), by: context.userID)
            return .json(await context.world.renderMessage(message, viewer: context.userID))
        }
    }
}
