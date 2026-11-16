@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

@Test func `bounded event delivery preserves order and exposes overflow exactly once`() async {
    let failures = Mutex(0)
    let buffer = SessionEventBuffer<Int>(capacity: 3, overflowEvent: -1, onOverflow: {
        failures.withLock { $0 += 1 }
    })
    var iterator = buffer.stream.makeAsyncIterator()
    for value in 0 ..< 1_000 {
        buffer.yield(value)
        #expect(await iterator.next() == value)
    }
    for value in 1 ... 10 { buffer.yield(value) }
    var remaining: [Int] = []
    while let value = await iterator.next() { remaining.append(value) }
    #expect(remaining == [-1], "Do not drain stale UI work before reporting an overflow")
    #expect(failures.withLock { $0 } == 1)
}

@Test func `event delivery drains on finish and terminates on consumer cancellation`() async {
    let draining = SessionEventBuffer<Int>(capacity: 3, overflowEvent: -1)
    for value in 0 ..< 3 { draining.yield(value) }
    draining.finish()
    var delivered: [Int] = []
    for await value in draining.stream { delivered.append(value) }
    #expect(delivered == [0, 1, 2])

    let buffer = SessionEventBuffer<Int>(overflowEvent: -1)
    let started = AsyncStream<Void>.makeStream()
    let consumer = Task {
        started.continuation.yield(())
        for await _ in buffer.stream {}
    }
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    consumer.cancel()
    await consumer.value
    buffer.yield(42)
    var ended = buffer.stream.makeAsyncIterator()
    #expect(await ended.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func `event delivery cancellation can race producers without deadlocking`() async {
    for index in 0 ..< 1_000 {
        let buffer = SessionEventBuffer<Int>(capacity: 3, overflowEvent: -1)
        let consumer = Task { for await _ in buffer.stream {} }
        let producer = Task {
            if index.isMultiple(of: 2) { buffer.beginBatch() }
            buffer.yield(index)
            if index.isMultiple(of: 2) {
                buffer.yield(index + 1)
                buffer.endBatch()
            }
            await Task.yield()
            buffer.finish()
        }
        if index.isMultiple(of: 2) { await Task.yield() }
        consumer.cancel()
        await producer.value
        await consumer.value
    }
    var producer: SessionEventBuffer<Int>? = SessionEventBuffer(overflowEvent: -1)
    let stream = producer!.stream
    producer = nil
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil)
}

@Test func `initial payload batches preserve order and remain subject to delivery overflow`() async {
    let buffer = SessionEventBuffer<Int>(capacity: 3, overflowEvent: -1)
    buffer.yield(0)
    buffer.beginBatch()
    for value in 1 ... 1_000 { buffer.yield(value) }
    buffer.endBatch()
    buffer.yield(1_001)
    buffer.finish()
    var delivered: [Int] = []
    for await value in buffer.stream { delivered.append(value) }
    #expect(delivered == Array(0 ... 1_001))

    let overflowing = SessionEventBuffer<Int>(capacity: 1, overflowEvent: -1)
    overflowing.beginBatch()
    for value in 1 ... 10 { overflowing.yield(value) }
    overflowing.endBatch()
    var iterator = overflowing.stream.makeAsyncIterator()
    #expect(await iterator.next() == 1)
    overflowing.yield(11)
    #expect(await iterator.next() == -1, "Overflow must discard the remainder of a partially consumed batch")
    #expect(await iterator.next() == nil)
}

@Test func `provider overflow invalidates session and closes the request circuit`() async {
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(),
        handle: CredentialHandle(accountID: "buffer-test"),
        session: URLSession(configuration: .ephemeral)
    )
    let stream = await provider.eventStream()
    let stopped = AsyncStream<Void>.makeStream()
    await provider.observeOverflow { stopped.continuation.yield(()) }
    for _ in 0 ..< 600 {
        await provider.continuation?.yield(.connectionChanged(.ready))
    }
    var invalidations = 0
    for await event in stream {
        if case .sessionInvalidated = event { invalidations += 1 }
    }
    #expect(invalidations == 1)
    var stoppedIterator = stopped.stream.makeAsyncIterator()
    _ = await stoppedIterator.next()
    #expect(await provider.requestSafetyCircuitIsOpen)
    await provider.disconnect()
}

