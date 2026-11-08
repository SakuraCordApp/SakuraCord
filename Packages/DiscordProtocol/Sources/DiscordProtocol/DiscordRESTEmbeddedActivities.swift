import Foundation
import SakuraCordModels

/// Discord Activities: the shelf, launching through the application's
/// entry-point command, leaving, proxy tickets and the OAuth requests an
/// Activity makes through its host. See docs/protocol/ACTIVITIES.md.
public extension DiscordRESTProvider {
    func embeddedActivityShelf(guildID: GuildID?) async throws -> [EmbeddedActivityApplication] {
        // Recents are ranked by the same application frecency the official shelf reads.
        async let settings = try? frecencySettingsProto()
        let shelf: ActivityShelfDTO = try await request(
            "/activities/shelf",
            query: guildID.map { [URLQueryItem(name: "guild_id", value: $0.description)] } ?? []
        )
        let frecency = await settings.flatMap {
            DiscordSettingsProto.frecencyHistory(from: $0, field: DiscordSettingsProto.applicationFrecencyField)
        }
        return shelf.domain(frecency: frecency?.entries ?? [])
    }

    /// Apps with commands in the person's and the server's command indexes,
    /// which the official launcher lists as Recents. A missing index lists nothing.
    func installedEmbeddedActivities(guildID: GuildID?) async -> Set<ApplicationID> {
        async let user = installedApplicationIDs(in: .user)
        async let guild: Set<ApplicationID> = if let guildID { await installedApplicationIDs(in: .guild(guildID)) } else { [] }
        return await user.union(guild)
    }

    private func installedApplicationIDs(in target: ApplicationCommandIndexTarget) async -> Set<ApplicationID> {
        guard let catalog = try? await applicationCommandCatalog(for: target) else { return [] }
        return Set(catalog.commands.filter { [.chatInput, .primaryEntryPoint].contains($0.type) }
            .compactMap { ApplicationID($0.applicationID) })
    }

    /// Counts a launch in the application frecency the shelf's Recents read,
    /// as the official client does when an Activity opens.
    func recordEmbeddedActivityLaunch(_ applicationID: ApplicationID) async throws {
        let fetched = try await frecencySettingsProto()
        // Read and update the cache without suspending, like sticker uses, so
        // a launch overlapping an earlier save still counts.
        let current = cachedFrecencySettingsProto ?? fetched
        var history = DiscordSettingsProto.frecencyHistory(from: current, field: DiscordSettingsProto.applicationFrecencyField)
            ?? DiscordFrecencyHistory()
        let key = applicationID.description
        let now = UInt64(Date.now.timeIntervalSince1970 * 1000)
        if let index = history.entries.firstIndex(where: { $0.key == key }) {
            history.entries[index].totalUses += 1
            history.entries[index].recentUses = Array((history.entries[index].recentUses + [now]).suffix(10))
            history.entries[index].frecency = -1
        } else {
            history.entries.append(DiscordFrecencyEntry(key: key, totalUses: 1, recentUses: [now]))
        }
        let patch = DiscordSettingsProto.frecencyPatch(
            history, field: DiscordSettingsProto.applicationFrecencyField, limit: 100, preserving: current
        )
        cachedFrecencySettingsProto = DiscordSettingsProto.mergingPartialFrecencySettings(patch, into: current)
        _ = try await persistFrecencySettingsPatch(patch)
    }

    /// The Gateway session that owns this account's Activity participation.
    func embeddedActivitySessionID() async throws -> String {
        try await interactionSessionID()
    }

