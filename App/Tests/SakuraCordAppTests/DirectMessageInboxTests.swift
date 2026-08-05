import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `direct message inbox only includes existing private conversations`() {
    let maya = User(id: UserID(rawValue: 2), username: "maya.dev", displayName: "Maya")
    let theo = User(id: UserID(rawValue: 3), username: "theo", displayName: "Theodore")
    let channels = [
        Channel(
            id: ChannelID(rawValue: 40),
            guildID: nil,
            name: "Maya",
            kind: .directMessage,
            recipients: [maya]
        ),
        Channel(
            id: ChannelID(rawValue: 41),
            guildID: nil,
            name: "Design crew",
            kind: .groupDirectMessage,
            recipients: [maya, theo]
        ),
        Channel(
            id: ChannelID(rawValue: 42),
            guildID: GuildID(rawValue: 10),
            name: "maya-not-a-dm",
            kind: .text
        ),
    ]

    #expect(DirectMessageInboxPolicy.conversations(in: channels).map(\.id) == [
        ChannelID(rawValue: 40), ChannelID(rawValue: 41),
    ])
    #expect(DirectMessageInboxPolicy.secondaryText(for: channels[0]) == nil)
    #expect(
        DirectMessageInboxPolicy.secondaryText(for: channels[1])
            == "3 members"
    )
}

@Test func `direct message inbox resolves presence and custom status by recipient`() throws {
    let maya = User(id: UserID(rawValue: 2), username: "maya.dev", displayName: "Maya")
    let channel = Channel(
        id: ChannelID(rawValue: 40),
        guildID: nil,
        name: "Maya",
        kind: .directMessage,
        recipients: [maya]
    )
    let member = Member(
        user: maya,
        roleName: "Direct Message",
        status: .idle,
        customStatus: "  Shipping tiny details  "
    )

    let resolved = try #require(
        DirectMessageInboxPolicy.recipientMember(
            for: channel,
            membersByID: [maya.id: member]
        )
    )
    #expect(resolved.status == .idle)
    #expect(
        DirectMessageInboxPolicy.secondaryText(for: channel, member: resolved)
            == "Shipping tiny details"
    )
}

@Test func `direct message inbox only surfaces actively ringing calls`() {
    let channelID = ChannelID(rawValue: 40)
    let ongoing = PrivateCall(
        channelID: channelID,
        voiceStates: []
    )
    let ringing = PrivateCall(
        channelID: channelID,
        ongoingRings: [
            PrivateCallRing(
                recipientID: UserID(rawValue: 2),
                senderID: UserID(rawValue: 3)
            )
        ],
        voiceStates: []
    )

    #expect(DirectMessageInboxPolicy.callStatus(for: ongoing) == nil)
    #expect(DirectMessageInboxPolicy.callStatus(for: ringing) == "Ringing")
}

@Test func `nameplate presentation matches Paicord palette and hover opacity`() {
    #expect(
        NameplatePresentationPolicy.colors(for: "violet")
            == NameplatePaletteColors(light: 0x972FED, dark: 0x730BC8)
    )
    #expect(NameplatePresentationPolicy.colors(for: "none") == nil)
    #expect(NameplatePresentationPolicy.colors(for: "unknown") == nil)
    #expect(NameplatePresentationPolicy.opacity(isHovered: false) == 0.5)
    #expect(NameplatePresentationPolicy.opacity(isHovered: true) == 0.8)
}

@Test func `composer prompts distinguish private conversations from channels`() {
    #expect(
        ComposerPlaceholderPolicy.text(
            channelName: "Maya Ortiz",
            channelKind: .directMessage,
            destination: .channel
        ) == "Message @Maya Ortiz"
    )
    #expect(
        ComposerPlaceholderPolicy.text(
            channelName: "Design crew",
            channelKind: .groupDirectMessage,
            destination: .channel
        ) == "Message @Design crew"
    )
    #expect(
        ComposerPlaceholderPolicy.text(
            channelName: "general",
            channelKind: .text,
            destination: .channel
        ) == "Message #general"
    )
    #expect(
        ComposerPlaceholderPolicy.text(
            channelName: "support thread",
            channelKind: .directMessage,
            destination: .thread
        ) == "Message #support thread"
    )
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func `large direct message inbox filtering remains bounded`() {
    let channels = (0 ..< 10_000).map { index in
        let user = User(
            id: UserID(rawValue: UInt64(index + 2)),
            username: "person-\(index)",
            displayName: "Person \(index)"
        )
        return Channel(
            id: ChannelID(rawValue: UInt64(index + 100)),
            guildID: nil,
            name: user.displayName,
            kind: .directMessage,
            recipients: [user]
        )
    }

    #expect(
        DirectMessageInboxPolicy.conversations(in: channels).count == 10_000
    )
}

@MainActor
@Test func `selecting an existing direct message uses the shared timeline and profile`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let existing = try #require(
        model.snapshot?.channels.first {
            $0.kind == .directMessage && $0.recipients.count == 1
        }
    )
    let recipient = try #require(existing.recipients.first)
    let guildPresentationRevision = model.timelinePresentationRevision
    model.selectGuild(nil)
    #expect(await waitForDirectMessageCondition { model.selectedGuildID == nil })
    #expect(model.timelinePresentationRevision > guildPresentationRevision)
    model.selectedChannelID = existing.id
    #expect(await waitForDirectMessageCondition {
        model.selectedChannelID == existing.id
            && model.selectedChannel?.kind == .directMessage
    })
    model.showInspectorProfile(for: recipient)

    #expect(model.selectedGuildID == nil)
    #expect(model.selectedChannelID == existing.id)
    #expect(model.selectedChannel?.kind == .directMessage)
    #expect(model.inspectorProfilePresentation?.member.id == recipient.id)
}

