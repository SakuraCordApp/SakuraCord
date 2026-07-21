import Compression
import Foundation
import OSLog
import SakuraCordModels

private let sessionLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "GatewaySession")

enum GatewaySocketMessage: Sendable, Equatable {
    case data(Data)
    case text(String)
}

protocol GatewaySocket: Sendable {
    func receive() async throws -> GatewaySocketMessage
    func send(_ data: Data) async throws
    func close(code: Int) async
    func closeCode() async -> Int?
}

protocol GatewayTransport: Sendable {
    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket
}

protocol GatewayClock: Sendable {
    func sleep(for duration: Duration) async throws
}

protocol GatewayRandomSource: Sendable {
    func unitInterval() async -> Double
}

struct ContinuousGatewayClock: GatewayClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct SystemGatewayRandomSource: GatewayRandomSource {
    func unitInterval() async -> Double {
        Double.random(in: 0 ..< 1)
    }
}

struct URLSessionGatewayTransport: GatewayTransport {
    let session: URLSession

    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageSize
        task.resume()
        return URLSessionGatewaySocket(task: task)
    }
}

private actor URLSessionGatewaySocket: GatewaySocket {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func receive() async throws -> GatewaySocketMessage {
        switch try await task.receive() {
        case let .data(data): .data(data)
        case let .string(text): .text(text)
        @unknown default: throw GatewaySessionError.unsupportedWebSocketMessage
        }
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func close(code: Int) async {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .abnormalClosure
        task.cancel(with: closeCode, reason: nil)
    }

    func closeCode() async -> Int? {
        let value = task.closeCode.rawValue
        return value == URLSessionWebSocketTask.CloseCode.invalid.rawValue ? nil : value
    }
}

enum GatewaySessionError: Error, Equatable {
    case unsupportedWebSocketMessage
    case malformedPayload
    case compressedBufferLimitExceeded
    case decompressedPayloadLimitExceeded
    case decompressionFailed
    case stopped
}

enum GatewaySessionEvent: Sendable, Equatable {
    case stateChanged(ConnectionState)
    case dispatch(name: String, data: JSONValue)
}

actor GatewaySession {
    enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case awaitingHello
        case identifying
        case resuming
        case ready
        case backingOff(attempt: Int)
        case stopped
    }

    struct Configuration: Sendable {
        var gatewayURL: URL
        var identifyPayload: Data
        var token: String
        var maximumReconnectAttempts: Int
        var maximumMessageSize: Int
        var maximumCompressedBufferSize: Int
        var maximumDecompressedPayloadSize: Int
        var backoffBase: Duration
        var backoffCap: Duration

        init(
            gatewayURL: URL,
            identifyPayload: Data,
            token: String,
            maximumReconnectAttempts: Int = 8,
            maximumMessageSize: Int = 16 * 1024 * 1024,
            maximumCompressedBufferSize: Int = 8 * 1024 * 1024,
            maximumDecompressedPayloadSize: Int = 16 * 1024 * 1024,
            backoffBase: Duration = .seconds(1),
            backoffCap: Duration = .seconds(60)
        ) {
            self.gatewayURL = gatewayURL
            self.identifyPayload = identifyPayload
            self.token = token
            self.maximumReconnectAttempts = maximumReconnectAttempts
            self.maximumMessageSize = maximumMessageSize
            self.maximumCompressedBufferSize = maximumCompressedBufferSize
            self.maximumDecompressedPayloadSize = maximumDecompressedPayloadSize
            self.backoffBase = backoffBase
            self.backoffCap = backoffCap
        }
    }

    struct Snapshot: Sendable, Equatable {
        var state: State
        var sequence: Int?
        var sessionID: String?
        var resumeGatewayURL: String?
        var reconnectAttempts: Int
        var awaitingHeartbeatACK: Bool
    }

    private enum ConnectionOutcome {
        case reconnectImmediately(preserveSession: Bool)
        case reconnectAfterBackoff(preserveSession: Bool)
        case invalidSessionDelay
        case terminal(authenticationFailed: Bool)
        case cancelled
    }

    nonisolated let events: AsyncStream<GatewaySessionEvent>

    private let configuration: Configuration
    private let transport: any GatewayTransport
    private let clock: any GatewayClock
    private let random: any GatewayRandomSource
    private let codec: any GatewayCodec
    private let eventContinuation: AsyncStream<GatewaySessionEvent>.Continuation

    private var state: State = .disconnected
    private var socket: (any GatewaySocket)?
    private var lifecycleTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var generation = 0
    private var intentionallyStopped = false
    private var handshakeSentGeneration: Int?
    private var forcedOutcome: ConnectionOutcome?
    private var sequence: Int?
    private var sessionID: String?
    private var resumeGatewayURL: String?
    private var reconnectAttempts = 0
    private var awaitingHeartbeatACK = false
    private var heartbeatInterval: Duration?

    init(
        configuration: Configuration,
        transport: any GatewayTransport,
        clock: any GatewayClock = ContinuousGatewayClock(),
        random: any GatewayRandomSource = SystemGatewayRandomSource(),
        codec: any GatewayCodec = JSONGatewayCodec()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.clock = clock
        self.random = random
        self.codec = codec
        let stream = AsyncStream<GatewaySessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(500))
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func connect() {
        guard lifecycleTask == nil else { return }
        intentionallyStopped = false
        generation += 1
        let activeGeneration = generation
        lifecycleTask = Task { [weak self] in
            await self?.runLifecycle(generation: activeGeneration)
        }
    }

    func stop() async {
        guard state != .stopped || lifecycleTask != nil || socket != nil else { return }
        intentionallyStopped = true
        generation += 1
        lifecycleTask?.cancel()
        lifecycleTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let activeSocket = socket
        socket = nil
        await activeSocket?.close(code: 1000)
        clearResumableState()
        awaitingHeartbeatACK = false
        transition(to: .stopped)
    }

    func send(_ data: Data) async throws {
        guard !intentionallyStopped, state == .ready, let socket else { throw GatewaySessionError.stopped }
        try await socket.send(data)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            state: state,
            sequence: sequence,
            sessionID: sessionID,
            resumeGatewayURL: resumeGatewayURL,
            reconnectAttempts: reconnectAttempts,
            awaitingHeartbeatACK: awaitingHeartbeatACK
        )
    }

    private func runLifecycle(generation activeGeneration: Int) async {
        var nextOutcome: ConnectionOutcome = .reconnectImmediately(preserveSession: true)
        var isInitialConnection = true

        lifecycle: while isActive(activeGeneration) {
            switch nextOutcome {
            case let .reconnectImmediately(preserveSession):
                if !preserveSession {
                    clearResumableState()
                }
                if isInitialConnection {
                    isInitialConnection = false
                } else {
                    reconnectAttempts += 1
                    guard reconnectAttempts <= configuration.maximumReconnectAttempts else { break lifecycle }
                }
            case let .reconnectAfterBackoff(preserveSession):
                if !preserveSession {
                    clearResumableState()
                }
                guard await waitForReconnectBackoff(generation: activeGeneration) else { break lifecycle }
            case .invalidSessionDelay:
                clearResumableState()
                reconnectAttempts += 1
                guard reconnectAttempts <= configuration.maximumReconnectAttempts else { break lifecycle }
                transition(to: .backingOff(attempt: reconnectAttempts))
                do {
                    let unit = await random.unitInterval()
                    try await clock.sleep(for: .seconds(1 + (max(0, min(unit, 0.999_999)) * 4)))
                } catch { break lifecycle }
            case let .terminal(authenticationFailed):
                transition(to: .stopped)
                eventContinuation.yield(.stateChanged(authenticationFailed ? .authenticationFailed : .disconnected))
                lifecycleTask = nil
                return
            case .cancelled:
                lifecycleTask = nil
                return
            }

            guard isActive(activeGeneration) else { break }
            nextOutcome = await runConnection(generation: activeGeneration)
        }

        if generation == activeGeneration {
            lifecycleTask = nil
            if !intentionallyStopped {
                transition(to: .disconnected)
                eventContinuation.yield(.stateChanged(.disconnected))
            }
        }
    }

    private func runConnection(generation activeGeneration: Int) async -> ConnectionOutcome {
        transition(to: .connecting)
        eventContinuation.yield(.stateChanged(.connecting))
        forcedOutcome = nil
        handshakeSentGeneration = nil
        heartbeatInterval = nil
        awaitingHeartbeatACK = false

        let targetURL = connectionURL()
        let activeSocket: any GatewaySocket
        do {
            activeSocket = try await transport.connect(
                to: targetURL,
                maximumMessageSize: configuration.maximumMessageSize
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .reconnectAfterBackoff(preserveSession: true)
        }

        guard isActive(activeGeneration) else {
            await activeSocket.close(code: 1000)
            return .cancelled
        }
        socket = activeSocket
        transition(to: .awaitingHello)
        var framer: GatewayPayloadFramer
        do {
            framer = try GatewayPayloadFramer(
                maximumCompressedBufferSize: configuration.maximumCompressedBufferSize,
                maximumDecompressedPayloadSize: configuration.maximumDecompressedPayloadSize
            )
        } catch {
            await activeSocket.close(code: 4002)
            socket = nil
            return .terminal(authenticationFailed: false)
        }

        defer {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            awaitingHeartbeatACK = false
            heartbeatInterval = nil
            if generation == activeGeneration {
                socket = nil
            }
        }

        do {
            while isActive(activeGeneration) {
                let message = try await activeSocket.receive()
                let payloads = try framer.append(message)
                for payload in payloads {
                    let envelope = try codec.decode(payload)
                    if let outcome = try await process(envelope, generation: activeGeneration) {
                        await activeSocket.close(code: 4000)
                        return outcome
                    }
                }
            }
            return .cancelled
        } catch is CancellationError {
            return .cancelled
        } catch {
            if let forcedOutcome {
                self.forcedOutcome = nil
                return forcedOutcome
            }
            if error is GatewaySessionError || error is DecodingError {
                sessionLogger.fault("Gateway payload was malformed; stopping the session")
                await activeSocket.close(code: 4002)
                return .terminal(authenticationFailed: false)
            }
            let closeCode = await activeSocket.closeCode()
            return classify(closeCode: closeCode)
        }
    }

    private func process(_ envelope: GatewayEnvelope, generation activeGeneration: Int) async throws -> ConnectionOutcome? {
        if let incomingSequence = envelope.sequence {
            sequence = incomingSequence
        }

        switch envelope.op {
        case 0:
            guard let name = envelope.eventName, let data = envelope.data else {
                throw GatewaySessionError.malformedPayload
            }
            eventContinuation.yield(.dispatch(name: name, data: data))
            if name == "READY" {
                guard case let .object(object) = data,
                      case let .string(readySessionID)? = object["session_id"],
                      case let .string(readyResumeURL)? = object["resume_gateway_url"]
                else {
                    throw GatewaySessionError.malformedPayload
                }
                sessionID = readySessionID
                resumeGatewayURL = readyResumeURL
                reconnectAttempts = 0
                transition(to: .ready)
                eventContinuation.yield(.stateChanged(.ready))
            } else if name == "RESUMED" {
                reconnectAttempts = 0
                transition(to: .ready)
                eventContinuation.yield(.stateChanged(.ready))
            }
        case 1:
            try await sendHeartbeat(generation: activeGeneration, restartCadence: true)
        case 7:
            return .reconnectImmediately(preserveSession: true)
        case 9:
            guard case let .bool(canResume)? = envelope.data else {
                throw GatewaySessionError.malformedPayload
            }
            return canResume ? .reconnectImmediately(preserveSession: true) : .invalidSessionDelay
        case 10:
            guard handshakeSentGeneration != activeGeneration,
                  case let .object(hello)? = envelope.data,
                  case let .number(milliseconds)? = hello["heartbeat_interval"],
                  milliseconds > 0
            else {
                if handshakeSentGeneration == activeGeneration {
                    return nil
                }
                throw GatewaySessionError.malformedPayload
            }
            handshakeSentGeneration = activeGeneration
            let interval = Duration.seconds(milliseconds / 1000)
            heartbeatInterval = interval
            let initialUnit = await random.unitInterval()
            startHeartbeatLoop(
                generation: activeGeneration,
                initialDelay: scaled(interval, by: max(0, min(initialUnit, 0.999_999))),
                interval: interval
            )
            if canResume {
                transition(to: .resuming)
                eventContinuation.yield(.stateChanged(.resuming))
                try await sendResume()
            } else {
                transition(to: .identifying)
                try await socket?.send(configuration.identifyPayload)
            }
        case 11:
            awaitingHeartbeatACK = false
        default:
            break
        }
        return nil
    }

    private var canResume: Bool {
        sessionID != nil && resumeGatewayURL != nil && sequence != nil
    }

    private func sendResume() async throws {
        guard let sessionID, let sequence else { throw GatewaySessionError.malformedPayload }
        let envelope = GatewayEnvelope(op: 6, data: .object([
            "token": .string(configuration.token),
            "session_id": .string(sessionID),
            "seq": .number(Double(sequence))
        ]))
        try await socket?.send(codec.encode(envelope))
    }

    private func startHeartbeatLoop(generation activeGeneration: Int, initialDelay: Duration, interval: Duration) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: initialDelay)
                while !Task.isCancelled {
                    guard await self?.scheduledHeartbeat(generation: activeGeneration) == true else { return }
                    try await clock.sleep(for: interval)
                }
            } catch {
                return
            }
        }
    }

    private func scheduledHeartbeat(generation activeGeneration: Int) async -> Bool {
        guard isActive(activeGeneration), socket != nil else { return false }
        if awaitingHeartbeatACK {
            forcedOutcome = .reconnectAfterBackoff(preserveSession: true)
            let activeSocket = socket
            await activeSocket?.close(code: 4000)
            return false
        }
        do {
            try await sendHeartbeat(generation: activeGeneration, restartCadence: false)
            return true
        } catch {
            forcedOutcome = .reconnectAfterBackoff(preserveSession: true)
            let activeSocket = socket
            await activeSocket?.close(code: 4000)
            return false
        }
    }

    private func sendHeartbeat(generation activeGeneration: Int, restartCadence: Bool) async throws {
        guard isActive(activeGeneration), let socket else { throw GatewaySessionError.stopped }
        let data: JSONValue = sequence.map { .number(Double($0)) } ?? .null
        try await socket.send(codec.encode(GatewayEnvelope(op: 1, data: data)))
        awaitingHeartbeatACK = true
        if restartCadence, let interval = heartbeatInterval {
            startHeartbeatLoop(generation: activeGeneration, initialDelay: interval, interval: interval)
        }
    }

    private func waitForReconnectBackoff(generation activeGeneration: Int) async -> Bool {
        reconnectAttempts += 1
        guard reconnectAttempts <= configuration.maximumReconnectAttempts else { return false }
        transition(to: .backingOff(attempt: reconnectAttempts))
        eventContinuation.yield(.stateChanged(.backingOff))
        let exponent = min(reconnectAttempts - 1, 20)
        let baseSeconds = durationSeconds(configuration.backoffBase) * pow(2, Double(exponent))
        let cappedSeconds = min(baseSeconds, durationSeconds(configuration.backoffCap))
        let jitter = await 0.8 + (max(0, min(random.unitInterval(), 0.999_999)) * 0.4)
        do {
            try await clock.sleep(for: .seconds(cappedSeconds * jitter))
            return isActive(activeGeneration)
        } catch {
            return false
        }
    }

    private func classify(closeCode: Int?) -> ConnectionOutcome {
        switch closeCode {
        case 4004:
            .terminal(authenticationFailed: true)
        case 4001, 4002, 4003, 4005, 4010, 4011, 4012, 4013, 4014:
            .terminal(authenticationFailed: false)
        case 1000, 1001, 4007, 4009:
            .reconnectAfterBackoff(preserveSession: false)
        default:
            .reconnectAfterBackoff(preserveSession: true)
        }
    }

    private func connectionURL() -> URL {
        let base = canResume ? (resumeGatewayURL.flatMap(URL.init(string:)) ?? configuration.gatewayURL) : configuration.gatewayURL
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        func set(_ name: String, _ value: String) {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }
        set("v", "9")
        set("encoding", "json")
        set("compress", "zlib-stream")
        components.queryItems = items
        return components.url ?? base
    }

    private func clearResumableState() {
        sequence = nil
        sessionID = nil
        resumeGatewayURL = nil
    }

    private func isActive(_ activeGeneration: Int) -> Bool {
        generation == activeGeneration && !intentionallyStopped && !Task.isCancelled
    }

    private func transition(to newState: State) {
        state = newState
    }
}

