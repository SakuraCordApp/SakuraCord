import Foundation

// Applications to join servers that review new members, and the server guide
// and onboarding a new member sees.
extension World {
    func joinRequest(_ guildID: Snowflake, userID: Snowflake) -> JoinRequest? {
        servers.joinRequests.values.filter { $0.guildID == guildID && $0.userID == userID }.max { $0.id < $1.id }
    }

    /// Opens an application (`STARTED`); the applicant sees GUILD_JOIN_REQUEST_CREATE.
    func startJoinRequest(_ guildID: Snowflake, by userID: Snowflake) async throws -> JoinRequest {
        let guild = try guild(guildID)
        guard guild.members[userID] == nil, servers.verificationForms[guildID] != nil else { throw WorldError.missingAccess }
        if let open = joinRequest(guildID, userID: userID), open.isOpen { return open }
        let request = JoinRequest(id: nextID(), guildID: guildID, userID: userID)
        servers.joinRequests[request.id] = request
        await emitJoinRequest("GUILD_JOIN_REQUEST_CREATE", request)
        return request
    }

    /// `PUT /guilds/{id}/requests/@me`: submits the form. Every required field needs a response.
    func submitJoinRequest(_ guildID: Snowflake, by userID: Snowflake, body: JSON) async throws -> JoinRequest {
        guard let form = servers.verificationForms[guildID] else { throw WorldError.unknown("Server Member Verification Form", code: 10068) }
        let fields = body["form_fields"]?.arrayValue ?? []
        if body["version"] != form["version"] { throw WorldError.invalidBody("version: the form changed") }
        for field in fields where field["required"]?.boolValue == true && (field["response"] ?? .null) == .null {
            throw WorldError.invalidBody("form_fields: a required field has no response")
        }
        var request = joinRequest(guildID, userID: userID)
        if request == nil || request?.status == .rejected { request = try await startJoinRequest(guildID, by: userID) }
        guard var request, request.isOpen else { throw WorldError.missingAccess }
        request.status = .submitted
        request.formResponses = fields
        servers.joinRequests[request.id] = request
        await emitJoinRequest("GUILD_JOIN_REQUEST_UPDATE", request)
        return request
    }

    /// `DELETE /guilds/{id}/requests/@me`: withdraws the application.
    func withdrawJoinRequest(_ guildID: Snowflake, by userID: Snowflake) async throws {
        guard let request = joinRequest(guildID, userID: userID) else { throw WorldError.notFound }
        servers.joinRequests[request.id] = nil
        await emit("GUILD_JOIN_REQUEST_DELETE", .object(JSONObject([
            ("guild_id", guildID.json), ("id", request.id.json), ("user_id", userID.json),
        ])), to: .users([userID]))
    }

    /// A moderator's decision. Approval makes the applicant a member.
    func reviewJoinRequest(_ guildID: Snowflake, applicant: Snowflake, approve: Bool, by moderator: Snowflake, reason: String?) async throws {
        guard var request = joinRequest(guildID, userID: applicant), request.status == .submitted else {
            throw WorldError.notFound
        }
        request.status = approve ? .approved : .rejected
        request.reviewedAt = clock.now
        request.actionedBy = moderator
        request.actionID = nextID()
        request.rejectionReason = approve ? nil : reason
        servers.joinRequests[request.id] = request
        await emitJoinRequest("GUILD_JOIN_REQUEST_UPDATE", request, detailed: true)
        if approve { try await addMember(applicant, to: guildID) }
    }

    /// `POST /guilds/{id}/requests/{id}/ack`: the applicant has seen the decision.
    func acknowledgeJoinRequest(_ id: Snowflake, in guildID: Snowflake, by userID: Snowflake) async throws {
        guard var request = servers.joinRequests[id], request.guildID == guildID, request.userID == userID, !request.isOpen else {
            throw WorldError.notFound
        }
        request.lastSeen = clock.now
        servers.joinRequests[id] = request
        await emitJoinRequest("GUILD_JOIN_REQUEST_UPDATE", request)
    }

