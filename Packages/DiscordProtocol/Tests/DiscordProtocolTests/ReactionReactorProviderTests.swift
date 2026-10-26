@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Suite(.serialized)
struct ReactionReactorProviderTests {
    @Test func `reaction details page every distinct normal and super reactor without expanding previews`() async throws {
        ReactionReactorURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReactionReactorURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: ReactionReactorCredentialStore(), handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
        let first = try await provider.reactionUsers(
            for: "<a:party_blob:123>", messageID: MessageID(rawValue: 301), channelID: ChannelID(rawValue: 200), after: nil, limit: 999
        )
        #expect(first.users.map(\.id.rawValue) == Array(UInt64(1) ... 100))
        #expect(first.hasMore)
        #expect(ReactionReactorURLProtocol.requestCount == 2)
        #expect(ReactionReactorURLProtocol.limit == "100")
        #expect(ReactionReactorURLProtocol.type == "1")
        #expect(ReactionReactorURLProtocol.path.hasSuffix("/channels/200/messages/301/reactions/party_blob:123"))
        let second = try await provider.reactionUsers(
            for: "<:renamed_blob:123>", messageID: MessageID(rawValue: 301), channelID: ChannelID(rawValue: 200), after: first.users.last?.id, limit: 100
        )
        #expect(second.users.map(\.id.rawValue) == Array(UInt64(101) ... 107))
        #expect(!second.hasMore)
        #expect(ReactionReactorURLProtocol.requestCount == 4)
        let preview = try await provider.reactionReactors(
            for: "<:renamed_blob:123>", messageID: MessageID(rawValue: 301), channelID: ChannelID(rawValue: 200), reactionCount: 107
        )
        #expect(preview.count == 5)
        #expect(ReactionReactorURLProtocol.limit == "5")
        #expect(ReactionReactorURLProtocol.type == "0")
        await provider.disconnect()
    }

    @Test func `reactor reads use the documented bounded contract and coalesce by reaction state`() async throws {
        ReactionReactorURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReactionReactorURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: ReactionReactorCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )

        async let first = provider.reactionReactors(
            for: "<:party_blob:123>",
            messageID: MessageID(rawValue: 300),
            channelID: ChannelID(rawValue: 200),
            reactionCount: 8
        )
        async let second = provider.reactionReactors(
            for: "<:party_blob:123>",
            messageID: MessageID(rawValue: 300),
            channelID: ChannelID(rawValue: 200),
            reactionCount: 8
        )
        let values = try await (first, second)

