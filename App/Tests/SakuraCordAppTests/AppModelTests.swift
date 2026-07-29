import AppKit
import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
import UserNotifications
@testable import SakuraCord

@MainActor
@Test func `native emoji catalog loads every fully qualified unicode 17 emoji`() {
    #expect(NativeEmojiCatalogDiagnostics.sourceEntryCount == 3944)
    #expect(
        NativeEmojiCatalogDiagnostics.itemCount < NativeEmojiCatalogDiagnostics.sourceEntryCount)
    #expect(NativeEmojiCatalogDiagnostics.skinToneCapableItemCount > 100)
    #expect(NativeEmojiCatalogDiagnostics.wavingHandValues == ["👋", "👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"])
    #expect(NativeEmojiCatalogDiagnostics.mediumToneVariationSelectorValues == ["✌🏽", "☝🏽", "✍🏽"])
    #expect(NativeEmojiCatalogDiagnostics.baseItemsContainingSkinToneModifier == 0)
    #expect(NativeEmojiCatalogDiagnostics.categoryItemCounts.count == 9)
    #expect(NativeEmojiCatalogDiagnostics.categoryItemCounts.values.allSatisfy { $0 > 0 })
    #expect(NativeEmojiCatalogDiagnostics.shortcode(for: "🤍") == ":white_heart:")
    // Tone variants share their base emoji's aliases, so the collapsed picker catalog is smaller
    // than Emojibase's 3,808 keyed source records.
    #expect(NativeEmojiCatalogDiagnostics.emojiCountWithDiscordShortcodes == 1884)
    #expect(NativeEmojiCatalogDiagnostics.discordShortcodeAliasCount == 2551)
    #expect(NativeEmojiCatalogDiagnostics.shortcodes(for: "🎉") == ["tada", "party_popper"])
    #expect(NativeEmojiCatalogDiagnostics.shortcode(for: "🎉") == ":tada:")
    #expect(NativeEmojiCatalogDiagnostics.searchMatches(value: "🎉", query: ":party_popper:"))
    #expect(NativeEmojiCatalogDiagnostics.searchMatches(value: "👍", query: "+1"))
    #expect(EmojiSearchMatcher.normalized(":grinning_face:") == "grinning_face")
}

@MainActor
@Test func `emoji picker uses one continuous recycled document`() {
    #expect(EmojiPickerPerformanceDiagnostics.itemsPerRecycledRow == 9)
    #expect(EmojiPickerPerformanceDiagnostics.nativeSectionIDs.count == 9)
    #expect(Set(EmojiPickerPerformanceDiagnostics.nativeSectionIDs).count == 9)
    #expect(
        EmojiPickerPerformanceDiagnostics.nativeDocumentRowCount
            < EmojiPickerPerformanceDiagnostics.nativeItemCount / 4)
    #expect(NativeEmojiCatalogDiagnostics.categoryItemCounts["people", default: 0] > 300)
    #expect(
        !EmojiPickerPerformanceDiagnostics.nativeSidebarIsVisible(
            bounds: nil,
            viewportHeight: 300
        ))
    #expect(
        !EmojiPickerPerformanceDiagnostics.nativeSidebarIsVisible(
            bounds: CGRect(x: 0, y: 320, width: 46, height: 300),
            viewportHeight: 300
        ))
    #expect(
        EmojiPickerPerformanceDiagnostics.nativeSidebarIsVisible(
            bounds: CGRect(x: 0, y: 280, width: 46, height: 300),
            viewportHeight: 300
        ))
}

@Test func `emoji picker keyboard navigation wraps rows and clamps columns`() {
    let rows = [
        ["a", "b", "c"],
        ["d", "e", "f"],
        ["g"],
    ]

    #expect(
        EmojiPickerGridNavigation.destinationID(
            rows: rows, currentID: nil, direction: .right
        ) == "a")
    #expect(
        EmojiPickerGridNavigation.destinationID(
            rows: rows, currentID: "a", direction: .left
        ) == "a")
    #expect(
        EmojiPickerGridNavigation.destinationID(
            rows: rows, currentID: "c", direction: .right
        ) == "d")
    #expect(
        EmojiPickerGridNavigation.destinationID(
            rows: rows, currentID: "d", direction: .left
        ) == "c")
    #expect(
        EmojiPickerGridNavigation.destinationID(
            rows: rows, currentID: "c", direction: .down
        ) == "f")
    #expect(
        EmojiPickerGridNavigation.destinationID(
            rows: rows, currentID: "f", direction: .down
        ) == "g")
    #expect(
        EmojiPickerGridNavigation.destinationID(
            rows: rows, currentID: "g", direction: .up
        ) == "d")
}

@Test func `emoji picker only stays open for explicit persistent shift selection`() {
    #expect(
        EmojiPickerActivationPolicy.keepsPickerPresented(
            allowsPersistentSelection: true,
            shiftPressed: true
        ))
    #expect(
        !EmojiPickerActivationPolicy.keepsPickerPresented(
            allowsPersistentSelection: true,
            shiftPressed: false
        ))
    #expect(
        !EmojiPickerActivationPolicy.keepsPickerPresented(
            allowsPersistentSelection: false,
            shiftPressed: true
        ))
}

@MainActor
@Test func `custom emoji preference keys retain their display name`() {
    let emoji = DiscordEmoji(
        id: "123",
        name: "party_blob",
        guildID: GuildID(rawValue: 1)
    )
    #expect(EmojiPickerSelection.custom(emoji).usageKey == "custom:party_blob:123")
}

@Test func `message actions remain visible while their reaction picker is presented`() {
    #expect(
        MessageActionVisibilityPolicy.isVisible(
            isRowHovered: true,
            isReactionPickerPresented: false,
            isEditing: false
        ))
    #expect(
        MessageActionVisibilityPolicy.isVisible(
            isRowHovered: false,
            isReactionPickerPresented: true,
            isEditing: false
        ))
    #expect(
        !MessageActionVisibilityPolicy.isVisible(
            isRowHovered: false,
            isReactionPickerPresented: false,
            isEditing: false
        ))
    #expect(
        !MessageActionVisibilityPolicy.isVisible(
            isRowHovered: true,
            isReactionPickerPresented: true,
            isEditing: true
        ))
}

@Test func `emoji picker only asks the scroll view to reveal changed rows`() {
    #expect(
        !EmojiPickerScrollPolicy.shouldReveal(
            previousRowID: "row:4",
            destinationRowID: "row:4"
        ))
    #expect(
        EmojiPickerScrollPolicy.shouldReveal(
            previousRowID: "row:4",
            destinationRowID: "row:5"
        ))
    #expect(
        EmojiPickerScrollPolicy.shouldReveal(
            previousRowID: nil,
            destinationRowID: "row:1"
        ))
}

@MainActor
@Test func `app model loads demo and sends message`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    #expect(model.snapshot != nil)
    #expect(model.selectedChannel != nil)
    #expect(model.supportsCapability(.components))
    let before = model.messages.count
    model.updateDraft("hello from test")
    await model.send()
    #expect(model.messages.count == before + 1)
    #expect(model.messages.last?.content == "hello from test")
}

@MainActor
@Test func `inaccessible private channels are absent from presentation and unread state`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let privateChannelID = ChannelID(rawValue: 215)

    #expect(await eventuallyOnMain {
        model.readState.entries[privateChannelID]?.isAccessible == false
    })
    #expect(!model.visibleChannels.contains(where: { $0.id == privateChannelID }))
    #expect(!model.isChannelUnread(privateChannelID))
    #expect(model.channelMentionCount(privateChannelID) == 0)
}

@MainActor
@Test func `startup snapshot presents channel guild and folder unread without a later event`() async
    throws
{
    let provider = StartupUnreadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)

    await model.start()

    let channel = try #require(model.visibleChannels.first)
    let guild = try #require(model.serverRailGuildsByID[GuildID(rawValue: 77_000)])
    #expect(channel.unreadCount == 1)
    #expect(channel.mentionCount == 2)
    #expect(guild.unreadCount == 1)
    #expect(guild.mentionCount == 2)
    #expect(
        model.serverRailItems
            == [
                .folder(
                    GuildFolder(
                        id: 77,
                        name: "Startup",
                        guildIDs: [GuildID(rawValue: 77_000)]
                    )
                )
            ]
    )
}

@MainActor
@Test func `snapshot refresh preserves the account unread notification mode`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let guildID = GuildID(rawValue: 78_000)
    let channelID = ChannelID(rawValue: 78_001)
    let refreshed = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [
            Guild(
                id: guildID,
                name: "Legacy unread policy",
                defaultMessageNotifications: .onlyMentions
            )
        ],
        channels: [
            Channel(
                id: channelID,
                guildID: guildID,
                name: "general",
                lastMessageID: MessageID(rawValue: 11)
            )
        ],
        members: [],
        readStates: [
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10)
            )
        ],
        usesNewNotifications: false
    )

    await provider.emit(.snapshotChanged(refreshed))

    #expect(await eventuallyOnMain {
        model.snapshot?.usesNewNotifications == false
            && model.snapshot?.channels.contains(where: { $0.id == channelID }) == true
    })
    #expect(model.isChannelUnread(channelID))
    #expect(model.serverRailGuildsByID[guildID]?.unreadCount == 1)
}

@MainActor
@Test func `gateway ready refreshes the account unread notification mode`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let guildID = GuildID(rawValue: 79_000)
    let channelID = ChannelID(rawValue: 79_001)
    let currentUser = try #require(model.snapshot?.currentUser)
    let refreshed = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [
            Guild(
                id: guildID,
                name: "Reconnect policy",
                defaultMessageNotifications: .onlyMentions
            )
        ],
        channels: [
            Channel(
                id: channelID,
                guildID: guildID,
                name: "general",
                lastMessageID: MessageID(rawValue: 11)
            )
        ],
        members: [],
        readStates: [
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10)
            )
        ],
        usesNewNotifications: true
    )
    await provider.emit(.snapshotChanged(refreshed))
    #expect(await eventuallyOnMain { model.snapshot == refreshed })
    #expect(!model.isChannelUnread(channelID))

    await provider.emit(
        .notificationModeChanged(usesNewNotifications: false)
    )

    #expect(await eventuallyOnMain {
        model.snapshot?.usesNewNotifications == false
    })
    #expect(model.isChannelUnread(channelID))
    #expect(model.serverRailGuildsByID[guildID]?.unreadCount == 1)
}

