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
        let (data, response) = try await acceptInviteRequest(
            reference, body: body, context: contextData.base64EncodedString(),
            sessionID: sessionID, captchaHandler: captchaHandler
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

    private func acceptInviteRequest(
        _ reference: ServerInviteReference, body: [String: JSONValue], context: String,
        sessionID: String, captchaHandler: DiscordCaptchaHandler?
    ) async throws -> (Data, HTTPURLResponse) {
        let path = "/invites/\(reference.code)"
        var headers = ["X-Context-Properties": context]
        let original = try await perform(path, method: "POST", query: [], body: body, headers: headers, maximumAttempts: 1)
        guard let challenge = DiscordCaptchaChallenge.inviteChallenge(
            data: original.0, status: original.1.statusCode, method: "POST", path: path
        ) else { return original }
        guard let captchaHandler else {
            throw ServerInviteError.failed("Discord requires a CAPTCHA to join this server. Complete the invite in Discord.")
        }
        try Task.checkCancellation()
        let token = try await captchaHandler(challenge)
        try Task.checkCancellation()
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerInviteError.failed("CAPTCHA verification did not return a solution. Try joining again.")
        }
        // Keep the original account, invite, message context and Gateway session. Never replay a stale join.
        let currentSessionID = await gatewaySession?.snapshot().sessionID
        guard !requestSafetyCircuitIsOpen, currentSessionID == sessionID else { throw CancellationError() }
        headers["X-Captcha-Key"] = token
        headers["X-Captcha-Rqtoken"] = challenge.rqtoken
        headers["X-Captcha-Session-Id"] = challenge.sessionID
        let completed = try await perform(path, method: "POST", query: [], body: body, headers: headers, maximumAttempts: 1)
        if DiscordCaptchaChallenge.inviteChallenge(data: completed.0, status: completed.1.statusCode, method: "POST", path: path) != nil {
            throw ServerInviteError.failed("Discord did not accept the CAPTCHA. Try joining again to get a new challenge.")
        }
        return completed
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
            let defaultIndex = discriminator.flatMap(Int.init).flatMap { $0 == 0 ? nil : $0 % 5 }
                ?? Int((userID.rawValue >> 22) % 6)
            let url = avatar.flatMap { URL(string: "https://cdn.discordapp.com/avatars/\(id)/\($0).webp?size=32") }
                ?? URL(string: "https://cdn.discordapp.com/embed/avatars/\(defaultIndex).png")
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
            expiresAt: expiresAt.flatMap { ISO8601DateFormatter().date(from: $0)
                ?? ISO8601DateFormatter.fractionalSeconds.date(from: $0) },
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
