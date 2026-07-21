import Foundation

public struct VoiceGatewayReady: Equatable, Sendable {
    public var ssrc: UInt32
    public var ip: String
    public var port: UInt16
    public var modes: [String]
    public var streams: [VoiceVideoStream]

    public init(
        ssrc: UInt32,
        ip: String,
        port: UInt16,
        modes: [String],
        streams: [VoiceVideoStream] = []
    ) {
        self.ssrc = ssrc
        self.ip = ip
        self.port = port
        self.modes = modes
        self.streams = streams
    }
}

public struct VoiceVideoStream: Equatable, Sendable {
    public var type: String
    public var rid: String
    public var ssrc: UInt32
    public var rtxSSRC: UInt32
    public var active: Bool
    public var quality: Int
    public var maxBitrate: Int?
    public var maxFramerate: Int?
    public var width: Int?
    public var height: Int?

    public init(
        type: String = "video",
        rid: String = "100",
        ssrc: UInt32,
        rtxSSRC: UInt32,
        active: Bool = true,
        quality: Int = 100,
        maxBitrate: Int? = nil,
        maxFramerate: Int? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.type = type
        self.rid = rid
        self.ssrc = ssrc
        self.rtxSSRC = rtxSSRC
        self.active = active
        self.quality = quality
        self.maxBitrate = maxBitrate
        self.maxFramerate = maxFramerate
        self.width = width
        self.height = height
    }
}

public struct VoiceVideoState: Equatable, Sendable {
    public var userID: String
    public var audioSSRC: UInt32
    public var videoSSRC: UInt32
    public var rtxSSRC: UInt32
    public var streams: [VoiceVideoStream]
}

public struct VoiceGatewaySessionDescription: Equatable, Sendable {
    public var mode: String
    public var secretKey: [UInt8]
    public var daveProtocolVersion: UInt16
    public var audioCodec: String?
    public var videoCodec: String?
    public var mediaSessionID: String?
    public var keyframeInterval: Int?
}

public enum VoiceGatewayServerEvent: Equatable, Sendable {
    case ready(VoiceGatewayReady)
    case sessionDescription(VoiceGatewaySessionDescription)
    case speaking(userID: String, ssrc: UInt32, flags: UInt8)
    case heartbeatAcknowledged(nonce: UInt64)
    case hello(heartbeatIntervalMilliseconds: UInt64)
    case resumed
    case clientsConnected([String])
    case clientDisconnected(String)
    case video(VoiceVideoState)
    case videoSinkWants([UInt32: Int], any: Int?)
    case davePrepareTransition(transitionID: UInt16, protocolVersion: UInt16)
    case daveExecuteTransition(transitionID: UInt16)
    case davePrepareEpoch(transitionID: UInt16, epoch: UInt32, protocolVersion: UInt16)
    case daveMLSExternalSender(Data)
    case daveMLSProposals(Data)
    case daveMLSAnnounceCommit(transitionID: UInt16, commit: Data)
    case daveMLSWelcome(transitionID: UInt16, welcome: Data)
    case connectionClosed(closeCode: Int)
    case unknown(opcode: UInt8)
}

public struct SequencedVoiceGatewayEvent: Equatable, Sendable {
    public var sequence: UInt16?
    public var event: VoiceGatewayServerEvent
}

public enum VoiceGatewayCodecError: Error, Equatable {
    case malformedPayload
    case unsupportedBinaryOpcode(UInt8)
}

