import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func serverInvite(_ reference: ServerInviteReference) async throws -> ServerInvite {
        let (data, response) = try await perform(
            "/invites/\(reference.code)", method: "GET",
            query: ["with_counts", "with_expiration", "with_permissions"].map {
                URLQueryItem(name: $0, value: "true")
            }, body: nil
        )
        try checkInviteResponse(data, response)
        return try Self.inviteDecoder().decode(ServerInviteDTO.self, from: data).domain(reference: reference)
    }

    func acceptServerInvite(_ reference: ServerInviteReference, messageID: MessageID?, captchaHandler: DiscordCaptchaHandler?) async throws -> ServerInviteAcceptance {
        // Refresh immediately before the write: previews can outlive a revoked invite or changed onboarding settings.
        let invite = try await serverInvite(reference)
        if cachedGuilds[invite.guildID] != nil {
            return ServerInviteAcceptance(invite: invite)
        }
        if let reason = invite.unsupportedJoinReason { throw ServerInviteError.unsupported(reason) }
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ServerInviteError.failed("Wait for SakuraCord to reconnect before joining this server.")
        }
        var context: [String: String] = [
            "location": messageID == nil ? "Join Guild" : "Invite Button Embed",
            "location_guild_id": invite.guildID.description
        ]
        if let channelID = invite.channelID { context["location_channel_id"] = channelID.description }
        // The channel type is a JSON number in the observed first-party context.
        var contextObject = context.mapValues { $0 as Any }
        if let channelType = invite.channelType { contextObject["location_channel_type"] = channelType }
        let contextData = try JSONSerialization.data(withJSONObject: contextObject, options: [.sortedKeys])
        var body: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let messageID { body["invite_instance_id"] = .string("\(messageID):\(reference.code)") }
        let (data, response) = try await joinRequest(
            "/invites/\(reference.code)", method: "POST", query: [], body: body,
            context: contextData.base64EncodedString(), sessionID: sessionID, captchaHandler: captchaHandler
        )
        try checkInviteResponse(data, response)
        struct Acceptance: Decodable {
            var showVerificationForm: Bool?
            var guild: GuildReference?
            struct GuildReference: Decodable { var id: String }
        }
        let accepted = try Self.inviteDecoder().decode(Acceptance.self, from: data)
        guard accepted.guild?.id == invite.guildID.description else {
            throw ServerInviteError.failed("Discord accepted the request but did not confirm the expected server. Check your server list before trying again.")
        }
        // The accept response lacks profile/count data. Keep the preview and let Gateway own the guild catalogue.
        return ServerInviteAcceptance(invite: invite, requiresVerification: accepted.showVerificationForm == true)
    }

    /// Full-membership join from a discoverable server's profile; see docs/protocol/GUILDS.md, Server tag cards.
    /// Returns whether Discord still requires verification.
    func joinDiscoverableGuild(_ guildID: GuildID, captchaHandler: DiscordCaptchaHandler?) async throws -> Bool {
        if cachedGuilds[guildID] != nil { return false }
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ServerInviteError.failed("Wait for SakuraCord to reconnect before joining this server.")
        }
        let (data, response) = try await joinRequest(
            "/guilds/\(guildID)/members/@me", method: "PUT", query: [URLQueryItem(name: "lurker", value: "false")],
            body: [:], context: Data("{}".utf8).base64EncodedString(), sessionID: sessionID, captchaHandler: captchaHandler
        )
        try checkInviteResponse(data, response)
        struct Joined: Decodable {
            var id: String?
            var showVerificationForm: Bool?
        }
        let joined = try Self.inviteDecoder().decode(Joined.self, from: data)
        guard joined.id == guildID.description else {
            throw ServerInviteError.failed("Discord accepted the request but did not confirm the expected server. Check your server list before trying again.")
        }
        return joined.showVerificationForm == true
    }

    private func joinRequest(
        _ path: String, method: String, query: [URLQueryItem], body: [String: JSONValue], context: String,
        sessionID: String, captchaHandler: DiscordCaptchaHandler?
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            // Keep the original account, request context and Gateway session. Never replay a stale join.
            return try await performChallengeable(
                path, method: method, query: query, body: body, headers: ["X-Context-Properties": context],
                captchaHandler: captchaHandler,
                replayIsCurrent: { [weak self] in await self?.gatewaySession?.snapshot().sessionID == sessionID }
            )
        } catch let failure as CaptchaReplayFailure {
            switch failure {
            case .handlerUnavailable: throw ServerInviteError.failed("Discord requires a CAPTCHA to join this server. Join it in Discord.")
            case .emptySolution: throw ServerInviteError.failed("CAPTCHA verification did not return a solution. Try joining again.")
            case .rejected: throw ServerInviteError.failed("Discord did not accept the CAPTCHA. Try joining again to get a new challenge.")
            }
        }
    }

    func createServerInvite(in channelID: ChannelID, guildID: GuildID, settings: ServerInviteSettings) async throws -> CreatedServerInvite {
        guard settings.maxAge != .never || cachedGuilds[guildID]?.features.contains("COMMUNITY") == true else {
            throw ServerInviteError.failed("Non-expiring invites require a Community server.")
        }
        // Mirrors the official settings-page submission. The modal's on-open
        // `validate` reuse is omitted because SakuraCord creates only on request.
        let context = try JSONSerialization.data(withJSONObject: ["location": "Guild Context Menu"])
        let (data, response) = try await perform(
            "/channels/\(channelID)/invites", method: "POST", query: [],
            body: [
                "max_age": .number(Double(settings.maxAge.rawValue)),
                "max_uses": .number(Double(settings.maxUses.rawValue)),
                "target_type": .null, "temporary": .bool(false), "flags": .number(0)
            ],
            headers: ["X-Context-Properties": context.base64EncodedString()], maximumAttempts: 1
        )
        if !(200 ..< 300).contains(response.statusCode) {
            switch Self.discordErrorCode(from: data) {
            case 50013, 50001: throw ServerInviteError.failed("You don’t have permission to create invites for this server.")
            case 30016: throw ServerInviteError.failed("This server has reached Discord’s invite limit. Ask a moderator to remove unused invites.")
            default: break
            }
        }
        try checkInviteResponse(data, response)
        struct Created: Decodable {
            var code: String
            var guildId: String?
            var channel: Channel?
            var createdAt: String?
            var expiresAt: String?
            var maxAge: Int?
            var maxUses: Int?
            struct Channel: Decodable { var id: String }
        }
        let created = try Self.inviteDecoder().decode(Created.self, from: data)
        guard let reference = ServerInviteReference(created.code),
              created.guildId.map({ $0 == guildID.description }) ?? true else {
            throw ServerInviteError.failed("Discord returned an unexpected invite. Try again.")
        }
        return CreatedServerInvite(
            reference: reference, guildID: guildID,
            channelID: created.channel.flatMap { ChannelID($0.id) } ?? channelID,
            createdAt: created.createdAt.flatMap(Self.inviteDate) ?? .now,
            expiresAt: created.expiresAt.flatMap(Self.inviteDate),
            maxAge: created.maxAge ?? settings.maxAge.rawValue,
            maxUses: created.maxUses ?? settings.maxUses.rawValue
        )
    }

    fileprivate static func inviteDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value) ?? ISO8601DateFormatter.fractionalSeconds.date(from: value)
    }

    func leaveGuild(_ guildID: GuildID) async throws {
        guard let guild = cachedGuilds[guildID], !guild.isUnavailable else {
            throw ServerInviteError.failed("This server is unavailable. Wait for SakuraCord to reconnect.")
        }
        guard guild.isOwnedByCurrentUser == false else {
            throw ServerInviteError.failed("The server owner must transfer ownership in Discord before leaving.")
        }
        let (data, response) = try await perform(
            "/users/@me/guilds/\(guildID)", method: "DELETE", query: [],
            body: ["lurking": .bool(false)], maximumAttempts: 1
        )
        try checkInviteResponse(data, response)
        // Do not remove local membership optimistically. GUILD_DELETE and READY remain authoritative.
    }

    private static func inviteDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func checkInviteResponse(_ data: Data, _ response: HTTPURLResponse) throws {
        guard !(200 ..< 300).contains(response.statusCode) else { return }
        switch Self.discordErrorCode(from: data) {
        case 10006, 50270: throw ServerInviteError.unavailable
        case 40007: throw ServerInviteError.banned
        case 30001: throw ServerInviteError.serverLimit
        case 50013: throw ServerInviteError.failed("Discord did not permit this server action.")
        default:
            if response.statusCode == 429 {
                throw ServerInviteError.failed("Discord is limiting server actions. Wait before trying again.")
            }
            throw apiDiagnostics.coalescing(ChatProviderError.transport(
                status: response.statusCode, requestID: response.value(forHTTPHeaderField: "x-request-id")
            ), with: response)
        }
    }
}

