import Foundation

public struct Attachment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var filename: String
    public var url: URL
    public var proxyURL: URL?
    public var mediaType: String?
    public var width: Int?
    public var height: Int?
    public var size: Int
    public var description: String?
    public var title: String?
    public var placeholder: String?
    public var placeholderVersion: Int?
    public var durationSeconds: Double?
    public var waveform: String?
    public var flags: AttachmentFlags
    public var isSpoiler: Bool
    public var isAnimated: Bool

    public var mediaKind: AttachmentMediaKind {
        let type = mediaType?.lowercased() ?? ""
        let path = filename.lowercased()
        if type == "image/gif" || path.hasSuffix(".gif") || flags.contains(.animated) {
            return .animatedImage
        }
        if type.hasPrefix("image/") {
            return .image
        }
        if type.hasPrefix("video/") {
            return .video
        }
        if type.hasPrefix("audio/") || durationSeconds != nil || waveform != nil {
            return .audio
        }
        return .file
    }

    public init(
        id: String, filename: String, url: URL, proxyURL: URL? = nil, mediaType: String? = nil,
        width: Int? = nil, height: Int? = nil, size: Int = 0, description: String? = nil,
        title: String? = nil, placeholder: String? = nil, placeholderVersion: Int? = nil,
        durationSeconds: Double? = nil, waveform: String? = nil, flags: AttachmentFlags = [],
        isSpoiler: Bool? = nil, isAnimated: Bool? = nil
    ) {
        self.id = id
        self.filename = filename
        self.url = url
        self.proxyURL = proxyURL
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.size = size
        self.description = description
        self.title = title
        self.placeholder = placeholder
        self.placeholderVersion = placeholderVersion
        self.durationSeconds = durationSeconds
        self.waveform = waveform
        self.flags = flags
        self.isSpoiler = isSpoiler ?? (filename.hasPrefix("SPOILER_") || flags.contains(.spoiler))
        self.isAnimated =
            isAnimated ?? (mediaType?.lowercased() == "image/gif" || flags.contains(.animated))
    }

    private enum CodingKeys: String, CodingKey {
        case id, filename, url, proxyURL, mediaType, width, height, size, description, title
        case placeholder, placeholderVersion, durationSeconds, waveform, flags, isSpoiler,
             isAnimated
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        filename = try values.decode(String.self, forKey: .filename)
        url = try values.decode(URL.self, forKey: .url)
        proxyURL = try values.decodeIfPresent(URL.self, forKey: .proxyURL)
        mediaType = try values.decodeIfPresent(String.self, forKey: .mediaType)
        width = try values.decodeIfPresent(Int.self, forKey: .width)
        height = try values.decodeIfPresent(Int.self, forKey: .height)
        size = try values.decodeIfPresent(Int.self, forKey: .size) ?? 0
        description = try values.decodeIfPresent(String.self, forKey: .description)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        placeholder = try values.decodeIfPresent(String.self, forKey: .placeholder)
        placeholderVersion = try values.decodeIfPresent(Int.self, forKey: .placeholderVersion)
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
        waveform = try values.decodeIfPresent(String.self, forKey: .waveform)
        flags = try values.decodeIfPresent(AttachmentFlags.self, forKey: .flags) ?? []
        isSpoiler =
            try values.decodeIfPresent(Bool.self, forKey: .isSpoiler)
                ?? (filename.hasPrefix("SPOILER_") || flags.contains(.spoiler))
        isAnimated =
            try values.decodeIfPresent(Bool.self, forKey: .isAnimated)
                ?? (mediaType?.lowercased() == "image/gif" || flags.contains(.animated))
    }
}

public struct ReactionReactor: Identifiable, Codable, Hashable, Sendable {
    public let id: UserID
    public var displayName: String
    public var avatarURL: URL?

    public init(id: UserID, displayName: String, avatarURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    public init(user: User) {
        self.init(id: user.id, displayName: user.displayName, avatarURL: user.avatarURL)
    }
}

public struct Reaction: Identifiable, Codable, Hashable, Sendable {
    public var id: String {
        emojiReference.id.map { "custom:\($0)" } ?? "unicode:\(emoji)"
    }

    public var emoji: String
    public var count: Int
    public var didCurrentUserReact: Bool
    public var didCurrentUserBurstReact: Bool
    public var reactors: [ReactionReactor]

