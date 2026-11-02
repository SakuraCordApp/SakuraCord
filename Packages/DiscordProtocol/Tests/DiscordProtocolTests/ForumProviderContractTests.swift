import Foundation
import Synchronization
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

/// Observed 2026-10-06: creating a thread delivers a member-less THREAD_CREATE,
/// then THREAD_MEMBER_UPDATE carrying the join timestamp the sidebar orders by.
@Test func `created thread joins on the following member update`() async throws {
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "joined-thread-create")
    )
    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_CREATE",
        data: .object([
            "id": .string("400"),
            "guild_id": .string("1"),
            "parent_id": .string("7"),
            "name": .string("New thread"),
            "type": .number(11),
            "newly_created": .bool(true),
            "thread_metadata": .object([
                "archived": .bool(false),
                "auto_archive_duration": .number(4320),
            ]),
        ])
    )
    #expect(await provider.activeJoinedThreadsForTesting().isEmpty)

    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_MEMBER_UPDATE",
        data: .object([
            "id": .string("400"),
            "guild_id": .string("1"),
            "flags": .number(1),
            "join_timestamp": .string("2026-10-06T13:59:32.181145+00:00"),
            "muted": .bool(false),
            "mute_config": .null,
        ])
    )
    let joined = await provider.activeJoinedThreadsForTesting()
    #expect(joined.map(\.id) == [ChannelID(rawValue: 400)])
    #expect(
        joined.first?.notificationSettings?.joinedAt
            == DiscordDate.parse("2026-10-06T13:59:32.181145+00:00")
    )
    await provider.disconnect()
}

/// Both thread-creation routes share `ForumPostCreationURLProtocol`'s captured request.
@Suite(.serialized)
struct ThreadCreationContractTests {
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
        #expect(Set(try #require(body["message"] as? [String: Any]).keys) == ["content"])
    }

    @Test(arguments: [
        (ChannelKindValue.text, false, 11),
        (ChannelKindValue.text, true, 12),
        (ChannelKindValue.announcement, false, 10),
    ])
    func `plus button thread creation sends one first-party thread payload`(
        kind: ChannelKindValue,
        isPrivate: Bool,
        expectedType: Int
    ) async throws {
        ForumPostCreationURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForumPostCreationURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: ForumPostDeletionCredentialStore(),
            handle: CredentialHandle(accountID: "thread-create"),
            session: URLSession(configuration: configuration)
        )
        let channel = Channel(id: ChannelID(rawValue: 7), guildID: GuildID(rawValue: 1), name: "general", kind: kind)
        await provider.seedForumChannelForTesting(channel)

        let thread = try await provider.createThread(
            CreateThreadDraft(
                channelID: channel.id,
                name: "  Contract thread ",
                isPrivate: isPrivate,
                autoArchiveDuration: 1_440
            )
        )

        #expect(thread.id == ChannelID(rawValue: 42))
        #expect(thread.parentID == channel.id)
        #expect(ForumPostCreationURLProtocol.requestCount == 1)
        #expect(ForumPostCreationURLProtocol.method == "POST")
        #expect(ForumPostCreationURLProtocol.path == "/api/v9/channels/7/threads")
        #expect(ForumPostCreationURLProtocol.query.isEmpty)
        #expect(ForumPostCreationURLProtocol.hadAuthorization)
        let body = try #require(ForumPostCreationURLProtocol.body)
        #expect(Set(body.keys) == ["name", "type", "auto_archive_duration", "location"])
        #expect(body["name"] as? String == "Contract thread")
        #expect(body["type"] as? Int == expectedType)
        #expect(body["auto_archive_duration"] as? Int == 1_440)
        #expect(body["location"] as? String == "Plus Button")
    }
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

private func retentionThreadPayload(
    _ id: String, parentID: String = "7", member: JSONValue? = nil
) -> JSONValue {
    var thread: [String: JSONValue] = [
        "id": .string(id), "guild_id": .string("1"), "parent_id": .string(parentID),
        "name": .string("Thread \(id)"), "type": .number(11),
        "thread_metadata": .object(["archived": .bool(false), "locked": .bool(false)]),
    ]
    if let member { thread["member"] = member }
    return .object(thread)
}

