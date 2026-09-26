import Foundation

public enum PresenceStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case online, idle, dnd, invisible, offline

    public var isVisibleOnline: Bool {
        self == .online || self == .idle || self == .dnd
    }
}

public struct GuildRole: Identifiable, Codable, Hashable, Sendable {
    public let id: RoleID
    public var name: String
    public var position: Int
    public var colorHex: UInt32?
    public var iconURL: URL?
    public var unicodeEmoji: String?
    public var isMentionable: Bool
    public var permissions: UInt64?

    public init(
        id: RoleID,
        name: String,
        position: Int = 0,
        colorHex: UInt32? = nil,
        iconURL: URL? = nil,
        unicodeEmoji: String? = nil,
        isMentionable: Bool = true,
        permissions: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.colorHex = colorHex
        self.iconURL = iconURL
        self.unicodeEmoji = unicodeEmoji
        self.isMentionable = isMentionable
        self.permissions = permissions
    }
}

public struct RoleMemberResult: Equatable, Sendable {
    public var members: [Member]
    public var totalCount: Int
    public var isTruncated: Bool

    public init(members: [Member], totalCount: Int, isTruncated: Bool = false) {
        self.members = members
        self.totalCount = totalCount
        self.isTruncated = isTruncated
    }
}

public struct Member: Identifiable, Codable, Hashable, Sendable {
    public var id: UserID {
        user.id
    }

    public var user: User
    public var roleName: String
    public var roleID: RoleID?
    public var rolePosition: Int?
    public var isRoleCategory: Bool?
    public var status: PresenceStatus
    /// Raw guild role membership retained even when the role catalogue has not
    /// arrived yet. `roles` contains the corresponding resolved role objects.
    public var roleIDs: [RoleID]
    public var roles: [GuildRole]
    public var guildAvatarURL: URL?
    /// The account-wide display name before `user.displayName` is replaced by
    /// a guild nickname for presentation.
    public var globalDisplayName: String?
    public var guildNickname: String?
    public var guildProfileCosmetics: GuildProfileCosmetics?
    public var activityText: String?
    public var customStatus: String?
    public var isListeningToMusic: Bool
    /// Discord's membership-screening state. A pending member does not have
    /// normal guild channel access even when role IDs are already present.
    public var isPending: Bool?
    public var flags: UInt64?

    public var requiresOnboarding: Bool {
        guard let flags else { return false }
        return flags & 8 != 0 && flags & 2 == 0
    }
    public var hasCompletedGuildGuide: Bool { (flags ?? 0) & 64 != 0 }
    public var joinedAt: Date?
    /// Absolute row index in Discord's virtualized guild member list. This is
    /// absent for DMs, fallback stores, and member lookups that are not backed
    /// by a `GUILD_MEMBER_LIST_UPDATE` range.
    public var memberListIndex: Int?

    public var isOnline: Bool {
        status.isVisibleOnline
    }

    public init(
        user: User,
        roleName: String,
        isOnline: Bool,
        roleID: RoleID? = nil,
        rolePosition: Int? = nil,
        isRoleCategory: Bool? = nil,
        roleIDs: [RoleID] = [],
        roles: [GuildRole] = [],
        guildAvatarURL: URL? = nil,
        globalDisplayName: String? = nil,
        guildNickname: String? = nil,
        guildProfileCosmetics: GuildProfileCosmetics? = nil,
        activityText: String? = nil,
        customStatus: String? = nil,
        isListeningToMusic: Bool = false,
        isPending: Bool? = nil,
        flags: UInt64? = nil,
        joinedAt: Date? = nil,
        memberListIndex: Int? = nil
    ) {
        self.user = user
        self.roleName = roleName
        self.roleID = roleID
        self.rolePosition = rolePosition
        self.isRoleCategory = isRoleCategory
        status = isOnline ? .online : .offline
        self.roleIDs = roleIDs
        self.roles = roles
        self.guildAvatarURL = guildAvatarURL
        self.globalDisplayName = globalDisplayName
        self.guildNickname = guildNickname
        self.guildProfileCosmetics = guildProfileCosmetics
        self.activityText = activityText
        self.customStatus = customStatus
        self.isListeningToMusic = isListeningToMusic
        self.isPending = isPending
        self.flags = flags
        self.joinedAt = joinedAt
        self.memberListIndex = memberListIndex
    }

