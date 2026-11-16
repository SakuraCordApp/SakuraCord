import Foundation

/// An invite link to a guild channel.
public struct Invite: Sendable {
    public var id: Snowflake
    public var code: String
    public var guildID: Snowflake
    public var channelID: Snowflake
    public var inviterID: Snowflake?
    public var createdAt: Date
    /// Seconds until it expires; 0 never expires.
    public var maxAge = 604_800
    /// 0 is unlimited.
    public var maxUses = 0
    public var uses = 0
    public var temporary = false

    public var expiresAt: Date? { maxAge == 0 ? nil : createdAt.addingTimeInterval(Double(maxAge)) }
}

/// An application to join a guild that reviews new members.
public struct JoinRequest: Sendable {
    public enum Status: String, Sendable { case started = "STARTED", submitted = "SUBMITTED", approved = "APPROVED", rejected = "REJECTED" }

    public var id: Snowflake
    public var guildID: Snowflake
    public var userID: Snowflake
    public var status: Status = .started
    /// The submitted form fields, each with its `response`, wire-shaped.
    public var formResponses: [JSON] = []
    public var reviewedAt: Date?
    public var actionedBy: Snowflake?
    public var actionID: Snowflake?
    public var rejectionReason: String?
}

/// Invites, applications to join, and each guild's server guide and onboarding.
public struct ServerState: Sendable {
    public var invites: [String: Invite] = [:]
    public var joinRequests: [Snowflake: JoinRequest] = [:]
    /// Membership application form (`version`, `description`, `form_fields`), wire-shaped.
    public var verificationForms: [Snowflake: JSONObject] = [:]
    /// Server guide (`enabled`, `welcome_message`, `new_member_actions`, `resource_channels`), wire-shaped.
    public var guides: [Snowflake: JSONObject] = [:]
    /// Onboarding (`prompts`, `default_channel_ids`, `enabled`, `mode`), wire-shaped.
    public var onboarding: [Snowflake: JSONObject] = [:]
    /// Server guide channel actions each member completed, per guild.
    public var completedActions: [Snowflake: [Snowflake: [Snowflake]]] = [:]
    /// Profile card traits and brand colour, per guild.
    public var traits: [Snowflake: [JSON]] = [:]
    public var brandColors: [Snowflake: String] = [:]
    public var scheduledEvents: [Snowflake: ScheduledEvent] = [:]
    /// The newest scheduled event each user marked read, per guild.
    public var eventAcks: [Snowflake: [Snowflake: Snowflake]] = [:]
    public var eventAckVersion: Int64 = 1
    /// Registered OAuth2 redirect URIs per application, and each user's grants.
    public var oauthRedirects: [Snowflake: [String]] = [:]
    public var autoModRules: [Snowflake: AutoModRule] = [:]
    /// Each member's onboarding answers and what they've seen, wire-shaped, per guild.
    public var onboardingResponses: [Snowflake: [Snowflake: JSONObject]] = [:]
    public var oauthGrants: [Snowflake: [Snowflake: OAuth2Grant]] = [:]
}

// MARK: Invites and membership

extension World {
    func invite(_ code: String) throws -> Invite {
        guard let invite = servers.invites[code], invite.expiresAt.map({ $0 > clock.now }) ?? true,
              invite.maxUses == 0 || invite.uses < invite.maxUses, guilds[invite.guildID] != nil
        else { throw WorldError.unknown("Invite", code: 10006) }
        return invite
    }

    func createInvite(in channelID: Snowflake, by userID: Snowflake, maxAge: Int, maxUses: Int, temporary: Bool) async throws -> Invite {
        let channel = try channel(channelID)
        guard let guildID = channel.guildID else { throw WorldError.missingAccess }
        try require(.createInstantInvite, userID, channel)
        var code: String
        repeat { code = random.urlSafeString(8).filter { $0.isLetter || $0.isNumber } } while code.count < 7 || servers.invites[code] != nil
        let invite = Invite(id: nextID(), code: code, guildID: guildID, channelID: channelID, inviterID: userID, createdAt: clock.now,
                            maxAge: maxAge, maxUses: maxUses, temporary: temporary)
        servers.invites[code] = invite
        let changes: [(String, JSON)] = [("code", .string(code)), ("channel_id", channelID.json), ("inviter_id", userID.json), ("uses", 0),
                                         ("max_uses", .int(maxUses)), ("max_age", .int(maxAge)), ("temporary", .bool(temporary)), ("flags", 0)]
        await emitAuditLog(guildID, action: 40, target: invite.id, by: userID, changes: changes.map { auditChange($0.0, old: nil, new: $0.1) })
        return invite
    }

