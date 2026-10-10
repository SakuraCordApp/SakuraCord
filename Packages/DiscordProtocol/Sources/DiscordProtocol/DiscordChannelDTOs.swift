import Foundation
import SakuraCordModels

struct ThreadMemberDTO: Decodable {
    struct MuteConfigDTO: Decodable {
        var endTime: String?

        enum CodingKeys: String, CodingKey {
            case endTime = "end_time"
        }
    }

    // Discord omits both identifiers when a thread member is embedded in a
    // channel object from READY/GUILD_CREATE. They are present on standalone
    // thread-member events and list responses.
    var id: String?
    var userID: String?
    var flags: UInt64?
    var muted: Bool?
    var muteConfig: MuteConfigDTO?
    var joinTimestamp: String?
    var member: GuildMemberDTO?
    var presence: GuildPresenceDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case flags, muted, member, presence
        case muteConfig = "mute_config"
        case joinTimestamp = "join_timestamp"
    }

    var domain: ThreadNotificationSettings {
        ThreadNotificationSettings(
            flags: flags ?? 0,
            isMuted: muted ?? false,
            muteConfiguration: muteConfig.map {
                DiscordMuteConfiguration(
                    endTime: $0.endTime.flatMap(DiscordDate.parse)
                )
            },
            joinedAt: joinTimestamp.flatMap(DiscordDate.parse)
        )
    }
}

struct ChannelDTO: Decodable {
    /// Most channels have no embedded starter message. Keeping its large
    /// value inline also reserves that space for every empty dictionary slot.
    /// Immutable storage preserves value semantics when a ChannelDTO is copied.
    private final class EmbeddedMessage: Decodable {
        let value: MessageDTO

        init(_ value: MessageDTO) {
            self.value = value
        }

        init(from decoder: any Decoder) throws {
            value = try MessageDTO(from: decoder)
        }
    }

    struct PermissionOverwriteDTO: Decodable {
        var id: String
        var type: Int
        var allow: String
        var deny: String

        var domain: ChannelPermissionOverwrite {
            ChannelPermissionOverwrite(
                id: id,
                type: type,
                allow: UInt64(allow) ?? 0,
                deny: UInt64(deny) ?? 0
            )
        }
    }

    struct ForumTagDTO: Decodable {
        var id: String
        var name: String
        var moderated: Bool?
        var emojiID: String?
        var emojiName: String?

        enum CodingKeys: String, CodingKey {
            case id, name, moderated
            case emojiID = "emoji_id"
            case emojiName = "emoji_name"
        }

        var domain: ForumTag? {
            guard let id = ForumTagID(id) else { return nil }
            return ForumTag(
                id: id, name: name, isModerated: moderated ?? false,
                emojiID: emojiID, emojiName: emojiName
            )
        }
    }

    struct DefaultReactionDTO: Decodable {
        var emojiID: String?
        var emojiName: String?

        enum CodingKeys: String, CodingKey {
            case emojiID = "emoji_id"
            case emojiName = "emoji_name"
        }
    }

    struct ThreadMetadataDTO: Decodable {
        var archived: Bool?
        var locked: Bool?
        var archiveTimestamp: String?
        var createTimestamp: String?
        var autoArchiveDuration: Int?

        enum CodingKeys: String, CodingKey {
            case archived, locked
            case archiveTimestamp = "archive_timestamp"
            case createTimestamp = "create_timestamp"
            case autoArchiveDuration = "auto_archive_duration"
        }
    }

    var id: String
    var guildID: String?
    var name: String?
    var icon: String?
    var topic: String?
    var nsfw: Bool?
    var type: Int
    var parentID: String?
    var position: Int?
    var recipients: [UserDTO]?
    var recipientIDs: [String]?
    var permissionOverwrites: [PermissionOverwriteDTO]?
    var memberListID: String?
    var lastMessageID: String?
    var lastPinTimestamp: String?
    var ownerID: String?
    var owner: LossyValue<UserDTO>?
    var messageCount: Int?
    var memberCount: Int?
    var totalMessageSent: Int?
    var threadMetadata: ThreadMetadataDTO?
    var lastNonMessageActivityTimestamp: String?
    var appliedTags: [String]?
    var flags: UInt64?
    var member: ThreadMemberDTO?
    // Forum and media channel metadata is decoded leniently: guild channel
    // lists are lossy per channel, so one unexpected tag or reaction shape
    // would otherwise drop the whole forum from the sidebar.
    var availableTags: LossyList<ForumTagDTO>?
    var defaultReactionEmoji: LossyValue<DefaultReactionDTO>?
    var defaultSortOrder: LossyValue<Int>?
    var defaultForumLayout: LossyValue<Int>?
    var defaultTagSetting: LossyValue<String>?
    var defaultAutoArchiveDuration: Int?
    var defaultThreadRateLimitPerUser: Int?
    var rateLimitPerUser: Int?
    var status: String?
    var voiceStartTime: DiscordTimestampDTO?
    private var embeddedMessage: EmbeddedMessage?

