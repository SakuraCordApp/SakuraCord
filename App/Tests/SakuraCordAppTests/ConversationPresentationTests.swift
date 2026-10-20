import AppKit
import CoreGraphics
import Foundation
import MessageRendering
import SakuraCordModels
import SwiftUI
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

@MainActor
@Test func `thread links and mentions present the names of known threads`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let parent = try #require(model.snapshot?.channels.first { $0.kind == .text && $0.guildID != nil })
    let guildID = try #require(parent.guildID)
    let joined = MessageThreadSummary(id: ChannelID(rawValue: 9_341_001), guildID: guildID, parentID: parent.id, name: "Joined thread")
    model.snapshot?.activeJoinedThreads.append(joined)
    let resolver = MessageMentionResolver(model: model)
    func presentation(_ token: String) throws -> MentionPresentation {
        try resolver.presentation(#require(RenderedMention(rawToken: token)))
    }

    for token in ["<#\(joined.id)>", "https://discord.com/channels/\(guildID)/\(joined.id)"] {
        let value = try presentation(token)
        #expect(value.label == "Joined thread")
        #expect(value.target == .linkedChannel(guildID: guildID, channelID: joined.id))
        #expect(value.systemImage == SakuraCordSystemSymbol.thread)
    }
    let unknown = try presentation("https://discord.com/channels/\(guildID)/9341002")
    #expect(unknown.label == "unknown-channel")
    #expect(unknown.isInteractive)

    let messageID = MessageID(rawValue: 9_341_003)
    let messageLink = try presentation("https://discord.com/channels/\(guildID)/\(joined.id)/\(messageID)")
    #expect(messageLink.label == "Joined thread ›")
    #expect(messageLink.target == .message(guildID: guildID, channelID: joined.id, messageID: messageID))
    let unknownMessage = try presentation("https://discord.com/channels/\(guildID)/9341002/\(messageID)")
    #expect(unknownMessage.label == "unknown-channel ›")
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

@MainActor
@Test func `workspace trailing column prefers search then side chats then members`() {
    let thread = MessageThreadSummary(id: ChannelID(rawValue: 2), parentID: ChannelID(rawValue: 1), name: "Thread")
    let paneThread = SideConversation.thread(thread, isFullWidth: false)
    let preview = SideConversation.channelPreview(ChannelID(rawValue: 3), returnTo: nil)
    func presentation(
        page: GuildWorkspacePage? = nil,
        friends: Bool = false,
        kind: ChannelKindValue? = .text,
        side: SideConversation? = nil,
        search: Bool = false,
        inspector: Bool = true
    ) -> WorkspacePresentation {
        WorkspacePresentation(
            guildPage: page,
            isFriendsPresented: friends,
            channelKind: kind,
            sideConversation: side,
            showsMessageSearch: search,
            showsInspector: inspector
        )
    }

    #expect(presentation(side: paneThread).supplementaryPane == .sideConversation(paneThread))
    #expect(presentation(side: paneThread, search: true).supplementaryPane == .messageSearch)
    #expect(presentation(search: true).supplementaryPane == .messageSearch)
    #expect(presentation().supplementaryPane == .memberInspector)
    #expect(presentation(inspector: false).supplementaryPane == nil)
    // A full-width thread replaces the primary column and keeps the member list.
    let fullWidth = presentation(page: .guide, side: .thread(thread, isFullWidth: true))
    #expect(fullWidth.primary == .fullWidthThread)
    #expect(fullWidth.supplementaryPane == .memberInspector)
    // Search results stay beside a full-width thread, with or without members.
    let fullWidthThread = SideConversation.thread(thread, isFullWidth: true)
    #expect(presentation(side: fullWidthThread, search: true).supplementaryPane == .messageSearch)
    #expect(presentation(side: fullWidthThread, search: true, inspector: false).supplementaryPane == .messageSearch)
    #expect(presentation(side: fullWidthThread, inspector: false).supplementaryPane == nil)
    // Voice channels show only their chat; guild pages only their side chats.
    #expect(presentation(kind: .voice).supplementaryPane == nil)
    #expect(presentation(kind: .voice, side: .voiceChat(ChannelID(rawValue: 4))).paneSideConversation == .voiceChat(ChannelID(rawValue: 4)))
    #expect(presentation(page: .channelsAndRoles, search: true).supplementaryPane == nil)
    #expect(presentation(page: .channelsAndRoles, side: preview).paneSideConversation == preview)
    #expect(presentation(friends: true, side: paneThread).supplementaryPane == nil)
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
    // A detached window's own bottom is not the newest reply.
    #expect(
        ThreadTimelinePresentationPolicy.showsNewRepliesButton(
            isNearBottom: true,
            hasUnreadReplies: false,
            isDetachedFromNewest: true,
            messageCount: 2
        )
    )
}

