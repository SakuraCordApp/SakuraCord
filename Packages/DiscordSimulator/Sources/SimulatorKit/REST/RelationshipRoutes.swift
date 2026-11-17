import Foundation

/// Friends, friend requests, blocking, ignoring and friend nicknames.
enum RelationshipRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["POST /api/v9/users/@me/relationships"] = { context in
            guard let username = try context.json["username"]?.stringValue else { throw WorldError.invalidBody("username") }
            try await context.world.sendFriendRequest(context.userID, toUsername: username)
            return .empty
        }
        routes["PUT /api/v9/users/@me/relationships/{id}"] = { context in
            try await context.world.putRelationship(context.userID, with: try context.id(0), type: try context.json["type"]?.intValue.map(Int.init))
            return .empty
        }
        routes["DELETE /api/v9/users/@me/relationships/{id}"] = { context in
            try await context.world.deleteRelationship(context.userID, with: try context.id(0))
            return .empty
        }
        routes["PATCH /api/v9/users/@me/relationships/{id}"] = { context in
            let nickname = try context.json["nickname"]?.stringValue
            try await context.world.updateRelationship(context.userID, with: try context.id(0)) { relationship in
                relationship.nickname = nickname.flatMap { $0.isEmpty ? nil : $0 }
            }
            return .empty
        }
        for (method, ignored) in [("PUT", true), ("DELETE", false)] {
            routes["\(method) /api/v9/users/@me/relationships/{id}/ignore"] = { context in
                try await context.world.setIgnored(context.userID, try context.id(0), ignored: ignored)
                return .empty
            }
        }
    }
}
