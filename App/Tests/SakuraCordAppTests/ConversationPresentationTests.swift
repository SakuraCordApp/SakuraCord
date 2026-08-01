import CoreGraphics
import Foundation
import MessageRendering
import SakuraCordModels
@testable import SakuraCord
import Testing

@MainActor
@Test func `malformed decoded mentions remain noninteractive`() throws {
    let data = try #require(
        """
        {
          "id": "not-a-snowflake",
          "kind": "channelLink",
          "rawToken": "https://discord.com/channels/1/not-a-snowflake"
        }
        """.data(using: .utf8)
    )
    let mention = try JSONDecoder().decode(RenderedMention.self, from: data)
    let presentation = MentionPresentation.fallback(for: mention)

    #expect(presentation.target == .unresolved)
}

@Test func `permission resolver applies role overwrites together then member overwrite last`() throws {
    let guildID = GuildID(rawValue: 100)
    let userID = UserID(rawValue: 1)
    let roleID = RoleID(rawValue: 10)
    let base = DiscordPermissionBits.viewChannel
        | DiscordPermissionBits.readMessageHistory
        | DiscordPermissionBits.sendMessages
    let guild = Guild(
        id: guildID,
        name: "Guild",
        currentUserPermissions: base
    )
    let role = GuildRole(id: roleID, name: "Member", position: 1, permissions: base)
    let member = Member(
        user: User(id: userID, username: "member", displayName: "Member"),
        roleName: "Member",
        isOnline: true,
        roles: [role]
    )
    let channel = Channel(
        id: ChannelID(rawValue: 200),
        guildID: guildID,
        name: "read-only",
        permissionOverwrites: [
            ChannelPermissionOverwrite(
                id: roleID.description,
                type: 0,
                deny: DiscordPermissionBits.sendMessages
            ),
            ChannelPermissionOverwrite(
                id: userID.description,
                type: 1,
                allow: DiscordPermissionBits.sendMessages
            )
        ]
    )

    let effective = ConversationPermissionResolver.effectivePermissions(
        guild: guild,
        channel: channel,
        currentUserID: userID,
        currentMember: member,
        roles: [role]
    )

    #expect(ConversationPermissionResolver.channelAccess(effectivePermissions: effective) == .readable(canSend: true))
}

@Test func `permission resolver applies ready role ids before the full member store loads`() {
    let guildID = GuildID(rawValue: 100)
    let userID = UserID(rawValue: 1)
    let allowedRoleID = RoleID(rawValue: 10)
    let base = DiscordPermissionBits.readMessageHistory
    let guild = Guild(
        id: guildID,
        name: "Guild",
        currentUserPermissions: base
    )
    let channel = Channel(
        id: ChannelID(rawValue: 200),
        guildID: guildID,
        name: "private",
        permissionOverwrites: [
            ChannelPermissionOverwrite(
                id: allowedRoleID.description,
                type: 0,
                allow: DiscordPermissionBits.viewChannel
            )
        ]
    )

    let denied = ConversationPermissionResolver.effectivePermissions(
        guild: guild,
        channel: channel,
        currentUserID: userID,
        currentMember: nil,
        roles: [],
        currentRoleIDs: []
    )
    let allowed = ConversationPermissionResolver.effectivePermissions(
        guild: guild,
        channel: channel,
        currentUserID: userID,
        currentMember: nil,
        roles: [],
        currentRoleIDs: [allowedRoleID]
    )

    #expect(ConversationPermissionResolver.channelAccess(effectivePermissions: denied) == .hidden)
    #expect(
        ConversationPermissionResolver.channelAccess(effectivePermissions: allowed)
            == .readable(canSend: false)
    )
}

