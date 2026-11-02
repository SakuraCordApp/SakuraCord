@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

/// Thread rename, membership, message-thread and browser contracts, following
/// the official client (web build 641004, observed 19 October 2026).
struct ThreadActionContractTests {
    private let fixture = ThreadActionFixture()
    private let parent = Channel(
        id: ChannelID(rawValue: 7), guildID: GuildID(rawValue: 1), name: "general",
        defaultAutoArchiveDuration: 1_440
    )

    @Test func `rename sends only the name after unarchiving and keeps a membership change made meanwhile`() async throws {
        let provider = await makeProvider(joined: true, archived: true)
        let archived = ForumPost(thread: thread(isArchived: true, joined: true))
        let gate = StatusRecoveryResponseGate()
        fixture.enqueue(threadJSON(name: "Old name", archived: false))
        // Discord's response still carries the member it had when it answered.
        fixture.enqueue(threadJSON(name: "New name", archived: false, joined: true), gate: gate)

        let rename = Task { try await provider.updateForumPost(archived, mutation: .name("  New name ")) }
        #expect(await eventually { gate.didCapture })
        // Leaving elsewhere while the name PATCH is pending; its response has no member.
        await provider.receiveGatewayDispatchForTesting(name: "THREAD_MEMBERS_UPDATE", data: removal)
        gate.release()
        let renamed = try await rename.value

        #expect(renamed.thread.name == "New name" && !renamed.thread.isArchived)
        #expect(renamed.thread.notificationSettings == nil)
        #expect(await provider.cachedForumPostForTesting(threadID: archived.id)?.thread.notificationSettings == nil)
        #expect(fixture.requests.withLock { $0.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } }
            == ["PATCH /api/v9/channels/42", "PATCH /api/v9/channels/42"])
        #expect(fixture.bodies.withLock { $0 } == [
            .object(["archived": .bool(false)]), .object(["name": .string("New name")]),
        ])
        #expect(await provider.cachedForumPostForTesting(threadID: archived.id)?.thread.name == "New name")
        await #expect(throws: ChatProviderError.self) {
            _ = try await provider.updateForumPost(renamed, mutation: .name(" \n "))
        }
        #expect(fixture.requests.withLock { $0.count } == 2)
        await provider.disconnect()
    }

    @Test(arguments: [false, true])
    func `a rename answered after a deletion does not restore the thread`(succeeds: Bool) async throws {
        let provider = await makeProvider(archived: true)
        let gate = StatusRecoveryResponseGate()
        fixture.enqueue(threadJSON(name: "Old name", archived: false))
        if succeeds {
            fixture.enqueue(threadJSON(name: "New", archived: false), gate: gate)
        } else {
            fixture.enqueue(#"{"code":10003,"message":"Unknown Channel"}"#, status: 404, gate: gate)
        }

        let rename = Task {
            try await provider.updateForumPost(ForumPost(thread: thread(isArchived: true)), mutation: .name("New"))
        }
        #expect(await eventually { gate.didCapture })
        await provider.receiveGatewayDispatchForTesting(name: "THREAD_DELETE", data: .object([
            "id": .string("42"), "guild_id": .string("1"), "parent_id": .string("7"), "type": .number(11),
        ]))
        gate.release()

        await #expect(throws: ChatProviderError.self) { _ = try await rename.value }
        #expect(await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 42)) == nil)
        await provider.disconnect()
    }

    @Test func `join posts, leave deletes, and a delayed leave cannot undo a newer join`() async throws {
        let provider = await makeProvider()
        let threadID = ChannelID(rawValue: 42)
        let gate = StatusRecoveryResponseGate()
        fixture.enqueue("")
        fixture.enqueue("", gate: gate)
        fixture.enqueue("")

        try await provider.setThreadMembership(threadID: threadID, isJoined: true, location: .sidePaneMenu)
        #expect(await provider.activeJoinedThreadsForTesting().map(\.id) == [threadID])
        let leave = Task { try await provider.setThreadMembership(threadID: threadID, isJoined: false, location: .fullViewMenu) }
        #expect(await eventually { gate.didCapture })
        await provider.receiveGatewayDispatchForTesting(name: "THREAD_MEMBERS_UPDATE", data: removal)
        #expect(await provider.activeJoinedThreadsForTesting().isEmpty)
        try await provider.setThreadMembership(threadID: threadID, isJoined: true, location: .contextMenu)
        gate.release()
        try await leave.value

        #expect(await provider.activeJoinedThreadsForTesting().map(\.id) == [threadID])
        let requests = fixture.requests.withLock { $0 }
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "")" } == [
            "POST https://discord.com/api/v9/channels/42/thread-members/@me?location=Sidebar%20Overflow",
            "DELETE https://discord.com/api/v9/channels/42/thread-members/@me?location=Toolbar%20Overflow",
            "POST https://discord.com/api/v9/channels/42/thread-members/@me?location=Context%20Menu",
        ])
        #expect(fixture.bodies.withLock { $0.isEmpty })
        await provider.disconnect()
    }

    @Test func `a lookup overlapping a confirmed leave cannot restore the membership`() async throws {
        let provider = await makeProvider(joined: true)
        let threadID = ChannelID(rawValue: 42)
        let leaveGate = StatusRecoveryResponseGate()
        let lookupGate = StatusRecoveryResponseGate()
        fixture.enqueue("", gate: leaveGate)
        fixture.enqueue(threadJSON(name: "Old name", archived: false, joined: true), gate: lookupGate)

        let leave = Task { try await provider.setThreadMembership(threadID: threadID, isJoined: false, location: .sidePaneMenu) }
        #expect(await eventually { leaveGate.didCapture })
        let lookup = Task { try await provider.resolveThreadAccess(threadID: threadID) }
        #expect(await eventually { lookupGate.didCapture })
        leaveGate.release()
        try await leave.value
        lookupGate.release()
        _ = try await lookup.value

        #expect(await provider.cachedForumPostForTesting(threadID: threadID)?.thread.notificationSettings == nil)
        #expect(await provider.activeJoinedThreadsForTesting().isEmpty)
        await provider.disconnect()
    }

    @Test func `a delayed browser page keeps deletions, newer records and membership removals`() async throws {
        let provider = await makeProvider(joined: true)
        let gate = StatusRecoveryResponseGate()
        let page = #"{"threads":[\#(threadJSON(name: "Old name", archived: true, joined: true)),"#
            + #"\#(threadJSON(id: "60", name: "Deleted", archived: true)),"#
            + #"\#(threadJSON(id: "61", name: "Archived", archived: true))],"has_more":true,"total_results":30}"#
        fixture.enqueue(page, gate: gate)

        let browse = Task { try await provider.threadBrowserPage(in: parent.id, query: ThreadBrowserQuery()) }
        #expect(await eventually { gate.didCapture })
        await provider.receiveGatewayDispatchForTesting(name: "THREAD_MEMBERS_UPDATE", data: removal)
        await provider.receiveGatewayDispatchForTesting(name: "THREAD_DELETE", data: .object([
            "id": .string("60"), "guild_id": .string("1"), "parent_id": .string("7"), "type": .number(11),
        ]))
        await provider.receiveGatewayDispatchForTesting(name: "THREAD_UPDATE", data: .object([
            "id": .string("61"), "guild_id": .string("1"), "parent_id": .string("7"), "type": .number(11),
            "name": .string("Reopened"), "thread_metadata": .object(["archived": .bool(false)]),
        ]))
        gate.release()
        let result = try await browse.value

        #expect(result.posts.map(\.id) == [ChannelID(rawValue: 42), ChannelID(rawValue: 61)])
        #expect(result.posts.first?.thread.notificationSettings == nil)
        #expect(result.posts.last?.thread.name == "Reopened" && result.posts.last?.thread.isArchived == false)
        #expect(await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 60)) == nil)
        #expect(result.nextOffset == 3)
        await provider.disconnect()
    }

    @Test func `a read during a leave cannot cancel the leave's confirmation`() async throws {
        let provider = await makeProvider(joined: true)
        let gate = StatusRecoveryResponseGate()
        fixture.enqueue("", gate: gate)
        fixture.enqueue(#"{"threads":[\#(threadJSON(name: "Old name", archived: false, joined: true))],"has_more":false}"#)

        let leave = Task {
            try await provider.setThreadMembership(threadID: ChannelID(rawValue: 42), isJoined: false, location: .sidePaneMenu)
        }
        #expect(await eventually { gate.didCapture })
        // The server still reports the member, with a join time unlike the cached one.
        _ = try await provider.threadBrowserPage(in: parent.id, query: ThreadBrowserQuery(scope: .search("Old")))
        gate.release()
        try await leave.value

        #expect(await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 42))?.thread.notificationSettings == nil)
        #expect(await provider.activeJoinedThreadsForTesting().isEmpty)
        await provider.disconnect()
    }

    @Test func `a create response after the thread was deleted fails instead of restoring it`() async throws {
        let provider = await makeProvider(seedsThread: false)
        let starter = Message(
            id: MessageID(rawValue: 500), channelID: parent.id,
            author: User(id: UserID(rawValue: 3), username: "author", displayName: "Author"),
            content: "Release notes", guildID: parent.guildID
        )
        await provider.seedMessageForTesting(starter)
        let gate = StatusRecoveryResponseGate()
        fixture.enqueue(threadJSON(id: "500", name: "Release notes", archived: false, joined: true), gate: gate)

        let create = Task { try await provider.createThread(.startingFrom(starter, in: parent)) }
        #expect(await eventually { gate.didCapture })
        await provider.receiveGatewayDispatchForTesting(name: "THREAD_DELETE", data: .object([
            "id": .string("500"), "guild_id": .string("1"), "parent_id": .string("7"), "type": .number(11),
        ]))
        gate.release()

        await #expect(throws: ChatProviderError.self) { _ = try await create.value }
        #expect(await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 500)) == nil)
        #expect(await provider.cachedMessageForTesting(messageID: starter.id)?.thread == nil)
        #expect(await provider.activeJoinedThreadsForTesting().isEmpty)
        await provider.disconnect()
    }

    @Test func `a message thread posts the first-party body and gives its starter a thread card`() async throws {
        let provider = await makeProvider(seedsThread: false)
        let starter = Message(
            id: MessageID(rawValue: 500), channelID: parent.id,
            author: User(id: UserID(rawValue: 3), username: "author", displayName: "Author"),
            content: "Release notes\nmore", guildID: parent.guildID
        )
        await provider.seedMessageForTesting(starter)
        // Discord's starter update precedes the 201 and carries only the flag.
        await provider.receiveGatewayDispatchForTesting(name: "MESSAGE_UPDATE", data: .object([
            "id": .string("500"), "channel_id": .string("7"), "guild_id": .string("1"), "flags": .number(32),
        ]))
        fixture.enqueue(threadJSON(id: "500", name: "Release notes", archived: false, joined: true))

        let thread = try await provider.createThread(.startingFrom(starter, in: parent))

        #expect(thread.id == ChannelID(rawValue: 500) && thread.notificationSettings != nil)
        let request = try #require(fixture.requests.withLock { $0.first })
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://discord.com/api/v9/channels/7/messages/500/threads")
        #expect(fixture.bodies.withLock { $0 } == [.object([
            "name": .string("Release notes"), "type": .number(11),
            "auto_archive_duration": .number(1_440), "location": .string("Message"),
        ])])
        let card = await provider.cachedMessageForTesting(messageID: starter.id)
        #expect(card?.thread?.id == thread.id && card?.flags.contains(.hasThread) == true)
        #expect(await provider.activeJoinedThreadsForTesting().map(\.id) == [thread.id])
        await provider.disconnect()
    }

    @Test func `the thread browser pages archived threads and searches names with first-party queries`() async throws {
        let provider = await makeProvider(seedsThread: false)
        let malformed = #"{"guild_id":"1","parent_id":"7","type":11,"name":"Missing identifier"}"#
        fixture.enqueue(
            #"{"threads":[\#(threadJSON(id: "60", name: "Archived notes", archived: true)),\#(malformed),"#
                + #"\#(threadJSON(id: "61", name: "Old plans", archived: true))],"#
                + #""members":[{"id":"61","user_id":"9","join_timestamp":"2026-10-01T00:00:00+00:00","flags":1}],"#
                + #""has_more":true,"total_results":30}"#,
            #"{"threads":[\#(malformed)],"has_more":true,"total_results":30}"#,
            #"{"threads":[\#(threadJSON(id: "61", name: "Old plans", archived: true))],"has_more":false,"total_results":1}"#
        )

        let page = try await provider.threadBrowserPage(in: parent.id, query: ThreadBrowserQuery())
        // Offsets count raw records, so an undecodable page still continues.
        let skipped = try await provider.threadBrowserPage(in: parent.id, query: ThreadBrowserQuery(scope: .archived(offset: 3)))
        let search = try await provider.threadBrowserPage(in: parent.id, query: ThreadBrowserQuery(scope: .search(" plans ")))

        #expect(page.posts.map(\.thread.name) == ["Archived notes", "Old plans"])
        #expect(page.posts.map { $0.thread.notificationSettings != nil } == [false, true])
        #expect(page.hasMore && page.nextOffset == 3 && page.totalResults == 30)
        #expect(skipped.posts.isEmpty && skipped.hasMore && skipped.nextOffset == 4)
        #expect(search.posts.map(\.id) == [ChannelID(rawValue: 61)] && search.totalResults == 1 && !search.hasMore)
        let archived = "https://discord.com/api/v9/channels/7/threads/search?archived=true"
            + "&sort_by=last_message_time&sort_order=desc&limit=25&tag_setting=match_some&offset="
        let expected: [String] = [
            archived + "0", archived + "3",
            "https://discord.com/api/v9/channels/7/threads/search?name=plans&tag_setting=match_some",
        ]
        #expect(fixture.requests.withLock { $0.map { $0.url?.absoluteString ?? "" } } == expected)
        await provider.disconnect()
    }

    private let removal = JSONValue.object([
        "id": .string("42"), "guild_id": .string("1"), "member_count": .number(0),
        "removed_member_ids": .array([.string("9")]),
    ])

    private func thread(isArchived: Bool, joined: Bool = false) -> MessageThreadSummary {
        MessageThreadSummary(
            id: ChannelID(rawValue: 42), guildID: parent.guildID, parentID: parent.id, name: "Old name",
            isArchived: isArchived, ownerID: UserID(rawValue: 9),
            notificationSettings: joined ? ThreadNotificationSettings() : nil
        )
    }

    private func threadJSON(id: String = "42", name: String, archived: Bool, joined: Bool = false) -> String {
        let member = joined
            ? #","member":{"id":"\#(id)","user_id":"9","join_timestamp":"2026-10-19T00:30:00+00:00","flags":1}"#
            : ""
        return #"{"id":"\#(id)","guild_id":"1","parent_id":"7","type":11,"name":"\#(name)","owner_id":"9","#
            + #""thread_metadata":{"archived":\#(archived),"locked":false,"auto_archive_duration":1440}\#(member)}"#
    }

    private func makeProvider(seedsThread: Bool = true, joined: Bool = false, archived: Bool = false) async -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThreadActionURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "thread-actions"),
            session: URLSession(configuration: configuration, delegate: fixture, delegateQueue: nil)
        )
        await provider.seedForumChannelForTesting(
            parent,
            posts: seedsThread ? [ForumPost(thread: thread(isArchived: archived, joined: joined))] : [],
            currentUser: User(id: UserID(rawValue: 9), username: "me", displayName: "Me")
        )
        return provider
    }
}

