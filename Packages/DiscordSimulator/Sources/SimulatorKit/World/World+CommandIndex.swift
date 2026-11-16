import Foundation

/// Slash command catalogues and the command behind a bot's reply. Modern bots
/// share their application's ID, and every demo bot offers the same commands.
extension World {
    static let botCommands = [("gamenight", "Post the next board game night"), ("digest", "Show this week's porch digest")]
    /// `/gamenight game:` suggests from the shelf as you type.
    static let gameShelf = ["Wingspan", "Codenames", "Azul", "Ticket to Ride", "Cascadia", "Just One", "Sushi Go Party!", "Patchwork"]

    enum CommandScope { case user, guild(Snowflake), channel(Snowflake), application(Snowflake) }

    func applicationCommandIndex(_ scope: CommandScope, viewer: Snowflake) throws -> JSON {
        var guildID: Snowflake?
        let bots: [User]
        switch scope {
        case .user:
            bots = botsIn(guilds(of: viewer))
        case let .guild(id):
            guildID = id
            bots = botsIn([try guild(id)])
        case let .channel(id):
            let channel = try channel(id)
            guard canView(viewer, channel) else { throw WorldError.missingAccess }
            guildID = channel.guildID
            bots = channel.guildID.map { botsIn(guilds[$0].map { [$0] } ?? []) } ?? channel.recipients.compactMap { users[$0] }.filter(\.bot)
        case let .application(id):
            guard let bot = users[id], bot.bot else { throw WorldError.unknown("Application", code: 10002) }
            bots = [bot]
        }
        return .object(JSONObject([
            ("applications", .array(bots.map(renderApplication))),
            ("application_commands", .array(bots.flatMap { bot in
                voice.activityApps[bot.id] != nil ? [renderEntryPointCommand(bot.id)]
                    : Self.botCommands.indices.map { renderCommand(bot.id, index: $0, guildID: guildID) }
            })),
            ("version", nextID().json),
        ]))
    }

    private func botsIn(_ guilds: [Guild]) -> [User] {
        Set(guilds.flatMap { $0.members.keys }).compactMap { users[$0] }.filter(\.bot).sorted { $0.id < $1.id }
    }

    private func renderApplication(_ bot: User) -> JSON {
        .object(JSONObject([
            ("id", bot.id.json), ("name", .string(bot.globalName ?? bot.username)), ("description", .string(bot.bio)),
            ("icon", .optional(bot.avatar)), ("bot", renderUser(bot.id)), ("bot_id", bot.id.json), ("flags", "0"), ("embedded_surfaces", []),
        ]))
    }

    private func renderCommand(_ applicationID: Snowflake, index: Int, guildID: Snowflake?) -> JSON {
        let (name, description) = Self.botCommands[index]
        var object = JSONObject([
            ("id", Snowflake(applicationID.rawValue + UInt64(index) + 2).json), ("type", 1), ("application_id", applicationID.json),
            ("version", Snowflake(applicationID.rawValue + 100).json), ("default_member_permissions", .null), ("nsfw", false),
            ("name", .string(name)), ("description", .string(description)), ("dm_permission", true), ("contexts", [0, 1, 2]),
            ("integration_types", [0]),
            ("options", name == "gamenight" ? [.object(JSONObject([
                ("type", 3), ("name", "game"), ("description", "What we're playing"), ("required", false), ("autocomplete", true),
            ]))] : []),
        ])
        if let guildID { object["guild_id"] = guildID.json }
        return .object(object)
    }

    /// `GET /channels/{id}/messages/{id}/interaction-data`: the command a bot's reply answers.
    func interactionData(_ messageID: Snowflake, in channelID: Snowflake) throws -> JSON {
        let message = try message(messageID, in: channelID)
        guard let interaction = message.interaction, interaction.type == 2, let applicationID = message.applicationID,
              let index = Self.botCommands.firstIndex(where: { $0.0 == interaction.name })
        else { throw WorldError.unknown("interaction", code: 10062) }
        let command = renderCommand(applicationID, index: index, guildID: nil)
        return .object(JSONObject([
            ("id", command["id"] ?? .null), ("name", .string(interaction.name)), ("type", 1), ("application_command", command),
        ]))
    }
}
