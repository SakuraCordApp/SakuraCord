import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `profile presentation retains rich activity when opened from message context`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()

    let guildID = GuildID(rawValue: 101)
    let channelID = ChannelID(rawValue: 201)
    let user = User(id: UserID(rawValue: 301), username: "game_dev", displayName: "Game Developer")
    let richActivity = MemberRichActivity(name: "Visual Studio Code", details: "Coding Rust", state: "Workspace: engine")
    let member = Member(
        user: user,
        roleName: "Engineer",
        status: .online,
        activityText: "Coding Rust",
        richActivity: richActivity
    )

    model.membersByGuildID[guildID] = [user.id: member]
    let message = Message(
        id: MessageID(rawValue: 401),
        channelID: channelID,
        author: user,
        content: "Check this out @\(user.username)",
        guildID: guildID
    )

    // Simulating tapping a mention or avatar in chat, passing the source message
    model.showProfile(for: user, sourceMessage: message)

    let contextual = try #require(model.contextualProfilePresentation)
    #expect(contextual.guildID == guildID)
    #expect(contextual.member.richActivity?.name == "Visual Studio Code")
    #expect(contextual.member.richActivity?.details == "Coding Rust")

    let live = try #require(model.liveProfilePresentation(for: .contextual))
    #expect(live.member.richActivity?.name == "Visual Studio Code")
}

@MainActor
@Test func `direct message profile inspector hydrates rich activity from mutual guild presence`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()

    // Inside DM: selectedGuildID is nil
    model.selectedGuildID = nil

    let mutualGuildID = GuildID(rawValue: 501)
    let friendUser = User(id: UserID(rawValue: 601), username: "streamer", displayName: "Streamer Friend")
    let richActivity = MemberRichActivity(name: "OBS Studio", details: "Live on Twitch", state: "Streaming SakuraCord")
    let guildMember = Member(
        user: friendUser,
        roleName: "VIP",
        status: .online,
        activityText: "Live on Twitch",
        richActivity: richActivity
    )

    // The user's presence and rich activity is known from a mutual guild
    model.membersByGuildID[mutualGuildID] = [friendUser.id: guildMember]

    // Open DM right-side inspector profile for this user
    model.showInspectorProfile(for: friendUser)

    let inspector = try #require(model.inspectorProfilePresentation)
    #expect(inspector.member.richActivity?.name == "OBS Studio")
    #expect(inspector.member.richActivity?.details == "Live on Twitch")
    #expect(inspector.member.status == .online)

    let liveInspector = try #require(model.liveProfilePresentation(for: .inspector))
    #expect(liveInspector.member.richActivity?.name == "OBS Studio")
    #expect(liveInspector.member.status == .online)
}

@MainActor
@Test func `liveProfilePresentation preserves existing rich activity across live member updates without rich activity`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()

    let guildID = GuildID(rawValue: 701)
    let user = User(id: UserID(rawValue: 801), username: "musician", displayName: "Musician")
    let initialRichActivity = MemberRichActivity(name: "Spotify", details: "Track A", state: "Artist B")
    var member = Member(
        user: user,
        roleName: "Member",
        status: .online,
        activityText: "Listening to Spotify",
        richActivity: initialRichActivity
    )

    model.membersByGuildID[guildID] = [user.id: member]
    model.presentProfile(for: member, in: guildID, destination: .contextual)

    #expect(model.contextualProfilePresentation?.member.richActivity?.name == "Spotify")

    // Simulate member store being updated by an event that lacks richActivity (e.g. offline or partial member sync)
    member.richActivity = nil
    model.membersByGuildID[guildID] = [user.id: member]

    // liveProfilePresentation must preserve the active richActivity
    let live = try #require(model.liveProfilePresentation(for: .contextual))
    #expect(live.member.richActivity?.name == "Spotify")
    #expect(live.member.richActivity?.details == "Track A")
}
