import Foundation

// Creating, editing and deleting a guild's channels, with the channel events
// and audit log entries Discord sends.
extension World {
    private static let creatableTypes: Set<ChannelType> = [.text, .voice, .category, .announcement, .stage, .forum, .media]

    /// Text-like channel names are lowercase with dashes for spaces, as Discord stores them.
    private static func channelName(_ raw: String?, type: ChannelType) throws -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 100).contains(trimmed.count) else { throw WorldError.invalidBody("name: Must be between 1 and 100 in length.") }
        guard [.text, .announcement, .forum, .media].contains(type) else { return trimmed }
        return trimmed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    private func overwrites(_ value: JSON?) -> [PermissionOverwrite]? {
        value?.arrayValue?.compactMap { entry in
            guard let id = entry["id"]?.stringValue.flatMap(Snowflake.init),
                  let kind = PermissionOverwrite.Kind(rawValue: Int(entry["type"]?.intValue ?? 0)) else { return nil }
            func bits(_ key: String) -> Permissions { Permissions(rawValue: entry[key]?.stringValue.flatMap(UInt64.init) ?? 0) }
            return PermissionOverwrite(id: id, kind: kind, allow: bits("allow"), deny: bits("deny"))
        }
    }

    private func requireCategory(_ id: Snowflake?, in guildID: Snowflake) throws {
        guard let id else { return }
        guard channels[id]?.guildID == guildID, channels[id]?.type == .category else { throw WorldError.invalidBody("parent_id: Not a category") }
    }

    /// `POST /guilds/{id}/channels`: needs Manage Channels; the new channel goes last.
    func createGuildChannel(in guildID: Snowflake, by userID: Snowflake, body: JSON) async throws -> Channel {
        let guild = try guild(guildID)
        guard guild.permissions(of: userID).contains(.manageChannels) else { throw WorldError.missingPermissions }
        guard let type = ChannelType(rawValue: Int(body["type"]?.intValue ?? 0)), Self.creatableTypes.contains(type) else {
            throw WorldError.invalidBody("type: Value is not a valid channel type")
        }
        var channel = Channel(id: nextID(), type: type, guildID: guildID, name: try Self.channelName(body["name"]?.stringValue, type: type))
        channel.parentID = body["parent_id"]?.stringValue.flatMap(Snowflake.init)
        try requireCategory(channel.parentID, in: guildID)
        channel.topic = body["topic"]?.stringValue
        channel.overwrites = overwrites(body["permission_overwrites"]) ?? []
        channel.position = (guild.channelIDs.compactMap { channels[$0] }.filter { !$0.type.isThread }.map(\.position).max() ?? -1) + 1
        addChannel(channel)
        await emit("CHANNEL_CREATE", renderChannelEvent(channel), to: audience(for: channel))
        await emitAuditLog(guildID, action: 10, target: channel.id, by: userID, changes: [
            auditChange("name", old: nil, new: .optional(channel.name)), auditChange("type", old: nil, new: .int(type.rawValue)),
        ])
        return channel
    }

    /// `PATCH /channels/{id}` for a guild channel: needs Manage Channels in it.
    func editGuildChannel(_ channelID: Snowflake, by userID: Snowflake, patch: JSON) async throws -> Channel {
        var channel = try channel(channelID)
        guard let guildID = channel.guildID else { throw WorldError.missingAccess }
        try require(.manageChannels, userID, channel)
        let before = channel
        if patch["name"] != nil { channel.name = try Self.channelName(patch["name"]?.stringValue, type: channel.type) }
        if let topic = patch["topic"] { channel.topic = topic.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        if let nsfw = patch["nsfw"]?.boolValue { channel.nsfw = nsfw }
        if let slowmode = patch["rate_limit_per_user"]?.intValue { channel.rateLimitPerUser = Int(slowmode) }
        if let bitrate = patch["bitrate"]?.intValue { channel.bitrate = Int(bitrate) }
        if let limit = patch["user_limit"]?.intValue { channel.userLimit = Int(limit) }
        if let position = patch["position"]?.intValue { channel.position = Int(position) }
        if let parent = patch["parent_id"] {
            channel.parentID = parent.stringValue.flatMap(Snowflake.init)
            try requireCategory(channel.parentID, in: guildID)
        }
        if let overwrites = overwrites(patch["permission_overwrites"]) {
            try require(.manageRoles, userID, channel)
            channel.overwrites = overwrites
        }
        channels[channelID] = channel
        await emit("CHANNEL_UPDATE", renderChannelEvent(channel), to: audience(for: channel))
        let changes = [("name", before.name.map(JSON.string), channel.name.map(JSON.string)),
                       ("topic", before.topic.map(JSON.string), channel.topic.map(JSON.string))]
            .filter { $0.1 != $0.2 }.map { auditChange($0.0, old: $0.1, new: $0.2) }
        await emitAuditLog(guildID, action: 11, target: channelID, by: userID, changes: changes)
        return channel
    }

    /// `DELETE /channels/{id}` for a guild channel. Its threads go with it; a category's channels stay, uncategorized.
    func deleteGuildChannel(_ channelID: Snowflake, by userID: Snowflake) async throws -> Channel {
        let channel = try channel(channelID)
        guard let guildID = channel.guildID else { throw WorldError.missingAccess }
        try require(.manageChannels, userID, channel)
        guard guilds[guildID]?.rulesChannelID != channelID else {
            throw WorldError(status: 400, code: 50074, message: "Cannot delete a channel required for Community Servers")
        }
        await emit("CHANNEL_DELETE", renderChannelEvent(channel), to: audience(for: channel))
        for thread in threads(in: channelID) { channels[thread.id] = nil }
        channels[channelID] = nil
        guilds[guildID]?.channelIDs.removeAll { channels[$0] == nil }
        if guilds[guildID]?.systemChannelID == channelID { guilds[guildID]?.systemChannelID = nil }
        for child in channels.values where child.parentID == channelID && !child.type.isThread {
            channels[child.id]?.parentID = nil
            if let moved = channels[child.id] { await emit("CHANNEL_UPDATE", renderChannelEvent(moved), to: audience(for: moved)) }
        }
        await emitAuditLog(guildID, action: 12, target: channelID, by: userID,
                           changes: [auditChange("name", old: .optional(channel.name), new: nil)])
        return channel
    }

    /// `PUT /channels/{id}/permissions/{id}` (`allow` nil deletes): needs Manage Roles in the channel.
    func setPermissionOverwrite(_ channelID: Snowflake, target: Snowflake, by userID: Snowflake, body: JSON?) async throws {
        var channel = try channel(channelID)
        guard let guildID = channel.guildID else { throw WorldError.missingAccess }
        try require(.manageRoles, userID, channel)
        let previous = channel.overwrites.first { $0.id == target }
        var options = JSONObject([("id", target.json)])
        let action: Int
        var changes: [JSON]
        if let body {
            guard let kind = PermissionOverwrite.Kind(rawValue: Int(body["type"]?.intValue ?? -1)) else { throw WorldError.invalidBody("type: required") }
            func bits(_ key: String) -> Permissions { Permissions(rawValue: body[key]?.stringValue.flatMap(UInt64.init) ?? 0) }
            let overwrite = PermissionOverwrite(id: target, kind: kind, allow: bits("allow"), deny: bits("deny"))
            if let index = channel.overwrites.firstIndex(where: { $0.id == target }) {
                channel.overwrites[index] = overwrite
            } else {
                channel.overwrites.append(overwrite)
            }
            action = previous == nil ? 13 : 14
            changes = previous.map { old in
                [("allow", old.allow, overwrite.allow), ("deny", old.deny, overwrite.deny)].filter { $0.1 != $0.2 }
                    .map { auditChange($0.0, old: .int(Int64($0.1.rawValue)), new: .string($0.2.wireString)) }
            } ?? [auditChange("id", old: nil, new: target.json), auditChange("type", old: nil, new: .int(kind.rawValue)),
                  auditChange("allow", old: nil, new: .string(overwrite.allow.wireString)),
                  auditChange("deny", old: nil, new: .string(overwrite.deny.wireString))]
            if kind == .role { options["role_name"] = .optional(guilds[guildID]?.roles.first { $0.id == target }?.name) }
            options["type"] = .string(String(kind.rawValue))
        } else {
            guard let previous else { return }
            channel.overwrites.removeAll { $0.id == target }
            action = 15
            changes = [auditChange("id", old: target.json, new: nil), auditChange("type", old: .int(previous.kind.rawValue), new: nil),
                       auditChange("allow", old: .int(Int64(previous.allow.rawValue)), new: nil),
                       auditChange("deny", old: .int(Int64(previous.deny.rawValue)), new: nil)]
            if previous.kind == .role { options["role_name"] = .optional(guilds[guildID]?.roles.first { $0.id == target }?.name) }
            options["type"] = .string(String(previous.kind.rawValue))
        }
        channels[channelID] = channel
        await emit("CHANNEL_UPDATE", renderChannelEvent(channel), to: audience(for: channel))
        await emitAuditLog(guildID, action: action, target: channelID, by: userID, changes: changes, options: options)
    }

    /// CHANNEL_CREATE/UPDATE/DELETE carry the guild channel plus its version.
    private func renderChannelEvent(_ channel: Channel) -> JSON {
        renderChannel(channel).merging(["version": .int(Int64(clock.now.timeIntervalSince1970 * 1000))])
    }

    /// A bot joining or leaving changes the guild's commands; clients refetch the catalogue.
    func emitCommandIndexUpdate(_ guildID: Snowflake) async {
        await emit("GUILD_APPLICATION_COMMAND_INDEX_UPDATE", .object(JSONObject([
            ("guild_id", guildID.json), ("application_command_counts", .object(JSONObject())), ("bot_users", []), ("version", 0),
        ])), to: .guild(guildID, channel: nil))
    }
}