@MainActor
@Test func `group direct messages retain the participant list inspector`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let group = try #require(
        model.snapshot?.channels.first { $0.kind == .groupDirectMessage }
    )

    model.selectGuild(nil)
    #expect(await waitForDirectMessageCondition { model.selectedGuildID == nil })
    model.selectedChannelID = group.id
    #expect(await waitForDirectMessageCondition {
        model.selectedChannelID == group.id
            && model.selectedChannel?.kind == .groupDirectMessage
    })
    let currentUserID = try #require(model.snapshot?.currentUser.id)
    #expect(
        Set(model.directMessageInspectorSections.flatMap(\.members).map(\.id))
            == Set(group.recipients.map(\.id) + [currentUserID])
    )
}

@MainActor
@Test func `group direct message participants reconcile a partial owner payload`() {
    let currentUser = User(
        id: UserID(rawValue: 1),
        username: "current",
        displayName: "Current"
    )
    let owner = User(
        id: UserID(rawValue: 2),
        username: "owner",
        displayName: "Owner"
    )
    let recipient = User(
        id: UserID(rawValue: 3),
        username: "recipient",
        displayName: "Recipient"
    )
    let channel = Channel(
        id: ChannelID(rawValue: 40),
        guildID: nil,
        name: "Group",
        ownerID: owner.id,
        kind: .groupDirectMessage,
        recipients: [currentUser, recipient]
    )
    let members = DirectMessageMemberResolver.members(
        for: channel,
        knownMembers: [
            Member(user: owner, roleName: "Members", status: .offline),
            Member(user: recipient, roleName: "Members", status: .online),
        ],
        currentUser: currentUser,
        currentStatus: .offline
    )

    #expect(members.map(\.id) == [recipient.id, owner.id, currentUser.id])
    #expect(Set(members.map(\.id)).count == 3)
    #expect(MemberSection.make(from: members).flatMap(\.members).count == 3)
}

@MainActor
@Test func `changing conversations dismisses an open group member profile`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let group = try #require(
        model.snapshot?.channels.first { $0.kind == .groupDirectMessage }
    )
    let directMessage = try #require(
        model.snapshot?.channels.first { $0.kind == .directMessage }
    )
    let member = try #require(group.recipients.first)

    model.selectGuild(nil)
    #expect(await waitForDirectMessageCondition { model.selectedGuildID == nil })
    model.selectedChannelID = group.id
    #expect(await waitForDirectMessageCondition {
        model.selectedChannelID == group.id
    })
    model.selectMember(
        Member(user: member, roleName: "Direct Message", status: .offline)
    )
    #expect(model.isInspectorProfilePresented)

    model.selectedChannelID = directMessage.id

    #expect(!model.isInspectorProfilePresented)
    #expect(model.inspectorProfilePresentation == nil)
}

@MainActor
@Test func `profile banners stay constrained to their presentation width`() {
    #expect(ProfileBannerLayout.constrainedWidth(280) == 280)
    #expect(ProfileBannerLayout.constrainedWidth(MemberProfilePopover.preferredWidth) == 330)
    #expect(ProfileBannerLayout.constrainedWidth(-20) == 0)
    #expect(ProfileBannerLayout.constrainedWidth(.infinity) == 0)
}

@MainActor
@Test func `positioned profile effect layers retain the canonical canvas`() throws {
    let animation = ProfileEffectAnimation(
        sourceURL: try #require(URL(string: "https://cdn.example/profile-effect.png")),
        width: 250,
        height: 400
    )

    let frame = try #require(ProfileEffectLayout.frames(
        for: [animation],
        containerWidth: MemberProfilePopover.preferredWidth
    ).first)

    #expect(ProfileEffectLayout.designWidth(for: [animation]) == 450)
    #expect(frame.width == 183.33333333333331)
    #expect(frame.height == 293.3333333333333)
}

@MainActor
@Test func `dimensionless profile effect layers use the canonical profile canvas`() throws {
    let animation = ProfileEffectAnimation(
        sourceURL: try #require(URL(string: "https://cdn.example/dimensionless-effect.png"))
    )
    let frame = try #require(ProfileEffectLayout.frames(for: [animation], containerWidth: 330).first)

    #expect(ProfileEffectLayout.designWidth(for: [animation]) == 450)
    #expect(frame == CGRect(x: 0, y: 0, width: 330, height: 645.3333333333333))
}

@MainActor
@Test func `official Discord system direct messages are read only`() {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    let officialUser = User(
        id: UserID(rawValue: 99),
        username: "discord",
        displayName: "Discord",
        isSystem: true
    )
    let officialChannel = Channel(
        id: ChannelID(rawValue: 50),
        guildID: nil,
        name: "Discord",
        kind: .directMessage,
        recipients: [officialUser]
    )
    let ordinaryChannel = Channel(
        id: ChannelID(rawValue: 51),
        guildID: nil,
        name: "Maya",
        kind: .directMessage,
        recipients: [
            User(
                id: UserID(rawValue: 2),
                username: "maya",
                displayName: "Maya"
            )
        ]
    )

    #expect(officialChannel.isOfficialSystemDirectMessage)
    #expect(
        model.conversationAccess(for: officialChannel)
            == .readable(canSend: false)
    )
    #expect(
        model.conversationAccess(for: ordinaryChannel)
            == .readable(canSend: true)
    )
}

@MainActor
private func waitForDirectMessageCondition(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}