private final class ThreadActionFixture: NSObject, URLSessionTaskDelegate {
    let requests = Mutex<[URLRequest]>([])
    let bodies = Mutex<[JSONValue]>([])
    struct Reply {
        var body: String
        var status: Int?
        /// A gated reply is held until the test releases its gate.
        var gate: StatusRecoveryResponseGate?
    }

    let responses = Mutex<[Reply]>([])

    func enqueue(_ bodies: String...) {
        responses.withLock { $0 += bodies.map { Reply(body: $0) } }
    }

    func enqueue(_ body: String, status: Int? = nil, gate: StatusRecoveryResponseGate?) {
        responses.withLock { $0.append(Reply(body: body, status: status, gate: gate)) }
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        task.delegate = self
    }
}

private final class ThreadActionURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with task: URLSessionTask) -> Bool { true }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = task?.delegate as? ThreadActionFixture else {
            Issue.record("Thread transport is missing its test-owned fixture")
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        fixture.requests.withLock { $0.append(request) }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        if !body.isEmpty, let value = try? JSONDecoder().decode(JSONValue.self, from: body) {
            fixture.bodies.withLock { $0.append(value) }
        }
        let next = fixture.responses.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let next else {
            Issue.record("Unexpected request \(request.url?.absoluteString ?? "")")
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let status = next.status ?? (next.body.isEmpty ? 204 : (request.httpMethod == "POST" ? 201 : 200))
        if let gate = next.gate {
            gate.capture { [self] in respond(status: status, body: next.body) }
        } else {
            respond(status: status, body: next.body)
        }
    }

    private func respond(status: Int, body: String) {
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
