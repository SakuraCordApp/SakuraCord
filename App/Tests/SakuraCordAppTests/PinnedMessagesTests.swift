import AppKit
@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `pin permission uses dedicated 2026 permission bit`() {
    #expect(DiscordPermissionBits.pinMessages == UInt64(1) << 51)
    #expect(DiscordPermissionBits.pinMessages != DiscordPermissionBits.manageThreads)
}

@MainActor
@Test func `message menu gates pin actions and pinned results omit unread behavior`() {
    let ordinary = NativeTimelineMessageMenuPolicy.entries(
        canEdit: false,
        canRetry: false,
        canReply: true,
        canPin: true,
        isPinned: false
    )
    #expect(ordinary.contains(.action(
        .pinMessage,
        title: "Pin Message",
        systemImage: "pin"
    )))

    let pinned = NativeTimelineMessageMenuPolicy.entries(
        canEdit: false,
        canRetry: false,
        canReply: false,
        canPin: true,
        isPinned: true,
        context: .pinnedResult
    )
    #expect(pinned.first == .action(
        .jumpToMessage,
        title: "Jump to Message",
        systemImage: NativeTimelineSearchResultPresentation.jumpToMessageSystemImage
    ))
    #expect(pinned.contains(.action(
        .unpinMessage,
        title: "Unpin Message",
        systemImage: "pin.slash"
    )))
    #expect(!pinned.contains(.action(
        .markUnread,
        title: "Mark Unread",
        systemImage: "envelope.badge"
    )))
}

@MainActor
@Test func `pin announcement centralizes actor target and browser links`() throws {
    let author = User(
        id: UserID(rawValue: 1),
        username: "actor",
        displayName: "Actor"
    )
    let message = Message(
        id: MessageID(rawValue: 10),
        channelID: ChannelID(rawValue: 20),
        author: author,
        content: "",
        type: .channelPinnedMessage,
        guildID: GuildID(rawValue: 30),
        messageReference: DiscordMessageReference(
            type: .reply,
            messageID: MessageID(rawValue: 40),
            channelID: ChannelID(rawValue: 20),
            guildID: GuildID(rawValue: 30)
        )
    )

    let runs = SystemMessagePresentation.textRuns(for: message)
    #expect(runs.map { $0.text }.joined() ==
        "Actor pinned a message to this channel. See all pinned messages.")
    #expect(runs[0].action == SystemMessagePresentation.Action.profile(author.id))
    #expect(runs[2].action == SystemMessagePresentation.Action.message(
        guildID: GuildID(rawValue: 30),
        channelID: ChannelID(rawValue: 20),
        messageID: MessageID(rawValue: 40)
    ))
    #expect(runs[4].action == SystemMessagePresentation.Action.pins(
        ChannelID(rawValue: 20)
    ))

    let actorColor = NSColor.systemBlue
    let attributed = SystemMessagePresentation.attributedLabel(
        for: message,
        baseFontSize: 13,
        actorColor: actorColor
    )
    #expect(attributed.attribute(.link, at: 0, effectiveRange: nil) != nil)
    #expect((attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        == actorColor)
    let targetLocation = (attributed.string as NSString).range(of: "a message").location
    #expect(attributed.attribute(.link, at: targetLocation, effectiveRange: nil) != nil)
}

@MainActor
@Test(arguments: [
    DiscordMessageType.recipientAdd,
    DiscordMessageType.recipientRemove,
    DiscordMessageType.channelPinnedMessage,
    DiscordMessageType.userJoin,
    DiscordMessageType.call,
])
func `interactive system message families share actor tint and profile link`(
    type: DiscordMessageType
) throws {
    let author = User(
        id: UserID(rawValue: 1), username: "actor", displayName: "Actor"
    )
    let target = User(
        id: UserID(rawValue: 2), username: "target", displayName: "Target"
    )
    let message = Message(
        id: MessageID(rawValue: 10),
        channelID: ChannelID(rawValue: 20),
        author: author,
        content: "",
        type: type,
        mentionedUsers: [target],
        call: type == .call ? MessageCall() : nil,
        messageReference: type == .channelPinnedMessage
            ? DiscordMessageReference(
                type: .reply,
                messageID: MessageID(rawValue: 30),
                channelID: ChannelID(rawValue: 20)
            )
            : nil
    )

    let actorRun = try #require(
        SystemMessagePresentation.textRuns(for: message).first(where: {
            $0.action == .profile(author.id)
        })
    )
    #expect(actorRun.text == author.displayName)

    let actorColor = NSColor.systemPink
    let attributed = SystemMessagePresentation.attributedLabel(
        for: message,
        baseFontSize: 13,
        actorColor: actorColor
    )
    let actorLocation = (attributed.string as NSString).range(
        of: author.displayName
    ).location
    #expect(attributed.attribute(.link, at: actorLocation, effectiveRange: nil) != nil)
    #expect((attributed.attribute(
        .foregroundColor,
        at: actorLocation,
        effectiveRange: nil
    ) as? NSColor) == actorColor)
}

