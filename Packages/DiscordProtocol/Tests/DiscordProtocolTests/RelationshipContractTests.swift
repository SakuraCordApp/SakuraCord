@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

struct RelationshipContractTests {
    private let fixture = RelationshipFixture()

    @Test func `READY, Gateway events and a racing full read reduce to one authoritative record set`() async throws {
        let credentials = RelationshipInterleavingCredentials()
        let (provider, session) = await makeProvider(credentials: credentials)
        defer { session.invalidateAndCancel() }
        await provider.handleGatewayDispatch(name: "READY", body: .object([
            "user": user("1"),
            "users": .array([user("2"), user("3")]),
            "relationships": .array([
                row("2", type: 1, extra: ["nickname": .string("Pal"), "note": .string("Hello 🌸"), "since": .string("2026-03-20T00:00:00+00:00")]),
                row("3", type: 3, extra: ["is_spam_request": .bool(true)]),
                row("4", type: 4),
                row("5", type: 2),
                row("6", type: 9),
            ]),
        ]))
        var records = await provider.cachedRelationships
        #expect(records.mapValues(\.type) == [id(2): .friend, id(3): .incomingRequest, id(4): .outgoingRequest, id(5): .blocked])
        #expect(records[id(3)]?.isSpamRequest == true)
        #expect(await provider.cachedFriendUserIDs == [id(2)])
        #expect(await provider.cachedRelationshipNicknamesByUserID == [id(2): "Pal"])
        // An unhydrated identity keeps its record.
        #expect(await provider.publishedRelationships().first { $0.id == id(4) }?.user == nil)

        // Accepting an outgoing request upgrades it in place and hydrates the user.
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_ADD", body: row("4", type: 1, extra: [
            "user": user("4"), "since": .string("2026-10-08T16:47:52.986000+00:00"),
        ]))
        // An add keeps metadata it omits; an update replaces it.
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_ADD", body: row("2", type: 1))
        #expect(await provider.cachedRelationships[id(2)]?.nickname == "Pal")
        #expect(await provider.publishedRelationships().first { $0.id == id(2) }?.note == "Hello 🌸")
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_UPDATE", body: row("2", type: 1))
        records = await provider.cachedRelationships
        #expect(records[id(2)]?.nickname == nil)
        #expect(records[id(2)]?.since == nil)
        #expect(records[id(2)]?.note == nil)
        #expect(records[id(4)]?.type == .friend)
        #expect(records[id(4)]?.since != nil)
        #expect(await provider.publishedRelationships().first { $0.id == id(4) }?.user?.username == "user4")
        let knownFriend = try JSONValueDecoder().decode(UserDTO.self, from: user("4"))
        await provider.cacheLiveSearchUsers([knownFriend])
        #expect(await provider.currentKnownUsers().contains { $0.id == id(4) })
        // Blocking replaces a friendship without a preceding removal.
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_ADD", body: row("4", type: 2))
        #expect(await provider.cachedRelationships[id(4)]?.type == .blocked)
        #expect(await provider.cachedBlockedOrIgnoredUserIDs == [id(4), id(5)])
        #expect(await !provider.currentKnownUsers().contains { $0.id == id(4) })
        #expect(await provider.cachedFriendUserIDs == [id(2)])

        // Gateway removes 2 while the full read is in flight: its older row
        // must not resurrect it. Unchanged records follow the read.
        await credentials.interleave {
            await provider.handleGatewayDispatch(name: "RELATIONSHIP_REMOVE", body: row("2", type: 1))
        }
        fixture.relationships.withLock {
            $0 = """
            [{"id":"2","type":1,"nickname":"Stale","user":{"id":"2","username":"user2"}},
             {"id":"3","type":3,"is_spam_request":false,"user":{"id":"3","username":"renamed3"}},
             {"id":"7","type":3,"user":{"id":"7","username":"user7"}}]
            """
        }
        try await provider.loadRelationships()
        records = await provider.cachedRelationships
        #expect(records.mapValues(\.type) == [id(3): .incomingRequest, id(7): .incomingRequest])
        #expect(records[id(3)]?.isSpamRequest == false)
        #expect(await provider.cachedBlockedOrIgnoredUserIDs.isEmpty)
        #expect(await provider.publishedRelationships().first { $0.id == id(3) }?.user?.username == "renamed3")
        // At most once per Gateway connection; READY makes it eligible again.
        try await provider.loadRelationships()
        #expect(requests(method: "GET").count == 1)
        await provider.handleGatewayDispatch(name: "READY", body: .object(["user": user("1"), "relationships": .array([])]))
        try await provider.loadRelationships()
        #expect(requests(method: "GET").count == 2)
        #expect(requests(method: "GET").allSatisfy { $0.url?.path == "/api/v9/users/@me/relationships" })
        #expect(await !provider.requestSafetyCircuitIsOpen)
        await provider.disconnect()
    }

    @Test(arguments: ["relationship", "nickname", "identity"])
    func `older full reads preserve newer relationship metadata and user identities`(change: String) async throws {
        let credentials = RelationshipInterleavingCredentials()
        let (provider, session) = await makeProvider(credentials: credentials)
        defer { session.invalidateAndCancel() }
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_ADD", body: row("2", type: 1, extra: [
            "user": user("2"), "nickname": .string("Old"),
        ]))
        let renamed: JSONValue = .object(["id": .string("2"), "username": .string("newname")])
        let renamedDTO = try JSONValueDecoder().decode(UserDTO.self, from: renamed)
        await credentials.interleave {
            switch change {
            case "relationship":
                await provider.handleGatewayDispatch(name: "RELATIONSHIP_UPDATE", body: .object([
                    "id": .string("2"), "type": .number(1), "user": renamed, "nickname": .string("Saved"),
                ]))
            case "nickname":
                do {
                    _ = try await provider.setFriendNickname("Saved", for: UserID(rawValue: 2))
                } catch {
                    Issue.record(error)
                }
            default:
                await provider.cacheLiveSearchUsers([renamedDTO])
            }
        }
        fixture.relationships.withLock {
            $0 = #"[{"id":"2","type":1,"nickname":"Old","user":{"id":"2","username":"user2"}}]"#
        }
        try await provider.loadRelationships()
        let relationship = try #require(await provider.publishedRelationships().first { $0.id == id(2) })
        #expect(relationship.nickname == (change == "identity" ? "Old" : "Saved"))
        #expect(relationship.user?.username == (change == "nickname" ? "user2" : "newname"))
        await provider.disconnect()
    }

    @Test(arguments: [false, true])
    func `live user changes publish renamed or newly hydrated Friends`(startsHydrated: Bool) async throws {
        let (provider, session) = await makeProvider()
        defer { session.invalidateAndCancel() }
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_ADD", body: row("2", type: 1,
            extra: startsHydrated ? ["user": user("2")] : [:]))
        await provider.relationshipUserPublicationTask?.value
        let events = SessionEventBuffer<ClientEvent>(overflowEvent: .connectionChanged(.disconnected))
        await provider.installRelationshipTestEvents(events)
        let renamed: JSONValue = .object(["id": .string("2"), "username": .string("renamed"), "global_name": .string("New Name")])
        // A persisted search identity does not hydrate the Friends record.
        let cachedUser = try JSONValueDecoder().decode(UserDTO.self, from: renamed)
        _ = await provider.cacheForwardSearchMessageUsers([cachedUser])
        await provider.handleGatewayDispatch(name: "GUILD_MEMBER_UPDATE", body: .object([
            "guild_id": .string("100"), "roles": .array([]),
            "user": renamed,
        ]))
        await provider.relationshipUserPublicationTask?.value
        events.finish()
        var published: [Relationship] = []
        for await event in events.stream {
            if case .relationshipsChanged(let value) = event { published = value }
        }
        #expect(published.first { $0.id == id(2) }?.user?.displayName == "New Name")
        #expect(published.first { $0.id == id(2) }?.user?.username == "renamed")
        await provider.disconnect()
    }

    @Test func `relationship mutations use Discord's routes, bodies and context once each`() async throws {
        let (provider, session) = await makeProvider()
        defer { session.invalidateAndCancel() }
        try await provider.sendFriendRequest(username: "example", discriminator: nil, captchaHandler: nil)
        try await provider.sendFriendRequest(username: "legacy", discriminator: 42, note: "  Hello\n🌸  ", captchaHandler: nil)
        try await provider.acceptFriendRequest(from: id(2), confirmingStranger: false, captchaHandler: nil)
        try await provider.removeRelationship(with: id(3), as: .removeFriend)
        try await provider.removeRelationship(with: id(4), as: .unblock)
        try await provider.blockUser(id(5))
        // Another session already removed this one.
        try await provider.removeRelationship(with: id(404), as: .cancelOutgoingRequest)
        let captured = fixture.requests.withLock { $0 }
        #expect(captured.map { "\($0.request.httpMethod!) \($0.request.url!.path)" } == [
            "POST /api/v9/users/@me/relationships", "POST /api/v9/users/@me/relationships",
            "PUT /api/v9/users/@me/relationships/2", "DELETE /api/v9/users/@me/relationships/3",
            "DELETE /api/v9/users/@me/relationships/4", "PUT /api/v9/users/@me/relationships/5",
            "DELETE /api/v9/users/@me/relationships/404",
        ])
        #expect(captured.map(\.body) == [
            .object(["username": .string("example"), "discriminator": .null]),
            .object(["username": .string("legacy"), "discriminator": .number(42), "note": .string("Hello 🌸")]),
            .object(["confirm_stranger_request": .bool(false)]), nil, nil,
            .object(["type": .number(2)]), nil,
        ])
        #expect(captured.map { context($0.request) } == ["Add Friend", "Add Friend", "Friends", "Friends", nil, "ContextMenu", "Friends"])
        #expect(captured.allSatisfy { $0.request.value(forHTTPHeaderField: "X-Captcha-Key") == nil })
        #expect(await !provider.requestSafetyCircuitIsOpen)
        await provider.disconnect()
    }

    @Test func `explained friend request failures stay scoped to the action and are never replayed`() async throws {
        let (provider, session) = await makeProvider()
        defer { session.invalidateAndCancel() }
        await #expect(throws: RelationshipActionError.failed("You’re already friends with that user!")) {
            try await provider.sendFriendRequest(username: "already", discriminator: nil, captchaHandler: nil)
        }
        await #expect(throws: RelationshipActionError.failed("closed is not accepting friend requests. They’ll have to add you to become friends.")) {
            try await provider.sendFriendRequest(username: "closed", discriminator: nil, captchaHandler: nil)
        }
        await #expect(throws: RelationshipActionError.failed("You’re sending friend requests too quickly!")) {
            try await provider.sendFriendRequest(username: "limited", discriminator: nil, captchaHandler: nil)
        }
        // Stranger confirmation is explicit: only a confirmed retry sends true.
        await #expect(throws: RelationshipActionError.strangerConfirmationRequired) {
            try await provider.acceptFriendRequest(from: id(813), confirmingStranger: false, captchaHandler: nil)
        }
        try await provider.acceptFriendRequest(from: id(813), confirmingStranger: true, captchaHandler: nil)
        let captured = fixture.requests.withLock { $0 }
        #expect(captured.count == 5)
        #expect(captured.suffix(2).map(\.body) == [
            .object(["confirm_stranger_request": .bool(false)]), .object(["confirm_stranger_request": .bool(true)]),
        ])
        #expect(await !provider.requestSafetyCircuitIsOpen)
        // Account restrictions keep the shared safety boundary.
        #expect(DiscordRESTProvider.isSafetyStop(status: 400, discordCode: 40068, method: "POST", data: Data(), path: "/users/@me/relationships"))
        #expect(!DiscordRESTProvider.isSafetyStop(status: 400, discordCode: 80007, method: "POST", data: Data(), path: "/users/@me/relationships"))
        #expect(DiscordRESTProvider.isSafetyStop(status: 400, discordCode: 80007, method: "POST", data: Data(), path: "/channels/1/messages"))
        await provider.disconnect()
    }

    @Test func `request note limits use UTF16 and reject before sending`() async throws {
        let (provider, session) = await makeProvider()
        defer { session.invalidateAndCancel() }
        #expect(try FriendRequestNote.normalized(String(repeating: "🌸", count: 60))?.utf16.count == 120)
        #expect(try FriendRequestNote.normalized(" \n ") == nil)
        await #expect(throws: RelationshipActionError.self) {
            try await provider.sendFriendRequest(username: "example", discriminator: nil,
                                                 note: String(repeating: "🌸", count: 61), captchaHandler: nil)
        }
        #expect(requests(method: "POST").isEmpty)
        await provider.disconnect()
    }

    @Test(arguments: ["hcaptcha", "recaptcha", "recaptcha_enterprise", "turnstile"])
    func `a friend request challenge is solved by a human once and replays the original request`(service: String) async throws {
        let (provider, session) = await makeProvider()
        defer { session.invalidateAndCancel() }
        try await provider.sendFriendRequest(username: "captcha-\(service)", discriminator: nil, note: "Hello 🌸") { challenge in
            #expect(challenge.service.rawValue == service)
            #expect(challenge.siteKey == "site-key")
            #expect(challenge.userFlow == "friend_request")
            #expect(await !provider.requestSafetyCircuitIsOpen)
            return "human-solution"
        }
        let captured = fixture.requests.withLock { $0 }
        #expect(captured.count == 2)
        let original = captured[0], replay = captured[1]
        #expect(original.request.url == replay.request.url)
        #expect(original.body == replay.body)
        #expect(context(original.request) == "Add Friend" && context(replay.request) == "Add Friend")
        #expect(original.request.value(forHTTPHeaderField: "X-Captcha-Key") == nil)
        #expect(replay.request.value(forHTTPHeaderField: "X-Captcha-Key") == "human-solution")
        #expect(replay.request.value(forHTTPHeaderField: "X-Captcha-Rqtoken") == "request-token")
        #expect(replay.request.value(forHTTPHeaderField: "X-Captcha-Session-Id") == "captcha-session")
        #expect(await !provider.requestSafetyCircuitIsOpen)
        await provider.disconnect()
    }

    @Test
    func `blocking presents the human challenge and preserves its original context`() async throws {
        let (provider, session) = await makeProvider()
        defer { session.invalidateAndCancel() }
        try await provider.blockUser(id(990)) { challenge in
            #expect(challenge.service == .hcaptcha)
            return "human-solution"
        }
        let captured = fixture.requests.withLock { $0 }
        #expect(captured.count == 2)
        #expect(captured.allSatisfy { $0.request.httpMethod == "PUT" && context($0.request) == "ContextMenu" })
        #expect(captured.allSatisfy { $0.body == .object(["type": .number(2)]) })
        #expect(captured.last?.request.value(forHTTPHeaderField: "X-Captcha-Key") == "human-solution")
        await provider.disconnect()
    }

    @Test(arguments: ["cancel", "empty", "repeated", "noHandler", "accountChanged"])
    func `cancelled, rejected or stale friend challenges never loop or cross accounts`(outcome: String) async throws {
        let (provider, session) = await makeProvider()
        defer { session.invalidateAndCancel() }
        let username = outcome == "repeated" ? "captcha-repeated" : "captcha-hcaptcha"
        let handler: DiscordCaptchaHandler = { _ in
            if outcome == "cancel" { throw CancellationError() }
            if outcome == "accountChanged" { await provider.replaceCurrentUser() }
            return outcome == "empty" ? " " : "human-solution"
        }
        await #expect(throws: (any Error).self) {
            try await provider.sendFriendRequest(username: username, discriminator: nil, captchaHandler: outcome == "noHandler" ? nil : handler)
        }
        #expect(fixture.requests.withLock { $0.count } == (outcome == "repeated" ? 2 : 1))
        #expect(await !provider.requestSafetyCircuitIsOpen)
        // Unknown services and other routes keep the safety boundary.
        let challenge = Data(RelationshipURLProtocol.challenge(service: "hcaptcha").utf8)
        let unknown = Data(RelationshipURLProtocol.challenge(service: "unknown").utf8)
        #expect(!DiscordRESTProvider.isSafetyStop(status: 400, discordCode: nil, method: "PUT", data: challenge, path: "/users/@me/relationships/2"))
        #expect(DiscordRESTProvider.isSafetyStop(status: 400, discordCode: nil, method: "POST", data: unknown, path: "/users/@me/relationships"))
        #expect(DiscordRESTProvider.isSafetyStop(status: 400, discordCode: nil, method: "PATCH", data: challenge, path: "/users/@me/relationships/2"))
        await provider.disconnect()
    }

    private func id(_ value: UInt64) -> UserID { UserID(rawValue: value) }

    private func user(_ id: String) -> JSONValue {
        .object(["id": .string(id), "username": .string("user\(id)")])
    }

    private func row(_ id: String, type: Int, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["id": .string(id), "type": .number(Double(type))].merging(extra) { _, new in new })
    }

    private func requests(method: String) -> [URLRequest] {
        fixture.requests.withLock { $0.map(\.request).filter { $0.httpMethod == method } }
    }

    private func context(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "X-Context-Properties")
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["location"]
    }

    private func makeProvider(credentials: any CredentialStore = TestCredentialStore()) async -> (DiscordRESTProvider, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelationshipURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: fixture, delegateQueue: nil)
        let provider = DiscordRESTProvider(credentials: credentials, handle: CredentialHandle(accountID: "relationships"), session: session)
        await provider.replaceCurrentUser(id: 1)
        return (provider, session)
    }
}

