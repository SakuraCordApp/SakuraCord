import CDave
import Foundation
import Network
import Synchronization

/// The voice server's UDP side: IP discovery, then encrypted RTP. Like
/// Discord's media servers it forwards each client's packets to everyone else
/// in the channel (re-encrypted per receiver) and plays simulated people's
/// generated speech. Not captured: RTP travels over UDP, which CDP can't see;
/// packet formats follow Discord's documented voice connection protocol
/// (discord.com/developers/docs/topics/voice-connections).
public actor VoiceMediaServer {
    struct Endpoint {
        let userID: Snowflake
        let channelID: Snowflake
        let mode: VoiceCrypto.Mode
        let key: [UInt8]
        var connection: NWConnection?
        var counter: UInt32 = 0
    }

    static let opusPayloadType: UInt8 = 120
    /// The H.264 payload type clients offer in Select Protocol.
    static let h264PayloadType: UInt8 = 105
    static let maximumPayload = 1_100
    /// Opus silence, sent five times when someone stops talking.
    static let silenceFrame = Data([0xF8, 0xFF, 0xFE])

    let port: UInt16
    let log: SimulatorLog
    private nonisolated let listener = Mutex<NWListener?>(nil)
    /// Clients by their audio SSRC, once they selected a protocol.
    private var endpoints: [UInt32: Endpoint] = [:]
    /// Video and RTX SSRCs to the audio SSRC of the client sending them.
    private var aliases: [UInt32: UInt32] = [:]
    /// Simulated cameras and screens, by sending SSRC.
    private var videos: [UInt32: (room: Snowflake, task: Task<Void, Never>)] = [:]
    /// Where each SSRC's IP discovery came from, before its session description.
    private var discovered: [UInt32: NWConnection] = [:]
    private var talkers: [Snowflake: (channelID: Snowflake, task: Task<Void, Never>)] = [:]
    private var reportedFailures: Set<UInt32> = []
    /// Simulated people's DAVE members per room; their frames are end-to-end encrypted before transport.
    private var dave: [Snowflake: [Snowflake: DaveMember]] = [:]
    private let queue = DispatchQueue(label: "simulator.net.voice-media")

    init(port: UInt16, log: SimulatorLog) {
        self.port = port
        self.log = log
    }

    // MARK: Socket

    func start() async throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener.withLock { $0 = listener }
        let started = Mutex<CheckedContinuation<Void, Error>?>(nil)
        listener.newConnectionHandler = { [weak self, queue] connection in
            connection.start(queue: queue)
            guard let self else { return }
            let datagrams = Self.datagrams(from: connection)
            Task { for await datagram in datagrams { await self.receive(datagram, from: connection) } }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: started.withLock { $0.take() }?.resume()
            case let .failed(error), let .waiting(error): started.withLock { $0.take() }?.resume(throwing: error)
            default: break
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            started.withLock { $0 = continuation }
            listener.start(queue: queue)
        }
    }

    nonisolated func stop() {
        listener.withLock { $0.take() }?.cancel()
    }

    private nonisolated static func datagrams(from connection: NWConnection) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        @Sendable func next() {
            connection.receiveMessage { data, _, _, error in
                if let data { continuation.yield(data) }
                if error == nil { next() } else { continuation.finish() }
            }
        }
        next()
        return stream
    }

    // MARK: Clients

    func register(ssrc: UInt32, userID: Snowflake, channelID: Snowflake, mode: VoiceCrypto.Mode, key: [UInt8]) {
        endpoints[ssrc] = Endpoint(userID: userID, channelID: channelID, mode: mode, key: key,
                                   connection: discovered.removeValue(forKey: ssrc) ?? endpoints[ssrc]?.connection)
        reportedFailures.remove(ssrc)
    }

    func unregister(ssrc: UInt32) {
        endpoints[ssrc] = nil
        discovered[ssrc] = nil
        aliases = aliases.filter { $0.value != ssrc }
    }

    /// A client's video and RTX SSRCs, so its video is forwarded too.
    func addAliases(_ ssrcs: [UInt32], to ssrc: UInt32) {
        for alias in ssrcs where alias != 0 && alias != ssrc { aliases[alias] = ssrc }
    }

    private func receive(_ datagram: Data, from connection: NWConnection) {
        let bytes = [UInt8](datagram)
        if bytes.count == 74, bytes[0] == 0, bytes[1] == 1 {
            answerDiscovery(bytes, from: connection)
            return
        }
        // RTP version 2 only; RTCP (payload types 200–204) needs no answer.
        guard bytes.count >= 12, bytes[0] >> 6 == 2, !(72 ... 76).contains(bytes[1] & 0x7F) else { return }
        let packetSSRC = Self.uint32(bytes, at: 8)
        let ssrc = aliases[packetSSRC] ?? packetSSRC
        guard var sender = endpoints[ssrc] else { return }
        sender.connection = connection
        endpoints[ssrc] = sender
        do {
            let (header, body) = try VoiceCrypto.open(datagram, key: sender.key, mode: sender.mode)
            forward(header: header, body: body, in: sender.channelID, from: sender.userID)
        } catch {
            if reportedFailures.insert(ssrc).inserted { log.error("voice", "RTP from SSRC \(ssrc) failed to decrypt with \(sender.mode.rawValue): \(error)") }
        }
    }

    /// Echoes the address and port the request came from (type 0x2, length 70).
    private func answerDiscovery(_ request: [UInt8], from connection: NWConnection) {
        let ssrc = Self.uint32(request, at: 4)
        guard case let .hostPort(host, port) = connection.endpoint else { return }
        discovered[ssrc] = connection
        if endpoints[ssrc] != nil { endpoints[ssrc]?.connection = connection }
        let address = Array("\(host)".split(separator: "%").first.map { Array($0.utf8) } ?? []).prefix(63)
        var response: [UInt8] = [0, 2, 0, 70] + request[4 ..< 8]
        response += address + [UInt8](repeating: 0, count: 64 - address.count)
        response += [UInt8(port.rawValue >> 8), UInt8(port.rawValue & 0xFF)]
        connection.send(content: Data(response), completion: .idempotent)
    }

    /// Sends one RTP packet's header and decrypted body to everyone else in the channel.
    private func forward(header: Data, body: Data, in channelID: Snowflake, from userID: Snowflake) {
        for (ssrc, var receiver) in endpoints where receiver.channelID == channelID && receiver.userID != userID {
            guard let connection = receiver.connection else { continue }
            receiver.counter &+= 1
            endpoints[ssrc] = receiver
            guard let packet = try? VoiceCrypto.seal(header: header, payload: body, key: receiver.key, counter: receiver.counter, mode: receiver.mode)
            else { continue }
            connection.send(content: packet, completion: .idempotent)
        }
    }

    // MARK: Simulated speech

    private func sendAudio(_ frame: Data, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, in room: Snowflake, from userID: Snowflake) {
        guard let body = outgoing([frame], from: userID, in: room, ssrc: ssrc, video: false)?.first else { return }
        forward(header: Self.rtpHeader(sequence: sequence, timestamp: timestamp, ssrc: ssrc), body: body, in: room, from: userID)
    }

    /// Sends one video frame; returns how many RTP packets it took.
    private func sendVideo(_ units: [Data], sequence: UInt16, timestamp: UInt32, ssrc: UInt32, in room: Snowflake, from userID: Snowflake) -> UInt16 {
        guard let units = outgoing(units, from: userID, in: room, ssrc: ssrc, video: true) else { return 0 }
        let payloads = Self.h264Payloads(units)
        for (position, payload) in payloads.enumerated() {
            let header = Self.rtpHeader(sequence: sequence &+ UInt16(truncatingIfNeeded: position), timestamp: timestamp, ssrc: ssrc,
                                        payloadType: Self.h264PayloadType, marker: position == payloads.count - 1)
            forward(header: header, body: payload, in: room, from: userID)
        }
        return UInt16(truncatingIfNeeded: payloads.count)
    }

    func setDave(_ members: [Snowflake: DaveMember]?, in room: Snowflake) { dave[room] = members }

    /// A simulated person's frame as it goes on the wire: DAVE-encrypted in a DAVE room (nil until
    /// they have a key), else unchanged. H.264 is encrypted as one Annex B frame, then split again.
    private func outgoing(_ units: [Data], from userID: Snowflake, in room: Snowflake, ssrc: UInt32, video: Bool) -> [Data]? {
        guard let member = dave[room]?[userID] else { return units }
        guard video else { return units.first.flatMap { member.encrypt($0, ssrc: ssrc, codec: DAVE_CODEC_OPUS) }.map { [$0] } }
        let startCode = Data([0, 0, 0, 1])
        guard let frame = member.encrypt(units.reduce(Data()) { $0 + startCode + $1 }, ssrc: ssrc, codec: DAVE_CODEC_H264) else { return nil }
        return Self.annexBUnits(frame)
    }

    /// NAL units of an Annex B frame (4-byte start codes, as `outgoing` writes them).
    private static func annexBUnits(_ frame: Data) -> [Data] {
        let bytes = [UInt8](frame)
        var starts: [Int] = []
        var index = 0
        while index + 4 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append(index + 4)
                index += 4
            } else {
                index += 1
            }
        }
        return starts.enumerated().map { position, start in
            Data(bytes[start ..< (position + 1 < starts.count ? starts[position + 1] - 4 : bytes.count)])
        }
    }

    /// `userID` talks in `channelID` on `ssrc` until `stopTalking`.
    func startTalking(_ userID: Snowflake, ssrc: UInt32, channelID: Snowflake) {
        guard talkers[userID]?.channelID != channelID else { return }
        talkers[userID]?.task.cancel()
        let task = Task.detached { [weak self] in
            let packets = SpeechSynthesizer.opusPackets(seed: userID.rawValue)
            guard !packets.isEmpty else { return }
            var sequence = UInt16(truncatingIfNeeded: userID.rawValue)
            var timestamp = UInt32(truncatingIfNeeded: userID.rawValue >> 16)
            var deadline = ContinuousClock.now
            var index = 0
            while !Task.isCancelled {
                await self?.sendAudio(packets[index % packets.count], sequence: sequence, timestamp: timestamp, ssrc: ssrc, in: channelID, from: userID)
                (sequence, timestamp, index) = (sequence &+ 1, timestamp &+ UInt32(SpeechSynthesizer.samplesPerPacket), index + 1)
                deadline += .milliseconds(20)
                try? await Task.sleep(until: deadline)
            }
            for _ in 0 ..< 5 {
                await self?.sendAudio(Self.silenceFrame, sequence: sequence, timestamp: timestamp, ssrc: ssrc, in: channelID, from: userID)
                (sequence, timestamp) = (sequence &+ 1, timestamp &+ UInt32(SpeechSynthesizer.samplesPerPacket))
            }
        }
        talkers[userID] = (channelID, task)
    }

    func stopTalking(_ userID: Snowflake) {
        talkers.removeValue(forKey: userID)?.task.cancel()
    }

    /// Stops simulated people who are no longer in `channelID`.
    func keepTalkers(in channelID: Snowflake, only present: Set<Snowflake>) {
        for (userID, talker) in talkers where talker.channelID == channelID && !present.contains(userID) { stopTalking(userID) }
    }

    // MARK: Simulated video

    /// Keeps exactly `senders` (sending SSRC to person) streaming generated video into `room`.
    func syncVideo(in room: Snowflake, senders: [UInt32: Snowflake], kind: VideoSynthesizer.Kind) {
        for (ssrc, video) in videos where video.room == room && senders[ssrc] == nil {
            video.task.cancel()
            videos[ssrc] = nil
        }
        for (ssrc, userID) in senders where videos[ssrc] == nil {
            videos[ssrc] = (room, Task.detached { [weak self] in
                let clip = VideoSynthesizer.clip(seed: userID.rawValue, kind: kind)
                guard !clip.isEmpty else { return }
                var sequence = UInt16(truncatingIfNeeded: ssrc)
                var timestamp = UInt32(truncatingIfNeeded: userID.rawValue >> 8)
                var deadline = ContinuousClock.now
                var index = 0
                while !Task.isCancelled {
                    let sent = await self?.sendVideo(clip[index % clip.count], sequence: sequence, timestamp: timestamp, ssrc: ssrc,
                                                     in: room, from: userID)
                    sequence &+= sent ?? 0
                    timestamp &+= UInt32(90_000 / VideoSynthesizer.framesPerSecond)
                    index += 1
                    deadline += .milliseconds(1_000 / VideoSynthesizer.framesPerSecond)
                    try? await Task.sleep(until: deadline)
                }
            })
        }
    }

    /// RFC 6184 payloads for one frame: small NAL units whole, larger ones as FU-A fragments.
    private static func h264Payloads(_ units: [Data]) -> [Data] {
        units.flatMap { unit -> [Data] in
            guard unit.count > maximumPayload, let first = unit.first else { return [unit] }
            let body = unit.dropFirst()
            return stride(from: body.startIndex, to: body.endIndex, by: maximumPayload).map { start in
                let end = min(start + maximumPayload, body.endIndex)
                let flags: UInt8 = (start == body.startIndex ? 0x80 : 0) | (end == body.endIndex ? 0x40 : 0)
                return Data([first & 0xE0 | 28, flags | first & 0x1F]) + body[start ..< end]
            }
        }
    }

    static func rtpHeader(sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payloadType: UInt8 = opusPayloadType, marker: Bool = false) -> Data {
        Data([0x80, payloadType | (marker ? 0x80 : 0), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
            + withUnsafeBytes(of: timestamp.bigEndian, Array.init) + withUnsafeBytes(of: ssrc.bigEndian, Array.init))
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
