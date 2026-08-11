import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Suite(.serialized)
struct MessageForwardingContractTests {
    @Test func `forward uses one exact message mutation and decodes its immutable snapshot`() async throws {
        ForwardingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForwardingURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: ForwardingCredentialStore(),
            handle: CredentialHandle(accountID: "forwarding"),
            session: URLSession(configuration: configuration)
        )
        await provider.seedPrivateChannelsForTesting([
            Channel(
                id: ChannelID(rawValue: 41),
                guildID: nil,
                name: "Maya",
                kind: .directMessage
            )
        ])
        let draft = ForwardMessageDraft(
            sourceMessageID: MessageID(rawValue: 9),
            sourceChannelID: ChannelID(rawValue: 7),
            sourceGuildID: GuildID(rawValue: 5),
            destinationChannelID: ChannelID(rawValue: 41),
            nonce: "forward-contract-nonce"
        )

        let message = try await provider.forward(draft)

        #expect(ForwardingURLProtocol.requestCount == 1)
        #expect(ForwardingURLProtocol.method == "POST")
        #expect(ForwardingURLProtocol.path == "/api/v9/channels/41/messages")
        #expect(ForwardingURLProtocol.context == Data(#"{"location":"forwarding"}"#.utf8)
            .base64EncodedString())
        let body = try #require(ForwardingURLProtocol.body)
        #expect(Set(body.keys) == [
            "content", "nonce", "tts", "flags",
            "mobile_network_type", "message_reference",
        ])
        #expect(body["content"] as? String == "")
        #expect(body["nonce"] as? String == draft.nonce)
        #expect(body["enforce_nonce"] == nil)
        let reference = try #require(body["message_reference"] as? [String: Any])
        #expect((reference["type"] as? NSNumber)?.intValue == 1)
        #expect(reference["message_id"] as? String == "9")
        #expect(reference["channel_id"] as? String == "7")
        #expect(reference["guild_id"] as? String == "5")
        #expect(message.messageReference?.type == .forward)
        #expect(message.forwardedSnapshot?.content == "snapshot text")
        #expect(message.content == "snapshot text")
        #expect(message.type.rawValue == 0)
        #expect(message.flags == .forwarded)
        #expect(message.attachments.first?.filename == "flower.png")
        #expect(message.embeds.first?.title == "Snapshot embed")
        #expect(message.stickers.first?.name == "Wave")
        #expect(message.mentionedUsers.map(\.displayName) == ["Known User"])
        await provider.disconnect()
    }

    @Test func `forward mutation never retries a server rate limit`() async throws {
        ForwardingURLProtocol.reset(status: 429)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForwardingURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: ForwardingCredentialStore(),
            handle: CredentialHandle(accountID: "forwarding"),
            session: URLSession(configuration: configuration)
        )
        await provider.seedPrivateChannelsForTesting([
            Channel(
                id: ChannelID(rawValue: 41),
                guildID: nil,
                name: "Maya",
                kind: .directMessage
            )
        ])

        await #expect(throws: ChatProviderError.self) {
            try await provider.forward(ForwardMessageDraft(
                sourceMessageID: MessageID(rawValue: 9),
                sourceChannelID: ChannelID(rawValue: 7),
                sourceGuildID: GuildID(rawValue: 5),
                destinationChannelID: ChannelID(rawValue: 41),
                nonce: "forward-no-retry"
            ))
        }
        #expect(ForwardingURLProtocol.requestCount == 1)
        await provider.disconnect()
    }

    @Test func `missing user destination creates one coalesced private channel`() async throws {
        ForwardingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForwardingURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: ForwardingCredentialStore(),
            handle: CredentialHandle(accountID: "forwarding"),
            session: URLSession(configuration: configuration)
        )
        let userID = UserID(rawValue: 2)

        async let first = provider.ensurePrivateChannel(for: userID)
        async let second = provider.ensurePrivateChannel(for: userID)
        let channels = try await [first, second]

        #expect(channels.map(\.id) == [ChannelID(rawValue: 41), ChannelID(rawValue: 41)])
        #expect(ForwardingURLProtocol.requestCount == 1)
        #expect(ForwardingURLProtocol.method == "POST")
        #expect(ForwardingURLProtocol.path == "/api/v9/users/@me/channels")
        #expect(ForwardingURLProtocol.context == nil)
        let body = try #require(ForwardingURLProtocol.body)
        #expect(Set(body.keys) == ["recipients"])
        #expect(body["recipients"] as? [String] == ["2"])
        await provider.disconnect()
    }
}

private actor ForwardingCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("forwarding-contract-session".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        [CredentialHandle(accountID: "forwarding")]
    }
}

private final class ForwardingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var method: String?
    nonisolated(unsafe) static var path = ""
    nonisolated(unsafe) static var context: String?
    nonisolated(unsafe) static var body: [String: Any]?
    nonisolated(unsafe) static var status = 200

    static func reset(status: Int = 200) {
        requestCount = 0
        method = nil
        path = ""
        context = nil
        body = nil
        self.status = status
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.method = request.httpMethod
        Self.path = request.url?.path ?? ""
        Self.context = request.value(forHTTPHeaderField: "X-Context-Properties")
        Self.body = requestBody().flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let successBody = Self.path.hasSuffix("/users/@me/channels")
            ? Self.privateChannelResponse
            : Self.successResponse
        let responseBody = Self.status == 200
            ? successBody
            : #"{"retry_after":0.01,"global":false}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody() -> Data? {
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

    private static let successResponse = #"""
    {
      "id":"50","channel_id":"41",
      "author":{"id":"1","username":"tester","global_name":"Tester","avatar":null},
      "content":"","timestamp":"2026-08-09T12:00:00.000Z","edited_timestamp":null,
      "type":0,"flags":16384,
      "attachments":[],"reactions":[],
      "message_reference":{"type":1,"message_id":"9","channel_id":"7","guild_id":"5"},
      "message_snapshots":[{"message":{
        "type":19,"content":"snapshot text","timestamp":"2026-08-08T10:30:00.000Z",
        "edited_timestamp":null,"flags":0,
        "attachments":[{
          "id":"80","filename":"flower.png",
          "url":"https://cdn.discordapp.com/attachments/7/80/flower.png",
          "proxy_url":"https://media.discordapp.net/attachments/7/80/flower.png",
          "content_type":"image/png","width":64,"height":64,"size":1024
        }],
        "embeds":[{"type":"rich","title":"Snapshot embed","description":"embed body"}],
        "components":[],
        "sticker_items":[{"id":"90","name":"Wave","format_type":1}],
        "mentions":[],"mention_roles":[],
        "resolved":{"users":{"2":{"id":"2","username":"known","global_name":"Known User","avatar":null}}}
      }}]
    }
    """#

    private static let privateChannelResponse = #"""
    {
      "id":"41","type":1,
      "recipients":[{
        "id":"2","username":"known","global_name":"Known User","avatar":null
      }]
    }
    """#
}
