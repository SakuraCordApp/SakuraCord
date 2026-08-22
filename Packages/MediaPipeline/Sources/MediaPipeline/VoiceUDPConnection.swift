import Foundation
@preconcurrency import Network

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

public actor VoiceUDPConnection {
    public let packets: AsyncThrowingStream<Data, any Error>

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.sakuracord.voice.udp", qos: .userInteractive)
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var keepaliveTask: Task<Void, Never>?
    private var keepaliveCounter: UInt32 = 0
    private var receiving = false

    public init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        let stream = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingNewest(2000))
        packets = stream.stream
        continuation = stream.continuation
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleState(state) }
            }
            connection.start(queue: queue)
        }
    }

    public func discoverExternalAddress(ssrc: UInt32) async throws -> VoiceDiscoveredAddress {
        try await send(VoiceIPDiscovery.request(ssrc: ssrc))
        let response = try await receiveOne()
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

    /// Submits one encoded video frame as a Network.framework batch. This
    /// preserves datagram boundaries while avoiding one continuation and actor
    /// round-trip per RTP fragment. Completion of the final datagram provides
    /// the frame-level backpressure needed by the encoder consumer.
    public func sendDatagrams(_ datagrams: [Data]) async throws {
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
            continuation.finish()
        default:
            break
        }
    }

    private func receiveOne() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: URLError(.cannotParseResponse))
                }
            }
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