public enum VoiceGatewayCodec {
    public static func decodeJSON(_ data: Data) throws -> SequencedVoiceGatewayEvent {
        let raw = try JSONDecoder().decode(RawEnvelope.self, from: data)
        let event: VoiceGatewayServerEvent
        switch raw.op {
        case 2:
            let value = try decodePayload(ReadyPayload.self, from: data)
            event = .ready(VoiceGatewayReady(
                ssrc: value.ssrc,
                ip: value.ip,
                port: value.port,
                modes: value.modes,
                streams: value.streams.map(\.model)
            ))
        case 4:
            let value = try decodePayload(SessionDescriptionPayload.self, from: data)
            event = .sessionDescription(VoiceGatewaySessionDescription(
                mode: value.mode,
                secretKey: value.secretKey,
                daveProtocolVersion: value.daveProtocolVersion,
                audioCodec: value.audioCodec,
                videoCodec: value.videoCodec,
                mediaSessionID: value.mediaSessionID,
                keyframeInterval: value.keyframeInterval
            ))
        case 5:
            let value = try decodePayload(SpeakingPayload.self, from: data)
            event = .speaking(userID: value.userID, ssrc: value.ssrc, flags: value.speaking)
        case 6:
            let value = try decodePayload(HeartbeatPayload.self, from: data)
            event = .heartbeatAcknowledged(nonce: value.nonce)
        case 8:
            let value = try decodePayload(HelloPayload.self, from: data)
            event = .hello(heartbeatIntervalMilliseconds: value.heartbeatInterval)
        case 9:
            event = .resumed
        case 11:
            event = try .clientsConnected(decodePayload(ClientsPayload.self, from: data).userIDs)
        case 12:
            let value = try decodePayload(VideoPayload.self, from: data)
            event = .video(VoiceVideoState(
                userID: value.userID,
                audioSSRC: value.audioSSRC,
                videoSSRC: value.videoSSRC,
                rtxSSRC: value.rtxSSRC,
                streams: value.streams.map(\.model)
            ))
        case 13:
            event = try .clientDisconnected(decodePayload(ClientPayload.self, from: data).userID)
        case 15:
            let wants = try decodePayload([String: Int].self, from: data)
            event = .videoSinkWants(
                Dictionary(uniqueKeysWithValues: wants.compactMap { key, value in
                    guard let ssrc = UInt32(key) else { return nil }
                    return (ssrc, value)
                }),
                any: wants["any"]
            )
        case 21:
            let value = try decodePayload(TransitionPayload.self, from: data)
            event = .davePrepareTransition(transitionID: value.transitionID, protocolVersion: value.protocolVersion)
        case 22:
            event = try .daveExecuteTransition(transitionID: decodePayload(TransitionIDPayload.self, from: data).transitionID)
        case 24:
            let value = try decodePayload(EpochPayload.self, from: data)
            event = .davePrepareEpoch(
                transitionID: value.transitionID,
                epoch: value.epoch,
                protocolVersion: value.protocolVersion
            )
        default:
            event = .unknown(opcode: UInt8(clamping: raw.op))
        }
        return SequencedVoiceGatewayEvent(sequence: raw.sequence, event: event)
    }

    public static func decodeBinary(_ data: Data) throws -> SequencedVoiceGatewayEvent {
        guard data.count >= 3,
              let sequence = data.readUInt16BigEndian(at: 0)
        else {
            throw VoiceGatewayCodecError.malformedPayload
        }
        let opcode = data[2]
        var payload = Data(data.dropFirst(3))
        let event: VoiceGatewayServerEvent
        switch opcode {
        case 25:
            event = .daveMLSExternalSender(payload)
        case 27:
            event = .daveMLSProposals(payload)
        case 29, 30:
            guard let transitionID = payload.readUInt16BigEndian(at: 0) else {
                throw VoiceGatewayCodecError.malformedPayload
            }
            payload.removeFirst(2)
            event = opcode == 29
                ? .daveMLSAnnounceCommit(transitionID: transitionID, commit: payload)
                : .daveMLSWelcome(transitionID: transitionID, welcome: payload)
        default:
            throw VoiceGatewayCodecError.unsupportedBinaryOpcode(opcode)
        }
        return SequencedVoiceGatewayEvent(sequence: sequence, event: event)
    }

    public static func identify(
        serverID: String,
        userID: String,
        sessionID: String,
        token: String,
        maxDaveProtocolVersion: UInt16,
        channelID: String? = nil,
        video: Bool = true
    ) throws -> String {
        var payload: [String: Any] = [
            "server_id": serverID,
            "user_id": userID,
            "session_id": sessionID,
            "token": token,
            "max_dave_protocol_version": Int(maxDaveProtocolVersion),
            "video": video,
            "streams": video ? [["type": "video", "rid": "100", "quality": 100]] : []
        ]
        if let channelID {
            payload["channel_id"] = channelID
        }
        return try json(opcode: 0, payload: payload)
    }

