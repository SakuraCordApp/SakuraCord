import DiscordProtocol
import Foundation
import Observation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
struct HumanCaptchaTests {
    @Test func `CAPTCHA completion ignores stale callbacks and consumes its continuation once`() async throws {
        let store = HumanCaptchaStore.serverInvites()
        let challenge = makeChallenge()
        let task = Task { try await store.solution(for: challenge) }
        #expect(await presented(store, id: challenge.id))
        store.complete(id: UUID(), token: "stale-solution")
        #expect(store.challenge?.id == challenge.id)
        await #expect(throws: ServerInviteError.self) { try await store.solution(for: makeChallenge()) }
        store.complete(id: challenge.id, token: "human-solution")
        store.complete(id: challenge.id, token: "duplicate-solution")
        #expect(try await task.value == "human-solution")
        #expect(store.challenge == nil)
    }

    @Test(arguments: ["close", "account-reset", "task-cancel", "failure"])
    func `dismissing or invalidating a challenge always releases the waiting join`(action: String) async {
        let invites = ServerInvitePresentationStore()
        let store = invites.captcha
        let challenge = makeChallenge()
        let task = Task { try await store.solution(for: challenge) }
        #expect(await presented(store, id: challenge.id))
        switch action {
        case "close": store.cancel()
        case "account-reset": invites.reset()
        case "task-cancel": task.cancel()
        default: store.complete(id: challenge.id, token: nil)
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(store.challenge == nil)
        let replacement = makeChallenge()
        let next = Task { try await store.solution(for: replacement) }
        #expect(await presented(store, id: replacement.id))
        store.complete(id: challenge.id, token: "late-old-account-token")
        store.cancel(id: challenge.id)
        #expect(store.challenge?.id == replacement.id)
        store.cancel()
        await #expect(throws: CancellationError.self) { try await next.value }
    }

    @Test(arguments: [true, false])
    func `invite and tag cards cannot join the same guild concurrently`(inviteFirst: Bool) async throws {
        let provider = SharedJoinProbeProvider()
        let model = AppModel(launchMode: .offlineTesting, provider: provider)
        let guildID = GuildID(rawValue: 950)
        let reference = try #require(ServerInviteReference("probe"))
        model.serverInvites.entries[reference] = .init(invite: .init(reference: reference, guildID: guildID, name: "Probe"))
        let profile = try JSONDecoder().decode(GuildProfile.self, from: Data(#"{"id":"950","name":"Probe","features":["DISCOVERABLE"]}"#.utf8))
        model.serverTagCards.entries[guildID] = .init(content: .loaded(profile))
        var arrivals = provider.arrivals.makeAsyncIterator()
        let first = Task {
            if inviteFirst { await model.activateServerInvite(reference) }
            else { await model.activateServerTagCard(guildID) }
        }
        _ = await arrivals.next()
        let second = if inviteFirst { await model.activateServerTagCard(guildID) }
            else { await model.activateServerInvite(reference) }
        #expect(!second)
        let joinCount = await provider.joinCount
        #expect(joinCount == 1)
        await provider.finish()
        #expect(await !first.value)
    }

    private func makeChallenge() -> DiscordCaptchaChallenge {
        .init(siteKey: "fixture", rqdata: nil, rqtoken: nil, sessionID: nil, shouldServeInvisible: false)
    }

    private func presented(_ store: HumanCaptchaStore, id: UUID) async -> Bool {
        if store.challenge?.id == id { return true }
        // Wait for publication rather than racing other main-actor tests
        // against a wall-clock deadline on a busy CI runner.
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = store.challenge
            } onChange: {
                continuation.resume()
            }
        }
        return store.challenge?.id == id
    }
}

private actor SharedJoinProbeProvider: ChatProvider {
    nonisolated let arrivals: AsyncStream<Void>
    private let events: AsyncStream<Void>.Continuation
    private let base = MockChatProvider()
    private var completion: CheckedContinuation<Void, Never>?
    private(set) var joinCount = 0

    init() { (arrivals, events) = AsyncStream.makeStream() }
    private func join() async throws {
        joinCount += 1
        if joinCount == 1 {
            await withCheckedContinuation { completion = $0; events.yield(()) }
        }
        throw ServerInviteError.failed("Probe stopped before remote membership")
    }
    func finish() { completion?.resume(); completion = nil }
    func acceptServerInvite(_ reference: ServerInviteReference, messageID: MessageID?, captchaHandler: DiscordCaptchaHandler?) async throws -> ServerInviteAcceptance {
        try await join()
        throw CancellationError()
    }
    func joinDiscoverableGuild(_ guildID: GuildID, captchaHandler: DiscordCaptchaHandler?) async throws -> Bool {
        try await join()
        return false
    }
    func bootstrap() async throws -> BootstrapSnapshot { try await base.bootstrap() }
    func channels(in guildID: GuildID?) async throws -> [Channel] { [] }
    func members(in guildID: GuildID?) async throws -> [Member] { [] }
    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile { try await base.profile(for: userID, in: guildID) }
    func currentStatus() async -> PresenceStatus { .offline }
    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage { .init(messages: [], hasMoreBefore: false) }
    func send(_ draft: SendMessageDraft) async throws -> Message { throw CancellationError() }
    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message { throw CancellationError() }
    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
}
