import SakuraCordModels

struct MessageUpdateDTO: Decodable {
    var id: String
    var channelID: String
    var guildID: String?
    var author: UserDTO?
    var webhookID: String?
    var poll: DiscordPollDTO?
    var content: String?
    var editedTimestamp: String?
    var attachments: LossyList<AttachmentDTO>?
    var embeds: LossyList<MessageEmbedDTO>?
    var components: LossyList<MessageComponentDTO>?
    var stickerItems: LossyList<MessageStickerDTO>?
    var stickers: LossyList<MessageStickerDTO>?
    var thread: MessageThreadDTO?
    var mentions: LossyList<MessageMentionDTO>?
    var mentionRoles: [String]?
    var mentionEveryone: Bool?
    var flags: UInt64?
    var pinned: Bool?
    var type: Int?
    var application: MessageDTO.ApplicationDTO?
    var interaction: MessageDTO.InteractionDTO?
    var interactionMetadata: MessageDTO.InteractionMetadataDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case guildID = "guild_id"
        case author
        case webhookID = "webhook_id"
        case content, poll
        case editedTimestamp = "edited_timestamp"
        case attachments
        case embeds, components, stickers, thread, flags, pinned, type, mentions, application, interaction
        case mentionRoles = "mention_roles"
        case mentionEveryone = "mention_everyone"
        case interactionMetadata = "interaction_metadata"
        case stickerItems = "sticker_items"
    }

    func apply(to message: inout Message) {
        domain(guildID: message.guildID)?.apply(to: &message)
    }

    func domain(guildID: GuildID?) -> MessageUpdate? {
        guard let messageID = MessageID(id), let channelID = ChannelID(channelID) else { return nil }
        let resolvedGuildID = self.guildID.flatMap(GuildID.init) ?? guildID
        var value = MessageUpdate(messageID: messageID, channelID: channelID)
        // A new webhook avatar can arrive after MESSAGE_CREATE. This identity
        // belongs only to this message, never the shared webhook/user cache.
        if webhookID != nil, let author = try? author?.domain(), author.isWebhookIdentity {
            value.webhookAuthor = author
        }
        if let poll { value.pollUpdates = [.snapshot(poll.domain, preservingSelection: true)] }
        value.content = content
        value.editedTimestamp = editedTimestamp.map { DiscordDate.parse($0) }
        value.attachments = attachments.map { $0.elements.compactMap { try? $0.domain() } }
        value.embeds = embeds.map { $0.elements.enumerated().map { $0.element.domain(index: $0.offset) } }
        value.components = components.map { $0.elements.enumerated().map { $0.element.domain(path: "\($0.offset)") } }
        value.stickers = (stickerItems ?? stickers).map { $0.elements.map(\.domain) }
        if let thread = thread?.domain { value.thread = thread }
        value.flags = flags.map(MessageFlags.init(rawValue:))
        value.isPinned = pinned
        value.type = type.map(DiscordMessageType.init(rawValue:))
        value.application = application?.domain
        value.interactionMetadata = MessageDTO.mergedInteractionMetadata(
            interactionMetadata, legacy: interaction, applicationIDFallback: nil
        )
        value.mentionedUsers = mentions.map { $0.elements.compactMap { try? $0.domain(guildID: resolvedGuildID) } }
        value.mentionedRoleIDs = mentionRoles.map { $0.compactMap(RoleID.init) }
        value.mentionsEveryone = mentionEveryone
        return value
    }
}
