@testable import DiscordProtocol
import Foundation
import Testing

@Test func `hello identifies once and repeated connect does not duplicate socket or heartbeat`() async throws {
    let socket = FakeGatewaySocket()
    let transport = FakeGatewayTransport(sockets: [socket])
    let clock = ManualGatewayClock()
    let session = makeGatewaySession(transport: transport, clock: clock, randomValues: [0.25])

    await session.connect()
    await session.connect()
    #expect(await eventually { await transport.connectionCount == 1 })

    await socket.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(40000)])))
    #expect(await eventually { await socket.sentCount == 1 })
    #expect(try await sentEnvelope(socket, at: 0).op == 2)
    #expect(await eventually { await clock.activeWaitCount == 1 })
    #expect(await clock.recordedDurations.first.map(seconds) == 10)

    await socket.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(40000)])))
    await Task.yield()
    #expect(await socket.sentCount == 1)
    #expect(await clock.activeWaitCount == 1)
    await session.stop()
}

@Test func `ready captures session and next hello resumes with latest sequence`() async throws {
    let first = FakeGatewaySocket()
    let second = FakeGatewaySocket()
    let transport = FakeGatewayTransport(sockets: [first, second])
    let clock = ManualGatewayClock()
    let session = makeGatewaySession(transport: transport, clock: clock, randomValues: [0, 0.5, 0])

    await session.connect()
    #expect(await eventually { await transport.connectionCount == 1 })
    await first.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(30000)])))
    await first.push(envelope(
        op: 0,
        data: .object([
            "session_id": .string("session-one"),
            "resume_gateway_url": .string("wss://resume.discord.gg")
        ]),
        sequence: 42,
        eventName: "READY"
    ))
    #expect(await eventually { await session.snapshot().state == .ready })
    let ready = await session.snapshot()
    #expect(ready.sessionID == "session-one")
    #expect(ready.resumeGatewayURL == "wss://resume.discord.gg")
    #expect(ready.sequence == 42)

    await first.terminate(code: nil)
    #expect(await eventually { await session.snapshot().state == .backingOff(attempt: 1) })
    await clock.advance(durationMatching: 1)
    #expect(await eventually { await transport.connectionCount == 2 })
    let secondURL = await transport.connectedURLs.last
    #expect(secondURL?.host == "resume.discord.gg")
    #expect(try URLComponents(url: #require(secondURL), resolvingAgainstBaseURL: false)?.queryItems?.contains(
        URLQueryItem(name: "compress", value: "zlib-stream")
    ) == true)

    await second.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(30000)])))
    #expect(await eventually { await second.sentCount == 1 })
    let resume = try await sentEnvelope(second, at: 0)
    #expect(resume.op == 6)
    #expect(resume.data == .object([
        "token": .string("test-token"),
        "session_id": .string("session-one"),
        "seq": .number(42)
    ]))

    await second.push(envelope(op: 0, data: .object([:]), sequence: 43, eventName: "RESUMED"))
    #expect(await eventually { await session.snapshot().state == .ready })
    #expect(await session.snapshot().reconnectAttempts == 0)
    await session.stop()
}

@Test func `heartbeat uses latest sequence ACK and missed ACK recovers exactly once`() async throws {
    let first = FakeGatewaySocket()
    let second = FakeGatewaySocket()
    let transport = FakeGatewayTransport(sockets: [first, second])
    let clock = ManualGatewayClock()
    let session = makeGatewaySession(transport: transport, clock: clock, randomValues: [0.5, 0.5, 0])

    await session.connect()
    #expect(await eventually { await transport.connectionCount == 1 })
    await first.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(20000)])))
    await first.push(envelope(op: 0, data: .object(["value": .bool(true)]), sequence: 99, eventName: "TEST"))
    #expect(await eventually { await clock.activeWaitCount == 1 })
    #expect(await clock.recordedDurations.first.map(seconds) == 10)

    await clock.advanceNext()
    #expect(await eventually { await first.sentCount == 2 })
    let heartbeat = try await sentEnvelope(first, at: 1)
    #expect(heartbeat.op == 1)
    #expect(heartbeat.data == .number(99))
    #expect(await session.snapshot().awaitingHeartbeatACK)

    await first.push(envelope(op: 11, data: .null))
    #expect(await eventually { await !(session.snapshot().awaitingHeartbeatACK) })
    #expect(await eventually { await clock.activeWaitCount == 1 })
    await clock.advanceNext()
    #expect(await eventually { await first.sentCount == 3 })

    #expect(await eventually { await clock.activeWaitCount == 1 })
    await clock.advanceNext()
    #expect(await eventually { await first.closeCodes.count == 1 })
    #expect(await first.closeCodes == [4000])
    #expect(await eventually { await session.snapshot().state == .backingOff(attempt: 1) })
    await Task.yield()
    #expect(await first.closeCodes.count == 1)
    await session.stop()
}

