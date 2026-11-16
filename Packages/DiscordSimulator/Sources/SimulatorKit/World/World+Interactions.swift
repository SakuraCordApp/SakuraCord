import Foundation

/// The slash command or component use a bot's message answers.
public struct InteractionRecord: Sendable {
    public var id: Snowflake
    /// 2 for an application command, 3 for a message component.
    public var type: Int
    public var name: String
    public var userID: Snowflake
}

/// What a bot posts when one of its slash commands runs.
public struct CommandReply: Sendable {
    public var content: String
    public var embeds: [JSON]
    public var components: [JSON]

    public init(content: String = "", embeds: [JSON] = [], components: [JSON] = []) {
        self.content = content
        self.embeds = embeds
        self.components = components
    }
}

/// How a bot updates its message when someone presses one of its buttons:
/// the current embeds, the button's `custom_id` and the presser's display
/// name in, the new embeds out.
public typealias ComponentResponder = @Sendable (_ embeds: [JSON], _ customID: String, _ name: String) -> [JSON]

/// Slash commands and buttons, as Discord runs them: the client gets
/// INTERACTION_CREATE, the bot responds, then INTERACTION_SUCCESS. The
/// simulated bots answer from replies a scenario registers.
public extension World {
    func setCommandReply(_ name: String, _ reply: CommandReply) {
        commandReplies[name] = reply
    }

    /// Button presses whose `custom_id` starts with `prefix` update the message through `responder`.
    func setComponentResponder(prefix: String, _ responder: @escaping ComponentResponder) {
        componentResponders[prefix] = responder
    }

    func interact(_ body: JSON, as userID: Snowflake) async throws {
        guard let channelID = body["channel_id"]?.stringValue.flatMap(Snowflake.init),
              let applicationID = body["application_id"]?.stringValue.flatMap(Snowflake.init),
              let nonce = body["nonce"]?.stringValue
        else { throw WorldError.invalidBody("interaction needs channel_id, application_id and nonce") }
        let channel = try channel(channelID)
        guard canView(userID, channel) else { throw WorldError.missingAccess }
        // Modern bots share their application's ID.
        let botID = applicationID
        guard users[botID]?.bot == true else { throw WorldError.unknown("Application", code: 10002) }
        let type = body["type"]?.intValue
        let name = body["data"]?["name"]?.stringValue ?? ""
        let customID = body["data"]?["custom_id"]?.stringValue ?? ""
        let messageID = body["message_id"]?.stringValue.flatMap(Snowflake.init)
        if type == 2, body["data"]?["type"]?.intValue == 4, voice.activityApps[applicationID] != nil {
            return try await launchActivityCommand(applicationID, in: channelID, by: userID, sessionID: body["session_id"]?.stringValue ?? "", nonce: nonce)
        }
        switch type {
        case 2, 4: guard commandReplies[name] != nil else { throw WorldError.unknown("application command", code: 10063) }
        case 3: guard let messageID, !customID.isEmpty, channel.messages.contains(where: { $0.id == messageID }) else {
            throw WorldError.unknown("Message", code: 10008)
        }
        default: throw WorldError.invalidBody("unsupported interaction type")
        }
        let id = nextID()
        let ids = JSONObject([("id", id.json), ("nonce", .string(nonce))])
        await emit("INTERACTION_CREATE", .object(ids), to: .users([userID]))
        if type == 4 {
            // Autocomplete answers with choices for the focused option instead of a message.
            let options = body["data"]?["options"]?.arrayValue ?? []
            let typed = (options.first { $0["focused"]?.boolValue == true }?["value"]?.stringValue ?? "").lowercased()
            let choices = Self.gameShelf.filter { typed.isEmpty || $0.lowercased().contains(typed) }.prefix(25)
            await emit("APPLICATION_COMMAND_AUTOCOMPLETE_RESPONSE", .object(JSONObject([
                ("choices", .array(choices.map { .object(JSONObject([("name", .string($0)), ("value", .string($0))])) })),
                ("nonce", .string(nonce)),
            ])), to: .users([userID]))
        } else if type == 2, let reply = commandReplies[name] {
            var draft = MessageDraft(content: reply.content)
            draft.type = 20
            draft.embeds = reply.embeds
            draft.components = reply.components
            draft.applicationID = applicationID
            draft.interaction = InteractionRecord(id: id, type: 2, name: name, userID: userID)
            try await sendMessage(draft, as: botID, in: channelID, checkPermissions: false)
        } else if let messageID, let responder = componentResponders.first(where: { customID.hasPrefix($0.key) })?.value {
            // Buttons without a responder are acknowledged without a change, like a deferred update.
            let presser = users[userID].map { $0.globalName ?? $0.username } ?? ""
            let now = clock.now
            let updated = try updateMessage(messageID, in: channelID) { message in
                message.embeds = responder(message.embeds, customID, presser)
                message.editedAt = now
            }
            await emit("MESSAGE_UPDATE", renderMessageEvent(updated), to: audience(for: channel))
        }
        await emit("INTERACTION_SUCCESS", .object(ids), to: .users([userID]))
    }
}
