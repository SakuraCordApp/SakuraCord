import Foundation
import SakuraCordModels

struct GatewayMergedPresencesDTO: Decodable {
    var friends: [PresenceUpdateDTO]

    enum CodingKeys: String, CodingKey {
        case friends
    }

    init(friends: [PresenceUpdateDTO] = []) {
        self.friends = friends
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        friends =
            (try? container.decode(
                LossyList<PresenceUpdateDTO>.self,
                forKey: .friends
            ))?.elements ?? []
    }
}

struct PresenceUpdateDTO: Decodable {
    struct PartialUser: Decodable { var id: String }
    var guildID: String?
    var user: PartialUser
    var status: String
    var activities: [GuildActivityDTO]?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case user
        case userID = "user_id"
        case status
        case activities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try container.decodeIfPresent(String.self, forKey: .guildID)
        if let embeddedUser = try container.decodeIfPresent(
            PartialUser.self,
            forKey: .user
        ) {
            user = embeddedUser
        } else {
            user = PartialUser(
                id: try container.decode(String.self, forKey: .userID)
            )
        }
        status = try container.decode(String.self, forKey: .status)
        activities = try container.decodeIfPresent(
            [GuildActivityDTO].self,
            forKey: .activities
        )
    }
}

struct AttachmentReservationDTO: Decodable {
    var attachments: [AttachmentSlotDTO]
}

struct GatewayApplicationCommandIndexUpdateDTO: Decodable {
    var guildID: String
    var version: StringOrIntegerDTO?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case version
    }
}

struct GatewayDeletedEntityDTO: Decodable {
    var id: String
}

struct GatewayChannelRecipientDTO: Decodable {
    var channelID: String
    var user: UserDTO

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case user
    }
}

struct GatewayApplicationCommandAutocompleteDTO: Decodable {
    struct Choice: Decodable {
        var name: String
        var localizedName: String?
        var value: JSONValue

        enum CodingKeys: String, CodingKey {
            case name, value
            case localizedName = "name_localized"
        }

        func domain(optionType: ApplicationCommandOptionType) -> ApplicationCommandChoice? {
            let parsed: ApplicationCommandChoiceValue
            switch (optionType, value) {
            case (.integer, let .number(value))
                where value.isFinite && value.rounded(.towardZero) == value:
                parsed = .integer(Int64(value))
            case (.number, let .number(value)) where value.isFinite:
                parsed = .number(value)
            case (.string, let .string(value)):
                parsed = .string(value)
            default:
                return nil
            }
            return ApplicationCommandChoice(
                name: name, localizedName: localizedName, value: parsed
            )
        }
    }

    var nonce: StringOrIntegerDTO
    var choices: [Choice]
}

struct GatewayInteractionLifecycleDTO: Decodable {
    var id: String?
    var nonce: StringOrIntegerDTO?
    var errorCode: Int?
    var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, nonce
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

struct GatewayInteractionModalDTO: Decodable {
    var nonce: StringOrIntegerDTO
    var applicationID: String
    var channelID: String
    var guildID: String?
    var customID: String
    var title: String
    var components: LossyList<MessageComponentDTO>

    enum CodingKeys: String, CodingKey {
        case nonce, title, components
        case applicationID = "application_id"
        case channelID = "channel_id"
        case guildID = "guild_id"
        case customID = "custom_id"
    }

    var modal: InteractionModal {
        InteractionModal(
            customID: customID,
            title: title,
            controls: components.elements.enumerated().map {
                $0.element.modalControl(path: "modal.\($0.offset)")
            }
        )
    }
}

struct AttachmentSlotDTO: Decodable {
    var id: Int
    var uploadURL: String
    var uploadFilename: String
    enum CodingKeys: String, CodingKey {
        case id
        case uploadURL = "upload_url"
        case uploadFilename = "upload_filename"
    }
}

struct MessageDTO: Decodable {
    struct CallDTO: Decodable {
        var participants: [String]?
        var endedTimestamp: String?

        enum CodingKeys: String, CodingKey {
            case participants
            case endedTimestamp = "ended_timestamp"
        }

        var domain: MessageCall {
            MessageCall(
                participantIDs: (participants ?? []).compactMap(UserID.init),
                endedAt: endedTimestamp.flatMap(DiscordDate.parse)
            )
        }
    }

    struct MemberDTO: Decodable {
        var nick: String?
        var roles: [String]?
        var avatar: String?

