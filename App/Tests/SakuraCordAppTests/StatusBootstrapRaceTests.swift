import DiscordProtocol
import Foundation
import Observation
@testable import SakuraCord
import SakuraCordModels
import Testing

enum StatusBootstrapReadStage: CaseIterable, Sendable { case snapshot, currentStatus }

@MainActor
@Test(.timeLimit(.minutes(1)), arguments: StatusBootstrapReadStage.allCases)
func `a newer account status event survives an earlier gated bootstrap snapshot`(stage: StatusBootstrapReadStage) async throws {
    let provider = GatedBootstrapRaceProvider(stage: stage)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    let start = Task { await model.start() }
    await provider.waitForStaleRead()
    await provider.publishStatus(.dnd)
    var observed = false
    for await status in Observations({ model.currentStatus }) where status == .dnd {
        observed = true
        break
    }
    if !observed { start.cancel() }
    await provider.releaseBootstrap()
    await cancellableValue(of: start)
    guard observed else {
        await provider.disconnect()
        try #require(observed, "The newer event must be consumed before releasing the old snapshot")
        return
    }
    #expect(await provider.currentStatus() == .dnd)
    #expect(model.currentStatus == .dnd, "The earlier snapshot must not overwrite the consumed status event")
    let selfID = try #require(model.snapshot?.currentUser.id)
    if let guildID = model.selectedGuildID {
        let stale = Member(user: try #require(model.snapshot?.currentUser), roleName: "Member", status: .online)
        model.consumeMembersChanged(guildID: guildID, members: [stale], groups: [])
        #expect(model.members.first { $0.id == selfID }?.status == .dnd)
    }
    await provider.disconnect()
}

actor GatedBootstrapRaceProvider: ChatProvider {
    private let base = MockChatProvider()
    private let stage: StatusBootstrapReadStage

    private let timeoutRemoval: Bool?
    private let until = Date.now.addingTimeInterval(300)

    init(stage: StatusBootstrapReadStage = .snapshot, timeoutRemoval: Bool? = nil) {
        self.stage = stage
        self.timeoutRemoval = timeoutRemoval
    }
    private let captured = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()
    private let events = AsyncStream<ClientEvent>.makeStream()
    private var status = PresenceStatus.online
    private var snapshot: BootstrapSnapshot?

    func bootstrap() async throws -> BootstrapSnapshot {
        var value = try await base.bootstrap()
        value.members.removeAll { $0.id == value.currentUser.id }
        if let timeoutRemoval {
            let guildID = try #require(value.guilds.first?.id)
            value.guilds[0].isOwnedByCurrentUser = false
            value.guilds[0].currentUserPermissions = (1 << 10) | (1 << 11) | (1 << 16)
            value.guilds[0].features = []
            var member = Member(user: value.currentUser, roleName: "Member", isOnline: false)
            member.communicationDisabledUntil = timeoutRemoval ? until : nil
            value.currentMembersByGuildID = [guildID: member]
            value.members = []
        } else if stage == .snapshot {
            value.members.append(Member(user: value.currentUser, roleName: "Member", status: .online))
        }
        snapshot = value
        if stage == .snapshot { await holdStaleRead() }
        try Task.checkCancellation()
        return value
    }
    func waitForStaleRead() async { for await _ in captured.stream { break } }
    private func holdStaleRead() async {
        captured.continuation.yield(())
        captured.continuation.finish()
        for await _ in release.stream { break }
    }
    func releaseBootstrap() { release.continuation.yield(()); release.continuation.finish() }
    func publishTimeoutChange() throws {
        let value = try #require(snapshot)
        let guildID = try #require(value.guilds.first?.id)
        var member = try #require(value.currentMembersByGuildID[guildID])
        member.communicationDisabledUntil = timeoutRemoval == true ? nil : until
        events.continuation.yield(.membersChanged(guildID: guildID, members: [member], groups: []))
        publishStatus(.dnd)
    }
    func publishStatus(_ value: PresenceStatus) { status = value; events.continuation.yield(.currentUserStatusChanged(value)) }
    func currentStatus() async -> PresenceStatus {
        let value = status
        if stage == .currentStatus { await holdStaleRead() }
        return value
    }
    func updateStatus(_ value: PresenceStatus) async throws { publishStatus(value) }
    func eventStream() async -> AsyncStream<ClientEvent> { events.stream }
    func channels(in guildID: GuildID?) async throws -> [Channel] { try await base.channels(in: guildID) }
    func members(in guildID: GuildID?) async throws -> [Member] { snapshot?.members ?? [] }
    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile { try await base.profile(for: userID, in: guildID) }
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage { try await base.messages(in: channelID, before: before, limit: limit) }
    func send(_ draft: SendMessageDraft) async throws -> Message { try await base.send(draft) }
    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message { try await base.edit(messageID: messageID, channelID: channelID, content: content) }
    func delete(messageID: MessageID, channelID: ChannelID) async throws { try await base.delete(messageID: messageID, channelID: channelID) }
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws { try await base.toggleReaction(emoji, messageID: messageID, channelID: channelID) }
    func disconnect() async { releaseBootstrap(); events.continuation.finish() }
}