@Test func `server requested heartbeat is immediate and restarts cadence`() async throws {
    let socket = FakeGatewaySocket()
    let transport = FakeGatewayTransport(sockets: [socket])
    let clock = ManualGatewayClock()
    let session = makeGatewaySession(transport: transport, clock: clock, randomValues: [0.75])

    await session.connect()
    #expect(await eventually { await transport.connectionCount == 1 })
    await socket.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(12000)])))
    #expect(await eventually { await socket.sentCount == 1 })
    await socket.push(envelope(op: 1, data: .null))
    #expect(await eventually { await socket.sentCount == 2 })
    #expect(try await sentEnvelope(socket, at: 1).op == 1)
    #expect(await eventually { await clock.activeDurations.contains(where: { seconds($0) == 12 }) })
    await session.stop()
}

@Test func `reconnect and invalid session choose immediate resume or delayed identify`() async throws {
    let one = FakeGatewaySocket()
    let two = FakeGatewaySocket()
    let three = FakeGatewaySocket()
    let four = FakeGatewaySocket()
    let transport = FakeGatewayTransport(sockets: [one, two, three, four])
    let clock = ManualGatewayClock()
    let session = makeGatewaySession(transport: transport, clock: clock, randomValues: [0, 0, 0, 0.5, 0])

    await session.connect()
    #expect(await eventually { await transport.connectionCount == 1 })
    await one.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(30000)])))
    await one.push(envelope(
        op: 0,
        data: .object([
            "session_id": .string("s"),
            "resume_gateway_url": .string("wss://resume.discord.gg")
        ]),
        sequence: 7,
        eventName: "READY"
    ))
    #expect(await eventually { await session.snapshot().state == .ready })
    await one.push(envelope(op: 7, data: .null))
    #expect(await eventually { await transport.connectionCount == 2 })
    await two.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(30000)])))
    #expect(await eventually { await two.sentCount == 1 })
    #expect(try await sentEnvelope(two, at: 0).op == 6)

    await two.push(envelope(op: 9, data: .bool(true)))
    #expect(await eventually { await transport.connectionCount == 3 })
    await three.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(30000)])))
    #expect(await eventually { await three.sentCount == 1 })
    #expect(try await sentEnvelope(three, at: 0).op == 6)

    await three.push(envelope(op: 9, data: .bool(false)))
    #expect(await eventually { await session.snapshot().state == .backingOff(attempt: 3) })
    #expect(await eventually { await clock.activeDurations.contains(where: { seconds($0) == 3 }) })
    await clock.advance(durationMatching: 3)
    #expect(await eventually { await transport.connectionCount == 4 })
    await four.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(30000)])))
    #expect(await eventually { await four.sentCount == 1 })
    #expect(try await sentEnvelope(four, at: 0).op == 2)
    #expect(await session.snapshot().sessionID == nil)
    await session.stop()
}

