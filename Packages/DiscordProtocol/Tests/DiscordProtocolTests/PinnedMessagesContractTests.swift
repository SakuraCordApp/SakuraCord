import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Suite(.serialized)
struct PinnedMessagesContractTests {
    @Test func `pin page uses observed cursor contract and preserves pin metadata`() async throws {
        PinURLProtocol.reset()
        let provider = makeProvider()
        let before = try #require(DiscordDate.parse("2026-08-30T01:02:03.456Z"))

        let page = try await provider.pinnedMessages(
            in: ChannelID(rawValue: 200),
            before: before,
            limit: 99
        )

        #expect(page.items.map(\.id) == [MessageID(rawValue: 301), MessageID(rawValue: 300)])
        #expect(page.items.allSatisfy { $0.message.isPinned })
        #expect(page.hasMore)
        #expect(page.nextBefore == page.items.last?.pinnedAt)
        let request = try #require(PinURLProtocol.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v9/channels/200/messages/pins")
        #expect(request.query["limit"] == "50")
        let encodedBefore = try #require(
            request.query["before"].flatMap(DiscordDate.parse)
        )
        #expect(abs(encodedBefore.timeIntervalSince(before)) < 0.002)
    }

    @Test func `pin and unpin use current idempotent mutation routes`() async throws {
        PinURLProtocol.reset()
        let provider = makeProvider()

        try await provider.setMessagePinned(
            true,
            messageID: MessageID(rawValue: 300),
            channelID: ChannelID(rawValue: 200)
        )
        try await provider.setMessagePinned(
            false,
            messageID: MessageID(rawValue: 300),
            channelID: ChannelID(rawValue: 200)
        )

        #expect(PinURLProtocol.requests.map(\.method) == ["PUT", "DELETE"])
        #expect(PinURLProtocol.requests.allSatisfy {
            $0.path == "/api/v9/channels/200/messages/pins/300"
        })
    }

    @Test func `message pin state survives omitted partial update and applies explicit update`() throws {
        let full = Data(#"{"id":"300","channel_id":"200","author":{"id":"1","username":"a"},"content":"x","timestamp":"2026-08-30T00:00:00Z","pinned":true}"#.utf8)
        var message = try JSONDecoder().decode(MessageDTO.self, from: full).domain()
        #expect(message.isPinned)

        let omitted = Data(#"{"id":"300","channel_id":"200","content":"edited"}"#.utf8)
        try JSONDecoder().decode(MessageUpdateDTO.self, from: omitted).apply(to: &message)
        #expect(message.isPinned)
        #expect(message.content == "edited")

        let explicit = Data(#"{"id":"300","channel_id":"200","pinned":false}"#.utf8)
        try JSONDecoder().decode(MessageUpdateDTO.self, from: explicit).apply(to: &message)
        #expect(!message.isPinned)
    }

    private func makeProvider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PinURLProtocol.self]
        return DiscordRESTProvider(
            credentials: PinCredentialStore(),
            handle: CredentialHandle(accountID: "pins-contract"),
            session: URLSession(configuration: configuration)
        )
    }
}

private actor PinCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }
    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("pins-contract-session".utf8)
    }
    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

private struct CapturedPinRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
}

private final class PinURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [CapturedPinRequest] = []

    static func reset() { requests = [] }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        Self.requests.append(CapturedPinRequest(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            query: Dictionary(
                uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                }
            )
        ))
        let isRead = request.httpMethod == "GET"
        let readBody = #"""
        {
          "items": [
            {"pinned_at":"2026-08-29T00:00:00Z","message":{"id":"300","channel_id":"200","author":{"id":"1","username":"a"},"content":"older","timestamp":"2026-08-01T00:00:00Z","pinned":true}},
            {"pinned_at":"2026-08-30T00:00:00Z","message":{"id":"301","channel_id":"200","author":{"id":"2","username":"b"},"content":"newer","timestamp":"2026-08-02T00:00:00Z","pinned":true}}
          ],
          "has_more": true
        }
        """#
        let body = isRead ? readBody : ""
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: isRead ? 200 : 204,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