private func retentionPost(
    _ id: UInt64, parentID: UInt64 = 7, isArchived: Bool = false, isPrivate: Bool = false
) -> ForumPost {
    ForumPost(thread: MessageThreadSummary(
        id: ChannelID(rawValue: id), guildID: GuildID(rawValue: 1),
        parentID: ChannelID(rawValue: parentID), name: "Post \(id)",
        isArchived: isArchived, notificationSettings: ThreadNotificationSettings(),
        isPrivate: isPrivate
    ))
}

/// The desktop op-37 THREAD_LIST_SYNC lists every viewable active thread
/// without `channel_ids` or members. Every official thread store only merges it.
@Test func `thread list sync adds threads without evicting omitted posts or memberships`() async throws {
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-thread-retention")
    )
    let forum = Channel(
        id: ChannelID(rawValue: 7), guildID: GuildID(rawValue: 1), name: "forum", kind: .forum
    )
    // A later archived catalogue page and an active post resolved by Get Channel.
    await provider.seedForumChannelForTesting(
        forum,
        posts: [retentionPost(500, isArchived: true), retentionPost(510)],
        currentUser: User(id: UserID(rawValue: 9), username: "tester", displayName: "Tester")
    )
    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_MEMBER_UPDATE",
        data: .object(["id": .string("510"), "flags": .number(0), "muted": .bool(false)])
    )
    let joinedMember: JSONValue = .object(["flags": .number(0), "muted": .bool(false)])
    for id in ["520", "530"] {
        await provider.receiveGatewayDispatchForTesting(
            name: "THREAD_CREATE", data: retentionThreadPayload(id, member: joinedMember)
        )
    }
    #expect(Set(await provider.activeJoinedThreadsForTesting().map(\.id)) == [
        ChannelID(rawValue: 510), ChannelID(rawValue: 520), ChannelID(rawValue: 530),
    ])

    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_LIST_SYNC",
        data: .object([
            "guild_id": .string("1"),
            "threads": .array([retentionThreadPayload("520"), retentionThreadPayload("540")]),
            "most_recent_messages": .array([]),
        ])
    )
    // A channel-scoped sync is equally additive for the channels it names.
    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_LIST_SYNC",
        data: .object([
            "guild_id": .string("1"),
            "channel_ids": .array([.string("7")]),
            "threads": .array([retentionThreadPayload("540")]),
        ])
    )

    for id: UInt64 in [500, 510, 520, 530, 540] {
        #expect(await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: id)) != nil)
    }
    // A member-less listing is not leaving, and an unjoined listing is not joining.
    #expect(Set(await provider.activeJoinedThreadsForTesting().map(\.id)) == [
        ChannelID(rawValue: 510), ChannelID(rawValue: 520), ChannelID(rawValue: 530),
    ])
    await provider.disconnect()
}

private func retentionReadyPayload() -> JSONValue {
    .object([
        "user": .object(["id": .string("9"), "username": .string("tester")]),
        "guilds": .array([.object([
            "id": .string("1"), "name": .string("Guild"),
            "channels": .array([
                .object(["id": .string("7"), "type": .number(15), "name": .string("forum")]),
            ]),
        ])]),
    ])
}

@Test func `fresh ready retains public REST known posts while their parent is listed`() async throws {
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-ready-retention")
    )
    await provider.seedForumChannelForTesting(
        Channel(id: ChannelID(rawValue: 7), guildID: GuildID(rawValue: 1), name: "forum", kind: .forum),
        posts: [
            retentionPost(500, isArchived: true), retentionPost(510),
            retentionPost(520, isArchived: true, isPrivate: true),
        ]
    )
    await provider.seedForumChannelForTesting(
        Channel(id: ChannelID(rawValue: 8), guildID: GuildID(rawValue: 1), name: "removed", kind: .forum),
        posts: [retentionPost(600, parentID: 8)]
    )

    await provider.receiveGatewayDispatchForTesting(name: "READY", data: retentionReadyPayload())

    // READY lists only joined active threads; a public thread's content follows
    // its parent, so it is kept, but its membership is no longer evidence.
    for id: UInt64 in [500, 510] {
        let retained = await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: id))
        #expect(retained != nil && retained?.thread.notificationSettings == nil)
    }
    // A private thread's access follows membership READY cannot settle.
    #expect(await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 520)) == nil)
    #expect(await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 600)) == nil)
    await provider.disconnect()
}

