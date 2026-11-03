import Foundation
import SakuraCordModels

/// Discord Activities: the shelf, launching through the application's
/// entry-point command, leaving, proxy tickets and the OAuth requests an
/// Activity makes through its host. See docs/protocol/ACTIVITIES.md.
public extension DiscordRESTProvider {
    func embeddedActivityShelf(guildID: GuildID?) async throws -> [EmbeddedActivityApplication] {
        let shelf: ActivityShelfDTO = try await request(
            "/activities/shelf",
            query: guildID.map { [URLQueryItem(name: "guild_id", value: $0.description)] } ?? []
        )
        return shelf.domain()
    }

    /// The Gateway session that owns this account's Activity participation.
    func embeddedActivitySessionID() async throws -> String {
        try await interactionSessionID()
    }

    /// Starts or joins the application's Activity in a voice or private channel
    /// by running its entry-point command, as the official client does. The
    /// resulting instance arrives as `EMBEDDED_ACTIVITY_UPDATE_V2`.
    func launchEmbeddedActivity(
        _ applicationID: ApplicationID,
        channelID: ChannelID,
        guildID: GuildID?
    ) async throws {
        let sessionID = try await interactionSessionID()
        guard let command = try await entryPointCommand(for: applicationID, channelID: channelID, guildID: guildID) else {
            // Applications without an entry point keep the older channel launch.
            var body: [String: JSONValue] = ["session_id": .string(sessionID)]
            if let guildID { body["guild_id"] = .string(guildID.description) }
            try Task.checkCancellation()
            let (data, response) = try await perform(
                "/activities/\(channelID)/\(applicationID)", method: "POST", query: [], body: body,
                maximumAttempts: 1
            )
            guard (200 ..< 300).contains(response.statusCode) else { throw unexplainedFailure(data, response) }
            return
        }
        let invocation = ApplicationCommandInvocation(command: command, channelID: channelID, guildID: guildID, values: [])
        var payload = try ApplicationCommandPayloadBuilder.execution(invocation)
        payload.data["attachments"] = .array([])
        var body: [String: JSONValue] = [
            "type": .number(2),
            "application_id": .string(applicationID.description),
            "channel_id": .string(channelID.description),
            "session_id": .string(sessionID),
            "data": .object(payload.data),
            "nonce": .string(invocation.nonce),
            "analytics_location": .string("app_launcher"),
        ]
        if let guildID {
            body["guild_id"] = .string(guildID.description)
            body["source"] = .string("VOICE")
        }
        // A launch superseded while its command was looked up stops here.
        try Task.checkCancellation()
        let (data, response) = try await perform("/interactions", method: "POST", query: [], body: body)
        guard response.statusCode == 204 else { throw interactionTransportError(data, response) }
    }

    func leaveEmbeddedActivity(_ instance: EmbeddedActivityInstance) async throws {
        let sessionID = try await interactionSessionID()
        let path = "/applications/\(instance.applicationID)/activities/\(instance.location.id)"
            + "/instances/\(instance.instanceID)/leave"
        let (data, response) = try await perform(
            path, method: "POST", query: [], body: ["session_id": .string(sessionID)], maximumAttempts: 1
        )
        guard (200 ..< 300).contains(response.statusCode) else { throw unexplainedFailure(data, response) }
    }

    /// A short-lived ticket that authenticates the Activity to Discord's proxy.
    func embeddedActivityProxyTicket(_ applicationID: ApplicationID, channelID: ChannelID) async throws -> String {
        let ticket: ProxyTicketDTO = try await request(
            "/applications/\(applicationID)/proxy-tickets",
            method: "POST",
            body: ["use_stateless_ticket": .bool(true), "channel_id": .string(channelID.description)]
        )
        return ticket.ticket
    }

    func embeddedActivityAuthorizationPreview(
        _ authorization: EmbeddedActivityAuthorizationRequest
    ) async throws -> EmbeddedActivityAuthorizationPreview {
        let preview: ActivityAuthorizationPreviewDTO = try await request(
            "/oauth2/authorize",
            query: Self.authorizationQuery(authorization) + [URLQueryItem(name: "integration_type", value: "1")]
        )
        guard preview.application.id == authorization.applicationID.description else {
            throw OAuth2AuthorizationError.unexpectedResponse
        }
        return EmbeddedActivityAuthorizationPreview(
            applicationName: preview.application.name,
            isAuthorized: preview.authorized == true
        )
    }

