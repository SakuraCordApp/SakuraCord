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