/// Each case holds the Get Channel response, produced while the user was a
/// member of the unlocked private thread, until a newer Gateway event was applied.
@Test(arguments: ["leave", "delete", "lock", "ready"])
func `a delayed thread lookup cannot override newer gateway evidence`(event: String) async throws {
    let fixture = ThreadLookupFixture { index in
        ThreadLookupFixture.Answer(includesMember: index == 0, isGated: index == 0)
    }
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-lookup-\(event)"),
        session: URLSession(configuration: fixture.configuration)
    )
    // The READY case resolves a retained public thread whose membership the
    // fresh READY clears; the others look up an uncached thread.
    await provider.seedForumChannelForTesting(
        Channel(id: ChannelID(rawValue: 7), guildID: GuildID(rawValue: 1), name: "forum", kind: .forum),
        posts: event == "ready" ? [retentionPost(700)] : [],
        currentUser: User(id: UserID(rawValue: 9), username: "tester", displayName: "Tester")
    )
    let threadID = "700"
    let lookup = Task {
        event == "ready"
            ? try await provider.resolveThreadAccess(threadID: ChannelID(rawValue: 700))
            : try await provider.forumPost(threadID: ChannelID(rawValue: 700))
    }
    await fixture.waitUntilGated()
    switch event {
    case "leave":
        await provider.receiveGatewayDispatchForTesting(name: "THREAD_MEMBERS_UPDATE", data: .object([
            "id": .string(threadID), "guild_id": .string("1"), "member_count": .number(0),
            "removed_member_ids": .array([.string("9")]),
        ]))
    case "delete":
        await provider.receiveGatewayDispatchForTesting(name: "THREAD_DELETE", data: .object([
            "id": .string(threadID), "guild_id": .string("1"), "parent_id": .string("7"),
        ]))
    case "ready":
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: retentionReadyPayload())
    default:
        await provider.receiveGatewayDispatchForTesting(
            name: "THREAD_UPDATE", data: lockedPrivateThreadUpdate(threadID)
        )
    }
    fixture.releaseGatedResponse()

    switch event {
    case "leave":
        // The leave makes the provider ask again; the newer answer has no member.
        let post = try await lookup.value
        #expect(post.thread.notificationSettings == nil)
        #expect(await provider.activeJoinedThreadsForTesting().isEmpty)
    case "delete":
        await #expect(throws: ChatProviderError.channelNotFound) { try await lookup.value }
        #expect(await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 700)) == nil)
    case "ready":
        // The response predates READY, which cleared the retained membership.
        let post = try await lookup.value
        #expect(post.thread.notificationSettings == nil)
        #expect(await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 700))?
            .thread.notificationSettings == nil)
        #expect(await provider.activeJoinedThreadsForTesting().isEmpty)
    default:
        // The newer metadata is kept, and a member-less record is no evidence
        // of leaving: the response's member still grants private access.
        let post = try await lookup.value
        #expect(post.thread.isLocked && post.thread.name == "Locked thread")
        #expect(post.thread.isPrivate && post.thread.notificationSettings != nil)
        let cached = await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 700))
        #expect(cached?.thread.isLocked == true && cached?.thread.notificationSettings != nil)
        #expect(await provider.activeJoinedThreadsForTesting().map(\.id) == [ChannelID(rawValue: 700)])
    }
    // The leave case asks again after the release; keep the fixture answering.
    withExtendedLifetime(fixture) {}
    await provider.disconnect()
}