@Test func `message working set evicts oldest insertion and remains consistent after removals`() {
    let user = User(id: UserID(rawValue: 1), username: "fixture", displayName: "Fixture")
    func message(_ id: UInt64) -> Message {
        Message(id: MessageID(rawValue: id), channelID: ChannelID(rawValue: id % 2 + 1),
                author: user, content: "message \(id)")
    }
    var cache = DiscordMessageCache(capacity: 3)
    for id in UInt64(1) ... 3 { cache[MessageID(rawValue: id)] = message(id) }
    var edited = message(1)
    edited.content = "edited"
    cache[edited.id] = edited
    cache[MessageID(rawValue: 4)] = message(4)
    #expect(cache[edited.id] == nil)
    #expect(cache.count == 3)
    cache[MessageID(rawValue: 3)] = nil
    cache[MessageID(rawValue: 5)] = message(5)
    cache[MessageID(rawValue: 6)] = message(6)
    #expect(Set(cache.values.map(\.id)) == Set([4, 5, 6].map { MessageID(rawValue: $0) }))
    cache.removeAll { $0.channelID == ChannelID(rawValue: 1) }
    #expect(cache.values.map(\.id) == [MessageID(rawValue: 5)])
    cache.removeAll()
    cache[edited.id] = edited
    #expect(cache.count == 1)
    #expect(cache[edited.id]?.content == "edited")
}

@Test func `derived cache removal is account scoped and preserves unrelated storage`() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.appending(path: "dev.sakuracord.SakuraCord")
    let removed = ["ForwardSearchPeople/1.json", "QuickSwitcherChannelStore/1.json", "EmojiCache/1/10.json"]
    let preserved = ["ForwardSearchPeople/2.json", "QuickSwitcherChannelStore/2.json", "EmojiCache/2/10.json", "drafts.sqlite", "MediaCache/test"]
    for path in removed + preserved {
        let url = base.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }
    try await DiscordDerivedCacheStorage.remove(accountID: "1", cacheRoot: root)
    try await DiscordDerivedCacheStorage.remove(accountID: "1", cacheRoot: root)
    for path in removed { #expect(!FileManager.default.fileExists(atPath: base.appending(path: path).path)) }
    for path in preserved { #expect(FileManager.default.fileExists(atPath: base.appending(path: path).path)) }
}

@Test func `clearing derived caches drains pending writes and cancels scheduled persistence`() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "1"),
        session: URLSession(configuration: .ephemeral), usesForwardSearchPeopleDiskCache: true
    )
    await provider.setForwardSearchPeopleCacheDirectoryForTesting(directory)
    let url = try #require(await provider.forwardSearchPeopleCacheURL())
    let gate = CacheWriteGate()
    let pending = Task {
        await gate.wait()
        try? DiscordForwardSearchPeopleCache(users: [], aliases: []).save(to: url)
    }
    await provider.installPendingCacheWrite(pending)
    let began = AsyncStream<Void>.makeStream()
    await provider.observeCacheClear { began.continuation.yield(()) }
    let clearing = Task { try await provider.clearLocalSearchCache() }
    var beganIterator = began.stream.makeAsyncIterator()
    _ = await beganIterator.next()
    #expect(await provider.isClearingDerivedCaches)
    await provider.scheduleForwardSearchPeopleCachePersistence()
    await gate.release()
    try await clearing.value
    await provider.flushForwardSearchPeopleCachePersistence()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(await provider.forwardPeopleCachePersistenceTask == nil)
    await provider.disconnect()
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

private actor CacheWriteGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private extension DiscordRESTProvider {
    func observeOverflow(_ callback: @escaping @Sendable () -> Void) {
        eventOverflowDidStopRequestsForTesting = callback
    }

    func observeCacheClear(_ callback: @escaping @Sendable () -> Void) {
        derivedCacheClearDidBeginForTesting = callback
    }

    func installPendingCacheWrite(_ task: Task<Void, Never>) {
        forwardPeopleCacheWriteTask = task
        scheduleForwardSearchPeopleCachePersistence()
    }
}