@Test func `wheel input toward newest is downward and vertical`() {
    #expect(NativeTimelineReadBoundaryPolicy.isScrollTowardNewest(deltaX: 0, deltaY: -4))
    #expect(!NativeTimelineReadBoundaryPolicy.isScrollTowardNewest(deltaX: 0, deltaY: 4))
    #expect(!NativeTimelineReadBoundaryPolicy.isScrollTowardNewest(deltaX: -6, deltaY: -2))
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

@Test(arguments: ["onboarding", "screening", "unknown", "completed"])
func `server verification blocks sends without exposing hidden channels`(state: String) {
    let guildID = GuildID(rawValue: 100)
    let channel = Channel(id: .init(rawValue: 200), guildID: guildID, name: "general")
    var basis = ConversationPermissionBasis(
        guild: Guild(id: guildID, name: "Test"),
        resolvedBasePermissions: DiscordPermissionBits.viewChannel | DiscordPermissionBits.readMessageHistory | DiscordPermissionBits.sendMessages,
        overwritePrincipals: PermissionOverwritePrincipals(guildID: guildID, currentUserID: .init(rawValue: 1), roleIDs: []),
        hasCurrentRoleIdentity: true, currentUserIsPending: state == "screening",
        currentUserRequiresOnboarding: state == "onboarding", currentUserOnboardingIsKnown: state != "unknown"
    )
    let access = AppModel.resolveConversationAccess(for: channel, permissionBasis: basis)
    #expect(access == (state == "unknown" ? .checking : .readable(canSend: state == "completed")))
    basis = ConversationPermissionBasis(guild: basis.guild, resolvedBasePermissions: 0,
        overwritePrincipals: basis.overwritePrincipals, hasCurrentRoleIdentity: true,
        currentUserIsPending: state == "screening", currentUserRequiresOnboarding: state == "onboarding")
    #expect(AppModel.resolveConversationAccess(for: channel, permissionBasis: basis) == .hidden)
}

@MainActor @Test func `webhook profiles remain scoped to each message instead of cached members`() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let user = User(id: UserID(rawValue: 300), username: "First persona", discriminator: "0000", displayName: "First persona", isBot: true)
    var first = Message(id: MessageID(rawValue: 100), channelID: ChannelID(rawValue: 200), author: user, webhookID: "300", content: "Test")
    let stale = Member(user: User(id: user.id, username: "Cached", displayName: "Cached"), roleName: "Cached role", status: .online)
    #expect(MessageAuthorPresentation.resolve(message: first, member: stale, roles: []).user == user)
    model.showProfile(for: user, sourceMessage: first)
    let initial = try #require(model.liveProfilePresentation(for: .contextual))
    #expect(initial.isWebhook && !initial.isLoading && initial.errorMessage == nil)
    #expect(model.contextualProfileTask == nil)
    first.author.displayName = "Second persona"
    first.author.avatarURL = URL(string: "https://cdn.discordapp.com/avatars/300/second.png")
    model.showProfile(for: first.author, sourceMessage: first)
    let second = try #require(model.liveProfilePresentation(for: .contextual))
    #expect(second.member.user == first.author)
    #expect(second.profile?.avatarURL == first.author.avatarURL)
    #expect(second.requestID != initial.requestID)
    #expect(model.profileCache.isEmpty)
    first.author.avatarURL = URL(string: "https://cdn.discordapp.com/avatars/300/ready.png")
    model.consumeMessageUpdated(first, preparedTextPlan: nil)
    let refreshed = try #require(model.liveProfilePresentation(for: .contextual))
    #expect(refreshed.requestID == second.requestID)
    #expect(refreshed.profile?.avatarURL == first.author.avatarURL)
    let other = Message(id: MessageID(rawValue: 101), channelID: first.channelID, author: user, webhookID: "300", content: "Other persona")
    model.consumeMessageUpdated(other, preparedTextPlan: nil)
    #expect(model.liveProfilePresentation(for: .contextual)?.member.user == first.author)
}

