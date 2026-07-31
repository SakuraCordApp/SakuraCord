import Foundation

/// A bounded, session-local record of Discord protocol traffic.
///
/// Payloads are sanitized before they enter the store. The export therefore
/// cannot recover credentials, message text, names, profile text, URLs, or
/// other user-authored strings that were deliberately discarded here.
public final class DiscordAPIDiagnosticStore: @unchecked Sendable {
    public static let shared = DiscordAPIDiagnosticStore()

    private struct RetainedEntry {
        let entry: Entry
        let estimatedByteCount: Int
    }

    private struct State {
        var entries: [RetainedEntry?]
        var headIndex = 0
        var entryCount = 0
        var retainedEstimatedByteCount = 0
        var nextSequence: UInt64 = 1
        var droppedEntryCount = 0

        init(capacity: Int) {
            entries = Array(repeating: nil, count: capacity)
        }

        var orderedEntries: [Entry] {
            (0 ..< entryCount).compactMap { offset in
                entries[(headIndex + offset) % entries.count]?.entry
            }
        }

        mutating func append(
            _ entry: Entry,
            estimatedByteCount: Int,
            maximumRetainedBytes: Int
        ) {
            guard estimatedByteCount <= maximumRetainedBytes else {
                droppedEntryCount += 1
                return
            }
            while shouldEvict(estimatedByteCount, maximumRetainedBytes) {
                removeOldest()
            }
            let insertionIndex = (headIndex + entryCount) % entries.count
            entries[insertionIndex] = RetainedEntry(
                entry: entry,
                estimatedByteCount: estimatedByteCount
            )
            entryCount += 1
            retainedEstimatedByteCount += estimatedByteCount
        }

        mutating func clear() {
            entries = Array(repeating: nil, count: entries.count)
            headIndex = 0
            entryCount = 0
            retainedEstimatedByteCount = 0
            droppedEntryCount = 0
        }

        private mutating func removeOldest() {
            guard entryCount > 0 else { return }
            if let removed = entries[headIndex] {
                retainedEstimatedByteCount -= removed.estimatedByteCount
            }
            entries[headIndex] = nil
            headIndex = (headIndex + 1) % entries.count
            entryCount -= 1
            droppedEntryCount += 1
        }

        private func shouldEvict(
            _ estimatedByteCount: Int,
            _ maximumRetainedBytes: Int
        ) -> Bool {
            entryCount == entries.count
                || retainedEstimatedByteCount + estimatedByteCount
                    > maximumRetainedBytes
        }
    }

    private struct Entry: Codable {
        let sequence: UInt64
        let timestamp: Date
        let transport: String
        let direction: String
        let operation: String
        let method: String?
        let path: String?
        let attempt: Int?
        let statusCode: Int?
        let durationMilliseconds: Int?
        let headers: [String: String]?
        let payload: JSONValue?
        let errorType: String?
    }

    private struct ExportMetadata: Codable {
        let format: String
        let generatedAt: Date
        let retainedEntryCount: Int
        let retainedEstimatedByteCount: Int
        let droppedEntryCount: Int
        let redaction: String
    }

    private struct EntrySizeComponents {
        let transport: String
        let direction: String
        let operation: String
        let method: String?
        let path: String?
        let headers: [String: String]?
        let payload: JSONValue?
        let errorType: String?
    }

    private let lock = NSLock()
    private let maximumRetainedBytes: Int
    private var state: State

    public init(
        maximumEntries: Int = 5_000,
        maximumRetainedBytes: Int = 8 * 1_024 * 1_024
    ) {
        let capacity = max(1, maximumEntries)
        self.maximumRetainedBytes = max(1, maximumRetainedBytes)
        state = State(capacity: capacity)
    }

    public var retainedEntryCount: Int {
        withLock { $0.entryCount }
    }

    public var retainedEstimatedByteCount: Int {
        withLock { $0.retainedEstimatedByteCount }
    }

    public func clear() {
        withLock { $0.clear() }
    }

    public func recordHTTPRequest(
        transport: String = "rest",
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data?,
        attempt: Int
    ) {
        var object: [String: JSONValue] = [:]
        if !query.isEmpty {
            object["query"] = .object(Self.sanitizedQuery(query))
        }
        if let body, let payload = Self.sanitizedPayload(body) {
            object["body"] = payload
        }
        append(
            transport: transport,
            direction: "request",
            operation: "http",
            method: method,
            path: path,
            attempt: attempt,
            payload: object.isEmpty ? nil : .object(object)
        )
    }

    public func recordHTTPResponse(
        transport: String = "rest",
        method: String,
        path: String,
        attempt: Int,
        response: HTTPURLResponse,
        body: Data,
        duration: Duration
    ) {
        append(
            transport: transport,
            direction: "response",
            operation: "http",
            method: method,
            path: path,
            attempt: attempt,
            statusCode: response.statusCode,
            durationMilliseconds: Self.milliseconds(duration),
            headers: Self.sanitizedHeaders(response.allHeaderFields),
            payload: Self.sanitizedPayload(body)
        )
    }