/// Failed resolution, then a member-less record caches the thread, then Try
/// Again: a cache hit would settle nothing, so the resolution asks Discord.
@Test func `thread access resolution asks again over a member-less cached record`() async throws {
    let fixture = ThreadLookupFixture { index in
        ThreadLookupFixture.Answer(status: index == 0 ? 404 : 200)
    }
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "forum-access-retry"),
        session: URLSession(configuration: fixture.configuration)
    )
    await provider.seedForumChannelForTesting(
        Channel(id: ChannelID(rawValue: 7), guildID: GuildID(rawValue: 1), name: "forum", kind: .forum),
        currentUser: User(id: UserID(rawValue: 9), username: "tester", displayName: "Tester")
    )
    let threadID = ChannelID(rawValue: 700)
    await #expect(throws: (any Error).self) { try await provider.resolveThreadAccess(threadID: threadID) }
    await provider.receiveGatewayDispatchForTesting(name: "THREAD_UPDATE", data: lockedPrivateThreadUpdate("700"))
    #expect(await provider.cachedForumPostForTesting(threadID: threadID)?.thread.notificationSettings == nil)

    let resolved = try await provider.resolveThreadAccess(threadID: threadID)

    #expect(fixture.requestCount == 2)
    // No record arrived during this read, so its fresher metadata (Discord now
    // reports the thread unlocked) replaces the cached record's.
    #expect(!resolved.thread.isLocked && resolved.thread.name == "Thread")
    #expect(resolved.thread.notificationSettings != nil)
    #expect(await provider.cachedForumPostForTesting(threadID: threadID)?.thread.isLocked == false)
    // Ordinary navigation stays a cache hit.
    #expect(try await provider.forumPost(threadID: threadID).thread.notificationSettings != nil)
    #expect(fixture.requestCount == 2)
    await provider.disconnect()
}

private func lockedPrivateThreadUpdate(_ threadID: String) -> JSONValue {
    .object([
        "id": .string(threadID), "guild_id": .string("1"), "parent_id": .string("7"),
        "type": .number(12), "name": .string("Locked thread"),
        "thread_metadata": .object(["archived": .bool(false), "locked": .bool(true)]),
    ])
}

/// A Get Channel fixture scoped to one test invocation: only requests carrying
/// its identity header reach it, its script decides each answer, and releasing
/// it frees a held response.
private final class ThreadLookupFixture {
    struct Answer: Sendable {
        var status = 200
        /// The response states that user 9 is a member.
        var includesMember = true
        /// The response waits for `releaseGatedResponse()`.
        var isGated = false
    }

    private final class Storage: Sendable {
        let requestCount = Mutex(0)
        let reached = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
    }

    let id = UUID().uuidString
    private let storage = Storage()
    private var observer: NSObjectProtocol?

    init(script: @escaping @Sendable (Int) -> Answer) {
        let id = id, storage = storage
        observer = NotificationCenter.default.addObserver(
            forName: ThreadLookupURLProtocol.requested, object: nil, queue: nil
        ) { note in
            guard let lookup = note.object as? ThreadLookupURLProtocol,
                  lookup.request.value(forHTTPHeaderField: ThreadLookupURLProtocol.fixtureHeader) == id
            else { return }
            let index = storage.requestCount.withLock { count in
                defer { count += 1 }
                return count
            }
            let answer = script(index)
            guard answer.isGated else {
                lookup.answer(answer)
                return
            }
            storage.reached.signal()
            DispatchQueue.global().async {
                storage.released.wait()
                lookup.answer(answer)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        storage.released.signal()
    }

    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThreadLookupURLProtocol.self]
        configuration.httpAdditionalHeaders = [ThreadLookupURLProtocol.fixtureHeader: id]
        return configuration
    }

    var requestCount: Int { storage.requestCount.withLock { $0 } }

    func waitUntilGated() async {
        let storage = storage
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                storage.reached.wait()
                continuation.resume()
            }
        }
    }

    func releaseGatedResponse() { storage.released.signal() }
}

private final class ThreadLookupURLProtocol: URLProtocol, @unchecked Sendable {
    static let requested = Notification.Name("ForumProviderContract.threadLookup")
    static let fixtureHeader = "X-Thread-Lookup-Test"

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { NotificationCenter.default.post(name: Self.requested, object: self) }
    override func stopLoading() {}