@MainActor
@Test func `system message links route profiles messages and pins through shared activator`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let directMessage = try #require(model.snapshot?.channels.first {
        $0.kind == .directMessage && !$0.isOfficialSystemDirectMessage
    })
    model.navigate(to: directMessage.id)
    #expect(await eventuallyPinned { model.selectedChannelID == directMessage.id })
    await model.channelLoadTask?.value
    let target = try #require(model.messages.first)

    #expect(MessageLinkActivator.activate(
        SystemMessagePresentation.Action.profile(target.author.id).url,
        model: model
    ))
    #expect(model.contextualProfilePresentation?.member.id == target.author.id)

    #expect(MessageLinkActivator.activate(
        SystemMessagePresentation.Action.pins(directMessage.id).url,
        model: model
    ))
    #expect(model.pinnedMessages.isPresented)
    #expect(model.pinnedMessages.channelID == directMessage.id)
    model.dismissPinnedMessages()

    #expect(MessageLinkActivator.activate(
        SystemMessagePresentation.Action.message(
            guildID: nil,
            channelID: directMessage.id,
            messageID: target.id
        ).url,
        model: model
    ))
    await model.guildActivationTask?.value
    #expect(model.messageNavigationRequest?.channelID == directMessage.id)
    #expect(model.messageNavigationRequest?.messageID == target.id)

    let guildChannel = try #require(model.snapshot?.channels.first {
        $0.guildID != nil && $0.kind == .text
    })
    #expect(MessageLinkActivator.activate(
        SystemMessagePresentation.Action.pins(guildChannel.id).url,
        model: model
    ))
    await model.guildActivationTask?.value
    #expect(await eventuallyPinned {
        model.pinnedMessages.isPresented
            && model.pinnedMessages.channelID == guildChannel.id
    })
}

@MainActor
@Test func `pinned presentation preserves pin ordering metadata and rich message`() {
    let author = User(id: UserID(rawValue: 1), username: "a", displayName: "A")
    let pinnedAt = Date(timeIntervalSince1970: 1_777_777_777)
    let message = Message(
        id: MessageID(rawValue: 2),
        channelID: ChannelID(rawValue: 3),
        author: author,
        content: "**rich**",
        isPinned: true,
        embeds: [MessageEmbed(id: "embed", title: "Card")]
    )
    let rows = PinnedMessagePresentation.rows(for: [
        PinnedMessage(pinnedAt: pinnedAt, message: message),
    ])
    #expect(rows.count == 1)
    #expect(rows[0].message.embeds.count == 1)
    #expect(rows[0].pinnedAt == pinnedAt)
    #expect(rows[0].startsGroup)
}

@MainActor
@Test func `pinned pagination reuses unchanged prepared rows`() {
    let author = User(id: UserID(rawValue: 1), username: "a", displayName: "A")
    let first = PinnedMessage(
        pinnedAt: Date(timeIntervalSince1970: 200),
        message: Message(
            id: MessageID(rawValue: 2), channelID: ChannelID(rawValue: 3),
            author: author, content: "first", isPinned: true
        )
    )
    let second = PinnedMessage(
        pinnedAt: Date(timeIntervalSince1970: 100),
        message: Message(
            id: MessageID(rawValue: 4), channelID: ChannelID(rawValue: 3),
            author: author, content: "second", isPinned: true
        )
    )
    let state = PinnedMessagesState()
    state.replaceItems([first])
    let originalRow = state.rows[0]

    state.replaceItems([first, second])

    #expect(state.rows.count == 2)
    #expect(state.rows.first === originalRow)
}

