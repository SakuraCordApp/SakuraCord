import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Test func `forum attachment edits preserve official upload metadata`() {
    let attachment = ForumPostAttachment(
        url: URL(fileURLWithPath: "/tmp/original.png"),
        filename: "renamed.png",
        description: "A pink SakuraCord flower",
        isSpoiler: true
    )

    let file = DiscordRESTProvider.forumUploadFile(attachment)
    #expect(file.name == "SPOILER_renamed.png")
    #expect(file.description == "A pink SakuraCord flower")
    #expect(
        DiscordRESTProvider.uploadedAttachmentPayload(
            id: 0,
            file: file,
            uploadFilename: "cloud-token"
        ) == .object([
            "id": .string("0"),
            "filename": .string("SPOILER_renamed.png"),
            "uploaded_filename": .string("cloud-token"),
            "description": .string("A pink SakuraCord flower"),
        ])
    )
}

@Test func `forum post deletion uses one authenticated delete channel request`() async throws {
    ForumPostDeletionURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ForumPostDeletionURLProtocol.self]
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-delete"),
        session: URLSession(configuration: configuration)
    )
    let post = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 42),
            parentID: ChannelID(rawValue: 7),
            name: "Delete me"
        )
    )

    try await provider.deleteForumPost(post)

    #expect(ForumPostDeletionURLProtocol.requestCount == 1)
    #expect(ForumPostDeletionURLProtocol.method == "DELETE")
    #expect(ForumPostDeletionURLProtocol.path == "/api/v9/channels/42")
    #expect(ForumPostDeletionURLProtocol.hadAuthorization)
    #expect(!ForumPostDeletionURLProtocol.hadBody)
}

@Test func `opening an uncached forum thread resolves it with one get channel request`() async throws {
    ForumThreadResolutionURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ForumThreadResolutionURLProtocol.self]
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-link"),
        session: URLSession(configuration: configuration)
    )

    let post = try await provider.forumPost(threadID: ChannelID(rawValue: 42))

    #expect(post.id == ChannelID(rawValue: 42))
    #expect(post.thread.parentID == ChannelID(rawValue: 7))
    #expect(post.thread.name == "Linked forum post")
    #expect(ForumThreadResolutionURLProtocol.requestCount == 1)
    #expect(ForumThreadResolutionURLProtocol.method == "GET")
    #expect(ForumThreadResolutionURLProtocol.path == "/api/v9/channels/42")
    #expect(ForumThreadResolutionURLProtocol.hadAuthorization)
    #expect(!ForumThreadResolutionURLProtocol.hadBody)
}

@Test func `thread create advances the forum parent last message boundary`() async throws {
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-thread-create")
    )
    let forum = Channel(
        id: ChannelID(rawValue: 7),
        guildID: GuildID(rawValue: 1),
        name: "forum",
        kind: .forum,
        lastMessageID: MessageID(rawValue: 100)
    )
    await provider.seedForumChannelForTesting(forum)

    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_CREATE",
        data: .object([
            "id": .string("200"),
            "guild_id": .string("1"),
            "parent_id": .string("7"),
            "name": .string("New post"),
            "type": .number(11),
            "last_message_id": .string("200"),
            "message_count": .number(1),
            "member_count": .number(1),
            "thread_metadata": .object([
                "archived": .bool(false),
                "locked": .bool(false),
            ]),
        ])
    )

    #expect(
        await provider.cachedChannelForTesting(channelID: forum.id)?.lastMessageID
            == MessageID(rawValue: 200)
    )
    await provider.disconnect()
}