private struct ServerInviteDTO: Decodable {
    var type: Int?
    var guild: InviteGuild?
    var channel: InviteChannel?
    var profile: Profile?
    var inviter: Inviter?
    var expiresAt: String?
    var approximateMemberCount: Int?
    var approximatePresenceCount: Int?
    var flags: Int?
    var targetType: Int?

    struct Inviter: Decodable {
        var id: String
        var username: String
        var globalName: String?
        var avatar: String?
        var discriminator: String?

        func domain() -> User? {
            guard let userID = UserID(id) else { return nil }
            let url = avatar.flatMap { URL(string: "https://cdn.discordapp.com/avatars/\(id)/\($0).webp?size=32") }
                ?? DiscordProfileImageAssets.defaultAvatarURL(userID: id, discriminator: discriminator)
            return User(id: userID, username: username, discriminator: discriminator ?? "0",
                        displayName: globalName ?? username, avatarURL: url)
        }
    }
    struct InviteGuild: Decodable {
        var id: String
        var name: String
        var icon: String?
        var description: String?
        var features: Set<String>?
    }
    struct InviteChannel: Decodable { var id: String; var type: Int? }
    struct Profile: Decodable {
        var name: String?
        var iconHash: String?
        var description: String?
        var brandColorPrimary: String?
        var features: Set<String>?
        var traits: [Trait]?
        struct Trait: Decodable {
            var label: String
            var emojiId: String?
            var emojiName: String?
            var emojiAnimated: Bool?
            var position: Int?
        }
    }