private func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + (Double(components.attoseconds) / 1e18)
}

private func scaled(_ duration: Duration, by multiplier: Double) -> Duration {
    .seconds(durationSeconds(duration) * multiplier)
}

struct GatewayPayloadFramer {
    private var decoder: GatewayZlibStreamDecoder

    init(maximumCompressedBufferSize: Int, maximumDecompressedPayloadSize: Int) throws {
        decoder = try GatewayZlibStreamDecoder(
            maximumCompressedBufferSize: maximumCompressedBufferSize,
            maximumDecompressedPayloadSize: maximumDecompressedPayloadSize
        )
    }

    mutating func append(_ message: GatewaySocketMessage) throws -> [Data] {
        switch message {
        case let .text(text): [Data(text.utf8)]
        case let .data(data): try decoder.append(data)
        }
    }
}

private final class GatewayZlibStreamDecoder {
    private static let flushMarker = Data([0x00, 0x00, 0xFF, 0xFF])

    private var stream = compression_stream(
        dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 0x1)!,
        dst_size: 0,
        src_ptr: UnsafePointer<UInt8>(bitPattern: 0x1)!,
        src_size: 0,
        state: nil
    )
    private var compressedBuffer = Data()
    private let maximumCompressedBufferSize: Int
    private let maximumDecompressedPayloadSize: Int

    init(maximumCompressedBufferSize: Int, maximumDecompressedPayloadSize: Int) throws {
        self.maximumCompressedBufferSize = maximumCompressedBufferSize
        self.maximumDecompressedPayloadSize = maximumDecompressedPayloadSize
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw GatewaySessionError.decompressionFailed
        }
    }

    deinit {
        compression_stream_destroy(&stream)
    }

    func append(_ data: Data) throws -> [Data] {
        compressedBuffer.append(data)
        guard compressedBuffer.count <= maximumCompressedBufferSize else {
            throw GatewaySessionError.compressedBufferLimitExceeded
        }

        var payloads: [Data] = []
        while let range = compressedBuffer.range(of: Self.flushMarker) {
            let frameEnd = range.upperBound
            let frame = Data(compressedBuffer[..<frameEnd])
            compressedBuffer.removeSubrange(..<frameEnd)
            try payloads.append(decompress(frame))
        }
        return payloads
    }

    private func decompress(_ frame: Data) throws -> Data {
        var output = Data()
        let sourceFrame: Data = if frame.starts(with: [0x78, 0x9C]) || frame.starts(with: [0x78, 0xDA]) || frame.starts(with: [0x78, 0x01]) {
            Data(frame.dropFirst(2))
        } else {
            frame
        }
        let destinationCapacity = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
        defer { destination.deallocate() }

        try sourceFrame.withUnsafeBytes { sourceBytes in
            guard let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                throw GatewaySessionError.decompressionFailed
            }
            stream.src_ptr = source
            stream.src_size = sourceFrame.count

            repeat {
                stream.dst_ptr = destination
                stream.dst_size = destinationCapacity
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = destinationCapacity - stream.dst_size
                if produced > 0 {
                    guard output.count + produced <= maximumDecompressedPayloadSize else {
                        throw GatewaySessionError.decompressedPayloadLimitExceeded
                    }
                    output.append(destination, count: produced)
                }
                if status == COMPRESSION_STATUS_ERROR, produced == 0, stream.src_size > 0 {
                    throw GatewaySessionError.decompressionFailed
                }
                if status == COMPRESSION_STATUS_END {
                    break
                }
            } while stream.src_size > 0 || stream.dst_size == 0
        }
        return output
    }
}
