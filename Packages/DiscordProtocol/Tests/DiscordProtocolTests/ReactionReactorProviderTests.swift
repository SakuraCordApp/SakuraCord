@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Suite(.serialized)
struct ReactionReactorProviderTests {
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

        let users = """
        [
          {"id":"1","username":"one","global_name":"One","avatar":"avatar-one"},
          {"id":"2","username":"two","global_name":"Two","avatar":null},
          {"id":"3","username":"three","global_name":"Three","avatar":null},
          {"id":"4","username":"four","global_name":"Four","avatar":null},
          {"id":"5","username":"five","global_name":"Five","avatar":null}
        ]
        """
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
