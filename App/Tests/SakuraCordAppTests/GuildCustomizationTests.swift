import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
struct GuildCustomizationTests {
    @Test(.timeLimit(.minutes(1)))
    func `returning to onboarding preserves the cached question and advancing cannot strand a refresh`() async throws {
        let provider = try CustomizationProvider()
        let model = AppModel(launchMode: .offlineTesting, provider: provider)
        await model.start()
        let configuration = await provider.configuration
        let guildID = configuration.guildID
        let guildIndex = try #require(model.snapshot?.guilds.firstIndex { $0.id == guildID })
        model.snapshot?.guilds[guildIndex].features.insert("GUILD_ONBOARDING")
        model.serverRailGuildsByID[guildID]?.features.insert("GUILD_ONBOARDING")
        model.onboarding.members[guildID] = try await provider.refreshCurrentMember(in: guildID)
        model.onboarding.entries[guildID] = .init(configuration: configuration, responses: ["required"], promptID: "1", initial: true, refreshedAt: .now)
        await model.activateGuild(nil)
        await model.activateGuild(guildID)
        #expect(await provider.readCount == 0)
        #expect(model.onboarding.entries[guildID]?.promptID == "1")
        #expect(model.onboarding.entries[guildID]?.responses == ["required"])
        #expect(model.onboarding.entries[guildID]?.isLoading == false)

        model.refreshOnboarding(in: guildID)
        model.setOnboardingPrompt("1", guildID: guildID)
        for task in Array(model.accountChildTasks.values) { await task.value }
        #expect(await provider.readCount == 1)
        #expect(model.onboarding.entries[guildID]?.isLoading == false)
        #expect(model.onboarding.entries[guildID]?.promptID == "1")
        #expect(model.onboarding.entries[guildID]?.responses == ["required"])
    }

    @Test(.timeLimit(.minutes(1)))
    func `answer bursts coalesce and old confirmations cannot replace newer input`() async throws {
        let provider = try CustomizationProvider()
        let clock = CustomizationGate()
        var ticks = clock.arrivals.makeAsyncIterator()
        var writes = provider.writes.makeAsyncIterator()
        let model = AppModel(launchMode: .offlineTesting, provider: provider)
        let configuration = await provider.configuration
        let guildID = configuration.guildID
        model.onboarding.entries[guildID] = .init(configuration: configuration, responses: ["required"])
        model.onboarding.customizationDebounce = { await clock.wait() }
        let prompt = try #require(configuration.prompts.last)
        let a = prompt.options[0], b = prompt.options[1]
        let required = try #require(configuration.prompts.first)
        model.setOnboardingOptions([], prompt: required, guildID: guildID)
        #expect(model.onboarding.entries[guildID]?.responses == ["required"])
        model.setOnboardingOptions(["a"], prompt: prompt, guildID: guildID)
        model.setOnboardingOptions(["a", "b"], prompt: prompt, guildID: guildID)
        model.setOnboardingOptions(["b", "deleted"], prompt: prompt, guildID: guildID)
        #expect(model.onboarding.entries[guildID]?.responses == ["required", "b"])
        _ = await ticks.next()
        #expect(await provider.writeCount == 0)
        await clock.release()
        #expect(await writes.next() == .answers(["required", "b"]))

        model.selectOnboardingOption(a, prompt: prompt, guildID: guildID)
        model.selectOnboardingOption(b, prompt: prompt, guildID: guildID)
        #expect(model.onboarding.entries[guildID]?.responses == ["required", "a"])
        await provider.finish(success: true)
        _ = await ticks.next()
        #expect(model.onboarding.entries[guildID]?.responses == ["required", "a"])
        #expect(model.onboarding.entries[guildID]?.configuration?.responses.sorted() == ["b", "required"])
        await clock.release()
        #expect(await writes.next() == .answers(["required", "a"]))
        let tasks = Array(model.accountChildTasks.values)
        await provider.finish(success: false)
        for task in tasks { await task.value }
        #expect(model.onboarding.entries[guildID]?.responses == ["required", "b"])
        #expect(model.onboarding.entries[guildID]?.error != nil)
        #expect(model.onboarding.entries[guildID]?.isSaving == false)

        model.selectOnboardingOption(a, prompt: prompt, guildID: guildID)
        _ = await ticks.next()
        let abandoned = Array(model.accountChildTasks.values)
        model.invalidateAccountSession()
        await clock.release()
        for task in abandoned { await task.value }
        #expect(await provider.writeCount == 2)
        #expect(model.onboarding.entries.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `channel edits are optimistic batched and rollback preserves unrelated server updates`() async throws {
        let provider = try CustomizationProvider()
        let clock = CustomizationGate()
        var ticks = clock.arrivals.makeAsyncIterator()
        var writes = provider.writes.makeAsyncIterator()
        let model = AppModel(launchMode: .offlineTesting, provider: provider)
        let guildID = GuildID(rawValue: 100)
        let a = ChannelID(rawValue: 200), b = ChannelID(rawValue: 201)
        model.featuresSettings.channelManagement = false
        model.setChannelSelected(true, channelID: a, guildID: guildID)
        #expect(model.onboarding.channelSelections.isEmpty)
        model.featuresSettings.channelManagement = true
        model.onboarding.customizationDebounce = { await clock.wait() }
        var confirmed = GuildNotificationSettings(guildID: guildID, flags: GuildChannelSelection.enabledFlag | 4)
        model.applyNotificationSettings(confirmed)
        model.setChannelSelected(true, channelID: a, guildID: guildID)
        model.setChannelSelected(true, channelID: b, guildID: guildID)
        model.setChannelSelected(false, channelID: a, guildID: guildID)
        #expect(GuildChannelSelection.isSelected(b, settings: model.presentedGuildChannelSettings(in: guildID)))
        #expect(!GuildChannelSelection.isSelected(a, settings: model.presentedGuildChannelSettings(in: guildID)))
        _ = await ticks.next()
        await clock.release()
        #expect(await writes.next() == .channels(nil, [a: false, b: true]))
        confirmed.isMuted = true
        confirmed.flags |= 8
        model.applyNotificationSettings(confirmed)
        let tasks = Array(model.accountChildTasks.values)
        await provider.finish(success: false)
        for task in tasks { await task.value }
        #expect(model.presentedGuildChannelSettings(in: guildID) == confirmed)
        #expect(await provider.writeCount == 1)
    }
}

