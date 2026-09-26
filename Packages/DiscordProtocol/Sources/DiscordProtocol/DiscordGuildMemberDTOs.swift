import Foundation
import SakuraCordModels

struct GuildDTO: Decodable {
    var id: String
    var name: String
    var icon: String?
    var homeHeader: String?
    var owner: Bool?
    var permissions: String?
    var rulesChannelID: String?
    var features: Set<String>?
    var profile: GuildProfileTagDTO?
    var defaultMessageNotifications: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, owner, permissions, features, profile
        case homeHeader = "home_header"
        case rulesChannelID = "rules_channel_id"
        case defaultMessageNotifications = "default_message_notifications"
    }

    func domain() throws -> Guild {
        guard let id = GuildID(id) else {
            throw ChatProviderError.invalidRequest("Discord returned an invalid guild identifier.")
        }
        let iconURL = icon.flatMap { hash in
            URL(
                string:
                "https://cdn.discordapp.com/icons/\(id)/\(hash).webp?size=128&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
            )
        }
        return Guild(
            id: id,
            name: name,
            iconURL: iconURL,
            isOwnedByCurrentUser: owner,
            currentUserPermissions: permissions.flatMap(UInt64.init),
            rulesChannelID: rulesChannelID.flatMap(ChannelID.init),
            features: features ?? [],
            guideHeaderURL: homeHeader.flatMap { URL(string: "https://cdn.discordapp.com/home-headers/\(id)/\($0).png?size=2048") },
            profileTag: profile?.domain(guildID: id),
            defaultMessageNotifications:
                defaultMessageNotifications.flatMap(MessageNotificationLevel.init(rawValue:))
                ?? .onlyMentions
        )
    }
}

struct GuildActivityEmojiDTO: Decodable {
    var name: String?
    var id: String?
    var animated: Bool?
}

struct GuildActivityDTO: Decodable {
    var name: String?
    var type: Int?
    var state: String?
    var emoji: GuildActivityEmojiDTO?

    var displayText: String? {
        let activityState = state.flatMap { $0.isEmpty ? nil : $0 }
        if type == 4 {
            let emojiText = emoji.flatMap { emoji -> String? in
                if let id = emoji.id {
                    return "<\(emoji.animated == true ? "a" : ""):\(emoji.name ?? "emoji"):\(id)>"
                }
                return emoji.name
            }
            let parts = [emojiText, activityState].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        return activityState ?? name
    }
}

extension [GuildActivityDTO] {
    var memberListActivity: GuildActivityDTO? {
        first(where: { $0.type == 2 }) ?? first(where: { $0.type != 4 })
    }
}

struct GuildPresenceDTO: Decodable {
    var status: String?
    var activities: [GuildActivityDTO]?
}

struct GuildMemberDTO: Decodable {
    var user: UserDTO
    var nick: String?
    var roles: [String]?
    var presence: GuildPresenceDTO?
    var avatar: String?
    var banner: String?
    var bio: String?
    var pending: Bool?
    var flags: UInt64?
    var joinedAt: String?
    var avatarDecorationData: UserDTO.AvatarDecorationDTO?
    var collectibles: UserCollectiblesDTO?
    var displayNameStyles: UserDTO.DisplayNameStyleDTO?

    enum CodingKeys: String, CodingKey {
        case user, nick, roles, presence, avatar, banner, bio, pending, flags, collectibles
        case joinedAt = "joined_at"
        case avatarDecorationData = "avatar_decoration_data"
        case displayNameStyles = "display_name_styles"
    }