@MainActor
@Test func `fast forum loads do not flash a transient loading surface`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))

    model.selectedChannelID = forum.id
    #expect(!model.isLoadingForumPosts)
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let unreadPosts = model.forumPosts.filter(\.isUnread)
    #expect(!unreadPosts.isEmpty)
    #expect(unreadPosts.allSatisfy { model.isForumPostUnread($0) })
    #expect(model.forumPosts.contains { $0.thread.isLocked })
    #expect(!model.forumRecentPosts.isEmpty)
    #expect(!model.forumOlderPosts.isEmpty)

    let reactionPost = try #require(
        model.forumPosts.first(where: { $0.firstMessage?.reactions.isEmpty == false })
    )
    let reactionMessage = try #require(reactionPost.firstMessage)
    let reaction = try #require(reactionMessage.reactions.first)
    let wasReacted = reaction.didCurrentUserReact
    await model.toggleReaction(reaction.emoji, on: reactionMessage)
    #expect(
        await eventuallyOnMain {
            model.forumPosts.first(where: { $0.id == reactionPost.id })?
                .firstMessage?.reactions.first?.didCurrentUserReact == !wasReacted
        }
    )

    model.open(reactionPost)
    #expect(model.openThread?.id == reactionPost.id)
    #expect(model.threadMessages.first == reactionPost.firstMessage)
    #expect(await eventuallyOnMain { !model.isLoadingThread })
    model.closeThread()

    let matchingTitle = try #require(model.forumPosts.first?.thread.name)
    model.updateForumSearch(String(matchingTitle.prefix(3)))
    #expect(!model.forumPosts.isEmpty)
    #expect(
        model.forumPosts.allSatisfy {
            $0.thread.name.localizedCaseInsensitiveContains(String(matchingTitle.prefix(3)))
        })
    #expect(model.isSearchingForumPosts)
    try await Task.sleep(for: .milliseconds(350))
    #expect(await eventuallyOnMain { !model.isSearchingForumPosts })
    let searchQueries = await provider.forumQueries(in: forum.id)
    #expect(
        searchQueries.contains {
            if case let .search(text) = $0.scope {
                return text == String(matchingTitle.prefix(3))
            }
            return false
        }
    )

    model.updateForumSearch("")
    #expect(!model.forumPosts.isEmpty)

    model.updateForumSearch("no-post-can-match-this-query")
    #expect(!model.isLoadingForumPosts)
    #expect(await eventuallyOnMain { model.forumPosts.isEmpty })

    model.updateForumSearch("")
    #expect(!model.isLoadingForumPosts)
    #expect(await eventuallyOnMain { !model.forumPosts.isEmpty })
    #expect(!model.isLoadingForumPosts)
}

@MainActor
@Test func `reaction gateway updates reconcile forum previews and open threads without reload`() async
    throws
{
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))

    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let post = try #require(model.forumPosts.first)
    let starter = try #require(post.firstMessage)
    model.open(post)
    #expect(await eventuallyOnMain { !model.isLoadingThread && !model.threadMessages.isEmpty })

    await provider.emit(
        .messageReactionUpdated(
            .add(
                channelID: post.id,
                messageID: starter.id,
                userID: UserID(rawValue: 55_555),
                emoji: "<:gateway_blob:999>",
                kind: .normal
            )
        )
    )

    #expect(
        await eventuallyOnMain {
            model.threadMessages.first(where: { $0.id == starter.id })?
                .reactions.contains(where: { $0.id == "custom:999" }) == true
                && model.forumPosts.first(where: { $0.id == post.id })?
                    .firstMessage?.reactions.contains(where: { $0.id == "custom:999" }) == true
        }
    )

    await provider.emit(
        .messageReactionUpdated(
            .removeEmoji(
                channelID: post.id,
                messageID: starter.id,
                emoji: "<a:renamed_gateway_blob:999>"
            )
        )
    )
    #expect(
        await eventuallyOnMain {
            model.threadMessages.first(where: { $0.id == starter.id })?
                .reactions.contains(where: { $0.id == "custom:999" }) == false
                && model.forumPosts.first(where: { $0.id == post.id })?
                    .firstMessage?.reactions.contains(where: { $0.id == "custom:999" }) == false
        }
    )
}

@MainActor
@Test func `forum preview hydration preserves loaded reactor avatars`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))

    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let initialPost = try #require(
        model.forumPosts.first(where: { $0.firstMessage?.reactions.isEmpty == false })
    )
    let initialMessage = try #require(initialPost.firstMessage)
    let initialReaction = try #require(initialMessage.reactions.first)
    await model.loadReactionReactors(initialReaction, on: initialMessage)
    #expect(
        await eventuallyOnMain {
            model.forumPosts.first(where: { $0.id == initialPost.id })?
                .firstMessage?.reactions.first(where: { $0.id == initialReaction.id })?
                .reactors.isEmpty == false
        }
    )
    let loadedReactors = try #require(
        model.forumPosts.first(where: { $0.id == initialPost.id })?
            .firstMessage?.reactions.first(where: { $0.id == initialReaction.id })?
            .reactors
    )

    var replacement = try #require(
        model.forumPosts.first(where: { $0.id == initialPost.id })
    )
    var replacementMessage = try #require(replacement.firstMessage)
    let reactionIndex = try #require(
        replacementMessage.reactions.firstIndex(where: {
            $0.id == initialReaction.id
        })
    )
    replacementMessage.reactions[reactionIndex].count += 1
    replacementMessage.reactions[reactionIndex].reactors = []
    replacement.firstMessage = replacementMessage
    await provider.emit(
        .forumPostPreviewsChanged(channelID: forum.id, posts: [replacement])
    )

    #expect(
        await eventuallyOnMain {
            guard
                let reaction = model.forumPosts.first(where: { $0.id == initialPost.id })?
                    .firstMessage?.reactions.first(where: { $0.id == initialReaction.id })
            else {
                return false
            }
            return reaction.count == initialReaction.count + 1
                && reaction.reactors == loadedReactors
        }
    )
}

@MainActor
@Test func `rapid reaction clicks publish only the latest state per message and emoji`() async throws {
    let provider = ReactionMutationTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let message = try #require(model.messages.first)

    let initialRowsRevision = model.messageRowsRevision
    await model.toggleReaction("🔥", on: message)
    #expect(model.messages.first?.reactions.first?.didCurrentUserReact == true)
    #expect(model.messageRows.first?.message.reactions.first?.didCurrentUserReact == true)
    #expect(model.messageRowsRevision > initialRowsRevision)
    await model.toggleReaction("🔥", on: message)
    #expect(model.messages.first?.reactions.isEmpty == true)
    #expect(model.messageRows.first?.message.reactions.isEmpty == true)
    await model.toggleReaction("🔥", on: message)
    #expect(model.messages.first?.reactions.first?.didCurrentUserReact == true)

    try await Task.sleep(for: .milliseconds(260))
    #expect(await provider.requests() == [.init(messageID: message.id, emoji: "🔥", reacted: true)])
}

@MainActor
@Test func `reaction clicks that return to confirmed state issue no request`() async throws {
    let provider = ReactionMutationTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let message = try #require(model.messages.first)

    for _ in 0 ..< 20 {
        await model.toggleReaction("🔥", on: message)
    }

    try await Task.sleep(for: .milliseconds(260))
    #expect(await provider.requests().isEmpty)
    #expect(model.messages.first?.reactions.isEmpty == true)
}

@MainActor
@Test func `reaction mutations stay independent across message and emoji keys`() async throws {
    let provider = ReactionMutationTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let first = try #require(model.messages.first)
    let second = try #require(model.messages.dropFirst().first)

    await model.toggleReaction("🔥", on: first)
    await model.toggleReaction("✅", on: first)
    await model.toggleReaction("🔥", on: second)

    try await Task.sleep(for: .milliseconds(260))
    let requests = await provider.requests()
    #expect(requests.count == 3)
    #expect(Set(requests.map(\.messageID)) == Set([first.id, second.id]))
    #expect(Set(requests.map(\.emoji)) == Set(["🔥", "✅"]))
}

@MainActor
@Test func `reaction failure reverts only the failed optimistic key`() async throws {
    let provider = ReactionMutationTestProvider(failingEmoji: "🔥")
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let message = try #require(model.messages.first)

    await model.toggleReaction("🔥", on: message)
    await model.toggleReaction("✅", on: message)
    #expect(model.messages.first?.reactions.count == 2)

    try await Task.sleep(for: .milliseconds(280))
    let reactions = try #require(model.messages.first?.reactions)
    #expect(reactions.contains(where: { $0.id == "unicode:🔥" }) == false)
    #expect(reactions.first(where: { $0.id == "unicode:✅" })?.didCurrentUserReact == true)
}

@MainActor
@Test func `message updates preserve already loaded reactor avatars`() async throws {
    let reactor = ReactionReactor(
        id: UserID(rawValue: 98_200),
        displayName: "Loaded Reactor",
        avatarURL: URL(string: "https://cdn.example/reactor.png")
    )
    let provider = ReactionMutationTestProvider(
        initialReaction: Reaction(emoji: "🔥", count: 2, reactors: [reactor])
    )
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let original = try #require(model.messages.first(where: { !$0.reactions.isEmpty }))

    await provider.emit(
        .messageUpdated(
            Message(
                id: original.id,
                channelID: original.channelID,
                author: original.author,
                content: original.content,
                reactions: [Reaction(emoji: "🔥", count: 3)]
            )
        )
    )

    #expect(
        await eventuallyOnMain {
            let updated = model.messages.first(where: { $0.id == original.id })
            return updated?.reactions.first?.count == 3
                && updated?.reactions.first?.reactors == [reactor]
        }
    )
}