@MainActor
@Test func `pin surfaces and permissions resolve each supported conversation`() throws {
    let currentUser = User(
        id: UserID(rawValue: 1), username: "current", displayName: "Current"
    )
    let guildID = GuildID(rawValue: 10)
    let permissions = DiscordPermissionBits.viewChannel
        | DiscordPermissionBits.readMessageHistory
        | DiscordPermissionBits.pinMessages
    let guild = Guild(
        id: guildID,
        name: "Pins",
        currentUserPermissions: permissions
    )
    let supportedKinds: [ChannelKindValue] = [.text, .announcement, .voice]
    let guildChannels = supportedKinds.enumerated().map { index, kind in
        Channel(
            id: ChannelID(rawValue: UInt64(20 + index)),
            guildID: guildID,
            name: kind.rawValue,
            kind: kind
        )
    }
    let denied = Channel(
        id: ChannelID(rawValue: 30),
        guildID: guildID,
        name: "denied",
        permissionOverwrites: [ChannelPermissionOverwrite(
            id: guildID.description,
            type: 0,
            deny: DiscordPermissionBits.pinMessages
        )]
    )
    let forum = Channel(
        id: ChannelID(rawValue: 31), guildID: guildID, name: "forum", kind: .forum
    )
    let direct = Channel(
        id: ChannelID(rawValue: 40), guildID: nil, name: "dm", kind: .directMessage
    )
    let group = Channel(
        id: ChannelID(rawValue: 41), guildID: nil, name: "gdm", kind: .groupDirectMessage
    )
    let systemDirect = Channel(
        id: ChannelID(rawValue: 42),
        guildID: nil,
        name: "system",
        kind: .directMessage,
        recipients: [User(
            id: UserID(rawValue: 2), username: "system", displayName: "System",
            isSystem: true
        )]
    )
    let channels = guildChannels + [denied, forum, direct, group, systemDirect]
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    model.snapshot = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [guild],
        channels: channels,
        members: []
    )
    model.visibleChannels = channels
    model.serverRailGuildsByID = [guildID: guild]

    for channel in guildChannels + [direct, group] {
        model.openThread = nil
        model.selectedChannel = channel
        model.selectedChannelID = channel.id
        #expect(model.activePinsChannelID == channel.id)
        #expect(model.canManagePins(for: pinTestMessage(in: channel.id)))
    }

    model.selectedChannel = forum
    model.selectedChannelID = forum.id
    #expect(model.activePinsChannelID == nil)
    #expect(!model.canManagePins(for: pinTestMessage(in: forum.id)))

    model.selectedChannel = systemDirect
    model.selectedChannelID = systemDirect.id
    #expect(!model.canManagePins(for: pinTestMessage(in: systemDirect.id)))

    let root = try #require(guildChannels.first)
    model.selectedChannel = root
    model.selectedChannelID = root.id
    #expect(!model.canManagePins(for: pinTestMessage(in: denied.id)))
    #expect(model.canManagePins(for: pinTestMessage(in: guildChannels[1].id)))

    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 50), guildID: guildID, parentID: root.id, name: "thread"
    )
    model.openThread = thread
    #expect(model.activePinsChannelID == thread.id)
    #expect(model.canManagePins(for: pinTestMessage(in: thread.id)))

    let searchThread = Channel(
        id: ChannelID(rawValue: 51),
        guildID: guildID,
        name: "search thread",
        categoryID: root.id
    )
    model.openThread = nil
    model.messageSearch.page = MessageSearchPage(
        messages: [], channels: [searchThread], totalResults: 0
    )
    #expect(model.canManagePins(for: pinTestMessage(in: searchThread.id)))
}