@Test func `terminal close stops and explicit stop never reconnects`() async {
    let terminalSocket = FakeGatewaySocket()
    let terminalTransport = FakeGatewayTransport(sockets: [terminalSocket])
    let terminalClock = ManualGatewayClock()
    let terminal = makeGatewaySession(transport: terminalTransport, clock: terminalClock, randomValues: [])
    await terminal.connect()
    #expect(await eventually { await terminalTransport.connectionCount == 1 })
    await terminalSocket.terminate(code: 4004)
    #expect(await eventually { await terminal.snapshot().state == .stopped })
    #expect(await terminalTransport.connectionCount == 1)

    let socket = FakeGatewaySocket()
    let spare = FakeGatewaySocket()
    let transport = FakeGatewayTransport(sockets: [socket, spare])
    let clock = ManualGatewayClock()
    let session = makeGatewaySession(transport: transport, clock: clock, randomValues: [])
    await session.connect()
    #expect(await eventually { await transport.connectionCount == 1 })
    await session.stop()
    await clock.advanceAll()
    for _ in 0 ..< 20 {
        await Task.yield()
    }
    #expect(await transport.connectionCount == 1)
    #expect(await session.snapshot().state == .stopped)
}

@Test func `invalid sequence close discards resume state before reconnect`() async throws {
    let first = FakeGatewaySocket()
    let second = FakeGatewaySocket()
    let transport = FakeGatewayTransport(sockets: [first, second])
    let clock = ManualGatewayClock()
    let session = makeGatewaySession(transport: transport, clock: clock, randomValues: [0, 0.5, 0])
    await session.connect()
    #expect(await eventually { await transport.connectionCount == 1 })
    await first.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(30000)])))
    await first.push(envelope(
        op: 0,
        data: .object([
            "session_id": .string("discard-me"),
            "resume_gateway_url": .string("wss://resume.discord.gg")
        ]),
        sequence: 55,
        eventName: "READY"
    ))
    #expect(await eventually { await session.snapshot().state == .ready })
    await first.terminate(code: 4007)
    #expect(await eventually { await session.snapshot().state == .backingOff(attempt: 1) })
    await clock.advance(durationMatching: 1)
    #expect(await eventually { await transport.connectionCount == 2 })
    await second.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(30000)])))
    #expect(await eventually { await second.sentCount == 1 })
    #expect(try await sentEnvelope(second, at: 0).op == 2)
    #expect(await session.snapshot().sessionID == nil)
    await session.stop()
}

@Test func `backoff is exponential capped attempt bounded and cancellation safe`() async {
    let transport = FakeGatewayTransport(sockets: [])
    let clock = ManualGatewayClock()
    let session = makeGatewaySession(
        transport: transport,
        clock: clock,
        randomValues: [0.5, 0.5, 0.5],
        maximumReconnectAttempts: 2,
        backoffCap: .seconds(2)
    )
    await session.connect()
    #expect(await eventually { await clock.activeWaitCount == 1 })
    #expect(await seconds(clock.activeDurations[0]) == 1)
    await clock.advanceNext()
    #expect(await eventually {
        let waits = await clock.activeWaitCount
        let connections = await transport.connectionCount
        return waits == 1 && connections == 2
    })
    #expect(await seconds(clock.activeDurations[0]) == 2)
    await clock.advanceNext()
    #expect(await eventually { await session.snapshot().state == .disconnected })
    #expect(await transport.connectionCount == 3)

    let cancellationTransport = FakeGatewayTransport(sockets: [])
    let cancellationClock = ManualGatewayClock()
    let cancelled = makeGatewaySession(transport: cancellationTransport, clock: cancellationClock, randomValues: [0.5])
    await cancelled.connect()
    #expect(await eventually { await cancellationClock.activeWaitCount == 1 })
    await cancelled.stop()
    await cancellationClock.advanceAll()
    #expect(await cancellationTransport.connectionCount == 1)
}