@Test func `change nickname follows Discord role hierarchy and protects the owner`() {
    let owner = UserID(rawValue: 9)
    let target = UserID(rawValue: 2)
    let roles = [
        GuildRole(id: RoleID(rawValue: 20), name: "Moderator", position: 3),
        GuildRole(id: RoleID(rawValue: 21), name: "Peer", position: 3),
        GuildRole(id: RoleID(rawValue: 30), name: "Member", position: 1),
        GuildRole(id: RoleID(rawValue: 100), name: "@everyone", position: 99),
    ]
    func can(
        _ targetUserID: UserID, _ targetRoleIDs: Set<RoleID>, permissions: UInt64,
        roleIDs: Set<RoleID> = [RoleID(rawValue: 20)], isOwner: Bool = false, ownerID: UserID? = owner
    ) -> Bool {
        NicknamePermissionPolicy.canChangeNickname(of: targetUserID, roleIDs: targetRoleIDs, in: .init(
            ownerID: ownerID, isOwner: isOwner, permissions: permissions, roleIDs: roleIDs, roles: roles,
            guildID: GuildID(rawValue: 100)
        ))
    }
    let manage = DiscordPermissionBits.manageNicknames

    #expect(can(target, [RoleID(rawValue: 30)], permissions: manage))
    #expect(can(target, [], permissions: manage))
    #expect(can(target, [RoleID(rawValue: 100)], permissions: manage))
    #expect(!can(target, [RoleID(rawValue: 30)], permissions: manage, roleIDs: [RoleID(rawValue: 100)]))
    #expect(!can(target, [RoleID(rawValue: 30)], permissions: DiscordPermissionBits.changeNickname))
    // An equal top role is not below ours; Discord breaks position ties by the older role.
    #expect(!can(target, [RoleID(rawValue: 20)], permissions: manage))
    #expect(can(target, [RoleID(rawValue: 21)], permissions: manage))
    // Administrators stay bound by hierarchy; only the owner bypasses it, and nobody renames the owner.
    #expect(!can(target, [RoleID(rawValue: 30)], permissions: DiscordPermissionBits.administrator, roleIDs: []))
    #expect(!can(owner, [], permissions: DiscordPermissionBits.administrator))
    #expect(can(target, [RoleID(rawValue: 20)], permissions: 0, roleIDs: [], isOwner: true))
    // Discord compares only loaded roles; unknown target roles have no highest role.
    #expect(can(target, [RoleID(rawValue: 30)], permissions: manage, ownerID: nil))
    #expect(can(target, [RoleID(rawValue: 99)], permissions: manage))
    #expect(!can(target, [], permissions: manage, roleIDs: [RoleID(rawValue: 99)]))
}

@Test func `nickname management follows Discord member restriction masks`() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let user = User(id: UserID(rawValue: 1), username: "moderator", displayName: "Moderator")
    let target = UserID(rawValue: 2)
    var context = NicknamePermissionPolicy.Context(
        ownerID: UserID(rawValue: 9), isOwner: false, permissions: DiscordPermissionBits.manageNicknames,
        roleIDs: [RoleID(rawValue: 20)], roles: [GuildRole(id: RoleID(rawValue: 20), name: "Moderator")]
    )
    func can(_ context: NicknamePermissionPolicy.Context) -> Bool {
        NicknamePermissionPolicy.canChangeNickname(of: target, roleIDs: [], in: context, now: now)
    }
    #expect(can(context))
    for flags: UInt64 in [16, 128, 256, 1024] {
        context.currentMember = Member(user: user, roleName: "Moderator", isOnline: true, flags: flags)
        #expect(!can(context))
    }
    context.currentMember = Member(user: user, roleName: "Moderator", isOnline: true, isPending: true)
    #expect(!can(context))
    context.currentMember?.isPending = false
    context.currentMember?.communicationDisabledUntil = now.addingTimeInterval(1)
    #expect(!can(context))
    context.currentMember?.communicationDisabledUntil = now
    #expect(can(context))

    // Administrator bypasses timeout and quarantine, but not pending/guest masks.
    context = .init(ownerID: context.ownerID, isOwner: false, permissions: DiscordPermissionBits.administrator,
                    roleIDs: context.roleIDs, roles: context.roles, currentMember: context.currentMember)
    context.currentMember?.communicationDisabledUntil = now.addingTimeInterval(1)
    context.currentMember?.flags = 128 | 256 | 1024
    #expect(can(context))
    context.currentMember?.isPending = true
    #expect(!can(context))
    context.currentMember?.isPending = false
    context.currentMember?.flags = 16
    #expect(!can(context))

    // Guild owners bypass the member masks entirely.
    context = .init(ownerID: user.id, isOwner: true, permissions: 0, roleIDs: [], roles: [],
                    currentMember: context.currentMember)
    #expect(can(context))
}
