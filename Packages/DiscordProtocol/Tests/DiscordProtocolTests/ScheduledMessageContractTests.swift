import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

/// Bodies observed from the official client (web build 670026, 11 November 2026).
@Suite(.serialized)
struct ScheduledMessageContractTests {
    @Test func `schedule, list, edit, send now and cancel send the official requests`() async throws {
        ScheduledURLProtocol.reset()
        let provider = makeProvider()
        await provider.seedGuildChannelForTesting(Channel(id: ChannelID(rawValue: 41), guildID: GuildID(rawValue: 5), name: "general"))
        let date = try #require(DiscordDate.parse("2026-11-11T08:00:00.000Z"))
        let draft = SendMessageDraft(
            channelID: ChannelID(rawValue: 41), content: "later",
            replyTo: MessageID(rawValue: 9), mentionsRepliedUser: false
        )

        let scheduled = try await provider.scheduleMessage(draft, at: date)
        let listed = try await provider.scheduledMessages()
        _ = try await provider.rescheduleMessage(scheduled.id, at: date.addingTimeInterval(900))
        _ = try await provider.editScheduledMessage(scheduled.id, content: "edited", flags: .suppressNotifications)
        try await provider.sendScheduledMessageNow(scheduled.id)
        try await provider.cancelScheduledMessage(scheduled.id)

        let requests = ScheduledURLProtocol.requests
        #expect(requests.map { "\($0.method) \($0.path)" } == [
            "POST /api/v9/users/@me/scheduled-messages",
            "GET /api/v9/users/@me/scheduled-messages",
            "PATCH /api/v9/users/@me/scheduled-messages/70",
            "PATCH /api/v9/users/@me/scheduled-messages/70",
            "POST /api/v9/users/@me/scheduled-messages/70/send",
            "DELETE /api/v9/users/@me/scheduled-messages/70",
        ])
        #expect(requests.allSatisfy { $0.context == nil })
        let create = try #require(requests[0].body)
        #expect(Set(create.keys) == [
            "channel_id", "content", "scheduled_timestamp", "flags", "message_reference", "allowed_mentions", "attachments",
        ])
        #expect(create["scheduled_timestamp"] as? String == "2026-11-11T08:00:00.000Z")
        #expect((create["flags"] as? NSNumber)?.intValue == 0)
        #expect((create["attachments"] as? [Any])?.isEmpty == true)
        let reference = try #require(create["message_reference"] as? [String: String])
        #expect(reference == ["guild_id": "5", "channel_id": "41", "message_id": "9"])
        let mentions = try #require(create["allowed_mentions"] as? [String: Any])
        #expect(mentions["parse"] as? [String] == ["users", "roles", "everyone"])
        #expect(mentions["replied_user"] as? Bool == false)
        #expect(requests[2].body?.keys.sorted() == ["scheduled_timestamp"])
        #expect(requests[2].body?["scheduled_timestamp"] as? String == "2026-11-11T08:15:00.000Z")
        #expect(requests[3].body?.keys.sorted() == ["content", "flags"])
        #expect((requests[3].body?["flags"] as? NSNumber)?.intValue == 4096)
        #expect(requests[4].body == nil)

        let message = try #require(listed.first)
        #expect(message.id == ScheduledMessageID(rawValue: 70))
        #expect(message.channelID == ChannelID(rawValue: 41))
        #expect(message.sendAt == date)
        #expect(message.replyTo == MessageID(rawValue: 9))
        #expect(message.flags == .suppressNotifications)
        #expect(message.state == .scheduled)
        #expect(message.attachmentCount == 1)
    }

    @Test func `the scheduled message limit is its own error`() async throws {
        ScheduledURLProtocol.reset(rejectsCreate: true)
        let provider = makeProvider()
        let draft = SendMessageDraft(channelID: ChannelID(rawValue: 41), content: "later")

        await #expect(throws: ChatProviderError.scheduledMessageLimitReached) {
            try await provider.scheduleMessage(draft, at: .now.addingTimeInterval(3600))
        }
        #expect(ScheduledURLProtocol.requests.count == 1)
    }

    private func makeProvider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScheduledURLProtocol.self]
        return DiscordRESTProvider(
            credentials: ScheduledCredentialStore(),
            handle: CredentialHandle(accountID: "scheduled-contract"),
            session: URLSession(configuration: configuration)
        )
    }
}

private actor ScheduledCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }
    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("scheduled-contract-session".utf8)
    }
    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

private struct CapturedScheduledRequest: @unchecked Sendable {
    let method: String
    let path: String
    let context: String?
    let body: [String: Any]?
}

private final class ScheduledURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [CapturedScheduledRequest] = []
    nonisolated(unsafe) static var rejectsCreate = false

    static func reset(rejectsCreate: Bool = false) {
        requests = []
        self.rejectsCreate = rejectsCreate
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? ""
        let path = request.url?.path ?? ""
        Self.requests.append(CapturedScheduledRequest(
            method: method,
            path: path,
            context: request.value(forHTTPHeaderField: "X-Context-Properties"),
            body: requestBody().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        ))
        let (status, body): (Int, String) = switch (method, path.hasSuffix("/send")) {
        case ("POST", false) where Self.rejectsCreate:
            (400, #"{"message":"You have too many scheduled messages","code":640003}"#)
        case ("DELETE", _): (204, "")
        case (_, true): (200, Self.sentMessage)
        case ("GET", _): (200, "[\(Self.scheduled)]")
        default: (200, Self.scheduled)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
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
        return data.isEmpty ? nil : data
    }

    private static let scheduled = #"""
    {
      "id":"70","scheduled_message_id":"70","user_id":"1",
      "create_args":{"content":"later","type":19,"message_reference":{"channel_id":"41","message_id":"9"},
        "channel_id":"41","flags":4096,"allowed_mentions":null,"poll":null,"sticker_ids":[],"forward_only":null},
      "send_at_timestamp":"2026-11-11T08:00:00+00:00","state":0,
      "attachment_uploads":[{"filename":"a.png","uploaded_filename":"x/a.png","description":null,"title":null}],
      "message_preview":{"id":"70","type":19,"content":"later","channel_id":"41"}
    }
    """#

    private static let sentMessage = #"""
    {"id":"80","channel_id":"41","author":{"id":"1","username":"tester"},"content":"later","timestamp":"2026-11-11T08:00:00.000Z","type":0}
    """#
}
