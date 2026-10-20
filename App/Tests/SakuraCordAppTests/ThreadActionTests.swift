import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `thread actions offer notification settings only once joined and invoke the model`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first { $0.kind == .forum })
    model.selectedChannelID = forum.id
    #expect(await until { model.hasLoadedForumPosts })
    let post = try #require(model.forumCataloguePosts.first {
        !$0.thread.isArchived && !$0.thread.isLocked && $0.thread.notificationSettings == nil
    })
    func entries() -> [String: ThreadMenuEntry] {
        let menu = ThreadActionsMenu(model: model, thread: post.thread, surface: .forumCard, offersTags: true)
        return Dictionary(menu.sections.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    func invoke(_ id: String) throws {
        guard case .action(let action)? = entries()[id]?.content else { throw CancellationError() }
        action()
    }

    // The offline account manages threads, so moderation is offered.
    #expect(["membership", "rename", ThreadActionsMenu.tagsSlotID, "archive", "lock", "pin", "delete"]
        .allSatisfy { entries()[$0] != nil })
    #expect(entries()["mute"] == nil && entries()["notifications"] == nil)

    try invoke("membership")
    #expect(await until {
        model.forumCataloguePosts.first { $0.id == post.id }?.thread.notificationSettings != nil
    })
    #expect(entries()["mute"] != nil && entries()["notifications"] != nil)
    try invoke("rename")
    #expect(model.threadActions.renaming?.id == post.id)
}

@MainActor
@Test func `joining from the side pane keeps it open and a rename reaches every projection`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    model.selectGuild(GuildID(rawValue: 101))
    await model.guildActivationTask?.value
    model.selectedChannelID = ChannelID(rawValue: 301)
    #expect(await eventually { !model.messages.isEmpty })
    let parent = try #require(model.selectedChannel)
    let starter = try #require(model.messages.last)
    let thread = try await provider.createThread(.startingFrom(starter, in: parent, name: "Release notes"))
    #expect(await eventually { model.messages.first { $0.id == starter.id }?.thread?.id == thread.id })
    model.open(thread)
    #expect(model.openThread?.id == thread.id && !model.isThreadFullWidth)

    model.setThreadMembership(thread, isJoined: false, surface: .sidePane)
    #expect(await eventually { model.snapshot?.activeJoinedThreads.contains { $0.id == thread.id } == false })
    model.setThreadMembership(thread, isJoined: true, surface: .sidePane)
    #expect(await eventually { model.snapshot?.activeJoinedThreads.contains { $0.id == thread.id } == true })
    #expect(model.openThread?.id == thread.id)

    model.presentThreadRename(thread)
    #expect(model.threadActions.draftName == thread.name)
    model.threadActions.draftName = "  Renamed thread  "
    model.saveThreadRename()
    #expect(await eventually { model.threadActions.renaming == nil })
    #expect(await eventually {
        model.presentedSideConversation.map { model.sideConversationLabel($0).title } == "Renamed thread"
    })
    #expect(model.openThread?.name == "Renamed thread")
    #expect(await eventually { model.snapshot?.activeJoinedThreads.first { $0.id == thread.id }?.name == "Renamed thread" })
    #expect(await eventually { model.messages.first { $0.id == starter.id }?.thread?.name == "Renamed thread" })
}
