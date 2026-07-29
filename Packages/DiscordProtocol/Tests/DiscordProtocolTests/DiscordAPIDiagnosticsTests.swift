@testable import DiscordProtocol
import Foundation
import Testing

@Test func `API diagnostics discard sensitive values before export`() throws {
    let store = DiscordAPIDiagnosticStore(maximumEntries: 10)
    let requestBody = Data(
        """
        {
          "content": "secret message body",
          "username": "private-user",
          "guild_id": "123456789",
          "channel_id": "234567890",
          "message_id": "345678901",
          "nested": {
            "name": "Private Server",
            "token": "secret-token",
            "status": "online"
          }
        }
        """.utf8
    )
    store.recordHTTPRequest(
        method: "POST",
        path: "/channels/234567890/messages",
        query: [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "query", value: "private search"),
        ],
        body: requestBody,
        attempt: 1
    )
    let response = try #require(HTTPURLResponse(
        url: URL(string: "https://discord.com/api/v9/channels/234567890/messages")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: [
            "X-RateLimit-Bucket": "bucket-id",
            "Set-Cookie": "private-cookie",
        ]
    ))
    store.recordHTTPResponse(
        method: "POST",
        path: "/channels/234567890/messages",
        attempt: 1,
        response: response,
        body: requestBody,
        duration: .milliseconds(12)
    )

    let export = try store.exportData()
    let text = try #require(String(data: export, encoding: .utf8))

    #expect(text.contains("123456789"))
    #expect(text.contains("234567890"))
    #expect(text.contains("345678901"))
    #expect(text.contains("online"))
    #expect(text.contains("bucket-id"))
    #expect(!text.contains("secret message body"))
    #expect(!text.contains("private-user"))
    #expect(!text.contains("Private Server"))
    #expect(!text.contains("secret-token"))
    #expect(!text.contains("private search"))
    #expect(!text.contains("private-cookie"))
}

@Test func `Gateway diagnostics redact identify credentials and dispatch content`() throws {
    let store = DiscordAPIDiagnosticStore(maximumEntries: 10)
    store.recordGateway(
        direction: "request",
        envelope: GatewayEnvelope(
            op: 2,
            data: .object([
                "token": .string("private-token"),
                "session_id": .string("private-session"),
                "guild_id": .string("123"),
            ])
        )
    )
    store.recordGateway(
        direction: "response",
        envelope: GatewayEnvelope(
            op: 0,
            data: .object([
                "id": .string("456"),
                "content": .string("private message"),
                "username": .string("private user"),
            ]),
            sequence: 17,
            eventName: "MESSAGE_CREATE"
        )
    )

    let text = try #require(
        String(data: store.exportData(), encoding: .utf8)
    )
    #expect(text.contains("123"))
    #expect(text.contains("456"))
    #expect(text.contains("MESSAGE_CREATE"))
    #expect(!text.contains("private-token"))
    #expect(!text.contains("private-session"))
    #expect(!text.contains("private message"))
    #expect(!text.contains("private user"))
}

@Test func `voice Gateway diagnostics discard session encryption material`() throws {
    let store = DiscordAPIDiagnosticStore(maximumEntries: 10)
    store.recordWebSocketData(
        transport: "voice_gateway",
        direction: "response",
        data: Data(
            """
            {
              "op": 4,
              "d": {
                "mode": "aead_aes256_gcm_rtpsize",
                "secret_key": [11, 22, 33, 44],
                "user_id": "123456789"
              },
              "seq": 9
            }
            """.utf8
        )
    )

    let text = try #require(
        String(data: store.exportData(), encoding: .utf8)
    )
    #expect(text.contains("123456789"))
    #expect(text.contains("\"secret_key\":\"<redacted>\""))
    #expect(!text.contains("[11,22,33,44]"))
}

@Test func `API diagnostics report dropped entries when the buffer is full`() throws {
    let store = DiscordAPIDiagnosticStore(maximumEntries: 2)
    for attempt in 1 ... 3 {
        store.recordHTTPRequest(
            method: "GET",
            path: "/channels/\(attempt)",
            body: nil,
            attempt: attempt
        )
    }

    let lines = try #require(
        String(data: store.exportData(), encoding: .utf8)
    ).split(separator: "\n")
    #expect(store.retainedEntryCount == 2)
    #expect(lines.count == 3)
    #expect(lines[0].contains("\"droppedEntryCount\":1"))
}
