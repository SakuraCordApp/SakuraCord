import Foundation

/// Agent controls for what other members do: moderators acting on members,
/// role edits, and someone scheduling an event.
extension ControlAPI {
    func moderationRoute(_ request: HTTPRequest, _ route: [String], _ body: JSON) async throws -> HTTPResponse? {
        switch (request.method, route.first ?? "", route.count) {
        case ("POST", "members", _):
            // Someone (or a bot) joins a server.
            try await world.addMember(try await resolveUser(body["user"]), to: try await resolveGuild(body["guild"]?.stringValue ?? ""))
            return ok([:])
        case ("POST", "automod", _):
            return try await createAutoModRule(body)
        case ("DELETE", "automod", 2):
            guard let id = Snowflake(route[1]), let rule = await world.servers.autoModRules[id] else { throw WorldError.notFound }
            try await world.deleteAutoModRule(id, by: try await world.guild(rule.guildID).ownerID)
            return ok([:])
        case ("POST", "moderation", _):
            return try await moderate(body)
        case ("POST", "roles", 1), ("PATCH", "roles", 2), ("DELETE", "roles", 2):
            let guildID = try await resolveGuild(body["guild"]?.stringValue ?? "")
            if request.method == "DELETE" {
                try await world.saveRole(nil, deleting: Snowflake(route[1]), in: guildID)
                return ok([:])
            }
            var role = Role(id: await world.nextID(), name: "new role", position: 1, permissions: .everyoneDefault)
            if route.count == 2 {
                guard let existing = try await world.guild(guildID).roles.first(where: { $0.id == Snowflake(route[1]) }) else {
                    throw WorldError.unknown("Role", code: 10011)
                }
                role = existing
            }
            if let name = body["name"]?.stringValue { role.name = name }
            if let color = body["color"]?.intValue { role.color = Int(color) }
            if let hoist = body["hoist"]?.boolValue { role.hoist = hoist }
            try await world.saveRole(role, in: guildID)
            return ok(["id": role.id.json])
        case ("POST", "events", _):
            let guildID = try await resolveGuild(body["guild"]?.stringValue ?? "")
            let start = world.clock.now.addingTimeInterval((body["starts_in_minutes"]?.doubleValue ?? 60) * 60)
            var fields = JSONObject([("name", body["name"] ?? "Hangout"), ("description", body["description"] ?? ""),
                                     ("scheduled_start_time", World.timestamp(start))])
            if let location = body["location"]?.stringValue {
                fields["entity_type"] = 3
                fields["entity_metadata"] = .object(JSONObject([("location", .string(location))]))
                fields["scheduled_end_time"] = World.timestamp(start.addingTimeInterval(7_200))
            } else {
                fields["entity_type"] = 2
                fields["channel_id"] = try await resolveChannel(body).json
            }
            let event = try await world.createScheduledEvent(in: guildID, by: try await resolveUser(body["author"]), body: .object(fields))
            return ok(["id": event.id.json])
        default:
            return nil
        }
    }

    /// A keyword rule that blocks matching messages; `timeout_seconds` also times the sender out.
    private func createAutoModRule(_ body: JSON) async throws -> HTTPResponse {
        let guildID = try await resolveGuild(body["guild"]?.stringValue ?? "")
        let owner = try await world.guild(guildID).ownerID
        let creator = try await body["creator"].asyncMap { try await resolveUser($0) } ?? owner
        var rule = AutoModRule(id: await world.nextID(), guildID: guildID, creatorID: creator, name: body["name"]?.stringValue ?? "Block Custom Words",
                           keywords: (body["keywords"]?.arrayValue ?? []).compactMap(\.stringValue))
        rule.allowList = (body["allow_list"]?.arrayValue ?? []).compactMap(\.stringValue)
        rule.timeoutSeconds = body["timeout_seconds"]?.intValue.map(Int.init)
        guard !rule.keywords.isEmpty else { throw WorldError.invalidBody("keywords: at least one") }
        await world.saveAutoModRule(rule)
        return ok(["id": rule.id.json])
    }

    /// `action`: kick, timeout (`minutes`, default 10) or untimeout, by `moderator` (default: the owner).
    private func moderate(_ body: JSON) async throws -> HTTPResponse {
        let guildID = try await resolveGuild(body["guild"]?.stringValue ?? "")
        let target = try await resolveUser(body["user"])
        let owner = try await world.guild(guildID).ownerID
        let moderator = try await body["moderator"].asyncMap { try await resolveUser($0) } ?? owner
        switch body["action"]?.stringValue {
        case "kick":
            guard try await world.guild(guildID).permissions(of: moderator).contains(.kickMembers) else { throw WorldError.missingPermissions }
            try await world.removeMember(target, from: guildID)
            await world.emitAuditLog(guildID, action: 20, target: target, by: moderator, changes: [])
        case "timeout", "untimeout":
            let until = body["action"]?.stringValue == "timeout"
                ? World.timestamp(world.clock.now.addingTimeInterval((body["minutes"]?.doubleValue ?? 10) * 60)) : JSON.null
            _ = try await world.modifyMember(target, in: guildID, by: moderator, body: .object(JSONObject([("communication_disabled_until", until)])))
        default:
            throw WorldError.invalidBody("action must be kick, timeout or untimeout")
        }
        return ok([:])
    }
}