    public init(
        user: User,
        roleName: String,
        status: PresenceStatus,
        roleID: RoleID? = nil,
        rolePosition: Int? = nil,
        isRoleCategory: Bool? = nil,
        roleIDs: [RoleID] = [],
        roles: [GuildRole] = [],
        guildAvatarURL: URL? = nil,
        globalDisplayName: String? = nil,
        guildNickname: String? = nil,
        guildProfileCosmetics: GuildProfileCosmetics? = nil,
        activityText: String? = nil,
        customStatus: String? = nil,
        isListeningToMusic: Bool = false,
        isPending: Bool? = nil,
        flags: UInt64? = nil,
        joinedAt: Date? = nil,
        memberListIndex: Int? = nil
    ) {
        self.user = user
        self.roleName = roleName
        self.roleID = roleID
        self.rolePosition = rolePosition
        self.isRoleCategory = isRoleCategory
        self.status = status
        self.roleIDs = roleIDs
        self.roles = roles
        self.guildAvatarURL = guildAvatarURL
        self.globalDisplayName = globalDisplayName
        self.guildNickname = guildNickname
        self.guildProfileCosmetics = guildProfileCosmetics
        self.activityText = activityText
        self.customStatus = customStatus
        self.isListeningToMusic = isListeningToMusic
        self.isPending = isPending
        self.flags = flags
        self.joinedAt = joinedAt
        self.memberListIndex = memberListIndex
    }

    private enum CodingKeys: String, CodingKey {
        case user, roleName, roleID, rolePosition, isRoleCategory, status, roleIDs, roles,
             guildAvatarURL,
             globalDisplayName, guildNickname, guildProfileCosmetics, activityText, customStatus, isListeningToMusic,
             memberListIndex, joinedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(User.self, forKey: .user)
        roleName = try container.decodeIfPresent(String.self, forKey: .roleName) ?? "Member"
        roleID = try container.decodeIfPresent(RoleID.self, forKey: .roleID)
        rolePosition = try container.decodeIfPresent(Int.self, forKey: .rolePosition)
        isRoleCategory = try container.decodeIfPresent(Bool.self, forKey: .isRoleCategory)
        status = try container.decodeIfPresent(PresenceStatus.self, forKey: .status) ?? .offline
        roleIDs = try container.decodeIfPresent([RoleID].self, forKey: .roleIDs) ?? []
        roles = try container.decodeIfPresent([GuildRole].self, forKey: .roles) ?? []
        guildAvatarURL = try container.decodeIfPresent(URL.self, forKey: .guildAvatarURL)
        globalDisplayName = try container.decodeIfPresent(String.self, forKey: .globalDisplayName)
        guildNickname = try container.decodeIfPresent(String.self, forKey: .guildNickname)
        guildProfileCosmetics = try container.decodeIfPresent(GuildProfileCosmetics.self, forKey: .guildProfileCosmetics)
        activityText = try container.decodeIfPresent(String.self, forKey: .activityText)
        customStatus = try container.decodeIfPresent(String.self, forKey: .customStatus)
        isListeningToMusic = try container.decodeIfPresent(Bool.self, forKey: .isListeningToMusic) ?? false
        memberListIndex = try container.decodeIfPresent(Int.self, forKey: .memberListIndex)
        joinedAt = try container.decodeIfPresent(Date.self, forKey: .joinedAt)
    }

    public mutating func applyGlobalProfileUser(_ value: User) {
        let oldName = user.displayName
        let inheritedName = globalDisplayName
        user = guildProfileCosmetics?.applying(to: value) ?? value
        if let guildNickname, !guildNickname.isEmpty { user.displayName = guildNickname } else if let inheritedName, oldName != inheritedName { user.displayName = oldName }
        if let guildAvatarURL { user.avatarURL = guildAvatarURL }
        globalDisplayName = value.displayName
    }
}

public struct GuildMemberListGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var count: Int

    public init(id: String, count: Int) {
        self.id = id
        self.count = max(0, count)
    }
}
