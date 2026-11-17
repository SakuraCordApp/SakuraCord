@testable import SakuraCord
@testable import DiscordProtocol
@testable import DiscordProtocolTestSupport
import Foundation
import SakuraCordModels
import Testing

@MainActor
@Test func `slowmode starts at confirmation and deduplicates REST and gateway delivery`() {
    let state = SlowmodeState()
    let channelID = ChannelID(rawValue: 200)
    let user = User(id: UserID(rawValue: 1), username: "me", displayName: "Me")
    let now = Date(timeIntervalSince1970: 1000)
    var message = Message(id: MessageID(rawValue: 300), channelID: channelID, author: user, content: "sent")
    message.outboxState = .sending
    state.begin(in: channelID)
    state.confirm(message, interval: 60, at: now)
    #expect(state.remaining(in: channelID, interval: 60, immune: false, now: now) == 0)
    message.outboxState = .confirmed
    state.confirm(message, interval: 60, at: now)
    state.confirm(message, interval: 60, at: now.addingTimeInterval(10))
    #expect(state.remaining(in: channelID, interval: 60, immune: false, now: now.addingTimeInterval(10)) == 50)
    #expect(state.remaining(in: ChannelID(rawValue: 201), interval: 60, immune: false, now: now) == 0)
    #expect(state.remaining(in: channelID, interval: 60, immune: true, now: now) == 0)
    #expect(state.remaining(in: channelID, interval: 0, immune: false, now: now) == 0)
    #expect(state.remaining(in: channelID, interval: 60, immune: false, now: now.addingTimeInterval(59.1)) == 1)
    #expect(state.remaining(in: channelID, interval: 60, immune: false, now: now.addingTimeInterval(60)) == 0)
    state.recover(channelID: channelID, retryAfter: 75.5, now: now)
    #expect(state.remaining(in: channelID, interval: 60, immune: false, now: now) == 76)
    state.reset()
    #expect(state.pendingChannels.isEmpty)
    #expect(state.remaining(in: channelID, interval: 60, immune: false, now: now) == 0)
}

@MainActor
@Test func `slowmode guards preserve drafts and apply current permissions and thread settings`() async throws {
    let model = AppModel(isEphemeral: true, provider: MockChatProvider())
    let user = User(id: UserID(rawValue: 1), username: "me", displayName: "Me")
    let guildID = GuildID(rawValue: 100)
    let base = DiscordPermissionBits.viewChannel | DiscordPermissionBits.readMessageHistory
        | DiscordPermissionBits.sendMessages | DiscordPermissionBits.sendMessagesInThreads
    var guild = Guild(id: guildID, name: "Guild", currentUserPermissions: base)
    let channel = Channel(id: ChannelID(rawValue: 200), guildID: guildID, name: "slow", rateLimitPerUser: 60)
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 201), guildID: guildID, parentID: channel.id, name: "Thread", rateLimitPerUser: 10
    )
    model.snapshot = BootstrapSnapshot(currentUser: user, guilds: [guild], channels: [channel], members: [])
    model.serverRailGuildsByID[guildID] = guild
    model.selectedGuildID = guildID
    model.selectedChannelID = channel.id
    await model.channelLoadTask?.value
    model.selectedChannel = channel
    model.openThread = thread
    model.draft = "keep draft"
    model.threadDraft = "keep thread draft"
    model.composer.slowmode.begin(in: channel.id)
    #expect(!model.allowSlowmodeSubmission(in: channel.id))
    #expect(model.slowmodeRemaining(in: channel.id) == 0)
    model.composer.slowmode.end(in: channel.id)
    let confirmation = Message(id: MessageID(rawValue: 300), channelID: channel.id, author: user, content: "sent")
    model.confirmSlowmodeMessage(confirmation)
    #expect(!(await model.submitComposerMessage(attachments: [])).consumedComposer)
    #expect(model.draft == "keep draft")
    #expect(model.composer.outbox.draftsByNonce.isEmpty)
    #expect(model.allowSlowmodeSubmission(in: thread.id))
    var threadConfirmation = confirmation
    threadConfirmation.channelID = thread.id
    model.confirmSlowmodeMessage(threadConfirmation)
    #expect(!(await model.submitThreadComposerMessage(attachments: [])).consumedComposer)
    #expect(model.threadDraft == "keep thread draft")
    #expect(model.slowmodeRemaining(in: thread.id) <= 10)

    for permission in [DiscordPermissionBits.manageMessages, UInt64(1 << 4), DiscordPermissionBits.manageThreads] {
        guild.currentUserPermissions = base | permission
        model.serverRailGuildsByID[guildID] = guild
        #expect(!model.slowmodeConfiguration(in: channel.id).immune)
    }
    for permission in [DiscordPermissionBits.bypassSlowmode, DiscordPermissionBits.administrator] {
        guild.currentUserPermissions = base | permission
        model.serverRailGuildsByID[guildID] = guild
        #expect(model.slowmodeConfiguration(in: channel.id).immune)
        #expect(model.allowSlowmodeSubmission(in: channel.id))
        #expect(model.slowmodeConfiguration(in: thread.id).immune)
    }
    guild.currentUserPermissions = base
    guild.isOwnedByCurrentUser = true
    model.serverRailGuildsByID[guildID] = guild
    #expect(model.slowmodeConfiguration(in: channel.id).immune)
    await model.composer.reset()
}