    var message: MessageDTO? {
        get { embeddedMessage?.value }
        set { embeddedMessage = newValue.map(EmbeddedMessage.init) }
    }

    /// Guild thread records carry the latest message shown in a thread card.
    private var embeddedMostRecentMessage: EmbeddedMessage?
    var mostRecentMessage: MessageDTO? {
        get { embeddedMostRecentMessage?.value }
        set { embeddedMostRecentMessage = newValue.map(EmbeddedMessage.init) }
    }

    var isThread: Bool {
        switch type {
        case 10, 11, 12: true
        default: false
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case guildID = "guild_id"
        case name, icon, topic, type, nsfw
        case parentID = "parent_id"
        case position, recipients
        case recipientIDs = "recipient_ids"
        case permissionOverwrites = "permission_overwrites"
        case memberListID = "member_list_id"
        case lastMessageID = "last_message_id"
        case lastPinTimestamp = "last_pin_timestamp"
        case lastNonMessageActivityTimestamp = "last_non_message_activity_timestamp"
        case ownerID = "owner_id"
        case owner, flags, member
        case embeddedMessage = "message"
        case embeddedMostRecentMessage = "most_recent_message"
        case messageCount = "message_count"
        case memberCount = "member_count"
        case totalMessageSent = "total_message_sent"
        case threadMetadata = "thread_metadata"
        case appliedTags = "applied_tags"
        case availableTags = "available_tags"
        case defaultReactionEmoji = "default_reaction_emoji"
        case defaultSortOrder = "default_sort_order"
        case defaultForumLayout = "default_forum_layout"
        case defaultTagSetting = "default_tag_setting"
        case defaultAutoArchiveDuration = "default_auto_archive_duration"
        case defaultThreadRateLimitPerUser = "default_thread_rate_limit_per_user"
        case rateLimitPerUser = "rate_limit_per_user"
        case status
        case voiceStartTime = "voice_start_time"
    }

    func domain(
        guildID fallbackGuildID: GuildID?,
        categoryName: String? = nil,
        categoryPosition: Int = 0,
        knownUsersByID: [String: UserDTO] = [:]
    ) throws -> Channel {
        let channelIDString = id
        guard let id = ChannelID(id) else {
            throw ChatProviderError.invalidRequest(
                "Discord returned an invalid channel identifier.")
        }
        let guild = guildID.flatMap(GuildID.init) ?? fallbackGuildID
        let unresolvedRecipientDTOs =
            recipients
            ?? recipientIDs?.compactMap { knownUsersByID[$0] }
            ?? []
        let recipientDTOs = DiscordPrivateRecipientOrdering.sortedUsers(
            unresolvedRecipientDTOs,
            channelID: channelIDString,
            channelType: type
        )
        let users = try recipientDTOs.map { try $0.domain() }
        let kind: ChannelKindValue =
            switch type {
            case 1: .directMessage
            case 3: .groupDirectMessage
            case 2, 13: .voice
            case 5: .announcement
            // Media channels (16) share the forum-style surface locally. The
            // distinction is not yet rendered separately, but retaining them
            // as non-text destinations is required for forwarding eligibility.
            case 15, 16: .forum
            default: .text
            }
        let explicitName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipientName = users.map(\.displayName).joined(separator: ", ")
        let ownerGroupName = ownerID
            .flatMap { knownUsersByID[$0] }
            .flatMap { try? $0.domain().displayName }
            .map { "\($0)'s Group" }
        let resolvedName: String
        if let explicitName, !explicitName.isEmpty {
            resolvedName = explicitName
        } else if !recipientName.isEmpty {
            resolvedName = recipientName
        } else if type == 3, let ownerGroupName {
            resolvedName = ownerGroupName
        } else {
            resolvedName = type == 3 ? "Group Direct Message" : "Direct Message"
        }
        let iconURL = icon.flatMap { hash in
            URL(
                string:
                    "https://cdn.discordapp.com/channel-icons/\(id)/\(hash).webp?size=128"
            )
        }
        return Channel(
            id: id,
            guildID: guild,
            name: resolvedName,
            hasExplicitName: explicitName?.isEmpty == false,
            iconURL: iconURL,
            ownerID: ownerID.flatMap(UserID.init),
            topic: topic,
            kind: kind,
            category: categoryName,
            categoryID: parentID.flatMap(ChannelID.init),
            position: position ?? 0,
            categoryPosition: categoryPosition,
            isAgeRestricted: nsfw ?? false,
            recipients: users,
            permissionOverwrites: permissionOverwrites?.map(\.domain),
            memberListID: memberListID,
            lastMessageID: lastMessageID.flatMap(MessageID.init),
            lastPinTimestamp: lastPinTimestamp.flatMap(DiscordDate.parse),
            flags: flags ?? 0,
            availableTags: availableTags?.elements.compactMap(\.domain) ?? [],
            defaultReaction: defaultReactionEmoji?.value.map {
                ForumDefaultReaction(emojiID: $0.emojiID, emojiName: $0.emojiName)
            },
            defaultSortOrder: defaultSortOrder?.value.flatMap(ForumSortOrder.init(rawValue:)),
            defaultForumLayout: defaultForumLayout?.value.flatMap(ForumLayout.init(rawValue:))
                ?? .defaultLayout,
            defaultTagMatch: defaultTagSetting?.value.flatMap(ForumTagMatch.init(rawValue:)) ?? .matchSome,
            defaultAutoArchiveDuration: defaultAutoArchiveDuration,
            defaultThreadRateLimitPerUser: defaultThreadRateLimitPerUser,
            rateLimitPerUser: rateLimitPerUser ?? 0,
            voiceStatus: status,
            voiceStartTime: voiceStartTime?.date
        )
    }

    func forumPost(fallbackGuildID: GuildID?) throws -> ForumPost {
        guard let id = ChannelID(id) else {
            throw ChatProviderError.invalidRequest(
                "Discord returned an invalid forum post identifier.")
        }
        let guild = guildID.flatMap(GuildID.init) ?? fallbackGuildID
        // Forum search records can contain a deliberately partial embedded owner
        // or starter message. The thread itself is still a valid search result;
        // the parallel first_messages payload and Gateway user cache hydrate what
        // Discord omitted without dropping the post.
        let ownerUser = owner?.value.flatMap { try? $0.domain() }
        let firstMessage = message.flatMap { try? $0.domain() }
        return ForumPost(
            thread: MessageThreadSummary(
                id: id,
                guildID: guild,
                parentID: parentID.flatMap(ChannelID.init),
                name: name ?? "Untitled post",
                messageCount: messageCount ?? totalMessageSent ?? (firstMessage == nil ? 0 : 1),
                memberCount: memberCount ?? 0,
                lastMessageID: lastMessageID.flatMap(MessageID.init),
                isArchived: threadMetadata?.archived ?? false,
                isLocked: threadMetadata?.locked ?? false,
                ownerID: ownerID.flatMap(UserID.init) ?? ownerUser?.id,
                appliedTagIDs: appliedTags?.compactMap(ForumTagID.init) ?? [],
                flags: flags ?? 0,
                archiveTimestamp: threadMetadata?.archiveTimestamp.flatMap(DiscordDate.parse),
                createdAt: threadMetadata?.createTimestamp.flatMap(DiscordDate.parse),
                autoArchiveDuration: threadMetadata?.autoArchiveDuration,
                totalMessageSent: totalMessageSent ?? messageCount ?? 0,
                notificationSettings: member?.domain,
                rateLimitPerUser: rateLimitPerUser ?? 0,
                lastNonMessageActivityAt: lastNonMessageActivityTimestamp.flatMap(DiscordDate.parse),
                isPrivate: type == 12
            ),
            owner: ownerUser ?? firstMessage?.author,
            firstMessage: firstMessage,
            mostRecentMessage: mostRecentMessage.flatMap { try? $0.domain() },
            isUnread: false
        )
    }
}

/// Discord's private-channel model does not preserve the server's recipient
/// array order. It orders each recipient by the signed 32-bit result of the
/// JavaScript expressions `parseInt(userID) ^ parseInt(channelID)`. Parsing via
/// `Double` intentionally preserves JavaScript's precision loss for snowflakes.
enum DiscordPrivateRecipientOrdering {
    static func sortedUsers(
        _ users: [UserDTO],
        channelID: String,
        channelType: Int
    ) -> [UserDTO] {
        guard channelType == 1 || channelType == 3 else { return users }
        return stableSort(users, channelID: channelID, id: \UserDTO.id)
    }

