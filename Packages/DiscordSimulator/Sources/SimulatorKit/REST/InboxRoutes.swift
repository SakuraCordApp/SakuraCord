import Foundation

/// The inbox's mentions tab and per-server notification settings.
enum InboxRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/users/@me/mentions"] = { context in
            let world = context.world
            let mentions = await world.recentMentions(
                for: context.userID, limit: min(100, max(1, Int(context.query("limit") ?? "25") ?? 25)),
                before: context.query("before").flatMap(Snowflake.init), guildID: context.query("guild_id").flatMap(Snowflake.init),
                roles: context.query("roles") != "false", everyone: context.query("everyone") != "false"
            )
            var rendered: [JSON] = []
            for message in mentions { rendered.append(await world.renderMessage(message, viewer: context.userID)) }
            return .json(.array(rendered))
        }

        // "Mark as read" in the Mentions tab clears one mention for this user only.
        routes["DELETE /api/v9/users/@me/mentions/{id}"] = { context in
            let messageID = try context.id(0)
            await context.world.dismissMention(messageID, for: context.userID)
            return .empty
        }

        routes["PATCH /api/v9/users/@me/guilds/settings"] = { context in
            guard let guilds = try context.json["guilds"]?.objectValue else { throw WorldError.invalidBody("guilds") }
            return .json(.array(try await context.world.patchGuildSettings(context.userID, guilds: guilds)))
        }
        // The per-server form takes one server's fields and answers with its settings; `@me` is direct messages.
        for scoped in ["{id}", "@me"] {
            routes["PATCH /api/v9/users/@me/guilds/\(scoped)/settings"] = { context in
                guard let fields = try context.json.objectValue else { throw WorldError.invalidBody("not an object") }
                let scope = scoped == "@me" ? nil : try context.id(0)
                return .json(try await context.world.patchGuildSettings(context.userID, scope: scope, fields: fields))
            }
        }
    }
}

extension World {
    /// Server messages that pinged the user, newest first, as the inbox lists them.
    func recentMentions(for userID: Snowflake, limit: Int, before: Snowflake?, guildID: Snowflake?, roles: Bool, everyone: Bool) -> [Message] {
        let dismissed = dismissedMentions[userID] ?? []
        var hits: [Message] = []
        for guild in guilds(of: userID) where guildID == nil || guild.id == guildID {
            let ownRoles = Set(guild.members[userID]?.roles ?? [])
            for channel in guild.channelIDs.compactMap({ channels[$0] }) where channel.type.holdsMessages && canView(userID, channel) {
                hits += channel.messages.filter { message in
                    message.authorID != userID && !dismissed.contains(message.id) && (before == nil || message.id < before!)
                        && (message.mentions.contains(userID) || roles && !ownRoles.isDisjoint(with: message.mentionRoles)
                            || everyone && message.mentionEveryone)
                }
            }
        }
        return Array(hits.sorted { $0.id > $1.id }.prefix(limit))
    }

    func dismissMention(_ messageID: Snowflake, for userID: Snowflake) async {
        dismissedMentions[userID, default: []].insert(messageID)
        await emit("RECENT_MENTION_DELETE", .object(JSONObject([("message_id", messageID.json)])), to: .users([userID]))
    }
}
