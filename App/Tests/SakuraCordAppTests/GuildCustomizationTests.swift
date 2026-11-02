import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
struct GuildCustomizationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `onboarding refresh preserves a timeout changed while configuration is loading`(removingTimeout: Bool) async throws {
        let provider = try CustomizationProvider()
        let model = AppModel(launchMode: .offlineTesting, provider: provider)
        await model.start()
        await model.memberLoadTask?.value
        let guildID = await provider.configuration.guildID
        let until = Date.now.addingTimeInterval(300)
        var member = try await provider.refreshCurrentMember(in: guildID)
        member.communicationDisabledUntil = removingTimeout ? until : nil
        model.receiveOnboardingMember(member, guildID: guildID)
        let gate = CustomizationGate()
        var reads = provider.refreshedMembers.makeAsyncIterator()
        // Discard the setup read before arming the delayed configuration.
        _ = await reads.next()
        var arrivals = gate.arrivals.makeAsyncIterator()
        await provider.holdOnboardingRead(on: gate, memberTimeout: member.communicationDisabledUntil)

        model.refreshOnboarding(in: guildID)
        _ = await arrivals.next()
        _ = await reads.next()
        let pending = Array(model.accountChildTasks.values)
        member.communicationDisabledUntil = removingTimeout ? nil : until
        model.consumeMembersChanged(guildID: guildID, members: [member], groups: [])
        await gate.release()
        for task in pending { await task.value }

