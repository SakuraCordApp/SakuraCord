import Foundation

/// Private call ringing. `POST /call/ring` follows the captured request
/// (`recipients: null` rings everyone else); `GET /call` and
/// `POST /call/stop-ringing` are not captured yet and follow Discord's
/// behavior as the official client relies on it.
enum CallRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/channels/{id}/call"] = { context in
            .json(try await context.world.callEligibility(try context.id(0), for: context.userID))
        }
        routes["POST /api/v9/channels/{id}/call/ring"] = { context in
            try await context.world.ring(try context.id(0), by: context.userID, recipients: try recipients(context))
            return .empty
        }
        routes["POST /api/v9/channels/{id}/call/stop-ringing"] = { context in
            try await context.world.stopRinging(try context.id(0), by: context.userID, recipients: try recipients(context) ?? [context.userID])
            return .empty
        }
    }

    private static func recipients(_ context: RouteContext) throws -> [Snowflake]? {
        try context.json["recipients"]?.arrayValue?.compactMap { $0.stringValue.flatMap(Snowflake.init) }
    }
}