@MainActor
@Test func `clicks during an in flight reaction collapse to one latest follow up`() async throws {
    let provider = ReactionMutationTestProvider(requestDelay: .milliseconds(220))
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let message = try #require(model.messages.first)

    await model.toggleReaction("🔥", on: message)
    try await Task.sleep(for: .milliseconds(190))
    for _ in 0 ..< 9 {
        await model.toggleReaction("🔥", on: message)
    }

    try await Task.sleep(for: .milliseconds(700))
    #expect(
        await provider.requests()
            == [
                .init(messageID: message.id, emoji: "🔥", reacted: true),
                .init(messageID: message.id, emoji: "🔥", reacted: false),
            ]
    )
    #expect(model.messages.first?.reactions.isEmpty == true)
}

@MainActor
@Test func `forum pagination failures preserve posts and can be retried`() async throws {
    let provider = ForumPaginationTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    #expect(
        await eventuallyOnMain {
            model.hasLoadedForumPosts
                && model.forumPosts.count == 1
                && model.hasMoreForumPosts
        }
    )
    let initialPostIDs = model.forumPosts.map(\.id)

    model.updateForumSearch("Recent")
    #expect(!model.hasMoreForumPosts)
    await model.loadMoreForumPosts()
    #expect(await provider.paginationRequestCount() == 0)
    model.updateForumSearch("")
    #expect(model.hasMoreForumPosts)

    await model.loadMoreForumPosts()

    #expect(model.forumPosts.map(\.id) == initialPostIDs)
    #expect(model.forumPostError == nil)
    #expect(model.forumPaginationError != nil)
    #expect(model.hasMoreForumPosts)

    await model.loadMoreForumPosts()

    #expect(model.forumPosts.count == 2)
    #expect(model.forumPaginationError == nil)
    #expect(!model.hasMoreForumPosts)
    #expect(await provider.paginationRequestCount() == 2)
}

@MainActor
@Test func `opening a forum acknowledges only the parent new post boundary`() async throws {
    let provider = ForumVisitAcknowledgementTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    #expect(
        await eventuallyOnMain {
            model.hasLoadedForumPosts && model.forumPosts.count == 2
        }
    )
    for _ in 0 ..< 40 where await provider.acknowledgements().isEmpty {
        try await Task.sleep(for: .milliseconds(25))
    }
    let acknowledgement = try #require(await provider.acknowledgements().first)
    #expect(acknowledgement.channelID == provider.forumID)
    #expect(acknowledgement.messageID.rawValue > provider.newPostID.rawValue)
    #expect(await provider.acknowledgements().count == 1)

    let newPost = try #require(model.forumPosts.first(where: { $0.id == provider.newPostID }))
    let unreadPost = try #require(
        model.forumPosts.first(where: { $0.id == provider.unreadPostID })
    )
    #expect(model.isForumPostNew(newPost))
    #expect(!model.isForumPostUnread(newPost))
    #expect(model.shouldEmphasizeForumPost(newPost))
    #expect(model.isForumPostUnread(unreadPost))
    #expect(model.shouldEmphasizeForumPost(unreadPost))
    #expect(!model.isChannelUnread(provider.forumID))

    model.open(newPost)
    #expect(!model.isForumPostNew(newPost))
    #expect(!model.shouldEmphasizeForumPost(newPost))
}

@MainActor
@Test func `forum thread links select their parent and open the post`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))
    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let post = try #require(model.forumPosts.first)
    let otherChannel = try #require(
        model.snapshot?.channels.first(where: { $0.guildID == forum.guildID && $0.id != forum.id })
    )

    model.selectedChannelID = otherChannel.id
    model.navigate(to: post.thread.guildID, linkedChannelID: post.id)

    #expect(
        await eventuallyOnMain {
            model.selectedChannelID == forum.id && model.openThread?.id == post.id
        }
    )
}

@MainActor
@Test func `returning to a forum clears the previous forum query state`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))
    let otherChannel = try #require(
        model.snapshot?.channels.first {
            $0.guildID == forum.guildID && $0.id != forum.id && $0.kind != .forum
        }
    )
    let tagID = try #require(forum.availableTags.first?.id)

    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts })
    model.forumSelectedTagIDs = [tagID]
    model.updateForumSearch("visual")
    #expect(model.forumSearchText == "visual")
    #expect(model.forumSelectedTagIDs == [tagID])

    model.selectedChannelID = otherChannel.id
    model.selectedChannelID = forum.id

    #expect(model.forumSearchText.isEmpty)
    #expect(model.forumSelectedTagIDs.isEmpty)
    #expect(!model.hasMoreForumPosts)
    #expect(
        await eventuallyOnMain {
            model.hasLoadedForumPosts
                && model.forumSearchText.isEmpty
                && model.forumSelectedTagIDs.isEmpty
        }
    )
}

@MainActor
@Test func `ordinary linked channels load their guild before forum resolution`() async {
    let provider = LinkedChannelNavigationTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let target = provider.targetChannel

    model.navigate(to: target.guildID, linkedChannelID: target.id)

    #expect(
        await eventuallyOnMain {
            model.selectedGuildID == target.guildID
                && model.selectedChannelID == target.id
        }
    )
    #expect(await provider.forumPostRequestCount() == 0)
}

@MainActor
@Test func `remote forum deletion closes the open post`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))

    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let post = try #require(model.forumPosts.first)
    model.open(post)
    #expect(model.openThread?.id == post.id)

    await provider.emit(
        .forumPostsChanged(
            channelID: forum.id,
            posts: model.forumPosts.filter { $0.id != post.id }
        )
    )

    #expect(await eventuallyOnMain { model.openThread == nil })
}

@MainActor
@Test func `forum cache events cannot close an ordinary text thread`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channel = try #require(model.snapshot?.channels.first(where: { $0.kind == .text }))
    model.selectedChannelID = channel.id
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 999_001),
        guildID: channel.guildID,
        parentID: channel.id,
        name: "Ordinary thread"
    )
    model.open(thread)

    await provider.emit(.forumPostsChanged(channelID: channel.id, posts: []))
    await Task.yield()

    #expect(model.openThread?.id == thread.id)
}

@MainActor
@Test func `thread send commits one final timeline revision`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(
        model.snapshot?.channels.first(where: { $0.kind == .forum })
    )
    model.selectedChannelID = forum.id
    #expect(
        await eventuallyOnMain {
            model.hasLoadedForumPosts
                && model.forumPosts.contains(where: { !$0.thread.isLocked })
        }
    )
    let post = try #require(
        model.forumPosts.first(where: { !$0.thread.isLocked })
    )
    model.open(post)
    #expect(
        await eventuallyOnMain {
            model.hasCompletedInitialThreadLoad
                && model.openThreadAccess.canSend
        }
    )
    let previousCount = model.threadMessages.count
    let previousRevision = model.threadMessageRowsRevision
    model.threadDraft = "one thread timeline mutation"

    #expect(await model.sendThreadComposerMessage(attachments: []))
    #expect(
        await eventuallyOnMain {
            model.threadMessages.count == previousCount + 1
        }
    )
    await Task.yield()

    #expect(model.threadMessageRowsRevision == previousRevision + 1)
    guard case let .insert(insertedIndexes) =
        model.threadMessageRowsUpdateHint?.change
    else {
        Issue.record("Expected a bounded thread insertion hint")
        return
    }
    #expect(insertedIndexes == IndexSet(integer: previousCount))
    let records = try #require(
        model.threadMessageRowsUpdateJournal.records(
            after: previousRevision,
            through: model.threadMessageRowsRevision
        )
    )
    let record = try #require(records.first)
    #expect(record.revision == model.threadMessageRowsRevision)
    #expect(record.insertedMessageIDs == [model.threadMessages[previousCount].id])
    #expect(!record.invalidatesAllRows)
}

@MainActor
@Test func `Discord channel links accept forum thread URLs without accepting lookalike hosts`() throws {
    let forumURL = try #require(URL(string: "https://discord.com/channels/100/220"))
    let lookalikeURL = try #require(URL(string: "https://discord.example/channels/100/220"))
    let link = DiscordChannelLink(forumURL)
    #expect(link?.guildID == GuildID(rawValue: 100))
    #expect(link?.channelID == ChannelID(rawValue: 220))
    #expect(DiscordChannelLink(lookalikeURL) == nil)
}

@Test func `cancelled forum searches never become user visible errors`() {
    #expect(AppModel.isForumLoadCancellation(CancellationError()))
    #expect(AppModel.isForumLoadCancellation(URLError(.cancelled)))
    #expect(!AppModel.isForumLoadCancellation(URLError(.timedOut)))
}

@Test func `forum post deletion is limited to its owner or a thread moderator`() {
    let ownerID = UserID(rawValue: 10)
    let otherID = UserID(rawValue: 11)

    #expect(
        AppModel.canDeleteForumPost(
            ownerID: ownerID,
            currentUserID: ownerID,
            canManage: false
        )
    )
    #expect(
        !AppModel.canDeleteForumPost(
            ownerID: ownerID,
            currentUserID: otherID,
            canManage: false
        )
    )
    #expect(
        AppModel.canDeleteForumPost(
            ownerID: ownerID,
            currentUserID: otherID,
            canManage: true
        )
    )
}

@MainActor
@Test func `forum creation clears queued upload progress after completion`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))
    let tag = try #require(forum.availableTags.first(where: { !$0.isModerated }))
    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts })

    let didCreate = await model.createForumPost(
        CreateForumPostDraft(
            channelID: forum.id,
            title: "Progress lifecycle",
            content: "The completion state must not be overwritten by a queued callback.",
            appliedTagIDs: [tag.id]
        )
    )
    await Task.yield()

    #expect(didCreate)
    #expect(model.forumCreateProgress == nil)
}

@MainActor
@Test func `deleting an offline forum post removes its card and closes its thread`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))
    let currentUserID = try #require(model.snapshot?.currentUser.id)

    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let post = try #require(
        model.forumPosts.first {
            ($0.thread.ownerID ?? $0.owner?.id) == currentUserID
        }
    )
    model.open(post)
    #expect(model.openThread?.id == post.id)

    await model.deleteForumPost(post)

    #expect(!model.forumPosts.contains { $0.id == post.id })
    #expect(model.openThread == nil)
    #expect(model.forumActionError == nil)
}

