import Foundation

/// Slash commands and button presses (`POST /interactions`, JSON or multipart `payload_json`).
enum InteractionRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["POST /api/v9/interactions"] = { context in
            let (body, _) = try MultipartForm.messageBody(context.request)
            try await context.world.interact(body, as: context.userID)
            return .empty
        }
    }
}