    private func emitJoinRequest(_ name: String, _ request: JoinRequest, detailed: Bool = false) async {
        await emit(name, .object(JSONObject([
            ("guild_id", request.guildID.json),
            ("request", renderJoinRequest(request, includeUser: detailed, includeAnswers: detailed)),
            ("status", .string(request.status.rawValue)),
        ])), to: .users([request.userID]))
    }

    func renderJoinRequest(_ request: JoinRequest, includeUser: Bool, includeAnswers: Bool) -> JSON {
        var object = JSONObject([
            ("created_at", World.timestamp(request.id.date)), ("reviewed_at", World.optionalTimestamp(request.reviewedAt)),
            ("join_request_id", request.id.json), ("id", request.id.json),
            ("rejection_reason", .optional(request.rejectionReason)), ("application_status", .string(request.status.rawValue)),
            ("last_seen", World.optionalTimestamp(request.lastSeen ?? request.reviewedAt)), ("guild_id", request.guildID.json),
            ("user_id", request.userID.json), ("interview_channel_id", .null),
        ])
        if includeUser { object["user"] = renderUser(request.userID) }
        if includeAnswers { object["form_responses"] = .array(request.formResponses) }
        if let moderator = request.actionedBy {
            object["actioned_by_user"] = renderUser(moderator)
            object["actioned_at"] = request.actionID?.json ?? .null
        }
        return .object(object)
    }

    /// `GET /join-requests/{id}`: only the applicant may read their application.
    func joinRequestDetails(_ id: Snowflake, viewer: Snowflake) throws -> JSON {
        guard let request = servers.joinRequests[id], request.userID == viewer else {
            throw WorldError.notFound
        }
        return renderJoinRequest(request, includeUser: true, includeAnswers: true)
    }

    /// Guilds the user has an open application to.
    func joinRequestGuilds(_ userID: Snowflake) -> JSON {
        let ids = servers.joinRequests.values.filter { $0.userID == userID && $0.isOpen }
            .sorted { $0.id < $1.id }.map(\.guildID)
        return .array(ids.compactMap { guilds[$0] }.map(renderGuildPreview))
    }

    /// READY's `guild_join_requests`: every application the user has made.
    func readyJoinRequests(_ userID: Snowflake) -> [JSON] {
        servers.joinRequests.values.filter { $0.userID == userID }.sorted { $0.id < $1.id }
            .map { renderJoinRequest($0, includeUser: false, includeAnswers: false) }
    }

    func renderGuildPreview(_ guild: Guild) -> JSON {
        .object(JSONObject([
            ("id", guild.id.json), ("name", .string(guild.name)), ("icon", .optional(guild.icon)),
            ("description", .optional(guild.description)), ("home_header", .null), ("splash", .optional(guild.splash)),
            ("discovery_splash", .null), ("features", .array(guild.features.map(JSON.string))),
            ("approximate_member_count", .int(guild.memberCount)), ("approximate_presence_count", .int(onlineCount(guild))),
            ("emojis", .array(guild.emojis.map(renderEmoji))), ("verification_level", .int(guild.verificationLevel)),
        ]))
    }

    /// `GET /guilds/{id}/member-verification`.
    func memberVerification(_ guildID: Snowflake, withGuild: Bool) throws -> JSON {
        let guild = try guild(guildID)
        guard var form = servers.verificationForms[guildID] else {
            throw WorldError.unknown("Server Member Verification Form", code: 10068)
        }
        if withGuild {
            form["guild"] = renderGuildPreview(guild)
            form["profile"] = renderGuildProfile(guild)
        }
        return .object(form)
    }

    // MARK: Server guide and onboarding

    func serverGuide(_ guildID: Snowflake, viewer: Snowflake) throws -> JSON {
        _ = try memberGuild(guildID, of: viewer)
        guard let guide = servers.guides[guildID] else { throw WorldError.notFound }
        return .object(JSONObject([("guild_id", guildID.json)] + guide.map { ($0.key, $0.value) }))
    }

    func newMemberActions(_ guildID: Snowflake, viewer: Snowflake) throws -> JSON {
        _ = try memberGuild(guildID, of: viewer)
        let done = servers.completedActions[guildID]?[viewer] ?? []
        return .object(JSONObject([
            ("guild_id", guildID.json), ("user_id", viewer.json),
            ("channel_actions", .object(JSONObject(done.map { ($0.description, .object(JSONObject([("completed", true)]))) }))),
        ]))
    }

