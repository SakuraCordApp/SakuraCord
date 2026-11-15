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
    #expect(DiscordDiagnosticSanitizer.sanitize(payload) == sanitized)
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
        credentials: TestCredentialStore(token: "diagnostics-test-token", handles: []),
        handle: CredentialHandle(accountID: "diagnostics-test"),
        session: URLSession(configuration: configuration),
        apiDiagnostics: diagnostics
    )

    let (_, response) = try await provider.perform(
        "/channels/111111111111111111/messages",
        method: "GET",
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

private final class DiagnosticsURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if request.url?.lastPathComponent == "tls-failure" {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: NSURLErrorDomain, code: URLError.secureConnectionFailed.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey: "private TLS description",
                    NSURLErrorFailingURLErrorKey: URL(string: "https://private.example/secret-token")!,
                ]
            ))
            return
        }
        respond(
            status: request.url?.lastPathComponent == "http-failure" ? 500 : 200,
            body: Data(#"{"id":"444444444444444444"}"#.utf8),
            headers: [
                "Content-Type": "application/json",
                "X-Request-ID": "222222222222222222",
                "X-RateLimit-Bucket": "333333333333333333",
            ]
        )
    }

    override func stopLoading() {}
}

@Test(arguments: ["tls-failure", "invalid-message-page", "http-failure"])
func `blocked REST loads panic save transport and decoding failures`(path: String) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordLoadingFailureTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(diskDirectoryURL: directory)
    store.enablesPanicSave = true
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DiagnosticsURLProtocol.self]
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(token: "diagnostics-test-token", handles: []),
        handle: CredentialHandle(accountID: "diagnostics-test"),
        session: URLSession(configuration: configuration),
        apiDiagnostics: store
    )
    await #expect(throws: (any Error).self) {
        do {
            let _: [String] = try await provider.request("/\(path)")
        } catch {
            store.recordClientFailure(error, operation: "app_load_failed")
            throw error
        }
    }
    await provider.disconnect()
    let text = try String(contentsOf: store.panicSaveURL, encoding: .utf8)
    let lines = text.split(separator: "\n")
    let failure = try decodedJSONObject(#require(lines.last))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    #expect(try String(data: store.exportData(), encoding: .utf8)?.contains("app_load_failed") == true)
    if path == "http-failure" {
        #expect(failure["statusCode"] as? Int == 500)
    } else if path == "tls-failure" {
        #expect(failure["errorDomain"] as? String == NSURLErrorDomain)
        #expect(failure["errorCode"] as? Int == URLError.secureConnectionFailed.rawValue)
        #expect(failure["path"] as? String == "/tls-failure")
    } else {
        #expect(failure["operation"] as? String == "rest_response_decode")
        #expect(text.contains(#""statusCode":200"#))
        #expect(failure["errorType"] as? String == String(reflecting: DecodingError.self))
    }
    for secret in ["private TLS description", "private.example", "secret-token", "444444444444444444"] {
        #expect(!text.contains(secret))
    }
}

@Test(arguments: ["http", "websocket", "client"], ["tls", "timeout", "cancelled", "task-cancelled"])
func `panic save captures failures but excludes normal cancellation`(boundary: String, failure: String) throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordFailureTriggerTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(diskDirectoryURL: directory)
    store.enablesPanicSave = true
    let error: any Error = switch failure {
    case "tls": URLError(.secureConnectionFailed)
    case "timeout": URLError(.timedOut)
    case "cancelled": URLError(.cancelled)
    default: CancellationError()
    }
    switch boundary {
    case "http":
        store.recordHTTPFailure(
            method: "GET", path: "/channels/123456789/messages", attempt: 1,
            duration: .milliseconds(17), error: error
        )
    case "websocket":
        store.recordWebSocketFailure(transport: "gateway", direction: "response", error: error)
    default:
        store.recordClientFailure(error, operation: "message_history_load")
    }
    #expect(FileManager.default.fileExists(atPath: store.panicSaveURL.path) == ["tls", "timeout"].contains(failure))
    #expect(store.panicSaveErrorDescription == nil)
}

