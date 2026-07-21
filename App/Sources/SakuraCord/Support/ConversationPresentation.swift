import Foundation
import SakuraCordModels

nonisolated enum ConversationAccess: Equatable {
    case checking
    case readable(canSend: Bool)
    case hidden

    var canSend: Bool {
        if case let .readable(canSend) = self { return canSend }
        return false
    }
}

nonisolated enum DiscordPermissionBits {
    static let administrator: UInt64 = 1 << 3
    static let viewChannel: UInt64 = 1 << 10
    static let sendMessages: UInt64 = 1 << 11
    static let readMessageHistory: UInt64 = 1 << 16
    static let connect: UInt64 = 1 << 20
    static let manageThreads: UInt64 = 1 << 34
    static let sendMessagesInThreads: UInt64 = 1 << 38
}

nonisolated enum ChannelIconPresentation {
    static func systemImage(for kind: ChannelKindValue, isHidden: Bool) -> String {
        if isHidden { return "lock.fill" }
        return switch kind {
        case .voice: "speaker.wave.2.fill"
        case .directMessage, .groupDirectMessage: "person.fill"
        case .announcement: "megaphone.fill"
        case .forum: "bubble.left.and.bubble.right.fill"
        default: "number"
        }
    }
}

nonisolated struct HiddenChannelAccessPrincipal: Identifiable, Equatable {
    enum Kind: Int, Equatable {
        case member
        case role
    }

    let id: String
    let kind: Kind
    let name: String
    let avatarURL: URL?
    let colorHex: UInt32?
}

nonisolated enum HiddenChannelAccessPresentation {
    static func allowedPrincipals(
        channel: Channel,
        members: [Member],
        roles: [GuildRole]
    ) -> [HiddenChannelAccessPrincipal] {
        let allowedOverwrites = (channel.permissionOverwrites ?? []).filter {
            $0.allow & DiscordPermissionBits.viewChannel != 0
        }
        let membersByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id.description, $0) })
        let rolesByID = Dictionary(uniqueKeysWithValues: roles.map { ($0.id.description, $0) })

        let allowedMembers: [HiddenChannelAccessPrincipal] = allowedOverwrites.compactMap { overwrite in
            guard overwrite.type == 1, let member = membersByID[overwrite.id] else { return nil }
            return HiddenChannelAccessPrincipal(
                id: "member:\(overwrite.id)",
                kind: .member,
                name: member.user.displayName,
                avatarURL: member.guildAvatarURL ?? member.user.avatarURL,
                colorHex: MessageAuthorPresentation.topRoleColor(in: member.roles)
            )
        }

        let allowedRoles = allowedOverwrites.compactMap { overwrite -> GuildRole? in
            guard overwrite.type == 0,
                  overwrite.id != channel.guildID?.description,
                  let role = rolesByID[overwrite.id],
                  role.name != "@everyone" else { return nil }
            return role
        }
        .sorted {
            if $0.position != $1.position { return $0.position > $1.position }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        .map { role in
            HiddenChannelAccessPrincipal(
                id: "role:\(role.id)",
                kind: .role,
                name: role.name,
                avatarURL: nil,
                colorHex: role.colorHex
            )
        }

        return allowedMembers + allowedRoles
    }
}

