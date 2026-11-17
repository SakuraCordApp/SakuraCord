import Foundation

/// Agent controls for what other people do to the user's social graph and
/// servers' expressions: friend requests from someone else, and members
/// adding or removing emoji, stickers and soundboard sounds.
extension ControlAPI {
    func expressionRoute(_ request: HTTPRequest, _ route: [String], _ body: JSON) async throws -> HTTPResponse? {
        let adding = request.method == "POST"
        switch (request.method, route.first ?? "", route.count) {
        case ("POST", "friend-requests", _):
            // `from` sends a friend request to `to` (default: the signed-in account).
            let from = try await resolveUser(body["from"]), to = try await resolveUser(body["to"])
            try await world.putRelationship(from, with: to, type: nil)
            return ok([:])
        case ("POST", "emojis", _), ("DELETE", "emojis", _):
            try await world.changeEmoji(try name(body), in: try await guild(body), by: try await resolveUser(body["user"]), adding: adding)
            return ok([:])
        case ("POST", "stickers", _), ("DELETE", "stickers", _):
            try await world.changeSticker(try name(body), in: try await guild(body), adding: adding)
            return ok([:])
        case ("POST", "soundboard", _):
            try await world.addSoundboardSound(try name(body), emoji: body["emoji"]?.stringValue, in: try await guild(body),
                                               by: try await resolveUser(body["user"]))
            return ok([:])
        case ("DELETE", "soundboard", _):
            try await world.removeSoundboardSound(try name(body), in: try await guild(body))
            return ok([:])
        default:
            return nil
        }
    }

    private func name(_ body: JSON) throws -> String {
        guard let name = body["name"]?.stringValue, !name.isEmpty else { throw WorldError.invalidBody("name is required") }
        return name
    }
}
