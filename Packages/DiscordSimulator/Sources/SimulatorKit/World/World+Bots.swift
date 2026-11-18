import Foundation

/// How a bot answers a submitted modal: the submitted values by `custom_id` in, its ephemeral reply out.
public typealias ModalResponder = @Sendable (_ values: [String: [String]]) -> String

/// Bot integrations, open modals, and bots set to ignore interactions.
public struct BotState: Sendable {
    /// Bots that never answer, so their interactions fail after Discord's three seconds.
    public var unresponsive: Set<Snowflake> = []
    /// Modals on screen, by the interaction that opened them.
    var openModals: [Snowflake: InteractionRecord] = [:]
    var modalResponders: [String: ModalResponder] = [:]
    /// Integration IDs of bots installed through OAuth2, per guild and application.
    public var integrations: [Snowflake: [Snowflake: Snowflake]] = [:]
}

extension World {
    func setModalResponder(customID: String, _ responder: @escaping ModalResponder) { bots.modalResponders[customID] = responder }

    /// Seeds the integration behind a bot a scenario put in a guild, as if it had been added through OAuth2.
    func registerIntegration(_ botID: Snowflake, in guildID: Snowflake) {
        bots.integrations[guildID, default: [:]][botID] = nextID()
    }

    func setBotResponsive(_ botID: Snowflake, _ responsive: Bool) {
        if responsive { bots.unresponsive.remove(botID) } else { bots.unresponsive.insert(botID) }
    }

    /// INTERACTION_FAILURE (reason 2) once Discord's three-second window passes with no answer from the bot.
    func failInteraction(_ ids: JSONObject, for userID: Snowflake) {
        var failure = ids
        failure["reason_code"] = 2
        Task { [failure] in
            try? await Task.sleep(for: .seconds(3))
            await emit("INTERACTION_FAILURE", .object(failure), to: .users([userID]))
        }
    }

    /// A command whose reply is a modal: INTERACTION_MODAL_CREATE with the bot's application and the form.
    func openModal(_ modal: JSON, interaction: InteractionRecord, applicationID: Snowflake, channelID: Snowflake, nonce: String) async {
        bots.openModals[interaction.id] = interaction
        let application = users[applicationID].map(renderOAuthApplication) ?? .null
        await emit("INTERACTION_MODAL_CREATE", modal.merging([
            "application": application, "channel_id": channelID.json, "id": interaction.id.json, "nonce": .string(nonce),
        ]), to: .users([interaction.userID]))
    }

    /// The modal that a submit (`type` 5) answers; only the user it was shown to can submit it.
    func openModal(for body: JSON, userID: Snowflake) throws -> InteractionRecord {
        guard let id = body["data"]?["id"]?.stringValue.flatMap(Snowflake.init), let modal = bots.openModals[id], modal.userID == userID else {
            throw WorldError.unknown("interaction", code: 10062)
        }
        return modal
    }

    /// A submitted modal: the bot answers with an ephemeral message only the submitter sees.
    func answerModal(_ body: JSON, interactionID: Snowflake, opened: InteractionRecord, applicationID: Snowflake, channelID: Snowflake) async throws {
        bots.openModals[opened.id] = nil
        var values: [String: [String]] = [:]
        for row in body["data"]?["components"]?.arrayValue ?? [] {
            let component = row["component"] ?? row
            guard let customID = component["custom_id"]?.stringValue else { continue }
            values[customID] = component["values"]?.arrayValue?.compactMap(\.stringValue) ?? component["value"]?.stringValue.map { [$0] } ?? []
        }
        let customID = body["data"]?["custom_id"]?.stringValue ?? ""
        var draft = MessageDraft(content: bots.modalResponders[customID]?(values) ?? "")
        draft.type = 20
        draft.flags = 64
        draft.applicationID = applicationID
        draft.interaction = InteractionRecord(id: interactionID, type: 5, name: opened.name, userID: opened.userID, openedBy: opened.id)
        try await sendMessage(draft, as: applicationID, in: channelID, checkPermissions: false)
    }

    // MARK: Installing and removing bots

    private func integrationAudience(_ guild: Guild) -> WorldEvent.Audience {
        .users(Set(guild.members.keys.filter { guild.permissions(of: $0, at: clock.now).contains(.manageGuild) }))
    }

    /// `POST /oauth2/authorize` with the `bot` scope and a `guild_id`: needs Manage Server there.
    func installBot(_ bot: User, in guildID: Snowflake, by userID: Snowflake, scopes: [String]) async throws {
        let guild = try memberGuild(guildID, of: userID)
        guard guild.permissions(of: userID, at: clock.now).contains(.manageGuild) else { throw WorldError.missingPermissions }
        guard guild.members[bot.id] == nil else { return }
        let integrationID = nextID()
        bots.integrations[guildID, default: [:]][bot.id] = integrationID
        let name = bot.globalName ?? bot.username
        await emit("INTEGRATION_CREATE", .object(JSONObject([
            ("guild_id", guildID.json), ("account", .object(JSONObject([("id", bot.id.json), ("name", .string(name))]))),
            ("application", renderOAuthApplication(bot)), ("enabled", true), ("id", integrationID.json), ("name", .string(name)),
            ("scopes", .array(scopes.map(JSON.string))), ("type", "discord"),
        ])), to: integrationAudience(guild))
        await emitCommandIndexUpdate(guildID)
        await emitAuditLog(guildID, action: 80, target: integrationID, by: userID,
                           changes: [auditChange("type", old: nil, new: "discord"), auditChange("name", old: nil, new: .string(name))])
        await emitAuditLog(guildID, action: 28, target: bot.id, by: userID, changes: [])
        try await addMember(bot.id, to: guildID)
    }

    /// `DELETE /guilds/{id}/members/{id}`: a kick. Kicking a bot also removes its integration and its commands.
    func kickMember(_ target: Snowflake, from guildID: Snowflake, by moderator: Snowflake) async throws {
        let guild = try guild(guildID)
        guard guild.members[target] != nil else { throw WorldError.unknown("Member", code: 10007) }
        try requireModeration(.kickMembers, by: moderator, on: target, in: guild)
        let integration = bots.integrations[guildID]?.removeValue(forKey: target)
        if users[target]?.bot == true { await emitCommandIndexUpdate(guildID) }
        if let integration {
            await emit("GUILD_INTEGRATIONS_UPDATE", .object(JSONObject([("guild_id", guildID.json)])), to: integrationAudience(guild))
            await emit("INTEGRATION_DELETE", .object(JSONObject([
                ("guild_id", guildID.json), ("application_id", target.json), ("id", integration.json),
            ])), to: integrationAudience(guild))
        }
        try await removeMember(target, from: guildID)
        if let integration, let bot = users[target] {
            await emitAuditLog(guildID, action: 82, target: integration, by: moderator, changes: [
                auditChange("type", old: "discord", new: nil), auditChange("name", old: .string(bot.globalName ?? bot.username), new: nil),
            ])
        }
        await emitAuditLog(guildID, action: 20, target: target, by: moderator, changes: [])
    }
}