@Test func `cancellation during connect closes late socket without reconnect`() async throws {
    let transport = BlockingGatewayTransport()
    let clock = ManualGatewayClock()
    let session = try GatewaySession(
        configuration: GatewaySession.Configuration(
            gatewayURL: #require(URL(string: "wss://gateway.discord.gg")),
            identifyPayload: Data(#"{"op":2,"d":{}}"#.utf8),
            token: "test-token"
        ),
        transport: transport,
        clock: clock,
        random: SequenceGatewayRandom(values: [])
    )
    let socket = FakeGatewaySocket()
    await session.connect()
    #expect(await eventually { await transport.connectionCount == 1 })
    await session.stop()
    await transport.release(socket)
    #expect(await eventually { await socket.closeCodes == [1000] })
    #expect(await transport.connectionCount == 1)
    #expect(await session.snapshot().state == .stopped)
}

@Test func `zlib framer handles fragmentation multiple payloads and bounds`() throws {
    let first = try #require(Data(base64Encoded: "eJyqVsovULIyNNRRSlGyyivNyakFAAAA//8="))
    let second = try #require(Data(base64Encoded: "qoaIIAQAAAAA//8="))
    var framer = try GatewayPayloadFramer(
        maximumCompressedBufferSize: 1024,
        maximumDecompressedPayloadSize: 1024
    )
    let split = first.count / 2
    #expect(try framer.append(.data(first.prefix(split))) == [])
    let firstPayload = try framer.append(.data(first.suffix(from: split)))
    #expect(firstPayload == [Data(#"{"op":11,"d":null}"#.utf8)])
    let secondPayload = try framer.append(.data(second))
    #expect(secondPayload == [Data(#"{"op":1,"d":null}"#.utf8)])

    let combined = try #require(Data(base64Encoded: "eJyqVsovULIyNNRRSlGyyivNyakFAAAA//+qhoggBAAAAAD//w=="))
    var combinedFramer = try GatewayPayloadFramer(
        maximumCompressedBufferSize: 1024,
        maximumDecompressedPayloadSize: 1024
    )
    #expect(try combinedFramer.append(.data(combined)).count == 2)

    var bounded = try GatewayPayloadFramer(
        maximumCompressedBufferSize: 2,
        maximumDecompressedPayloadSize: 1024
    )
    #expect(throws: GatewaySessionError.compressedBufferLimitExceeded) {
        try bounded.append(.data(Data([1, 2, 3])))
    }
}

@Test func `malformed payload fails closed without reconnect storm`() async {
    let socket = FakeGatewaySocket()
    let spare = FakeGatewaySocket()
    let transport = FakeGatewayTransport(sockets: [socket, spare])
    let clock = ManualGatewayClock()
    let session = makeGatewaySession(transport: transport, clock: clock, randomValues: [])
    await session.connect()
    #expect(await eventually { await transport.connectionCount == 1 })
    await socket.push(.text("not-json"))
    #expect(await eventually { await session.snapshot().state == .stopped })
    #expect(await transport.connectionCount == 1)
    #expect(await socket.closeCodes == [4002])
}

@Test func `existing message member presence and voice dispatches remain lossless`() async {
    let socket = FakeGatewaySocket()
    let transport = FakeGatewayTransport(sockets: [socket])
    let clock = ManualGatewayClock()
    let session = makeGatewaySession(transport: transport, clock: clock, randomValues: [0])
    let recorder = GatewayEventRecorder()
    let eventTask = Task {
        for await event in session.events {
            await recorder.append(event)
        }
    }
    await session.connect()
    #expect(await eventually { await transport.connectionCount == 1 })
    await socket.push(envelope(op: 10, data: .object(["heartbeat_interval": .number(30000)])))
    let names = ["MESSAGE_CREATE", "GUILD_MEMBER_LIST_UPDATE", "PRESENCE_UPDATE", "VOICE_STATE_UPDATE"]
    for (index, name) in names.enumerated() {
        await socket.push(envelope(
            op: 0,
            data: .object(["fixture": .string(name)]),
            sequence: index + 1,
            eventName: name
        ))
    }
    #expect(await eventually { await recorder.dispatchNames == names })
    #expect(await session.snapshot().sequence == 4)
    eventTask.cancel()
    await session.stop()
}

private func makeGatewaySession(
    transport: FakeGatewayTransport,
    clock: ManualGatewayClock,
    randomValues: [Double],
    maximumReconnectAttempts: Int = 8,
    backoffCap: Duration = .seconds(60)
) -> GatewaySession {
    let identify = try! JSONGatewayCodec().encode(GatewayEnvelope(op: 2, data: .object([
        "token": .string("test-token")
    ])))
    return GatewaySession(
        configuration: GatewaySession.Configuration(
            gatewayURL: URL(string: "wss://gateway.discord.gg")!,
            identifyPayload: identify,
            token: "test-token",
            maximumReconnectAttempts: maximumReconnectAttempts,
            backoffCap: backoffCap
        ),
        transport: transport,
        clock: clock,
        random: SequenceGatewayRandom(values: randomValues)
    )
}