@Test func `uncached Gateway edits publish a sparse update preserving omitted fields`() async throws {
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "patch-test"),
        session: URLSession(configuration: .ephemeral)
    )
    let stream = await provider.eventStream()
    await provider.handleGatewayDispatch(name: "MESSAGE_UPDATE", body: .object([
        "id": .string("30"), "channel_id": .string("20"),
        "content": .string("edited"), "pinned": .bool(false), "attachments": .array([])
    ]))
    await provider.disconnect()
    var patch: MessageUpdate?
    for await event in stream {
        if case .messagePatched(let update) = event { patch = update }
    }
    let update = try #require(patch)
    let author = User(id: UserID(rawValue: 1), username: "author", displayName: "Author")
    var message = Message(id: MessageID(rawValue: 30), channelID: ChannelID(rawValue: 20), author: author, content: "old")
    message.isPinned = true
    let timestamp = message.timestamp
    update.apply(to: &message)
    #expect(message.content == "edited")
    #expect(!message.isPinned)
    #expect(message.author == author)
    #expect(message.timestamp == timestamp)
    #expect(message.attachments.isEmpty)
}

@Test func `cleared search history cannot be restored by unrelated discoveries`() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "1"),
        session: URLSession(configuration: .ephemeral), usesForwardSearchPeopleDiskCache: true
    )
    await provider.setForwardSearchPeopleCacheDirectoryForTesting(directory)
    let old = try JSONDecoder().decode(UserDTO.self, from: Data(#"{"id":"10","username":"historical"}"#.utf8))
    let new = try JSONDecoder().decode(UserDTO.self, from: Data(#"{"id":"11","username":"new"}"#.utf8))
    await provider.cacheMessageSearchUsers([old])
    await provider.appendQuickSwitcherChannelStoreOrder([ChannelID(rawValue: 90)])
    try await provider.clearLocalSearchCache()
    #expect(await provider.cachedGatewayUsersByID[old.id] != nil)
    await provider.cacheMessageSearchUsers([new])
    await provider.flushForwardSearchPeopleCachePersistence()
    let url = try #require(await provider.forwardSearchPeopleCacheURL())
    let saved = try #require(DiscordForwardSearchPeopleCache.load(from: url))
    #expect(saved.users.map(\.id) == [UserID(rawValue: 11)])
    await provider.appendQuickSwitcherChannelStoreOrder([ChannelID(rawValue: 91)])
    await provider.persistQuickSwitcherChannelStoreCache()
    let orderURL = try #require(await provider.quickSwitcherChannelStoreCacheURL())
    let order = try #require(DiscordQuickSwitcherChannelStoreCache.load(from: orderURL))
    #expect(order.channelIDs == [ChannelID(rawValue: 91)])
    // Explicitly learning a person again permits a new history entry.
    await provider.cacheMessageSearchUsers([old])
    await provider.flushForwardSearchPeopleCachePersistence()
    let relearned = try #require(DiscordForwardSearchPeopleCache.load(from: url))
    #expect(Set(relearned.users.map(\.id)) == Set([10, 11].map { UserID(rawValue: $0) }))
    await provider.disconnect()
}

@Test(arguments: [false, true])
func `forum reactions survive working set eviction and later edits`(evicts: Bool) async throws {
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "1"),
        session: URLSession(configuration: .ephemeral)
    )
    await provider.seedForumReactionProjection(evicts: evicts)
    let messageID = MessageID(rawValue: 42)
    let channelID = ChannelID(rawValue: 42)
    let parentID = ChannelID(rawValue: 7)
    let userID = UserID(rawValue: 2)
    await provider.applyGatewayReactionUpdate(.add(
        channelID: channelID, messageID: messageID, userID: userID, emoji: "🔥", kind: .normal
    ))
    await provider.handleGatewayDispatch(name: "MESSAGE_UPDATE", body: .object([
        "id": .string("42"), "channel_id": .string("42"), "content": .string("edited")
    ]))
    let post = try #require(await provider.cachedForumPosts[parentID]?[channelID])
    #expect(post.firstMessage?.content == "edited")
    #expect(post.firstMessage?.reactions.first?.count == 1)
    #expect(post.mostRecentMessage?.reactions.first?.count == 1)
    await provider.applyGatewayReactionUpdate(.remove(
        channelID: channelID, messageID: messageID, userID: userID, emoji: "🔥", kind: .normal
    ))
    let removed = try #require(await provider.cachedForumPosts[parentID]?[channelID])
    #expect(removed.firstMessage?.reactions.isEmpty == true)
    #expect(removed.mostRecentMessage?.reactions.isEmpty == true)
    await provider.disconnect()
}

private extension DiscordRESTProvider {
    func seedForumReactionProjection(evicts: Bool) {
        let user = User(id: UserID(rawValue: 1), username: "author", displayName: "Author")
        let message = Message(id: MessageID(rawValue: 42), channelID: ChannelID(rawValue: 42), author: user, content: "original")
        cachedMessages = DiscordMessageCache(capacity: 1)
        cachedMessages[message.id] = message
        if evicts {
            let other = Message(id: MessageID(rawValue: 43), channelID: ChannelID(rawValue: 43), author: user, content: "other")
            cachedMessages[other.id] = other
        }
        let thread = MessageThreadSummary(id: ChannelID(rawValue: 42), parentID: ChannelID(rawValue: 7), name: "Post")
        cachedForumPosts[ChannelID(rawValue: 7)] = [thread.id: ForumPost(thread: thread, firstMessage: message, mostRecentMessage: message)]
    }
}

@Test(arguments: [false, true])
func `profile events reconcile retained identities independently of working set eviction`(evicts: Bool) async throws {
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "profile-test"),
        session: URLSession(configuration: .ephemeral)
    )
    await provider.seedForumReactionProjection(evicts: evicts)
    let stream = await provider.eventStream()
    await provider.handleGatewayDispatch(name: "USER_UPDATE", body: .object([
        "id": .string("1"), "username": .string("new"), "global_name": .string("New")
    ]))
    let forum = try #require(await provider.cachedForumPosts[ChannelID(rawValue: 7)]?[ChannelID(rawValue: 42)])
    #expect(forum.firstMessage?.author.displayName == "New")
    #expect(forum.mostRecentMessage?.author.displayName == "New")
    await provider.disconnect()
    var identity: User?
    for await event in stream {
        if case .currentUserChanged(let user) = event { identity = user }
    }
    #expect(identity?.displayName == "New")
}

