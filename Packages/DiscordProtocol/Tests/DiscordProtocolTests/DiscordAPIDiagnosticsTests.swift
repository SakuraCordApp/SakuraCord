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

    #expect(!text.contains("123456789"))
    #expect(!text.contains("234567890"))
    #expect(!text.contains("345678901"))
    #expect(text.contains("online"))
    #expect(!text.contains("bucket-id"))
    #expect(text.contains("<redacted-id>"))
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
    #expect(!text.contains(#""123""#))
    #expect(!text.contains(#""456""#))
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
    #expect(!text.contains("123456789"))
    #expect(text.contains("\"secret_key\":\"<redacted>\""))
    #expect(!text.contains("[11,22,33,44]"))
}

@Test func `voice Gateway lifecycle diagnostics retain safe reconnect metadata by default`() throws {
    let store = DiscordAPIDiagnosticStore(maximumEntries: 10)

    store.recordWebSocketLifecycle(
        transport: "voice_gateway",
        operation: "reconnect_scheduled",
        integers: [
            "attempt": 3,
            "close_code": 4_014,
            "delay_milliseconds": 4_000,
        ],
        flags: ["resuming": true]
    )

    let text = try #require(String(data: store.exportData(), encoding: .utf8))
    #expect(text.contains(#""direction":"lifecycle""#))
    #expect(text.contains(#""operation":"reconnect_scheduled""#))
    #expect(text.contains(#""attempt":3"#))
    #expect(text.contains(#""close_code":4014"#))
    #expect(text.contains(#""resuming":true"#))
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

@Test func `API diagnostics redact identifiers in every retained surface`() throws {
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: 10,
        capturesPayloadDetails: true
    )
    let body = Data(
        #"{"id":"111111111111111111","recipient_ids":["222222222222222222"],"nonce":"333333333333333333","id_map":{"121212121212121212":{"status":"online"}}}"#.utf8
    )
    store.recordHTTPRequest(
        method: "GET",
        path: "/channels/444444444444444444/messages/555555555555555555/reactions/private-emoji",
        query: [
            URLQueryItem(name: "before", value: "666666666666666666"),
            URLQueryItem(name: "guild_id", value: "777777777777777777"),
        ],
        body: body,
        attempt: 1
    )
    let response = try #require(HTTPURLResponse(
        url: URL(string: "https://discord.com/api/v9/channels/444444444444444444")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: [
            "X-Request-ID": "888888888888888888",
            "X-RateLimit-Bucket": "999999999999999999",
        ]
    ))
    store.recordHTTPResponse(
        method: "GET",
        path: "/channels/444444444444444444/messages/555555555555555555",
        attempt: 1,
        response: response,
        body: body,
        duration: .milliseconds(1)
    )

    let text = try #require(String(data: store.exportData(), encoding: .utf8))
    for identifier in [
        "111111111111111111", "222222222222222222", "333333333333333333",
        "444444444444444444", "555555555555555555", "666666666666666666",
        "777777777777777777", "888888888888888888", "999999999999999999",
        "121212121212121212", "private-emoji",
    ] {
        #expect(!text.contains(identifier))
    }
    #expect(text.contains("/channels/<redacted-id>/messages/<redacted-id>"))
    #expect(text.contains(#""X-Request-ID":"<redacted-id>""#))
    #expect(text.contains(#""X-RateLimit-Bucket":"<redacted-id>""#))
}

@Test func `disk diagnostics are opt in and contain every recorded request outcome`() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordDiagnosticsTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: 10,
        capturesPayloadDetails: true,
        diskDirectoryURL: directory
    )

    store.recordHTTPRequest(
        method: "GET",
        path: "/channels/111111111111111111/messages",
        body: nil,
        attempt: 1
    )
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    try store.setSavesDiagnosticsToDisk(true)
    let fileURL = try #require(store.currentDiskLogURL)
    let response = try #require(HTTPURLResponse(
        url: URL(string: "https://discord.com/api/v9/channels/222222222222222222")!,
        statusCode: 204,
        httpVersion: nil,
        headerFields: nil
    ))
    store.recordHTTPRequest(
        method: "DELETE",
        path: "/channels/222222222222222222/messages/333333333333333333",
        body: nil,
        attempt: 1
    )
    store.recordHTTPResponse(
        method: "DELETE",
        path: "/channels/222222222222222222/messages/333333333333333333",
        attempt: 1,
        response: response,
        body: Data(),
        duration: .milliseconds(2)
    )
    try store.setSavesDiagnosticsToDisk(false)

    let text = try String(contentsOf: fileURL, encoding: .utf8)
    let lines = text.split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines[1].contains(#""direction":"request""#))
    #expect(lines[2].contains(#""direction":"response""#))
    #expect(!text.contains("222222222222222222"))
    #expect(!text.contains("333333333333333333"))
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func `disk diagnostics stop at their per session byte limit`() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordDiagnosticsLimitTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let maximumDiskBytes = 1_024
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: 10,
        diskDirectoryURL: directory,
        maximumDiskBytes: maximumDiskBytes
    )
    try store.setSavesDiagnosticsToDisk(true)
    let fileURL = try #require(store.currentDiskLogURL)

    for _ in 0 ..< 100 {
        store.recordHTTPRequest(
            method: "GET",
            path: "/channels/111111111111111111/messages",
            body: nil,
            attempt: 1
        )
    }

    #expect(!store.savesDiagnosticsToDisk)
    #expect(store.diskLoggingErrorDescription != nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let byteCount = try #require(attributes[.size] as? NSNumber).intValue
    #expect(byteCount <= maximumDiskBytes)
}

