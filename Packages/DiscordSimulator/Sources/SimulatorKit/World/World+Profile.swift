import Foundation

/// Editing one's own profile: identity (`PATCH /users/@me`), profile details
/// (`PATCH /users/@me/profile`), the server profile, the server tag, avatar
/// history and profile widgets.
extension World {
    /// `PATCH /users/@me`: display name, avatar (upload or from history), decoration and nameplate.
    func editIdentity(_ userID: Snowflake, body: JSON) async throws -> JSON {
        var user = try user(userID)
        if let name = body["global_name"] {
            let trimmed = name.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Not captured: Discord's documented 32-character limit.
            guard (trimmed?.count ?? 0) <= 32 else { throw WorldError.invalidBody("global_name: Must be between 1 and 32 in length.") }
            user.globalName = trimmed?.isEmpty == false ? trimmed : nil
        }
        if let avatar = body["avatar"] {
            user.avatar = try avatar.stringValue.map { try storeAvatar($0, of: userID, description: body["avatar_description"]?.stringValue) }
        }
        if let historyID = body["avatar_id"]?.stringValue {
            guard let entry = avatarHistory[userID]?.first(where: { $0["id"]?.stringValue == historyID }) else {
                throw WorldError.invalidBody("avatar_id: Unknown avatar")
            }
            user.avatar = entry["storage_hash"]?.stringValue
        }
        if let sku = body["avatar_decoration_sku_id"] {
            try requireOwned(sku, current: user.avatarDecoration?["sku_id"])
            if sku == .null { user.avatarDecoration = nil }
        }
        if let sku = body["nameplate_sku_id"] {
            try requireOwned(sku, current: user.collectibles?["nameplate"]?["sku_id"])
            if sku == .null { user.collectibles = nil }
        }
        if body["display_name_font_id"] != nil || body["display_name_colors"] != nil {
            throw NotSimulated(description: "display name styles (never captured)")
        }
        let edited = user
        try await updateUser(userID) { $0 = edited }
        return renderSelf(userID).merging(["token": .string(tokens.first { $0.value == userID }?.key ?? "")])
    }

    /// `PATCH /users/@me/profile`: bio, pronouns, accent colour, banner and theme.
    /// Only the user's own sessions hear about it (USER_UPDATE).
    func editProfileDetails(_ userID: Snowflake, body: JSON) async throws -> JSON {
        var user = try user(userID)
        if let bio = try Self.capped(body["bio"], 190, "bio") { user.bio = bio }
        if let pronouns = try Self.capped(body["pronouns"], 40, "pronouns") { user.pronouns = pronouns }
        if let accent = body["accent_color"] { user.accentColor = accent.intValue.map(Int.init) }
        if let banner = body["banner"] {
            user.banner = try banner.stringValue.map { try storeUploadedImage($0, path: { "/banners/\(userID)/\($0)" }) }
        }
        if let colors = body["theme_colors"] { user.themeColors = Self.themeColors(colors) }
        if let skus = body["collectibles_sku_ids"]?.arrayValue, !skus.isEmpty {
            throw NotSimulated(description: "profile collectibles (never captured)")
        }
        users[userID] = user
        await emit("USER_UPDATE", renderSelf(userID), to: .users([userID]))
        return .object(JSONObject([
            ("bio", .string(user.bio)), ("accent_color", .optional(user.accentColor)), ("pronouns", .string(user.pronouns)),
            ("profile_effect", .null), ("collectibles", []),
        ]))
    }