    /// Starts the application's Activity in a channel by running its
    /// entry-point command, or joins the instance running there with the
    /// channel join, as the official client does. The resulting instance
    /// arrives as `EMBEDDED_ACTIVITY_UPDATE_V2`.
    func launchEmbeddedActivity(
        _ applicationID: ApplicationID, in channel: Channel, sessionID: String, joining: Bool, fromCall: Bool,
        shelfSection: String?
    ) async throws {
        let channelID = channel.id, guildID = channel.guildID
        let command = joining ? nil : try await entryPointCommand(for: applicationID, channelID: channelID, guildID: guildID)?.command
        guard let command else {
            // Applications without an entry point start with the channel join too.
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
            // Where the launcher was opened: a call's controls or the composer.
            "source": .string(fromCall ? "VOICE" : "TEXT"),
        ]
        if let guildID { body["guild_id"] = .string(guildID.description) }
        if let shelfSection { body["section_name"] = .string(shelfSection) }
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
    /// A ticket for the Activity in a channel, or, without one, for the main
    /// surface a contextless Activity opens on.
    func embeddedActivityProxyTicket(_ applicationID: ApplicationID, channelID: ChannelID?) async throws -> String {
        var body: [String: JSONValue] = ["use_stateless_ticket": .bool(true)]
        if let channelID { body["channel_id"] = .string(channelID.description) } else { body["surface"] = .number(0) }
        let ticket: ProxyTicketDTO = try await request(
            "/applications/\(applicationID)/proxy-tickets", method: "POST", body: body
        )
        return ticket.ticket
    }

    func embeddedActivityAuthorizationPreview(
        _ authorization: EmbeddedActivityAuthorizationRequest
    ) async throws -> EmbeddedActivityAuthorizationPreview {
        // The official client reads the developer's disclosures first.
        let disclosures: ActivityDisclosuresDTO = try await request("/applications/\(authorization.applicationID)/disclosures")
        let preview: ActivityAuthorizationPreviewDTO = try await request(
            "/oauth2/authorize",
            query: Self.authorizationQuery(authorization) + [URLQueryItem(name: "integration_type", value: "1")]
        )
        guard preview.application.id == authorization.applicationID.description else {
            throw OAuth2AuthorizationError.unexpectedResponse
        }
        return EmbeddedActivityAuthorizationPreview(
            applicationName: preview.application.name,
            isAuthorized: preview.authorized == true,
            unacknowledgedDisclosures: disclosures.disclosures.filter { !disclosures.ackedDisclosures.contains($0) }
                .compactMap(EmbeddedActivityDisclosure.init)
        )
    }

    /// Records that the person saw the developer's disclosures.
    func acknowledgeEmbeddedActivityDisclosures(
        _ disclosures: [EmbeddedActivityDisclosure], applicationID: ApplicationID
    ) async throws {
        let (data, response) = try await perform(
            "/applications/\(applicationID)/disclosures", method: "POST", query: [],
            body: ["disclosures": .array(disclosures.map { .number(Double($0.rawValue)) })], maximumAttempts: 1
        )
        guard (200 ..< 300).contains(response.statusCode) else { throw unexplainedFailure(data, response) }
    }

    /// Grants the Activity an authorization code, or records the person's
    /// refusal as the official client does, which yields none. The POST is a
    /// single attempt; the redirect it names is parsed, never followed.
    func authorizeEmbeddedActivity(
        _ authorization: EmbeddedActivityAuthorizationRequest,
        granted: Bool
    ) async throws -> String {
        let items = try await postAuthorization(authorization, granted: granted)
        guard granted, items.first(where: { $0.name == "state" })?.value == authorization.state,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw OAuth2AuthorizationError.unexpectedResponse }
        return code
    }

    /// The scopes Discord asks a person to grant before it launches an
    /// app-handled Activity they and the place haven't installed, or nil when
    /// it launches straight away.
    func embeddedActivityInstallScopes(_ applicationID: ApplicationID, in channel: Channel) async throws -> [String]? {
        guard let entryPoint = try await entryPointCommand(for: applicationID, channelID: channel.id, guildID: channel.guildID),
              !entryPoint.isInstalled, entryPoint.command.integrationTypes.contains(1),
              Self.isApplicationHandled(entryPoint.command)
        else { return nil }
        let application: PublicApplicationDTO = try await request(
            "/applications/\(applicationID)/public", query: [URLQueryItem(name: "with_guild", value: "false")]
        )
        return application.integrationTypesConfig?["1"]?.oauth2InstallParams?.scopes
    }

