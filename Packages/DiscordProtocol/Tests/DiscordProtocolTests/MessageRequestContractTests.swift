@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

struct MessageRequestContractTests {
    private let fixture = MessageRequestFixture()
    private let requestID = ChannelID(rawValue: 501)
    private let friendID = ChannelID(rawValue: 502)

    @Test func `request flags survive a partial channel update and clear when Discord drops them`() async throws {
        let provider = await makeProvider()
        await provider.handleGatewayDispatch(name: "CHANNEL_CREATE", body: dm("503", fields: ["is_spam": .bool(true), "is_message_request": .bool(true)]))
        #expect(await provider.privateChannel(id: ChannelID(rawValue: 503))?.messageRequest == .spam)

        await provider.handleGatewayDispatch(name: "CHANNEL_UPDATE", body: dm("501", fields: ["last_message_id": .string("900")]))
        #expect(await provider.privateChannel(id: requestID)?.messageRequest == .pending)
        await provider.handleGatewayDispatch(name: "CHANNEL_UPDATE", body: dm("501", fields: ["is_message_request": .bool(false)]))
        #expect(await provider.privateChannel(id: requestID)?.messageRequest == nil)
        await provider.disconnect()
    }

    @Test func `accept sends one consent PUT and moves the request into the conversation list`() async throws {
        let provider = await makeProvider()
        try await provider.acceptMessageRequest(requestID)
        #expect(await provider.privateChannel(id: requestID)?.messageRequest == nil)
        let requests = fixture.requests.withLock { $0 }
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "")" }
            == ["PUT https://discord.com/api/v9/channels/501/recipients/@me"])
        #expect(fixture.bodies.withLock { $0 } == [.object(["consent_status": .number(2)])])
        await provider.disconnect()
    }

    @Test func `ignore sends one bare recipient DELETE and refuses a conversation that is not a request`() async throws {
        let provider = await makeProvider()
        await #expect(throws: ChatProviderError.self) { try await provider.ignoreMessageRequest(friendID) }
        try await provider.ignoreMessageRequest(requestID)
        #expect(await provider.privateChannel(id: requestID) == nil)
        #expect(await provider.privateChannel(id: friendID) != nil)
        let requests = fixture.requests.withLock { $0 }
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "")" }
            == ["DELETE https://discord.com/api/v9/channels/501/recipients/@me"])
        #expect(requests.first?.httpBody == nil && requests.first?.httpBodyStream == nil)
        await provider.disconnect()
    }

    private func dm(_ id: String, fields: [String: JSONValue]) -> JSONValue {
        .object(fields.merging([
            "id": .string(id), "type": .number(1),
            "recipients": .array([.object(["id": .string("2"), "username": .string("stranger")])]),
        ]) { _, base in base })
    }

    private func makeProvider() async -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageRequestURLProtocol.self]
        let provider = DiscordRESTProvider(credentials: TestCredentialStore(),
                                           handle: CredentialHandle(accountID: "message-requests"),
                                           session: URLSession(configuration: configuration, delegate: fixture, delegateQueue: nil))
        await provider.seedMessageRequest()
        return provider
    }
}

private extension DiscordRESTProvider {
    func seedMessageRequest() {
        currentUser = User(id: .init(rawValue: 1), username: "fixture", displayName: "Fixture")
        let stranger = User(id: .init(rawValue: 2), username: "stranger", displayName: "Stranger")
        cachedChannels[nil] = [
            Channel(id: .init(rawValue: 501), guildID: nil, name: "Stranger", kind: .directMessage,
                    recipients: [stranger], messageRequest: .pending),
            Channel(id: .init(rawValue: 502), guildID: nil, name: "Stranger", kind: .directMessage,
                    recipients: [stranger]),
        ]
    }
}

private final class MessageRequestFixture: NSObject, URLSessionTaskDelegate {
    let requests = Mutex<[URLRequest]>([])
    let bodies = Mutex<[JSONValue]>([])

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        task.delegate = self
    }
}

private final class MessageRequestURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with task: URLSessionTask) -> Bool { true }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = task?.delegate as? MessageRequestFixture else {
            Issue.record("Message request transport is missing its test-owned fixture")
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        fixture.requests.withLock { $0.append(request) }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        if let value = try? JSONDecoder().decode(JSONValue.self, from: body) {
            fixture.bodies.withLock { $0.append(value) }
        }
        // The provider reads no body from either decision.
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204,
                                                            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