@Test func `thread list sync advances the forum parent last message boundary`() async throws {
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-thread-list-sync")
    )
    let forum = Channel(
        id: ChannelID(rawValue: 7),
        guildID: GuildID(rawValue: 1),
        name: "forum",
        kind: .forum,
        lastMessageID: MessageID(rawValue: 100)
    )
    await provider.seedForumChannelForTesting(
        forum,
        currentUser: User(
            id: UserID(rawValue: 9), username: "tester", displayName: "Tester"
        )
    )

    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_LIST_SYNC",
        data: .object([
            "guild_id": .string("1"),
            "channel_ids": .array([.string("7")]),
            "threads": .array([
                .object([
                    "id": .string("250"),
                    "guild_id": .string("1"),
                    "parent_id": .string("7"),
                    "name": .string("Synced post"),
                    "type": .number(11),
                    "last_message_id": .string("250"),
                    "message_count": .number(1),
                    "member_count": .number(1),
                    "thread_metadata": .object([
                        "archived": .bool(false),
                        "locked": .bool(false),
                    ]),
                ])
            ]),
            "members": .array([
                .object([
                    "id": .string("250"),
                    "flags": .number(
                        Double(ThreadNotificationSettings.onlyMentionsFlag)
                    ),
                    "muted": .bool(true),
                    "mute_config": .object([
                        "end_time": .string("2026-07-30T20:00:00.000Z")
                    ]),
                ])
            ]),
        ])
    )

    #expect(
        await provider.cachedChannelForTesting(channelID: forum.id)?.lastMessageID
            == MessageID(rawValue: 250)
    )
    #expect(
        await provider.cachedForumPostForTesting(
            threadID: ChannelID(rawValue: 250)
        )?.thread.notificationSettings?.notificationLevel == .onlyMentions
    )
    #expect(
        await provider.cachedForumPostForTesting(
            threadID: ChannelID(rawValue: 250)
        )?.thread.notificationSettings?.isMuted == true
    )
    #expect(
        await provider.activeJoinedThreadsForTesting().map(\.id)
            == [ChannelID(rawValue: 250)]
    )

    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_MEMBER_UPDATE",
        data: .object([
            "id": .string("250"),
            "flags": .number(Double(ThreadNotificationSettings.noMessagesFlag)),
            "muted": .bool(false),
            "mute_config": .null,
        ])
    )
    #expect(
        await provider.cachedForumPostForTesting(
            threadID: ChannelID(rawValue: 250)
        )?.thread.notificationSettings?.notificationLevel == .nothing
    )
    #expect(
        await provider.cachedForumPostForTesting(
            threadID: ChannelID(rawValue: 250)
        )?.thread.notificationSettings?.isMuted == false
    )
    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_MEMBERS_UPDATE",
        data: .object([
            "id": .string("250"),
            "guild_id": .string("1"),
            "member_count": .number(0),
            "removed_member_ids": .array([.string("9")]),
        ])
    )
    #expect(await provider.activeJoinedThreadsForTesting().isEmpty)
    await provider.disconnect()
}

@Test func `joined thread snapshot preserves gateway source order`() async throws {
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-joined-thread-order")
    )
    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_LIST_SYNC",
        data: .object([
            "guild_id": .string("1"),
            "threads": .array(["300", "250"].map { id in
                .object([
                    "id": .string(id),
                    "guild_id": .string("1"),
                    "parent_id": .string("7"),
                    "name": .string("Thread \(id)"),
                    "type": .number(11),
                    "thread_metadata": .object(["archived": .bool(false)]),
                ])
            }),
            "members": .array(["300", "250"].map { id in
                .object([
                    "id": .string(id),
                    "flags": .number(0),
                    "muted": .bool(false),
                ])
            }),
        ])
    )

    #expect(await provider.activeJoinedThreadsForTesting().map(\.id) == [
        ChannelID(rawValue: 300), ChannelID(rawValue: 250),
    ])
    await provider.disconnect()
}

@Test func `forum creation sends one nested thread payload with stable tag order`() async throws {
    ForumPostCreationURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ForumPostCreationURLProtocol.self]
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-create"),
        session: URLSession(configuration: configuration)
    )
    let firstTag = ForumTag(id: ForumTagID(rawValue: 8_001), name: "First")
    let secondTag = ForumTag(id: ForumTagID(rawValue: 8_002), name: "Second")
    let channel = Channel(
        id: ChannelID(rawValue: 7),
        guildID: GuildID(rawValue: 1),
        name: "forum",
        kind: .forum,
        flags: 1 << 4,
        availableTags: [firstTag, secondTag],
        defaultAutoArchiveDuration: 4_320
    )
    await provider.seedForumChannelForTesting(channel)

    let created = try await provider.createForumPost(
        CreateForumPostDraft(
            channelID: channel.id,
            title: "Contract post",
            content: "Nested starter content",
            appliedTagIDs: [secondTag.id, firstTag.id],
            autoArchiveDuration: 4_320
        ),
        progress: { _ in }
    )

    #expect(created.thread.name == "Contract post")
    #expect(ForumPostCreationURLProtocol.requestCount == 1)
    #expect(ForumPostCreationURLProtocol.method == "POST")
    #expect(ForumPostCreationURLProtocol.path == "/api/v9/channels/7/threads")
    #expect(ForumPostCreationURLProtocol.query["use_nested_fields"] == "true")
    #expect(ForumPostCreationURLProtocol.hadAuthorization)
    let body = try #require(ForumPostCreationURLProtocol.body)
    #expect(body["name"] as? String == "Contract post")
    #expect(body["auto_archive_duration"] as? Int == 4_320)
    #expect(body["applied_tags"] as? [String] == ["8001", "8002"])
    #expect(
        (body["message"] as? [String: Any])?["content"] as? String
            == "Nested starter content"
    )
    #expect((body["message"] as? [String: Any])?["sticker_ids"] as? [String] == [])
}

