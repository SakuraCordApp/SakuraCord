import Foundation

/// Users, relationships, settings, guilds, search and sign-in routes.
enum AccountRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/users/@me"] = { context in .json(await context.world.renderSelf(context.userID)) }

        routes["GET /api/v9/users/@me/relationships"] = { context in
            let world = context.world
            var list: [JSON] = []
            for relationship in (await world.relationships[context.userID] ?? [:]).values.sorted(by: { $0.since < $1.since }) {
                list.append(.object(JSONObject([
                    ("id", relationship.userID.json), ("type", .int(relationship.type.rawValue)),
                    ("nickname", .optional(relationship.nickname)), ("user", await world.renderUser(relationship.userID)),
                    ("since", World.timestamp(relationship.since)), ("is_spam_request", false), ("user_ignored", .bool(relationship.ignored)),
                ])))
            }
            return .json(.array(list))
        }

        routes["GET /api/v9/users/{id}/profile"] = { context in
            .json(try await context.world.renderProfile(try context.id(0), viewer: context.userID,
                                                       guildID: context.query("guild_id").flatMap(Snowflake.init)))
        }

        // Settings types are small integers, which the template keeps literal.
        for type in 1 ... 3 {
            routes["GET /api/v9/users/@me/settings-proto/\(type)"] = { context in
                let data = await context.world.settingsProto[context.userID]?[type] ?? Data()
                return .json(.object(JSONObject([("settings", .string(data.base64EncodedString()))])))
            }
            routes["PATCH /api/v9/users/@me/settings-proto/\(type)"] = { context in
                let encoded = try context.json["settings"]?.stringValue ?? ""
                guard let patch = Data(base64Encoded: encoded) else { throw WorldError.invalidBody("settings: not base64") }
                let merged = try await context.world.patchSettings(context.userID, type: type, patch: patch)
                return .json(.object(JSONObject([("settings", .string(merged.base64EncodedString()))])))
            }
        }

        routes["GET /api/v9/users/@me/channels"] = { context in
            let world = context.world
            var list: [JSON] = []
            for id in await world.openPrivateChannels[context.userID] ?? [] {
                if let channel = await world.channels[id] { list.append(await world.renderChannel(channel, viewer: context.userID)) }
            }
            return .json(.array(list))
        }
        routes["POST /api/v9/users/@me/channels"] = { context in
            let recipients = (try context.json["recipients"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Snowflake.init) }
            let channel = try await context.world.openPrivateChannel(for: context.userID, with: recipients)
            return .json(await context.world.renderChannel(channel, viewer: context.userID))
        }

        routes["GET /api/v9/guilds/{id}/members/{id}"] = { context in
            let guild = try await context.world.guild(try context.id(0))
            guard let member = guild.members[try context.id(1)] else { throw WorldError.unknown("Member", code: 10007) }
            return .json(await context.world.renderMember(member, guildID: guild.id, includeUser: true))
        }

        routes["GET /api/v9/guilds/{id}/messages/search"] = { context in
            .json(try await context.world.search(guildID: try context.id(0), request: context.request, viewer: context.userID))
        }

        // Pre-sign-in identity routes. The official client can't be captured
        // before sign-in, so these follow Discord's documented responses.
        routes["GET /api/v9/experiments"] = { context in
            .json(.object(JSONObject([("fingerprint", .string(await context.world.clientIdentity())),
                                      ("assignments", []), ("guild_experiments", [])])))
        }
        routes["GET /api/v9/apex/experiments"] = { context in
            .json(.object(JSONObject([("installation", .string(await context.world.clientIdentity())),
                                      ("assignments", .object(JSONObject()))])))
        }

        routes["POST /auth/login"] = { context in .json(try await context.world.login(try context.json)) }
        routes["POST /api/v9/auth/login"] = routes["POST /auth/login"]
    }
}

extension World {
    /// A fingerprint or installation ID: `<snowflake>.<27 url-safe characters>`.
    func clientIdentity() -> String {
        "\(nextID()).\(random.urlSafeString(27))"
    }

    /// Merges a partial settings proto into the stored one and returns the
    /// full result, which is also what other sessions receive. Every write
    /// moves the settings' data version on by one, as captured.
    func patchSettings(_ userID: Snowflake, type: Int, patch: Data) async throws -> Data {
        guard let data = ProtobufMerge.merge(settingsProto[userID]?[type] ?? Data(), patch).map(ProtobufMerge.bumpingDataVersion) else {
            throw WorldError.invalidBody("settings: not a protobuf message")
        }
        settingsProto[userID, default: [:]][type] = data
        await emit("USER_SETTINGS_PROTO_UPDATE", .object(JSONObject([
            ("settings", .object(JSONObject([("type", .int(type)), ("proto", .string(data.base64EncodedString()))]))),
            ("partial", false),
        ])), to: .users([userID]))
        return data
    }