    /// `PATCH /guilds/{id}/members/@me`: the server nickname, avatar and banner.
    /// A nickname goes through the moderation path, which also logs it as Discord does.
    func editServerProfile(_ userID: Snowflake, in guildID: Snowflake, body: JSON) async throws -> JSON {
        let guild = try guild(guildID)
        guard var member = guild.members[userID] else { throw WorldError.unknown("Guild", code: 10004) }
        if let avatar = body["avatar"] {
            member.avatar = try avatar.stringValue.map { try storeUploadedImage($0, path: { "/guilds/\(guildID)/users/\(userID)/avatars/\($0)" }) }
        }
        if let banner = body["banner"] {
            member.banner = try banner.stringValue.map { try storeUploadedImage($0, path: { "/guilds/\(guildID)/users/\(userID)/banners/\($0)" }) }
        }
        if let collectibles = body["collectibles"], collectibles != .null {
            throw NotSimulated(description: "server nameplates (never captured)")
        }
        guilds[guildID]?.members[userID] = member
        let rendered: JSON
        if let nick = body["nick"] {
            rendered = try await modifyMember(userID, in: guildID, by: userID, body: .object(JSONObject([("nick", nick)])))
        } else {
            rendered = renderMember(member, guildID: guildID, includeUser: true)
            await emit("GUILD_MEMBER_UPDATE", rendered.merging(["guild_id": guildID.json]), to: .guild(guildID, channel: nil))
        }
        return rendered.merging(["bio": .string(member.bio ?? ""), "permissions": .string(guild.permissions(of: userID, at: clock.now).wireString)])
    }

    /// `PATCH /guilds/{id}/profile/@me`: the per-server bio, pronouns, banner and theme.
    /// Everyone in the server sees it through GUILD_MEMBER_UPDATE.
    func editServerProfileDetails(_ userID: Snowflake, in guildID: Snowflake, body: JSON) async throws -> JSON {
        guard var member = try guild(guildID).members[userID] else { throw WorldError.unknown("Guild", code: 10004) }
        if let pronouns = try Self.capped(body["pronouns"], 40, "pronouns") { member.pronouns = pronouns }
        // An empty or null server bio falls back to the main profile's.
        if body["bio"] != nil { member.bio = try Self.capped(body["bio"], 190, "bio").flatMap { $0.isEmpty ? nil : $0 } }
        if let accent = body["accent_color"] { member.accentColor = accent.intValue.map(Int.init) }
        if let colors = body["theme_colors"] { member.themeColors = Self.themeColors(colors) }
        if let banner = body["banner"] {
            member.banner = try banner.stringValue.map { try storeUploadedImage($0, path: { "/guilds/\(guildID)/users/\(userID)/banners/\($0)" }) }
        }
        guilds[guildID]?.members[userID] = member
        await emitMemberUpdate(member, in: guildID)
        return .object(JSONObject([("guild_id", guildID.json), ("pronouns", .string(member.pronouns)), ("bio", .optional(member.bio)),
                                   ("accent_color", .optional(member.accentColor)), ("profile_effect", .null), ("collectibles", [])]))
    }

    /// `PUT /users/@me/clan`: wear a server's tag, or take it off.
    func setServerTag(_ userID: Snowflake, body: JSON) async throws -> JSON {
        let guildID = body["identity_guild_id"]?.stringValue.flatMap(Snowflake.init)
        let enabled = body["identity_enabled"]?.boolValue ?? false
        var tag: JSON = .object(JSONObject([("identity_guild_id", .null), ("identity_enabled", false), ("tag", .null), ("badge", .null)]))
        if let guildID, enabled {
            guard let guild = guilds[guildID], guild.members[userID] != nil, let serverTag = guild.serverTag else {
                throw WorldError.invalidBody("identity_guild_id: This server has no tag")
            }
            tag = .object(JSONObject([("identity_guild_id", guildID.json), ("identity_enabled", true),
                                      ("tag", .string(serverTag.tag)), ("badge", .string(serverTag.badge))]))
        }
        try await updateUser(userID) { $0.primaryGuild = tag }
        return renderSelf(userID)
    }