@Test func `cold forum catalogue becomes visible without waiting for preview hydration`() async throws {
    ForumInitialLoadURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ForumInitialLoadURLProtocol.self]
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-initial-load"),
        session: URLSession(configuration: configuration)
    )
    let channel = Channel(
        id: ChannelID(rawValue: 7),
        guildID: GuildID(rawValue: 1),
        name: "forum",
        kind: .forum
    )
    await provider.seedForumChannelForTesting(channel)

    let clock = ContinuousClock()
    let started = clock.now
    let page = try await provider.forumPosts(
        in: channel.id,
        query: ForumPostQuery(limit: 25)
    )
    let catalogueLatency = started.duration(to: clock.now)

    #expect(page.posts.map(\.thread.name) == ["Visible immediately"])
    #expect(page.posts.first?.firstMessage == nil)
    #expect(catalogueLatency < .milliseconds(450))
    #expect(ForumInitialLoadURLProtocol.catalogueRequestCount == 1)
    #expect(ForumInitialLoadURLProtocol.previewRequestCount == 0)

    try await Task.sleep(for: .milliseconds(650))
    #expect(ForumInitialLoadURLProtocol.previewRequestCount == 1)
    await provider.disconnect()
}

@Test func `warm forum retains its cached catalogue and hydrates only returned posts`() async throws {
    ForumPageScopedPreviewURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ForumPageScopedPreviewURLProtocol.self]
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-page-scoped-preview"),
        session: URLSession(configuration: configuration)
    )
    let channel = Channel(
        id: ChannelID(rawValue: 7),
        guildID: GuildID(rawValue: 1),
        name: "forum",
        kind: .forum
    )
    let active = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 42),
            guildID: channel.guildID,
            parentID: channel.id,
            name: "Visible active post"
        )
    )
    let cachedArchived = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 43),
            guildID: channel.guildID,
            parentID: channel.id,
            name: "Cached archived post",
            isArchived: true
        )
    )
    await provider.seedForumChannelForTesting(channel, posts: [active, cachedArchived])

    let page = try await provider.forumPosts(
        in: channel.id,
        query: ForumPostQuery(limit: 25)
    )

    #expect(Set(page.posts.map(\.id)) == [active.id, cachedArchived.id])
    for _ in 0 ..< 40 where ForumPageScopedPreviewURLProtocol.previewRequestCount == 0 {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(ForumPageScopedPreviewURLProtocol.previewRequestCount == 1)
    #expect(
        Set(ForumPageScopedPreviewURLProtocol.requestedThreadIDs)
            == [active.id.description, cachedArchived.id.description]
    )
    await provider.disconnect()
}

@Test func `blank forum attachment edits fall back without extra metadata`() {
    let file = DiscordRESTProvider.forumUploadFile(
        ForumPostAttachment(
            url: URL(fileURLWithPath: "/tmp/original.png"),
            filename: "  ",
            description: "  "
        )
    )

    #expect(file.name == "original.png")
    #expect(file.description == nil)
}

@Test func `forum name search matches the official query contract`() {
    let query = ForumPostQuery(
        scope: .search("media"),
        selectedTagIDs: [ForumTagID(rawValue: 8_002), ForumTagID(rawValue: 8_001)],
        tagMatch: .matchAll,
        limit: 25
    )

    let items = DiscordRESTProvider.forumNameSearchQueryItems(
        searchText: "  media  ",
        query: query
    )
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

    #expect(
        values == [
            "name": "media",
            "tag": "8001,8002",
            "tag_setting": "match_all",
        ])
    #expect(
        items.allSatisfy {
            !["archived", "limit", "offset", "sort_by", "sort_order"].contains($0.name)
        })
}