    func answer(_ answer: ThreadLookupFixture.Answer) {
        let threadID = request.url?.lastPathComponent ?? ""
        let member = answer.includesMember
            ? #", "member": {"id": "\#(threadID)", "user_id": "9", "flags": 1, "muted": false}"#
            : ""
        let body = answer.status == 200
            ? """
            {"id": "\(threadID)", "guild_id": "1", "parent_id": "7", "type": 12, "name": "Thread",
             "thread_metadata": {"archived": false, "locked": false}\(member)}
            """
            : #"{"message": "Unknown Channel", "code": 10003}"#
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
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

    #expect(await eventually {
        await provider.activeForumCatalogueQueriesForTesting(channelID: channel.id)
            == [latestActivity]
    })
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

    #expect(await eventually {
        let first = await provider.activeForumCatalogueQueriesForTesting(channelID: firstChannel.id)
        let second = await provider.activeForumCatalogueQueriesForTesting(channelID: secondChannel.id)
        return first.isEmpty && second == [query]
    })
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

@Test func `thread-created messages attach the known thread and its latest message`() async throws {
    let record = try JSONDecoder().decode(ChannelDTO.self, from: Data(
        #"{"id":"42","parent_id":"7","type":11,"name":"Notes","most_recent_message":{"id":"45","channel_id":"42","content":"Guild record","author":{"id":"3","username":"owner"}}}"#.utf8
    ))
    #expect(try record.forumPost(fallbackGuildID: nil).mostRecentMessage?.content == "Guild record")

    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "thread-card"),
        session: URLSession(configuration: .ephemeral)
    )
    await provider.seedForumChannelForTesting(
        Channel(id: ChannelID(rawValue: 7), guildID: GuildID(rawValue: 1), name: "general", kind: .text)
    )
    await provider.receiveGatewayDispatchForTesting(
        name: "THREAD_LIST_SYNC",
        data: .object([
            "guild_id": .string("1"),
            "channel_ids": .array([.string("7")]),
            "threads": .array([.object([
                "id": .string("42"), "guild_id": .string("1"), "parent_id": .string("7"),
                "name": .string("Release notes"), "type": .number(11), "message_count": .number(3),
            ])]),
            "most_recent_messages": .array([.object([
                "id": .string("45"), "channel_id": .string("42"), "content": .string("Latest reply"),
                "author": .object(["id": .string("3"), "username": .string("owner")]),
            ])]),
        ])
    )
    let post = try #require(await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 42)))
    #expect(post.mostRecentMessage?.content == "Latest reply")

    var created = try JSONDecoder().decode(MessageDTO.self, from: Data(
        #"{"id":"43","channel_id":"7","type":18,"content":"Release notes","author":{"id":"3","username":"owner"},"message_reference":{"channel_id":"42","guild_id":"1"}}"#.utf8
    )).domain()
    await provider.attachKnownThread(to: &created)

    #expect(created.thread == post.thread)

    await provider.seedMessageForTesting(created)
    let reply = try #require(post.mostRecentMessage)
    await provider.seedMessageForTesting(reply)
    let stream = await provider.eventStream()
    await provider.receiveGatewayDispatchForTesting(name: "THREAD_DELETE", data: .object([
        "id": .string("42"), "parent_id": .string("7"), "guild_id": .string("1"), "type": .number(11),
    ]))
    var events = stream.makeAsyncIterator()
    #expect(await events.next() == .threadDeleted(channelID: post.id))
    #expect(await provider.cachedForumPostForTesting(threadID: post.id) == nil)
    #expect(await provider.cachedMessageForTesting(messageID: reply.id) == nil)
    let retained = await provider.cachedMessageForTesting(messageID: created.id)
    #expect(retained?.thread == nil)
    #expect(retained?.content == created.content)
}