    /// `PUT /users/@me/widgets` replaces the list; widgets keep their ID and
    /// time while unchanged, and new or changed ones get fresh ones.
    func saveProfileWidgets(_ userID: Snowflake, body: JSON) throws -> JSON {
        let previous = profileWidgets[userID] ?? []
        var saved: [JSON] = []
        for widget in body["widgets"]?.arrayValue ?? [] {
            guard var data = widget["data"]?.objectValue, let type = data["type"]?.stringValue else { throw WorldError.invalidBody("widgets: data.type") }
            if let games = data["games"]?.arrayValue {
                data["games"] = .array(games.map { game in
                    .object(JSONObject([("game_id", game["game_id"] ?? .null), ("comment", game["comment"] ?? .null), ("tags", game["tags"] ?? [])]))
                })
            }
            if type == "application", data["application_id"] == nil { throw WorldError.invalidBody("widgets: data.application_id") }
            let existing = previous.first { $0["id"] != nil && $0["id"] == widget["id"] }
            if let existing, existing["data"] == .object(data) {
                saved.append(existing)
            } else {
                saved.append(.object(JSONObject([("id", nextID().json), ("updated_at", World.timestamp(clock.now)), ("data", .object(data))])))
            }
        }
        profileWidgets[userID] = saved
        return .object(JSONObject([("widgets", .array(saved))]))
    }

    // MARK: Images

    /// Stores an uploaded avatar and records it in the user's avatar history.
    private func storeAvatar(_ dataURI: String, of userID: Snowflake, description: String?) throws -> String {
        let hash = try storeUploadedImage(dataURI, path: { "/avatars/\(userID)/\($0)" })
        recordAvatar(hash, of: userID, description: description, at: clock.now)
        return hash
    }

    /// Adds an avatar to the front of the history, labelled like Discord: "<description>, added 5 October 2026 at 22:20".
    func recordAvatar(_ hash: String, of userID: Snowflake, description: String?, at date: Date) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy 'at' HH:mm"
        let label = description.flatMap { $0.isEmpty ? nil : $0 } ?? "Avatar"
        avatarHistory[userID, default: []].insert(JSONObject([
            ("id", nextID(at: date).json), ("storage_hash", .string(hash)), ("description", .string("\(label), added \(formatter.string(from: date))")),
        ]), at: 0)
    }

    func deleteAvatarHistoryEntry(_ id: Snowflake, of userID: Snowflake) throws {
        guard let index = avatarHistory[userID]?.firstIndex(where: { $0["id"]?.stringValue == id.description }) else { throw WorldError.notFound }
        avatarHistory[userID]?.remove(at: index)
    }

    /// Decodes a `data:<type>;base64,…` upload and serves it at `path(hash)` in every extension the client may ask for.
    func storeUploadedImage(_ dataURI: String, path: (String) -> String) throws -> String {
        guard dataURI.hasPrefix("data:"), let comma = dataURI.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURI[dataURI.index(after: comma)...])) else {
            throw WorldError.invalidBody("image: Invalid image data")
        }
        let contentType = String(dataURI[dataURI.index(dataURI.startIndex, offsetBy: 5) ..< comma]).replacingOccurrences(of: ";base64", with: "")
        let hash = nextHash(animated: contentType == "image/gif")
        registerAsset(hash)
        for ext in ["png", "webp", "jpg", "gif"] { storeMedia(path("\(hash).\(ext)"), data, contentType: contentType) }
        return hash
    }

    /// Not captured: the length limits are Discord's documented ones (190 for bios, 40 for pronouns).
    private static func capped(_ value: JSON?, _ limit: Int, _ field: String) throws -> String? {
        guard let text = value?.stringValue else { return nil }
        guard text.count <= limit else { throw WorldError.invalidBody("\(field): Must be \(limit) or fewer in length.") }
        return text
    }

    /// `[primary, accent]`, or `[null, null]` to clear.
    private static func themeColors(_ value: JSON) -> [Int]? {
        let values = (value.arrayValue ?? []).compactMap { $0.intValue.map(Int.init) }
        return values.count == 2 ? values : nil
    }

    /// Collectibles can only be cleared or kept; the simulator sells nothing.
    private func requireOwned(_ sku: JSON, current: JSON?) throws {
        guard sku == .null || sku == current else { throw WorldError.invalidBody("sku_id: You do not own this item") }
    }
}