@Test func `forum presentation preserves section ordering while filtering without duplicates`() {
    let now = Date(timeIntervalSince1970: 10_000)
    let tagA = ForumTagID(rawValue: 1)
    let tagB = ForumTagID(rawValue: 2)
    let posts = [
        forumPresentationPost(id: 1, name: "Pinned alpha", date: now, tags: [tagA], pinned: true),
        forumPresentationPost(
            id: 2, name: "Newest alpha beta", date: now.addingTimeInterval(30), tags: [tagA, tagB]
        ),
        forumPresentationPost(
            id: 3, name: "Older alpha beta", date: now.addingTimeInterval(20), tags: [tagA, tagB],
            archived: true
        ),
        forumPresentationPost(
            id: 4, name: "Newest archived alpha beta", date: now.addingTimeInterval(40),
            tags: [tagA, tagB], archived: true
        ),
        forumPresentationPost(id: 5, name: "Unrelated", date: now, tags: [tagB]),
    ]

    let presentation = ForumPostPresentation.make(
        catalogue: posts,
        searchText: " ALPHA ",
        selectedTagIDs: [tagA, tagB],
        tagMatch: .matchAll,
        sortOrder: .latestActivity
    )

    #expect(presentation.recentCount == 1)
    #expect(presentation.posts.map(\.id.rawValue) == [2, 4, 3])
    #expect(Set(presentation.posts.map(\.id)).count == presentation.posts.count)

    var updated = posts[3]
    updated.thread.isArchived = false
    updated.thread.flags = 1 << 1
    let incremental = presentation.updating(
        updated,
        searchText: " ALPHA ",
        selectedTagIDs: [tagA, tagB],
        tagMatch: .matchAll,
        sortOrder: .latestActivity
    )
    let rebuilt = ForumPostPresentation.make(
        catalogue: posts.enumerated().map { $0.offset == 3 ? updated : $0.element },
        searchText: " ALPHA ",
        selectedTagIDs: [tagA, tagB],
        tagMatch: .matchAll,
        sortOrder: .latestActivity
    )
    #expect(incremental.posts == rebuilt.posts)
    #expect(incremental.recentCount == rebuilt.recentCount)

    let narrowed = ForumPostPresentation.make(
        catalogue: posts,
        searchText: "",
        selectedTagIDs: [],
        tagMatch: .matchSome,
        sortOrder: .latestActivity
    ).filtering(
        searchText: "newest alpha beta",
        selectedTagIDs: [],
        tagMatch: .matchSome
    )
    let rebuiltNarrowed = ForumPostPresentation.make(
        catalogue: posts,
        searchText: "newest alpha beta",
        selectedTagIDs: [],
        tagMatch: .matchSome,
        sortOrder: .latestActivity
    )
    #expect(narrowed.posts == rebuiltNarrowed.posts)
    #expect(narrowed.recentCount == rebuiltNarrowed.recentCount)
}

private func forumPresentationPost(
    id: UInt64,
    name: String,
    date: Date,
    tags: [ForumTagID],
    pinned: Bool = false,
    archived: Bool = false
) -> ForumPost {
    ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: id),
            name: name,
            isArchived: archived,
            appliedTagIDs: tags,
            flags: pinned ? 1 << 1 : 0,
            archiveTimestamp: archived ? date : nil,
            createdAt: date
        )
    )
}

@Test func `ten thousand forum posts keep stable identities through an incremental update`() throws {
    let posts = (0 ..< 10_000).map { index in
        forumPresentationPost(
            id: UInt64(index + 1),
            name: "Forum post \(index)",
            date: Date(timeIntervalSince1970: TimeInterval(index)),
            tags: [],
            pinned: index.isMultiple(of: 1_000),
            archived: index >= 5_000
        )
    }
    let presentation = ForumPostPresentation.make(
        catalogue: posts,
        searchText: "",
        selectedTagIDs: [],
        tagMatch: .matchSome,
        sortOrder: .latestActivity
    )
    #expect(presentation.posts.count == 10_000)
    #expect(presentation.recentCount == 5_000)
    #expect(Set(presentation.posts.map(\.id)).count == 10_000)

    var updated = try #require(posts.last)
    updated.thread.isArchived = false
    updated.thread.flags = 1 << 1
    let result = presentation.updating(
        updated,
        searchText: "",
        selectedTagIDs: [],
        tagMatch: .matchSome,
        sortOrder: .latestActivity
    )
    #expect(result.posts.count == 10_000)
    #expect(result.recentCount == 5_001)
    #expect(Set(result.posts.map(\.id)).count == 10_000)
}

@Test func `component control identity is scoped to its message`() {
    let first = ComponentControlKey(messageID: MessageID(rawValue: 1), customID: "confirm")
    let second = ComponentControlKey(messageID: MessageID(rawValue: 2), customID: "confirm")
    #expect(first != second)
    #expect(Set([first, second]).count == 2)
}

@Test func `rich message selection copies custom emoji as its discord token`() {
    let value = NSMutableAttributedString(string: "hello ")
    let attachment = NSMutableAttributedString(attachment: NSTextAttachment())
    attachment.addAttribute(
        .discordEmojiToken,
        value: "<:wave:123>",
        range: NSRange(location: 0, length: attachment.length)
    )
    value.append(attachment)
    value.append(NSAttributedString(string: " @Design"))

    #expect(
        RichMessageCopySerializer.string(
            from: value,
            range: NSRange(location: 0, length: value.length)
        ) == "hello <:wave:123> @Design"
    )
}

@MainActor
@Test func `selected custom emoji exposes an attachment overlay rect`() throws {
    let attachment = NSTextAttachment()
    attachment.image = NSImage(size: NSSize(width: 22, height: 22))
    attachment.bounds = NSRect(x: 0, y: -3, width: 22, height: 22)
    let value = NSMutableAttributedString(string: "before ")
    value.append(NSAttributedString(attachment: attachment))
    value.append(NSAttributedString(string: " after"))

    let textView = RichMessageNSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.containerSize = NSSize(width: 240, height: 40)
    textView.textStorage?.setAttributedString(value)
    textView.setSelectedRange(NSRange(location: 7, length: 1))
    textView.layoutManager?.ensureLayout(for: try #require(textView.textContainer))

    let rect = try #require(textView.attachmentSelectionRects().first)
    #expect(rect.width >= 22)
    #expect(rect.height >= 22)
}

@MainActor
@Test func `mention popover anchor tracks the exact inline attachment glyph`() throws {
    let token = "<@42>"
    let presentation = MentionPresentation(
        rawToken: token,
        label: "@Maya",
        target: .user(UserID(rawValue: 42))
    )
    let value = NSMutableAttributedString(string: "before ")
    value.append(MentionAttachmentRenderer.attributedString(presentation: presentation))
    value.append(NSAttributedString(string: " after"))

    let window = NSWindow(
        contentRect: CGRect(x: 120, y: 140, width: 420, height: 180),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let contentView = NSView(frame: window.contentLayoutRect)
    let textView = RichMessageNSTextView(frame: CGRect(x: 36, y: 70, width: 320, height: 44))
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.containerSize = NSSize(width: 320, height: 44)
    textView.textStorage?.setAttributedString(value)
    contentView.addSubview(textView)
    window.contentView = contentView
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    let index = 7
    textView.layoutManager?.ensureLayout(for: try #require(textView.textContainer))
    let glyphRect = try #require(textView.mentionAttachmentRect(at: index, rawToken: token))
    let anchor = try #require(textView.mentionPopoverAnchor(at: index, rawToken: token))
    #expect(anchor.sourceView === textView)
    #expect(anchor.sourceRect() == glyphRect)
    #expect(glyphRect.width >= 50)
    #expect(glyphRect.height >= 21)

    let tracker = StablePopoverAnchorTracker()
    let firstSourceRect = try #require(anchor.sourceRect())
    let firstFrame = try #require(
        tracker.attach(
            to: textView,
            sourceRect: firstSourceRect
        ))
    #expect(firstFrame != contentView.bounds)

    textView.frame.origin.x += 48
    let movedSourceRect = try #require(anchor.sourceRect())
    let movedFrame = try #require(
        tracker.attach(
            to: textView,
            sourceRect: movedSourceRect
        ))
    #expect(abs(movedFrame.minX - firstFrame.minX - 48) <= 0.5)
    #expect(abs(movedFrame.width - glyphRect.width) <= 0.5)
}

@MainActor
@Test func `selecting a different message clears the previous message selection`() {
    let first = RichMessageNSTextView()
    first.string = "first message"
    first.setSelectedRange(NSRange(location: 0, length: 5))
    first.claimSelectionOwnership()

    let second = RichMessageNSTextView()
    second.string = "second message"
    second.setSelectedRange(NSRange(location: 0, length: 6))
    second.claimSelectionOwnership()

    #expect(first.selectedRange().length == 0)
    #expect(second.selectedRange() == NSRange(location: 0, length: 6))
}

@MainActor
@Test func `reply summary removes markdown and collapses multiline content`() {
    let summary = MessageReplySummary.text(
        content: "# **test**\n[DiscordKit](https://example.com) <:cat_blob:123> <@42>"
    ) { mention in
        mention.id == "42" ? "@Maya" : "@unknown-user"
    }

    #expect(summary == "test DiscordKit :cat_blob: @Maya")
    #expect(MessageReplySummary.text(content: " \n\t ") == "Attachment")
}

@Test func `only supported offline flags select testing mode`() {
    #expect(AppLaunchConfiguration(arguments: ["SakuraCord"]).mode == .normal)
    #expect(AppLaunchConfiguration(arguments: ["SakuraCord", "--offline"]).mode == .offlineTesting)
    let longList = AppLaunchConfiguration(arguments: ["SakuraCord", "--offline-long-server-list"])
    #expect(longList.mode == .offlineTesting)
    #expect(longList.includesLongServerList)
    let forumPerformance = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-forum-performance"]
    )
    #expect(forumPerformance.mode == .offlineTesting)
    #expect(forumPerformance.includesForumPerformanceFixture)
    let chatPerformance = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-chat-performance"]
    )
    #expect(chatPerformance.mode == .offlineTesting)
    #expect(chatPerformance.includesChatPerformanceFixture)
    #expect(!chatPerformance.runsChatPerformanceAutoScroll)
    let chatAutoScroll = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-chat-performance-autoscroll"]
    )
    #expect(chatAutoScroll.mode == .offlineTesting)
    #expect(chatAutoScroll.includesChatPerformanceFixture)
    #expect(chatAutoScroll.runsChatPerformanceAutoScroll)
    #expect(!chatAutoScroll.runsChatLiveArrivalStress)
    let chatLiveAutoScroll = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-chat-performance-live-autoscroll"]
    )
    #expect(chatLiveAutoScroll.mode == .offlineTesting)
    #expect(chatLiveAutoScroll.includesChatPerformanceFixture)
    #expect(chatLiveAutoScroll.runsChatPerformanceAutoScroll)
    #expect(chatLiveAutoScroll.runsChatLiveArrivalStress)
    let chatMediaAutoScroll = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-chat-media-performance-autoscroll"]
    )
    #expect(chatMediaAutoScroll.mode == .offlineTesting)
    #expect(chatMediaAutoScroll.includesChatPerformanceFixture)
    #expect(chatMediaAutoScroll.includesChatMediaPerformanceFixture)
    #expect(chatMediaAutoScroll.runsChatPerformanceAutoScroll)
    #expect(!chatMediaAutoScroll.runsChatLiveArrivalStress)
    let incomingPrivateCall = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-incoming-private-call"]
    )
    #expect(incomingPrivateCall.mode == .offlineTesting)
    #expect(incomingPrivateCall.includesIncomingPrivateCallFixture)
}

