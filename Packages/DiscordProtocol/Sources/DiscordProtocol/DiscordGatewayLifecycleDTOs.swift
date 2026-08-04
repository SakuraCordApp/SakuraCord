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

struct GatewayGuildPropertiesDTO: Decodable {
    var name: String?
    var icon: String?
    var owner: Bool?
    var ownerID: String?
    var permissions: String?
    var rulesChannelID: String?
    var defaultMessageNotifications: Int?
    var containsIcon: Bool
    var containsRulesChannelID: Bool

    enum CodingKeys: String, CodingKey {
        case name, icon, owner, permissions
        case ownerID = "owner_id"
        case rulesChannelID = "rules_channel_id"
        case defaultMessageNotifications = "default_message_notifications"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try? values.decode(String.self, forKey: .name)
        icon = try? values.decode(String.self, forKey: .icon)
        owner = try? values.decode(Bool.self, forKey: .owner)
        ownerID = try? values.decode(String.self, forKey: .ownerID)
        permissions = try? values.decode(
            StringOrIntegerDTO.self, forKey: .permissions
        ).value
        rulesChannelID = try? values.decode(String.self, forKey: .rulesChannelID)
        defaultMessageNotifications = try? values.decode(
            Int.self, forKey: .defaultMessageNotifications
        )
        containsIcon = values.contains(.icon)
        containsRulesChannelID = values.contains(.rulesChannelID)
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
        case id, name, icon, owner, permissions, unavailable, properties
        case ownerID = "owner_id"
        case rulesChannelID = "rules_channel_id"
        case defaultMessageNotifications = "default_message_notifications"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try? values.decode(
            GatewayGuildPropertiesDTO.self, forKey: .properties
        )
        id = try values.decode(String.self, forKey: .id)
        name = (try? values.decode(String.self, forKey: .name)) ?? nested?.name
        owner = (try? values.decode(Bool.self, forKey: .owner)) ?? nested?.owner
        ownerID = (try? values.decode(String.self, forKey: .ownerID)) ?? nested?.ownerID
        permissions = (try? values.decode(
            StringOrIntegerDTO.self, forKey: .permissions
        ).value) ?? nested?.permissions
        defaultMessageNotifications = (try? values.decode(
            Int.self, forKey: .defaultMessageNotifications
        )) ?? nested?.defaultMessageNotifications
        unavailable = try? values.decode(Bool.self, forKey: .unavailable)
        if values.contains(.icon) {
            icon = try? values.decode(String.self, forKey: .icon)
            containsIcon = true
        } else {
            icon = nested?.icon
            containsIcon = nested?.containsIcon ?? false
        }
        if values.contains(.rulesChannelID) {
            rulesChannelID = try? values.decode(String.self, forKey: .rulesChannelID)
            containsRulesChannelID = true
        } else {
            rulesChannelID = nested?.rulesChannelID
            containsRulesChannelID = nested?.containsRulesChannelID ?? false
        }
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