    /// Grants the Activity an authorization code. The POST is a single attempt;
    /// the redirect it names is parsed, never followed.
    func authorizeEmbeddedActivity(_ authorization: EmbeddedActivityAuthorizationRequest) async throws -> String {
        let location = authorization.location
        let (data, response) = try await perform(
            "/oauth2/authorize",
            method: "POST",
            query: Self.authorizationQuery(authorization),
            body: [
                "authorize": .bool(true),
                "integration_type": .number(1),
                "location_context": .object([
                    // The official client uses the 10000 placeholder outside a guild.
                    "guild_id": .string(location.guildID?.description ?? "10000"),
                    "channel_id": .string(location.channelID.description),
                    "channel_type": .number(location.guildID == nil ? 1 : 2),
                ]),
            ],
            maximumAttempts: 1
        )
        let authorized: ActivityAuthorizationLocationDTO = try decodedResponse(
            data, response, method: "POST", path: "/oauth2/authorize"
        )
        let items = URLComponents(string: authorized.location)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw OAuth2AuthorizationError.denied(items.first { $0.name == "error_description" }?.value ?? error)
        }
        guard items.first(where: { $0.name == "state" })?.value == authorization.state,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw OAuth2AuthorizationError.unexpectedResponse }
        return code
    }

    /// Validates an Activity's OAuth access token for its own application and
    /// this account, returning the SDK's `AUTHENTICATE` payload.
    func authenticateEmbeddedActivity(
        _ applicationID: ApplicationID,
        accessToken: String
    ) async throws -> JSONValue {
        let (data, response) = try await perform(
            "/oauth2/@me", method: "GET", query: [], body: nil,
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
        guard (200 ..< 300).contains(response.statusCode),
              case .object(var authorization)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let application)? = authorization["application"],
              application["id"] == .string(applicationID.description)
        else { throw OAuth2AuthorizationError.invalidRequest }
        if case .object(let user)? = authorization["user"], user["id"] != currentUser.map({ .string($0.id.description) }) {
            throw OAuth2AuthorizationError.invalidRequest
        }
        authorization["access_token"] = .string(accessToken)
        return .object(authorization)
    }

    private static func authorizationQuery(_ authorization: EmbeddedActivityAuthorizationRequest) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "client_id", value: authorization.applicationID.description),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: authorization.scopes.joined(separator: " ")),
        ]
        if let state = authorization.state { query.append(URLQueryItem(name: "state", value: state)) }
        if let challenge = authorization.codeChallenge {
            query.append(URLQueryItem(name: "code_challenge", value: challenge))
            query.append(URLQueryItem(name: "code_challenge_method", value: authorization.codeChallengeMethod ?? "S256"))
        }
        return query
    }

    /// The application's entry-point command, from the indexes the official
    /// client already holds, then the application's own index.
    private func entryPointCommand(
        for applicationID: ApplicationID,
        channelID: ChannelID,
        guildID: GuildID?
    ) async throws -> ApplicationCommand? {
        let targets: [ApplicationCommandIndexTarget] = [
            .user, guildID.map(ApplicationCommandIndexTarget.guild) ?? .channel(channelID),
            .application(applicationID.description),
        ]
        for target in targets {
            let catalog: ApplicationCommandCatalog
            do {
                catalog = try await applicationCommandCatalog(for: target)
            } catch {
                // The application's own index decides between its entry point
                // and the older launch; without it either would be a guess.
                if case .application = target { throw error }
                continue
            }
            if let command = catalog.commands.first(where: {
                $0.type == .primaryEntryPoint && $0.applicationID == applicationID.description
            }) {
                return command
            }
        }
        return nil
    }
}

private struct ProxyTicketDTO: Decodable {
    let ticket: String
}

private struct ActivityAuthorizationPreviewDTO: Decodable {
    struct Application: Decodable {
        let id: String
        let name: String
    }

    let application: Application
    let authorized: Bool?
}

private struct ActivityAuthorizationLocationDTO: Decodable {
    let location: String
}

private struct ActivityShelfDTO: Decodable {
    struct Entry: Decodable {
        let applicationID: String
        let shelfRank: Int?

        enum CodingKeys: String, CodingKey {
            case applicationID = "application_id"
            case shelfRank = "shelf_rank"
        }
    }

    struct Application: Decodable {
        let id: String
        let name: String
        let description: String?
        let icon: String?
        let coverImage: String?
        let tags: [String]?
        let maxParticipants: Int?

        enum CodingKeys: String, CodingKey {
            case id, name, description, icon, tags
            case coverImage = "cover_image"
            case maxParticipants = "max_participants"
        }
    }

    struct Asset: Decodable {
        let id: String
        let name: String
    }

    let activities: LossyList<Entry>
    let applications: LossyList<Application>
    let assets: [String: LossyList<Asset>]?

    func domain() -> [EmbeddedActivityApplication] {
        let applications = Dictionary(
            self.applications.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return activities.elements
            .sorted { ($0.shelfRank ?? .max) < ($1.shelfRank ?? .max) }
            .compactMap { entry in
                guard let application = applications[entry.applicationID],
                      let id = ApplicationID(application.id) else { return nil }
                let cover = assets?[application.id]?.elements.first { $0.name == "embedded_cover" }
                    .flatMap { URL(string: "https://cdn.discordapp.com/app-assets/\(id)/\($0.id).png?size=512") }
                    ?? application.coverImage.flatMap { URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\($0).png?size=512") }
                return EmbeddedActivityApplication(
                    id: id,
                    name: application.name,
                    description: application.description ?? "",
                    iconURL: application.icon.flatMap { URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\($0).png?size=128") },
                    coverURL: cover,
                    tags: application.tags ?? [],
                    maximumParticipants: application.maxParticipants.flatMap { $0 > 0 ? $0 : nil }
                )
            }
    }
}