    public static func selectProtocol(address: String, port: UInt16, mode: VoiceTransportMode) throws -> String {
        try json(opcode: 1, payload: [
            "protocol": "udp",
            "codecs": [
                ["name": "opus", "type": "audio", "priority": 1000, "payload_type": 120],
                [
                    "name": "H264", "type": "video", "priority": 1000,
                    "payload_type": 105, "rtx_payload_type": 106,
                    "encode": true, "decode": true
                ]
            ],
            "data": ["address": address, "port": Int(port), "mode": mode.rawValue] as [String: Any]
        ])
    }

    public static func video(
        audioSSRC: UInt32,
        videoSSRC: UInt32,
        rtxSSRC: UInt32,
        width: Int,
        height: Int,
        framerate: Int,
        enabled: Bool
    ) throws -> String {
        let streams: [[String: Any]] = enabled ? [[
            "type": "video",
            "rid": "100",
            "ssrc": Int(videoSSRC),
            "active": true,
            "quality": 100,
            "rtx_ssrc": Int(rtxSSRC),
            "max_bitrate": 4_000_000,
            "max_framerate": framerate,
            "max_resolution": ["type": "fixed", "width": width, "height": height]
        ]] : []
        return try json(opcode: 12, payload: [
            "audio_ssrc": Int(audioSSRC),
            "video_ssrc": enabled ? Int(videoSSRC) : 0,
            "rtx_ssrc": enabled ? Int(rtxSSRC) : 0,
            "streams": streams
        ])
    }

    public static func videoSinkWants(_ wants: [UInt32: Int], any: Int = 100) throws -> String {
        var payload = Dictionary(uniqueKeysWithValues: wants.map { (String($0.key), $0.value) })
        payload["any"] = any
        return try json(opcode: 15, payload: payload)
    }

    public static func heartbeat(nonce: UInt64, sequence: Int) throws -> String {
        try json(opcode: 3, payload: ["t": nonce, "seq_ack": sequence])
    }

    public static func speaking(flags: UInt8, ssrc: UInt32) throws -> String {
        try json(opcode: 5, payload: ["speaking": Int(flags), "delay": 0, "ssrc": Int(ssrc)])
    }

    public static func resume(serverID: String, sessionID: String, token: String, sequence: Int) throws -> String {
        try json(opcode: 7, payload: [
            "server_id": serverID,
            "session_id": sessionID,
            "token": token,
            "seq_ack": sequence
        ])
    }

    public static func daveTransitionReady(_ transitionID: UInt16) throws -> String {
        try json(opcode: 23, payload: ["transition_id": Int(transitionID)])
    }

    public static func daveInvalidCommitWelcome(_ transitionID: UInt16) throws -> String {
        try json(opcode: 31, payload: ["transition_id": Int(transitionID)])
    }

    public static func binary(opcode: UInt8, payload: Data) -> Data {
        Data([opcode]) + payload
    }

    private static func json(opcode: UInt8, payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["op": Int(opcode), "d": payload])
        guard let string = String(data: data, encoding: .utf8) else {
            throw VoiceGatewayCodecError.malformedPayload
        }
        return string
    }

    private static func decodePayload<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(Envelope<Value>.self, from: data).data
    }
}

private struct RawEnvelope: Decodable {
    var op: Int
    var sequence: UInt16?
    enum CodingKeys: String, CodingKey { case op, sequence = "seq" }
}

private struct Envelope<Payload: Decodable>: Decodable {
    var data: Payload
    enum CodingKeys: String, CodingKey { case data = "d" }
}

private struct ReadyPayload: Decodable {
    var ssrc: UInt32
    var ip: String
    var port: UInt16
    var modes: [String]
    var streams: [VideoStreamPayload] = []

    enum CodingKeys: String, CodingKey { case ssrc, ip, port, modes, streams }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ssrc = try container.decode(UInt32.self, forKey: .ssrc)
        ip = try container.decode(String.self, forKey: .ip)
        port = try container.decode(UInt16.self, forKey: .port)
        modes = try container.decode([String].self, forKey: .modes)
        streams = try container.decodeIfPresent([VideoStreamPayload].self, forKey: .streams) ?? []
    }
}