@Test func `older forum posts use the official forum search catalogue contract`() {
    let query = ForumPostQuery(
        sortOrder: .latestActivity,
        selectedTagIDs: [ForumTagID(rawValue: 8_001)],
        tagMatch: .matchSome,
        offset: 25,
        limit: 25
    )

    let items = DiscordRESTProvider.forumCatalogueQueryItems(query: query)
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

    #expect(
        DiscordRESTProvider.forumThreadSearchPath(channelID: ChannelID(rawValue: 42))
            == "/channels/42/threads/search"
    )
    #expect(
        values == [
            "archived": "true",
            "sort_by": "last_message_time",
            "sort_order": "desc",
            "limit": "25",
            "tag": "8001",
            "tag_setting": "match_some",
            "offset": "25",
        ])
}

@Test func `forum catalogue maps date posted to creation time`() {
    let query = ForumPostQuery(sortOrder: .creationDate, tagMatch: .matchAll, limit: 100)
    let values = Dictionary(
        uniqueKeysWithValues: DiscordRESTProvider.forumCatalogueQueryItems(query: query)
            .map { ($0.name, $0.value) }
    )

    #expect(values["sort_by"] == "creation_time")
    #expect(values["tag_setting"] == "match_all")
    #expect(values["limit"] == "25")
    #expect(values["offset"] == "0")
}

@Test func `forum catalogue and name search both send tag matching`() {
    let query = ForumPostQuery(tagMatch: .matchSome, limit: 25)

    let catalogue = Dictionary(
        uniqueKeysWithValues: DiscordRESTProvider.forumCatalogueQueryItems(query: query)
            .map { ($0.name, $0.value) }
    )
    let search = Dictionary(
        uniqueKeysWithValues: DiscordRESTProvider.forumNameSearchQueryItems(
            searchText: "media",
            query: query
        ).map { ($0.name, $0.value) }
    )

    #expect(catalogue["tag"] == nil)
    #expect(catalogue["tag_setting"] == "match_some")
    #expect(catalogue["limit"] == "25")
    #expect(search["tag"] == nil)
    #expect(search["tag_setting"] == "match_some")
}

@Test func `forum mutations keep available tag order and reject unknown tags`() {
    let first = ForumTag(id: ForumTagID(rawValue: 8_001), name: "First")
    let second = ForumTag(id: ForumTagID(rawValue: 8_002), name: "Second")

    #expect(
        DiscordRESTProvider.orderedUniqueForumTagIDs(
            [second.id, first.id, second.id],
            availableTags: [first, second]
        ) == [first.id, second.id]
    )
    #expect(
        DiscordRESTProvider.orderedUniqueForumTagIDs(
            [ForumTagID(rawValue: 9_999)],
            availableTags: [first, second]
        ).isEmpty
    )
    #expect(
        DiscordRESTProvider.validForumAutoArchiveDurations
            == [60, 1_440, 4_320, 10_080]
    )
}

@Test func `older forum pagination keeps the remote offset separate from active posts`() {
    let parentID = ChannelID(rawValue: 10)
    let active = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 100),
            parentID: parentID,
            name: "Active"
        )
    )
    let staleOlder = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 101),
            parentID: parentID,
            name: "Stale older",
            isArchived: true
        )
    )
    let firstRemoteOlder = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 102),
            parentID: parentID,
            name: "First remote older",
            isArchived: true
        )
    )
    let firstPage = DiscordRESTProvider.mergedForumCataloguePage(
        cachedPosts: [active, staleOlder],
        olderPage: ForumPostPage(
            posts: [firstRemoteOlder],
            hasMore: true,
            nextOffset: 25
        ),
        query: ForumPostQuery(limit: 25)
    )

    #expect(Set(firstPage.posts.map(\.id)) == [active.id, firstRemoteOlder.id])
    #expect(firstPage.nextOffset == 25)
    #expect(firstPage.hasMore)

    let secondRemoteOlder = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 103),
            parentID: parentID,
            name: "Second remote older",
            isArchived: true
        )
    )
    let secondPage = DiscordRESTProvider.mergedForumCataloguePage(
        cachedPosts: [active, firstRemoteOlder],
        olderPage: ForumPostPage(
            posts: [secondRemoteOlder],
            hasMore: false,
            nextOffset: nil
        ),
        query: ForumPostQuery(offset: 25, limit: 25)
    )

    #expect(secondPage.posts.map(\.id) == [secondRemoteOlder.id])
    #expect(secondPage.nextOffset == nil)
    #expect(!secondPage.hasMore)
}