    public func recordHTTPFailure(
        transport: String = "rest",
        method: String,
        path: String,
        attempt: Int,
        duration: Duration,
        error: any Error
    ) {
        append(
            transport: transport,
            direction: "failure",
            operation: "http",
            method: method,
            path: path,
            attempt: attempt,
            durationMilliseconds: Self.milliseconds(duration),
            errorType: String(reflecting: type(of: error))
        )
    }

    public func recordGateway(
        transport: String = "gateway",
        direction: String,
        envelope: GatewayEnvelope
    ) {
        append(
            transport: transport,
            direction: direction,
            operation: envelope.eventName ?? "opcode_\(envelope.op)",
            payload: .object([
                "op": .number(Double(envelope.op)),
                "sequence": envelope.sequence.map { .number(Double($0)) } ?? .null,
                "event": envelope.eventName.map(JSONValue.string) ?? .null,
                "data": Self.sanitize(envelope.data ?? .null, key: "data", depth: 0),
            ])
        )
    }

    public func recordGatewayData(
        transport: String = "gateway",
        direction: String,
        data: Data
    ) {
        if let envelope = try? JSONDecoder().decode(GatewayEnvelope.self, from: data) {
            recordGateway(transport: transport, direction: direction, envelope: envelope)
            return
        }
        append(
            transport: transport,
            direction: direction,
            operation: "unparsed_payload",
            payload: .object(["byte_count": .number(Double(data.count))])
        )
    }

    public func recordWebSocketData(
        transport: String,
        direction: String,
        data: Data
    ) {
        let rawPayload = try? JSONDecoder().decode(JSONValue.self, from: data)
        let operation: String
        if case let .object(object)? = rawPayload,
           case let .string(op)? = object["op"]
        {
            operation = String(op.prefix(128))
        } else {
            operation = "websocket_payload"
        }
        append(
            transport: transport,
            direction: direction,
            operation: operation,
            payload: rawPayload.map {
                Self.sanitize($0, key: nil, depth: 0)
            } ?? .object(["byte_count": .number(Double(data.count))])
        )
    }

    public func exportData() throws -> Data {
        let snapshot = withLock { state in
            (
                entries: state.orderedEntries,
                retainedEstimatedByteCount:
                    state.retainedEstimatedByteCount,
                droppedEntryCount: state.droppedEntryCount
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let metadata = ExportMetadata(
            format: "sakuracord-discord-api-log-v1",
            generatedAt: .now,
            retainedEntryCount: snapshot.entries.count,
            retainedEstimatedByteCount:
                snapshot.retainedEstimatedByteCount,
            droppedEntryCount: snapshot.droppedEntryCount,
            redaction:
                "Sensitive values are discarded before retention. Message content, names, usernames, profile text, credentials, cookies, "
                    + "challenge data, filenames, and URLs are not included. Snowflake IDs and protocol metadata may be included."
        )
        var result = try encoder.encode(metadata)
        result.append(0x0A)
        for entry in snapshot.entries {
            result.append(try encoder.encode(entry))
            result.append(0x0A)
        }
        return result
    }

    public static func sanitizedPayload(_ data: Data) -> JSONValue? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object(["byte_count": .number(Double(data.count))])
        }
        return sanitize(value, key: nil, depth: 0)
    }

    private func append(
        transport: String,
        direction: String,
        operation: String,
        method: String? = nil,
        path: String? = nil,
        attempt: Int? = nil,
        statusCode: Int? = nil,
        durationMilliseconds: Int? = nil,
        headers: [String: String]? = nil,
        payload: JSONValue? = nil,
        errorType: String? = nil
    ) {
        let estimatedByteCount = Self.estimatedEntryByteCount(.init(
            transport: transport,
            direction: direction,
            operation: operation,
            method: method,
            path: path,
            headers: headers,
            payload: payload,
            errorType: errorType
        ))
        withLock { state in
            let entry = Entry(
                sequence: state.nextSequence,
                timestamp: .now,
                transport: transport,
                direction: direction,
                operation: operation,
                method: method,
                path: path,
                attempt: attempt,
                statusCode: statusCode,
                durationMilliseconds: durationMilliseconds,
                headers: headers?.isEmpty == false ? headers : nil,
                payload: payload,
                errorType: errorType
            )
            state.nextSequence &+= 1
            state.append(
                entry,
                estimatedByteCount: estimatedByteCount,
                maximumRetainedBytes: maximumRetainedBytes
            )
        }
    }

    @discardableResult
    private func withLock<Result>(_ operation: (inout State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&state)
    }

    private static let sensitiveKeys: Set<String> = [
        "authorization", "cookie", "set_cookie", "token", "access_token",
        "refresh_token", "password", "login", "email", "phone", "content",
        "username", "global_name", "display_name", "nick", "nickname", "name",
        "topic", "title", "description", "bio", "state", "custom_status",
        "filename", "uploaded_filename", "url", "proxy_url", "avatar", "banner",
        "icon", "splash", "session_id", "resume_gateway_url", "fingerprint",
        "analytics_token", "captcha_key", "captcha_rqdata", "captcha_rqtoken",
        "captcha_session_id", "ticket", "secret", "secret_key", "key",
        "public_key", "private_key", "encryption_key", "reason", "message",
        "nonce_proof", "encrypted_nonce", "encrypted_user_payload",
        "encoded_public_key",
    ]

