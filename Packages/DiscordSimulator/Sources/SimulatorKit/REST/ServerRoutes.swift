import Foundation

/// Invites, joining and leaving servers, applications to join, roles, and the server guide.
enum ServerRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        registerInvites(into: &routes)
        registerJoinRequests(into: &routes)
        registerGuide(into: &routes)

        routes["GET /api/v9/guilds/{id}/roles/{id}/member-ids"] = { context in
            .json(try await context.world.roleMemberIDs(try context.id(0), roleID: try context.id(1), viewer: context.userID))
        }
    }

    private static func registerInvites(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/invites/{code}"] = { context in
            let world = context.world
            let invite = try await world.invite(context.parameters.first ?? "")
            return .json(await world.renderInvite(invite, withCounts: context.query("with_counts") == "true",
                                                  withPermissions: context.query("with_permissions") == "true", viewer: context.userID))
        }
        routes["POST /api/v9/invites/{code}"] = { context in
            .json(try await context.world.acceptInvite(context.parameters.first ?? "", by: context.userID))
        }
        routes["POST /api/v9/channels/{id}/invites"] = { context in
            let body = try context.json
            let world = context.world
            let invite = try await world.createInvite(
                in: try context.id(0), by: context.userID, maxAge: Int(body["max_age"]?.intValue ?? 604_800),
                maxUses: Int(body["max_uses"]?.intValue ?? 0), temporary: body["temporary"]?.boolValue ?? false
            )
            return .json(await world.renderInvite(invite, viewer: context.userID))
        }
        routes["PUT /api/v9/guilds/{id}/members/@me"] = { context in
            try await context.world.joinDiscoverableGuild(try context.id(0), userID: context.userID)
            return .empty
        }
        routes["DELETE /api/v9/users/@me/guilds/{id}"] = { context in
            try await context.world.leaveGuild(try context.id(0), userID: context.userID)
            return .empty
        }
    }

    private static func registerJoinRequests(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/guilds/{id}/member-verification"] = { context in
            .json(try await context.world.memberVerification(try context.id(0), withGuild: context.query("with_guild") == "true"))
        }
        routes["PUT /api/v9/guilds/{id}/requests/@me"] = { context in
            let world = context.world
            let request = try await world.submitJoinRequest(try context.id(0), by: context.userID, body: try context.json)
            return .json(await world.renderJoinRequest(request, includeUser: false, includeAnswers: false), status: 201)
        }
        routes["POST /api/v9/guilds/{id}/requests/@me"] = { context in
            let world = context.world
            let request = try await world.startJoinRequest(try context.id(0), by: context.userID)
            return .json(await world.renderJoinRequest(request, includeUser: true, includeAnswers: false))
        }
        routes["DELETE /api/v9/guilds/{id}/requests/@me"] = { context in
            try await context.world.withdrawJoinRequest(try context.id(0), by: context.userID)
            return .empty
        }
        routes["GET /api/v9/users/@me/join-request-guilds"] = { context in
            .json(await context.world.joinRequestGuilds(context.userID))
        }
        routes["GET /api/v9/join-requests/{id}"] = { context in
            .json(try await context.world.joinRequestDetails(try context.id(0), viewer: context.userID))
        }
    }

    private static func registerGuide(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/guilds/{id}/profile"] = { context in
            .json(await context.world.renderGuildProfile(try await context.world.guild(try context.id(0))))
        }
        routes["GET /api/v9/guilds/{id}/new-member-welcome"] = { context in
            .json(try await context.world.serverGuide(try context.id(0), viewer: context.userID))
        }
        routes["GET /api/v9/guilds/{id}/new-member-actions"] = { context in
            .json(try await context.world.newMemberActions(try context.id(0), viewer: context.userID))
        }
        routes["POST /api/v9/guilds/{id}/new-member-action/{id}"] = { context in
            .json(try await context.world.completeNewMemberAction(try context.id(0), channelID: try context.id(1), viewer: context.userID))
        }
        routes["GET /api/v9/guilds/{id}/onboarding"] = { context in
            .json(try await context.world.onboarding(try context.id(0), viewer: context.userID))
        }
    }
}
