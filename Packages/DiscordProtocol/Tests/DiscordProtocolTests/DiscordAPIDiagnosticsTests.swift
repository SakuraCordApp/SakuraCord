@testable import DiscordProtocol
import Foundation
import Testing

@Test func `API diagnostics discard sensitive values before export`() throws {
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: 10,
        capturesPayloadDetails: true
    )
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

@Test func `gateway diagnostics redact identify credentials and dispatch content`() throws {
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: 10,
        capturesPayloadDetails: true
    )
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
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: 10,
        capturesPayloadDetails: true
    )
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

@Test func `API diagnostics default to lightweight payload summaries`() throws {
    let store = DiscordAPIDiagnosticStore(maximumEntries: 10)
    let response = try #require(HTTPURLResponse(
        url: URL(string: "https://discord.com/api/v9/channels/1/messages")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    ))
    let body = Data(#"[{"id":"123","content":"private"}]"#.utf8)

    store.recordHTTPResponse(
        method: "GET",
        path: "/channels/1/messages",
        attempt: 1,
        response: response,
        body: body,
        duration: .milliseconds(4)
    )

    let text = try #require(String(data: store.exportData(), encoding: .utf8))
    #expect(text.contains("byte_count"))
    #expect(text.contains(String(body.count)))
    #expect(!text.contains("123"))
    #expect(!text.contains("private"))
}

@Test func `API diagnostics ring buffer stays bounded beyond capacity`() throws {
    let maximumEntries = 128
    let recordedEntries = 50_000
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: maximumEntries,
        maximumRetainedBytes: 2 * 1_024 * 1_024
    )

    for attempt in 1 ... recordedEntries {
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
    let metadata = try decodedJSONObject(lines[0])
    let firstEntry = try decodedJSONObject(lines[1])
    let lastEntry = try decodedJSONObject(lines[maximumEntries])

    #expect(store.retainedEntryCount == maximumEntries)
    #expect(lines.count == maximumEntries + 1)
    #expect(metadata["droppedEntryCount"] as? Int == recordedEntries - maximumEntries)
    #expect(firstEntry["sequence"] as? Int == recordedEntries - maximumEntries + 1)
    #expect(lastEntry["sequence"] as? Int == recordedEntries)
}

@Test func `API diagnostics bound payload collections`() throws {
    let values = (0 ..< 250).map { JSONValue.string(String($0)) }
    let fields = Dictionary(
        uniqueKeysWithValues: (0 ..< 250).map {
            ("field_\($0)", JSONValue.number(Double($0)))
        }
    )
    let payload = JSONValue.object([
        "items": .array(values),
        "fields": .object(fields)
    ])
    let data = try JSONEncoder().encode(payload)

    let sanitized = try #require(
        DiscordAPIDiagnosticStore.sanitizedPayload(data)
    )
    guard case let .object(root) = sanitized,
          case let .array(retainedItems)? = root["items"],
          case let .object(retainedFields)? = root["fields"]
    else {
        Issue.record("Expected a sanitized object with bounded collections.")
        return
    }
    #expect(retainedItems.count == 101)
    #expect(retainedFields.count == 101)
    #expect(retainedItems.last == .object([
        "truncated_count": .number(150)
    ]))
    #expect(retainedFields["truncated_field_count"] == .number(150))
}

@Test func `API diagnostics enforce retained byte budget`() throws {
    let maximumRetainedBytes = 4_096
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: 1_000,
        maximumRetainedBytes: maximumRetainedBytes
    )
    let payload = JSONValue.object([
        "items": .array(
            (0 ..< 250).map { JSONValue.string(String($0)) }
        )
    ])
    let data = try JSONEncoder().encode(payload)

    for attempt in 1 ... 50 {
        store.recordHTTPRequest(
            method: "POST",
            path: "/channels/1/messages",
            body: data,
            attempt: attempt
        )
    }

    let metadataLine = try #require(
        String(data: store.exportData(), encoding: .utf8)?
            .split(separator: "\n")
            .first
    )
    let metadata = try decodedJSONObject(metadataLine)
    #expect(store.retainedEstimatedByteCount <= maximumRetainedBytes)
    #expect(store.retainedEntryCount < 50)
    #expect((metadata["droppedEntryCount"] as? Int ?? 0) > 0)
    #expect(
        metadata["retainedEstimatedByteCount"] as? Int
            == store.retainedEstimatedByteCount
    )

    store.clear()
    #expect(store.retainedEntryCount == 0)
    #expect(store.retainedEstimatedByteCount == 0)
}

private func decodedJSONObject(
    _ line: Substring
) throws -> [String: Any] {
    let data = Data(line.utf8)
    return try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}