        func domain(guildID: GuildID?, userID: UserID) -> MessageGuildMember {
            let nickname = nick?.trimmingCharacters(in: .whitespacesAndNewlines)
            let avatarURL = avatar.flatMap { hash in
                guildID.flatMap {
                    URL(
                        string:
                        "https://cdn.discordapp.com/guilds/\($0)/users/\(userID)/avatars/\(hash).webp?size=128&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
                    )
                }
            }
            return MessageGuildMember(
                nickname: nickname?.isEmpty == false ? nickname : nil,
                roleIDs: (roles ?? []).compactMap(RoleID.init),
                avatarURL: avatarURL
            )
        }
    }

    struct ApplicationDTO: Decodable {
        var id: String
        var name: String
        var description: String?
        var icon: String?
        var bot: UserDTO?

        var domain: ApplicationCommandApplication {
            ApplicationCommandApplication(
                id: id,
                name: name,
                description: description ?? "",
                iconURL: icon.flatMap {
                    URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\($0).webp?size=64")
                },
                bot: bot.flatMap { try? $0.domain() }
            )
        }
    }

    struct InteractionDTO: Decodable {
        var id: String?
        var type: Int?
        var name: String?
        var localizedName: String?
        var user: UserDTO?

        enum CodingKeys: String, CodingKey {
            case id, type, name, user
            case localizedName = "name_localized"
        }
    }

    struct InteractionMetadataDTO: Decodable {
        var id: String?
        var type: Int?
        var name: String?
        var localizedName: String?
        var user: UserDTO?
        var applicationID: String?
        var originalResponseMessageID: String?

        enum CodingKeys: String, CodingKey {
            case id, type, name, user
            case localizedName = "name_localized"
            case applicationID = "application_id"
            case originalResponseMessageID = "original_response_message_id"
        }
    }

    struct ReferenceDTO: Decodable {
        var messageID: String?
        enum CodingKeys: String, CodingKey { case messageID = "message_id" }
    }

    struct ReferencedMessageDTO: Decodable {
        var id: String
        var author: UserDTO?
        var member: MemberDTO?
        var content: String?

        func domain(guildID: GuildID?) -> MessageReplyPreview? {
            guard let messageID = MessageID(id), let author, var user = try? author.domain() else {
                return nil
            }
            let guildMember = member?.domain(guildID: guildID, userID: user.id)
            if let guildMember {
                user.displayName = guildMember.nickname ?? user.displayName
                user.avatarURL = guildMember.avatarURL ?? user.avatarURL
            }
            return MessageReplyPreview(
                messageID: messageID,
                author: user,
                guildMember: guildMember,
                content: content ?? ""
            )
        }
    }

    var id: String
    var channelID: String
    var author: UserDTO?
    var member: MemberDTO?
    var content: String?
    var timestamp: String?
    var editedTimestamp: String?
    var attachments: LossyList<AttachmentDTO>?
    var reactions: LossyList<ReactionDTO>?
    var nonce: StringOrIntegerDTO?
    var messageReference: ReferenceDTO?
    var referencedMessage: ReferencedMessageDTO?
    var type: Int?
    var flags: UInt64?
    var applicationID: String?
    var application: ApplicationDTO?
    var interaction: InteractionDTO?
    var interactionMetadata: InteractionMetadataDTO?
    var guildID: String?
    var embeds: LossyList<MessageEmbedDTO>?
    var components: LossyList<MessageComponentDTO>?
    var stickerItems: LossyList<MessageStickerDTO>?
    var stickers: LossyList<MessageStickerDTO>?
    var thread: MessageThreadDTO?
    var mentions: LossyList<MessageMentionDTO>?
    var mentionRoles: [String]?
    var mentionEveryone: Bool?
    var call: CallDTO?
    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case author, member, content, timestamp
        case editedTimestamp = "edited_timestamp"
        case attachments, reactions, nonce
        case messageReference = "message_reference"
        case referencedMessage = "referenced_message"
        case type, flags, application, interaction, embeds, components, stickers, thread, mentions
        case mentionRoles = "mention_roles"
        case mentionEveryone = "mention_everyone"
        case applicationID = "application_id"
        case interactionMetadata = "interaction_metadata"
        case guildID = "guild_id"
        case stickerItems = "sticker_items"
        case call
    }