@Test func `disk diagnostics prune older session files to the aggregate count limit`() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordDiagnosticsRetentionTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let oldest = directory.appending(
        path: "SakuraCord Discord API Logs 2026-01-01 00-00-00.jsonl"
    )
    let newer = directory.appending(
        path: "SakuraCord Discord API Logs 2026-01-02 00-00-00.jsonl"
    )
    try Data("oldest\n".utf8).write(to: oldest)
    try Data("newer\n".utf8).write(to: newer)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)],
        ofItemAtPath: oldest.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 2)],
        ofItemAtPath: newer.path
    )
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: 10,
        diskDirectoryURL: directory,
        maximumDiskBytes: 4_096,
        maximumDiskSessionFileCount: 2
    )
    try store.setSavesDiagnosticsToDisk(true)
    let current = try #require(store.currentDiskLogURL)

    #expect(!FileManager.default.fileExists(atPath: oldest.path))
    #expect(FileManager.default.fileExists(atPath: newer.path))
    #expect(FileManager.default.fileExists(atPath: current.path))
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".jsonl") }.count == 2
    )
}

@Test func `clearing memory and disk removes prior files and resumes active capture`() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordDiagnosticsClearTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: 10,
        diskDirectoryURL: directory,
        maximumDiskBytes: 4_096,
        maximumDiskSessionFileCount: 2
    )
    try store.setSavesDiagnosticsToDisk(true)
    store.recordHTTPRequest(
        method: "GET",
        path: "/channels/111111111111111111/messages",
        body: nil,
        attempt: 1
    )
    #expect(store.retainedEntryCount == 1)

    try store.clearMemoryAndDisk()

    #expect(store.retainedEntryCount == 0)
    #expect(store.savesDiagnosticsToDisk)
    let currentURL = try #require(store.currentDiskLogURL)
    let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "jsonl" }
    #expect(files.count == 1)
    #expect(
        files.first?.resolvingSymlinksInPath()
            == currentURL.resolvingSymlinksInPath()
    )
    #expect(try String(contentsOf: currentURL, encoding: .utf8)
        .split(separator: "\n").count == 1)
}

@Test func `central REST transport records one request and one response`() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DiagnosticsURLProtocol.self]
    let diagnostics = DiscordAPIDiagnosticStore(
        maximumEntries: 10,
        capturesPayloadDetails: true
    )
    let provider = DiscordRESTProvider(
        credentials: DiagnosticsCredentialStore(),
        handle: CredentialHandle(accountID: "diagnostics-test"),
        session: URLSession(configuration: configuration),
        apiDiagnostics: diagnostics
    )

    let (_, response) = try await provider.perform(
        "/channels/111111111111111111/messages",
        method: "GET",
        query: [],
        body: nil,
        maximumAttempts: 1
    )
    #expect(response.statusCode == 200)
    await provider.disconnect()

    let lines = try #require(
        String(data: diagnostics.exportData(), encoding: .utf8)
    ).split(separator: "\n")
    #expect(lines.count == 3)
    let request = try decodedJSONObject(lines[1])
    let recordedResponse = try decodedJSONObject(lines[2])
    #expect(request["direction"] as? String == "request")
    #expect(recordedResponse["direction"] as? String == "response")
    #expect(request["path"] as? String == "/channels/<redacted-id>/messages")
    #expect(recordedResponse["statusCode"] as? Int == 200)
}

private func decodedJSONObject(
    _ line: Substring
) throws -> [String: Any] {
    let data = Data(line.utf8)
    return try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}

private actor DiagnosticsCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for _: CredentialHandle) async throws -> Data {
        Data("diagnostics-test-token".utf8)
    }

    func remove(_: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] { [] }
}

private final class DiagnosticsURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "X-Request-ID": "222222222222222222",
                "X-RateLimit-Bucket": "333333333333333333",
            ]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"id":"444444444444444444"}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
