import Foundation
@preconcurrency import Network
import Synchronization

public struct VoiceDiscoveredAddress: Equatable, Sendable {
    public var ip: String
    public var port: UInt16
}

public enum VoiceIPDiscovery {
    public static func request(ssrc: UInt32) -> Data {
        var data = Data()
        data.appendBigEndian(UInt16(1))
        data.appendBigEndian(UInt16(70))
        data.appendBigEndian(ssrc)
        data.append(Data(repeating: 0, count: 66))
        return data
    }

    public static func parseResponse(_ data: Data) -> VoiceDiscoveredAddress? {
        guard data.count == 74,
              data.readUInt16BigEndian(at: 0) == 2,
              data.readUInt16BigEndian(at: 2) == 70,
              let terminator = data[8 ..< 72].firstIndex(of: 0),
              let ip = String(data: data[8 ..< terminator], encoding: .utf8),
              !ip.isEmpty,
              let port = data.readUInt16BigEndian(at: 72) else { return nil }
        return VoiceDiscoveredAddress(ip: ip, port: port)
    }
}

struct RTPDatagramPacingPlan: Equatable, Sendable {
    private static let burstsPerSecond = 200
    private static let drainHeadroomDivisor = 10

    var ranges: [Range<Int>]

    static func make(datagramSizes: [Int], bitsPerSecond: Int) -> Self {
        guard !datagramSizes.isEmpty else { return Self(ranges: []) }
        let bytesPerSecond = max(1, bitsPerSecond / 8)
        let largestDatagram = datagramSizes.max() ?? 1
        // Keep each Network.framework submission near five milliseconds of
        // media while avoiding a continuation for every individual packet at
        // lower bitrates.
        let burstByteLimit = max(largestDatagram * 2, bytesPerSecond / burstsPerSecond)
        var ranges: [Range<Int>] = []
        var start = 0
        var byteCount = 0

        for (index, size) in datagramSizes.enumerated() {
            if index > start, byteCount + size > burstByteLimit {
                ranges.append(start ..< index)
                start = index
                byteCount = 0
            }
            byteCount += size
        }
        ranges.append(start ..< datagramSizes.count)
        return Self(ranges: ranges)
    }

    /// Converts the encoder's media-payload rate into a wire-rate pacing
    /// target. RTP extensions, AEAD tags, and packet headers are not part of
    /// VideoToolbox's bitrate, so charging them to the same rate accumulates
    /// permanent sender debt during sustained motion. A further ten percent
    /// drain margin absorbs normal short-term encoder variation without
    /// increasing the amount of media the encoder produces.
    static func wireBitsPerSecond(
        mediaBitsPerSecond: Int,
        mediaByteCount: Int,
        datagramSizes: [Int]
    ) -> Int {
        let mediaRate = max(1, mediaBitsPerSecond)
        let mediaBytes = max(1, mediaByteCount)
        let transportBytes = max(mediaBytes, datagramSizes.reduce(0, +))
        let overheadAdjustedRate = Int64(mediaRate) * Int64(transportBytes)
            / Int64(mediaBytes)
        let drainHeadroom = max(1, overheadAdjustedRate / Int64(drainHeadroomDivisor))
        return Int(clamping: overheadAdjustedRate + drainHeadroom)
    }
}