    public var emojiReference: EmojiReference {
        get { EmojiReference(rawToken: emoji) }
        set { emoji = newValue.rawToken }
    }

    public init(
        emoji: String,
        count: Int,
        didCurrentUserReact: Bool = false,
        didCurrentUserBurstReact: Bool = false,
        reactors: [ReactionReactor] = []
    ) {
        self.emoji = emoji
        self.count = count
        self.didCurrentUserReact = didCurrentUserReact
        self.didCurrentUserBurstReact = didCurrentUserBurstReact
        self.reactors = reactors
    }

    private enum CodingKeys: String, CodingKey {
        case emoji, count, didCurrentUserReact, didCurrentUserBurstReact, reactors
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try values.decode(String.self, forKey: .emoji)
        count = try values.decode(Int.self, forKey: .count)
        didCurrentUserReact =
            try values.decodeIfPresent(Bool.self, forKey: .didCurrentUserReact) ?? false
        didCurrentUserBurstReact =
            try values.decodeIfPresent(Bool.self, forKey: .didCurrentUserBurstReact) ?? false
        reactors = try values.decodeIfPresent([ReactionReactor].self, forKey: .reactors) ?? []
    }
}

public enum MessageReactionKind: Int, Codable, Hashable, Sendable {
    case normal = 0
    case burst = 1
}

public enum MessageReactionUpdate: Equatable, Sendable {
    case add(
        channelID: ChannelID,
        messageID: MessageID,
        userID: UserID,
        emoji: String,
        kind: MessageReactionKind
    )
    case remove(
        channelID: ChannelID,
        messageID: MessageID,
        userID: UserID,
        emoji: String,
        kind: MessageReactionKind
    )
    case removeAll(channelID: ChannelID, messageID: MessageID)
    case removeEmoji(channelID: ChannelID, messageID: MessageID, emoji: String)

    /// The affected emoji identity, or nil when all reactions are cleared.
    public var reactionID: String? {
        switch self {
        case .add(_, _, _, let emoji, _), .remove(_, _, _, let emoji, _), .removeEmoji(_, _, let emoji):
            Reaction(emoji: emoji, count: 0).id
        case .removeAll:
            nil
        }
    }

    public var channelID: ChannelID {
        switch self {
        case .add(let channelID, _, _, _, _),
             .remove(let channelID, _, _, _, _),
             .removeAll(let channelID, _),
             .removeEmoji(let channelID, _, _):
            channelID
        }
    }

    public var messageID: MessageID {
        switch self {
        case .add(_, let messageID, _, _, _),
             .remove(_, let messageID, _, _, _),
             .removeAll(_, let messageID),
             .removeEmoji(_, let messageID, _):
            messageID
        }
    }
}

public enum OutboxState: String, Codable, Hashable, Sendable {
    case confirmed, queued, uploading, sending, awaitingReconciliation, failed
}

/// A definite rejection of a local send, independent of guild membership restrictions.
public enum MessageSendFailure: Codable, Hashable, Sendable {
    case autoModeration(explanation: String?)
}

public struct MessageReplyPreview: Codable, Hashable, Sendable {
    public var messageID: MessageID
    public var author: User
    public var webhookID: String?
    public var guildMember: MessageGuildMember?
    public var content: String
    public var mediaKind: AttachmentMediaKind?

    public init(
        messageID: MessageID,
        author: User,
        guildMember: MessageGuildMember? = nil,
        webhookID: String? = nil,
        content: String,
        mediaKind: AttachmentMediaKind? = nil
    ) {
        self.messageID = messageID
        self.author = author
        self.webhookID = webhookID
        self.guildMember = guildMember
        self.content = content
        self.mediaKind = mediaKind
    }

    public init(message: Message) {
        self.init(
            messageID: message.id,
            author: message.author,
            guildMember: message.guildMember,
            webhookID: message.webhookID,
            content: message.content,
            mediaKind: Self.mediaKind(
                attachments: message.attachments,
                embeds: message.embeds,
                stickers: message.stickers
            )
        )
    }

