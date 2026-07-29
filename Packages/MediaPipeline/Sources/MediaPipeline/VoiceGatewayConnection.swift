import DaveKit
import Foundation
import OSLog
import SakuraCordModels

private let voiceGatewayLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "VoiceGateway")

public enum VoiceGatewayDiagnosticDirection: String, Sendable {
    case request
    case response
}

public struct VoiceGatewayDiagnostics: Sendable {
    public static let disabled = VoiceGatewayDiagnostics { _, _ in }

    private let recorder:
        @Sendable (VoiceGatewayDiagnosticDirection, Data) -> Void

    public init(
        recorder:
            @escaping @Sendable (VoiceGatewayDiagnosticDirection, Data) -> Void
    ) {
        self.recorder = recorder
    }

    public func record(
        _ direction: VoiceGatewayDiagnosticDirection,
        data: Data
    ) {
        recorder(direction, data)
    }
}

public actor VoiceGatewayConnection {
    public let events: AsyncStream<SequencedVoiceGatewayEvent>

    private let info: VoiceConnectionInfo
    private let session: URLSession
    private let diagnostics: VoiceGatewayDiagnostics
    private let continuation: AsyncStream<SequencedVoiceGatewayEvent>.Continuation
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastSequence = -1
    private var lastHeartbeatAcknowledged = true

    public init(
        info: VoiceConnectionInfo,
        session: URLSession = .shared,
        diagnostics: VoiceGatewayDiagnostics = .disabled
    ) {
        self.info = info
        self.session = session
        self.diagnostics = diagnostics
        let stream = AsyncStream<SequencedVoiceGatewayEvent>.makeStream(bufferingPolicy: .bufferingNewest(1000))
        events = stream.stream
        continuation = stream.continuation
    }

    public func connect(resuming: Bool = false) async throws {
        closeSocketOnly()
        guard let url = Self.endpointURL(info.endpoint) else {
            throw VoiceGatewayCodecError.malformedPayload
        }
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        voiceGatewayLogger.info("Voice gateway socket opened; resuming=\(resuming)")

        if resuming {
            try await sendText(VoiceGatewayCodec.resume(
                serverID: info.serverID,
                sessionID: info.sessionID,
                token: info.token,
                sequence: lastSequence
            ))
        } else {
            lastSequence = -1
            try await sendText(VoiceGatewayCodec.identify(
                serverID: info.serverID,
                userID: info.userID.description,
                sessionID: info.sessionID,
                token: info.token,
                maxDaveProtocolVersion: DaveSessionManager.maxSupportedProtocolVersion(),
                channelID: String(info.channelID.rawValue),
                video: true
            ))
        }

        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }
    }

    public func sendSelectProtocol(address: String, port: UInt16, mode: VoiceTransportMode) async throws {
        try await sendText(VoiceGatewayCodec.selectProtocol(address: address, port: port, mode: mode))
    }

    public func sendSpeaking(flags: UInt8, ssrc: UInt32) async throws {
        try await sendText(VoiceGatewayCodec.speaking(flags: flags, ssrc: ssrc))
    }

    public func sendVideo(
        audioSSRC: UInt32,
        videoSSRC: UInt32,
        rtxSSRC: UInt32,
        width: Int,
        height: Int,
        framerate: Int,
        enabled: Bool
    ) async throws {
        try await sendText(VoiceGatewayCodec.video(
            audioSSRC: audioSSRC,
            videoSSRC: videoSSRC,
            rtxSSRC: rtxSSRC,
            width: width,
            height: height,
            framerate: framerate,
            enabled: enabled
        ))
    }

    public func sendVideoSinkWants(_ wants: [UInt32: Int], any: Int = 100) async throws {
        try await sendText(VoiceGatewayCodec.videoSinkWants(wants, any: any))
    }

    public func sendDaveTransitionReady(_ transitionID: UInt16) async throws {
        try await sendText(VoiceGatewayCodec.daveTransitionReady(transitionID))
    }

    public func sendDaveInvalidCommitWelcome(_ transitionID: UInt16) async throws {
        try await sendText(VoiceGatewayCodec.daveInvalidCommitWelcome(transitionID))
    }

    public func sendDaveKeyPackage(_ data: Data) async throws {
        try await sendBinary(VoiceGatewayCodec.binary(opcode: 26, payload: data))
    }

    public func sendDaveCommitWelcome(_ data: Data) async throws {
        try await sendBinary(VoiceGatewayCodec.binary(opcode: 28, payload: data))
    }

    public func close() {
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        closeSocketOnly()
        continuation.finish()
    }

    private func receiveMessages() async {
        while !Task.isCancelled, let socket {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch is CancellationError {
                return
            } catch {
                voiceGatewayLogger.error(
                    "Voice gateway socket receive failed; error=\(String(reflecting: error), privacy: .public), closeCode=\(socket.closeCode.rawValue)"
                )
                continuation.yield(SequencedVoiceGatewayEvent(
                    sequence: nil,
                    event: .connectionClosed(closeCode: socket.closeCode.rawValue)
                ))
                return
            }

            switch message {
            case let .data(data):
                diagnostics.record(.response, data: data)
            case let .string(string):
                diagnostics.record(.response, data: Data(string.utf8))
            @unknown default:
                break
            }

            do {
                let sequenced: SequencedVoiceGatewayEvent = switch message {
                case let .data(data): try VoiceGatewayCodec.decodeBinary(data)
                case let .string(string): try VoiceGatewayCodec.decodeJSON(Data(string.utf8))
                @unknown default: throw VoiceGatewayCodecError.malformedPayload
                }
                if let sequence = sequenced.sequence {
                    lastSequence = Int(sequence)
                }
                if sequenced.event.isDiagnosticMilestone {
                    voiceGatewayLogger.info(
                        "Voice gateway event; name=\(sequenced.event.diagnosticName, privacy: .public), sequence=\(sequenced.sequence.map(String.init) ?? "none", privacy: .public)"
                    )
                }
                switch sequenced.event {
                case let .hello(interval):
                    startHeartbeat(intervalMilliseconds: interval)
                case .heartbeatAcknowledged:
                    lastHeartbeatAcknowledged = true
                default:
                    break
                }
                continuation.yield(sequenced)
            } catch {
                if let sequence = Self.sequence(in: message) {
                    lastSequence = Int(sequence)
                }
                voiceGatewayLogger.warning(
                    "Voice gateway payload ignored; error=\(String(reflecting: error), privacy: .public)"
                )
            }
        }
    }

    private static func sequence(in message: URLSessionWebSocketTask.Message) -> UInt16? {
        switch message {
        case let .data(data):
            return data.readUInt16BigEndian(at: 0)
        case let .string(string):
            guard let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
            else { return nil }
            return (object["seq"] as? NSNumber).map { UInt16(truncating: $0) }
        @unknown default:
            return nil
        }
    }

    private func startHeartbeat(intervalMilliseconds: UInt64) {
        heartbeatTask?.cancel()
        let interval = Duration.milliseconds(max(1, Int64(clamping: intervalMilliseconds)))
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let acknowledged = await lastHeartbeatAcknowledged
                guard acknowledged else {
                    await closeSocketOnly()
                    return
                }
                await markHeartbeatPending()
                let nonce = UInt64(Date.now.timeIntervalSince1970 * 1000)
                do {
                    try await sendText(VoiceGatewayCodec.heartbeat(
                        nonce: nonce,
                        sequence: lastSequence
                    ))
                } catch {
                    await closeSocketOnly()
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func markHeartbeatPending() {
        lastHeartbeatAcknowledged = false
    }

    private func sendText(_ text: String) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        diagnostics.record(.request, data: Data(text.utf8))
        try await socket.send(.string(text))
    }

    private func sendBinary(_ data: Data) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        diagnostics.record(.request, data: data)
        try await socket.send(.data(data))
    }

    private func closeSocketOnly() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    static func endpointURL(_ endpoint: String) -> URL? {
        let base = endpoint.hasPrefix("ws://") || endpoint.hasPrefix("wss://")
            ? endpoint
            : "wss://\(endpoint)"
        guard var components = URLComponents(string: base) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "v" }
        items.append(URLQueryItem(name: "v", value: "8"))
        components.queryItems = items
        return components.url
    }
}

private extension VoiceGatewayServerEvent {
    var diagnosticName: String {
        switch self {
        case .ready: "ready"
        case .sessionDescription: "session-description"
        case .speaking: "speaking"
        case .heartbeatAcknowledged: "heartbeat-ack"
        case .hello: "hello"
        case .resumed: "resumed"
        case .clientsConnected: "clients-connected"
        case .clientDisconnected: "client-disconnected"
        case .video: "video"
        case .videoSinkWants: "video-sink-wants"
        case .davePrepareTransition: "dave-prepare-transition"
        case .daveExecuteTransition: "dave-execute-transition"
        case .davePrepareEpoch: "dave-prepare-epoch"
        case .daveMLSExternalSender: "dave-external-sender"
        case .daveMLSProposals: "dave-proposals"
        case .daveMLSAnnounceCommit: "dave-announce-commit"
        case .daveMLSWelcome: "dave-welcome"
        case .connectionClosed: "connection-closed"
        case let .unknown(opcode): "unknown-\(opcode)"
        }
    }

    var isDiagnosticMilestone: Bool {
        switch self {
        case .heartbeatAcknowledged, .hello: false
        default: true
        }
    }
}