@Test func `forum search response keeps locked threads with partial owners`() throws {
    let data = Data(
        """
        {
          "threads": [
            {
              "id": "100",
              "guild_id": "1",
              "parent_id": "2",
              "type": 11,
              "name": "media viewer",
              "owner": { "id": "3" },
              "message_count": 2,
              "thread_metadata": {
                "archived": false,
                "locked": true
              }
            }
          ],
          "members": [
            {
              "id": "100",
              "user_id": "9",
              "flags": 4,
              "muted": false
            }
          ],
          "first_messages": [],
          "most_recent_messages": [],
          "has_more": false
        }
        """.utf8
    )

    let response = try JSONDecoder().decode(ForumThreadSearchResponseDTO.self, from: data)
    let post = try #require(response.posts(fallbackGuildID: GuildID(rawValue: 1)).first)

    #expect(post.thread.name == "media viewer")
    #expect(post.thread.isLocked)
    #expect(post.owner?.id == UserID(rawValue: 3))
    #expect(post.thread.notificationSettings?.notificationLevel == .onlyMentions)
    #expect(post.thread.notificationSettings?.isMuted == false)
}

@Test func `forum catalogue response decodes older posts and result metadata`() throws {
    let data = Data(
        """
        {
          "threads": [
            {
              "id": "200",
              "guild_id": "1",
              "parent_id": "2",
              "type": 11,
              "name": "Older post",
              "owner_id": "3",
              "owner": { "avatar": "partial-owner-record" },
              "message_count": 4,
              "thread_metadata": {
                "archived": true,
                "locked": false,
                "archive_timestamp": "2026-07-20T10:11:12.345Z"
              }
            }
          ],
          "members": [
            {
              "id": "200",
              "user_id": "9",
              "flags": 2,
              "muted": true,
              "mute_config": {
                "end_time": "2026-07-30T22:00:00.000Z"
              }
            }
          ],
          "has_more": true,
          "total_results": 31
        }
        """.utf8
    )

    let response = try JSONDecoder().decode(ForumThreadCatalogueResponseDTO.self, from: data)
    let post = try #require(response.posts(fallbackGuildID: GuildID(rawValue: 1)).first)

    #expect(response.hasMore)
    #expect(response.totalResults == 31)
    #expect(post.thread.name == "Older post")
    #expect(post.thread.isArchived)
    #expect(post.thread.ownerID == UserID(rawValue: 3))
    #expect(post.owner == nil)
    #expect(post.thread.archiveTimestamp != nil)
    #expect(post.thread.notificationSettings?.notificationLevel == .allMessages)
    #expect(post.thread.notificationSettings?.isMuted == true)
    #expect(post.thread.notificationSettings?.muteConfiguration?.endTime != nil)
}

@Test func `forum catalogue keeps valid posts when one sibling is malformed`() throws {
    let data = Data(
        """
        {
          "threads": [
            {
              "id": "200",
              "guild_id": "1",
              "parent_id": "2",
              "type": 11,
              "name": "Valid post"
            },
            {
              "guild_id": "1",
              "parent_id": "2",
              "type": 11,
              "name": "Missing identifier"
            }
          ],
          "has_more": false
        }
        """.utf8
    )

    let response = try JSONDecoder().decode(ForumThreadCatalogueResponseDTO.self, from: data)

    #expect(response.threads.count == 1)
    #expect(response.skippedThreadCount == 1)
    #expect(response.posts(fallbackGuildID: GuildID(rawValue: 1)).first?.thread.name == "Valid post")
}

@Test func `thread list replacement retains locked forum posts`() {
    let locked = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 100),
            guildID: GuildID(rawValue: 1),
            parentID: ChannelID(rawValue: 2),
            name: "Locked",
            isLocked: true
        )
    )
    var open = locked
    open.thread.isLocked = false

    #expect(DiscordRESTProvider.shouldPreserveForumPostDuringThreadListReplacement(locked))
    #expect(!DiscordRESTProvider.shouldPreserveForumPostDuringThreadListReplacement(open))
}