        #expect(values.0 == values.1)
        #expect(values.0.count == 5)
        #expect(values.0.map(\.displayName) == ["One", "Two", "Three", "Four", "Five"])
        #expect(ReactionReactorURLProtocol.requestCount == 1)
        #expect(ReactionReactorURLProtocol.method == "GET")
        #expect(ReactionReactorURLProtocol.type == "0")
        #expect(ReactionReactorURLProtocol.limit == "5")
        #expect(ReactionReactorURLProtocol.hadAuthorization)
        #expect(ReactionReactorURLProtocol.path.hasSuffix(
            "/channels/200/messages/300/reactions/party_blob:123"
        ))

        _ = try await provider.reactionReactors(
            for: "<a:renamed_blob:123>",
            messageID: MessageID(rawValue: 300),
            channelID: ChannelID(rawValue: 200),
            reactionCount: 8
        )
        #expect(ReactionReactorURLProtocol.requestCount == 1)

        _ = try await provider.reactionReactors(
            for: "<:party_blob:123>",
            messageID: MessageID(rawValue: 300),
            channelID: ChannelID(rawValue: 200),
            reactionCount: 9
        )
        #expect(ReactionReactorURLProtocol.requestCount == 2)
    }

    @Test func `nonpositive reaction counts never produce a request`() async throws {
        ReactionReactorURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReactionReactorURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: ReactionReactorCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )

        let reactors = try await provider.reactionReactors(
            for: "✅",
            messageID: MessageID(rawValue: 300),
            channelID: ChannelID(rawValue: 200),
            reactionCount: 0
        )
        #expect(reactors.isEmpty)
        #expect(ReactionReactorURLProtocol.requestCount == 0)
    }

    @Test func `reaction changes invalidate pending and same-count cached previews`() async throws {
        ReactionReactorURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReactionReactorURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: ReactionReactorCredentialStore(), handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
        let received = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer {
            received.continuation.finish()
            release.continuation.finish()
        }
        await provider.setReactorResponseGate {
            received.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let first = Task {
            try await provider.reactionReactors(
                for: "👍", messageID: MessageID(rawValue: 300), channelID: ChannelID(rawValue: 200), reactionCount: 2
            )
        }
        var iterator = received.stream.makeAsyncIterator()
        _ = await iterator.next()
        let unaffected = Task {
            try await provider.reactionReactors(
                for: "✅", messageID: MessageID(rawValue: 300), channelID: ChannelID(rawValue: 200), reactionCount: 2
            )
        }
        _ = await iterator.next()
        let removed = MessageReactionUpdate.remove(
            channelID: ChannelID(rawValue: 200), messageID: MessageID(rawValue: 300),
            userID: UserID(rawValue: 1), emoji: "👍", kind: .normal
        )
        await provider.receiveGatewayReactionForTesting(removed)
        release.continuation.finish()
        await #expect(throws: CancellationError.self) { try await first.value }
        let retained = try await unaffected.value
        #expect(retained.count == 5)
        #expect(await provider.cachedReactionReactors.keys.map(\.emojiIdentity) == ["unicode:✅"])
        #expect(await provider.reactionReactorTasks.isEmpty)

        _ = try await provider.reactionReactors(
            for: "👍", messageID: MessageID(rawValue: 300), channelID: ChannelID(rawValue: 200), reactionCount: 2
        )
        #expect(ReactionReactorURLProtocol.requestCount == 3)
        _ = try await provider.reactionReactors(
            for: "✅", messageID: MessageID(rawValue: 300), channelID: ChannelID(rawValue: 200), reactionCount: 2
        )
        #expect(ReactionReactorURLProtocol.requestCount == 3)
        await provider.receiveGatewayReactionForTesting(removed)
        _ = try await provider.reactionReactors(
            for: "👍", messageID: MessageID(rawValue: 300), channelID: ChannelID(rawValue: 200), reactionCount: 2
        )
        #expect(ReactionReactorURLProtocol.requestCount == 4)
        await provider.receiveGatewayReactionForTesting(.removeAll(
            channelID: ChannelID(rawValue: 200), messageID: MessageID(rawValue: 300)
        ))
        #expect(await provider.cachedReactionReactors.isEmpty)
        await provider.disconnect()
    }
}

private extension DiscordRESTProvider {
    func setReactorResponseGate(_ callback: @escaping @Sendable () async -> Void) {
        reactorResponseReceivedForTesting = callback
    }
}

private actor ReactionReactorCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("reaction-test-session".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        [CredentialHandle(accountID: "1")]
    }
}

private final class ReactionReactorURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var method: String?
    nonisolated(unsafe) static var type: String?
    nonisolated(unsafe) static var limit: String?
    nonisolated(unsafe) static var hadAuthorization = false
    nonisolated(unsafe) static var path = ""

    static func reset() {
        requestCount = 0
        method = nil
        type = nil
        limit = nil
        hadAuthorization = false
        path = ""
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
        let queryItems = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
        }
        Self.type = queryItems?.first(where: { $0.name == "type" })?.value
        Self.limit = queryItems?.first(where: { $0.name == "limit" })?.value
        Self.hadAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil

        var users = """
        [
          {"id":"1","username":"one","global_name":"One","avatar":"avatar-one"},
          {"id":"2","username":"two","global_name":"Two","avatar":null},
          {"id":"3","username":"three","global_name":"Three","avatar":null},
          {"id":"4","username":"four","global_name":"Four","avatar":null},
          {"id":"5","username":"five","global_name":"Five","avatar":null}
        ]
        """
        if Self.path.contains("/messages/301/") {
            let after = UInt64(queryItems?.first(where: { $0.name == "after" })?.value ?? "0") ?? 0
            let limit = Int(Self.limit ?? "100") ?? 100
            // Neither stream fills 100 slots; their merged suffix still needs a second page.
            let ids: [UInt64] = Self.type == "1" ? [3] + Array(71 ... 107) : Array(1 ... 70)
            let page = ids.filter { $0 > after }.prefix(limit).map {
                #"{"id":"\#($0)","username":"user\#($0)"}"#
            }
            users = "[\(page.joined(separator: ","))]"
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(users.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
