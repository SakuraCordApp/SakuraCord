import Darwin
import Foundation

/// A bounded, session-local record of Discord protocol traffic.
///
/// Payloads remain in bounded memory until saving or exporting, when sensitive
/// values are discarded. Every output uses the same redaction boundary.
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
        var supportSummary: JSONValue?
        var supportSummaryCapturedAt: Date?
        var capturesConnectionMetrics = false
        var enablesPanicSave = false
        var panicSaveErrorDescription: String?
        // Weak identity keys never retain error userInfo, response URLs, or
        // completed connections. Equal error codes are separate failures.
        let capturedFailures = NSHashTable<AnyObject>(options: [.weakMemory, .objectPointerPersonality])
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

        /// Reconcile materialized caches before releasing the store lock.
        /// The current output owns its snapshot even if these entries are evicted.
        mutating func reconcileRetainedSizes(maximumRetainedBytes: Int) {
            retainedEstimatedByteCount = 0
            for offset in 0 ..< entryCount {
                let index = (headIndex + offset) % entries.count
                guard let retained = entries[index] else { continue }
                let size = DiscordAPIDiagnosticStore.estimatedEntryByteCount(retained.entry)
                entries[index] = RetainedEntry(entry: retained.entry, estimatedByteCount: size)
                retainedEstimatedByteCount += size
            }
            while retainedEstimatedByteCount > maximumRetainedBytes {
                removeOldest()
            }
        }

        mutating func clear() {
            entries = Array(repeating: nil, count: entries.count)
            headIndex = 0
            entryCount = 0
            retainedEstimatedByteCount = 0
            droppedEntryCount = 0
            capturedFailures.removeAllObjects()
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

    /// Raw sources cannot be encoded without passing through this boundary.
    /// Materialization and retention accounting share the store lock. Replacing
    /// the source releases raw data and records the sanitized cache's size.
    private final class Payload: Encodable {
        enum Source {
            case json(JSONValue)
            case data(Data)
            case webSocketData(Data)
            case sanitized(JSONValue)
            case object([String: Payload])
        }

        private var source: Source
        private(set) var estimatedByteCount: Int
        private(set) var operationName: String?

        init(_ source: Source) {
            self.source = source
            estimatedByteCount = switch source {
            case let .json(value), let .sanitized(value):
                DiscordAPIDiagnosticStore.estimatedJSONByteCount(value)
            case let .data(data), let .webSocketData(data): data.count
            case let .object(fields):
                16 + fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.estimatedByteCount + 16 }
            }
        }

        func encode(to encoder: any Encoder) throws {
            try sanitizedValue().encode(to: encoder)
        }

        func operationForExport() -> String {
            _ = sanitizedValue()
            return operationName ?? "websocket_payload"
        }

        private func sanitizedValue() -> JSONValue {
            let value: JSONValue
            switch source {
            case let .sanitized(cached): return cached
            case let .json(raw): value = DiscordDiagnosticSanitizer.sanitize(raw)
            case let .data(raw): value = DiscordAPIDiagnosticStore.sanitizedPayload(raw) ?? .null
            case let .webSocketData(raw):
                let decoded = try? JSONDecoder().decode(DiscordDiagnosticSanitizer.WebSocketPayload.self, from: raw)
                operationName = decoded?.operation.map { String($0.prefix(128)) }
                value = decoded?.value ?? DiscordAPIDiagnosticStore.payloadSummary(raw)
            case let .object(fields): value = .object(fields.mapValues { $0.sanitizedValue() })
            }
            source = .sanitized(value)
            estimatedByteCount = DiscordAPIDiagnosticStore.estimatedJSONByteCount(value)
            return value
        }
    }

    /// WebSocket operation names are extracted with the payload at output time,
    /// avoiding a second JSON parse solely for diagnostic metadata.
    private enum Operation: Encodable {
        case named(String)
        case webSocket(Payload)

        var estimatedByteCount: Int {
            switch self {
            case let .named(name): name.utf8.count
            case let .webSocket(payload): payload.operationName?.utf8.count ?? "websocket_payload".utf8.count
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .named(name): try container.encode(name)
            case let .webSocket(payload): try container.encode(payload.operationForExport())
            }
        }
    }

    /// Output and capture both hold the store lock. Once redaction and encoding
    /// succeed, retain the immutable output rather than its expanded JSON tree.
    private final class Entry {
        private enum Source {
            case fields(EntryFields)
            case encoded(Data, estimatedByteCount: Int)
        }

        let sequence: UInt64
        private var source: Source

        init(_ fields: EntryFields) {
            sequence = fields.sequence
            source = .fields(fields)
        }

        var estimatedByteCount: Int {
            switch source {
            case let .fields(fields): DiscordAPIDiagnosticStore.estimatedEntryByteCount(fields)
            case let .encoded(_, estimatedByteCount): estimatedByteCount
            }
        }

        func encodedLine() throws -> Data {
            switch source {
            case let .encoded(data, _): return data
            case let .fields(fields):
                let data = try DiscordAPIDiagnosticStore.encodedJSONLine(fields)
                // Keep the existing conservative budget and eviction behavior
                // even though the encoded representation usually costs less.
                let cost = max(data.count, DiscordAPIDiagnosticStore.estimatedEntryByteCount(fields))
                source = .encoded(data, estimatedByteCount: cost)
                return data
            }
        }
    }

    private struct EntryFields: Encodable {
        let sequence: UInt64
        let timestamp: Date
        let transport: String
        let direction: String
        let operation: Operation
        let method: String?
        let path: String?
        let attempt: Int?
        let statusCode: Int?
        let durationMilliseconds: Int?
        let headers: [String: String]?
        let payload: Payload?
        let errorType: String?
        let errorDomain: String?
        let errorCode: Int?
    }

    private struct ExportMetadata: Codable {
        let format: String
        let generatedAt: Date
        let retainedEntryCount: Int
        let retainedEstimatedByteCount: Int
        let droppedEntryCount: Int
        let redaction: String
        let supportSummary: JSONValue?
        let supportSummaryCapturedAt: Date?
    }

    private struct DiskMetadata: Codable {
        let format: String
        let startedAt: Date
        let redaction: String
        let supportSummary: JSONValue?
        let supportSummaryCapturedAt: Date?
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

    /// The app supplies its fixed, already-sanitized support-summary schema.
    /// Never pass raw account data or arbitrary diagnostic payloads here.
    public func setSupportSummary(_ summary: JSONValue) {
        guard case .object = summary, Self.estimatedJSONByteCount(summary) <= 32 * 1_024 else { return }
        withLock { state in
            state.supportSummary = summary
            state.supportSummaryCapturedAt = .now
        }
    }

    private static func supportSummary(_ state: State, savesToDisk: Bool? = nil) -> JSONValue? {
        guard case var .object(summary) = state.supportSummary else { return nil }
        summary["diagnosticModes"] = .object([
            "capturesDetailedSanitizedPayloads": .bool(state.capturesPayloadDetails || state.enablesPanicSave),
            "capturesConnectionMetrics": .bool(state.capturesConnectionMetrics),
            "savesSanitizedDiagnosticsToDisk": .bool(savesToDisk ?? (state.diskCapture != nil)),
            "retainedEntryCount": .number(Double(state.entryCount)),
        ])
        return .object(summary)
    }

    /// Explicit detailed capture and panic save both retain payloads for sanitized output.
    /// The app restores panic save's default-on preference before networking starts.
    public var capturesPayloadDetails: Bool {
        get { withLock { $0.capturesPayloadDetails } }
        set { withLock { $0.capturesPayloadDetails = newValue } }
    }

    /// Independent opt-in; panic save and payload capture never enable this.
    public var capturesConnectionMetrics: Bool {
        get { withLock { $0.capturesConnectionMetrics } }
        set { withLock { $0.capturesConnectionMetrics = newValue } }
    }

    public var enablesPanicSave: Bool {
        get { withLock { $0.enablesPanicSave } }
        set { withLock { $0.enablesPanicSave = newValue } }
    }

    public var retainsPayloadDetails: Bool {
        withLock { $0.capturesPayloadDetails || $0.enablesPanicSave }
    }

    /// The newest snapshot. The two preceding snapshots use numbered siblings.
    public var panicSaveURL: URL {
        panicSaveURLs[0]
    }

    private var panicSaveURLs: [URL] {
        (1 ... 3).map { index in
            let suffix = index == 1 ? "" : "-\(index)"
            return diskDirectoryURL.appending(path: "SakuraCord Discord API Panic Save\(suffix).jsonl")
        }
    }

    public var panicSaveErrorDescription: String? {
        withLock { $0.panicSaveErrorDescription }
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
                        maximumFileCount: maximumDiskSessionFileCount,
                        supportSummary: Self.supportSummary(state, savesToDisk: true),
                        supportSummaryCapturedAt: state.supportSummaryCapturedAt
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
                for url in panicSaveURLs where FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                state.panicSaveErrorDescription = nil
                if resumesDiskCapture {
                    state.diskCapture = try Self.makeDiskCapture(
                        directoryURL: diskDirectoryURL,
                        maximumBytes: maximumDiskBytes,
                        maximumFileCount: maximumDiskSessionFileCount,
                        supportSummary: Self.supportSummary(state, savesToDisk: true),
                        supportSummaryCapturedAt: state.supportSummaryCapturedAt
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
        var object: [String: Payload] = [:]
        if !query.isEmpty {
            object["query"] = Payload(.sanitized(.object(Self.sanitizedQuery(query))))
        }
        if let body {
            object["body"] = payloadForRetention(body)
        }
        append(
            transport: transport,
            direction: "request",
            operation: .named("http"),
            method: method,
            path: path,
            attempt: attempt,
            payload: object.isEmpty ? nil : Payload(.object(object))
        )
    }

    func recordHTTPConnectionMetrics(
        _ metrics: RESTConnectionMetrics,
        method: String,
        path: String,
        attempt: Int
    ) {
        append(
            transport: "rest",
            direction: "metrics",
            operation: .named("http_connection"),
            method: method,
            path: path,
            attempt: attempt,
            payload: Payload(.sanitized(.object(metrics.fields))),
            requiresConnectionMetrics: true
        )
    }

    func recordRESTSessionReplacement(previousGeneration: Int, generation: Int) {
        append(
            transport: "rest",
            direction: "lifecycle",
            operation: .named("connection_pool_replaced"),
            payload: Payload(.sanitized(.object([
                "previous_generation": .number(Double(previousGeneration)),
                "generation": .number(Double(generation)),
                "reason": .string("request_timeout"),
            ]))),
            requiresConnectionMetrics: true
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
            operation: .named("http"),
            method: method,
            path: path,
            attempt: attempt,
            statusCode: response.statusCode,
            durationMilliseconds: Self.milliseconds(duration),
            headers: Self.sanitizedHeaders(response.allHeaderFields),
            payload: payloadForRetention(body),
            panicIdentity: response,
            triggersPanicSave: response.statusCode >= 400
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
            operation: .named("http"),
            method: method,
            path: path,
            attempt: attempt,
            durationMilliseconds: Self.milliseconds(duration),
            error: error,
            triggersPanicSave: !Self.isCancellation(error)
        )
    }

    public func recordGateway(
        transport: String = "gateway",
        direction: String,
        envelope: GatewayEnvelope
    ) {
        var payload: [String: Payload] = [
            "op": Payload(.sanitized(.number(Double(envelope.op)))),
            "sequence": Payload(.sanitized(envelope.sequence.map { .number(Double($0)) } ?? .null)),
            "event": Payload(.sanitized(envelope.eventName.map(JSONValue.string) ?? .null)),
        ]
        if retainsPayloadDetails {
            payload["data"] = Payload(.json(envelope.data ?? .null))
        }
        append(
            transport: transport,
            direction: direction,
            operation: .named(envelope.eventName ?? "opcode_\(envelope.op)"),
            payload: Payload(.object(payload))
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
            operation: .named("unparsed_payload"),
            payload: Payload(.sanitized(Self.payloadSummary(data)))
        )
    }

    public func recordWebSocketData(
        transport: String,
        direction: String,
        data: Data
    ) {
        let payload = retainsPayloadDetails
            ? Payload(.webSocketData(data)) : Payload(.sanitized(Self.payloadSummary(data)))
        append(
            transport: transport,
            direction: direction,
            operation: .webSocket(payload),
            payload: payload
        )
    }

    public func recordWebSocketFailure(
        transport: String,
        direction: String,
        error: any Error,
        incident: NSUUID? = nil,
        integers: [String: Int] = [:]
    ) {
        append(
            transport: transport,
            direction: "\(direction)_failure",
            operation: .named("websocket"),
            payload: integers.isEmpty ? nil : Payload(.sanitized(.object(integers.mapValues { .number(Double($0)) }))),
            error: error,
            panicIdentity: incident,
            triggersPanicSave: !Self.isCancellation(error)
        )
    }

    /// Call when an operation leaves client content unavailable, after checking
    /// that the load still belongs to the current account and presentation.
    /// Static call-site names identify the feature without retaining UI text.
    public func recordClientFailure(_ error: any Error, operation: StaticString = #function) {
        guard !Self.isCancellation(error) else { return }
        append(
            transport: "client",
            direction: "failure",
            operation: .named(operation.description),
            error: error,
            triggersPanicSave: true
        )
    }

    /// Records bounded lifecycle metadata that never contains Discord payload
    /// strings. These events remain useful when detailed payload capture is off.
    public func recordWebSocketLifecycle(
        transport: String,
        operation: String,
        integers: [String: Int] = [:],
        flags: [String: Bool] = [:],
        error: (any Error)? = nil,
        incident: NSUUID? = nil,
        triggersPanicSave: Bool = true
    ) {
        var fields = integers.mapValues { JSONValue.number(Double($0)) }
        fields.merge(flags.mapValues(JSONValue.bool)) { _, replacement in
            replacement
        }
        append(
            transport: transport,
            direction: "lifecycle",
            operation: .named(String(operation.prefix(128))),
            payload: fields.isEmpty ? nil : Payload(.sanitized(.object(fields))),
            error: error,
            panicIdentity: incident,
            triggersPanicSave: triggersPanicSave && !(error.map(Self.isCancellation) ?? false) && (operation.hasSuffix("_failed")
                || operation == "heartbeat_ack_missed"
                || (operation == "socket_closed" && ![1_000, 1_001].contains(integers["close_code"] ?? 0)))
        )
    }

    /// Preserve the thrown error's type and identity while linking it to the
    /// HTTP response that already triggered a snapshot. No error is retained.
    func coalescing(_ error: any Error, with response: HTTPURLResponse) -> any Error {
        withLock { state in
            if state.capturedFailures.contains(response) {
                state.capturedFailures.add(error as NSError)
            }
        }
        return error
    }

    public func exportData() throws -> Data {
        try withLock { state in
            defer { state.reconcileRetainedSizes(maximumRetainedBytes: maximumRetainedBytes) }
            let entries = state.orderedEntries
            let metadata = ExportMetadata(
                format: "sakuracord-discord-api-log-v2",
                generatedAt: .now,
                retainedEntryCount: entries.count,
                retainedEstimatedByteCount: state.retainedEstimatedByteCount,
                droppedEntryCount: state.droppedEntryCount,
                redaction: Self.redactionDescription,
                supportSummary: Self.supportSummary(state),
                supportSummaryCapturedAt: state.supportSummaryCapturedAt
            )
            var result = try Self.encodedJSONLine(metadata)
            for entry in entries {
                result.append(try Self.encodedJSONLine(entry))
            }
            return result
        }
    }

    public static func sanitizedPayload(_ data: Data) -> JSONValue? {
        (try? DiscordDiagnosticSanitizer.decode(data)) ?? payloadSummary(data)
    }

    private func payloadForRetention(_ data: Data) -> Payload {
        guard retainsPayloadDetails else {
            return Payload(.sanitized(Self.payloadSummary(data)))
        }
        return Payload(.data(data))
    }

    private static let redactionDescription =
        "Sensitive and user-authored values, URLs, IDs, nonces, request IDs, and rate-limit bucket IDs are discarded before writing."

    private static func payloadSummary(_ data: Data) -> JSONValue {
        .object(["byte_count": .number(Double(data.count))])
    }

    private func append(
        transport: String,
        direction: String,
        operation: Operation,
        method: String? = nil,
        path: String? = nil,
        attempt: Int? = nil,
        statusCode: Int? = nil,
        durationMilliseconds: Int? = nil,
        headers: [String: String]? = nil,
        payload: Payload? = nil,
        error: (any Error)? = nil,
        panicIdentity: AnyObject? = nil,
        triggersPanicSave: Bool = false,
        requiresConnectionMetrics: Bool = false
    ) {
        withLock { state in
            guard !requiresConnectionMetrics || state.capturesConnectionMetrics else { return }
            let entry = Entry(EntryFields(
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
                errorType: error.map { String(reflecting: type(of: $0)) },
                errorDomain: error.map { Self.sanitizedErrorDomain(($0 as NSError).domain) },
                errorCode: error.map { ($0 as NSError).code }
            ))
            state.nextSequence &+= 1
            // Disk capture may expand the payload into a sanitized cache. Account
            // for that representation before inserting it into the memory ring.
            appendToDisk(entry, state: &state)
            state.append(
                entry,
                estimatedByteCount: Self.estimatedEntryByteCount(entry),
                maximumRetainedBytes: maximumRetainedBytes
            )
            if triggersPanicSave, state.enablesPanicSave {
                let identities = [panicIdentity, error.map { $0 as NSError }].compactMap { $0 }
                let alreadyCaptured = identities.contains { state.capturedFailures.contains($0) }
                for identity in identities { state.capturedFailures.add(identity) }
                // Claim before writing: even a failed write is attempted only
                // once per incident, and concurrent reports cannot race it.
                if !alreadyCaptured {
                    savePanicSnapshot(state: &state, triggeringEntry: entry)
                }
            }
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }

    private static func sanitizedErrorDomain(_ domain: String) -> String {
        // NSError userInfo and localized descriptions can contain credentials,
        // failing URLs, paths, and response content. Keep only system domains
        // and numeric codes; custom domains are not trusted diagnostic text.
        switch domain {
        case NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
             "kCFErrorDomainCFNetwork": domain
        default: "<redacted>"
        }
    }

    /// Called under the store lock, before the entry's retention size is fixed.
    private func appendToDisk(_ entry: Entry, state: inout State) {
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

    /// Called under the store lock so the triggering entry, replacement, clear,
    /// and preference changes are ordered with all other diagnostic writes.
    private func savePanicSnapshot(state: inout State, triggeringEntry: Entry) {
        defer { state.reconcileRetainedSizes(maximumRetainedBytes: maximumRetainedBytes) }
        do {
            var entries = state.orderedEntries
            let recoveredTrigger = entries.last?.sequence != triggeringEntry.sequence
            if recoveredTrigger {
                entries.append(triggeringEntry)
            }
            var lines: [Data] = []
            var byteCount = 0
            // Reserve the actual summary/header size plus count-field headroom.
            let headerReserve = try Self.encodedJSONLine(ExportMetadata(
                format: "sakuracord-discord-api-log-v2",
                generatedAt: .now,
                retainedEntryCount: entries.count,
                retainedEstimatedByteCount: state.retainedEstimatedByteCount,
                droppedEntryCount: state.droppedEntryCount + entries.count,
                redaction: Self.redactionDescription,
                supportSummary: Self.supportSummary(state),
                supportSummaryCapturedAt: state.supportSummaryCapturedAt
            )).count + 128
            for entry in entries.reversed() {
                let line = try Self.encodedJSONLine(entry)
                guard byteCount + line.count + headerReserve <= maximumDiskBytes else { break }
                lines.append(line)
                byteCount += line.count
            }
            guard !lines.isEmpty else { throw CocoaError(.fileWriteOutOfSpace) }
            let metadata = ExportMetadata(
                format: "sakuracord-discord-api-log-v2",
                generatedAt: .now,
                retainedEntryCount: lines.count,
                retainedEstimatedByteCount: byteCount,
                droppedEntryCount: state.droppedEntryCount - (recoveredTrigger ? 1 : 0)
                    + entries.count - lines.count,
                redaction: Self.redactionDescription,
                supportSummary: Self.supportSummary(state),
                supportSummaryCapturedAt: state.supportSummaryCapturedAt
            )
            var data = try Self.encodedJSONLine(metadata)
            for line in lines.reversed() { data.append(line) }
            guard data.count <= maximumDiskBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try Self.writePrivateSnapshot(data, rotating: panicSaveURLs)
            state.panicSaveErrorDescription = nil
        } catch {
            state.panicSaveErrorDescription = "Panic save failed (\(String(reflecting: type(of: error))))."
        }
    }

    private static func writePrivateSnapshot(_ data: Data, rotating destinations: [URL]) throws {
        let destination = destinations[0]
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for url in destinations where fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        let temporary = directory.appending(path: ".panic-\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? fileManager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        // Finish writing before rotating, preserving existing snapshots on write
        // failure. Each rename is atomic; the oldest slot is replaced first.
        for index in stride(from: destinations.count - 1, through: 1, by: -1) {
            let previous = destinations[index - 1]
            guard fileManager.fileExists(atPath: previous.path) else { continue }
            guard rename(previous.path, destinations[index].path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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

    private static func sanitizedQuery(_ query: [URLQueryItem]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for item in query {
            let key = item.name.lowercased()
            let isIdentifier = DiscordDiagnosticSanitizer.isIDKey(key)
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
                guard segment != "@me", segment != "refresh-urls" else { return segment }
                return "<redacted-id>"
            }
            redactedChildCount = identifierChildCounts[segment.lowercased()] ?? 0
            return DiscordDiagnosticSanitizer.isIdentifierString(segment) ? "<redacted-id>" : segment
        }.joined(separator: "/")
    }

    private static func estimatedEntryByteCount(
        _ entry: Entry
    ) -> Int {
        entry.estimatedByteCount
    }

    private static func estimatedEntryByteCount(
        _ entry: EntryFields
    ) -> Int {
        var size = 256
        size += entry.transport.utf8.count
        size += entry.direction.utf8.count
        size += entry.operation.estimatedByteCount
        size += entry.method?.utf8.count ?? 0
        size += entry.path?.utf8.count ?? 0
        size += entry.errorType?.utf8.count ?? 0
        size += entry.errorDomain?.utf8.count ?? 0
        if let headers = entry.headers {
            size += headers.reduce(0) {
                $0 + $1.key.utf8.count + $1.value.utf8.count + 16
            }
        }
        if let payload = entry.payload {
            size += payload.estimatedByteCount
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
        maximumFileCount: Int,
        supportSummary: JSONValue?,
        supportSummaryCapturedAt: Date?
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
                redaction: Self.redactionDescription,
                supportSummary: supportSummary,
                supportSummaryCapturedAt: supportSummaryCapturedAt
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

    private static func encodedJSONLine(_ entry: Entry) throws -> Data {
        try entry.encodedLine()
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