@Test func `client loading failures save context without exporting error text`() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordClientFailureTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(diskDirectoryURL: directory)
    store.enablesPanicSave = true
    let response = try #require(HTTPURLResponse(
        url: URL(string: "https://discord.com/api/v9/channels/123456789/messages")!,
        statusCode: 200, httpVersion: nil, headerFields: nil
    ))
    store.recordHTTPResponse(
        method: "GET", path: "/channels/123456789/messages", attempt: 1,
        response: response, body: Data(#"{"code":50001,"message":"private reason"}"#.utf8),
        duration: .milliseconds(1)
    )
    #expect(!FileManager.default.fileExists(atPath: store.panicSaveURL.path))
    let error = NSError(domain: "private domain", code: 42, userInfo: [
        NSLocalizedDescriptionKey: "private description",
        NSUnderlyingErrorKey: NSError(domain: "private underlying domain", code: 1),
    ])
    store.recordClientFailure(error, operation: "message_history_load")
    let text = try String(contentsOf: store.panicSaveURL, encoding: .utf8)
    #expect(text.contains(#""statusCode":200"#))
    #expect(text.contains(#""operation":"message_history_load""#))
    #expect(text.contains(#""errorDomain":"<redacted>""#))
    #expect(text.contains(#""errorCode":42"#))
    #expect(!text.contains("private"))
    #expect(!text.contains("123456789"))
    store.enablesPanicSave = false
    store.recordClientFailure(error, operation: "another_load")
    #expect(try String(contentsOf: store.panicSaveURL, encoding: .utf8) == text)
}

@Test(arguments: [
    ("socket_closed", 1000, false),
    ("socket_closed", 1001, false),
    ("socket_closed", 4004, true),
    ("socket_receive_failed", 0, true),
    ("heartbeat_ack_missed", 0, true),
    ("app_session_state_failed", 0, true),
    ("socket_connect_started", 0, false),
])
func `panic save captures failed lifecycles and excludes normal socket closure`(
    operation: String, closeCode: Int, shouldSave: Bool
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordLifecycleFailureTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(diskDirectoryURL: directory)
    store.enablesPanicSave = true
    store.recordWebSocketLifecycle(
        transport: "voice_gateway", operation: operation, integers: ["close_code": closeCode]
    )
    #expect(FileManager.default.fileExists(atPath: store.panicSaveURL.path) == shouldSave)
}