    func openPrivateChannel(for userID: Snowflake, with recipients: [Snowflake]) async throws -> Channel {
        let members = Set(recipients + [userID])
        // A DM is reopened; every group create makes a new group, as on Discord.
        if recipients.count == 1, let existing = channels.values.first(where: { $0.type == .dm && Set($0.recipients) == members }) {
            if openPrivateChannels[userID]?.contains(existing.id) != true { openPrivateChannels[userID, default: []].append(existing.id) }
            return existing
        }
        for recipient in recipients { _ = try user(recipient) }
        var channel = Channel(id: nextID(), type: recipients.count == 1 ? .dm : .groupDM)
        channel.recipients = Array(members).sorted()
        if channel.type == .groupDM { channel.ownerID = userID }
        channels[channel.id] = channel
        // Everyone in a new group gets it at once; the other side of a DM only once a message arrives.
        for member in channel.type == .groupDM ? channel.recipients : [userID] {
            openPrivateChannels[member, default: []].append(channel.id)
            await emit("CHANNEL_CREATE", renderChannel(channel, viewer: member), to: .users([member]))
        }
        return channel
    }

    /// `POST /auth/login`. The response shape follows Discord's documented
    /// login result; the official client can't be captured signing in without
    /// the account owner, so this route is listed as uncaptured by the parity suite.
    func login(_ body: JSON) throws -> JSON {
        let login = (body["login"]?.stringValue ?? "").lowercased()
        let password = body["password"]?.stringValue ?? ""
        guard let user = users.values.first(where: { ($0.email?.lowercased() == login || $0.username == login) && $0.password != nil }),
              user.password == password else {
            throw WorldError(status: 400, code: 50035, message: "Invalid Form Body")
        }
        if signIn.authenticatorCodes[user.id] != nil { return mfaChallenge(for: user.id) }
        return try signedIn(user.id)
    }

    func renderProfile(_ userID: Snowflake, viewer: Snowflake, guildID: Snowflake?) throws -> JSON {
        let user = try user(userID)
        let viewerGuilds = Set(guilds(of: viewer).map(\.id))
        let mutualGuilds = guilds(of: userID).filter { viewerGuilds.contains($0.id) && userID != viewer }
        let viewerFriends = Set((relationships[viewer] ?? [:]).values.filter { $0.type == .friend }.map(\.userID))
        let mutualFriends = (relationships[userID] ?? [:]).values.filter { $0.type == .friend && viewerFriends.contains($0.userID) }
            .map(\.userID).sorted()
        var userObject = JSONObject()
        if case let .object(base) = renderUser(userID) { userObject = base }
        userObject["bio"] = .string(user.bio)
        var object = JSONObject([
            ("user", .object(userObject)),
            ("connected_accounts", []),
            ("premium_type", .int(user.premiumType.rawValue)),
            ("premium_since", World.optionalTimestamp(user.premiumType == .none ? nil : user.premiumSince ?? user.createdAt)),
            ("premium_guild_since", World.optionalTimestamp(guilds.values.compactMap { $0.boosts.first { $0.userID == userID }?.since }.min())),
            ("profile_themes_experiment_bucket", 4),
            ("user_profile", .object(JSONObject([
                ("bio", .string(user.bio)), ("accent_color", .optional(user.accentColor)), ("pronouns", .string(user.pronouns)),
                ("profile_effect", .null), ("banner", .optional(user.banner)),
                ("theme_colors", user.themeColors.map { .array($0.map { .int($0) }) } ?? .null), ("popout_animation_particle_type", .null),
                ("emoji", .null), ("collectibles", []),
            ]))),
            ("badges", .array(user.premiumType == .none ? [] : [.object(JSONObject([
                ("id", "premium"), ("description", .string("Subscriber since \(Self.badgeDate(user.premiumSince ?? user.createdAt))")),
                ("icon", .string(World.premiumBadgeIcon)), ("link", "https://discord.com/settings/premium"),
            ]))])),
            ("guild_badges", []),
            ("widgets", .array(profileWidgets[userID] ?? [])),
            ("wishlist_settings", .object(JSONObject())),
            ("legacy_username", .null),
        ])
        if userID != viewer {
            object["mutual_friends"] = .array(mutualFriends.map(renderUser))
            object["mutual_friends_count"] = .int(mutualFriends.count)
            object["mutual_guilds"] = .array(mutualGuilds.map { guild in
                .object(JSONObject([("id", guild.id.json), ("nick", .optional(guild.members[userID]?.nick))]))
            })
        }
        if let guildID, let guild = guilds[guildID], let member = guild.members[userID] {
            object["guild_member"] = renderMember(member, guildID: guildID, includeUser: true).merging(["bio": ""])
            var serverProfile = JSONObject([
                ("guild_id", guildID.json), ("pronouns", .string(member.pronouns)),
                ("banner", .optional(member.banner)), ("accent_color", .optional(member.accentColor)), ("profile_effect", .null),
                ("theme_colors", member.themeColors.map { .array($0.map { .int($0) }) } ?? .null), ("popout_animation_particle_type", .null),
                ("emoji", .null), ("collectibles", []),
            ])
            // Discord leaves an unset server bio out rather than sending null.
            if let bio = member.bio { serverProfile["bio"] = .string(bio) }
            object["guild_member_profile"] = .object(serverProfile)
        }
        return .object(object)
    }

