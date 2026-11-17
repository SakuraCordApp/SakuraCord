import Foundation

/// Profile widgets and game profiles: the game catalogue, application widget
/// configs, suggested games and widget image uploads.
enum WidgetRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/games"] = { context in
            .json(await context.world.renderGames((context.request.query["game_ids"] ?? []).compactMap(Snowflake.init)))
        }
        routes["GET /api/v9/games/autocomplete"] = { context in
            .json(await context.world.autocompleteGames(context.query("q") ?? ""))
        }
        // Captured: a game without an official server (no simulated game has one) answers with no channel and no messages.
        routes["GET /api/v9/games/{id}/announcements"] = { context in
            _ = try await context.world.game(try context.id(0))
            return .json(.object(JSONObject([("guild_id", .null), ("channel_id", .null), ("messages", [])])))
        }
        // Captured: up to 20 similar games. Which ones Discord picks isn't knowable; the catalogue's others stand in.
        routes["GET /api/v9/content-inventory/users/@me/similar-games/{id}"] = { context in
            let game = try await context.world.game(try context.id(0))
            let others = await context.world.games.filter { $0.id != game.id }.prefix(20).map(\.id.json)
            return .json(.object(JSONObject([("game_id", game.id.json), ("similar_games", .array(Array(others)))])))
        }
        // Discord suggests games from what the user and their friends play (inferred); the
        // simulated world keeps no wishlists.
        routes["GET /api/v9/users/@me/widgets/suggested-games"] = { context in
            let played = await context.world.gamesPlayed(around: context.userID)
            return .json(.object(JSONObject([("suggested_games", .array(played.map(\.json))), ("suggested_wishlist_games", [])])))
        }

        // No simulated application publishes a widget config, so both catalogues and every
        // application's list are empty.
        for catalogue in ["featured", "developer"] {
            routes["GET /api/v9/widget-configs/\(catalogue)"] = { _ in
                .json(.object(JSONObject([("applications", []), ("configs", .object(JSONObject()))])))
            }
        }
        routes["GET /api/v9/applications/{id}/widget-configs"] = { context in
            guard await context.world.users[try context.id(0)]?.bot == true else { throw WorldError.unknown("Application", code: 10002) }
            return .json([])
        }

        // The body and answer follow the official client's code; not captured: the slot is on the
        // attachment host like a message attachment's, and saving a personal widget consumes it.
        routes["POST /api/v9/users/@me/widgets/assets/upload"] = { context in
            guard let filename = try context.json["filename"]?.stringValue, !filename.isEmpty else { throw WorldError.invalidBody("filename") }
            let name = await context.world.reserveUpload(filename: filename, owner: context.userID, channel: nil)
            return .json(.object(JSONObject([("upload_url", .string(World.uploadURL(for: name))), ("upload_filename", .string(name))])))
        }
    }
}
