import Foundation

/// Activities: the launcher shelf, application details, joining and leaving an
/// instance, proxy tickets and disclosures, as captured from the official client.
enum ActivityRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/activities/shelf"] = { context in .json(await context.world.activityShelf()) }
        routes["GET /api/v9/applications/{id}/public"] = { context in
            .json(try await context.world.renderActivityApplication(try context.id(0)))
        }
        routes["POST /api/v9/activities/{id}/{id}"] = { context in
            let world = context.world
            let instance = try await world.launchActivity(try context.id(1), in: try context.id(0), by: context.userID,
                                                          sessionID: try context.json["session_id"]?.stringValue ?? "")
            await world.announceActivity(instance)
            return .empty
        }
        routes["POST /api/v9/applications/{id}/activities/{id}/instances/{id}/leave"] = { context in
            // Location IDs (`gc-…`, `pc-…`) aren't snowflakes, so the router doesn't extract them.
            let segments = context.request.path.split(separator: "/").map(String.init)
            let location = segments.firstIndex(of: "activities").map { segments[$0 + 1] } ?? ""
            try await context.world.leaveActivity(try context.id(0), locationID: location, instanceID: try context.id(1), by: context.userID)
            return .json(.object(JSONObject()))
        }
        routes["POST /api/v9/applications/{id}/proxy-tickets"] = { context in
            .json(try await context.world.activityProxyTicket(try context.id(0), for: context.userID))
        }
        routes["GET /api/v9/applications/{id}/disclosures"] = { context in
            .json(try await context.world.activityDisclosures(try context.id(0), for: context.userID))
        }
        routes["POST /api/v9/applications/{id}/disclosures"] = { context in
            let disclosures = (try context.json["disclosures"]?.arrayValue ?? []).compactMap { $0.intValue.map(Int.init) }
            return .json(try await context.world.acknowledgeDisclosures(disclosures, for: try context.id(0), by: context.userID))
        }
    }
}