@Test func `permission resolver preserves everyone overwrite precedence in the role bucket`() {
    let guildID = GuildID(rawValue: 100)
    let userID = UserID(rawValue: 1)
    let deniedRoleID = RoleID(rawValue: 10)
    let base = DiscordPermissionBits.readMessageHistory
    let guild = Guild(
        id: guildID,
        name: "Guild",
        currentUserPermissions: base
    )
    let channel = Channel(
        id: ChannelID(rawValue: 200),
        guildID: guildID,
        name: "private",
        permissionOverwrites: [
            ChannelPermissionOverwrite(
                id: deniedRoleID.description,
                type: 0,
                deny: DiscordPermissionBits.viewChannel
            ),
            ChannelPermissionOverwrite(
                id: guildID.description,
                type: 0,
                allow: DiscordPermissionBits.viewChannel
            ),
        ]
    )

    let effective = ConversationPermissionResolver.effectivePermissions(
        guild: guild,
        channel: channel,
        currentUserID: userID,
        currentMember: nil,
        roles: [],
        currentRoleIDs: [
            RoleID(rawValue: guildID.rawValue),
            deniedRoleID,
        ]
    )

    #expect(
        ConversationPermissionResolver.channelAccess(effectivePermissions: effective)
            == .readable(canSend: false)
    )
}

@Test func `permission resolver keeps malformed role identity unresolved`() {
    let guild = Guild(
        id: GuildID(rawValue: 100),
        name: "Guild",
        currentUserPermissions: DiscordPermissionBits.readMessageHistory
    )
    let channel = Channel(
        id: ChannelID(rawValue: 200),
        guildID: guild.id,
        name: "private",
        permissionOverwrites: [
            ChannelPermissionOverwrite(
                id: "not-a-snowflake",
                type: 0,
                allow: DiscordPermissionBits.viewChannel
            )
        ]
    )

    let effective = ConversationPermissionResolver.effectivePermissions(
        guild: guild,
        channel: channel,
        currentUserID: UserID(rawValue: 1),
        currentMember: nil,
        roles: []
    )

    #expect(effective == nil)
}

@Test(arguments: ["000100", "+100"])
func `permission resolver ignores noncanonical numeric role ids`(_ overwriteID: String) {
    let guild = Guild(
        id: GuildID(rawValue: 100),
        name: "Guild",
        currentUserPermissions: DiscordPermissionBits.readMessageHistory
    )
    let channel = Channel(
        id: ChannelID(rawValue: 200),
        guildID: guild.id,
        name: "private",
        permissionOverwrites: [
            ChannelPermissionOverwrite(
                id: overwriteID,
                type: 0,
                allow: DiscordPermissionBits.viewChannel
            )
        ]
    )

    let effective = ConversationPermissionResolver.effectivePermissions(
        guild: guild,
        channel: channel,
        currentUserID: UserID(rawValue: 1),
        currentMember: nil,
        roles: [],
        currentRoleIDs: []
    )

    #expect(
        ConversationPermissionResolver.channelAccess(effectivePermissions: effective) == .hidden
    )
}

@Test(arguments: ["000001", "+1"])
func `permission resolver ignores noncanonical numeric member ids`(_ overwriteID: String) {
    let guild = Guild(
        id: GuildID(rawValue: 100),
        name: "Guild",
        currentUserPermissions: DiscordPermissionBits.readMessageHistory
    )
    let channel = Channel(
        id: ChannelID(rawValue: 200),
        guildID: guild.id,
        name: "private",
        permissionOverwrites: [
            ChannelPermissionOverwrite(
                id: overwriteID,
                type: 1,
                allow: DiscordPermissionBits.viewChannel
            )
        ]
    )

    let effective = ConversationPermissionResolver.effectivePermissions(
        guild: guild,
        channel: channel,
        currentUserID: UserID(rawValue: 1),
        currentMember: nil,
        roles: [],
        currentRoleIDs: []
    )

    #expect(
        ConversationPermissionResolver.channelAccess(effectivePermissions: effective) == .hidden
    )
}

@Test func `channel access distinguishes read only and hidden channels`() {
    let readable = DiscordPermissionBits.viewChannel | DiscordPermissionBits.readMessageHistory
    #expect(
        ConversationPermissionResolver.channelAccess(effectivePermissions: readable)
            == .readable(canSend: false)
    )
    #expect(
        ConversationPermissionResolver.channelAccess(
            effectivePermissions: DiscordPermissionBits.readMessageHistory
        ) == .hidden
    )
}