@Test(arguments: [false, true])
func `deleted messages cannot return through cached thread previews`(bulk: Bool) async throws {
    let provider = DiscordRESTProvider(credentials: ForumPostDeletionCredentialStore(), handle: CredentialHandle(accountID: "deleted-thread-preview"))
    let parent = Channel(id: ChannelID(rawValue: 7), guildID: GuildID(rawValue: 1), name: "parent", kind: .text)
    let thread = MessageThreadSummary(id: ChannelID(rawValue: 200), parentID: parent.id, name: "thread")
    let author = User(id: UserID(rawValue: 1), username: "author", displayName: "Author")
    let message = Message(id: MessageID(rawValue: 201), channelID: thread.id, author: author, content: "Deleted")
    await provider.seedForumChannelForTesting(parent, posts: [ForumPost(thread: thread, firstMessage: message, mostRecentMessage: message)])
    var payload: [String: JSONValue] = ["channel_id": .string("200")]
    if bulk { payload["ids"] = .array([.string("201")]) } else { payload["id"] = .string("201") }
    await provider.receiveGatewayDispatchForTesting(name: bulk ? "MESSAGE_DELETE_BULK" : "MESSAGE_DELETE", data: .object(payload))
    let cached = try #require(await provider.cachedForumPostForTesting(threadID: thread.id))
    #expect(cached.firstMessage == nil)
    // A deleted starter is answered, not still loading.
    #expect(cached.isFirstMessageLoaded)
    #expect(cached.mostRecentMessage == nil)
    await provider.disconnect()
}

@Test func `thread member snapshots stay separate from the guild and reconcile membership and presence`() async throws {
    let payload = DiscordGatewayPayloadFactory.threadMemberSubscriptions(
        guildID: GuildID(rawValue: 1), threadIDs: [ChannelID(rawValue: 42)]
    )
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
    #expect(encoded == .object([
        "op": .number(37), "d": .object(["subscriptions": .object([
            "1": .object(["thread_member_lists": .array([.string("42")])])
        ])])
    ]))
    let provider = DiscordRESTProvider(
        credentials: ForumPostDeletionCredentialStore(),
        handle: CredentialHandle(accountID: "thread-members")
    )
    let guildID = GuildID(rawValue: 1)
    let thread = MessageThreadSummary(id: ChannelID(rawValue: 42), guildID: guildID, parentID: ChannelID(rawValue: 7), name: "Members")
    await provider.seedForumChannelForTesting(
        Channel(id: ChannelID(rawValue: 7), guildID: guildID, name: "general"),
        posts: [ForumPost(thread: thread)]
    )
    #expect(try await provider.threadMembers(in: thread) == nil)
    let snapshot = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
    {"guild_id":"1","thread_id":"42","members":[
      {"user_id":"9","member":{"user":{"id":"9","username":"joined"},"nick":"Thread Nick","roles":[]},
       "presence":{"status":"online","activities":[]}}
    ]}
    """#.utf8))
    await provider.receiveGatewayDispatchForTesting(name: "THREAD_MEMBER_LIST_UPDATE", data: snapshot)
    var members = try #require(try await provider.threadMembers(in: thread))
    #expect(members.map(\.id) == [UserID(rawValue: 9)])
    #expect(members.first?.user.displayName == "Thread Nick")
    #expect(members.first?.status == .online)
    #expect(members.first?.memberListIndex == nil)

    let presence = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"guild_id":"1","user":{"id":"9"},"status":"idle","activities":[]}"#.utf8))
    await provider.receiveGatewayDispatchForTesting(name: "PRESENCE_UPDATE", data: presence)
    #expect(try await provider.threadMembers(in: thread)?.first?.status == .idle)
    let changed = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
    {"guild_id":"1","id":"42","member_count":1,"removed_member_ids":["9"],"added_members":[
      {"user_id":"10","member":{"user":{"id":"10","username":"new"},"roles":[]},"presence":{"status":"offline"}}
    ]}
    """#.utf8))
    await provider.receiveGatewayDispatchForTesting(name: "THREAD_MEMBERS_UPDATE", data: changed)
    members = try #require(try await provider.threadMembers(in: thread))
    #expect(members.map(\.id) == [UserID(rawValue: 10)])
    // A new full snapshot replaces membership instead of accumulating stale users.
    await provider.receiveGatewayDispatchForTesting(name: "THREAD_MEMBER_LIST_UPDATE", data: snapshot)
    #expect(try await provider.threadMembers(in: thread)?.map(\.id) == [UserID(rawValue: 9)])
    await provider.disconnect()
}