    public static func mediaKind(
        attachments: [Attachment],
        embeds: [MessageEmbed],
        stickers: [MessageSticker]
    ) -> AttachmentMediaKind? {
        attachments.first?.mediaKind
            ?? (embeds.contains(where: { $0.video != nil }) ? .video : nil)
            ?? (embeds.contains(where: { $0.image != nil || $0.thumbnail != nil }) ? .image : nil)
            ?? (stickers.isEmpty ? nil : .image)
    }
}

public struct MessageGuildMember: Codable, Hashable, Sendable {
    public var nickname: String?
    public var roleIDs: [RoleID]
    public var avatarURL: URL?

    public init(nickname: String? = nil, roleIDs: [RoleID] = [], avatarURL: URL? = nil) {
        self.nickname = nickname
        self.roleIDs = roleIDs
        self.avatarURL = avatarURL
    }

    public init(member: Member) {
        self.init(
            nickname: member.globalDisplayName == member.user.displayName
                ? nil
                : member.user.displayName,
            roleIDs: member.roleIDs.isEmpty ? member.roles.map(\.id) : member.roleIDs,
            avatarURL: member.guildAvatarURL
        )
    }

    /// Matches Paicord's partial-member merge: an update that omits member
    /// fields must not erase values already learned from an earlier payload.
    public static func merging(
        incoming: MessageGuildMember?,
        existing: MessageGuildMember?
    ) -> MessageGuildMember? {
        guard var incoming else { return existing }
        guard let existing else { return incoming }
        incoming.nickname = incoming.nickname ?? existing.nickname
        incoming.avatarURL = incoming.avatarURL ?? existing.avatarURL
        if incoming.roleIDs.isEmpty, !existing.roleIDs.isEmpty {
            incoming.roleIDs = existing.roleIDs
        }
        return incoming
    }
}

public struct MessageCall: Codable, Hashable, Sendable {
    public var participantIDs: [UserID]
    public var endedAt: Date?

    public init(participantIDs: [UserID] = [], endedAt: Date? = nil) {
        self.participantIDs = participantIDs
        self.endedAt = endedAt
    }
}

public struct Message: Identifiable, Codable, Hashable, Sendable {
    public let id: MessageID
    public var channelID: ChannelID
    public var author: User
    public var webhookID: String?
    public var guildMember: MessageGuildMember?
    public var content: String
    public var timestamp: Date
    public var editedTimestamp: Date?
    public var replyTo: MessageID?
    public var replyPreview: MessageReplyPreview?
    public var attachments: [Attachment]
    public var reactions: [Reaction]
    public var isPinned: Bool
    public var nonce: String?
    public var outboxState: OutboxState
    public var sendFailure: MessageSendFailure?
    public var canRetrySending: Bool { outboxState == .failed && sendFailure == nil }
    public var type: DiscordMessageType
    public var flags: MessageFlags
    public var applicationID: ApplicationID?
    public var application: ApplicationCommandApplication?
    public var interactionMetadata: MessageInteractionMetadata?
    public var guildID: GuildID?
    public var embeds: [MessageEmbed]
    public var components: [MessageComponent]
    public var stickers: [MessageSticker]
    public var thread: MessageThreadSummary?
    public var mentionedUsers: [User]
    public var mentionedRoleIDs: [RoleID]
    public var mentionsEveryone: Bool
    public var call: MessageCall?
    public var poll: MessagePoll?
    public var hasPoll: Bool
    public var hasActivity: Bool
    public var hasSharedClientTheme: Bool
    public var hasActivityInstance: Bool
    public var messageReference: DiscordMessageReference?
    public var forwardedSnapshot: ForwardedMessageSnapshot?