@MainActor
@Test func `network disabled normal launch stops signed out without mock data`() async {
    let model = AppModel(launchMode: .normal, discordNetworkDisabledOverride: true)
    #expect(model.sessionState == .restoring)
    await model.start()

    #expect(model.sessionState == .signedOut)
    #expect(model.snapshot == nil)
    #expect(model.visibleChannels.isEmpty)
    #expect(!model.isOfflineTesting)
}

@MainActor
@Test func `offline launch never consults its credential store`() async {
    let credentials = CredentialAccessProbeStore()
    let model = AppModel(launchMode: .offlineTesting, credentialStore: credentials)

    await model.start()

    #expect(model.sessionState == .workspace)
    #expect(await credentials.accessCount == 0)
}

@MainActor
@Test func `interactive sign in keeps login presentation alive until bootstrap finishes`() async {
    let provider = SuspendedBootstrapTestProvider()
    let notifications = PermissionRecordingNotificationService()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        authenticatedProviderFactory: { _, _ in provider },
        notificationService: notifications
    )
    await model.start()
    #expect(model.sessionState == .signedOut)

    let connection = Task {
        await model.connectAuthenticatedAccount(
            CredentialHandle(accountID: "93000"),
            preservesInteractivePresentation: true
        )
    }
    await provider.waitUntilBootstrapStarts()

    // Switching to `.connecting` here destroys DiscordLoginView, whose
    // disappearance cancels the task that is performing this bootstrap.
    #expect(model.sessionState == .signedOut)

    await provider.releaseBootstrap()
    #expect(await connection.value)
    #expect(model.sessionState == .workspace)
    #expect(model.isAuthenticated)
    #expect(notifications.authorizationRequestCount == 1)
}

private actor CredentialAccessProbeStore: CredentialStore {
    private(set) var accessCount = 0

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        accessCount += 1
        return CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        accessCount += 1
        return Data()
    }

    func remove(_ handle: CredentialHandle) async throws {
        accessCount += 1
    }

    func handles() async throws -> [CredentialHandle] {
        accessCount += 1
        return []
    }
}

@MainActor
@Test func `interactive sign in failure stays signed out and exposes bootstrap error`() async {
    let provider = SuspendedBootstrapTestProvider(bootstrapError: "fixture bootstrap stopped")
    let notifications = PermissionRecordingNotificationService()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        authenticatedProviderFactory: { _, _ in provider },
        notificationService: notifications
    )
    await model.start()

    let connection = Task {
        await model.connectAuthenticatedAccount(
            CredentialHandle(accountID: "93000"),
            preservesInteractivePresentation: true
        )
    }
    await provider.waitUntilBootstrapStarts()
    #expect(model.sessionState == .signedOut)

    await provider.releaseBootstrap()
    #expect(await !(connection.value))
    #expect(model.sessionState == .signedOut)
    #expect(model.errorMessage == "fixture bootstrap stopped")
    #expect(notifications.authorizationRequestCount == 0)
}

@MainActor
@Test func `replying targets the selected message and clears after sending`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let target = try #require(model.messages.first)

    model.reply(to: target)
    #expect(model.replyingTo?.id == target.id)

    model.updateDraft("reply from test")
    await model.send()

    #expect(model.messages.last?.replyTo == target.id)
    #expect(model.messageRows.last?.replyPreview?.messageID == target.id)
    #expect(model.messageRows.last?.replyPreview?.content == target.content)
    #expect(model.replyingTo == nil)
}

@MainActor
@Test func `message grouping matches discord continuation rules`() {
    let author = User(id: UserID(rawValue: 1), username: "one", displayName: "One")
    let other = User(id: UserID(rawValue: 2), username: "two", displayName: "Two")
    let channel = ChannelID(rawValue: 10)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let messages = [
        Message(
            id: MessageID(rawValue: 1), channelID: channel, author: author, content: "first",
            timestamp: base),
        Message(
            id: MessageID(rawValue: 2), channelID: channel, author: author, content: "six minutes",
            timestamp: base.addingTimeInterval(6 * 60)),
        Message(
            id: MessageID(rawValue: 3), channelID: channel, author: author,
            content: "seven minutes", timestamp: base.addingTimeInterval(13 * 60)),
        Message(
            id: MessageID(rawValue: 4), channelID: channel, author: other, content: "other author",
            timestamp: base.addingTimeInterval(13 * 60 + 1)),
        Message(
            id: MessageID(rawValue: 5), channelID: channel, author: other, content: "reply",
            timestamp: base.addingTimeInterval(13 * 60 + 2), replyTo: MessageID(rawValue: 1)),
    ]

    let rows = MessageGrouping.rows(for: messages)
    #expect(rows.map(\.startsGroup) == [true, false, true, true, true])
}

@MainActor
@Test func `system messages break surrounding author groups`() {
    let author = User(id: UserID(rawValue: 1), username: "nova", displayName: "Nova")
    let start = Date(timeIntervalSince1970: 1_000)
    let messages = [
        Message(
            id: MessageID(rawValue: 1), channelID: ChannelID(rawValue: 1), author: author,
            content: "before", timestamp: start
        ),
        Message(
            id: MessageID(rawValue: 2), channelID: ChannelID(rawValue: 1), author: author,
            content: "", timestamp: start.addingTimeInterval(10), type: .userJoin
        ),
        Message(
            id: MessageID(rawValue: 3), channelID: ChannelID(rawValue: 1), author: author,
            content: "after", timestamp: start.addingTimeInterval(20)
        ),
    ]

    #expect(MessageGrouping.rows(for: messages).map(\.startsGroup) == [true, true, true])
}

@MainActor
@Test func `application command responses break surrounding app groups`() {
    let app = User(
        id: UserID(rawValue: 10), username: "verified", displayName: "Verified", isBot: true
    )
    let channel = ChannelID(rawValue: 1)
    let start = Date(timeIntervalSince1970: 1_000)
    let messages = [
        Message(
            id: MessageID(rawValue: 1), channelID: channel, author: app,
            content: "before", timestamp: start
        ),
        Message(
            id: MessageID(rawValue: 2), channelID: channel, author: app,
            content: "result", timestamp: start.addingTimeInterval(1), type: .chatInputCommand
        ),
        Message(
            id: MessageID(rawValue: 3), channelID: channel, author: app,
            content: "after", timestamp: start.addingTimeInterval(2)
        ),
    ]

    #expect(MessageGrouping.rows(for: messages).map(\.startsGroup) == [true, true, true])
}

@MainActor
@Test func `member sections use hoisted roles and sort members`() {
    let members = [
        Member(
            user: User(id: UserID(rawValue: 1), username: "zed", displayName: "Zed"),
            roleName: "Moderator",
            status: .online,
            rolePosition: 10,
            isRoleCategory: true
        ),
        Member(
            user: User(id: UserID(rawValue: 2), username: "amy", displayName: "Amy"),
            roleName: "Moderator",
            status: .idle,
            rolePosition: 10,
            isRoleCategory: true
        ),
        Member(
            user: User(id: UserID(rawValue: 3), username: "sam", displayName: "Sam"),
            roleName: "Member",
            status: .online
        ),
        Member(
            user: User(id: UserID(rawValue: 4), username: "off", displayName: "Offline"),
            roleName: "Moderator",
            status: .offline,
            rolePosition: 10,
            isRoleCategory: true
        ),
    ]

    let sections = MemberSection.make(from: members)
    #expect(sections.map(\.title) == ["Moderator", "Online", "Offline"])
    #expect(sections[0].members.map(\.user.displayName) == ["Amy", "Zed"])
    #expect(sections[2].members.map(\.user.displayName) == ["Offline"])
}

@MainActor
@Test func `channel groups place voice channels after text channels`() {
    let guildID = GuildID(rawValue: 20)
    let categoryID = ChannelID(rawValue: 21)
    let channels = [
        Channel(
            id: ChannelID(rawValue: 22), guildID: guildID, name: "Voice first by position",
            kind: .voice, category: "Chat", categoryID: categoryID, position: 0),
        Channel(
            id: ChannelID(rawValue: 23), guildID: guildID, name: "general", category: "Chat",
            categoryID: categoryID, position: 2),
        Channel(
            id: ChannelID(rawValue: 24), guildID: guildID, name: "announcements",
            kind: .announcement, category: "Chat", categoryID: categoryID, position: 3),
        Channel(
            id: ChannelID(rawValue: 25), guildID: guildID, name: "Voice second", kind: .voice,
            category: "Chat", categoryID: categoryID, position: 1),
    ]

    let group = ChannelGroup.make(from: channels)[0]
    #expect(
        group.channels.map(\.name) == [
            "general", "announcements", "Voice first by position", "Voice second",
        ])
}