@Test func `catalogue refresh retains hydrated forum preview data`() throws {
    let channelID = ChannelID(rawValue: 100)
    let owner = User(id: UserID(rawValue: 7), username: "owner", displayName: "Owner")
    let message = Message(
        id: MessageID(rawValue: 101),
        channelID: channelID,
        author: owner,
        content: "Already hydrated",
        timestamp: Date(timeIntervalSince1970: 100)
    )
    let existing = ForumPost(
        thread: MessageThreadSummary(id: channelID, name: "Old metadata"),
        owner: owner,
        firstMessage: message,
        mostRecentMessage: message,
        isUnread: true
    )
    let incoming = ForumPost(
        thread: MessageThreadSummary(id: channelID, name: "Fresh metadata", isLocked: true)
    )

    let merged = DiscordRESTProvider.mergingForumPostCatalogueMetadata(
        incoming: incoming,
        existing: existing
    )

    #expect(merged.thread.name == "Fresh metadata")
    #expect(merged.thread.isLocked)
    #expect(merged.owner == owner)
    #expect(merged.firstMessage == message)
    #expect(merged.mostRecentMessage == message)
    #expect(merged.isUnread)
}

@Test func `catalogue refresh retains loaded forum reactor identities`() throws {
    let channelID = ChannelID(rawValue: 110)
    let owner = User(id: UserID(rawValue: 8), username: "owner", displayName: "Owner")
    let reactor = ReactionReactor(id: UserID(rawValue: 9), displayName: "Reactor")
    let existingMessage = Message(
        id: MessageID(rawValue: 111),
        channelID: channelID,
        author: owner,
        content: "Existing",
        reactions: [Reaction(emoji: "❤️", count: 1, reactors: [reactor])]
    )
    var incomingMessage = existingMessage
    incomingMessage.content = "Fresh"
    incomingMessage.reactions = [Reaction(emoji: "❤️", count: 2)]
    let existing = ForumPost(
        thread: MessageThreadSummary(id: channelID, name: "Old"),
        firstMessage: existingMessage
    )
    let incoming = ForumPost(
        thread: MessageThreadSummary(id: channelID, name: "Fresh"),
        firstMessage: incomingMessage
    )

    let merged = DiscordRESTProvider.mergingForumPostCatalogueMetadata(
        incoming: incoming,
        existing: existing
    )

    #expect(merged.firstMessage?.content == "Fresh")
    #expect(merged.firstMessage?.reactions.first?.count == 2)
    #expect(merged.firstMessage?.reactions.first?.reactors == [reactor])
}

@Test func `superseded forum catalogue refreshes leave only the latest query active`() async throws {
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-refresh-cancellation"),
        session: .shared
    )
    let channel = Channel(
        id: ChannelID(rawValue: 7),
        guildID: GuildID(rawValue: 1),
        name: "forum",
        kind: .forum
    )
    let cachedPost = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 42),
            guildID: channel.guildID,
            parentID: channel.id,
            name: "Cached active post"
        )
    )
    await provider.seedForumChannelForTesting(channel, posts: [cachedPost])
    await provider.suspendForumCatalogueRefreshForTesting()
    let latestActivity = ForumPostQuery(sortOrder: .latestActivity, limit: 25)
    let creationDate = ForumPostQuery(sortOrder: .creationDate, limit: 25)

    _ = try await provider.forumPosts(in: channel.id, query: latestActivity)
    _ = try await provider.forumPosts(in: channel.id, query: creationDate)
    _ = try await provider.forumPosts(in: channel.id, query: latestActivity)
    for _ in 0 ..< 10 {
        await Task.yield()
    }

    #expect(
        await provider.activeForumCatalogueQueriesForTesting(channelID: channel.id)
            == [latestActivity]
    )
    await provider.disconnect()
}

@Test func `switching forums cancels the previous catalogue refresh`() async throws {
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-switch-cancellation"),
        session: .shared
    )
    let firstChannel = Channel(
        id: ChannelID(rawValue: 7),
        guildID: GuildID(rawValue: 1),
        name: "first",
        kind: .forum
    )
    let secondChannel = Channel(
        id: ChannelID(rawValue: 8),
        guildID: GuildID(rawValue: 1),
        name: "second",
        kind: .forum
    )
    let firstPost = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 41),
            guildID: firstChannel.guildID,
            parentID: firstChannel.id,
            name: "First"
        )
    )
    let secondPost = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 42),
            guildID: secondChannel.guildID,
            parentID: secondChannel.id,
            name: "Second"
        )
    )
    await provider.seedForumChannelForTesting(firstChannel, posts: [firstPost])
    await provider.seedForumChannelForTesting(secondChannel, posts: [secondPost])
    await provider.suspendForumCatalogueRefreshForTesting()
    let query = ForumPostQuery(limit: 25)

    _ = try await provider.forumPosts(in: firstChannel.id, query: query)
    _ = try await provider.forumPosts(in: secondChannel.id, query: query)
    for _ in 0 ..< 10 {
        await Task.yield()
    }

    #expect(await provider.activeForumCatalogueQueriesForTesting(channelID: firstChannel.id).isEmpty)
    #expect(
        await provider.activeForumCatalogueQueriesForTesting(channelID: secondChannel.id)
            == [query]
    )
    await provider.disconnect()
}