nonisolated enum ConversationPermissionResolver {
    static func effectivePermissions(
        guild: Guild,
        channel: Channel,
        currentUserID: UserID,
        currentMember: Member?,
        roles: [GuildRole]
    ) -> UInt64? {
        if guild.isOwnedByCurrentUser == true { return .max }

        let roleIDs = Set(currentMember?.roles.map(\.id) ?? [])
        let basePermissions = guild.currentUserPermissions ?? basePermissions(
            guildID: guild.id,
            roleIDs: roleIDs,
            roles: roles
        )
        guard var permissions = basePermissions else { return nil }
        if permissions & DiscordPermissionBits.administrator != 0 { return .max }

        let overwrites = channel.permissionOverwrites ?? []
        apply(
            overwrites.filter { $0.type == 0 && $0.id == guild.id.description },
            to: &permissions
        )

        let roleOverwriteIDs = Set(
            overwrites.lazy.filter { $0.type == 0 && $0.id != guild.id.description }.map(\.id)
        )
        if currentMember == nil, !roleOverwriteIDs.isEmpty { return nil }
        let currentRoleIDs = Set(roleIDs.map(\.description))
        apply(
            overwrites.filter { $0.type == 0 && currentRoleIDs.contains($0.id) },
            to: &permissions
        )
        apply(
            overwrites.filter { $0.type == 1 && $0.id == currentUserID.description },
            to: &permissions
        )
        return permissions
    }

    static func channelAccess(effectivePermissions: UInt64?) -> ConversationAccess {
        guard let effectivePermissions else { return .checking }
        let canView = effectivePermissions & DiscordPermissionBits.viewChannel != 0
            && effectivePermissions & DiscordPermissionBits.readMessageHistory != 0
        guard canView else { return .hidden }
        return .readable(
            canSend: effectivePermissions & DiscordPermissionBits.sendMessages != 0
        )
    }

    static func voiceChannelAccess(effectivePermissions: UInt64?) -> ConversationAccess {
        guard let effectivePermissions else { return .checking }
        let canView = effectivePermissions & DiscordPermissionBits.viewChannel != 0
            && effectivePermissions & DiscordPermissionBits.readMessageHistory != 0
            && effectivePermissions & DiscordPermissionBits.connect != 0
        guard canView else { return .hidden }
        return .readable(
            canSend: effectivePermissions & DiscordPermissionBits.sendMessages != 0
        )
    }

    static func threadAccess(
        effectivePermissions: UInt64?,
        isLocked: Bool
    ) -> ConversationAccess {
        guard let effectivePermissions else { return .checking }
        let canView = effectivePermissions & DiscordPermissionBits.viewChannel != 0
            && effectivePermissions & DiscordPermissionBits.readMessageHistory != 0
        guard canView else { return .hidden }
        let canManage = effectivePermissions & DiscordPermissionBits.manageThreads != 0
        let canSend = effectivePermissions & DiscordPermissionBits.sendMessagesInThreads != 0
            && (!isLocked || canManage)
        return .readable(canSend: canSend)
    }

    private static func basePermissions(
        guildID: GuildID,
        roleIDs: Set<RoleID>,
        roles: [GuildRole]
    ) -> UInt64? {
        let applicableRoles = roles.filter { $0.id.description == guildID.description || roleIDs.contains($0.id) }
        guard !applicableRoles.isEmpty else { return nil }
        return applicableRoles.reduce(0) { $0 | ($1.permissions ?? 0) }
    }

    private static func apply(
        _ overwrites: [ChannelPermissionOverwrite],
        to permissions: inout UInt64
    ) {
        let deny = overwrites.reduce(0) { $0 | $1.deny }
        let allow = overwrites.reduce(0) { $0 | $1.allow }
        permissions &= ~deny
        permissions |= allow
    }
}

nonisolated struct MessageAuthorPresentation: Equatable {
    let user: User
    let roleColorHex: UInt32?

    static func resolve(
        message: Message,
        members: [Member],
        roles: [GuildRole]
    ) -> Self {
        resolve(
            message: message,
            member: members.first(where: { $0.id == message.author.id }),
            roles: roles
        )
    }

    static func resolve(
        message: Message,
        member: Member?,
        roles: [GuildRole]
    ) -> Self {
        if let member {
            return Self(
                user: member.user,
                roleColorHex: topRoleColor(in: member.roles)
            )
        }

        var user = message.author
        if let messageMember = message.guildMember {
            user.displayName = messageMember.nickname ?? user.displayName
            user.avatarURL = messageMember.avatarURL ?? user.avatarURL
            let roleIDs = Set(messageMember.roleIDs)
            return Self(
                user: user,
                roleColorHex: topRoleColor(in: roles.filter { roleIDs.contains($0.id) })
            )
        }
        return Self(user: user, roleColorHex: nil)
    }

    static func topRoleColor(in roles: [GuildRole]) -> UInt32? {
        roles.lazy.filter { $0.colorHex != nil }.max { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.rawValue < rhs.id.rawValue
        }?.colorHex
    }
}

nonisolated enum ConversationBeginningPolicy {
    static func showsBeginning(
        isLoading: Bool,
        hasMoreBefore: Bool,
        hasError: Bool
    ) -> Bool {
        !isLoading && !hasMoreBefore && !hasError
    }
}

nonisolated enum MessageTimelineSkeletonLayout {
    static func rowCount(for height: CGFloat) -> Int {
        max(6, Int(ceil(max(0, height - 36) / 76)))
    }
}

nonisolated enum ThreadTimelineLayoutPolicy {
    static func minimumContentHeight(viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight)
    }

    static func showsFirstReplyDateSeparator(
        showsBeginning: Bool,
        starterDate: Date?,
        firstReplyDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard showsBeginning, let starterDate else { return true }
        return !calendar.isDate(firstReplyDate, inSameDayAs: starterDate)
    }
}