@Test func `voice channel chat requires connect as well as message history`() {
    let messagePermissions = DiscordPermissionBits.viewChannel
        | DiscordPermissionBits.readMessageHistory
        | DiscordPermissionBits.sendMessages
    #expect(
        ConversationPermissionResolver.voiceChannelAccess(
            effectivePermissions: messagePermissions
        ) == .hidden
    )
    #expect(
        ConversationPermissionResolver.voiceChannelAccess(
            effectivePermissions: messagePermissions | DiscordPermissionBits.connect
        ) == .readable(canSend: true)
    )
}

@Test func `hidden channel icon overrides its ordinary channel kind icon`() {
    #expect(ChannelIconPresentation.systemImage(for: .text, isHidden: true) == "lock.fill")
    #expect(ChannelIconPresentation.systemImage(for: .text, isHidden: false) == "number")
    #expect(
        ChannelIconPresentation.systemImage(for: .announcement, isHidden: false)
            == "megaphone.fill"
    )
    #expect(ChannelIconPresentation.systemImage(for: .forum, isHidden: false)
        == "bubble.left.and.bubble.right.fill")
    #expect(ChannelIconPresentation.systemImage(for: .voice, isHidden: false)
        == "speaker.wave.2.fill")
    #expect(ChannelIconPresentation.systemImage(for: .directMessage, isHidden: false)
        == "person.fill")
    #expect(ChannelIconPresentation.systemImage(for: .groupDirectMessage, isHidden: false)
        == "person.2.fill")
    #expect(ChannelIconPresentation.systemImage(for: .unknown, isHidden: false)
        == "questionmark")
    #expect(ChannelIconPresentation.forumPostSystemImage == "bubble.left.fill")
}

@Test func `rules channel icon uses only the guild designation`() {
    let guildID = GuildID(rawValue: 100)
    let designatedRulesID = ChannelID(rawValue: 101)
    let namedRulesID = ChannelID(rawValue: 102)
    let designated = Channel(
        id: designatedRulesID,
        guildID: guildID,
        name: "read-me-first"
    )
    let merelyNamedRules = Channel(
        id: namedRulesID,
        guildID: guildID,
        name: "rules"
    )

    #expect(
        ChannelIconPresentation.systemImage(
            for: designated,
            isHidden: false,
            rulesChannelID: designatedRulesID
        ) == "newspaper.fill"
    )
    #expect(
        ChannelIconPresentation.systemImage(
            for: merelyNamedRules,
            isHidden: false,
            rulesChannelID: designatedRulesID
        ) == "number"
    )
    #expect(
        ChannelIconPresentation.systemImage(
            for: designated,
            isHidden: true,
            rulesChannelID: designatedRulesID
        ) == "lock.fill"
    )
}

@Test func `hidden channel details resolve explicitly allowed members and roles`() {
    let guildID = GuildID(rawValue: 100)
    let memberID = UserID(rawValue: 1)
    let allowedRole = GuildRole(
        id: RoleID(rawValue: 10), name: "Design", position: 20, colorHex: 0xF472B6
    )
    let deniedRole = GuildRole(
        id: RoleID(rawValue: 11), name: "Guests", position: 5, colorHex: 0x94A3B8
    )
    let member = Member(
        user: User(id: memberID, username: "maya", displayName: "Maya • Orbit"),
        roleName: "Design",
        isOnline: true,
        roles: [allowedRole]
    )
    let channel = Channel(
        id: ChannelID(rawValue: 200),
        guildID: guildID,
        name: "staff-vault",
        permissionOverwrites: [
            ChannelPermissionOverwrite(
                id: guildID.description,
                type: 0,
                allow: DiscordPermissionBits.viewChannel
            ),
            ChannelPermissionOverwrite(
                id: deniedRole.id.description,
                type: 0,
                deny: DiscordPermissionBits.viewChannel
            ),
            ChannelPermissionOverwrite(
                id: allowedRole.id.description,
                type: 0,
                allow: DiscordPermissionBits.viewChannel
            ),
            ChannelPermissionOverwrite(
                id: memberID.description,
                type: 1,
                allow: DiscordPermissionBits.viewChannel
            )
        ]
    )

    let principals = HiddenChannelAccessPresentation.allowedPrincipals(
        channel: channel,
        members: [member],
        roles: [allowedRole, deniedRole]
    )

    #expect(principals.map(\.id) == ["member:1", "role:10"])
    #expect(principals.map(\.name) == ["Maya • Orbit", "Design"])
    #expect(principals.first?.colorHex == 0xF472B6)
}