private actor CustomizationGate {
    nonisolated let arrivals: AsyncStream<Void>
    private let events: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<Void, Never>?
    init() { (arrivals, events) = AsyncStream.makeStream() }
    func wait() async {
        await withCheckedContinuation { pending = $0; events.yield(()) }
    }
    func release() { pending?.resume(); pending = nil }
}

private actor CustomizationProvider: ChatProvider {
    enum Write: Equatable, Sendable {
        case answers(Set<String>)
        case channels(Bool?, [ChannelID: Bool])
    }
    nonisolated let writes: AsyncStream<Write>
    private let events: AsyncStream<Write>.Continuation
    private let base = MockChatProvider()
    private var completion: CheckedContinuation<Bool, Never>?
    private(set) var writeCount = 0
    private(set) var readCount = 0
    private(set) var configuration: GuildOnboarding
    init() throws {
        (writes, events) = AsyncStream.makeStream()
        configuration = try JSONDecoder().decode(GuildOnboarding.self, from: Data(#"""
        {"guild_id":"100","enabled":true,"default_channel_ids":[],"responses":["required"],"prompts":[
        {"id":"1","title":"Track","type":0,"single_select":true,"required":true,"in_onboarding":true,"options":[
        {"id":"required","title":"Required","role_ids":[],"channel_ids":[]}]},
        {"id":"2","title":"Interests","type":0,"single_select":false,"required":false,"in_onboarding":false,"options":[
        {"id":"a","title":"A","role_ids":[],"channel_ids":[]},{"id":"b","title":"B","role_ids":[],"channel_ids":[]}]}]}
        """#.utf8))
    }
    private func record(_ write: Write) async throws {
        writeCount += 1
        let success = await withCheckedContinuation { completion = $0; events.yield(write) }
        if !success { throw ChatProviderError.invalidRequest("Test request failed") }
    }
    func finish(success: Bool) { completion?.resume(returning: success); completion = nil }
    func guildOnboarding(in guildID: GuildID) async throws -> GuildOnboarding { readCount += 1; return configuration }
    func refreshCurrentMember(in guildID: GuildID) async throws -> Member {
        let snapshot = try await base.bootstrap()
        var member = Member(user: snapshot.currentUser, roleName: "", isOnline: false)
        member.flags = 9
        member.joinedAt = Date(timeIntervalSince1970: 1_790_000_000)
        return member
    }
    func saveGuildOnboarding(in guildID: GuildID, responses: Set<String>, initial: Bool) async throws -> GuildOnboarding {
        try await record(.answers(responses))
        configuration.responses = responses.sorted()
        return configuration
    }
    func updateGuildChannelSelection(in guildID: GuildID, enabled: Bool?, channels: [ChannelID: Bool]) async throws -> GuildNotificationSettings {
        try await record(.channels(enabled, channels))
        return GuildNotificationSettings(guildID: guildID)
    }
    func bootstrap() async throws -> BootstrapSnapshot { try await base.bootstrap() }
    func channels(in guildID: GuildID?) async throws -> [Channel] { try await base.channels(in: guildID) }
    func members(in guildID: GuildID?) async throws -> [Member] { try await base.members(in: guildID) }
    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile { try await base.profile(for: userID, in: guildID) }
    func currentStatus() async -> PresenceStatus { .offline }
    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage { try await base.messages(in: channelID, before: before, limit: limit) }
    func send(_ draft: SendMessageDraft) async throws -> Message { try await base.send(draft) }
    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message { try await base.edit(messageID: messageID, channelID: channelID, content: content) }
    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
}
