import Foundation

/// A bounded, session-local record of Discord protocol traffic.
///
/// Payloads are sanitized before they enter the store. The export therefore
/// cannot recover credentials, message text, names, profile text, URLs, or
/// other user-authored strings that were deliberately discarded here.
public final class DiscordAPIDiagnosticStore: @unchecked Sendable {
    public static let shared = DiscordAPIDiagnosticStore()
    public static let defaultMaximumDiskBytes = 64 * 1_024 * 1_024
    public static let defaultMaximumDiskSessionFileCount = 4

    private struct DiskCapture {
        let fileURL: URL
        let handle: FileHandle
        var byteCount: Int
    }

    private struct RetainedEntry {
        let entry: Entry
        let estimatedByteCount: Int
    }

    private struct State {
        var entries: [RetainedEntry?]
        var capturesPayloadDetails: Bool
        var diskCapture: DiskCapture?
        var diskLoggingErrorDescription: String?
        var headIndex = 0
        var entryCount = 0
        var retainedEstimatedByteCount = 0
        var nextSequence: UInt64 = 1
        var droppedEntryCount = 0

        init(capacity: Int, capturesPayloadDetails: Bool) {
            entries = Array(repeating: nil, count: capacity)
            self.capturesPayloadDetails = capturesPayloadDetails
            diskCapture = nil
            diskLoggingErrorDescription = nil
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

    private struct DiskMetadata: Codable {
        let format: String
        let startedAt: Date
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
    private let maximumDiskBytes: Int
    private let maximumDiskSessionFileCount: Int
    private let configuredDiskDirectoryURL: URL?
    private var state: State

    public init(
        maximumEntries: Int = 5_000,
        maximumRetainedBytes: Int = 8 * 1_024 * 1_024,
        capturesPayloadDetails: Bool = false,
        diskDirectoryURL: URL? = nil,
        maximumDiskBytes: Int = defaultMaximumDiskBytes,
        maximumDiskSessionFileCount: Int = defaultMaximumDiskSessionFileCount
    ) {
        let capacity = max(1, maximumEntries)
        self.maximumRetainedBytes = max(1, maximumRetainedBytes)
        self.maximumDiskBytes = max(1, maximumDiskBytes)
        self.maximumDiskSessionFileCount = max(
            1,
            maximumDiskSessionFileCount
        )
        configuredDiskDirectoryURL = diskDirectoryURL
        state = State(
            capacity: capacity,
            capturesPayloadDetails: capturesPayloadDetails
        )
    }

    deinit {
        try? state.diskCapture?.handle.close()
    }

    /// Detailed payload diagnostics deliberately default to off. Sanitizing a
    /// large message or member response otherwise decodes and walks the same
    /// payload a second time on every ordinary request. Route, status, timing,
    /// rate-limit headers, and byte counts remain available in the lightweight
    /// default mode.
    public var capturesPayloadDetails: Bool {
        get { withLock { $0.capturesPayloadDetails } }
        set { withLock { $0.capturesPayloadDetails = newValue } }
    }

    public var retainedEntryCount: Int {
        withLock { $0.entryCount }
    }

    public var retainedEstimatedByteCount: Int {
        withLock { $0.retainedEstimatedByteCount }
    }

    public var savesDiagnosticsToDisk: Bool {
        withLock { $0.diskCapture != nil }
    }

    public var currentDiskLogURL: URL? {
        withLock { $0.diskCapture?.fileURL }
    }

    public var diskLoggingErrorDescription: String? {
        withLock { $0.diskLoggingErrorDescription }
    }

    public var diskDirectoryURL: URL {
        configuredDiskDirectoryURL ?? Self.defaultDiskDirectoryURL()
    }

    public func setSavesDiagnosticsToDisk(_ savesToDisk: Bool) throws {
        try withLock { state in
            state.diskLoggingErrorDescription = nil
            if savesToDisk {
                guard state.diskCapture == nil else { return }
                do {
                    state.diskCapture = try Self.makeDiskCapture(
                        directoryURL: diskDirectoryURL,
                        maximumBytes: maximumDiskBytes,
                        maximumFileCount: maximumDiskSessionFileCount
                    )
                } catch {
                    state.diskLoggingErrorDescription = String(
                        reflecting: type(of: error)
                    )
                    throw error
                }
            } else if let capture = state.diskCapture {
                state.diskCapture = nil
                try capture.handle.close()
            }
        }
    }

    public func clear() {
        withLock { $0.clear() }
    }

    /// Clears the in-memory ring and every managed session file. If disk
    /// capture was active, it resumes in a fresh bounded file.
    public func clearMemoryAndDisk() throws {
        try withLock { state in
            state.clear()
            let resumesDiskCapture = state.diskCapture != nil
            if let capture = state.diskCapture {
                state.diskCapture = nil
                try capture.handle.close()
            }
            do {
                try Self.removeDiskCaptures(in: diskDirectoryURL)
                if resumesDiskCapture {
                    state.diskCapture = try Self.makeDiskCapture(
                        directoryURL: diskDirectoryURL,
                        maximumBytes: maximumDiskBytes,
                        maximumFileCount: maximumDiskSessionFileCount
                    )
                }
                state.diskLoggingErrorDescription = nil
            } catch {
                state.diskLoggingErrorDescription = String(
                    reflecting: type(of: error)
                )
                throw error
            }
        }
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
        if let body {
            object["body"] = payloadForRetention(body)
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
            payload: payloadForRetention(body)
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
        var payload: [String: JSONValue] = [
            "op": .number(Double(envelope.op)),
            "sequence": envelope.sequence.map { .number(Double($0)) } ?? .null,
            "event": envelope.eventName.map(JSONValue.string) ?? .null,
        ]
        if capturesPayloadDetails {
            payload["data"] = Self.sanitize(
                envelope.data ?? .null,
                key: "data",
                depth: 0
            )
        }
        append(
            transport: transport,
            direction: direction,
            operation: envelope.eventName ?? "opcode_\(envelope.op)",
            payload: .object(payload)
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
        guard capturesPayloadDetails else {
            append(
                transport: transport,
                direction: direction,
                operation: "websocket_payload",
                payload: Self.payloadSummary(data)
            )
            return
        }
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

    public func recordWebSocketFailure(
        transport: String,
        direction: String,
        error: any Error
    ) {
        append(
            transport: transport,
            direction: "\(direction)_failure",
            operation: "websocket",
            errorType: String(reflecting: type(of: error))
        )
    }

    /// Records bounded lifecycle metadata that never contains Discord payload
    /// strings. These events remain useful when detailed payload capture is off.
    public func recordWebSocketLifecycle(
        transport: String,
        operation: String,
        integers: [String: Int] = [:],
        flags: [String: Bool] = [:]
    ) {
        var fields = integers.mapValues { JSONValue.number(Double($0)) }
        fields.merge(flags.mapValues(JSONValue.bool)) { _, replacement in
            replacement
        }
        append(
            transport: transport,
            direction: "lifecycle",
            operation: String(operation.prefix(128)),
            payload: fields.isEmpty ? nil : .object(fields)
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
            format: "sakuracord-discord-api-log-v2",
            generatedAt: .now,
            retainedEntryCount: snapshot.entries.count,
            retainedEstimatedByteCount:
                snapshot.retainedEstimatedByteCount,
            droppedEntryCount: snapshot.droppedEntryCount,
            redaction:
                "Sensitive values are discarded before retention. Message content, names, usernames, profile text, credentials, cookies, "
                    + "challenge data, filenames, URLs, IDs, nonces, request IDs, and rate-limit bucket IDs are not included."
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

    private func payloadForRetention(_ data: Data) -> JSONValue {
        guard capturesPayloadDetails else {
            return Self.payloadSummary(data)
        }
        return Self.sanitizedPayload(data) ?? Self.payloadSummary(data)
    }

    private static func payloadSummary(_ data: Data) -> JSONValue {
        .object(["byte_count": .number(Double(data.count))])
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
                path: path.map(Self.sanitizedPath),
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
            guard var capture = state.diskCapture else { return }
            do {
                let line = try Self.encodedJSONLine(entry)
                guard capture.byteCount + line.count <= maximumDiskBytes else {
                    try? capture.handle.close()
                    state.diskCapture = nil
                    state.diskLoggingErrorDescription =
                        "Disk diagnostics reached the per-session size limit and stopped."
                    return
                }
                try capture.handle.write(contentsOf: line)
                capture.byteCount += line.count
                state.diskCapture = capture
            } catch {
                try? capture.handle.close()
                state.diskCapture = nil
                state.diskLoggingErrorDescription = String(
                    reflecting: type(of: error)
                )
            }
        }
    }

    @discardableResult
    private func withLock<Result>(
        _ operation: (inout State) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&state)
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
        if normalizedKey.map(isIDKey) == true || normalizedKey == "nonce" {
            return .string("<redacted-id>")
        }
        switch value {
        case let .object(object):
            return sanitizedObject(object, depth: depth)
        case let .array(values):
            return sanitizedArray(values, key: normalizedKey, depth: depth)
        case let .string(string):
            let preservesString = normalizedKey.map { safeStringKeys.contains($0) } == true
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
        for (index, pair) in retainedPairs.enumerated() {
            let retainedKey = isIdentifierString(pair.key)
                ? "<redacted-id-key-\(index + 1)>"
                : pair.key
            result[retainedKey] = sanitize(
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
            let isIdentifier = isIDKey(key)
                || ["before", "after", "around"].contains(key)
            let preservesValue = ["limit", "type", "with_counts"]
                    .contains(key)
            if isIdentifier {
                result[item.name] = .string("<redacted-id>")
            } else if preservesValue {
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
            if ["x-request-id", "x-ratelimit-bucket"].contains(name.lowercased()) {
                result[name] = "<redacted-id>"
            } else {
                result[name] = String(describing: pair.value).prefix(256).description
            }
        }
    }

    private static func sanitizedPath(_ path: String) -> String {
        let identifierChildCounts: [String: Int] = [
            "applications": 1, "attachments": 1, "channels": 1,
            "collectibles-products": 1, "guilds": 1, "invites": 1,
            "messages": 1, "reactions": 1, "roles": 1, "users": 1,
            "webhooks": 2,
        ]
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        var redactedChildCount = 0
        return segments.map { rawSegment in
            let segment = String(rawSegment)
            if redactedChildCount > 0 {
                redactedChildCount -= 1
                guard segment != "@me" else { return segment }
                return "<redacted-id>"
            }
            redactedChildCount = identifierChildCounts[segment.lowercased()] ?? 0
            return isIdentifierString(segment) ? "<redacted-id>" : segment
        }.joined(separator: "/")
    }

    private static func isIdentifierString(_ value: String) -> Bool {
        !value.isEmpty && (value.allSatisfy(\.isNumber) || UUID(uuidString: value) != nil)
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

    private static func defaultDiskDirectoryURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "SakuraCord", directoryHint: .isDirectory)
            .appending(path: "Diagnostics", directoryHint: .isDirectory)
    }

    private static func makeDiskCapture(
        directoryURL: URL,
        maximumBytes: Int,
        maximumFileCount: Int
    ) throws -> DiskCapture {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try pruneDiskCaptures(
            in: directoryURL,
            keepingExistingCount: max(0, maximumFileCount - 1)
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let baseName = "SakuraCord Discord API Logs \(formatter.string(from: .now))"
        var fileURL = directoryURL.appending(path: "\(baseName).jsonl")
        var suffix = 2
        while fileManager.fileExists(atPath: fileURL.path) {
            fileURL = directoryURL.appending(path: "\(baseName)-\(suffix).jsonl")
            suffix += 1
        }
        guard fileManager.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            let metadata = DiskMetadata(
                format: "sakuracord-discord-api-log-v2",
                startedAt: .now,
                redaction:
                    "Sensitive and user-authored values, URLs, IDs, nonces, request IDs, and rate-limit bucket IDs are discarded before writing."
            )
            let line = try encodedJSONLine(metadata)
            guard line.count <= maximumBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try handle.write(contentsOf: line)
            return DiskCapture(
                fileURL: fileURL,
                handle: handle,
                byteCount: line.count
            )
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: fileURL)
            throw error
        }
    }

    private static func pruneDiskCaptures(
        in directoryURL: URL,
        keepingExistingCount: Int
    ) throws {
        let files = try diskCaptureFiles(in: directoryURL)
        let removalCount = max(0, files.count - keepingExistingCount)
        for file in files.prefix(removalCount) {
            try FileManager.default.removeItem(at: file.url)
        }
    }

    private static func removeDiskCaptures(in directoryURL: URL) throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        for file in try diskCaptureFiles(in: directoryURL) {
            try FileManager.default.removeItem(at: file.url)
        }
    }

    private static func diskCaptureFiles(
        in directoryURL: URL
    ) throws -> [(url: URL, date: Date)] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasPrefix(
                "SakuraCord Discord API Logs "
            ), url.pathExtension == "jsonl",
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        .sorted {
            if $0.1 == $1.1 {
                return $0.0.lastPathComponent < $1.0.lastPathComponent
            }
            return $0.1 < $1.1
        }
    }

    private static func encodedJSONLine<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