    /// Installs the application for the person before its Activity launches,
    /// or records that they declined; neither yields a code.
    func installEmbeddedActivity(_ authorization: EmbeddedActivityAuthorizationRequest, granted: Bool) async throws {
        _ = try await postAuthorization(authorization, granted: granted)
    }

    /// The consent POST shared by Activity authorization and installation;
    /// returns the query of the location Discord names.
    private func postAuthorization(
        _ authorization: EmbeddedActivityAuthorizationRequest,
        granted: Bool
    ) async throws -> [URLQueryItem] {
        let location = authorization.location
        var body: [String: JSONValue] = [
            "authorize": .bool(granted),
            "integration_type": .number(1),
            "location_context": .object([
                // The official client uses the 10000 placeholder outside a guild.
                "guild_id": .string(location.guildID?.description ?? "10000"),
                "channel_id": .string(location.channelID.description),
                "channel_type": .number(Double(authorization.channelType)),
            ]),
        ]
        if !granted { body["permissions"] = .string("0") }
        let (data, response) = try await perform(
            "/oauth2/authorize",
            method: "POST",
            query: Self.authorizationQuery(authorization),
            body: body,
            maximumAttempts: 1
        )
        let authorized: ActivityAuthorizationLocationDTO = try decodedResponse(
            data, response, method: "POST", path: "/oauth2/authorize"
        )
        let items = URLComponents(string: authorized.location)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw OAuth2AuthorizationError.denied(items.first { $0.name == "error_description" }?.value ?? error)
        }
        return items
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
    /// client already holds, then the application's own index. It counts as
    /// installed when the person's or the place's index lists it.
    private func entryPointCommand(
        for applicationID: ApplicationID,
        channelID: ChannelID,
        guildID: GuildID?
    ) async throws -> (command: ApplicationCommand, isInstalled: Bool)? {
        let targets: [ApplicationCommandIndexTarget] = [
            .user, guildID.map(ApplicationCommandIndexTarget.guild) ?? .channel(channelID),
            .application(applicationID.description),
        ]
        for target in targets {
            let isOwnIndex = if case .application = target { true } else { false }
            let catalog: ApplicationCommandCatalog
            do {
                catalog = try await applicationCommandCatalog(for: target)
            } catch {
                // The application's own index decides between its entry point
                // and the older launch; without it either would be a guess.
                if isOwnIndex { throw error }
                continue
            }
            if let command = catalog.commands.first(where: {
                $0.type == .primaryEntryPoint && $0.applicationID == applicationID.description
            }) {
                return (command, isInstalled: !isOwnIndex)
            }
        }
        return nil
    }

    /// Whether the application answers the entry point itself (handler 1),
    /// rather than Discord launching the Activity (handler 2).
    private static func isApplicationHandled(_ command: ApplicationCommand) -> Bool {
        (try? JSONSerialization.jsonObject(with: command.rootCommandJSON) as? [String: Any])?["handler"] as? Int == 1
    }
}

private struct PublicApplicationDTO: Decodable {
    struct IntegrationTypeConfiguration: Decodable {
        struct InstallParameters: Decodable {
            let scopes: [String]
        }

        let oauth2InstallParams: InstallParameters?

        enum CodingKeys: String, CodingKey {
            case oauth2InstallParams = "oauth2_install_params"
        }
    }

    let integrationTypesConfig: [String: IntegrationTypeConfiguration]?

    enum CodingKeys: String, CodingKey {
        case integrationTypesConfig = "integration_types_config"
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

private struct ActivityDisclosuresDTO: Decodable {
    let disclosures: [Int]
    let ackedDisclosures: [Int]

    enum CodingKeys: String, CodingKey {
        case disclosures
        case ackedDisclosures = "acked_disclosures"
    }
}

private struct ActivityAuthorizationLocationDTO: Decodable {
    let location: String
}

private struct ActivityShelfDTO: Decodable {
    struct Entry: Decodable {
        let applicationID: String
        let shelfRank: Int?
        let requiresAgeGate: Bool?
        let supportedPlatforms: [String]?