    func domain() throws -> Message {
        guard let id = MessageID(id), let channelID = ChannelID(channelID) else {
            throw ChatProviderError.invalidRequest(
                "Discord returned an invalid message identifier.")
        }
        guard let author else {
            throw ChatProviderError.invalidRequest("Discord returned a message without an author.")
        }
        let metadata: MessageInteractionMetadata? = {
            guard interaction != nil || interactionMetadata != nil else { return nil }
            let source = interactionMetadata
            return MessageInteractionMetadata(
                id: source?.id ?? interaction?.id,
                type: source?.type ?? interaction?.type ?? 2,
                name: source?.name ?? interaction?.name,
                localizedName: source?.localizedName ?? interaction?.localizedName,
                user: (source?.user ?? interaction?.user).flatMap { try? $0.domain() },
                applicationID: source?.applicationID ?? applicationID ?? application?.id,
                originalResponseMessageID: source?.originalResponseMessageID.flatMap(MessageID.init)
            )
        }()
        let resolvedGuildID = guildID.flatMap(GuildID.init)
        var resolvedAuthor = try author.domain()
        let resolvedMember = member?.domain(guildID: resolvedGuildID, userID: resolvedAuthor.id)
        resolvedAuthor.displayName = resolvedMember?.nickname ?? resolvedAuthor.displayName
        resolvedAuthor.avatarURL = resolvedMember?.avatarURL ?? resolvedAuthor.avatarURL
        return Message(
            id: id, channelID: channelID, author: resolvedAuthor, guildMember: resolvedMember,
            content: content ?? "",
            timestamp: timestamp.flatMap(DiscordDate.parse) ?? .now,
            editedTimestamp: editedTimestamp.flatMap(DiscordDate.parse),
            replyTo: messageReference?.messageID.flatMap(MessageID.init)
                ?? referencedMessage.flatMap { MessageID($0.id) },
            replyPreview: referencedMessage?.domain(guildID: resolvedGuildID),
            attachments: attachments?.elements.compactMap { try? $0.domain() } ?? [],
            reactions: reactions?.elements.map(\.domain) ?? [],
            nonce: nonce?.value,
            type: DiscordMessageType(rawValue: type ?? 0),
            flags: MessageFlags(rawValue: flags ?? 0),
            applicationID: (applicationID ?? application?.id).flatMap(ApplicationID.init),
            application: application?.domain,
            interactionMetadata: metadata,
            guildID: resolvedGuildID,
            embeds: (embeds?.elements ?? []).enumerated().map {
                $0.element.domain(index: $0.offset)
            },
            components: (components?.elements ?? []).enumerated().map {
                $0.element.domain(path: "\($0.offset)")
            },
            stickers: (stickerItems ?? stickers)?.elements.map(\.domain) ?? [],
            thread: thread?.domain,
            mentionedUsers: mentions?.elements.compactMap {
                try? $0.domain(guildID: resolvedGuildID)
            } ?? [],
            mentionedRoleIDs: (mentionRoles ?? []).compactMap(RoleID.init),
            mentionsEveryone: mentionEveryone ?? false,
            call: call?.domain
        )
    }
}

struct ForumPostDataResponseDTO: Decodable {
    struct ThreadData: Decodable {
        var firstMessage: MessageDTO?
        var mostRecentMessage: MessageDTO?

        enum CodingKeys: String, CodingKey {
            case firstMessage = "first_message"
            case mostRecentMessage = "most_recent_message"
        }
    }

    var threads: [String: ThreadData]
}

struct ForumThreadCatalogueResponseDTO: Decodable {
    var threads: [ChannelDTO]
    fileprivate var members: [ThreadMemberDTO]
    var skippedThreadCount: Int
    var hasMore: Bool
    var totalResults: Int?

    enum CodingKeys: String, CodingKey {
        case threads, members
        case hasMore = "has_more"
        case totalResults = "total_results"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedThreads = try values.decodeIfPresent(
            LossyList<ChannelDTO>.self,
            forKey: .threads
        )
        threads = decodedThreads?.elements ?? []
        members =
            try values.decodeIfPresent(
                LossyList<ThreadMemberDTO>.self,
                forKey: .members
            )?.elements ?? []
        skippedThreadCount = decodedThreads?.skippedCount ?? 0
        hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        totalResults = try values.decodeIfPresent(Int.self, forKey: .totalResults)
    }