@Test func `thread access requires send messages in threads and honors locks`() {
    let readable = DiscordPermissionBits.viewChannel | DiscordPermissionBits.readMessageHistory
    let sendable = readable | DiscordPermissionBits.sendMessagesInThreads
    #expect(
        ConversationPermissionResolver.threadAccess(
            effectivePermissions: readable,
            isLocked: false
        ) == .readable(canSend: false)
    )
    #expect(
        ConversationPermissionResolver.threadAccess(
            effectivePermissions: sendable,
            isLocked: false
        ) == .readable(canSend: true)
    )
    #expect(
        ConversationPermissionResolver.threadAccess(
            effectivePermissions: sendable,
            isLocked: true
        ) == .readable(canSend: false)
    )
}

@Test func `forum posts begin at newest so opening them clears unread replies`() {
    #expect(
        ThreadTimelinePresentationPolicy.initialScrollTarget(
            isForumPost: true,
            hasUnreadReplies: true
        ) == .newest
    )
    #expect(
        ThreadTimelinePresentationPolicy.initialScrollTarget(
            isForumPost: false,
            hasUnreadReplies: true
        ) == .firstUnread
    )
    #expect(
        ThreadTimelinePresentationPolicy.initialScrollTarget(
            isForumPost: false,
            hasUnreadReplies: false
        ) == .newest
    )
}

@Test func `new replies button requires actual unread replies below the viewport`() {
    #expect(
        ThreadTimelinePresentationPolicy.showsNewRepliesButton(
            isNearBottom: false,
            hasUnreadReplies: true,
            messageCount: 2
        )
    )
    #expect(
        !ThreadTimelinePresentationPolicy.showsNewRepliesButton(
            isNearBottom: false,
            hasUnreadReplies: false,
            messageCount: 2
        )
    )
    #expect(
        !ThreadTimelinePresentationPolicy.showsNewRepliesButton(
            isNearBottom: true,
            hasUnreadReplies: true,
            messageCount: 2
        )
    )
}

@Test func `forum cards reserve chrome emphasis for selection`() {
    #expect(
        ForumPostCardPresentationPolicy.emphasis(isSelected: false, isUnread: false)
            == .standard
    )
    #expect(
        ForumPostCardPresentationPolicy.emphasis(isSelected: false, isUnread: true)
            == .standard
    )
    #expect(
        ForumPostCardPresentationPolicy.emphasis(isSelected: true, isUnread: true)
            == .selected
    )
}

@Test func `message author presentation prefers member cache nickname and top colored role`() {
    let user = User(
        id: UserID(rawValue: 1),
        username: "global",
        displayName: "Global Name",
        displayNameStyle: DisplayNameStyle(colors: [0xFF0000, 0x00FF00])
    )
    let lowerRole = GuildRole(
        id: RoleID(rawValue: 10), name: "Lower", position: 2, colorHex: 0x123456
    )
    let topRole = GuildRole(
        id: RoleID(rawValue: 11), name: "Top", position: 9, colorHex: 0xABCDEF
    )
    var guildUser = user
    guildUser.displayName = "Server Nick"
    let member = Member(
        user: guildUser,
        roleName: "Top",
        isOnline: true,
        roles: [lowerRole, topRole]
    )
    let message = Message(
        id: MessageID(rawValue: 20),
        channelID: ChannelID(rawValue: 30),
        author: user,
        content: "Hello"
    )

    let presentation = MessageAuthorPresentation.resolve(
        message: message,
        members: [member],
        roles: [lowerRole, topRole]
    )
    #expect(presentation.user.displayName == "Server Nick")
    #expect(presentation.roleColorHex == 0xABCDEF)
}