@MainActor
@Test func `automatic guild selection prefers a text conversation over general voice`() {
    let guildID = GuildID(rawValue: 7)
    let voiceGeneral = Channel(
        id: ChannelID(rawValue: 70),
        guildID: guildID,
        name: "general",
        kind: .voice
    )
    let welcome = Channel(
        id: ChannelID(rawValue: 71),
        guildID: guildID,
        name: "welcome",
        kind: .text
    )
    let textGeneral = Channel(
        id: ChannelID(rawValue: 72),
        guildID: guildID,
        name: "general",
        kind: .text
    )

    #expect(
        AppModel.preferredInitialChannelID(
            in: [voiceGeneral, welcome, textGeneral]
        ) == textGeneral.id
    )
    #expect(
        AppModel.preferredInitialChannelID(in: [voiceGeneral, welcome])
            == welcome.id
    )
    #expect(
        AppModel.preferredInitialChannelID(in: [voiceGeneral])
            == voiceGeneral.id
    )
}

@MainActor
@Test func `selecting voice channel opens its text chat by default without joining`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let voiceChannel = try #require(model.visibleChannels.first(where: { $0.kind == .voice }))

    model.selectedChannelID = voiceChannel.id

    #expect(model.selectedChannel?.id == voiceChannel.id)
    #expect(model.selectedChannel?.kind == .voice)
    #expect(model.activeVoiceChannel == nil)
    #expect(model.isVoiceChatOpen)
    #expect(await eventuallyOnMain { !model.isLoadingMessages && !model.messages.isEmpty })
}

@MainActor
@Test func `voice channel selection loads once and closed chat can be reopened`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let voiceChannel = ChannelID(rawValue: 91003)

    model.selectedChannelID = voiceChannel
    #expect(await eventuallyOnMain { !model.isLoadingMessages })
    #expect(await provider.requestCount(for: voiceChannel) == 1)
    #expect(model.activeVoiceChannel == nil)
    #expect(model.isVoiceChatOpen)

    let channel = try #require(model.selectedChannel)
    model.openVoiceChat(for: channel)
    #expect(await provider.requestCount(for: voiceChannel) == 1)
    #expect(model.messages.map(\.channelID) == [voiceChannel])
    #expect(model.activeVoiceChannel == nil)
    #expect(model.isVoiceChatOpen)

    model.openVoiceChat(for: channel)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await provider.requestCount(for: voiceChannel) == 1)

    model.closeVoiceChat()
    #expect(!model.isVoiceChatOpen)
    #expect(model.activeVoiceChannel == nil)

    model.openVoiceChat(for: channel)
    #expect(model.isVoiceChatOpen)
    try await Task.sleep(for: .milliseconds(40))
    #expect(!model.isLoadingMessages)
    #expect(await provider.requestCount(for: voiceChannel) == 2)
    #expect(model.activeVoiceChannel == nil)
}

@MainActor
@Test func `profile role names remove custom emoji markup and collapse whitespace`() {
    #expect(
        ProfileRolePresentation.normalizedName("  Developers   <:sparkle:123456>   💖  ")
            == "Developers 💖"
    )
    #expect(ProfileRolePresentation.normalizedName("<a:dance:987654>") == "")
    #expect(ProfileRolePresentation.collapsedLimit == 5)
}

@Test func `unchanged unread projection does not republish the account snapshot`() async throws {
    let snapshot = try await MockChatProvider().bootstrap()
    #expect(
        !UnreadPresentationPublicationPolicy.shouldPublish(
            snapshot: snapshot,
            channels: snapshot.channels,
            guilds: snapshot.guilds
        )
    )

    var changedChannels = snapshot.channels
    changedChannels[0].unreadCount += 1
    #expect(
        UnreadPresentationPublicationPolicy.shouldPublish(
            snapshot: snapshot,
            channels: changedChannels,
            guilds: snapshot.guilds
        )
    )
}

@MainActor
@Test func `selecting member loads full profile`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let member = try #require(model.members.first)

    model.selectMember(member)
    #expect(await eventuallyOnMain { model.selectedProfile?.id == member.id })

    let profile = try #require(model.selectedProfile)
    #expect(model.isInspectorProfilePresented)
    #expect(profile.id == member.id)
    #expect(!profile.badges.isEmpty)
    #expect(!profile.mutualGuilds.isEmpty)
    #expect(profile.status == member.status)
}

@MainActor
@Test func `message profile does not compete with the member inspector popover`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let contextualMember = try #require(model.members.first)
    let inspectorMember = try #require(
        model.members.first { $0.id != contextualMember.id }
    )
    model.showInspector = false

    model.selectMember(inspectorMember)
    model.showProfile(for: contextualMember.user)
    #expect(model.isInspectorProfilePresented)
    #expect(model.selectedMember?.id == inspectorMember.id)
    #expect(
        model.contextualProfilePresentation?.member.id
            == contextualMember.id
    )
    #expect(
        await eventuallyOnMain {
            model.contextualProfilePresentation?.profile?.id
                == contextualMember.id
        }
    )
    #expect(
        await eventuallyOnMain {
            model.selectedProfile?.id == inspectorMember.id
        }
    )
    #expect(model.selectedMember?.id == inspectorMember.id)
    #expect(model.selectedProfile?.id == inspectorMember.id)
    #expect(model.isInspectorProfilePresented)
    #expect(!model.showInspector)
    #expect(
        model.contextualProfilePresentation?.member.id
            == contextualMember.id
    )

    model.dismissContextualProfile(for: contextualMember.id)
    #expect(model.contextualProfilePresentation == nil)
    #expect(model.isInspectorProfilePresented)
    #expect(model.selectedMember?.id == inspectorMember.id)
}

@MainActor
private func eventuallyOnMain(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
@Test func `demo emoji preferences and custom emoji assets stay offline`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    #expect(model.favoriteEmojiKeys.isEmpty)
    #expect(model.emojiUsageCounts.isEmpty)
    model.recordEmojiUse("native:✨")
    #expect(model.emojiUsageCounts == ["native:✨": 1])

    let guildID = try #require(model.selectedGuildID)
    let emojis = try await provider.emojis(in: guildID)
    #expect(emojis.count == 3)
    #expect(emojis.allSatisfy { $0.imageURL?.isFileURL == true })
    #expect(emojis.allSatisfy { $0.imageURL?.host != "cdn.discordapp.com" })
    #expect(
        emojis.allSatisfy { emoji in
            emoji.imageURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        })
    for emoji in emojis {
        ComposerEmojiImageStore.shared.register(emoji)
        #expect(ComposerEmojiImageStore.shared.cachedImage(for: emoji.messageToken) != nil)
    }
    let attributed = ComposerEmojiAttributedText.make(
        emojis.map(\.messageToken).joined(separator: " ")
    )
    var renderedAttachmentCount = 0
    attributed.enumerateAttribute(
        .attachment,
        in: NSRange(location: 0, length: attributed.length)
    ) { value, _, _ in
        guard let attachment = value as? NSTextAttachment else { return }
        #expect(attachment.image?.isValid == true)
        renderedAttachmentCount += 1
    }
    #expect(renderedAttachmentCount == emojis.count)
    let settings = try await provider.emojiUserSettings()
    #expect(
        settings.favoriteKeys.prefix(3) == [
            "custom:900000000000000201", "white_check_mark", "x",
        ])
    #expect(settings.frequentlyUsedKeys.count == 18)
}

@MainActor
@Test func `channel loads are single flight cached and protected from stale responses`()
    async throws
{
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)

    await model.start()
    let firstChannel = ChannelID(rawValue: 91001)
    let secondChannel = ChannelID(rawValue: 91002)
    #expect(await provider.requestCount(for: firstChannel) == 1)
    #expect(model.messages.map(\.channelID) == [firstChannel])

    model.selectedChannelID = secondChannel
    try await Task.sleep(for: .milliseconds(5))
    model.selectedChannelID = firstChannel

    // The in-memory page is restored synchronously, while the refresh remains
    // explicitly in flight so the UI cannot claim this cached boundary is the
    // start of the channel.
    #expect(model.messages.map(\.channelID) == [firstChannel])
    #expect(model.isLoadingMessages)
    try await Task.sleep(for: .milliseconds(160))

    #expect(model.selectedChannelID == firstChannel)
    #expect(model.messages.allSatisfy { $0.channelID == firstChannel })
    #expect(await provider.requestCount(for: firstChannel) == 2)
    #expect(await provider.requestCount(for: secondChannel) == 1)
}

@MainActor
@Test func `app model reconciles lazy production reactors without repeated reads`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let message = try #require(model.messages.first)
    let reaction = try #require(message.reactions.first)
    #expect(reaction.reactors.isEmpty)
    await model.loadReactionReactors(reaction, on: message)

    let loaded = try #require(model.messages.first?.reactions.first)
    #expect(loaded.reactors.map(\.displayName) == ["One", "Two", "Three", "Four", "Five"])
    #expect(await provider.reactorRequestCount() == 1)

    await model.loadReactionReactors(loaded, on: try #require(model.messages.first))
    #expect(await provider.reactorRequestCount() == 1)
}

@MainActor
@Test func `failed earlier page stays retryable without refreshing the newest page`() async throws {
    let provider = ChannelLoadTestProvider(failsFirstEarlierPage: true)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)

    await model.start()
    let channelID = try #require(model.selectedChannelID)
    #expect(model.hasMoreMessages)

    await model.loadEarlier()
    #expect(model.messageLoadError != nil)
    #expect(model.hasMoreMessages)
    #expect(!model.isLoadingEarlier)

    model.retryMessageLoad()

    #expect(await eventuallyOnMain {
        model.messageLoadError == nil
            && !model.isLoadingEarlier
            && !model.hasMoreMessages
            && model.messages.count == 2
    })
    #expect(await provider.requestCount(for: channelID) == 3)
    #expect(await provider.earlierRequestCount() == 2)
}