    func posts(fallbackGuildID: GuildID?) -> [ForumPost] {
        let membersByThreadID = Dictionary(
            members.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return threads.compactMap { incoming in
            var thread = incoming
            if thread.member == nil {
                thread.member = membersByThreadID[thread.id]
            }
            return try? thread.forumPost(fallbackGuildID: fallbackGuildID)
        }
    }
}

struct ForumThreadSearchResponseDTO: Decodable {
    var threads: [ChannelDTO]
    fileprivate var members: [ThreadMemberDTO]
    fileprivate var firstMessages: [MessageDTO]
    fileprivate var mostRecentMessages: [MessageDTO]
    var hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case threads, members
        case firstMessages = "first_messages"
        case mostRecentMessages = "most_recent_messages"
        case hasMore = "has_more"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        threads =
            try values.decodeIfPresent(LossyList<ChannelDTO>.self, forKey: .threads)?.elements ?? []
        members =
            try values.decodeIfPresent(
                LossyList<ThreadMemberDTO>.self,
                forKey: .members
            )?.elements ?? []
        firstMessages =
            try values.decodeIfPresent(
                LossyList<MessageDTO>.self, forKey: .firstMessages
            )?.elements ?? []
        mostRecentMessages =
            try values.decodeIfPresent(
                LossyList<MessageDTO>.self, forKey: .mostRecentMessages
            )?.elements ?? []
        hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore)
    }

    func posts(fallbackGuildID: GuildID?) -> [ForumPost] {
        let firstByChannel = Dictionary(
            firstMessages.compactMap { dto -> (ChannelID, Message)? in
                guard let message = try? dto.domain() else { return nil }
                return (message.channelID, message)
            },
            uniquingKeysWith: { _, newer in newer }
        )
        let recentByChannel = Dictionary(
            mostRecentMessages.compactMap { dto -> (ChannelID, Message)? in
                guard let message = try? dto.domain() else { return nil }
                return (message.channelID, message)
            },
            uniquingKeysWith: { _, newer in newer }
        )
        let membersByThreadID = Dictionary(
            members.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return threads.compactMap { incoming in
            var thread = incoming
            if thread.member == nil {
                thread.member = membersByThreadID[thread.id]
            }
            guard var post = try? thread.forumPost(fallbackGuildID: fallbackGuildID) else {
                return nil
            }
            post.firstMessage = post.firstMessage ?? firstByChannel[post.id]
            post.mostRecentMessage = recentByChannel[post.id]
            post.owner = post.owner ?? post.firstMessage?.author
            return post
        }
    }
}

enum RichMessageFixtureDecoder {
    static func decodeMessage(from data: Data) throws -> Message {
        try JSONDecoder().decode(MessageDTO.self, from: data).domain()
    }

    static func mergeUpdate(from data: Data, into message: Message) throws -> Message {
        var result = message
        try JSONDecoder().decode(MessageUpdateDTO.self, from: data).apply(to: &result)
        return result
    }
}

struct StringOrIntegerDTO: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = try String(container.decode(UInt64.self))
        }
    }
}

struct AttachmentDTO: Decodable {
    var id: String
    var filename: String
    var url: String
    var proxyURL: String?
    var contentType: String?
    var width: Int?
    var height: Int?
    var size: Int
    var description: String?
    var title: String?
    var placeholder: String?
    var placeholderVersion: Int?
    var durationSeconds: Double?
    var waveform: String?
    var flags: UInt64?
    enum CodingKeys: String, CodingKey {
        case id, filename, url, width, height, size, description, title, placeholder, waveform,
             flags
        case proxyURL = "proxy_url"
        case contentType = "content_type"
        case placeholderVersion = "placeholder_version"
        case durationSeconds = "duration_secs"
    }

    func domain() throws -> Attachment {
        guard let url = URL(string: url) else {
            throw ChatProviderError.invalidRequest("Discord returned an invalid attachment URL.")
        }
        return Attachment(
            id: id, filename: filename, url: url, proxyURL: proxyURL.flatMap(URL.init),
            mediaType: contentType, width: width, height: height, size: size,
            description: description,
            title: title, placeholder: placeholder, placeholderVersion: placeholderVersion,
            durationSeconds: durationSeconds, waveform: waveform,
            flags: AttachmentFlags(rawValue: flags ?? 0)
        )
    }
}

struct ReactionDTO: Decodable {
    struct EmojiDTO: Decodable {
        var id: String?
        var name: String?
        var animated: Bool?

        var domainToken: String {
            id.map {
                "<\(animated == true ? "a" : ""):\(name ?? "emoji"):\($0)>"
            } ?? (name ?? "?")
        }
    }

    var count: Int?
    var me: Bool?
    var meBurst: Bool?
    var emoji: EmojiDTO?

    enum CodingKeys: String, CodingKey {
        case count, me, emoji
        case meBurst = "me_burst"
    }

    var domain: Reaction {
        Reaction(
            emoji: emoji?.domainToken ?? "?",
            count: count ?? 0,
            didCurrentUserReact: me ?? false,
            didCurrentUserBurstReact: meBurst ?? false
        )
    }
}

struct GuildEmojiDTO: Decodable {
    var id: String?
    var name: String?
    var animated: Bool?
    var available: Bool?

    func domain(guildID: GuildID) -> DiscordEmoji? {
        guard let id, let name, !name.isEmpty else { return nil }
        return DiscordEmoji(
            id: id,
            name: name,
            isAnimated: animated ?? false,
            guildID: guildID,
            isAvailable: available ?? true
        )
    }
}

struct EmojiCacheEntry: Codable {
    var fetchedAt: Date
    var emojis: [DiscordEmoji]

    var isFresh: Bool {
        Date.now.timeIntervalSince(fetchedAt) < 7 * 24 * 60 * 60
    }
}

enum DiscordDate {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