    /// `POST /invites/{code}`: joins the guild, or starts an application when it reviews new members.
    func acceptInvite(_ code: String, by userID: Snowflake) async throws -> JSON {
        var invite = try invite(code)
        let guild = try guild(invite.guildID)
        var response = renderInvite(invite, viewer: userID)
        if guild.members[userID] != nil {
            return response.merging(["new_member": false])
        }
        if guild.features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL") {
            _ = try await startJoinRequest(guild.id, by: userID)
            return response.merging(["new_member": true, "show_verification_form": true])
        }
        invite.uses += 1
        servers.invites[code] = invite
        try await addMember(userID, to: guild.id)
        response = response.merging(["new_member": true])
        return response
    }

    /// Adds a member: the joiner receives the whole guild, everyone else the new member,
    /// and the system channel welcomes them.
    func addMember(_ userID: Snowflake, to guildID: Snowflake) async throws {
        var guild = try guild(guildID)
        guard guild.members[userID] == nil else { return }
        guild.members[userID] = Member(userID: userID, joinedAt: clock.now)
        guild.memberOrder.append(userID)
        guilds[guildID] = guild
        if !guildOrder.contains(guildID) { guildOrder.append(guildID) }
        await emit("GUILD_CREATE", renderGuildCreate(guild, viewer: userID), to: .users([userID]))
        if let member = guild.members[userID] {
            let added = renderMember(member, guildID: guildID, includeUser: true).merging(["guild_id": guildID.json])
            await emit("GUILD_MEMBER_ADD", added, to: .users(Set(guild.members.keys).subtracting([userID])))
        }
        if users[userID]?.bot == true { await emitCommandIndexUpdate(guildID) }
        if let systemChannel = guild.systemChannelID {
            var notice = MessageDraft()
            notice.type = 7
            _ = try await sendSystemMessage(notice, as: userID, in: systemChannel)
        }
    }

    /// `DELETE /users/@me/guilds/{id}`. Owners must transfer the server first.
    func leaveGuild(_ guildID: Snowflake, userID: Snowflake) async throws {
        let guild = try guild(guildID)
        guard guild.members[userID] != nil else { throw WorldError.unknown("Guild", code: 10004) }
        guard guild.ownerID != userID else { throw WorldError(status: 400, code: 50055, message: "Invalid Guild") }
        try await removeMember(userID, from: guildID)
    }

    /// `PUT /guilds/{id}/members/@me`: joining a server listed in Server Discovery.
    func joinDiscoverableGuild(_ guildID: Snowflake, userID: Snowflake) async throws {
        let guild = try guild(guildID)
        guard guild.features.contains("DISCOVERABLE") else { throw WorldError.missingAccess }
        try await addMember(userID, to: guildID)
    }

    func renderInvite(_ invite: Invite, withCounts: Bool = false, withPermissions: Bool = false, viewer: Snowflake) -> JSON {
        guard let guild = guilds[invite.guildID], let channel = channels[invite.channelID] else { return .null }
        var object = JSONObject([
            ("type", 0), ("code", .string(invite.code)), ("id", invite.id.json),
            ("inviter", invite.inviterID.map(renderUser) ?? .null),
            ("max_age", .int(invite.maxAge)), ("created_at", World.timestamp(invite.createdAt)),
            ("expires_at", World.optionalTimestamp(invite.expiresAt)), ("flags", 0),
            ("guild", .object(JSONObject([
                ("id", guild.id.json), ("name", .string(guild.name)), ("splash", .optional(guild.splash)),
                ("banner", .optional(guild.banner)), ("description", .optional(guild.description)), ("icon", .optional(guild.icon)),
                ("features", .array(guild.features.map(JSON.string))), ("verification_level", .int(guild.verificationLevel)),
                ("vanity_url_code", .null), ("nsfw_level", 0), ("nsfw", false),
                ("premium_subscription_count", .int(guild.premiumSubscriptionCount)), ("premium_tier", .int(guild.premiumTier)),
            ]))),
            ("guild_id", guild.id.json),
            ("channel", .object(JSONObject([("id", channel.id.json), ("type", .int(channel.type.rawValue)), ("name", .optional(channel.name))]))),
            ("profile", renderGuildProfile(guild)),
            ("uses", .int(invite.uses)), ("max_uses", .int(invite.maxUses)), ("temporary", .bool(invite.temporary)),
        ])
        if withCounts {
            object["approximate_member_count"] = .int(guild.memberCount)
            object["approximate_presence_count"] = .int(onlineCount(guild))
        }
        if withPermissions {
            let permissions = guild.members[viewer] != nil ? guild.permissions(of: viewer) : guild.everyoneRole?.permissions ?? []
            object["is_nickname_changeable"] = .bool(permissions.contains(.changeNickname))
        }
        if invite.inviterID == nil { object["inviter"] = nil }
        return .object(object)
    }

    func onlineCount(_ guild: Guild) -> Int {
        guild.approximatePresenceCount ?? guild.members.keys.count(where: isOnline)
    }

    /// The server's profile card, as invites, applications and `GET /guilds/{id}/profile` show it.
    func renderGuildProfile(_ guild: Guild) -> JSON {
        .object(JSONObject([
            ("id", guild.id.json), ("name", .string(guild.name)), ("icon_hash", .optional(guild.icon)),
            ("member_count", .int(guild.memberCount)), ("online_count", .int(onlineCount(guild))),
            ("description", .optional(guild.description)), ("brand_color_primary", .optional(servers.brandColors[guild.id])),
            ("banner_hash", .optional(guild.banner)), ("game_application_ids", []), ("game_activity", .object(JSONObject())),
            ("tag", .null), ("badge", 0), ("badge_color_primary", .null), ("badge_color_secondary", .null), ("badge_hash", .null),
            ("traits", .array(servers.traits[guild.id] ?? [])), ("features", .array(guild.features.map(JSON.string))),
            ("visibility", .int(guild.features.contains("DISCOVERABLE") ? 1 : 3)), ("custom_banner_hash", .null),
            ("premium_subscription_count", .int(guild.premiumSubscriptionCount)), ("premium_tier", .int(guild.premiumTier)),
        ]))
    }

    /// The full guild a member receives when they join: READY's guild form plus members, presences and voice.
    func renderGuildCreate(_ guild: Guild, viewer: Snowflake) -> JSON {
        guard case var .object(object) = readyGuild(guild, viewer: viewer) else { return .null }
        object["members"] = .array(guild.memberOrder.prefix(100).compactMap { id in
            guild.members[id].map { renderMember($0, guildID: guild.id, includeUser: true) }
        })
        object["presences"] = .array(guild.memberOrder.filter { (presences[$0]?.status ?? .offline) != .offline }
            .prefix(100).map { renderPresence($0, guildID: nil) })
        object["voice_states"] = []
        object["embedded_activities"] = []
        object["activity_instances"] = []
        return .object(object)
    }

    /// A member's view of a guild's roles and the channels they can see.
    func guildLists(_ guildID: Snowflake, viewer: Snowflake) throws -> (roles: JSON, channels: JSON) {
        let guild = try guild(guildID)
        guard guild.members[viewer] != nil else { throw WorldError.missingAccess }
        return (.array(guild.roles.map(renderRole)), .array(visibleChannels(in: guild, for: viewer).map { renderChannel($0, viewer: viewer) }))
    }

    /// Members holding a role, as `GET /guilds/{id}/roles/{id}/member-ids` lists them.
    func roleMemberIDs(_ guildID: Snowflake, roleID: Snowflake, viewer: Snowflake) throws -> JSON {
        let guild = try guild(guildID)
        guard guild.members[viewer] != nil else { throw WorldError.missingAccess }
        guard guild.roles.contains(where: { $0.id == roleID }) else { throw WorldError.unknown("Role", code: 10011) }
        return .array(guild.memberOrder.filter { guild.members[$0]?.roles.contains(roleID) == true }.prefix(100).map(\.json))
    }
}