@Test func `new incoming forum replies mark only the affected post unread`() async throws {
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-unread"),
        session: .shared
    )
    let currentUser = User(
        id: UserID(rawValue: 10),
        username: "current",
        displayName: "Current"
    )
    let otherUser = User(
        id: UserID(rawValue: 11),
        username: "other",
        displayName: "Other"
    )
    let channel = Channel(
        id: ChannelID(rawValue: 7),
        guildID: GuildID(rawValue: 1),
        name: "forum",
        kind: .forum
    )
    let incomingPost = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 42),
            guildID: channel.guildID,
            parentID: channel.id,
            name: "Incoming reply",
            lastMessageID: MessageID(rawValue: 100)
        )
    )
    let ownPost = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 43),
            guildID: channel.guildID,
            parentID: channel.id,
            name: "Own reply",
            lastMessageID: MessageID(rawValue: 200)
        )
    )
    await provider.seedForumChannelForTesting(
        channel,
        posts: [incomingPost, ownPost],
        currentUser: currentUser
    )

    await provider.receiveForumMessageForTesting(
        Message(
            id: MessageID(rawValue: 101),
            channelID: incomingPost.id,
            author: otherUser,
            content: "New incoming reply",
            timestamp: Date(timeIntervalSince1970: 101)
        )
    )
    await provider.receiveForumMessageForTesting(
        Message(
            id: MessageID(rawValue: 201),
            channelID: ownPost.id,
            author: currentUser,
            content: "My own reply",
            timestamp: Date(timeIntervalSince1970: 201)
        )
    )

    #expect(await provider.cachedForumPostForTesting(threadID: incomingPost.id)?.isUnread == true)
    #expect(await provider.cachedForumPostForTesting(threadID: ownPost.id)?.isUnread == false)
    #expect(
        await provider.cachedForumPostForTesting(threadID: incomingPost.id)?
            .thread.messageCount == incomingPost.thread.messageCount + 1
    )
    #expect(
        await provider.cachedForumPostForTesting(threadID: ownPost.id)?
            .thread.messageCount == ownPost.thread.messageCount + 1
    )
    await provider.disconnect()
}

@Test func `forum preview messages enter the shared reaction message cache`() async {
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-preview-cache"),
        session: .shared
    )
    let channel = Channel(
        id: ChannelID(rawValue: 7),
        guildID: GuildID(rawValue: 1),
        name: "forum",
        kind: .forum
    )
    let message = Message(
        id: MessageID(rawValue: 42),
        channelID: ChannelID(rawValue: 42),
        author: User(id: UserID(rawValue: 3), username: "owner", displayName: "Owner"),
        content: "Starter",
        timestamp: .now
    )
    let post = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 42),
            guildID: channel.guildID,
            parentID: channel.id,
            name: "Reaction-ready post"
        ),
        firstMessage: message
    )

    await provider.seedForumChannelForTesting(channel, posts: [post])

    #expect(await provider.cachedMessageForTesting(messageID: message.id) == message)
    await provider.disconnect()
}

private actor ForumPostDeletionCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("forum-delete-test-session".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        [CredentialHandle(accountID: "forum-delete")]
    }
}