    func domain(reference: ServerInviteReference) throws -> ServerInvite {
        guard (type ?? 0) == 0, let guild, let guildID = GuildID(guild.id) else {
            throw ServerInviteError.unsupported("This invitation is not a server invite. Open it in Discord to continue.")
        }
        let features = (guild.features ?? []).union(profile?.features ?? [])
        let icon = profile?.iconHash ?? guild.icon
        return ServerInvite(
            reference: reference, guildID: guildID,
            channelID: channel.flatMap { ChannelID($0.id) }, channelType: channel?.type,
            name: profile?.name ?? guild.name,
            iconURL: icon.flatMap { URL(string: "https://cdn.discordapp.com/icons/\(guildID)/\($0).webp?size=128") },
            inviter: inviter?.domain(),
            brandColor: profile?.brandColorPrimary.flatMap { UInt32($0.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) },
            description: profile?.description ?? guild.description,
            traits: (profile?.traits ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }.map {
                .init(label: $0.label, emoji: $0.emojiName, emojiURL: $0.emojiId.flatMap {
                    URL(string: "https://cdn.discordapp.com/emojis/\($0).webp?size=32")
                })
            }, memberCount: approximateMemberCount, onlineCount: approximatePresenceCount,
            expiresAt: expiresAt.flatMap(DiscordRESTProvider.inviteDate),
            features: features, requiresSpecialAcceptance: (flags ?? 0) & 1 != 0 || targetType != nil
        )
    }
}

private extension ISO8601DateFormatter {
    static var fractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
