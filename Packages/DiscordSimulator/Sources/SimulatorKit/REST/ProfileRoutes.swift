import Foundation

/// Profile editing: identity, profile details, server profile and nickname, server tag, avatar history,
/// the collectibles shop and widgets.
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
        // Not captured: removing a past avatar answers 204, and an unknown one Discord's bare 404.
        routes["DELETE /api/v9/users/@me/avatars/{id}"] = { context in
            try await context.world.deleteAvatarHistoryEntry(try context.id(0), of: context.userID)
            return .empty
        }
        routes["GET /api/v9/collectibles-categories/v2"] = { context in .json(await context.world.renderCollectibleCategories()) }
        routes["GET /api/v9/collectibles-products/{id}"] = { context in
            .json(await context.world.renderProduct(try await context.world.collectibleProduct(try context.id(0)), withPrices: false))
        }
        routes["GET /api/v9/users/@me/collectibles-purchases"] = { context in .json(await context.world.renderPurchases(context.userID)) }
        routes["PUT /api/v9/users/@me/widgets"] = { context in
            .json(try await context.world.saveProfileWidgets(context.userID, body: try context.json))
        }
    }
}