    public init(
        id: MessageID,
        channelID: ChannelID,
        author: User,
        guildMember: MessageGuildMember? = nil,
        webhookID: String? = nil,
        content: String,
        timestamp: Date = .now,
        editedTimestamp: Date? = nil,
        replyTo: MessageID? = nil,
        replyPreview: MessageReplyPreview? = nil,
        attachments: [Attachment] = [],
        reactions: [Reaction] = [],
        isPinned: Bool = false,
        nonce: String? = nil,
        outboxState: OutboxState = .confirmed,
        sendFailure: MessageSendFailure? = nil,
        type: DiscordMessageType = .default,
        flags: MessageFlags = [],
        applicationID: ApplicationID? = nil,
        application: ApplicationCommandApplication? = nil,
        interactionMetadata: MessageInteractionMetadata? = nil,
        guildID: GuildID? = nil,
        embeds: [MessageEmbed] = [],
        components: [MessageComponent] = [],
        stickers: [MessageSticker] = [],
        thread: MessageThreadSummary? = nil,
        mentionedUsers: [User] = [],
        mentionedRoleIDs: [RoleID] = [],
        mentionsEveryone: Bool = false,
        call: MessageCall? = nil,
        hasPoll: Bool = false,
        poll: MessagePoll? = nil,
        hasActivity: Bool = false,
        hasSharedClientTheme: Bool = false,
        hasActivityInstance: Bool = false,
        messageReference: DiscordMessageReference? = nil,
        forwardedSnapshot: ForwardedMessageSnapshot? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.author = author
        self.webhookID = webhookID
        self.guildMember = guildMember
        self.content = content
        self.timestamp = timestamp
        self.editedTimestamp = editedTimestamp
        self.replyTo = replyTo
        self.replyPreview = replyPreview
        self.attachments = attachments
        self.reactions = reactions
        self.isPinned = isPinned
        self.nonce = nonce
        self.outboxState = outboxState
        self.sendFailure = sendFailure
        self.type = type
        self.flags = flags
        self.applicationID = applicationID
        self.application = application
        self.interactionMetadata = interactionMetadata
        self.guildID = guildID
        self.embeds = embeds
        self.components = components
        self.stickers = stickers
        self.thread = thread
        self.mentionedUsers = mentionedUsers
        self.mentionedRoleIDs = mentionedRoleIDs
        self.mentionsEveryone = mentionsEveryone
        self.call = call
        self.hasPoll = hasPoll || poll != nil
        self.poll = poll
        self.hasActivity = hasActivity
        self.hasSharedClientTheme = hasSharedClientTheme
        self.hasActivityInstance = hasActivityInstance
        self.messageReference = messageReference
        self.forwardedSnapshot = forwardedSnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case id, channelID, author, guildMember, content, timestamp, editedTimestamp, replyTo,
             replyPreview
        case attachments, reactions, isPinned, nonce, outboxState, type, flags, applicationID, application
        case interactionMetadata, guildID, webhookID, sendFailure
        case embeds, components, stickers, thread, mentionedUsers, mentionedRoleIDs, mentionsEveryone
        case call, poll, hasPoll, hasActivity, hasSharedClientTheme, hasActivityInstance
        case messageReference, forwardedSnapshot
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(MessageID.self, forKey: .id)
        channelID = try values.decode(ChannelID.self, forKey: .channelID)
        author = try values.decode(User.self, forKey: .author)
        guildMember = try values.decodeIfPresent(MessageGuildMember.self, forKey: .guildMember)
        webhookID = try values.decodeIfPresent(String.self, forKey: .webhookID)
        content = try values.decodeIfPresent(String.self, forKey: .content) ?? ""
        timestamp = try values.decodeIfPresent(Date.self, forKey: .timestamp) ?? .distantPast
        editedTimestamp = try values.decodeIfPresent(Date.self, forKey: .editedTimestamp)
        replyTo = try values.decodeIfPresent(MessageID.self, forKey: .replyTo)
        replyPreview = try values.decodeIfPresent(MessageReplyPreview.self, forKey: .replyPreview)
        attachments = try values.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        reactions = try values.decodeIfPresent([Reaction].self, forKey: .reactions) ?? []
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        nonce = try values.decodeIfPresent(String.self, forKey: .nonce)
        outboxState =
            try values.decodeIfPresent(OutboxState.self, forKey: .outboxState) ?? .confirmed
        sendFailure = try values.decodeIfPresent(MessageSendFailure.self, forKey: .sendFailure)
        type = try values.decodeIfPresent(DiscordMessageType.self, forKey: .type) ?? .default
        flags = try values.decodeIfPresent(MessageFlags.self, forKey: .flags) ?? []
        applicationID = try values.decodeIfPresent(ApplicationID.self, forKey: .applicationID)
        application = try values.decodeIfPresent(
            ApplicationCommandApplication.self, forKey: .application
        )
        interactionMetadata = try values.decodeIfPresent(
            MessageInteractionMetadata.self, forKey: .interactionMetadata
        )
        guildID = try values.decodeIfPresent(GuildID.self, forKey: .guildID)
        embeds = try values.decodeIfPresent([MessageEmbed].self, forKey: .embeds) ?? []
        components = try values.decodeIfPresent([MessageComponent].self, forKey: .components) ?? []
        stickers = try values.decodeIfPresent([MessageSticker].self, forKey: .stickers) ?? []
        thread = try values.decodeIfPresent(MessageThreadSummary.self, forKey: .thread)
        mentionedUsers = try values.decodeIfPresent([User].self, forKey: .mentionedUsers) ?? []
        mentionedRoleIDs = try values.decodeIfPresent([RoleID].self, forKey: .mentionedRoleIDs) ?? []
        mentionsEveryone = try values.decodeIfPresent(Bool.self, forKey: .mentionsEveryone) ?? false
        call = try values.decodeIfPresent(MessageCall.self, forKey: .call)
        poll = try values.decodeIfPresent(MessagePoll.self, forKey: .poll)
        hasPoll = (try values.decodeIfPresent(Bool.self, forKey: .hasPoll) ?? false) || poll != nil
        hasActivity = try values.decodeIfPresent(Bool.self, forKey: .hasActivity) ?? false
        hasSharedClientTheme =
            try values.decodeIfPresent(Bool.self, forKey: .hasSharedClientTheme) ?? false
        hasActivityInstance =
            try values.decodeIfPresent(Bool.self, forKey: .hasActivityInstance) ?? false
        messageReference = try values.decodeIfPresent(
            DiscordMessageReference.self, forKey: .messageReference
        )
        forwardedSnapshot = try values.decodeIfPresent(
            ForwardedMessageSnapshot.self, forKey: .forwardedSnapshot
        )
    }