@Test(arguments: [false, true], ["event", "joined", "forum"])
func `thread mention updates preserve guild avatars after eviction`(evicted: Bool, context: String) async throws {
    let provider = DiscordRESTProvider(credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "audit"), session: URLSession(configuration: .ephemeral))
    let original = await provider.seedMentionThread(evicted: evicted, context: context)
    let stream = await provider.eventStream()
    var body: [String: JSONValue] = [
        "id": .string("42"), "channel_id": .string("42"),
        "mentions": .array([.object([
            "id": .string("2"), "username": .string("mentioned"),
            "member": .object(["nick": .string("Guild Nick"), "avatar": .string("guild-avatar")])
        ])])
    ]
    if context == "event" { body["guild_id"] = .string("7") }
    await provider.handleGatewayDispatch(name: "MESSAGE_UPDATE", body: .object(body))
    await provider.disconnect()
    var resolved = original
    for await event in stream {
        switch event {
        case .messageUpdated(let message): resolved = message
        case .messagePatched(let patch): patch.apply(to: &resolved)
        default: break
        }
    }
    let avatar = resolved.mentionedUsers.first?.avatarURL.absoluteString ?? "nil"
    #expect(avatar.contains("/guilds/7/users/2/avatars/"))
}

private extension DiscordRESTProvider {
    func seedMentionThread(evicted: Bool, context: String) -> Message {
        let user = User(id: UserID(rawValue: 1), username: "audit", displayName: "Audit")
        let thread = MessageThreadSummary(id: ChannelID(rawValue: 42), guildID: GuildID(rawValue: 7), parentID: ChannelID(rawValue: 20), name: "Audit")
        let message = Message(id: MessageID(rawValue: 42), channelID: thread.id, author: user, content: "original", guildID: thread.guildID)
        if context == "joined" { cachedJoinedThreads[thread.id] = thread }
        if context == "forum" {
            cachedForumPosts[thread.parentID!] = [thread.id: ForumPost(thread: thread, firstMessage: message, mostRecentMessage: message)]
        }
        if !evicted { cachedMessages[message.id] = message }
        return message
    }
}
