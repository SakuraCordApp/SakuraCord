import Foundation

/// Editing, deleting and joining threads and forum posts (`/channels/{id}`, `/thread-members/@me`),
/// and creating, editing and deleting guild channels.
enum ChannelEditRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["PATCH /api/v9/channels/{id}"] = { context in
            let world = context.world
            let channel = try await world.channel(try context.id(0))
            if channel.type.isThread {
                let thread = try await world.editThread(channel.id, by: context.userID, patch: try context.json)
                return .json(await world.renderThread(thread, viewer: context.userID))
            }
            if channel.type == .groupDM {
                return .json(await world.renderChannel(try await world.editGroupDM(channel.id, by: context.userID, patch: try context.json),
                                                       viewer: context.userID))
            }
            // Discord's answer to editing a 1:1 DM was never captured.
            guard channel.type != .dm else { throw NotSimulated(description: "editing a DM") }
            let edited = try await world.editGuildChannel(channel.id, by: context.userID, patch: try context.json)
            return .json(await world.renderChannel(edited, viewer: context.userID))
        }
        routes["DELETE /api/v9/channels/{id}"] = { context in
            let world = context.world
            let channel = try await world.channel(try context.id(0))
            if channel.type.isThread {
                let rendered = await world.renderThread(channel, viewer: context.userID)
                _ = try await world.deleteThread(channel.id, by: context.userID)
                return .json(rendered)
            }
            if channel.type.isPrivate { return .json(try await world.closePrivateChannel(channel.id, by: context.userID)) }
            return .json(await world.renderChannel(try await world.deleteGuildChannel(channel.id, by: context.userID), viewer: context.userID))
        }

        routes["PUT /api/v9/channels/{id}/permissions/{id}"] = { context in
            try await context.world.setPermissionOverwrite(try context.id(0), target: try context.id(1), by: context.userID, body: try context.json)
            return .empty
        }
        routes["DELETE /api/v9/channels/{id}/permissions/{id}"] = { context in
            try await context.world.setPermissionOverwrite(try context.id(0), target: try context.id(1), by: context.userID, body: nil)
            return .empty
        }

        routes["PATCH /api/v9/guilds/{id}/channels"] = { context in
            try await context.world.reorderChannels(in: try context.id(0), by: context.userID, body: try context.json)
            return .empty
        }
        routes["POST /api/v9/guilds/{id}/channels"] = { context in
            let world = context.world
            let channel = try await world.createGuildChannel(in: try context.id(0), by: context.userID, body: try context.json)
            return .json(await world.renderChannel(channel, viewer: context.userID), status: 201)
        }

        routes["PUT /api/v9/channels/{id}/recipients/{id}"] = { context in
            try await context.world.addGroupRecipient(try context.id(0), try context.id(1), by: context.userID)
            return .empty
        }
        routes["DELETE /api/v9/channels/{id}/recipients/{id}"] = { context in
            try await context.world.removeGroupRecipient(try context.id(0), try context.id(1), by: context.userID)
            return .empty
        }

        // Message requests: accepting keeps the DM (not captured: 204 and no event when it was
        // no request); ignoring closes it for this user only, without telling the sender.
        routes["PUT /api/v9/channels/{id}/recipients/@me"] = { context in
            try await context.world.acceptMessageRequest(try context.id(0), by: context.userID, consent: try context.json["consent_status"])
            return .empty
        }
        routes["DELETE /api/v9/channels/{id}/recipients/@me"] = { context in
            try await context.world.ignoreMessageRequest(try context.id(0), by: context.userID)
            return .empty
        }
        routes["POST /api/v9/channels/{id}/blocked-user-warning-dismissal"] = { context in
            try await context.world.dismissBlockedUserWarning(in: try context.id(0), by: context.userID)
            return .emptyOK
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