        enum CodingKeys: String, CodingKey {
            case applicationID = "application_id"
            case shelfRank = "shelf_rank"
            case requiresAgeGate = "requires_age_gate"
            case supportedPlatforms = "supported_platforms"
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
        let flags: Int?
        let extendedFlags: String?
        let embeddedSurfaces: [Int]?
        let isMonetized: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name, description, icon, tags, flags
            case coverImage = "cover_image"
            case maxParticipants = "max_participants"
            case extendedFlags = "flags_new"
            case embeddedSurfaces = "embedded_surfaces"
            case isMonetized = "is_monetized"
        }

        /// The client's test for a contextless Activity: the
        /// CONTEXTLESS_ACTIVITY flag and the main embedded surface.
        var isContextless: Bool {
            extendedFlags.flatMap(UInt64.init).map { $0 & 1 << 9 != 0 } == true && embeddedSurfaces?.contains(0) == true
        }
    }

    struct Asset: Decodable {
        let id: String
        let name: String
    }

    let activities: LossyList<Entry>
    let applications: LossyList<Application>
    let assets: [String: LossyList<Asset>]?

    /// The application flag behind the shelf's PROMOTED badge.
    private static let promotedFlag = 1 << 29

    /// Shelf order, without Activities the desktop (web) client cannot run.
    /// Recents order follows the score the official launcher sorts by: the age
    /// weights of the last ten launches added up, then the name.
    func domain(frecency: [DiscordFrecencyEntry], now: Date = .now) -> [EmbeddedActivityApplication] {
        let applications = Dictionary(
            self.applications.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let scores = Dictionary(frecency.compactMap { entry in
            DiscordSettingsProto.frecency(
                totalUses: entry.totalUses, recentUses: entry.recentUses.filter { $0 > 0 },
                nowMilliseconds: UInt64(now.timeIntervalSince1970 * 1000)
            ).map { (entry.key, $0.score) }
        }, uniquingKeysWith: max)
        let recentRanks = Dictionary(uniqueKeysWithValues: Set(activities.elements.map(\.applicationID))
            .sorted { lhs, rhs in
                let (left, right) = (scores[lhs] ?? 0, scores[rhs] ?? 0)
                guard left == right else { return left > right }
                return (applications[lhs]?.name ?? "").localizedCompare(applications[rhs]?.name ?? "") == .orderedAscending
            }
            .enumerated().map { ($1, $0) })
        return activities.elements
            .filter { $0.supportedPlatforms?.contains("web") ?? true }
            .sorted { ($0.shelfRank ?? .max) < ($1.shelfRank ?? .max) }
            .compactMap { entry in
                guard let application = applications[entry.applicationID],
                      let id = ApplicationID(application.id) else { return nil }
                // Discord keys assets by name, so the last of a repeated name wins.
                let cover = assets?[application.id]?.elements.last { $0.name == "embedded_cover" }
                    .flatMap { URL(string: "https://cdn.discordapp.com/app-assets/\(id)/\($0.id).png?size=512") }
                    ?? application.coverImage.flatMap { URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\($0).png?size=512") }
                return EmbeddedActivityApplication(
                    id: id,
                    name: application.name,
                    description: application.description ?? "",
                    iconURL: application.icon.flatMap { URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\($0).png?size=128") },
                    coverURL: cover,
                    tags: application.tags ?? [],
                    maximumParticipants: application.maxParticipants.flatMap { $0 > 0 ? $0 : nil },
                    isPromoted: (application.flags ?? 0) & Self.promotedFlag != 0,
                    requiresAgeGate: entry.requiresAgeGate == true,
                    hasInAppPurchases: application.isMonetized == true,
                    isContextless: application.isContextless,
                    recentRank: recentRanks[application.id]
                )
            }
    }
}