@Test func `message member payload supplies nickname and role color before member cache loads`() {
    let role = GuildRole(
        id: RoleID(rawValue: 10), name: "Role", position: 5, colorHex: 0x654321
    )
    let message = Message(
        id: MessageID(rawValue: 20),
        channelID: ChannelID(rawValue: 30),
        author: User(id: UserID(rawValue: 1), username: "global", displayName: "Global"),
        guildMember: MessageGuildMember(nickname: "Payload Nick", roleIDs: [role.id]),
        content: "Hello"
    )

    let presentation = MessageAuthorPresentation.resolve(
        message: message,
        members: [],
        roles: [role]
    )
    #expect(presentation.user.displayName == "Payload Nick")
    #expect(presentation.roleColorHex == 0x654321)
}

@Test func `reply preview uses referenced member role color before member cache loads`() {
    let role = GuildRole(
        id: RoleID(rawValue: 10), name: "Role", position: 5, colorHex: 0x654321
    )
    let preview = MessageReplyPreview(
        messageID: MessageID(rawValue: 20),
        author: User(id: UserID(rawValue: 1), username: "global", displayName: "Global"),
        guildMember: MessageGuildMember(nickname: "Payload Nick", roleIDs: [role.id]),
        content: "Hello"
    )

    let presentation = MessageAuthorPresentation.resolve(
        replyPreview: preview,
        member: nil,
        roles: [role]
    )
    #expect(presentation.user.displayName == "Payload Nick")
    #expect(presentation.roleColorHex == 0x654321)
}

@Test func `authoritative member without colored role ignores stale message role IDs`() {
    let coloredRole = GuildRole(
        id: RoleID(rawValue: 10), name: "Role", position: 5, colorHex: 0x654321
    )
    let user = User(id: UserID(rawValue: 1), username: "global", displayName: "Global")
    let member = Member(user: user, roleName: "Member", isOnline: true)
    let message = Message(
        id: MessageID(rawValue: 20),
        channelID: ChannelID(rawValue: 30),
        author: user,
        guildMember: MessageGuildMember(roleIDs: [coloredRole.id]),
        content: "Hello"
    )

    let presentation = MessageAuthorPresentation.resolve(
        message: message,
        member: member,
        roles: [coloredRole]
    )
    #expect(presentation.roleColorHex == nil)
}

@Test func `authoritative raw member role IDs resolve against guild role catalog`() {
    let coloredRole = GuildRole(
        id: RoleID(rawValue: 10), name: "Role", position: 5, colorHex: 0x654321
    )
    let user = User(id: UserID(rawValue: 1), username: "global", displayName: "Global")
    let member = Member(
        user: user,
        roleName: "Member",
        isOnline: true,
        roleIDs: [coloredRole.id]
    )
    let message = Message(
        id: MessageID(rawValue: 20),
        channelID: ChannelID(rawValue: 30),
        author: user,
        content: "Hello"
    )

    let presentation = MessageAuthorPresentation.resolve(
        message: message,
        member: member,
        roles: [coloredRole]
    )
    #expect(presentation.roleColorHex == coloredRole.colorHex)
}

@Test func `conversation beginnings appear only at the oldest loaded boundary`() {
    #expect(
        ConversationBeginningPolicy.showsBeginning(
            isLoading: false,
            hasMoreBefore: false,
            hasError: false
        )
    )
    #expect(
        !ConversationBeginningPolicy.showsBeginning(
            isLoading: false,
            hasMoreBefore: true,
            hasError: false
        )
    )
    #expect(
        !ConversationBeginningPolicy.showsBeginning(
            isLoading: true,
            hasMoreBefore: false,
            hasError: false
        )
    )
    #expect(
        !ConversationBeginningPolicy.showsBeginning(
            isLoading: false,
            hasMoreBefore: false,
            hasError: true
        )
    )
}