    static func badgeDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    func search(guildID: Snowflake, request: HTTPRequest, viewer: Snowflake) throws -> JSON {
        let guild = try guild(guildID)
        let text = request.query["content"]?.first?.lowercased() ?? ""
        let authors = Set((request.query["author_id"] ?? []).compactMap(Snowflake.init))
        let channelFilter = Set((request.query["channel_id"] ?? []).compactMap(Snowflake.init))
        let offset = Int(request.query["offset"]?.first ?? "0") ?? 0
        var hits: [Message] = []
        for channel in guild.channelIDs.compactMap({ channels[$0] }) where canView(viewer, channel) {
            if !channelFilter.isEmpty, !channelFilter.contains(channel.id) { continue }
            hits += channel.messages.filter { message in
                (text.isEmpty || message.content.lowercased().contains(text)) && (authors.isEmpty || authors.contains(message.authorID))
            }
        }
        hits.sort { $0.id > $1.id }
        return .object(JSONObject([
            ("analytics_id", .string(nextHash())),
            ("messages", .array(hits.dropFirst(offset).prefix(25).map { hit in
                .array([renderMessage(hit, viewer: viewer).merging(["hit": true])])
            })),
            ("doing_deep_historical_index", false),
            ("total_results", .int(hits.count)),
        ]))
    }

    func threadSearch(parentID: Snowflake, request: HTTPRequest, viewer: Snowflake) throws -> JSON {
        let parent = try channel(parentID)
        guard canView(viewer, parent) else { throw WorldError.missingAccess }
        let offset = Int(request.query["offset"]?.first ?? "0") ?? 0
        let limit = Int(request.query["limit"]?.first ?? "25") ?? 25
        let archived = request.query["archived"]?.first == "true"
        let tagFilter = Set((request.query["tag"] ?? []).compactMap(Snowflake.init))
        let matchesAllTags = request.query["tag_setting"]?.first == "match_all"
        let terms = (request.query["name"]?.first ?? "").split(whereSeparator: \.isWhitespace)
        var threads = threads(in: parentID).filter { ($0.thread?.archived ?? false) == archived || request.query["archived"] == nil }
        if !tagFilter.isEmpty {
            threads = threads.filter { matchesAllTags ? tagFilter.isSubset(of: $0.appliedTags) : !tagFilter.isDisjoint(with: $0.appliedTags) }
        }
        // Name search matches every word, ignoring case and accents, before paging.
        threads = threads.filter { thread in
            terms.allSatisfy { (thread.name ?? "").range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        let sortByCreation = request.query["sort_by"]?.first == "creation_time"
        let ascending = request.query["sort_order"]?.first == "asc"
        threads.sort {
            let (lhs, rhs) = sortByCreation ? ($0.id, $1.id) : ($0.lastMessageID ?? $0.id, $1.lastMessageID ?? $1.id)
            return ascending ? lhs < rhs : lhs > rhs
        }
        let page = Array(threads.dropFirst(offset).prefix(limit))
        return .object(JSONObject([
            ("threads", .array(page.map { renderThread($0, viewer: viewer) })),
            ("members", .array(page.filter { $0.threadMembers.contains(viewer) }.map { renderThreadMember($0, userID: viewer, includeIDs: true) })),
            ("has_more", .bool(offset + page.count < threads.count)),
            ("first_messages", .array(page.compactMap { $0.messages.first.map { renderMessage($0, viewer: viewer) } })),
            ("total_results", .int(threads.count)),
        ]))
    }
}
