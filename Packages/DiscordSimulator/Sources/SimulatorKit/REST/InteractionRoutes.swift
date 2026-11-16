import Foundation

/// Slash commands and button presses (`POST /interactions`, JSON or multipart
/// `payload_json`), the command catalogues, and the command behind a reply.
enum InteractionRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["POST /api/v9/interactions"] = { context in
            let (body, _) = try MultipartForm.messageBody(context.request)
            try await context.world.interact(body, as: context.userID)
            return .empty
        }
        routes["GET /api/v9/users/@me/application-command-index"] = { context in
            .json(try await context.world.applicationCommandIndex(.user, viewer: context.userID))
        }
        routes["GET /api/v9/guilds/{id}/application-command-index"] = { context in
            .json(try await context.world.applicationCommandIndex(.guild(try context.id(0)), viewer: context.userID))
        }
        routes["GET /api/v9/channels/{id}/application-command-index"] = { context in
            .json(try await context.world.applicationCommandIndex(.channel(try context.id(0)), viewer: context.userID))
        }
        routes["GET /api/v9/applications/{id}/application-command-index"] = { context in
            .json(try await context.world.applicationCommandIndex(.application(try context.id(0)), viewer: context.userID))
        }
        routes["GET /api/v9/channels/{id}/messages/{id}/interaction-data"] = { context in
            .json(try await context.world.interactionData(try context.id(1), in: try context.id(0)))
        }
    }
}
