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
    static func systemImage(
        for channel: Channel,
        isHidden: Bool,
        rulesChannelID: ChannelID?
    ) -> String {
        systemImage(
            for: channel.kind,
            isHidden: isHidden,
            isRulesChannel: rulesChannelID == channel.id
        )
    }

    static func systemImage(
        for kind: ChannelKindValue,
        isHidden: Bool,
        isRulesChannel: Bool = false
    ) -> String {
        if isHidden { return "lock.fill" }
        if isRulesChannel { return "newspaper.fill" }
        return switch kind {
        case .text: "number"
        case .announcement: "megaphone.fill"
        case .forum: "bubble.left.and.bubble.right.fill"
        case .voice: "speaker.wave.2.fill"
        case .directMessage: "person.fill"
        case .groupDirectMessage: "person.2.fill"
        case .unknown: "questionmark"
        }
    }

    static let forumPostSystemImage = "bubble.left.fill"
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
        roles: [GuildRole],
        currentRoleIDs: Set<RoleID>? = nil
    ) -> UInt64? {
        if guild.isOwnedByCurrentUser == true { return .max }

        let roleIDs = currentRoleIDs ?? Set(currentMember?.roles.map(\.id) ?? [])
        let hasCurrentRoleIdentity = currentRoleIDs != nil || currentMember != nil
        let basePermissions = guild.currentUserPermissions ?? basePermissions(
            guildID: guild.id,
            roleIDs: roleIDs,
            roles: roles
        )
        guard let permissions = basePermissions else { return nil }
        if permissions & DiscordPermissionBits.administrator != 0 { return .max }

        guard let overwrites = channel.permissionOverwrites, !overwrites.isEmpty else {
            return permissions
        }
        let mask = OverwriteMask(
            overwrites,
            guildRawID: guild.id.rawValue,
            currentUserRawID: currentUserID.rawValue,
            roleIDs: roleIDs
        )
        if !hasCurrentRoleIdentity, mask.hasRoleOverwrite { return nil }
        return mask.applied(to: permissions)
    }

    /// A channel's permission overwrites bucketed into the order Discord
    /// applies them: @everyone, then the member's roles, then the member.
    ///
    /// The account-wide unread refresh resolves every channel, so this runs
    /// thousands of times per pass. The previous shape made four filtering
    /// passes over the overwrites, re-rendered `guild.id` as a string once per
    /// overwrite inside the filter predicates, and built a `Set` of role-id
    /// strings per channel. One pass comparing snowflakes numerically
    /// allocates nothing.
    private struct OverwriteMask {
        private var everyoneAllow: UInt64 = 0
        private var everyoneDeny: UInt64 = 0
        private var roleAllow: UInt64 = 0
        private var roleDeny: UInt64 = 0
        private var memberAllow: UInt64 = 0
        private var memberDeny: UInt64 = 0
        private(set) var hasRoleOverwrite = false

        init(
            _ overwrites: [ChannelPermissionOverwrite],
            guildRawID: UInt64,
            currentUserRawID: UInt64,
            roleIDs: Set<RoleID>
        ) {
            for overwrite in overwrites {
                guard let rawID = UInt64(overwrite.id) else { continue }
                switch overwrite.type {
                case 0:
                    if rawID == guildRawID {
                        everyoneAllow |= overwrite.allow
                        everyoneDeny |= overwrite.deny
                    } else {
                        hasRoleOverwrite = true
                    }
                    // Membership is tested independently of the @everyone
                    // match: when the @everyone role id reaches `roleIDs`, its
                    // overwrite joins the role bucket too, so its allows
                    // survive a role deny in the same pass. Keep that, rather
                    // than quietly changing which channels resolve as visible.
                    guard roleIDs.contains(RoleID(rawValue: rawID)) else { continue }
                    roleAllow |= overwrite.allow
                    roleDeny |= overwrite.deny
                case 1 where rawID == currentUserRawID:
                    memberAllow |= overwrite.allow
                    memberDeny |= overwrite.deny
                default:
                    continue
                }
            }
        }

        func applied(to permissions: UInt64) -> UInt64 {
            var value = permissions
            value &= ~everyoneDeny
            value |= everyoneAllow
            value &= ~roleDeny
            value |= roleAllow
            value &= ~memberDeny
            value |= memberAllow
            return value
        }
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
        // @everyone shares the guild's id. Match it numerically rather than
        // rendering both snowflakes as strings for every role of every channel.
        var permissions: UInt64 = 0
        var didMatchRole = false
        for role in roles
        where role.id.rawValue == guildID.rawValue || roleIDs.contains(role.id) {
            didMatchRole = true
            permissions |= role.permissions ?? 0
        }
        guard didMatchRole else { return nil }
        return permissions
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
    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 20
    static let verticalPadding: CGFloat = 36

    static func rowCount(for height: CGFloat) -> Int {
        let availableHeight = max(0, height - verticalPadding)
        return max(
            6,
            Int(ceil((availableHeight + rowSpacing) / (rowHeight + rowSpacing)))
        )
    }

    static func coveredHeight(rowCount: Int) -> CGFloat {
        verticalPadding
            + CGFloat(max(0, rowCount)) * rowHeight
            + CGFloat(max(0, rowCount - 1)) * rowSpacing
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
