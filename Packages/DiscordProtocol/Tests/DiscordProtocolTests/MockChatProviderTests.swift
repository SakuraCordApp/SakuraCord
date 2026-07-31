import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Test func `offline incoming private call fixture is app wide`() async throws {
    let provider = MockChatProvider(includesIncomingPrivateCall: true)
    let stream = await provider.eventStream()
    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())

    guard case .privateCallChanged(let call) = event else {
        Issue.record("Expected the seeded private call to be the first app-wide event")
        return
    }
    #expect(call.channelID == ChannelID(rawValue: 400))
    #expect(call.ongoingRings == [
        PrivateCallRing(
            recipientID: UserID(rawValue: 1),
            senderID: UserID(rawValue: 2)
        )
    ])
}

@Test func `forum channel metadata decodes official field names`() throws {
    let data = Data(
        #"""
        {
          "id":"220","guild_id":"100","name":"feedback","type":15,"flags":16,
          "available_tags":[
            {"id":"8001","name":"Visual","moderated":false,"emoji_name":"🖌️"},
            {"id":"8003","name":"Critical","moderated":true,"emoji_name":"❗"}
          ],
          "default_reaction_emoji":{"emoji_id":null,"emoji_name":"👍"},
          "default_sort_order":0,"default_forum_layout":1,"default_tag_setting":"match_all",
          "default_auto_archive_duration":4320,"default_thread_rate_limit_per_user":15
        }
        """#.utf8)
    let channel = try JSONDecoder().decode(ChannelDTO.self, from: data).domain(guildID: nil)
    #expect(channel.kind == .forum)
    #expect(channel.requiresForumTag)
    #expect(channel.availableTags.count == 2)
    #expect(channel.availableTags.last?.isModerated == true)
    #expect(channel.defaultReaction?.emojiName == "👍")
    #expect(channel.defaultSortOrder == .latestActivity)
    #expect(channel.defaultForumLayout == .list)
    #expect(channel.defaultTagMatch == .matchAll)
    #expect(channel.defaultAutoArchiveDuration == 4_320)
}

@Test func `offline forum supports browsing creation filtering and moderation`() async throws {
    let provider = MockChatProvider()
    _ = try await provider.bootstrap()
    let channelID = ChannelID(rawValue: 220)
    let visualID = ForumTagID(rawValue: 8_001)

    let initial = try await provider.forumPosts(
        in: channelID,
        query: ForumPostQuery(limit: 25)
    )
    #expect(initial.posts.count == 6)
    #expect(initial.posts.first?.thread.isPinned == true)
    #expect(initial.posts.contains { $0.isUnread })
    #expect(initial.posts.contains { $0.thread.isLocked && !$0.thread.isArchived })
    #expect(initial.posts.contains { $0.thread.isArchived && !$0.thread.isLocked })

    let filtered = try await provider.forumPosts(
        in: channelID,
        query: ForumPostQuery(selectedTagIDs: [visualID], tagMatch: .matchAll, limit: 25)
    )
    #expect(!filtered.posts.isEmpty)
    #expect(filtered.posts.allSatisfy { $0.thread.appliedTagIDs.contains(visualID) })

    let created = try await provider.createForumPost(
        CreateForumPostDraft(
            channelID: channelID,
            title: "Offline forum contract",
            content: "This post never leaves the deterministic fixture.",
            appliedTagIDs: [visualID]
        ),
        progress: { _ in }
    )
    #expect(created.thread.parentID == channelID)
    #expect(created.firstMessage?.content.contains("never leaves") == true)
    #expect(try await provider.messages(in: created.id, before: nil, limit: 25).messages.count == 1)
    await #expect(throws: ChatProviderError.self) {
        try await provider.updateForumPost(created, mutation: .tags([]))
    }

    let closed = try await provider.updateForumPost(created, mutation: .archived(true))
    #expect(closed.thread.isArchived)
    let reopened = try await provider.updateForumPost(closed, mutation: .archived(false))
    #expect(!reopened.thread.isArchived)
    let locked = try await provider.updateForumPost(reopened, mutation: .locked(true))
    #expect(locked.thread.isLocked)
    let pinned = try await provider.updateForumPost(locked, mutation: .pinned(true))
    #expect(pinned.thread.isPinned)

    let refreshed = try await provider.forumPosts(
        in: channelID,
        query: ForumPostQuery(limit: 25)
    )
    #expect(refreshed.posts.contains(where: { $0.id == pinned.id }))
}

@Test func `mock fixture is synthetic rich and available offline`() async throws {
    let provider = MockChatProvider()
    let snapshot = try await provider.bootstrap()

    try await verifyGuildFixtures(provider: provider, snapshot: snapshot)
    try await verifyMemberFixtures(provider: provider)
    try await verifyChannelFixtures(provider: provider, snapshot: snapshot)
    try await verifyShowcaseFixtures(provider: provider, snapshot: snapshot)
}

private func verifyGuildFixtures(
    provider: MockChatProvider,
    snapshot: BootstrapSnapshot
) async throws {
    #expect(snapshot.currentUser.displayName == "Nova Chen")
    #expect(snapshot.guilds.count == 2)
    #expect(snapshot.guilds.allSatisfy { $0.iconURL?.isFileURL == true })
    #expect(snapshot.guilds.allSatisfy { guild in
        guild.iconURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
    })
    for guild in snapshot.guilds {
        let emojis = try await provider.emojis(in: guild.id)
        #expect(!emojis.isEmpty)
        #expect(emojis.allSatisfy { $0.guildID == guild.id })
        #expect(emojis.allSatisfy { $0.imageURL?.isFileURL == true })
        #expect(emojis.allSatisfy { emoji in
            emoji.imageURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        })
    }
}

private func verifyMemberFixtures(provider: MockChatProvider) async throws {
    let guildID = GuildID(rawValue: 100)
    let members = try await provider.members(in: guildID)
    #expect(members.count == 5)
    let searchedMembers = try await provider.searchMembers(
        in: guildID, query: "maya", limit: 25
    )
    #expect(searchedMembers.map(\.user.displayName) == ["Maya • Orbit"])
    #expect(members.allSatisfy { $0.user.avatarURL?.isFileURL == true })
    for member in members {
        let profile = try await provider.profile(for: member.user.id, in: guildID)
        #expect(profile.bio?.isEmpty == false)
        #expect(profile.pronouns?.isEmpty == false)
        #expect(!profile.roles.isEmpty)
    }
}

private func verifyChannelFixtures(
    provider: MockChatProvider,
    snapshot: BootstrapSnapshot
) async throws {
    for rawChannelID: UInt64 in [200, 210, 211, 212, 300, 301, 302, 400, 401] {
        let channelID = ChannelID(rawValue: rawChannelID)
        let page = try await provider.messages(in: channelID, before: nil, limit: 50)
        #expect(!page.messages.isEmpty)
    }
    let groupDM = try #require(snapshot.channels.first {
        $0.id == ChannelID(rawValue: 401)
    })
    #expect(groupDM.kind == .groupDirectMessage)
    #expect(groupDM.recipients.map(\.id) == [
        UserID(rawValue: 2),
        UserID(rawValue: 3),
        UserID(rawValue: 4),
    ])
    let threadID = ChannelID(rawValue: 901)
    let threadPage = try await provider.messages(in: threadID, before: nil, limit: 50)
    #expect(
        threadPage.messages.map(\.id) == [MessageID(rawValue: 9011), MessageID(rawValue: 9012)]
    )
    #expect(threadPage.messages.allSatisfy { $0.channelID == threadID })
}

private func verifyShowcaseFixtures(
    provider: MockChatProvider,
    snapshot: BootstrapSnapshot
) async throws {
    let showcase = try await provider.messages(
        in: ChannelID(rawValue: 301),
        before: nil,
        limit: 50
    )
    let spoilerFixture = try #require(showcase.messages.first {
        $0.id == MessageID(rawValue: 3105)
    })
    #expect(spoilerFixture.attachments.first?.isSpoiler == true)
    #expect(spoilerFixture.components.contains {
        guard case let .container(_, _, spoiler, _) = $0 else { return false }
        return spoiler
    })
    let independentSpoilers = try #require(showcase.messages.first {
        $0.id == MessageID(rawValue: 3106)
    })
    #expect(independentSpoilers.attachments.count == 4)
    #expect(independentSpoilers.attachments.allSatisfy { $0.isSpoiler })
    #expect(
        Set(independentSpoilers.attachments.map(\.mediaKind))
            == [.image, .animatedImage, .video, .file]
    )
    #expect(independentSpoilers.components.contains {
        guard case let .mediaGallery(_, items) = $0 else { return false }
        return items.count == 2 && items.allSatisfy { $0.media.isSpoiler }
    })
    #expect(independentSpoilers.components.contains {
        guard case let .file(_, media) = $0 else { return false }
        return media.isSpoiler
    })
    try verifyAnimatedAndCommandFixtures(
        messages: showcase.messages,
        currentUserID: snapshot.currentUser.id
    )
    let animatedEmoji = try #require(
        try await provider.emojis(in: GuildID(rawValue: 101)).first {
            $0.id == "900000000000000203"
        }
    )
    #expect(animatedEmoji.assetURL?.isFileURL == true)
    #expect(animatedEmoji.assetURL?.pathExtension == "gif")
}

private func verifyAnimatedAndCommandFixtures(
    messages: [Message],
    currentUserID: UserID
) throws {
    let animatedFixture = try #require(messages.first {
        $0.id == MessageID(rawValue: 3107)
    })
    #expect(animatedFixture.content.contains("<a:animated_fixture:900000000000000203>"))
    #expect(animatedFixture.reactions.first?.emojiReference.isAnimated == true)
    let commandFixture = try #require(messages.first { $0.id == MessageID(rawValue: 3108) })
    #expect(commandFixture.type == .chatInputCommand)
    #expect(commandFixture.flags.contains(.ephemeral))
    #expect(commandFixture.interactionMetadata?.displayName == "inspect")
    #expect(commandFixture.interactionMetadata?.user?.id == currentUserID)
    let systemFixture = try #require(messages.first { $0.id == MessageID(rawValue: 3109) })
    #expect(systemFixture.type == .channelPinnedMessage)
    #expect(systemFixture.type.hasGeneratedContent)
    let loadingFixture = try #require(messages.first { $0.id == MessageID(rawValue: 3110) })
    #expect(loadingFixture.type == .chatInputCommand)
    #expect(loadingFixture.flags.contains(.loading))
    #expect(loadingFixture.interactionMetadata?.displayName == "compare")
    let replyMentionFixture = try #require(messages.first { $0.id == MessageID(rawValue: 3113) })
    #expect(replyMentionFixture.replyTo == MessageID(rawValue: 3112))
    #expect(replyMentionFixture.mentionedUsers.contains { $0.id == currentUserID })
    let suppressedEmbedFixture = try #require(messages.first { $0.id == MessageID(rawValue: 3114) })
    #expect(suppressedEmbedFixture.flags.contains(.suppressEmbeds))
    #expect(suppressedEmbedFixture.embeds.count == 1)
    #expect(suppressedEmbedFixture.content == "https://example.com/suppressed-preview")
    let failedFixture = try #require(messages.first { $0.id == MessageID(rawValue: 3111) })
    #expect(failedFixture.outboxState == .failed)
}

@Test func `mock long server list fixture provides scrollable guild and emoji rails`() async throws
{
    let provider = MockChatProvider(includesLongServerList: true)
    let snapshot = try await provider.bootstrap()

    #expect(snapshot.guilds.count == 20)
    let lastGuild = try #require(snapshot.guilds.last)
    #expect(lastGuild.name == "Scroll Test 18")
    #expect(lastGuild.iconURL == nil)
    #expect(snapshot.guildRailItems.count == 11)
    #expect(
        snapshot.guildRailItems.compactMap { item -> GuildFolder? in
            guard case .folder(let folder) = item else { return nil }
            return folder
        }.map(\.name) == ["Native Projects", "Communities"])

    let channels = try await provider.channels(in: lastGuild.id)
    let channel = try #require(channels.first)
    #expect(channel.name == "general")
    #expect(try await !(provider.messages(in: channel.id, before: nil, limit: 50)).messages.isEmpty)
    #expect(try await (provider.members(in: lastGuild.id)).count == 2)
}

@Test func `mock timeline stress emits deterministic live message bursts`() async throws {
    let provider = MockChatProvider(timelineMessageCount: 120)
    _ = try await provider.bootstrap()
    let channelID = ChannelID(rawValue: 210)
    let stream = await provider.eventStream()
    let collector = Task { () -> [Message] in
        var messages: [Message] = []
        for await event in stream {
            guard case let .messageCreated(message) = event,
                  message.channelID == channelID
            else { continue }
            messages.append(message)
            if messages.count == 12 {
                return messages
            }
        }
        return messages
    }

    await provider.emitTimelineStressMessages(
        in: channelID,
        count: 12,
        burstSize: 4,
        burstInterval: .milliseconds(1)
    )
    let emitted = await collector.value
    let page = try await provider.messages(in: channelID, before: nil, limit: 20)
    await provider.disconnect()

    #expect(emitted.count == 12)
    #expect(emitted.map(\.id) == emitted.map(\.id).sorted())
    #expect(Set(emitted.map(\.id)).count == 12)
    #expect(Array(page.messages.suffix(12)).map(\.id) == emitted.map(\.id))
    #expect(emitted.allSatisfy { !$0.content.isEmpty && $0.channelID == channelID })
}

@Test func `mock timeline mutation stress emits deterministic updates and deletes`() async throws {
    enum MutationEvent: Equatable {
        case updated(MessageID, String)
        case deleted(MessageID)
    }

    let provider = MockChatProvider(timelineMessageCount: 120)
    _ = try await provider.bootstrap()
    let channelID = ChannelID(rawValue: 210)
    let stream = await provider.eventStream()
    let collector = Task { () -> [MutationEvent] in
        var events: [MutationEvent] = []
        for await event in stream {
            switch event {
            case let .messageUpdated(message)
            where message.channelID == channelID:
                events.append(.updated(message.id, message.content))
            case let .messageDeleted(eventChannelID, messageID)
            where eventChannelID == channelID:
                events.append(.deleted(messageID))
            default:
                continue
            }
            if events.count == 12 {
                return events
            }
        }
        return events
    }

    await provider.emitTimelineMutationStress(
        in: channelID,
        operationCount: 12,
        deleteEvery: 4,
        lookback: 24,
        initialDelay: .zero,
        operationInterval: .milliseconds(1)
    )
    let events = await collector.value
    let page = try await provider.messages(
        in: channelID,
        before: nil,
        limit: 200
    )
    await provider.disconnect()

    #expect(events.count == 12)
    #expect(events.filter {
        if case .deleted = $0 { true } else { false }
    }.count == 3)
    #expect(events.filter {
        if case .updated = $0 { true } else { false }
    }.count == 9)
    let deletedIDs = Set(events.compactMap { event -> MessageID? in
        guard case let .deleted(messageID) = event else { return nil }
        return messageID
    })
    let finalUpdatedContent = Dictionary(
        events.compactMap { event -> (MessageID, String)? in
            guard case let .updated(messageID, content) = event else {
                return nil
            }
            return (messageID, content)
        },
        uniquingKeysWith: { _, newer in newer }
    )
    for event in events {
        switch event {
        case let .updated(messageID, content):
            #expect(content.contains("stress"))
            if !deletedIDs.contains(messageID),
               finalUpdatedContent[messageID] == content
            {
                #expect(page.messages.contains {
                    $0.id == messageID && $0.content == content
                })
            }
        case let .deleted(messageID):
            #expect(!page.messages.contains { $0.id == messageID })
        }
    }
}

@Test func `media timeline fixture uses bundled video lottie and animated raster rows`() async throws {
    let provider = MockChatProvider(
        timelineMessageCount: 120,
        timelineIncludesAnimatedMedia: true
    )
    _ = try await provider.bootstrap()
    let page = try await provider.messages(
        in: ChannelID(rawValue: 210),
        before: nil,
        limit: 120
    )

    let videos = page.messages.flatMap(\.embeds).compactMap(\.video)
        .filter { $0.contentType == "video/mp4" }
    let lottieStickers = page.messages.flatMap(\.stickers)
        .filter { $0.format == .lottie }

    #expect(!videos.isEmpty)
    #expect(videos.allSatisfy { $0.url?.isFileURL == true })
    #expect(!lottieStickers.isEmpty)
    #expect(lottieStickers.allSatisfy { $0.mediaURL?.isFileURL == true })
    #expect(page.messages.contains {
        $0.content.contains("file://") && $0.content.contains(".gif")
    })
}

@Test func `mock reactions provide local avatar fixtures and reconcile the current reactor`()
    async throws
{
    let provider = MockChatProvider()
    let snapshot = try await provider.bootstrap()
    let channelID = ChannelID(rawValue: 210)
    let messageID = MessageID(rawValue: 2002)
    var message = try #require(
        try await provider.messages(in: channelID, before: nil, limit: 50).messages.first {
            $0.id == messageID
        }
    )
    let reaction = try #require(message.reactions.first { $0.emoji == "😭" })
    #expect(reaction.reactors.count == 2)
    #expect(reaction.reactors.allSatisfy { $0.avatarURL?.isFileURL == true })
    #expect(reaction.didCurrentUserReact)

    let overflowing = try #require(message.reactions.first { $0.emoji == "🔥" })
    let overflowingReactors = try await provider.reactionReactors(
        for: overflowing.emoji,
        messageID: messageID,
        channelID: channelID,
        reactionCount: overflowing.count
    )
    #expect(overflowingReactors.count == 5)
    #expect(overflowingReactors.allSatisfy { $0.avatarURL?.isFileURL == true })

    try await provider.toggleReaction(reaction.emoji, messageID: messageID, channelID: channelID)
    message = try #require(
        try await provider.messages(in: channelID, before: nil, limit: 50).messages.first {
            $0.id == messageID
        }
    )
    var updated = try #require(message.reactions.first { $0.emoji == reaction.emoji })
    #expect(!updated.didCurrentUserReact)
    #expect(!updated.reactors.contains { $0.id == snapshot.currentUser.id })

    try await provider.toggleReaction(reaction.emoji, messageID: messageID, channelID: channelID)
    message = try #require(
        try await provider.messages(in: channelID, before: nil, limit: 50).messages.first {
            $0.id == messageID
        }
    )
    updated = try #require(message.reactions.first { $0.emoji == reaction.emoji })
    #expect(updated.didCurrentUserReact)
    #expect(updated.reactors.contains { $0.id == snapshot.currentUser.id })
}

@Test func `mock attachment send copies the selected file into demo storage`() async throws {
    let provider = MockChatProvider()
    _ = try await provider.bootstrap()
    let sourceDirectory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let source = sourceDirectory.appending(path: "demo-note.txt")
    let contents = Data("A fictional attachment from the SakuraCord demo.".utf8)
    try contents.write(to: source)

    let sent = try await provider.send(
        SendMessageDraft(
            channelID: ChannelID(rawValue: 210),
            content: "",
            attachmentURLs: [source],
            nonce: "demo-attachment-test"
        ))
    let attachment = try #require(sent.attachments.first)
    defer { try? FileManager.default.removeItem(at: attachment.url) }

    #expect(attachment.filename == "demo-note.txt")
    #expect(attachment.mediaType == "text/plain")
    #expect(attachment.size == contents.count)
    #expect(attachment.url != source)
    #expect(attachment.url.isFileURL)
    #expect(try Data(contentsOf: attachment.url) == contents)
}

@Test func `mock message send rejects more than ten attachments before staging`() async throws {
    let provider = MockChatProvider()
    _ = try await provider.bootstrap()
    let urls = (0 ... SendMessageDraft.maximumAttachmentCount).map {
        URL(fileURLWithPath: "/tmp/sakuracord-over-limit-\($0)")
    }

    await #expect(throws: ChatProviderError.self) {
        try await provider.send(
            SendMessageDraft(
                channelID: ChannelID(rawValue: 210),
                content: "",
                attachmentURLs: urls
            )
        )
    }
}

@Test func `message draft keeps attachment urls and metadata synchronized`() {
    let original = URL(fileURLWithPath: "/tmp/sakuracord-original.png")
    let replacement = URL(fileURLWithPath: "/tmp/sakuracord-replacement.png")
    var draft = SendMessageDraft(
        channelID: ChannelID(rawValue: 210),
        content: "",
        attachments: [
            ForumPostAttachment(
                url: original,
                filename: "renamed.png",
                description: "Alt text",
                isSpoiler: true
            )
        ]
    )

    #expect(draft.attachmentURLs == [original])
    draft.attachmentURLs = [replacement]
    #expect(draft.attachments == [ForumPostAttachment(url: replacement)])
    draft.attachments[0].filename = "replacement-name.png"
    #expect(draft.attachmentURLs == [replacement])
}

@Test func `mock slash commands cover ephemeral deferred followup and failure lifecycles`()
    async throws
{
    let provider = MockChatProvider()
    _ = try await provider.bootstrap()
    let channelID = ChannelID(rawValue: 210)
    let guildID = GuildID(rawValue: 100)
    let catalog = try await provider.applicationCommandCatalog(for: .guild(guildID))
    let responseCommands = catalog.commands.filter { $0.name == "response" }
    #expect(
        Set(responseCommands.map(\.subcommandPath.last?.name)) == [
            "normal", "ephemeral", "deferred", "followup", "failure",
        ])

    func command(_ mode: String) throws -> ApplicationCommand {
        try #require(responseCommands.first { $0.subcommandPath.last?.name == mode })
    }
    func invocation(_ mode: String) throws -> ApplicationCommandInvocation {
        ApplicationCommandInvocation(
            command: try command(mode),
            channelID: channelID,
            guildID: guildID,
            values: [],
            nonce: "offline-response-\(mode)"
        )
    }

    try await provider.executeApplicationCommand(try invocation("ephemeral")) { _ in }
    var messages = try await provider.messages(in: channelID, before: nil, limit: 100).messages
    let ephemeral = try #require(messages.first { $0.nonce == "offline-response-ephemeral" })
    #expect(ephemeral.flags.contains(.ephemeral))

    try await provider.executeApplicationCommand(try invocation("deferred")) { _ in }
    messages = try await provider.messages(in: channelID, before: nil, limit: 100).messages
    let deferred = try #require(messages.first { $0.nonce == "offline-response-deferred" })
    #expect(!deferred.flags.contains(.loading))
    #expect(deferred.editedTimestamp != nil)
    #expect(deferred.content.contains("completed successfully"))

    try await provider.executeApplicationCommand(try invocation("followup")) { _ in }
    messages = try await provider.messages(in: channelID, before: nil, limit: 100).messages
    #expect(messages.contains { $0.nonce == "offline-response-followup" })
    #expect(messages.contains { $0.content == "This is the synthetic follow-up response." })

    let events = await provider.eventStream()
    let failure = Task { () -> String? in
        for await event in events {
            if case .interaction(.failed(let nonce, let message)) = event,
               nonce == "offline-response-failure"
            {
                return message
            }
        }
        return nil
    }
    try await provider.executeApplicationCommand(try invocation("failure")) { _ in }
    #expect(await failure.value == "Synthetic interaction failure. No retry was attempted.")
    messages = try await provider.messages(in: channelID, before: nil, limit: 100).messages
    #expect(!messages.contains { $0.nonce == "offline-response-failure" })
}

@Test func `mock component choices cover every select kind with bounded filtering`()
    async throws
{
    let provider = MockChatProvider()
    _ = try await provider.bootstrap()
    let guildID = GuildID(rawValue: 100)
    let channelID = ChannelID(rawValue: 210)

    #expect(await provider.supports(.remoteComponentChoices))
    #expect(
        try await provider.componentChoices(
            kind: .string,
            query: "",
            guildID: guildID,
            channelID: channelID
        ).isEmpty
    )
    for kind in [
        ComponentSelectKind.user,
        .role,
        .mentionable,
        .channel,
    ] {
        let choices = try await provider.componentChoices(
            kind: kind,
            query: "",
            guildID: guildID,
            channelID: channelID
        )
        #expect(!choices.isEmpty)
        #expect(choices.count <= 25)
    }
    #expect(
        try await provider.componentChoices(
            kind: .role,
            query: "engineering",
            guildID: guildID,
            channelID: channelID
        ).map(\.label) == ["@Engineering"]
    )
    #expect(
        try await provider.componentChoices(
            kind: .user,
            query: "not-a-fixture-user",
            guildID: guildID,
            channelID: channelID
        ).isEmpty
    )
}