    private static let safeStringKeys: Set<String> = [
        "status", "type", "event", "locale", "method", "platform",
        "release_channel", "os", "browser", "device", "scope",
    ]

    private static let maximumCollectionCount = 100
    private static let maximumPayloadDepth = 10

    private static func sanitize(
        _ value: JSONValue,
        key: String?,
        depth: Int
    ) -> JSONValue {
        guard depth < maximumPayloadDepth else {
            return .string("<truncated-depth>")
        }
        let normalizedKey = key?.lowercased().replacingOccurrences(of: "-", with: "_")
        if let normalizedKey, sensitiveKeys.contains(normalizedKey) {
            return .string("<redacted>")
        }
        switch value {
        case let .object(object):
            return sanitizedObject(object, depth: depth)
        case let .array(values):
            return sanitizedArray(values, key: normalizedKey, depth: depth)
        case let .string(string):
            let preservesString = normalizedKey.map(isIDKey) == true
                || normalizedKey == "nonce"
                || normalizedKey.map { safeStringKeys.contains($0) } == true
            if preservesString {
                return .string(String(string.prefix(256)))
            }
            return .string("<redacted>")
        case .number, .bool, .null:
            return value
        }
    }

    private static func sanitizedObject(
        _ object: [String: JSONValue],
        depth: Int
    ) -> JSONValue {
        let retainedPairs = object.sorted { $0.key < $1.key }
            .prefix(maximumCollectionCount)
        var result: [String: JSONValue] = [:]
        for pair in retainedPairs {
            result[pair.key] = sanitize(
                pair.value,
                key: pair.key,
                depth: depth + 1
            )
        }
        if object.count > result.count {
            result["truncated_field_count"] = .number(
                Double(object.count - result.count)
            )
        }
        return .object(result)
    }

    private static func sanitizedArray(
        _ values: [JSONValue],
        key: String?,
        depth: Int
    ) -> JSONValue {
        let retained = values.prefix(maximumCollectionCount).map {
            sanitize($0, key: key, depth: depth + 1)
        }
        guard values.count > retained.count else {
            return .array(retained)
        }
        return .array(
            retained + [
                .object([
                    "truncated_count": .number(
                        Double(values.count - retained.count)
                    )
                ])
            ]
        )
    }

    private static func sanitizedQuery(_ query: [URLQueryItem]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for item in query {
            let key = item.name.lowercased()
            let preservesValue = isIDKey(key)
                || ["before", "after", "around", "limit", "type", "with_counts"]
                    .contains(key)
            if preservesValue {
                result[item.name] = item.value.map(JSONValue.string) ?? .null
            } else {
                result[item.name] = .string("<redacted>")
            }
        }
        return result
    }

    private static func sanitizedHeaders(_ raw: [AnyHashable: Any]) -> [String: String] {
        let allowed = Set([
            "content-type", "date", "retry-after", "x-request-id",
            "x-ratelimit-bucket", "x-ratelimit-limit", "x-ratelimit-remaining",
            "x-ratelimit-reset", "x-ratelimit-reset-after", "x-ratelimit-scope",
            "x-ratelimit-global",
        ])
        return raw.reduce(into: [String: String]()) { result, pair in
            let name = String(describing: pair.key)
            guard allowed.contains(name.lowercased()) else { return }
            result[name] = String(describing: pair.value).prefix(256).description
        }
    }

    private static func isIDKey(_ key: String) -> Bool {
        key == "id"
            || key.hasSuffix("_id")
            || key.hasSuffix("_ids")
            || key == "sequence"
    }

    private static func estimatedEntryByteCount(
        _ components: EntrySizeComponents
    ) -> Int {
        var size = 256
        size += components.transport.utf8.count
        size += components.direction.utf8.count
        size += components.operation.utf8.count
        size += components.method?.utf8.count ?? 0
        size += components.path?.utf8.count ?? 0
        size += components.errorType?.utf8.count ?? 0
        if let headers = components.headers {
            size += headers.reduce(0) {
                $0 + $1.key.utf8.count + $1.value.utf8.count + 16
            }
        }
        if let payload = components.payload {
            size += estimatedJSONByteCount(payload)
        }
        return size
    }

    private static func estimatedJSONByteCount(_ value: JSONValue) -> Int {
        switch value {
        case let .object(object):
            16 + object.reduce(0) {
                $0 + $1.key.utf8.count
                    + estimatedJSONByteCount($1.value) + 16
            }
        case let .array(values):
            16 + values.reduce(0) {
                $0 + estimatedJSONByteCount($1) + 8
            }
        case let .string(string):
            string.utf8.count + 16
        case .number:
            16
        case .bool, .null:
            8
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = components.seconds * 1_000
        let attoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(clamping: seconds + attoseconds)
    }
}