private func envelope(
    op: Int,
    data: JSONValue?,
    sequence: Int? = nil,
    eventName: String? = nil
) -> GatewaySocketMessage {
    let value = GatewayEnvelope(op: op, data: data, sequence: sequence, eventName: eventName)
    return .text(String(decoding: try! JSONGatewayCodec().encode(value), as: UTF8.self))
}

private func sentEnvelope(_ socket: FakeGatewaySocket, at index: Int) async throws -> GatewayEnvelope {
    let data = try #require(await socket.sentData(at: index))
    return try JSONGatewayCodec().decode(data)
}

private func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0 ..< 500 {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private enum FakeGatewayError: Error { case closed, unavailable }

private actor FakeGatewaySocket: GatewaySocket {
    private var queued: [GatewaySocketMessage] = []
    private var receiver: CheckedContinuation<GatewaySocketMessage, any Error>?
    private(set) var sent: [Data] = []
    private(set) var closeCodes: [Int] = []
    private var terminalCloseCode: Int?

    var sentCount: Int {
        sent.count
    }

    func receive() async throws -> GatewaySocketMessage {
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiver = continuation
        }
    }

    func send(_ data: Data) async throws {
        sent.append(data)
    }

    func close(code: Int) async {
        closeCodes.append(code)
        receiver?.resume(throwing: FakeGatewayError.closed)
        receiver = nil
    }

    func closeCode() async -> Int? {
        terminalCloseCode
    }

    func push(_ message: GatewaySocketMessage) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: message)
        } else {
            queued.append(message)
        }
    }

    func terminate(code: Int?) {
        terminalCloseCode = code
        receiver?.resume(throwing: FakeGatewayError.closed)
        receiver = nil
    }

    func sentData(at index: Int) -> Data? {
        sent.indices.contains(index) ? sent[index] : nil
    }
}

private actor FakeGatewayTransport: GatewayTransport {
    private var sockets: [FakeGatewaySocket]
    private(set) var connectedURLs: [URL] = []

    init(sockets: [FakeGatewaySocket]) {
        self.sockets = sockets
    }

    var connectionCount: Int {
        connectedURLs.count
    }

    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        connectedURLs.append(url)
        guard !sockets.isEmpty else { throw FakeGatewayError.unavailable }
        return sockets.removeFirst()
    }
}

private actor BlockingGatewayTransport: GatewayTransport {
    private var continuation: CheckedContinuation<any GatewaySocket, any Error>?
    private(set) var connectionCount = 0

    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        connectionCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ socket: any GatewaySocket) {
        continuation?.resume(returning: socket)
        continuation = nil
    }
}

private actor SequenceGatewayRandom: GatewayRandomSource {
    private var values: [Double]

    init(values: [Double]) {
        self.values = values
    }

    func unitInterval() async -> Double {
        values.isEmpty ? 0.5 : values.removeFirst()
    }
}

private actor GatewayEventRecorder {
    private(set) var dispatchNames: [String] = []

    func append(_ event: GatewaySessionEvent) {
        guard case let .dispatch(name, _) = event else { return }
        dispatchNames.append(name)
    }
}

private actor ManualGatewayClock: GatewayClock {
    private struct Waiter {
        var duration: Duration
        var continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [Waiter] = []
    private(set) var recordedDurations: [Duration] = []

    var activeWaitCount: Int {
        waiters.count
    }

    var activeDurations: [Duration] {
        waiters.map(\.duration)
    }

    func sleep(for duration: Duration) async throws {
        recordedDurations.append(duration)
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(duration: duration, continuation: continuation))
        }
        try Task.checkCancellation()
    }

    func advanceNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func advance(durationMatching value: Double) {
        guard let index = waiters.firstIndex(where: { abs(seconds($0.duration) - value) < 0.001 }) else { return }
        waiters.remove(at: index).continuation.resume()
    }

    func advanceAll() {
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            waiter.continuation.resume()
        }
    }
}
