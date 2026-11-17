import Foundation

/// Private call ringing, Go Live previews and soundboard sounds in voice.
/// `POST /call/ring`, `POST /call/stop-ringing`, `GET /call`, `GET /streams/{key}/preview`
/// and `POST /send-soundboard-sound` follow captured requests.
enum VoiceRoutes {
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
        routes["GET /api/v9/streams/{id}/preview"] = { context in
            // Stream keys (`guild:…:…:…`) aren't snowflakes, so the router doesn't extract them.
            let segments = context.request.path.split(separator: "/")
            let key = segments.firstIndex(of: "streams").map { String(segments[$0 + 1]).removingPercentEncoding ?? "" } ?? ""
            return .json(try await context.world.streamPreview(key, viewer: context.userID))
        }
        routes["POST /api/v9/channels/{id}/send-soundboard-sound"] = { context in
            let body = try context.json
            guard let soundID = body["sound_id"]?.stringValue else { throw WorldError.invalidBody("sound_id is required") }
            try await context.world.playSoundboardSound(soundID, in: try context.id(0), by: context.userID,
                                                        emojiID: body["emoji_id"]?.stringValue.flatMap(Snowflake.init),
                                                        emojiName: body["emoji_name"]?.stringValue)
            return .empty
        }
    }

    private static func recipients(_ context: RouteContext) throws -> [Snowflake]? {
        try context.json["recipients"]?.arrayValue?.compactMap { $0.stringValue.flatMap(Snowflake.init) }
    }
}