public actor VoiceUDPConnection {
    /// Allows a scene-change or keyframe to consume a small amount of future
    /// pacing budget. This keeps one RTP frame from being stretched across the
    /// receiver's assembly deadline without restoring unbounded UDP bursts.
    private static let maximumVideoBurstCreditOffset: Duration = .milliseconds(-100)

    public let packets: AsyncThrowingStream<Data, any Error>

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var keepaliveTask: Task<Void, Never>?
    private var keepaliveCounter: UInt32 = 0
    private var receiving = false
    private var nextVideoSendTime: ContinuousClock.Instant?

    public init(
        host: String,
        port: UInt16,
        serviceClass: NWParameters.ServiceClass = .interactiveVoice
    ) {
        let parameters = NWParameters.udp
        parameters.serviceClass = serviceClass
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        queue = DispatchQueue(
            label: "dev.sakuracord.voice.udp",
            qos: serviceClass == .interactiveVoice ? .userInteractive : .userInitiated
        )
        let stream = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingNewest(2000))
        packets = stream.stream
        continuation = stream.continuation
    }

    public func start() async throws {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                await self?.timeoutPendingStart()
            } catch {}
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                readyContinuation = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { await self?.handleState(state) }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPendingStart()
            }
        }
    }

    public func discoverExternalAddress(ssrc: UInt32) async throws -> VoiceDiscoveredAddress {
        let request = VoiceIPDiscovery.request(ssrc: ssrc)
        try await send(request)
        let response = try await receiveDiscoveryResponse(retrying: request)
        guard let discovered = VoiceIPDiscovery.parseResponse(response) else {
            throw VoiceGatewayCodecError.malformedPayload
        }
        return discovered
    }

    public func beginReceiving() {
        guard !receiving else { return }
        receiving = true
        receiveNext()
        startKeepalive()
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Paces encoded video into small Network.framework batches. VideoToolbox
    /// limits the average bitrate over a one-second window, but an immediate
    /// whole-frame batch can still enqueue that window as one large UDP burst.
    /// Keeping only a few milliseconds of media in each submission prevents
    /// screen video from building latency in voice and signaling traffic.
    public func sendDatagrams(
        _ datagrams: [Data],
        mediaByteCount: Int,
        pacedAtBitsPerSecond mediaBitsPerSecond: Int
    ) async throws {
        let datagramSizes = datagrams.map(\.count)
        let wireBitsPerSecond = RTPDatagramPacingPlan.wireBitsPerSecond(
            mediaBitsPerSecond: mediaBitsPerSecond,
            mediaByteCount: mediaByteCount,
            datagramSizes: datagramSizes
        )
        let plan = RTPDatagramPacingPlan.make(
            datagramSizes: datagramSizes,
            bitsPerSecond: wireBitsPerSecond
        )
        let clock = ContinuousClock()
        for range in plan.ranges {
            try Task.checkCancellation()
            let now = clock.now
            let creditFloor = now.advanced(by: Self.maximumVideoBurstCreditOffset)
            let scheduledStart = max(nextVideoSendTime ?? creditFloor, creditFloor)
            if scheduledStart > now {
                try await clock.sleep(until: scheduledStart)
            }
            try await sendBatch(datagrams[range])
            let byteCount = datagrams[range].reduce(0) { $0 + $1.count }
            nextVideoSendTime = scheduledStart.advanced(
                by: Self.transmissionDuration(
                    byteCount: byteCount,
                    bitsPerSecond: wireBitsPerSecond
                )
            )
        }
    }

    private func sendBatch(_ datagrams: ArraySlice<Data>) async throws {
        guard let final = datagrams.last else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.batch {
                for datagram in datagrams.dropLast() {
                    connection.send(content: datagram, completion: .idempotent)
                }
                connection.send(content: final, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
    }

    private static func transmissionDuration(
        byteCount: Int,
        bitsPerSecond: Int
    ) -> Duration {
        let bitCount = UInt64(clamping: byteCount) * 8
        let rate = UInt64(clamping: max(1, bitsPerSecond))
        let nanoseconds = bitCount * 1_000_000_000 / rate
        return .nanoseconds(Int64(clamping: nanoseconds))
    }

    public func close() {
        keepaliveTask?.cancel()
        connection.cancel()
        continuation.finish()
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            readyContinuation?.resume()
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
            continuation.finish(throwing: error)
        case .cancelled:
            readyContinuation?.resume(throwing: CancellationError())
            readyContinuation = nil
            continuation.finish()
        default:
            break
        }
    }

    private func timeoutPendingStart() {
        readyContinuation?.resume(throwing: VoiceSessionError.connectionTimedOut)
        readyContinuation = nil
    }

    private func cancelPendingStart() {
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
        connection.cancel()
    }

    private func receiveDiscoveryResponse(retrying request: Data) async throws -> Data {
        let gate = VoiceUDPReceiveGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard gate.isPending else { return }
                connection.receiveMessage { data, _, _, error in
                    if let error {
                        gate.fail(error)
                    } else if let data {
                        gate.succeed(data)
                    } else {
                        gate.fail(URLError(.cannotParseResponse))
                    }
                }
                for seconds in 1 ... 2 {
                    queue.asyncAfter(deadline: .now() + .seconds(seconds)) { [connection] in
                        guard gate.isPending else { return }
                        connection.send(content: request, completion: .idempotent)
                    }
                }
                queue.asyncAfter(deadline: .now() + .seconds(3)) {
                    gate.fail(VoiceSessionError.connectionTimedOut)
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    private func receiveNext() {
        guard receiving else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { await self?.handleReceived(data: data, error: error) }
        }
    }

    private func handleReceived(data: Data?, error: NWError?) {
        if let error {
            continuation.finish(throwing: error)
            receiving = false
            return
        }
        if let data {
            continuation.yield(data)
        }
        receiveNext()
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var data = Data()
                let counter = await nextKeepaliveCounter()
                var littleEndian = counter.littleEndian
                Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
                data.append(Data(repeating: 0, count: 4))
                try? await send(data)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func nextKeepaliveCounter() -> UInt32 {
        defer { keepaliveCounter &+= 1 }
        return keepaliveCounter
    }
}

private final class VoiceUDPReceiveGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Data, any Error>?
        var isFinished = false
    }

    private let state = Mutex(State())

    var isPending: Bool {
        state.withLock { !$0.isFinished }
    }

    func install(_ continuation: CheckedContinuation<Data, any Error>) {
        let wasAlreadyFinished = state.withLock { state in
            guard !state.isFinished else { return true }
            state.continuation = continuation
            return false
        }
        if wasAlreadyFinished {
            continuation.resume(throwing: CancellationError())
        }
    }

    func succeed(_ data: Data) {
        takeContinuation()?.resume(returning: data)
    }

    func fail(_ error: any Error) {
        takeContinuation()?.resume(throwing: error)
    }

    func cancel() {
        fail(CancellationError())
    }

    private func takeContinuation() -> CheckedContinuation<Data, any Error>? {
        state.withLock { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            defer { state.continuation = nil }
            return state.continuation
        }
    }
}