@Test(arguments: [false, true])
func `panic save always retains detailed sanitized history and rotates three snapshots`(
    detailedCapture: Bool
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordPanicTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(
        maximumEntries: 10, capturesPayloadDetails: detailedCapture, diskDirectoryURL: directory
    )
    store.enablesPanicSave = true
    #expect(store.capturesPayloadDetails == detailedCapture)
    store.recordHTTPRequest(
        method: "POST", path: "/channels/123456789/messages",
        body: Data(#"{"content":"private-message","token":"private-token","flags":64}"#.utf8),
        attempt: 1
    )
    store.recordGateway(
        direction: "response",
        envelope: GatewayEnvelope(op: 0, data: .object([
            "flags": .number(128), "content": .string("private-gateway-message")
        ]), eventName: "MESSAGE_CREATE")
    )
    store.recordWebSocketData(
        transport: "voice_gateway", direction: "response",
        data: Data(#"{"op":4,"d":{"heartbeat_interval":45000,"secret_key":[11,22,33]}}"#.utf8)
    )
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    try store.setSavesDiagnosticsToDisk(true)
    let continuousLog = try #require(store.currentDiskLogURL)
    let response = try #require(HTTPURLResponse(
        url: URL(string: "https://discord.com/api/v9/channels/123456789/messages")!,
        statusCode: 500, httpVersion: nil, headerFields: ["X-Request-ID": "private-request"]
    ))
    store.recordHTTPResponse(
        method: "POST", path: "/channels/123456789/messages", attempt: 1,
        response: response, body: Data(#"{"code":0,"message":"Unknown error private-message"}"#.utf8),
        duration: .milliseconds(17)
    )
    let first = try String(contentsOf: store.panicSaveURL, encoding: .utf8)
    #expect(first.contains(#""flags":64"#))
    #expect(first.contains(#""flags":128"#))
    #expect(first.contains(#""heartbeat_interval":45000"#))
    #expect(first.contains(#""secret_key":"<redacted>""#))
    #expect(first.contains(#""statusCode":500"#))
    #expect(first.contains(#""durationMilliseconds":17"#))
    for secret in ["private-message", "private-gateway-message", "private-token", "private-request", "123456789", "[11,22,33]"] {
        #expect(!first.contains(secret))
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: store.panicSaveURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let folderAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((folderAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    store.clear()
    store.recordWebSocketLifecycle(
        transport: "gateway", operation: "socket_closed", integers: ["close_code": 4000]
    )
    let replacement = try Data(contentsOf: store.panicSaveURL)
    let replacementText = try #require(String(data: replacement, encoding: .utf8))
    #expect(!replacementText.contains("statusCode"))
    #expect(replacementText.contains(#""close_code":4000"#))
    #expect(store.currentDiskLogURL == continuousLog)
    #expect(store.savesDiagnosticsToDisk)
    let secondURL = directory.appending(path: "SakuraCord Discord API Panic Save-2.jsonl")
    let thirdURL = directory.appending(path: "SakuraCord Discord API Panic Save-3.jsonl")
    #expect(try String(contentsOf: secondURL, encoding: .utf8) == first)
    // A new store discovers and rotates snapshots retained by an earlier launch.
    let relaunchedStore = DiscordAPIDiagnosticStore(diskDirectoryURL: directory)
    relaunchedStore.enablesPanicSave = true
    for snapshot in 3 ... 4 {
        relaunchedStore.clear()
        relaunchedStore.recordWebSocketLifecycle(
            transport: "gateway", operation: "socket_closed",
            integers: ["close_code": 4000, "snapshot": snapshot]
        )
    }
    #expect(try Data(contentsOf: thirdURL) == replacement)
    #expect(try String(contentsOf: secondURL, encoding: .utf8).contains(#""snapshot":3"#))
    let newest = try Data(contentsOf: store.panicSaveURL)
    #expect(try #require(String(data: newest, encoding: .utf8)).contains(#""snapshot":4"#))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 4)
    store.enablesPanicSave = false
    #expect(store.retainsPayloadDetails == detailedCapture)
    store.recordWebSocketLifecycle(
        transport: "gateway", operation: "socket_closed", integers: ["close_code": 4000]
    )
    #expect(try Data(contentsOf: store.panicSaveURL) == newest)
    try store.clearMemoryAndDisk()
    #expect(!FileManager.default.fileExists(atPath: store.panicSaveURL.path))
    #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    #expect(!FileManager.default.fileExists(atPath: thirdURL.path))
    #expect(store.retainedEntryCount == 0)
    #expect(store.savesDiagnosticsToDisk)
}

@Test(arguments: [
    (200, #"{"code":0}"#, false),
    (400, #"{"code":0}"#, true),
    (400, #"{"code":50035,"message":"Invalid Form Body"}"#, true),
    (400, #"{"code":999999,"message":"Unknown error"}"#, true),
    (401, "{}", true),
    (403, "{}", true),
    (404, #"{"code":10008,"message":"Unknown Message"}"#, true),
    (429, #"{"retry_after":1}"#, true),
    (502, "upstream unavailable", true),
    (400, "malformed response", true),
])
func `panic save captures every failed HTTP response`(
    status: Int, body: String, shouldSave: Bool
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordPanicTriggerTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(diskDirectoryURL: directory)
    store.enablesPanicSave = true
    let response = try #require(HTTPURLResponse(
        url: URL(string: "https://discord.com/api/v9/users/@me")!,
        statusCode: status, httpVersion: nil, headerFields: nil
    ))
    store.recordHTTPResponse(
        method: "GET", path: "/users/@me", attempt: 1, response: response,
        body: Data(body.utf8), duration: .milliseconds(1)
    )
    #expect(FileManager.default.fileExists(atPath: store.panicSaveURL.path) == shouldSave)
    #expect(store.panicSaveErrorDescription == nil)
}

@Test func `panic save bounds newest entries and reports disk failures without interrupting logging`() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SakuraCordPanicBoundTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(diskDirectoryURL: directory, maximumDiskBytes: 2_048)
    store.setSupportSummary(.object([
        "application": .object(["version": .string(String(repeating: "v", count: 600))]),
    ]))
    store.enablesPanicSave = true
    for attempt in 1 ... 30 {
        store.recordHTTPRequest(method: "GET", path: "/users/@me", body: nil, attempt: attempt)
    }
    store.recordWebSocketLifecycle(
        transport: "voice_gateway", operation: "socket_receive_failed", integers: ["close_code": 4000]
    )
    let data = try Data(contentsOf: store.panicSaveURL)
    #expect(data.count <= 2_048)
    #expect(try #require(String(data: data, encoding: .utf8)).contains("supportSummary"))
    let lines = try #require(String(data: data, encoding: .utf8)).split(separator: "\n")
    #expect(try decodedJSONObject(lines[0])["droppedEntryCount"] as? Int ?? 0 > 0)
    #expect(lines.last?.contains(#""close_code":4000"#) == true)
    #expect(lines.dropFirst().first?.contains(#""attempt":1,"#) == false)

    try store.clearMemoryAndDisk()
    // A directory at the destination forces atomic replacement to fail.
    try FileManager.default.createDirectory(at: store.panicSaveURL, withIntermediateDirectories: true)
    store.recordWebSocketLifecycle(
        transport: "gateway", operation: "socket_closed", integers: ["close_code": 4000]
    )
    #expect(store.panicSaveErrorDescription != nil)
    #expect(store.retainedEntryCount == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
}

@Test func `direct JSON diagnostics match Gateway redaction for mixed types and depth limits`() throws {
    var deepValue: JSONValue = .string("private-deep-value")
    for _ in 0 ..< 12 { deepValue = .object(["child": deepValue]) }
    let longStatus = String(repeating: "🌸", count: 300)
    let payload = JSONValue.object([
        "ToKeN": .object(["nested": .string("private-token")]),
        "CHANNEL-ID": .number(123456789),
        "secret-key": .array([.number(11), .number(22)]),
        "status": .array([.string(longStatus), .bool(true), .number(1), .null]),
        "other": .array([.bool(false), .number(0), .number(-1.25), .string("private-text")]),
        "123456789": .object(["flags": .number(64)]),
        "deep": deepValue,
    ])
    let data = try JSONEncoder().encode(payload)
    let sanitized = try #require(DiscordAPIDiagnosticStore.sanitizedPayload(data))
    let store = DiscordAPIDiagnosticStore(capturesPayloadDetails: true)
    store.recordGateway(direction: "response", envelope: GatewayEnvelope(op: 0, data: payload))
    let line = try #require(String(data: store.exportData(), encoding: .utf8)?.split(separator: "\n").last)
    let entry = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    guard case let .object(fields) = sanitized,
          case let .object(gateway) = entry,
          case let .object(envelope)? = gateway["payload"]
    else {
        Issue.record("Expected sanitized objects from both transport paths.")
        return
    }
    #expect(envelope["data"] == sanitized)
    #expect(fields["ToKeN"] == .string("<redacted>"))
    #expect(fields["CHANNEL-ID"] == .string("<redacted-id>"))
    #expect(fields["secret-key"] == .string("<redacted>"))
    #expect(fields["status"] == .array([.string(String(longStatus.prefix(256))), .bool(true), .number(1), .null]))
    #expect(fields["other"] == .array([.bool(false), .number(0), .number(-1.25), .string("<redacted>")]))
    #expect(fields["123456789"] == nil)
    let text = try #require(String(data: JSONEncoder().encode(sanitized), encoding: .utf8))
    #expect(text.contains("<truncated-depth>"))
    #expect(!text.contains("private-"))

    let malformed = Data(#"{"token":"private-token","flags":}"#.utf8)
    #expect(DiscordAPIDiagnosticStore.sanitizedPayload(malformed) == .object([
        "byte_count": .number(Double(malformed.count))
    ]))
}

@Test(arguments: [false, true])
func `deferred diagnostics budget original payloads and release evicted entries`(authentication: Bool) throws {
    let transport = authentication ? "authentication" : "rest"
    let path = authentication ? "/auth/login" : "/channels/1/messages"
    let operation = authentication ? "opcode_2" : "MESSAGE_CREATE"
    let store = DiscordAPIDiagnosticStore(maximumEntries: 10, maximumRetainedBytes: 4_096, capturesPayloadDetails: true)
    let body = try JSONEncoder().encode(JSONValue.object([
        "content": .string(String(repeating: "private", count: 300)),
        "flags": .number(64),
    ]))
    store.recordHTTPRequest(transport: transport, method: "POST", path: path, body: body, attempt: 1)
    #expect(store.retainedEstimatedByteCount >= body.count)
    store.recordGateway(direction: "response", envelope: GatewayEnvelope(
        op: authentication ? 2 : 0, data: .object(["content": .string(String(repeating: "private", count: 300))]), eventName: authentication ? nil : "MESSAGE_CREATE"
    ))
    #expect(store.retainedEntryCount == 1)
    let text = try #require(String(data: store.exportData(), encoding: .utf8))
    #expect(!text.contains("private"))
    #expect(!text.contains("\"method\":\"POST\""))
    #expect(text.contains(operation))
    #expect(text.contains("\"droppedEntryCount\":1"))

    // Even a payload which would redact to a few bytes must fit before retention.
    let oversized = try JSONEncoder().encode(JSONValue.object([
        "content": .string(String(repeating: "private", count: 1_000)),
    ]))
    store.recordHTTPRequest(transport: transport, method: "POST", path: path, body: oversized, attempt: 2)
    #expect(store.retainedEntryCount == 1)
    #expect(store.retainedEstimatedByteCount <= 4_096)
    store.clear()
    #expect(store.retainedEntryCount == 0)
    #expect(store.retainedEstimatedByteCount == 0)
    #expect(try String(data: store.exportData(), encoding: .utf8)?.split(separator: "\n").count == 1)
}

@Test func `concurrent exports share deferred payloads without exposing raw content`() async throws {
    let store = DiscordAPIDiagnosticStore(maximumEntries: 100, capturesPayloadDetails: true)
    let body = Data(#"{"content":"private-content","token":"private-token","flags":64}"#.utf8)
    for attempt in 1 ... 20 {
        store.recordHTTPRequest(method: "POST", path: "/channels/1/messages", body: body, attempt: attempt)
    }
    try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0 ..< 8 { group.addTask { try store.exportData() } }
        var firstEntries: [Substring]?
        for try await export in group {
            let text = try #require(String(data: export, encoding: .utf8))
            #expect(!text.contains("private-"))
            #expect(text.contains("\"flags\":64"))
            let entries = Array(text.split(separator: "\n").dropFirst())
            #expect(entries.count == 20)
            if let firstEntries { #expect(entries == firstEntries) }
            firstEntries = entries
        }
    }
}

@Test(arguments: ["export", "panic", "disk", "failed-panic"], ["rest", "authentication", "websocket"])
func `sanitized cache growth is accounted for at every output boundary`(output: String, source: String) throws {
    let body = try JSONEncoder().encode(JSONValue.object([
        "values": .array(Array(repeating: .array(Array(repeating: .number(0), count: 100)), count: 10)),
        "content": .string("private-content"),
        "token": .string("private-token"),
        "secret_key": .array([.number(11), .number(22), .number(33)]),
        "op": .string("nonce_proof"),
        "flags": .number(64),
    ]))
    // The wire body fits both budgets. Its conservative sanitized size only fits the larger one.
    for budget in [4_096, 32_768] {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SakuraCordCacheGrowthTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiscordAPIDiagnosticStore(
            maximumRetainedBytes: budget, capturesPayloadDetails: true, diskDirectoryURL: directory
        )
        store.enablesPanicSave = output == "panic" || output == "failed-panic"
        if output == "disk" { try store.setSavesDiagnosticsToDisk(true) }
        if output == "failed-panic" {
            try FileManager.default.createDirectory(at: store.panicSaveURL, withIntermediateDirectories: true)
        }
        if source == "websocket" {
            store.recordWebSocketData(transport: "remote_auth_gateway", direction: "request", data: body)
        } else {
            store.recordHTTPRequest(transport: source, method: "POST", path: "/test", body: body, attempt: 1)
        }
        store.recordWebSocketLifecycle(
            transport: "gateway", operation: "socket_closed", integers: ["close_code": 4000]
        )

        let text: String
        switch output {
        case "export": text = try #require(String(data: store.exportData(), encoding: .utf8))
        case "panic": text = try String(contentsOf: store.panicSaveURL, encoding: .utf8)
        case "disk": text = try String(contentsOf: #require(store.currentDiskLogURL), encoding: .utf8)
        default:
            #expect(store.panicSaveErrorDescription != nil)
            text = ""
        }
        #expect(store.retainedEstimatedByteCount <= budget)
        if budget == 4_096 {
            #expect(store.retainedEntryCount == 1)
        } else {
            #expect(store.retainedEntryCount == 2)
            #expect(store.retainedEstimatedByteCount > 24_000)
        }
        if output != "failed-panic" {
            // Retention eviction must not remove the detailed entry from this output.
            #expect(text.contains(#""flags":64"#))
            #expect(text.contains(#""content":"<redacted>""#))
            #expect(!text.contains("private-"))
            #expect(text.contains(#""secret_key":"<redacted>""#))
            if source == "websocket" {
                #expect(text.contains(#""operation":"nonce_proof""#))
            }
            #expect(text.contains("socket_closed"))
        }
        store.clear()
        #expect(store.retainedEstimatedByteCount == 0)
    }
}

@Test(arguments: ["url", "swift", "decode"])
func `one propagated error saves once while independent equal errors still save`(kind: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "SakuraCordCoalescing-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(diskDirectoryURL: directory)
    store.enablesPanicSave = true
    func makeError() -> any Error {
        switch kind {
        case "url": URLError(.secureConnectionFailed)
        case "swift": ChatProviderError.invalidRequest("private reason")
        default: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "private decode"))
        }
    }
    let error = makeError()
    store.recordHTTPFailure(method: "GET", path: "/test", attempt: 1, duration: .zero, error: error)
    let first = try Data(contentsOf: store.panicSaveURL)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0 ..< 8 {
            group.addTask { store.recordClientFailure(error, operation: "propagated_load") }
        }
    }
    #expect(try Data(contentsOf: store.panicSaveURL) == first)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    #expect(store.retainedEntryCount == 9)
    let distinctError = makeError()
    store.recordClientFailure(distinctError, operation: "independent_load")
    let previous = directory.appending(path: "SakuraCord Discord API Panic Save-2.jsonl")
    #expect(try Data(contentsOf: previous) == first)
    #expect(try String(contentsOf: store.panicSaveURL, encoding: .utf8).contains("propagated_load"))
    // Clearing resets coalescing along with diagnostic history.
    try store.clearMemoryAndDisk()
    store.recordClientFailure(error)
    #expect(FileManager.default.fileExists(atPath: store.panicSaveURL.path))
}

@Test func `response and socket consequences share captures without retaining private error objects`() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "SakuraCordIncident-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(diskDirectoryURL: directory)
    store.enablesPanicSave = true
    let response = try #require(HTTPURLResponse(
        url: URL(string: "https://discord.com/api/v9/test")!, statusCode: 500,
        httpVersion: nil, headerFields: nil
    ))
    store.recordHTTPResponse(method: "GET", path: "/test", attempt: 1, response: response, body: Data(), duration: .zero)
    let first = try Data(contentsOf: store.panicSaveURL)
    let error = store.coalescing(ChatProviderError.transport(status: 500, requestID: nil), with: response)
    #expect(error is ChatProviderError)
    store.recordClientFailure(error)
    #expect(try Data(contentsOf: store.panicSaveURL) == first)
    let incident = NSUUID()
    weak var releasedError: NSError?
    autoreleasepool {
        let socketError = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: ["private": "secret"])
        releasedError = socketError
        store.recordWebSocketFailure(transport: "gateway", direction: "response", error: socketError, incident: incident)
        store.recordClientFailure(socketError)
    }
    #expect(releasedError == nil)
    let second = try Data(contentsOf: store.panicSaveURL)
    store.recordWebSocketLifecycle(
        transport: "gateway", operation: "socket_closed", integers: ["close_code": 4000], incident: incident
    )
    #expect(try Data(contentsOf: store.panicSaveURL) == second)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    // A new connection is eligible even when the close code is identical.
    store.recordWebSocketLifecycle(
        transport: "gateway", operation: "socket_closed", integers: ["close_code": 4000], incident: NSUUID()
    )
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
}

@Test func `duplicate failures do not retry failed panic writes and disabled capture does not claim errors`() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "SakuraCordFailedCoalescing-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiscordAPIDiagnosticStore(diskDirectoryURL: directory)
    let error: any Error = URLError(.timedOut)
    store.recordClientFailure(error)
    store.enablesPanicSave = true
    try FileManager.default.createDirectory(at: store.panicSaveURL, withIntermediateDirectories: true)
    store.recordClientFailure(error)
    #expect(store.panicSaveErrorDescription != nil)
    try FileManager.default.removeItem(at: store.panicSaveURL)
    store.recordClientFailure(error)
    #expect(!FileManager.default.fileExists(atPath: store.panicSaveURL.path))
    store.recordClientFailure(URLError(.timedOut))
    #expect(FileManager.default.fileExists(atPath: store.panicSaveURL.path))
    #expect(store.panicSaveErrorDescription == nil)
}