@MainActor
@Test func `account presentation reset clears pins and pending intents`() {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    let message = pinTestMessage(in: ChannelID(rawValue: 10))
    model.pinnedMessages.channelID = message.channelID
    model.pinnedMessages.isPresented = true
    model.pinnedMessages.mutationIntents[message.id] = .init(
        channelID: message.channelID,
        desired: true,
        generation: 1
    )
    model.pinnedMessages.replaceItems([
        PinnedMessage(pinnedAt: .now, message: message),
    ])

    model.resetAccountPresentationState()

    #expect(!model.pinnedMessages.isPresented)
    #expect(model.pinnedMessages.channelID == nil)
    #expect(model.pinnedMessages.items.isEmpty)
    #expect(model.pinnedMessages.rows.isEmpty)
    #expect(model.pinnedMessages.mutationIntents.isEmpty)
}

@MainActor
@Test func `direct message pin mutation updates optimistically and records one provider request`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let directMessage = try #require(model.snapshot?.channels.first {
        $0.kind == .directMessage && !$0.isOfficialSystemDirectMessage
    })
    model.navigate(to: directMessage.id)
    #expect(await eventuallyPinned { model.selectedChannelID == directMessage.id })
    await model.channelLoadTask?.value
    let message = try #require(model.messages.first)

    model.togglePinnedState(for: message)

    #expect(model.messages.first(where: { $0.id == message.id })?.isPinned == true)
    #expect(await eventuallyPinned {
        await provider.pinMutationRequests.count == 1
    })
    #expect(await provider.pinMutationRequests.first?.isPinned == true)
}

@MainActor
@Test func `pinned row activation dismisses and uses exact message navigation`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let directMessage = try #require(model.snapshot?.channels.first {
        $0.kind == .directMessage && !$0.isOfficialSystemDirectMessage
    })
    model.navigate(to: directMessage.id)
    #expect(await eventuallyPinned { model.selectedChannelID == directMessage.id })
    await model.channelLoadTask?.value
    let message = try #require(model.messages.first)
    model.pinnedMessages.isPresented = true
    model.pinnedMessages.channelID = directMessage.id

    let timeline = NativeMessageTimelineView(
        model: model,
        conversation: .pins(directMessage.id),
        beginning: nil,
        firstMessageStartsDayOverride: false,
        hasMoreMessages: false,
        isLoadingEarlier: false,
        bottomContentInset: 0,
        unreadMessageID: nil,
        highlightedMessageID: nil,
        scrollRequest: nil,
        runsPerformanceAutoScroll: false,
        loadEarlier: {},
        openReply: { _ in },
        onScrollActivityChange: { _ in },
        onScrollStateChange: { _ in },
        onUserScrollBegan: {},
        onUserScrollEnded: { _ in }
    )
    let actions = NativeMessageTimelineCoordinator.makeActions(from: timeline)

    let openMessage = try #require(actions.openMessage)
    openMessage(message)
    await model.guildActivationTask?.value
    await model.channelLoadTask?.value

    #expect(!model.pinnedMessages.isPresented)
    #expect(model.messageNavigationRequest?.channelID == directMessage.id)
    #expect(model.messageNavigationRequest?.messageID == message.id)
}

@MainActor
private func eventuallyPinned(
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    for _ in 0 ..< 120 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@MainActor
@Test func `message deletion removes only matching channel pin`() {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    let author = User(id: UserID(rawValue: 1), username: "a", displayName: "A")
    let first = Message(
        id: MessageID(rawValue: 1), channelID: ChannelID(rawValue: 10),
        author: author, content: "one", isPinned: true
    )
    let second = Message(
        id: MessageID(rawValue: 2), channelID: ChannelID(rawValue: 10),
        author: author, content: "two", isPinned: true
    )
    model.pinnedMessages.channelID = ChannelID(rawValue: 10)
    model.pinnedMessages.replaceItems([
        PinnedMessage(pinnedAt: .now, message: first),
        PinnedMessage(pinnedAt: .now.addingTimeInterval(-1), message: second),
    ])

    model.consumeImmediately(.messageDeleted(
        channelID: ChannelID(rawValue: 10),
        messageID: first.id
    ))

    #expect(model.pinnedMessages.items.map(\.id) == [second.id])
}

@MainActor
@Test func `definite pin failure rolls back optimistic state`() async throws {
    let provider = MockChatProvider(pinMutationFailureStatus: 403)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let directMessage = try #require(model.snapshot?.channels.first {
        $0.kind == .directMessage && !$0.isOfficialSystemDirectMessage
    })
    model.navigate(to: directMessage.id)
    #expect(await eventuallyPinned { model.selectedChannelID == directMessage.id })
    await model.channelLoadTask?.value
    let message = try #require(model.messages.first)

    model.togglePinnedState(for: message)
    #expect(await eventuallyPinned {
        model.messages.first(where: { $0.id == message.id })?.isPinned == false
    })
    #expect(await provider.pinMutationRequests.count == 1)
}