@MainActor
@Test func `gateway mutations keep exact indexes after repeated history prepends`() async throws {
    let provider = MockChatProvider(timelineMessageCount: 500)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    #expect(model.selectedChannelID == ChannelID(rawValue: 210))
    let initialCount = model.messages.count
    for _ in 0 ..< 5 {
        await model.loadEarlier()
    }
    #expect(model.messages.count == min(500, initialCount + 250))

    let updateTarget = model.messages[173]
    var updated = updateTarget
    updated.content = "Updated after five prepended pages"
    await provider.emit(.messageUpdated(updated))

    #expect(await eventuallyOnMain {
        model.messages.first(where: { $0.id == updateTarget.id })?.content
            == updated.content
    })

    let deleted = model.messages[211]
    await provider.emit(.messageDeleted(
        channelID: deleted.channelID,
        messageID: deleted.id
    ))
    #expect(await eventuallyOnMain {
        !model.messages.contains(where: { $0.id == deleted.id })
    })
}

@MainActor
@Test func `failed earlier thread page retries inside the shared conversation`() async throws {
    let provider = ChannelLoadTestProvider(failsFirstEarlierPage: true)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let parentID = try #require(model.selectedChannelID)
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 91_099),
        parentID: parentID,
        name: "Pagination retry"
    )

    model.open(thread)
    #expect(await eventuallyOnMain {
        model.hasCompletedInitialThreadLoad
            && model.hasMoreThreadMessages
            && model.threadMessages.count == 1
    })

    await model.loadEarlierThread()
    #expect(model.threadErrorMessage != nil)
    #expect(model.canRetryThreadLoad)
    #expect(model.hasMoreThreadMessages)

    model.retryThreadLoad()

    #expect(await eventuallyOnMain {
        model.threadErrorMessage == nil
            && !model.isLoadingEarlierThread
            && !model.hasMoreThreadMessages
            && model.threadMessages.count == 2
    })
    #expect(await provider.requestCount(for: thread.id) == 3)
}

@MainActor
@Test func `reaction preview enrichment waits for live timeline scrolling to end`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let message = try #require(model.messages.first)
    let reaction = try #require(message.reactions.first)
    let primaryID = message.channelID
    let supplementaryID = ChannelID(rawValue: 910_002)
    model.reportTimelineLiveScrolling(
        true,
        conversationID: primaryID
    )
    model.reportTimelineLiveScrolling(
        true,
        conversationID: supplementaryID
    )
    let load = Task {
        await model.loadReactionReactors(reaction, on: message)
    }
    try await Task.sleep(for: .milliseconds(80))

    #expect(await provider.reactorRequestCount() == 0)
    #expect(model.messages.first?.reactions.first?.reactors.isEmpty == true)

    model.reportTimelineLiveScrolling(
        false,
        conversationID: primaryID
    )
    try await Task.sleep(for: .milliseconds(80))

    #expect(await provider.reactorRequestCount() == 0)
    #expect(model.messages.first?.reactions.first?.reactors.isEmpty == true)

    model.reportTimelineLiveScrolling(
        false,
        conversationID: supplementaryID
    )
    await load.value

    #expect(await provider.reactorRequestCount() == 1)
    #expect(model.messages.first?.reactions.first?.reactors.count == 5)
}

@MainActor
@Test func `visible reaction preview reads stay within the app request budget`() async {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    await withTaskGroup(of: Void.self) { group in
        for value in 0 ..< 12 {
            let message = Message(
                id: MessageID(rawValue: UInt64(92000 + value)),
                channelID: ChannelID(rawValue: 91001),
                author: User(
                    id: UserID(rawValue: 91000),
                    username: "tester",
                    displayName: "Tester"
                ),
                content: "reaction \(value)",
                reactions: [Reaction(emoji: "emoji-\(value)", count: 1)]
            )
            group.addTask {
                await model.loadReactionReactors(message.reactions[0], on: message)
            }
        }
    }

    #expect(await provider.reactorRequestCount() == 12)
    #expect(
        await provider.maximumConcurrentReactorRequestCount()
            <= AppModel.maximumConcurrentReactionReactorLoads
    )
}

@MainActor
@Test func `voice server reallocation keeps the call selected and reconnects`() async throws {
    let provider = VoiceMigrationTestProvider()
    let sounds = RecordingAppSoundPlayer()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        soundPlayer: sounds
    )
    await model.start()
    let voiceChannel = try #require(model.visibleChannels.first)

    await model.joinVoice(voiceChannel)
    #expect(model.activeVoiceChannel?.id == voiceChannel.id)
    #expect(model.voiceSessionState == .connected)
    #expect(sounds.played == [.userJoin])

    await provider.emit(.voiceServerChanged(nil))
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.activeVoiceChannel?.id == voiceChannel.id)
    #expect(model.voiceSessionState == .reconnecting)

    await provider.emit(.voiceServerChanged(provider.connectionInfo(token: "replacement")))
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.activeVoiceChannel?.id == voiceChannel.id)
    #expect(model.voiceSessionState == .connected)
    #expect(sounds.played == [.userJoin])

    await model.leaveVoice()
    #expect(sounds.played == [.userJoin, .disconnect])
}

@MainActor
@Test func `private calls remain app wide and reconcile incoming ongoing and deleted state`() async throws {
    let provider = VoiceMigrationTestProvider()
    let sounds = RecordingAppSoundPlayer()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        soundPlayer: sounds
    )
    await model.start()
    let currentUserID = try #require(model.snapshot?.currentUser.id)
    let channelID = ChannelID(rawValue: 88_800)
    let senderID = UserID(rawValue: 88_801)

    await provider.emit(
        .privateCallChanged(
            PrivateCall(
                channelID: channelID,
                messageID: MessageID(rawValue: 88_802),
                region: "rotterdam",
                ongoingRings: [
                    PrivateCallRing(
                        recipientID: currentUserID,
                        senderID: senderID
                    )
                ],
                voiceStates: []
            )
        )
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.incomingPrivateCalls.map(\.channelID) == [channelID])
    #expect(model.privateCall(in: channelID)?.isRinging(currentUserID) == true)
    #expect(sounds.looping[.callRinging] == true)

    await provider.emit(
        .privateCallChanged(
            PrivateCall(
                channelID: channelID,
                messageID: MessageID(rawValue: 88_802),
                region: "rotterdam",
                ongoingRings: [],
                voiceStates: [
                    VoiceParticipantState(
                        userID: senderID,
                        channelID: channelID,
                        guildID: nil,
                        sessionID: "private-session"
                    )
                ]
            )
        )
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.incomingPrivateCalls.isEmpty)
    #expect(model.privateCall(in: channelID)?.voiceStates?.map(\.userID) == [senderID])
    #expect(sounds.looping[.callRinging] == false)

    await provider.emit(.privateCallDeleted(channelID: channelID, unavailable: false))
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.privateCall(in: channelID) == nil)
    #expect(sounds.looping[.callRinging] == false)
}

private struct ReactionMutationRequest: Equatable, Sendable {
    var messageID: MessageID
    var emoji: String
    var reacted: Bool
}

private actor ReactionMutationTestProvider: ChatProvider {
    private let user = User(
        id: UserID(rawValue: 98_001),
        username: "reaction-tester",
        displayName: "Reaction Tester"
    )
    private let channel = Channel(
        id: ChannelID(rawValue: 98_002),
        guildID: nil,
        name: "reaction-tests"
    )
    private let requestDelay: Duration
    private let failingEmoji: String?
    private let initialReaction: Reaction?
    private var recordedRequests: [ReactionMutationRequest] = []
    private var continuation: AsyncStream<ClientEvent>.Continuation?

    init(
        requestDelay: Duration = .zero,
        failingEmoji: String? = nil,
        initialReaction: Reaction? = nil
    ) {
        self.requestDelay = requestDelay
        self.failingEmoji = failingEmoji
        self.initialReaction = initialReaction
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(currentUser: user, guilds: [], channels: [channel], members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        [channel]
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(
            messages: [
                Message(
                    id: MessageID(rawValue: 98_100),
                    channelID: channel.id,
                    author: user,
                    content: "First",
                    reactions: initialReaction.map { [$0] } ?? []
                ),
                Message(
                    id: MessageID(rawValue: 98_101),
                    channelID: channel.id,
                    author: user,
                    content: "Second"
                ),
            ],
            hasMoreBefore: false
        )
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}

    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}

    func setReaction(
        _ emoji: String,
        reacted: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        recordedRequests.append(
            ReactionMutationRequest(messageID: messageID, emoji: emoji, reacted: reacted)
        )
        if requestDelay > .zero {
            try await Task.sleep(for: requestDelay)
        }
        if failingEmoji == emoji {
            throw ChatProviderError.invalidRequest("Synthetic reaction failure.")
        }
    }

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { continuation = $0 }
    }

    func disconnect() async {
        continuation?.finish()
        continuation = nil
    }

    func requests() -> [ReactionMutationRequest] {
        recordedRequests
    }

    func emit(_ event: ClientEvent) {
        continuation?.yield(event)
    }
}

private actor ChannelLoadTestProvider: ChatProvider {
    private let user = User(id: UserID(rawValue: 91000), username: "tester", displayName: "Tester")
    private let testChannels = [
        Channel(id: ChannelID(rawValue: 91001), guildID: nil, name: "general"),
        Channel(id: ChannelID(rawValue: 91002), guildID: nil, name: "other"),
        Channel(
            id: ChannelID(rawValue: 91003),
            guildID: nil,
            name: "Voice Room",
            kind: .voice
        ),
    ]
    private var messageRequests: [ChannelID: Int] = [:]
    private var reactorRequests = 0
    private var activeReactorRequests = 0
    private var maximumActiveReactorRequests = 0
    private let failsFirstEarlierPage: Bool
    private var earlierRequests = 0

    init(failsFirstEarlierPage: Bool = false) {
        self.failsFirstEarlierPage = failsFirstEarlierPage
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(currentUser: user, guilds: [], channels: testChannels, members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        testChannels
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        messageRequests[channelID, default: 0] += 1
        if failsFirstEarlierPage, before != nil {
            earlierRequests += 1
            if earlierRequests == 1 {
                throw ChatProviderError.invalidRequest(
                    "Synthetic earlier-page timeout."
                )
            }
            return MessagePage(
                messages: [
                    Message(
                        id: MessageID(rawValue: channelID.rawValue - 1),
                        channelID: channelID,
                        author: user,
                        content: "earlier"
                    )
                ],
                hasMoreBefore: false
            )
        }
        // Intentionally ignore cancellation to prove the model's generation guard works.
        let delay: Duration =
            channelID == testChannels[1].id ? .milliseconds(100) : .milliseconds(20)
        try? await Task.sleep(for: delay)
        let message = Message(
            id: MessageID(rawValue: channelID.rawValue),
            channelID: channelID,
            author: user,
            content: "channel \(channelID)",
            reactions: [Reaction(emoji: "🔥", count: 8)]
        )
        return MessagePage(
            messages: [message],
            hasMoreBefore: failsFirstEarlierPage
        )
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        reactorRequests += 1
        activeReactorRequests += 1
        maximumActiveReactorRequests = max(
            maximumActiveReactorRequests,
            activeReactorRequests
        )
        defer { activeReactorRequests -= 1 }
        try await Task.sleep(for: .milliseconds(25))
        return (1 ... 5).map {
            ReactionReactor(
                id: UserID(rawValue: UInt64($0)),
                displayName: ["One", "Two", "Three", "Four", "Five"][$0 - 1]
            )
        }
    }
    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}

    func requestCount(for channelID: ChannelID) -> Int {
        messageRequests[channelID, default: 0]
    }

    func earlierRequestCount() -> Int {
        earlierRequests
    }

    func reactorRequestCount() -> Int {
        reactorRequests
    }

    func maximumConcurrentReactorRequestCount() -> Int {
        maximumActiveReactorRequests
    }
}