    /// Message-local portion of Discord desktop's current forwarding guard.
    /// Source-channel permission and guild gating are evaluated by `AppModel`.
    public var isForwardable: Bool {
        outboxState == .confirmed
            && type.isForwardable
            && !hasPoll
            && !hasActivity
            && !hasSharedClientTheme
            && call == nil
            && !hasActivityInstance
            && flags.subtracting(.forwardingAllowed).isEmpty
    }
}

public struct SendMessageDraft: Equatable, Sendable {
    public static let maximumAttachmentCount = 10

    public var channelID: ChannelID
    public var content: String
    public var replyTo: MessageID?
    public var mentionsRepliedUser: Bool
    public var attachments: [ForumPostAttachment]
    public var attachmentURLs: [URL] {
        get { attachments.map(\.url) }
        set { attachments = newValue.map { ForumPostAttachment(url: $0) } }
    }
    public var nonce: String
    public var stickerIDs: [String]
    public var poll: PollDraft?
    /// Read aloud to members viewing the channel, as Discord's `/tts` sends.
    public var isTTS: Bool
    /// Sends the single attachment as a voice message.
    public var voiceMessage: VoiceMessageMetadata?

    public init(
        channelID: ChannelID, content: String, replyTo: MessageID? = nil,
        mentionsRepliedUser: Bool = true,
        attachmentURLs: [URL] = [],
        attachments: [ForumPostAttachment]? = nil,
        nonce: String = ClientNonce.make(), stickerIDs: [String] = [], poll: PollDraft? = nil,
        isTTS: Bool = false,
        voiceMessage: VoiceMessageMetadata? = nil
    ) {
        self.channelID = channelID
        self.content = content
        self.replyTo = replyTo
        self.mentionsRepliedUser = mentionsRepliedUser
        self.attachments =
            attachments ?? attachmentURLs.map { ForumPostAttachment(url: $0) }
        self.nonce = nonce
        self.stickerIDs = stickerIDs
        self.poll = poll
        self.isTTS = isTTS
        self.voiceMessage = voiceMessage
    }
}

/// The attachment metadata Discord requires on a voice message.
public struct VoiceMessageMetadata: Equatable, Sendable {
    public static let filename = "voice-message.ogg"
    public static let contentType = "audio/ogg; codecs=opus"

    public var durationSeconds: Double
    /// Base64 of 0–255 waveform bins.
    public var waveform: String

    public init(durationSeconds: Double, waveform: String) {
        self.durationSeconds = durationSeconds
        self.waveform = waveform
    }
}