        #expect(model.onboardingMember(in: guildID)?.communicationDisabledUntil == member.communicationDisabledUntil)
        #expect((model.onboarding.timeoutExpiryTasks[guildID] != nil) == !removingTimeout)
        #expect(model.onboarding.entries[guildID]?.isLoading == false)
        model.onboarding.reset()
    }

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

    @Test
    func `channel filtering respects community capabilities local override resources and mentions`() async throws {
        let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
        await model.start()
        let guild = try #require(model.snapshot?.guilds.first)
        let id = guild.id
        let selected = Channel(id: .init(rawValue: 200), guildID: id, name: "selected")
        let omitted = Channel(id: .init(rawValue: 201), guildID: id, name: "omitted")
        let resource = Channel(id: .init(rawValue: 202), guildID: id, name: "resource", flags: 128)
        let mention = Channel(id: .init(rawValue: 203), guildID: id, name: "mentioned", mentionCount: 1)
        let channels = [selected, omitted, resource, mention]
        model.snapshot?.channels = channels
        model.snapshot?.guilds[0].features = ["COMMUNITY", "GUILD_ONBOARDING", "GUILD_SERVER_GUIDE"]
        model.serverRailGuildsByID[id]?.features = ["COMMUNITY", "GUILD_ONBOARDING", "GUILD_SERVER_GUIDE"]
        model.serverRailGuildsByID[id]?.currentUserPermissions = .max
        var member = Member(user: try #require(model.currentUser), roleName: "", isOnline: false)
        member.flags = 2
        model.onboarding.members[id] = member
        model.onboarding.presentedGuildID = model.selectedGuildID
        model.featuresSettings.channelManagement = true
        model.applyNotificationSettings(.init(guildID: id, flags: GuildChannelSelection.enabledFlag,
            channelOverrides: [.init(channelID: selected.id, flags: GuildChannelSelection.selectedFlag)]))
        let groups = ChannelGroup.make(from: channels)
        #expect(model.selectedChannelGroups(groups, guildID: id).flatMap(\.channels).map(\.id) == [selected.id, mention.id])
        let voice = Channel(id: .init(rawValue: 204), guildID: id, name: "voice", kind: .voice)
        let mixedGroups = ChannelGroup.make(from: channels + [voice])
        #expect(model.selectedChannelGroups(mixedGroups, guildID: id).flatMap(\.channels).map(\.id) == [selected.id, mention.id])
        model.applyNotificationSettings(.init(guildID: id, flags: GuildChannelSelection.enabledFlag,
            channelOverrides: [
                .init(channelID: selected.id, flags: GuildChannelSelection.selectedFlag),
                .init(channelID: voice.id, flags: GuildChannelSelection.selectedFlag),
            ]))
        #expect(model.selectedChannelGroups(mixedGroups, guildID: id).flatMap(\.channels).map(\.id) == [selected.id, mention.id, voice.id])
        let savedSettings = model.presentedGuildChannelSettings(in: id)
        model.featuresSettings.channelManagement = false
        #expect(model.selectedChannelGroups(groups, guildID: id).flatMap(\.channels).count == 4)
        #expect(!model.hasChannelsAndRoles(in: id))
        model.setChannelSelectionEnabled(true, guildID: id)
        model.setChannelSelected(false, channelID: selected.id, guildID: id)
        #expect(model.onboarding.channelSelections.isEmpty)
        #expect(model.presentedGuildChannelSettings(in: id) == savedSettings)
        model.serverRailGuildsByID[id]?.features.insert("GUILD_ONBOARDING_HAS_PROMPTS")
        #expect(model.hasChannelsAndRoles(in: id))
        #expect(model.customizationTitle(in: id) == "Roles")
        model.featuresSettings.channelManagement = true
        #expect(model.presentedGuildChannelSettings(in: id) == savedSettings)
        model.serverRailGuildsByID[id]?.features = []
        #expect(model.selectedChannelGroups(groups, guildID: id).flatMap(\.channels).count == 4)
    }

    @Test
    func `hide muted sync filters channels independently of opt in while preserving visible conversation context`() async throws {
        let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
        await model.start()
        let guildID = try #require(model.selectedGuildID)
        let muted = Channel(id: .init(rawValue: 200), guildID: guildID, name: "muted")
        let focused = Channel(id: .init(rawValue: 201), guildID: guildID, name: "focused")
        let mentioned = Channel(id: .init(rawValue: 202), guildID: guildID, name: "mentioned", mentionCount: 1)
        let threaded = Channel(id: .init(rawValue: 203), guildID: guildID, name: "threaded")
        var inherited = Channel(id: .init(rawValue: 204), guildID: guildID, name: "category-muted")
        inherited.categoryID = .init(rawValue: 190)
        let expired = Channel(id: .init(rawValue: 205), guildID: guildID, name: "expired")
        let channels = [muted, focused, mentioned, threaded, inherited, expired]
        model.selectedChannelID = focused.id
        model.featuresSettings.channelManagement = false
        let groups = ChannelGroup.make(from: channels)
        let thread = MessageThreadSummary(id: .init(rawValue: 300), guildID: guildID, parentID: threaded.id, name: "reply")
        let threads = [threaded.id: [SidebarThreadRow(thread: thread, isUnread: true, mentionCount: 1, isMuted: false)]]
        let overrides = [muted, focused, mentioned, threaded].map {
            ChannelNotificationOverride(channelID: $0.id, isMuted: true)
        } + [
            .init(channelID: .init(rawValue: 190), isMuted: true),
            .init(channelID: expired.id, isMuted: true, muteConfiguration: .init(endTime: .distantPast)),
        ]
        var settings = GuildNotificationSettings(guildID: guildID, isMuted: true, hideMutedChannels: true, channelOverrides: overrides)
        await model.consume(.notificationSettingsChanged(settings))
        #expect(Set(model.selectedChannelGroups(groups, guildID: guildID, threadsByParentID: threads)
            .flatMap(\.channels).map(\.id)) == Set([focused.id, mentioned.id, threaded.id, inherited.id, expired.id]))
        #expect(model.selectedChannelGroups(groups, guildID: guildID, threadsByParentID: [:])
            .flatMap(\.channels).contains { $0.id == threaded.id } == false)

        settings.hideMutedChannels = false
        await model.consume(.notificationSettingsChanged(settings))
        #expect(model.selectedChannelGroups(groups, guildID: guildID).flatMap(\.channels).count == channels.count)
        #expect(model.presentedGuildChannelSettings(in: guildID).channelOverrides == overrides)
    }

    @Test(.timeLimit(.minutes(1)))
    func `hide muted completion preserves newer synchronized settings and retains the HTTP fallback`() async throws {
        let provider = try CustomizationProvider()
        let model = AppModel(launchMode: .offlineTesting, provider: provider)
        await model.start()
        let guild = try #require(model.snapshot?.guilds.first)
        let channel = try #require(model.snapshot?.channels.first { $0.guildID == guild.id })
        var writes = provider.writes.makeAsyncIterator()
        model.applyNotificationSettings(.init(guildID: guild.id))
        model.setGuildNotificationToggle(.hideMutedChannels, isEnabled: true, for: guild)
        #expect(await writes.next() == .notificationToggle(.hideMutedChannels, true))
        let pending = model.guildNotificationMutationTasks[guild.id]
        await model.consume(.notificationSettingsChanged(.init(guildID: guild.id, hideMutedChannels: true)))
        await model.consume(.notificationSettingsChanged(.init(guildID: guild.id, hideMutedChannels: false)))
        await provider.finish(success: true)
        await pending?.value
        #expect(!model.presentedGuildChannelSettings(in: guild.id).hideMutedChannels)
        #expect(model.guildNotificationMutationTasks[guild.id] == nil)

        model.setGuildNotificationToggle(.hideMutedChannels, isEnabled: true, for: guild)
        #expect(await writes.next() == .notificationToggle(.hideMutedChannels, true))
        let reconnect = model.guildNotificationMutationTasks[guild.id]
        var replacement = try #require(model.snapshot)
        replacement.notificationSettings.removeAll { $0.guildID == guild.id }
        replacement.notificationSettings.append(.init(guildID: guild.id, hideMutedChannels: false))
        await model.consume(.snapshotChanged(replacement))
        await provider.finish(success: true)
        await reconnect?.value
        #expect(!model.presentedGuildChannelSettings(in: guild.id).hideMutedChannels)

        model.setGuildNotificationToggle(.hideMutedChannels, isEnabled: true, for: guild)
        #expect(await writes.next() == .notificationToggle(.hideMutedChannels, true))
        let fallback = model.guildNotificationMutationTasks[guild.id]
        model.updateLocalChannelNotificationOverride(channel: channel) { $0.isMuted = true }
        await provider.finish(success: true)
        await fallback?.value
        #expect(model.presentedGuildChannelSettings(in: guild.id).hideMutedChannels)
        #expect(model.presentedGuildChannelSettings(in: guild.id).channelOverrides.first { $0.channelID == channel.id }?.isMuted == true)
        model.setGuildNotificationToggle(.hideMutedChannels, isEnabled: false, for: guild)
        #expect(await writes.next() == .notificationToggle(.hideMutedChannels, false))
        let failed = model.guildNotificationMutationTasks[guild.id]
        await provider.finish(success: false)
        await failed?.value
        #expect(model.presentedGuildChannelSettings(in: guild.id).hideMutedChannels)
    }

    @Test
    func `hide muted schedules channel mute expiry without joined threads`() async throws {
        let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
        await model.start()
        let guildID = try #require(model.selectedGuildID)
        model.snapshot?.activeJoinedThreads = []
        model.openThread = nil
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = now.addingTimeInterval(60)
        model.applyNotificationSettings(.init(guildID: guildID, hideMutedChannels: true, channelOverrides: [
            .init(channelID: .init(rawValue: 200), isMuted: true, muteConfiguration: .init(endTime: expiry)),
            .init(channelID: .init(rawValue: 201), isMuted: true, muteConfiguration: .init(endTime: now.addingTimeInterval(-1))),
        ]))
        #expect(model.sidebarThreadLayout(guildID: guildID, channelGroups: [], now: now).relevanceDeadlines == [expiry])
        #expect(model.sidebarThreadLayout(guildID: guildID, channelGroups: [], now: expiry).relevanceDeadlines.isEmpty)
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
        case notificationToggle(GuildNotificationToggle, Bool)
    }
    nonisolated let writes: AsyncStream<Write>
    nonisolated let refreshedMembers: AsyncStream<Void>
    private let events: AsyncStream<Write>.Continuation
    private let memberEvents: AsyncStream<Void>.Continuation
    private let base = MockChatProvider()
    private var onboardingReadGate: CustomizationGate?
    private var memberTimeout: Date?
    private var completion: CheckedContinuation<Bool, Never>?
    private(set) var writeCount = 0
    private(set) var readCount = 0
    private(set) var configuration: GuildOnboarding
    init() throws {
        (writes, events) = AsyncStream.makeStream()
        (refreshedMembers, memberEvents) = AsyncStream.makeStream()
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
    func holdOnboardingRead(on gate: CustomizationGate, memberTimeout: Date?) {
        onboardingReadGate = gate
        self.memberTimeout = memberTimeout
    }
    func guildOnboarding(in guildID: GuildID) async throws -> GuildOnboarding {
        readCount += 1
        if let onboardingReadGate { await onboardingReadGate.wait() }
        return configuration
    }
    func refreshCurrentMember(in guildID: GuildID) async throws -> Member {
        let snapshot = try await base.bootstrap()
        var member = Member(user: snapshot.currentUser, roleName: "", isOnline: false)
        member.flags = 9
        member.joinedAt = Date(timeIntervalSince1970: 1_790_000_000)
        member.communicationDisabledUntil = memberTimeout
        memberEvents.yield(())
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
    func updateGuildNotificationToggle(guildID: GuildID, toggle: GuildNotificationToggle, isEnabled: Bool) async throws {
        try await record(.notificationToggle(toggle, isEnabled))
    }
    func bootstrap() async throws -> BootstrapSnapshot { try await base.bootstrap() }
    func channels(in guildID: GuildID?) async throws -> [Channel] { try await base.channels(in: guildID) }
    func members(in guildID: GuildID?) async throws -> [Member] { try await base.members(in: guildID) }
    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile { try await base.profile(for: userID, in: guildID) }
    func currentStatus() async -> PresenceStatus { .offline }
    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage { try await base.messages(in: channelID, before: before, limit: limit) }
    func send(_ draft: SendMessageDraft) async throws -> Message { try await base.send(draft) }
    func edit(_ message: Message, content: String) async throws -> Message { try await base.edit(message, content: content) }
    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
}
