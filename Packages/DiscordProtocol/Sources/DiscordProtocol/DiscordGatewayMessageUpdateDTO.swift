import SakuraCordModels

struct MessageUpdateDTO: Decodable {
    var id: String
    var channelID: String
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
        case content
        case editedTimestamp = "edited_timestamp"
        case attachments
        case embeds, components, stickers, thread, flags, pinned, type, mentions, application, interaction
        case mentionRoles = "mention_roles"
        case mentionEveryone = "mention_everyone"
        case interactionMetadata = "interaction_metadata"
        case stickerItems = "sticker_items"
    }

    func apply(to message: inout Message) {
        if let content {
            message.content = content
        }
        if let editedTimestamp {
            message.editedTimestamp = DiscordDate.parse(editedTimestamp)
        }
        if let attachments {
            message.attachments = attachments.elements.compactMap { try? $0.domain() }
        }
        if let embeds {
            message.embeds = embeds.elements.enumerated().map {
                $0.element.domain(index: $0.offset)
            }
        }
        if let components {
            message.components = components.elements.enumerated().map {
                $0.element.domain(path: "\($0.offset)")
            }
        }
        if let stickers = stickerItems ?? stickers {
            message.stickers = stickers.elements.map(\.domain)
        }
        if let thread {
            message.thread = thread.domain
        }
        if let flags {
            message.flags = MessageFlags(rawValue: flags)
        }
        if let pinned {
            message.isPinned = pinned
        }
        if let type {
            message.type = DiscordMessageType(rawValue: type)
        }
        if let application {
            message.application = application.domain
            message.applicationID = ApplicationID(application.id)
        }
        if interaction != nil || interactionMetadata != nil {
            message.interactionMetadata = MessageInteractionMetadata(
                id: interactionMetadata?.id ?? interaction?.id,
                type: interactionMetadata?.type ?? interaction?.type ?? 2,
                name: interactionMetadata?.name ?? interaction?.name,
                localizedName: interactionMetadata?.localizedName ?? interaction?.localizedName,
                user: (interactionMetadata?.user ?? interaction?.user).flatMap { try? $0.domain() },
                applicationID: interactionMetadata?.applicationID
                    ?? message.applicationID?.description,
                originalResponseMessageID: interactionMetadata?.originalResponseMessageID.flatMap(
                    MessageID.init
                )
            )
        }
        if let mentions {
            message.mentionedUsers = mentions.elements.compactMap {
                try? $0.domain(guildID: message.guildID)
            }
        }
        if let mentionRoles {
            message.mentionedRoleIDs = mentionRoles.compactMap(RoleID.init)
        }
        if let mentionEveryone {
            message.mentionsEveryone = mentionEveryone
        }
    }
}
