import SakuraCordModels

struct MessageDeleteDTO: Decodable {
    var id: String
    var channelID: String

    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
    }
}

struct GatewayMessageReactionUserDTO: Decodable {
    var userID: String
    var channelID: String
    var messageID: String
    var emoji: ReactionDTO.EmojiDTO
    var type: Int?
    var burst: Bool?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case channelID = "channel_id"
        case messageID = "message_id"
        case emoji, type, burst
    }

    func domainUpdate(isAddition: Bool) -> MessageReactionUpdate? {
        guard
            let channelID = ChannelID(channelID),
            let messageID = MessageID(messageID),
            let userID = UserID(userID),
            let kind = MessageReactionKind(rawValue: type ?? (burst == true ? 1 : 0))
        else { return nil }
        if isAddition {
            return .add(
                channelID: channelID,
                messageID: messageID,
                userID: userID,
                emoji: emoji.domainToken,
                kind: kind
            )
        }
        return .remove(
            channelID: channelID,
            messageID: messageID,
            userID: userID,
            emoji: emoji.domainToken,
            kind: kind
        )
    }
}

struct GatewayMessageReactionRemoveAllDTO: Decodable {
    var channelID: String
    var messageID: String

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case messageID = "message_id"
    }

    var domainUpdate: MessageReactionUpdate? {
        guard let channelID = ChannelID(channelID), let messageID = MessageID(messageID) else {
            return nil
        }
        return .removeAll(channelID: channelID, messageID: messageID)
    }
}

struct GatewayMessageReactionRemoveEmojiDTO: Decodable {
    var channelID: String
    var messageID: String
    var emoji: ReactionDTO.EmojiDTO

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case messageID = "message_id"
        case emoji
    }

    var domainUpdate: MessageReactionUpdate? {
        guard let channelID = ChannelID(channelID), let messageID = MessageID(messageID) else {
            return nil
        }
        return .removeEmoji(
            channelID: channelID,
            messageID: messageID,
            emoji: emoji.domainToken
        )
    }
}

struct TypingStartDTO: Decodable {
    var channelID: String
    var guildID: String?
    var userID: String
    var member: GuildMemberDTO?
    var user: UserDTO?

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case guildID = "guild_id"
        case userID = "user_id"
        case member, user
    }
}