private struct VideoPayload: Decodable {
    var userID: String
    var audioSSRC: UInt32
    var videoSSRC: UInt32
    var rtxSSRC: UInt32
    var streams: [VideoStreamPayload]

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case audioSSRC = "audio_ssrc"
        case videoSSRC = "video_ssrc"
        case rtxSSRC = "rtx_ssrc"
        case streams
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(String.self, forKey: .userID)
        audioSSRC = try container.decodeIfPresent(UInt32.self, forKey: .audioSSRC) ?? 0
        videoSSRC = try container.decodeIfPresent(UInt32.self, forKey: .videoSSRC) ?? 0
        rtxSSRC = try container.decodeIfPresent(UInt32.self, forKey: .rtxSSRC) ?? 0
        streams = try container.decodeIfPresent([VideoStreamPayload].self, forKey: .streams) ?? []
    }
}

private struct VideoStreamPayload: Decodable {
    var type: String?
    var rid: String?
    var ssrc: UInt32
    var rtxSSRC: UInt32?
    var active: Bool?
    var quality: Int?
    var maxBitrate: Int?
    var maxFramerate: Int?
    var maxResolution: ResolutionPayload?

    enum CodingKeys: String, CodingKey {
        case type, rid, ssrc, active, quality
        case rtxSSRC = "rtx_ssrc"
        case maxBitrate = "max_bitrate"
        case maxFramerate = "max_framerate"
        case maxResolution = "max_resolution"
    }

    var model: VoiceVideoStream {
        VoiceVideoStream(
            type: type ?? "video",
            rid: rid ?? "100",
            ssrc: ssrc,
            rtxSSRC: rtxSSRC ?? 0,
            active: active ?? true,
            quality: quality ?? 100,
            maxBitrate: maxBitrate,
            maxFramerate: maxFramerate,
            width: maxResolution?.width,
            height: maxResolution?.height
        )
    }
}

private struct ResolutionPayload: Decodable {
    var width: Int
    var height: Int
}

private struct SessionDescriptionPayload: Decodable {
    var mode: String
    var secretKey: [UInt8]
    var daveProtocolVersion: UInt16
    var audioCodec: String?
    var videoCodec: String?
    var mediaSessionID: String?
    var keyframeInterval: Int?
    enum CodingKeys: String, CodingKey {
        case mode
        case secretKey = "secret_key"
        case daveProtocolVersion = "dave_protocol_version"
        case audioCodec = "audio_codec"
        case videoCodec = "video_codec"
        case mediaSessionID = "media_session_id"
        case keyframeInterval = "keyframe_interval"
    }
}

private struct SpeakingPayload: Decodable {
    var speaking: UInt8
    var ssrc: UInt32
    var userID: String
    enum CodingKeys: String, CodingKey { case speaking, ssrc, userID = "user_id" }
}

private struct HeartbeatPayload: Decodable {
    var nonce: UInt64
    enum CodingKeys: String, CodingKey { case nonce = "t" }
}

private struct HelloPayload: Decodable {
    var heartbeatInterval: UInt64
    enum CodingKeys: String, CodingKey { case heartbeatInterval = "heartbeat_interval" }
}

private struct ClientsPayload: Decodable {
    var userIDs: [String]
    enum CodingKeys: String, CodingKey { case userIDs = "user_ids" }
}

private struct ClientPayload: Decodable {
    var userID: String
    enum CodingKeys: String, CodingKey { case userID = "user_id" }
}

private struct TransitionIDPayload: Decodable {
    var transitionID: UInt16
    enum CodingKeys: String, CodingKey { case transitionID = "transition_id" }

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            transitionID = try container.decodeIfPresent(UInt16.self, forKey: .transitionID) ?? 0
        } else {
            transitionID = 0
        }
    }
}

private struct TransitionPayload: Decodable {
    var transitionID: UInt16
    var protocolVersion: UInt16
    enum CodingKeys: String, CodingKey {
        case transitionID = "transition_id"
        case protocolVersion = "protocol_version"
    }
}

private struct EpochPayload: Decodable {
    var transitionID: UInt16
    var epoch: UInt32
    var protocolVersion: UInt16
    enum CodingKeys: String, CodingKey {
        case transitionID = "transition_id"
        case epoch
        case protocolVersion = "protocol_version"
    }
}