private actor StartupUnreadTestProvider: ChatProvider {
    private let guild = Guild(id: GuildID(rawValue: 77_000), name: "Startup Guild")
    private let user = User(
        id: UserID(rawValue: 77_001),
        username: "startup-tester",
        displayName: "Startup Tester"
    )
    private let channel = Channel(
        id: ChannelID(rawValue: 77_002),
        guildID: GuildID(rawValue: 77_000),
        name: "general",
        lastMessageID: MessageID(rawValue: 77_200)
    )

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [guild],
            guildRailItems: [
                .folder(
                    GuildFolder(id: 77, name: "Startup", guildIDs: [guild.id])
                )
            ],
            channels: [channel],
            members: [],
            readStates: [
                ChannelReadState(
                    channelID: channel.id,
                    lastAcknowledgedMessageID: MessageID(rawValue: 77_100),
                    mentionCount: 2
                )
            ]
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        guildID == guild.id ? [channel] : []
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {
        throw ChatProviderError.invalidRequest("Deleting is not part of this test.")
    }

    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {
        throw ChatProviderError.invalidRequest("Reactions are not part of this test.")
    }

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}
}

private actor ForumVisitAcknowledgementTestProvider: ChatProvider {
    struct Acknowledgement: Sendable {
        var channelID: ChannelID
        var messageID: MessageID
    }

    nonisolated let forumID = ChannelID(rawValue: 96_002)
    nonisolated let newPostID = ChannelID(rawValue: 96_300)
    nonisolated let unreadPostID = ChannelID(rawValue: 96_240)
    private let guild = Guild(id: GuildID(rawValue: 96_000), name: "Forum Visits")
    private let user = User(
        id: UserID(rawValue: 96_001),
        username: "forum-visitor",
        displayName: "Forum Visitor"
    )
    private var recordedAcknowledgements: [Acknowledgement] = []

    private var forum: Channel {
        Channel(
            id: forumID,
            guildID: guild.id,
            name: "forum",
            kind: .forum,
            lastMessageID: MessageID(rawValue: newPostID.rawValue)
        )
    }

    private var posts: [ForumPost] {
        [
            ForumPost(
                thread: MessageThreadSummary(
                    id: newPostID,
                    guildID: guild.id,
                    parentID: forumID,
                    name: "Brand new",
                    lastMessageID: MessageID(rawValue: newPostID.rawValue)
                )
            ),
            ForumPost(
                thread: MessageThreadSummary(
                    id: unreadPostID,
                    guildID: guild.id,
                    parentID: forumID,
                    name: "Unread replies",
                    lastMessageID: MessageID(rawValue: 96_500)
                ),
                isUnread: true
            ),
        ]
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [guild],
            channels: [forum],
            members: [],
            readStates: [
                ChannelReadState(
                    channelID: forumID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 96_250)
                ),
                ChannelReadState(
                    channelID: unreadPostID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 96_450)
                ),
            ]
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        guildID == guild.id ? [forum] : []
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        guard channelID == forumID else { throw ChatProviderError.channelNotFound }
        return ForumPostPage(posts: posts, hasMore: false, nextOffset: nil)
    }

    func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?
    ) async throws -> ReadAcknowledgementResponse {
        recordedAcknowledgements.append(
            Acknowledgement(channelID: channelID, messageID: messageID)
        )
        return ReadAcknowledgementResponse(token: token)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}

    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}

    func acknowledgements() -> [Acknowledgement] {
        recordedAcknowledgements
    }
}

private actor ForumPaginationTestProvider: ChatProvider {
    private let guild = Guild(id: GuildID(rawValue: 95_000), name: "Forum Test")
    private let user = User(
        id: UserID(rawValue: 95_001),
        username: "forum-tester",
        displayName: "Forum Tester"
    )
    private let channel = Channel(
        id: ChannelID(rawValue: 95_002),
        guildID: GuildID(rawValue: 95_000),
        name: "forum",
        kind: .forum
    )
    private var paginationRequests = 0

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [guild],
            channels: [channel],
            members: []
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        guildID == guild.id ? [channel] : []
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        guard channelID == channel.id else { throw ChatProviderError.channelNotFound }
        if query.offset == 0 {
            return ForumPostPage(
                posts: [
                    ForumPost(
                        thread: MessageThreadSummary(
                            id: ChannelID(rawValue: 95_010),
                            guildID: guild.id,
                            parentID: channel.id,
                            name: "Recent post",
                            createdAt: Date(timeIntervalSince1970: 200)
                        )
                    )
                ],
                hasMore: true,
                nextOffset: 1
            )
        }

        paginationRequests += 1
        if paginationRequests == 1 {
            throw ChatProviderError.invalidRequest("Older posts are temporarily unavailable.")
        }
        return ForumPostPage(
            posts: [
                ForumPost(
                    thread: MessageThreadSummary(
                        id: ChannelID(rawValue: 95_011),
                        guildID: guild.id,
                        parentID: channel.id,
                        name: "Older post",
                        isArchived: true,
                        archiveTimestamp: Date(timeIntervalSince1970: 100),
                        createdAt: Date(timeIntervalSince1970: 100)
                    )
                )
            ],
            hasMore: false,
            nextOffset: nil
        )
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}

    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}

    func paginationRequestCount() -> Int {
        paginationRequests
    }
}

private actor LinkedChannelNavigationTestProvider: ChatProvider {
    private let firstGuild = Guild(id: GuildID(rawValue: 94_000), name: "First")
    private let secondGuild = Guild(id: GuildID(rawValue: 94_100), name: "Second")
    private let user = User(
        id: UserID(rawValue: 94_200),
        username: "navigator",
        displayName: "Navigator"
    )
    private let firstChannel = Channel(
        id: ChannelID(rawValue: 94_001),
        guildID: GuildID(rawValue: 94_000),
        name: "general"
    )
    let targetChannel = Channel(
        id: ChannelID(rawValue: 94_101),
        guildID: GuildID(rawValue: 94_100),
        name: "linked-channel"
    )
    private var forumPostRequests = 0

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [firstGuild, secondGuild],
            channels: [],
            members: []
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        switch guildID {
        case firstGuild.id: [firstChannel]
        case secondGuild.id: [targetChannel]
        default: []
        }
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func forumPost(threadID: ChannelID) async throws -> ForumPost {
        forumPostRequests += 1
        throw ChatProviderError.invalidRequest("Ordinary channels are not forum posts.")
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}

    func forumPostRequestCount() -> Int {
        forumPostRequests
    }
}

private actor SuspendedBootstrapTestProvider: ChatProvider {
    private let user = User(id: UserID(rawValue: 93000), username: "tester", displayName: "Tester")
    private let channel = Channel(id: ChannelID(rawValue: 93001), guildID: nil, name: "general")
    private var bootstrapStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var bootstrapContinuation: CheckedContinuation<Void, Never>?
    private let bootstrapError: String?

    init(bootstrapError: String? = nil) {
        self.bootstrapError = bootstrapError
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        bootstrapStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { bootstrapContinuation = $0 }
        if let bootstrapError {
            throw ChatProviderError.invalidRequest(bootstrapError)
        }
        return BootstrapSnapshot(currentUser: user, guilds: [], channels: [channel], members: [])
    }

    func waitUntilBootstrapStarts() async {
        if bootstrapStarted {
            return
        }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBootstrap() {
        bootstrapContinuation?.resume()
        bootstrapContinuation = nil
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        [channel]
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}
}

@MainActor
private final class PermissionRecordingNotificationService: NativeNotificationService {
    private(set) var authorizationRequestCount = 0
    private var status: UNAuthorizationStatus = .notDetermined

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        status = .authorized
        return true
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func deliver(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        preferences: NotificationPreferences
    ) async {}

    func cancel(accountID: String, channelID: ChannelID) async {}

    func setDockBadge(_ count: Int, enabled: Bool) {}
}

private actor VoiceMigrationTestProvider: ChatProvider {
    private let guild = Guild(id: GuildID(rawValue: 92000), name: "Voice Test")
    private let user = User(id: UserID(rawValue: 92001), username: "tester", displayName: "Tester")
    private let channel = Channel(
        id: ChannelID(rawValue: 92002),
        guildID: GuildID(rawValue: 92000),
        name: "Lounge",
        kind: .voice
    )
    private var continuation: AsyncStream<ClientEvent>.Continuation?

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(currentUser: user, guilds: [guild], channels: [channel], members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        [channel]
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        connectionInfo(token: "initial")
    }

    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { continuation = $0 }
    }

    func disconnect() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ event: ClientEvent) {
        continuation?.yield(event)
    }

    func connectionInfo(token: String) -> VoiceConnectionInfo {
        VoiceConnectionInfo(
            serverID: guild.id.description,
            channelID: channel.id,
            guildID: guild.id,
            userID: user.id,
            sessionID: "session",
            token: token,
            endpoint: "mock.sakuracord.invalid"
        )
    }
}
