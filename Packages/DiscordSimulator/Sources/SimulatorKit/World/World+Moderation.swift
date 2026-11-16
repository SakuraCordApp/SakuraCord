import Foundation

extension Member {
    /// Guild member flags Discord sets as a member goes through onboarding.
    static let completedOnboarding = 1 << 1
    static let startedOnboarding = 1 << 3
}

// Member moderation and role changes, with the audit log entries Discord
// dispatches to members who can view the audit log.
extension World {
    /// The highest role position a member holds; the owner outranks everyone.
    private func rank(_ userID: Snowflake, in guild: Guild) -> Int {
        if userID == guild.ownerID { return .max }
        let held = guild.members[userID]?.roles ?? []
        return guild.roles.filter { held.contains($0.id) }.map(\.position).max() ?? 0
    }

    /// Moderators act only on members ranked below them.
    func requireModeration(_ permission: Permissions, by moderator: Snowflake, on target: Snowflake, in guild: Guild) throws {
        guard guild.permissions(of: moderator).contains(permission) else { throw WorldError.missingPermissions }
        guard target == moderator || rank(moderator, in: guild) > rank(target, in: guild) else { throw WorldError.missingPermissions }
    }

    /// `PATCH /guilds/{id}/members/{id}`: nickname, roles and timeout, each with its own permission.
    func modifyMember(_ target: Snowflake, in guildID: Snowflake, by moderator: Snowflake, body: JSON) async throws -> JSON {
        let guild = try guild(guildID)
        guard var member = guild.members[target] else { throw WorldError.unknown("Member", code: 10007) }
        var changes: [JSON] = []
        if let nick = body["nick"] {
            try requireModeration(target == moderator ? .changeNickname : .manageNicknames, by: moderator, on: target, in: guild)
            let new = nick.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            guard (new?.count ?? 0) <= 32 else { throw WorldError.invalidBody("nick: Must be 32 or fewer in length.") }
            changes.append(auditChange("nick", old: member.nick.map(JSON.string), new: new.map(JSON.string)))
            member.nick = new
        }
        if let roles = body["roles"]?.arrayValue {
            try requireModeration(.manageRoles, by: moderator, on: target, in: guild)
            let ids = roles.compactMap { $0.stringValue.flatMap(Snowflake.init) }
            let ceiling = rank(moderator, in: guild)
            guard ids.allSatisfy({ id in guild.roles.contains { $0.id == id && $0.id != guildID && !$0.managed && $0.position < ceiling } }) else {
                throw WorldError.missingPermissions
            }
            member.roles = ids
        }
        if let until = body["communication_disabled_until"] {
            try requireModeration(.moderateMembers, by: moderator, on: target, in: guild)
            guard target != guild.ownerID, !guild.permissions(of: target).contains(.administrator) else { throw WorldError.missingPermissions }
            member.communicationDisabledUntil = until.stringValue.flatMap(World.parseTimestamp)
        }
        guilds[guildID]?.members[target] = member
        await emitMemberUpdate(member, in: guildID)
        if !changes.isEmpty { await emitAuditLog(guildID, action: 24, target: target, by: moderator, changes: changes) }
        return renderMember(member, guildID: guildID, includeUser: true)
    }

    func emitMemberUpdate(_ member: Member, in guildID: Snowflake) async {
        await emit("GUILD_MEMBER_UPDATE", renderMember(member, guildID: guildID, includeUser: true).merging(["guild_id": guildID.json]),
                   to: .guild(guildID, channel: nil))
    }

    /// Removes a member: everyone sees them go, and they lose the guild.
    func removeMember(_ userID: Snowflake, from guildID: Snowflake) async throws {
        guard try guild(guildID).members[userID] != nil else { throw WorldError.unknown("Member", code: 10007) }
        await emit("GUILD_MEMBER_REMOVE", .object(JSONObject([("guild_id", guildID.json), ("user", renderUser(userID))])),
                   to: .guild(guildID, channel: nil))
        guilds[guildID]?.members[userID] = nil
        guilds[guildID]?.memberOrder.removeAll { $0 == userID }
        await emit("GUILD_DELETE", .object(JSONObject([("id", guildID.json)])), to: .users([userID]))
    }

    /// Creates, edits (`role` non-nil with an existing ID) or deletes (`role` nil) a role.
    func saveRole(_ role: Role?, deleting roleID: Snowflake? = nil, in guildID: Snowflake) async throws {
        var guild = try guild(guildID)
        let version = JSON.int(Int64(clock.now.timeIntervalSince1970 * 1000))
        if let role {
            let exists = guild.roles.contains { $0.id == role.id }
            if exists { guild.roles = guild.roles.map { $0.id == role.id ? role : $0 } } else { guild.roles.append(role) }
            guilds[guildID] = guild
            // Only managed roles carry tags in role events.
            let rendered = role.managed ? renderRole(role) : renderRole(role).removing("tags")
            await emit(exists ? "GUILD_ROLE_UPDATE" : "GUILD_ROLE_CREATE", .object(JSONObject([
                ("guild_id", guildID.json), ("role", rendered.merging(["version": version])),
            ])), to: .guild(guildID, channel: nil))
        } else if let roleID, roleID != guildID, guild.roles.contains(where: { $0.id == roleID }) {
            guild.roles.removeAll { $0.id == roleID }
            for id in guild.memberOrder { guild.members[id]?.roles.removeAll { $0 == roleID } }
            guilds[guildID] = guild
            await emit("GUILD_ROLE_DELETE", .object(JSONObject([("guild_id", guildID.json), ("role_id", roleID.json), ("version", version)])),
                       to: .guild(guildID, channel: nil))
        } else {
            throw WorldError.unknown("Role", code: 10011)
        }
    }

    func auditChange(_ key: String, old: JSON?, new: JSON?) -> JSON {
        var object = JSONObject([("key", .string(key))])
        if let old { object["old_value"] = old }
        if let new { object["new_value"] = new }
        return .object(object)
    }

    /// GUILD_AUDIT_LOG_ENTRY_CREATE goes only to members who can view the audit log.
    func emitAuditLog(_ guildID: Snowflake, action: Int, target: Snowflake?, by userID: Snowflake, changes: [JSON],
                      options: JSONObject? = nil) async {
        guard let guild = guilds[guildID] else { return }
        let viewers = Set(guild.members.keys.filter { guild.permissions(of: $0).contains(.viewAuditLog) })
        var entry = JSONObject([("guild_id", guildID.json), ("action_type", .int(action))])
        if !changes.isEmpty { entry["changes"] = .array(changes) }
        entry["id"] = nextID().json
        if let options { entry["options"] = .object(options) }
        entry["target_id"] = target?.json ?? .null
        entry["user_id"] = userID.json
        await emit("GUILD_AUDIT_LOG_ENTRY_CREATE", .object(entry), to: .users(viewers))
    }
}
