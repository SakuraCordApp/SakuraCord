import Foundation

/// Editing, deleting and joining threads and forum posts (`/channels/{id}`, `/thread-members/@me`).
enum ChannelEditRoutes {
    /// A real route whose behavior for this kind of channel hasn't been built yet: a 500 and an ERROR log, never a quiet stub.
    struct NotSimulated: Error, CustomStringConvertible {
        var description: String
    }

    static func register(into routes: inout [String: RouteHandler]) {
        routes["PATCH /api/v9/channels/{id}"] = { context in
            let world = context.world
            let channel = try await world.channel(try context.id(0))
            guard channel.type.isThread else { throw NotSimulated(description: "editing a channel of type \(channel.type)") }
            let thread = try await world.editThread(channel.id, by: context.userID, patch: try context.json)
            return .json(await world.renderThread(thread, viewer: context.userID))
        }
        routes["DELETE /api/v9/channels/{id}"] = { context in
            let world = context.world
            let channel = try await world.channel(try context.id(0))
            guard channel.type.isThread else { throw NotSimulated(description: "deleting a channel of type \(channel.type)") }
            let rendered = await world.renderThread(channel, viewer: context.userID)
            _ = try await world.deleteThread(channel.id, by: context.userID)
            return .json(rendered)
        }

        routes["POST /api/v9/channels/{id}/thread-members/@me"] = { context in
            try await context.world.joinThread(try context.id(0), by: context.userID)
            return .empty
        }
        routes["DELETE /api/v9/channels/{id}/thread-members/@me"] = { context in
            try await context.world.leaveThread(try context.id(0), by: context.userID)
            return .empty
        }
        routes["PATCH /api/v9/channels/{id}/thread-members/@me/settings"] = { context in
            guard let muted = try context.json["muted"]?.boolValue else { throw WorldError.invalidBody("muted") }
            return .json(try await context.world.setThreadMuted(try context.id(0), by: context.userID, muted: muted))
        }
    }
}
