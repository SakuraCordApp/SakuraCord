@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

struct MessageSendRateLimitContractTests {
    @Test func `rate-limited message send replays its nonce after the server cooldown`() async throws {
        let fixture = MessageSendRateLimitFixture(rateLimitedAttempts: 2)
        let provider = fixture.provider()
        let draft = SendMessageDraft(channelID: ChannelID(rawValue: 200), content: "queued")

        let message = try await provider.send(draft)

        #expect(message.nonce == draft.nonce)
        let bodies = fixture.bodies
        #expect(bodies.count == 3)
        #expect(bodies.allSatisfy { $0.nonce == draft.nonce && $0.enforcesNonce })
        await provider.disconnect()
    }

    @Test func `persistent message rate limit stops at the send attempt budget`() async throws {
        let fixture = MessageSendRateLimitFixture(rateLimitedAttempts: .max)
        let provider = fixture.provider()

        await #expect(throws: ChatProviderError.self) {
            try await provider.send(SendMessageDraft(channelID: ChannelID(rawValue: 200), content: "queued"))
        }
        #expect(fixture.bodies.count == DiscordRESTProvider.maximumMessageSendAttempts)
        await provider.disconnect()
    }
}

/// Owns one test's responses. The URL protocol routes each request here by the
/// session's fixture header, so concurrent tests never share state.
private final class MessageSendRateLimitFixture {
    struct SentBody: Sendable {
        let nonce: String?
        let enforcesNonce: Bool
    }

    private final class Storage: Sendable {
        let remainingRateLimits: Mutex<Int>
        let bodies = Mutex<[SentBody]>([])
        init(rateLimitedAttempts: Int) { remainingRateLimits = Mutex(rateLimitedAttempts) }
    }

    let id = UUID().uuidString
    private let storage: Storage
    private var observer: NSObjectProtocol?

    init(rateLimitedAttempts: Int) {
        let storage = Storage(rateLimitedAttempts: rateLimitedAttempts)
        self.storage = storage
        let id = id
        observer = NotificationCenter.default.addObserver(
            forName: MessageSendRateLimitURLProtocol.received, object: nil, queue: nil
        ) { note in
            guard let exchange = note.object as? MessageSendRateLimitURLProtocol.Exchange,
                  exchange.fixtureID == id
            else { return }
            storage.bodies.withLock { $0.append(exchange.body) }
            let isRateLimited = storage.remainingRateLimits.withLock { remaining in
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            exchange.isRateLimited.withLock { $0 = isRateLimited }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var bodies: [SentBody] { storage.bodies.withLock { $0 } }

    func provider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageSendRateLimitURLProtocol.self]
        configuration.httpAdditionalHeaders = [MessageSendRateLimitURLProtocol.fixtureHeader: id]
        return DiscordRESTProvider(
            credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
    }
}

private final class MessageSendRateLimitURLProtocol: URLProtocol, @unchecked Sendable {
    static let received = Notification.Name("MessageSendRateLimitContract.request")
    static let fixtureHeader = "X-Message-Send-Rate-Limit-Test"

    final class Exchange: Sendable {
        let fixtureID: String?
        let body: MessageSendRateLimitFixture.SentBody
        let isRateLimited = Mutex(false)

        init(fixtureID: String?, body: MessageSendRateLimitFixture.SentBody) {
            self.fixtureID = fixtureID
            self.body = body
        }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let json = Self.requestBody(request)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let exchange = Exchange(
            fixtureID: request.value(forHTTPHeaderField: Self.fixtureHeader),
            body: .init(nonce: json["nonce"] as? String, enforcesNonce: json["enforce_nonce"] as? Bool == true)
        )
        NotificationCenter.default.post(name: Self.received, object: exchange)
        let nonce = exchange.body.nonce ?? ""
        let (status, data) = exchange.isRateLimited.withLock { $0 }
            ? (429, Data(#"{"message":"You are being rate limited.","retry_after":0.01,"global":false}"#.utf8))
            : (200, Data("""
            {"id":"50","channel_id":"200","author":{"id":"1","username":"tester","global_name":"Tester","avatar":null},
            "content":"queued","timestamp":"2026-10-09T12:00:00.000Z","edited_timestamp":null,
            "type":0,"flags":0,"attachments":[],"reactions":[],"nonce":"\(nonce)"}
            """.utf8))
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
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