    static func sortedIDs(
        _ ids: [String],
        channelID: String,
        channelType: Int
    ) -> [String] {
        guard channelType == 1 || channelType == 3 else { return ids }
        return stableSort(ids, channelID: channelID, id: { $0 })
    }

    static func sortedDomainUsers(
        _ users: [User],
        channelID: String,
        channelType: Int
    ) -> [User] {
        guard channelType == 1 || channelType == 3 else { return users }
        return stableSort(users, channelID: channelID, id: { $0.id.description })
    }

    private static func stableSort<Value>(
        _ values: [Value],
        channelID: String,
        id: (Value) -> String
    ) -> [Value] {
        let channelBits = javascriptInt32Bits(channelID)
        return values.enumerated().sorted { lhs, rhs in
            let left = Int32(bitPattern: javascriptInt32Bits(id(lhs.element)) ^ channelBits)
            let right = Int32(bitPattern: javascriptInt32Bits(id(rhs.element)) ^ channelBits)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func javascriptInt32Bits(_ value: String) -> UInt32 {
        guard let parsed = Double(value), parsed.isFinite else { return 0 }
        let modulus = 4_294_967_296.0
        var remainder = parsed.rounded(.towardZero)
            .truncatingRemainder(dividingBy: modulus)
        if remainder < 0 { remainder += modulus }
        return UInt32(remainder)
    }
}