@Test func `loading skeleton and short thread content fill their viewport`() {
    let viewportHeight: CGFloat = 1_000
    let rowCount = MessageTimelineSkeletonLayout.rowCount(for: viewportHeight)
    let coveredHeight = MessageTimelineSkeletonLayout.coveredHeight(rowCount: rowCount)
    #expect(coveredHeight >= viewportHeight)
    #expect(
        coveredHeight - viewportHeight
            < MessageTimelineSkeletonLayout.rowHeight
                + MessageTimelineSkeletonLayout.rowSpacing
    )
    #expect(ThreadTimelineLayoutPolicy.minimumContentHeight(viewportHeight: 680) == 680)
}

@Test func `read eligibility uses established newest message geometry`() {
    #expect(
        TimelineReadEligibilityPolicy.hasReachedReadBoundary(
            TimelineScrollState(
                isNearTop: true,
                isNearBottom: false,
                contentFitsViewport: true,
                hasEstablishedInitialPosition: true,
                hasReachedNewestMessageBoundary: true
            )
        )
    )
    #expect(
        !TimelineReadEligibilityPolicy.hasReachedReadBoundary(
            TimelineScrollState(
                isNearTop: false,
                isNearBottom: true,
                contentFitsViewport: true,
                hasEstablishedInitialPosition: false,
                hasReachedNewestMessageBoundary: true
            )
        )
    )
    #expect(
        !TimelineReadEligibilityPolicy.hasReachedReadBoundary(
            TimelineScrollState(
                isNearTop: false,
                isNearBottom: true,
                contentFitsViewport: true,
                hasEstablishedInitialPosition: true,
                hasReachedNewestMessageBoundary: false
            )
        )
    )
}

@Test func `newest message boundary uses exact viewport space`() {
    #expect(
        NativeTimelineReadBoundaryPolicy
            .hasReachedNewestMessageBoundary(
                newestMessageMaximumY: 700,
                viewportMinimumY: 200,
                viewportMaximumY: 700
            )
    )
    #expect(
        !NativeTimelineReadBoundaryPolicy
            .hasReachedNewestMessageBoundary(
                newestMessageMaximumY: 701,
                viewportMinimumY: 200,
                viewportMaximumY: 700
            )
    )
    #expect(
        !NativeTimelineReadBoundaryPolicy
            .hasReachedNewestMessageBoundary(
                newestMessageMaximumY: 199,
                viewportMinimumY: 200,
                viewportMaximumY: 700
            )
    )
}

@Test func `exact unread run placement includes the footer in its fit decision`() {
    #expect(
        NativeTimelineInitialPlacementPolicy.exactUnreadRunFitsAtBottom(
            unreadMinimumY: 1_200,
            newestMaximumY: 1_800,
            viewportHeight: 700,
            bottomInset: 76
        )
    )
    #expect(
        !NativeTimelineInitialPlacementPolicy.exactUnreadRunFitsAtBottom(
            unreadMinimumY: 1_200,
            newestMaximumY: 1_825,
            viewportHeight: 700,
            bottomInset: 76
        )
    )
}

@Test func `thread beginning does not duplicate a same-day first reply separator`() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let starter = Date(timeIntervalSince1970: 1_774_675_800)
    #expect(
        !ThreadTimelineLayoutPolicy.showsFirstReplyDateSeparator(
            showsBeginning: true,
            starterDate: starter,
            firstReplyDate: starter.addingTimeInterval(120),
            calendar: calendar
        )
    )
    #expect(
        ThreadTimelineLayoutPolicy.showsFirstReplyDateSeparator(
            showsBeginning: false,
            starterDate: starter,
            firstReplyDate: starter.addingTimeInterval(120),
            calendar: calendar
        )
    )
}