    func domain(
        currentUserID: UserID?,
        currentStatus: PresenceStatus,
        presence overridePresence: GuildPresenceDTO? = nil,
        guildRoles: [GuildRoleDTO] = [],
        guildRoleCatalog: GuildMemberRoleCatalog? = nil,
        guildID: GuildID? = nil
    ) throws -> Member {
        var domainUser = try user.domain()
        let globalDisplayName = domainUser.displayName
        var scopedDTO = user
        scopedDTO.avatarDecorationData = avatarDecorationData
        scopedDTO.collectibles = collectibles
        scopedDTO.displayNameStyles = displayNameStyles
        let scopedUser = try scopedDTO.domain()
        let cosmetics = GuildProfileCosmetics(
            avatarDecorationURL: scopedUser.avatarDecorationURL,
            nameplate: scopedUser.nameplate,
            displayNameStyle: scopedUser.displayNameStyle
        )
        domainUser = cosmetics.applying(to: domainUser)
        if let nick, !nick.isEmpty {
            domainUser.displayName = nick
        }
        let guildAvatarURL = guildAvatarURL(guildID: guildID, userID: domainUser.id)
        if let guildAvatarURL {
            domainUser.avatarURL = guildAvatarURL
        }
        let status =
            domainUser.id == currentUserID
                ? currentStatus
                : (overridePresence ?? presence)?.status.flatMap(PresenceStatus.init(rawValue:))
                ?? .offline
        let memberRoleIDs = Set(roles ?? [])
        let catalogEntries = guildRoleCatalog?.entries(matching: memberRoleIDs)
        let matchingRoles = catalogEntries?.map(\.dto)
            ?? guildRoles.filter { memberRoleIDs.contains($0.id) }
        let categoryRole = matchingRoles
                .filter(\.hoist)
                .max { lhs, rhs in
                    if lhs.position != rhs.position {
                        return lhs.position < rhs.position
                    }
                    return lhs.id < rhs.id
                }
        let domainRoles = if let catalogEntries {
            catalogEntries
                .sorted { $0.dto.position > $1.dto.position }
                .compactMap(\.domain)
        } else {
            matchingRoles
                .sorted { $0.position > $1.position }
                .compactMap(\.domain)
        }
        let activities = (overridePresence ?? presence)?.activities ?? []
        let customStatus = activities.first(where: { $0.type == 4 })?.displayText
        let primaryActivity = activities.memberListActivity
        return Member(
            user: domainUser,
            roleName: categoryRole?.name ?? "Member",
            status: status,
            roleID: categoryRole.flatMap { RoleID($0.id) },
            rolePosition: categoryRole?.position,
            isRoleCategory: categoryRole != nil,
            roleIDs: (roles ?? []).compactMap(RoleID.init),
            roles: domainRoles,
            guildAvatarURL: guildAvatarURL,
            globalDisplayName: globalDisplayName,
            guildNickname: nick,
            guildProfileCosmetics: cosmetics,
            activityText: primaryActivity?.displayText ?? customStatus,
            customStatus: customStatus,
            isListeningToMusic: primaryActivity?.type == 2,
            isPending: pending,
            flags: flags,
            joinedAt: joinedAt.flatMap(DiscordDate.parse)
        )
    }

    private func guildAvatarURL(guildID: GuildID?, userID: UserID) -> URL? {
        guard let avatar, let guildID else { return nil }
        return URL(
            string:
            "https://cdn.discordapp.com/guilds/\(guildID)/users/\(userID)/avatars/\(avatar).webp?size=128&animated=\(avatar.hasPrefix("a_") ? "true" : "false")"
        )
    }
}

struct GuildRoleColorsDTO: Decodable {
    var primaryColor: UInt32?

    enum CodingKeys: String, CodingKey {
        case primaryColor = "primary_color"
    }
}

struct GuildRoleDTO: Decodable {
    var id: String
    var name: String
    var position: Int
    var hoist: Bool
    var color: UInt32?
    private var colors: GuildRoleColorsDTO?
    var icon: String?
    var unicodeEmoji: String?
    var mentionable: Bool?
    var permissions: String?
    enum CodingKeys: String, CodingKey {
        case id, name, position, hoist, color, colors, icon
        case unicodeEmoji = "unicode_emoji"
        case mentionable, permissions
    }

    var domain: GuildRole? {
        guard let id = RoleID(id) else { return nil }
        let colorHex = colors?.primaryColor.flatMap { $0 == 0 ? nil : $0 }
            ?? color.flatMap { $0 == 0 ? nil : $0 }
        let iconURL = icon.flatMap {
            URL(string: "https://cdn.discordapp.com/role-icons/\(id)/\($0).png?size=32")
        }
        return GuildRole(
            id: id,
            name: name,
            position: position,
            colorHex: colorHex,
            iconURL: iconURL,
            unicodeEmoji: unicodeEmoji,
            isMentionable: mentionable ?? false,
            permissions: permissions.flatMap(UInt64.init)
        )
    }
}

struct GatewayGuildMembersChunkDTO: Decodable {
    var guildID: String
    var members: [GuildMemberDTO]
    var chunkIndex: Int
    var chunkCount: Int
    var notFound: [String]?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case members
        case chunkIndex = "chunk_index"
        case chunkCount = "chunk_count"
        case notFound = "not_found"
    }
}
