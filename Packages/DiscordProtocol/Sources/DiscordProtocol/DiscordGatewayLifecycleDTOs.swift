import Foundation
import SakuraCordModels

struct DiscordTimestampDTO: Decodable {
    var date: Date

    init(date: Date) {
        self.date = date
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let seconds = try? value.decode(Double.self) {
            date = Date(timeIntervalSince1970: seconds)
            return
        }
        let timestamp = try value.decode(String.self)
        guard let parsed = DiscordDate.parse(timestamp) else {
            throw DecodingError.dataCorruptedError(
                in: value, debugDescription: "Expected a Discord timestamp."
            )
        }
        date = parsed
    }
}

struct GatewayGuildPatchDTO: Decodable {
    var id: String
    var name: String?
    var icon: String?
    var owner: Bool?
    var ownerID: String?
    var permissions: String?
    var rulesChannelID: String?
    var defaultMessageNotifications: Int?
    var unavailable: Bool?
    var containsIcon: Bool
    var containsRulesChannelID: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, icon, owner, permissions, unavailable
        case ownerID = "owner_id"
        case rulesChannelID = "rules_channel_id"
        case defaultMessageNotifications = "default_message_notifications"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        owner = try values.decodeIfPresent(Bool.self, forKey: .owner)
        ownerID = try values.decodeIfPresent(String.self, forKey: .ownerID)
        permissions = try values.decodeIfPresent(String.self, forKey: .permissions)
        rulesChannelID = try values.decodeIfPresent(String.self, forKey: .rulesChannelID)
        defaultMessageNotifications = try values.decodeIfPresent(
            Int.self, forKey: .defaultMessageNotifications
        )
        unavailable = try values.decodeIfPresent(Bool.self, forKey: .unavailable)
        containsIcon = values.contains(.icon)
        containsRulesChannelID = values.contains(.rulesChannelID)
    }

    func applying(to existing: Guild?, currentUserID: UserID?) -> Guild? {
        guard let guildID = GuildID(id), let resolvedName = name ?? existing?.name else {
            return nil
        }
        let resolvedIconURL: URL?
        if containsIcon {
            resolvedIconURL = icon.flatMap { hash in
                URL(
                    string:
                    "https://cdn.discordapp.com/icons/\(guildID)/\(hash).webp?size=128&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
                )
            }
        } else {
            resolvedIconURL = existing?.iconURL
        }
        return Guild(
            id: guildID,
            name: resolvedName,
            iconURL: resolvedIconURL,
            accentHex: existing?.accentHex ?? 0x5865F2,
            unreadCount: existing?.unreadCount ?? 0,
            mentionCount: existing?.mentionCount ?? 0,
            isOwnedByCurrentUser: owner
                ?? ownerID.map { $0 == currentUserID?.description }
                ?? existing?.isOwnedByCurrentUser,
            currentUserPermissions: permissions.flatMap(UInt64.init)
                ?? existing?.currentUserPermissions,
            rulesChannelID: containsRulesChannelID
                ? rulesChannelID.flatMap(ChannelID.init)
                : existing?.rulesChannelID,
            defaultMessageNotifications:
                defaultMessageNotifications.flatMap(MessageNotificationLevel.init(rawValue:))
                ?? existing?.defaultMessageNotifications
                ?? .onlyMentions,
            isUnavailable: unavailable ?? existing?.isUnavailable ?? false
        )
    }
}

struct GatewayGuildRoleEventDTO: Decodable {
    var guildID: String
    var role: GuildRoleDTO

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case role
    }
}

struct GatewayGuildRoleDeleteDTO: Decodable {
    var guildID: String
    var roleID: String

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case roleID = "role_id"
    }
}

struct GatewayGuildMemberEventDTO: Decodable {
    var guildID: String
    var member: GuildMemberDTO

    enum CodingKeys: String, CodingKey { case guildID = "guild_id" }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try values.decode(String.self, forKey: .guildID)
        member = try GuildMemberDTO(from: decoder)
    }
}

struct GatewayGuildMemberRemoveDTO: Decodable {
    var guildID: String
    var user: UserDTO

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case user
    }
}

struct GatewayMessageDeleteBulkDTO: Decodable {
    var ids: [String]
    var channelID: String

    enum CodingKeys: String, CodingKey {
        case ids
        case channelID = "channel_id"
    }
}

struct GatewayChannelPinsUpdateDTO: Decodable {
    var guildID: String?
    var channelID: String
    var lastPinTimestamp: String?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case channelID = "channel_id"
        case lastPinTimestamp = "last_pin_timestamp"
    }
}

struct GatewayThreadMembersUpdateDTO: Decodable {
    var id: String
    var guildID: String
    var memberCount: Int
    var addedMembers: [ThreadMemberDTO]?
    var removedMemberIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case guildID = "guild_id"
        case memberCount = "member_count"
        case addedMembers = "added_members"
        case removedMemberIDs = "removed_member_ids"
    }
}

struct GatewayVoiceChannelMetadataDTO: Decodable {
    var guildID: String
    var id: String
    var status: String?
    var voiceStartTime: DiscordTimestampDTO?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case id, status
        case voiceStartTime = "voice_start_time"
    }
}

struct GatewayRateLimitedDTO: Decodable {
    struct Metadata: Decodable {
        var guildID: String?
        var nonce: StringOrIntegerDTO?

        enum CodingKeys: String, CodingKey {
            case guildID = "guild_id"
            case nonce
        }
    }

    var opcode: Int
    var retryAfter: Double
    var metadata: Metadata?

    enum CodingKeys: String, CodingKey {
        case opcode
        case retryAfter = "retry_after"
        case metadata = "meta"
    }
}
