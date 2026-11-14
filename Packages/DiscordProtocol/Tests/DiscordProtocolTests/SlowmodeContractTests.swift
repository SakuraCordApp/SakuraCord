@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
import Synchronization

@Test(arguments: ["", ",\"rate_limit_per_user\":null", ",\"rate_limit_per_user\":120"])
func `thread decoding preserves slowmode and resets an omitted setting`(_ field: String) throws {
    let data = Data("{\"id\":\"200\",\"guild_id\":\"100\",\"parent_id\":\"199\",\"name\":\"Thread\",\"type\":11\(field)}".utf8)
    let expected = field.contains("120") ? 120 : 0
    let channel = try JSONDecoder().decode(ChannelDTO.self, from: data)
    #expect(try channel.forumPost(fallbackGuildID: nil).thread.rateLimitPerUser == expected)
    let embedded = try JSONDecoder().decode(MessageThreadDTO.self, from: data)
    #expect(embedded.domain?.rateLimitPerUser == expected)
}

@Test func `slowmode rejection surfaces its retry interval without replaying the message`() async throws {
    SlowmodeURLProtocol.requestCount.withLock { $0 = 0 }
    let provider = stubbedProvider(SlowmodeURLProtocol.self)
    do {
        // Exercise the same central transport as send, with retries explicitly
        // available so a generic 429 replay cannot accidentally pass this test.
        _ = try await provider.perform(
            "/channels/200/messages", method: "POST", body: ["content": .string("test")],
            maximumAttempts: 2
        )
        Issue.record("Slowmode must be returned to the local composer")
    } catch let error as ChatProviderError {
        #expect(error == .slowmode(retryAfter: 0.125))
        #expect(SlowmodeURLProtocol.requestCount.withLock { $0 } == 1)
    }
}

private final class SlowmodeURLProtocol: URLProtocol, @unchecked Sendable {
    static let requestCount = Mutex(0)

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount.withLock { $0 += 1 }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 429, httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":20016,"retry_after":0.125}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
