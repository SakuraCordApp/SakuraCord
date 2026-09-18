import Foundation

public enum DiscordMessageReferenceType: Int, Codable, Hashable, Sendable {
    case reply = 0
    case forward = 1
}

public struct DiscordMessageReference: Codable, Hashable, Sendable {
    public var type: DiscordMessageReferenceType
    public var messageID: MessageID?
    public var channelID: ChannelID?
    public var guildID: GuildID?

    public init(
        type: DiscordMessageReferenceType,
        messageID: MessageID? = nil,
        channelID: ChannelID? = nil,
        guildID: GuildID? = nil
    ) {
        self.type = type
        self.messageID = messageID
        self.channelID = channelID
        self.guildID = guildID
    }
}

/// Discord's immutable, authorless copy of a message at forwarding time.
/// Snapshots deliberately do not contain another snapshot, limiting forwards
/// to the one level supported by Discord's message contract.
public struct ForwardedMessageSnapshot: Codable, Hashable, Sendable {
    public var type: DiscordMessageType
    public var content: String
    public var timestamp: Date
    public var editedTimestamp: Date?
    public var flags: MessageFlags
    public var attachments: [Attachment]
    public var embeds: [MessageEmbed]
    public var components: [MessageComponent]
    public var stickers: [MessageSticker]
    public var mentionedUsers: [User]
    public var mentionedRoleIDs: [RoleID]

    public init(
        type: DiscordMessageType = .default,
        content: String = "",
        timestamp: Date,
        editedTimestamp: Date? = nil,
        flags: MessageFlags = [],
        attachments: [Attachment] = [],
        embeds: [MessageEmbed] = [],
        components: [MessageComponent] = [],
        stickers: [MessageSticker] = [],
        mentionedUsers: [User] = [],
        mentionedRoleIDs: [RoleID] = []
    ) {
        self.type = type
        self.content = content
        self.timestamp = timestamp
        self.editedTimestamp = editedTimestamp
        self.flags = flags
        self.attachments = attachments
        self.embeds = embeds
        self.components = components
        self.stickers = stickers
        self.mentionedUsers = mentionedUsers
        self.mentionedRoleIDs = mentionedRoleIDs
    }
}

public struct ForwardMessageDraft: Equatable, Sendable {
    public var sourceMessageID: MessageID
    public var sourceChannelID: ChannelID
    public var sourceGuildID: GuildID?
    public var destinationChannelID: ChannelID
    public var nonce: String

    public init(
        sourceMessageID: MessageID,
        sourceChannelID: ChannelID,
        sourceGuildID: GuildID?,
        destinationChannelID: ChannelID,
        nonce: String = ClientNonce.make()
    ) {
        self.sourceMessageID = sourceMessageID
        self.sourceChannelID = sourceChannelID
        self.sourceGuildID = sourceGuildID
        self.destinationChannelID = destinationChannelID
        self.nonce = nonce
    }
}