    /// `POST /guilds/{id}/new-member-action/{channel}`: the channel must be one of the guide's actions.
    func completeNewMemberAction(_ guildID: Snowflake, channelID: Snowflake, viewer: Snowflake) throws -> JSON {
        _ = try newMemberActions(guildID, viewer: viewer)
        let actions = servers.guides[guildID]?["new_member_actions"]?.arrayValue ?? []
        guard actions.contains(where: { $0["channel_id"]?.stringValue == channelID.description }) else {
            throw WorldError.invalidBody("channel_id: not a new member action")
        }
        guard servers.completedActions[guildID]?[viewer]?.contains(channelID) != true else {
            throw WorldError(status: 400, code: 40075, message: "New member action already completed")
        }
        servers.completedActions[guildID, default: [:]][viewer, default: []].append(channelID)
        return try newMemberActions(guildID, viewer: viewer)
    }

    func onboarding(_ guildID: Snowflake, viewer: Snowflake) throws -> JSON {
        _ = try memberGuild(guildID, of: viewer)
        let config = servers.onboarding[guildID] ?? JSONObject([
            ("prompts", []), ("default_channel_ids", []), ("enabled", false), ("mode", 0),
        ])
        var object = JSONObject([("guild_id", guildID.json)] + config.map { ($0.key, $0.value) })
        let answers = servers.onboardingResponses[guildID]?[viewer]
        object["below_requirements"] = false
        object["responses"] = answers?["onboarding_responses"] ?? []
        object["onboarding_prompts_seen"] = answers?["onboarding_prompts_seen"] ?? .object(JSONObject())
        object["onboarding_responses_seen"] = answers?["onboarding_responses_seen"] ?? .object(JSONObject())
        return .object(object)
    }

    /// `POST` (first answers) or `PUT /guilds/{id}/onboarding-responses`: stores the answers and swaps the roles
    /// they grant. Finishing onboarding marks the member and posts their welcome, as captured.
    func saveOnboardingResponses(_ guildID: Snowflake, userID: Snowflake, body: JSON, initial: Bool) async throws -> JSON {
        guard var member = try guild(guildID).members[userID] else { throw WorldError.missingAccess }
        let options = (servers.onboarding[guildID]?["prompts"]?.arrayValue ?? []).flatMap { $0["options"]?.arrayValue ?? [] }
        func roles(_ answers: [String]) -> Set<Snowflake> {
            Set(options.filter { answers.contains($0["id"]?.stringValue ?? "") }
                .flatMap { ($0["role_ids"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Snowflake.init) } })
        }
        let answers = (body["onboarding_responses"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard answers.allSatisfy({ answer in options.contains { $0["id"]?.stringValue == answer } }) else {
            throw WorldError.invalidBody("onboarding_responses: Unknown option")
        }
        let previous = (servers.onboardingResponses[guildID]?[userID]?["onboarding_responses"]?.arrayValue ?? []).compactMap(\.stringValue)
        let granted = roles(answers), revoked = roles(previous).subtracting(granted)
        let stored = JSONObject([
            ("onboarding_responses", .array(answers.map(JSON.string))),
            ("onboarding_prompts_seen", body["onboarding_prompts_seen"] ?? .object(JSONObject())),
            ("onboarding_responses_seen", body["onboarding_responses_seen"] ?? .object(JSONObject())),
        ])
        servers.onboardingResponses[guildID, default: [:]][userID] = stored
        let newRoles = member.roles.filter { !revoked.contains($0) } + granted.subtracting(member.roles).sorted()
        let completes = initial && member.flags & Member.completedOnboarding == 0
        if newRoles != member.roles || completes {
            member.roles = newRoles
            if completes { member.flags |= Member.completedOnboarding | Member.startedOnboarding }
            guilds[guildID]?.members[userID] = member
            await emitMemberUpdate(member, in: guildID)
        }
        if completes { try await postJoinMessage(userID, in: try guild(guildID)) }
        return .object(JSONObject([("guild_id", guildID.json), ("user_id", userID.json)] + stored.map { ($0.key, $0.value) }))
    }
}