private final class ForumPostDeletionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var method: String?
    nonisolated(unsafe) static var path = ""
    nonisolated(unsafe) static var hadAuthorization = false
    nonisolated(unsafe) static var hadBody = false

    static func reset() {
        requestCount = 0
        method = nil
        path = ""
        hadAuthorization = false
        hadBody = false
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        Self.method = request.httpMethod
        Self.path = request.url?.path ?? ""
        Self.hadAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
        Self.hadBody = request.httpBody != nil || request.httpBodyStream != nil

        guard let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ForumThreadResolutionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var method: String?
    nonisolated(unsafe) static var path = ""
    nonisolated(unsafe) static var hadAuthorization = false
    nonisolated(unsafe) static var hadBody = false

    static func reset() {
        requestCount = 0
        method = nil
        path = ""
        hadAuthorization = false
        hadBody = false
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        Self.method = request.httpMethod
        Self.path = request.url?.path ?? ""
        Self.hadAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
        Self.hadBody = request.httpBody != nil || request.httpBodyStream != nil

        guard let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = Data(
            """
            {
              "id": "42",
              "guild_id": "1",
              "parent_id": "7",
              "type": 11,
              "name": "Linked forum post",
              "owner_id": "3",
              "message_count": 1,
              "thread_metadata": {
                "archived": false,
                "locked": false,
                "archive_timestamp": "2026-07-23T10:00:00.000Z"
              }
            }
            """.utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ForumPostCreationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var method: String?
    nonisolated(unsafe) static var path = ""
    nonisolated(unsafe) static var query: [String: String] = [:]
    nonisolated(unsafe) static var hadAuthorization = false
    nonisolated(unsafe) static var body: [String: Any]?

    static func reset() {
        requestCount = 0
        method = nil
        path = ""
        query = [:]
        hadAuthorization = false
        body = nil
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        Self.method = request.httpMethod
        Self.path = request.url?.path ?? ""
        Self.query = Dictionary(
            uniqueKeysWithValues: URLComponents(
                url: request.url ?? URL(fileURLWithPath: "/"),
                resolvingAgainstBaseURL: false
            )?.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? []
        )
        Self.hadAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
        if let data = Self.requestBody(request) {
            Self.body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        guard let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let responseBody = Data(
            """
            {
              "id": "42",
              "guild_id": "1",
              "parent_id": "7",
              "type": 11,
              "name": "Contract post",
              "owner_id": "3",
              "applied_tags": ["8001", "8002"],
              "message_count": 1,
              "thread_metadata": {
                "archived": false,
                "locked": false,
                "auto_archive_duration": 4320
              },
              "message": {
                "id": "42",
                "channel_id": "42",
                "author": {
                  "id": "3",
                  "username": "owner"
                },
                "content": "Nested starter content",
                "timestamp": "2026-07-23T10:00:00.000Z"
              }
            }
            """.utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class ForumInitialLoadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var catalogueRequestCount = 0
    nonisolated(unsafe) static var previewRequestCount = 0

    static func reset() {
        catalogueRequestCount = 0
        previewRequestCount = 0
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: Data
        if path.hasSuffix("/channels/7/threads/search") {
            Self.catalogueRequestCount += 1
            body = Data(
                """
                {
                  "threads": [
                    {
                      "id": "42",
                      "guild_id": "1",
                      "parent_id": "7",
                      "type": 11,
                      "name": "Visible immediately",
                      "owner_id": "3",
                      "message_count": 1,
                      "thread_metadata": {
                        "archived": true,
                        "locked": false,
                        "archive_timestamp": "2026-07-23T10:00:00.000Z"
                      }
                    }
                  ],
                  "has_more": false,
                  "total_results": 1
                }
                """.utf8
            )
        } else if path.hasSuffix("/channels/7/post-data") {
            Self.previewRequestCount += 1
            // Model the comparatively expensive preview request that used to block
            // the catalogue result. The production path must return the decoded
            // threads while this request is still in flight.
            Thread.sleep(forTimeInterval: 0.55)
            body = Data(#"{"threads":{"42":{}}}"#.utf8)
        } else {
            body = Data("{}".utf8)
        }

        guard let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ForumPageScopedPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var previewRequestCount = 0
    nonisolated(unsafe) static var requestedThreadIDs: [String] = []

    static func reset() {
        previewRequestCount = 0
        requestedThreadIDs = []
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: Data
        if path.hasSuffix("/channels/7/post-data") {
            Self.previewRequestCount += 1
            if let data = Self.requestBody(request),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ids = object["thread_ids"] as? [String]
            {
                Self.requestedThreadIDs.append(contentsOf: ids)
            }
            body = Data(#"{"threads":{"42":{}}}"#.utf8)
        } else if path.hasSuffix("/channels/7/threads/search") {
            body = Data(
                #"{"threads":[],"has_more":false,"total_results":0}"#.utf8
            )
        } else {
            body = Data("{}".utf8)
        }

        guard let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
