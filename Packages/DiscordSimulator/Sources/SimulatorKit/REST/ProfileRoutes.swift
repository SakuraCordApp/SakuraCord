import Foundation

/// Profile editing: identity, profile details, server profile and nickname, server tag, avatar history and widgets.
enum ProfileRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["PATCH /api/v9/users/@me"] = { context in
            .json(try await context.world.editIdentity(context.userID, body: try context.json))
        }
        routes["PATCH /api/v9/users/@me/profile"] = { context in
            .json(try await context.world.editProfileDetails(context.userID, body: try context.json))
        }
        routes["PATCH /api/v9/guilds/{id}/members/@me"] = { context in
            .json(try await context.world.editServerProfile(context.userID, in: try context.id(0), body: try context.json))
        }
        // The older nickname-only route reaches the same state and answers with just the nickname.
        routes["PATCH /api/v9/guilds/{id}/members/@me/nick"] = { context in
            let nick = try context.json["nick"] ?? .null
            let member = try await context.world.editServerProfile(context.userID, in: try context.id(0),
                                                                   body: .object(JSONObject([("nick", nick)])))
            return .json(.object(JSONObject([("nick", member["nick"] ?? .null)])))
        }
        routes["PATCH /api/v9/guilds/{id}/profile/@me"] = { context in
            .json(try await context.world.editServerProfileDetails(context.userID, in: try context.id(0), body: try context.json))
        }
        routes["PUT /api/v9/users/@me/clan"] = { context in
            .json(try await context.world.setServerTag(context.userID, body: try context.json))
        }
        routes["GET /api/v9/users/@me/avatars"] = { context in
            .json(.object(JSONObject([("avatars", .array((await context.world.avatarHistory[context.userID] ?? []).map(JSON.object)))])))
        }
        routes["PUT /api/v9/users/@me/widgets"] = { context in
            .json(try await context.world.saveProfileWidgets(context.userID, body: try context.json))
        }
    }
}