@MainActor
@Test func `offline pin fixture paginates deterministically`() async throws {
    let provider = MockChatProvider(
        timelineMessageCount: 80,
        pinnedMessageCount: 80
    )
    let first = try await provider.pinnedMessages(
        in: ChannelID(rawValue: 210), before: nil, limit: 25
    )
    let second = try await provider.pinnedMessages(
        in: ChannelID(rawValue: 210), before: first.nextBefore, limit: 25
    )

    #expect(first.items.count == 25)
    #expect(second.items.count == 25)
    #expect(first.hasMore)
    #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
    #expect((first.items.last?.pinnedAt ?? .distantPast)
        > (second.items.first?.pinnedAt ?? .distantFuture))
}

@MainActor
@Test func `conflicting pin intents serialize and ignore stale gateway echo`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let directMessage = try #require(model.snapshot?.channels.first {
        $0.kind == .directMessage && !$0.isOfficialSystemDirectMessage
    })
    model.navigate(to: directMessage.id)
    #expect(await eventuallyPinned { model.selectedChannelID == directMessage.id })
    await model.channelLoadTask?.value
    let message = try #require(model.messages.first)

    model.togglePinnedState(for: message)
    model.togglePinnedState(for: message)

    #expect(await eventuallyPinned { await provider.pinMutationRequests.count == 2 })
    #expect(await provider.pinMutationRequests.map(\.isPinned) == [true, false])
    #expect(await eventuallyPinned {
        model.messages.first(where: { $0.id == message.id })?.isPinned == false
    })
}

@MainActor
@Test func `pinned reply activation jumps to the referenced message`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let directMessage = try #require(model.snapshot?.channels.first {
        $0.kind == .directMessage && !$0.isOfficialSystemDirectMessage
    })
    model.navigate(to: directMessage.id)
    #expect(await eventuallyPinned { model.selectedChannelID == directMessage.id })
    await model.channelLoadTask?.value
    let target = try #require(model.messages.first)
    let pinnedReply = Message(
        id: MessageID(rawValue: target.id.rawValue + 100_000),
        channelID: directMessage.id,
        author: target.author,
        content: "reply",
        replyTo: target.id,
        isPinned: true
    )
    model.pinnedMessages.replaceItems([
        PinnedMessage(pinnedAt: .now, message: pinnedReply),
    ])

    model.navigateToPinnedReply(target.id)
    await model.guildActivationTask?.value

    #expect(model.messageNavigationRequest?.channelID == directMessage.id)
    #expect(model.messageNavigationRequest?.messageID == target.id)
}

@MainActor
@Test func `pin invalidation is channel scoped`() {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    let message = Message(
        id: MessageID(rawValue: 1),
        channelID: ChannelID(rawValue: 10),
        author: User(id: UserID(rawValue: 2), username: "a", displayName: "A"),
        content: "pinned",
        isPinned: true
    )
    model.pinnedMessages.channelID = message.channelID
    model.pinnedMessages.replaceItems([
        PinnedMessage(pinnedAt: .now, message: message),
    ])

    model.consumeImmediately(.channelPinsInvalidated(
        channelID: ChannelID(rawValue: 11)
    ))
    #expect(model.pinnedMessages.items.map(\.id) == [message.id])

    model.consumeImmediately(.channelPinsInvalidated(channelID: message.channelID))
    #expect(model.pinnedMessages.items.isEmpty)
}

private func pinTestMessage(in channelID: ChannelID) -> Message {
    Message(
        id: MessageID(rawValue: channelID.rawValue + 10_000),
        channelID: channelID,
        author: User(id: UserID(rawValue: 1), username: "a", displayName: "A"),
        content: "pin me"
    )
}