@MainActor
@Test func `changing slowmode shortens an active cooldown without extending or restarting it`() async {
    let state = SlowmodeState()
    let channelID = ChannelID(rawValue: 200)
    let now = Date(timeIntervalSince1970: 1000)
    let message = Message(
        id: MessageID(rawValue: 300), channelID: channelID,
        author: User(id: UserID(rawValue: 1), username: "me", displayName: "Me"), content: "sent"
    )
    state.confirm(message, interval: 60, at: now)
    let changedAt = now.addingTimeInterval(30)
    let original = Channel(id: channelID, guildID: nil, name: "slow", rateLimitPerUser: 60)
    let shortened = Channel(id: channelID, guildID: nil, name: "slow", rateLimitPerUser: 10)
    let buffer = SessionEventBuffer<ClientEvent>(
        overflowEvent: .sessionInvalidated("overflow"),
        coalescing: DiscordRESTProvider.coalescingChannelSnapshots
    )
    buffer.yield(.channelsChanged(guildID: nil, channels: [shortened]))
    buffer.yield(.channelsChanged(guildID: nil, channels: [original]))
    buffer.finish()
    var previous = [original]
    var intervals: [Int] = []
    for await event in buffer.stream {
        if case let .channelsChanged(_, channels) = event {
            state.updateIntervals(for: channels, replacing: previous, now: changedAt)
            intervals.append(contentsOf: channels.map(\.rateLimitPerUser))
            previous = channels
        }
    }
    #expect(intervals == [10, 60], "The intermediate reduction must reach the cooldown state")
    #expect(state.remaining(in: channelID, interval: 10, immune: false, now: changedAt) == 10)
    state.updateInterval(in: channelID, to: 120, now: changedAt)
    #expect(state.remaining(in: channelID, interval: 120, immune: false, now: changedAt) == 10)
    state.updateInterval(in: channelID, to: 0, now: changedAt)
    state.updateInterval(in: channelID, to: 60, now: changedAt)
    #expect(state.remaining(in: channelID, interval: 60, immune: false, now: changedAt) == 0)

    // An unrelated catalogue update must not shorten an authoritative retry.
    state.recover(channelID: channelID, retryAfter: 75, now: changedAt)
    state.updateIntervals(for: [shortened], replacing: [shortened], now: changedAt)
    #expect(state.remaining(in: channelID, interval: 10, immune: false, now: changedAt) == 75)
}
