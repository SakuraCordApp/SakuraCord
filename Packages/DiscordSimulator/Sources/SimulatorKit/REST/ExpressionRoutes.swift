import Foundation

/// GIF, emoji, sticker and soundboard pickers, linked application identities, and ending polls.
enum ExpressionRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/gifs/search"] = { context in
            .json(.array(await context.world.gifSearch(context.query("q") ?? "", limit: Int(context.query("limit") ?? "50") ?? 50)))
        }
        routes["GET /api/v9/gifs/trending"] = { context in .json(await context.world.gifTrending()) }
        routes["GET /api/v9/gifs/trending-gifs"] = { context in .json(.array(await context.world.gifSearch("trending", limit: 50))) }
        // Selection only feeds Discord's GIF ranking.
        routes["POST /api/v9/gifs/select"] = { _ in .empty }

        routes["GET /api/v9/guilds/{id}/emojis"] = { context in
            .json(.array(try await context.world.guildEmojis(try context.id(0), viewer: context.userID)))
        }
        routes["GET /api/v9/sticker-packs"] = { context in .json(await context.world.stickerPacks()) }
        routes["GET /api/v9/soundboard-default-sounds"] = { context in .json(.array(await context.world.defaultSoundboardSounds())) }

        // Nobody in the simulated world has linked an application account.
        routes["GET /api/v9/users/{id}/application-identities"] = { context in
            _ = try await context.world.user(try context.id(0))
            return .json(.object(JSONObject([("identities", [])])))
        }

        routes["POST /api/v9/channels/{id}/polls/{id}/expire"] = { context in
            .json(try await context.world.expirePoll(try context.id(1), in: try context.id(0), by: context.userID))
        }
    }
}