private extension DiscordRESTProvider {
    func installRelationshipTestEvents(_ events: SessionEventBuffer<ClientEvent>) { continuation = events }

    func replaceCurrentUser(id: UInt64 = 99) {
        currentUser = User(id: .init(rawValue: id), username: "fixture\(id)", displayName: "Fixture")
    }
}

private actor RelationshipInterleavingCredentials: CredentialStore {
    private let base = TestCredentialStore()
    private var action: (@Sendable () async -> Void)?

    func interleave(_ action: @escaping @Sendable () async -> Void) { self.action = action }
    func credential(for handle: CredentialHandle) async throws -> Data {
        let pending = action
        action = nil
        await pending?()
        return try await base.credential(for: handle)
    }
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        try await base.store(credential, accountID: accountID)
    }
    func remove(_ handle: CredentialHandle) async throws { try await base.remove(handle) }
    func handles() async throws -> [CredentialHandle] { try await base.handles() }
}

private final class RelationshipFixture: NSObject, URLSessionTaskDelegate {
    let requests = Mutex<[RelationshipURLProtocol.Captured]>([])
    let relationships = Mutex("[]")

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        task.delegate = self
    }
}

private final class RelationshipURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        let request: URLRequest
        let body: JSONValue?
    }

    static func challenge(service: String) -> String {
        """
        {"captcha_key":["captcha-required"],"captcha_service":"\(service)","captcha_sitekey":"site-key",
         "captcha_rqtoken":"request-token","captcha_session_id":"captcha-session","user_flow":"friend_request"}
        """
    }

    override static func canInit(with task: URLSessionTask) -> Bool { true }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = task?.delegate as? RelationshipFixture else {
            Issue.record("Relationship transport is missing its test-owned fixture")
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let body = decodedRequestBody()
        fixture.requests.withLock { $0.append(Captured(request: request, body: body)) }
        let solved = request.value(forHTTPHeaderField: "X-Captcha-Key") != nil
        var username: String?
        if case let .object(fields)? = body, case let .string(value)? = fields["username"] { username = value }
        let lastComponent = request.url!.lastPathComponent
        let (status, response): (Int, String) = switch (request.httpMethod!, username, lastComponent) {
        case ("GET", _, _): (200, fixture.relationships.withLock { $0 })
        case (_, "already"?, _): (400, #"{"code":80007,"message":"You are already friends with that user."}"#)
        case (_, "closed"?, _): (400, #"{"code":80000,"message":"Incoming friend requests disabled."}"#)
        case (_, "limited"?, _): (429, #"{"retry_after":0.01,"global":false}"#)
        case (_, "captcha-repeated"?, _): (400, Self.challenge(service: "hcaptcha"))
        case (_, let name?, _) where name.hasPrefix("captcha-") && !solved:
            (400, Self.challenge(service: String(name.dropFirst("captcha-".count))))
        case ("PUT", _, "990") where !solved: (400, Self.challenge(service: "hcaptcha"))
        case ("PUT", _, "813") where body == .object(["confirm_stranger_request": .bool(false)]):
            (400, #"{"code":80013,"message":"Confirmation required"}"#)
        case ("DELETE", _, "404"): (404, #"{"code":10013,"message":"Unknown User"}"#)
        default: (204, "")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                             headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        if !response.isEmpty { client?.urlProtocol(self, didLoad: Data(response.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func decodedRequestBody() -> JSONValue? {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    override func stopLoading() {}
}
