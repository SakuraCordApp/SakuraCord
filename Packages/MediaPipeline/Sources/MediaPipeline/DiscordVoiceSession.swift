import CoreAudio
import DaveKit
import Foundation
import OSLog
import SakuraCordModels

private let voiceMediaLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "VoiceMedia")

public struct VoiceSessionConfiguration: Equatable, Sendable {
    public var inputDeviceID: AudioDeviceID?
    public var outputDeviceID: AudioDeviceID?
    public var inputVolume: Float
    public var outputVolume: Float
    public var isMuted: Bool
    public var isDeafened: Bool
    public var cameraUniqueID: String?

    public init(
        inputDeviceID: AudioDeviceID? = nil,
        outputDeviceID: AudioDeviceID? = nil,
        inputVolume: Float = 1,
        outputVolume: Float = 1,
        isMuted: Bool = false,
        isDeafened: Bool = false,
        cameraUniqueID: String? = nil
    ) {
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID
        self.inputVolume = inputVolume
        self.outputVolume = outputVolume
        self.isMuted = isMuted
        self.isDeafened = isDeafened
        self.cameraUniqueID = cameraUniqueID
    }
}

public enum VoiceSessionState: String, Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting
    case disconnecting
    case disconnected
    case failed
}

public struct VoiceRemoteParticipant: Equatable, Sendable {
    public var userID: String
    public var audioSSRC: UInt32?
    public var videoSSRC: UInt32?
    public var isSpeaking: Bool
    public var isCameraEnabled: Bool
    public var volume: Float

    public init(
        userID: String,
        audioSSRC: UInt32? = nil,
        videoSSRC: UInt32? = nil,
        isSpeaking: Bool = false,
        isCameraEnabled: Bool = false,
        volume: Float = 1
    ) {
        self.userID = userID
        self.audioSSRC = audioSSRC
        self.videoSSRC = videoSSRC
        self.isSpeaking = isSpeaking
        self.isCameraEnabled = isCameraEnabled
        self.volume = volume
    }
}

public enum VoiceSessionEvent: Equatable, Sendable {
    case stateChanged(VoiceSessionState)
    case latencyUpdated(milliseconds: Int)
    case participantChanged(VoiceRemoteParticipant)
    case participantLeft(userID: String)
    case localSpeakingChanged(Bool)
    case encryptionReady(protocolVersion: UInt16)
    case videoFrame(userID: String, frame: VoiceVideoFrame)
    case videoStopped(userID: String)
    case error(String)
}

public actor DiscordVoiceSession: DaveSessionDelegate {
    public nonisolated let events: AsyncStream<VoiceSessionEvent>

    private let info: VoiceConnectionInfo
    private let eventContinuation: AsyncStream<VoiceSessionEvent>.Continuation
    private let gateway: VoiceGatewayConnection
    private var configuration: VoiceSessionConfiguration
    private var state: VoiceSessionState = .idle
    private var udp: VoiceUDPConnection?
    private var cipher: VoiceTransportCipher?
    private var audioEngine: VoiceAudioEngine?
    private var videoEngine: VoiceVideoEngine?
    private var capturedAudioContinuation: AsyncStream<CapturedOpusFrame>.Continuation?
    private var capturedAudioTask: Task<Void, Never>?
    private var encodedVideoContinuation: AsyncStream<EncodedVideoFrame>.Continuation?
    private var previewVideoContinuation: AsyncStream<VoiceVideoFrame>.Continuation?
    private var encodedVideoTask: Task<Void, Never>?
    private var previewVideoTask: Task<Void, Never>?
    private var gatewayEventTask: Task<Void, Never>?
    private var udpTask: Task<Void, Never>?
    private var inboundVideoTask: Task<Void, Never>?
    private var inboundVideoContinuation: AsyncStream<Data>.Continuation?
    private var connectTimeoutTask: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var audioSSRC: UInt32?
    private var videoSSRC: UInt32?
    private var rtxSSRC: UInt32?
    private var videoRID = "100"
    private var sequence = UInt16.random(in: 0 ... UInt16.max)
    private var videoSequence = UInt16.random(in: 0 ... UInt16.max)
    private var rtxSequence = UInt16.random(in: 0 ... UInt16.max)
    private var videoTransportSequence = UInt16.random(in: 0 ... UInt16.max)
    private var timestamp = UInt32.random(in: 0 ... UInt32.max)
    private var ssrcToUserID: [UInt32: String] = [:]
    private var rtxToVideoSSRC: [UInt32: UInt32] = [:]
    private var videoDepacketizers: [UInt32: H264RTPDepacketizer] = [:]
    private var videoDecoders: [UInt32: H264VideoDecoder] = [:]
    private var reorderBuffers: [UInt32: RTPReorderBuffer] = [:]
    private var videoAwaitingKeyframe = Set<UInt32>()
    private var lastVideoKeyframeRequest: [UInt32: ContinuousClock.Instant] = [:]
    private var participants: [String: VoiceRemoteParticipant] = [:]
    private var lastRemoteAudioActivity: [String: ContinuousClock.Instant] = [:]
    private var speakingExpiryTask: Task<Void, Never>?
    private var locallySpeaking = false
    private var localVoiceActivity = false
    private var trailingSilenceFrames = 0
    private var reconnectAttempts = 0
    private var videoSendQuality = 100
    private var audioSenderTracker = RTCPSenderTracker()
    private var videoSenderTracker = RTCPSenderTracker()
    private var videoRetransmissionCache = RTPRetransmissionCache()
    private var rejectedPacketCount = 0
    private var unmappedPacketCount = 0
    private var loggedInboundStreams = Set<UInt64>()
    private var didLogCapturedAudio = false
    private var didLogSentAudio = false
    private var didLogReceivedAudio = false
    private var didLogDecryptedAudio = false
    private var didLogPlayedAudio = false
    private var didLogReceivedVideo = false
    private var didLogCapturedVideo = false
    private var didLogSentVideo = false
    private var didLogSuppressedVideo = false
    private var cameraGeneration: UInt64 = 0
    private var inboundAudioPacketCount = 0
    private var inboundVideoPacketCount = 0
    private var scheduledAudioPacketCount = 0

    private lazy var dave = DaveSessionManager(
        selfUserId: info.userID.description,
        groupId: UInt64(info.serverID) ?? info.channelID.rawValue,
        delegate: self
    )

    private static let opusSilence = Data([0xF8, 0xFF, 0xFE])

    public init(info: VoiceConnectionInfo, configuration: VoiceSessionConfiguration = .init()) {
        self.info = info
        self.configuration = configuration
        gateway = VoiceGatewayConnection(info: info)
        let stream = AsyncStream<VoiceSessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(1000))
        events = stream.stream
        eventContinuation = stream.continuation
    }

    public func connect() async throws {
        guard state == .idle || state == .disconnected || state == .failed else { return }
        voiceMediaLogger.info("Voice session connect started")
        transition(to: .connecting)
        gatewayEventTask?.cancel()
        gatewayEventTask = Task { [weak self, gateway] in
            for await event in gateway.events {
                guard !Task.isCancelled else { return }
                await self?.handleGatewayEvent(event.event)
            }
        }
        try await gateway.connect()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
                connectTimeoutTask?.cancel()
                connectTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    await self?.failConnectIfPending(id: id)
                }
            }
        } onCancel: {
            Task { await self.cancelPendingConnect() }
        }
    }

    public func disconnect() async {
        guard state != .disconnected else { return }
        transition(to: .disconnecting)
        gatewayEventTask?.cancel()
        udpTask?.cancel()
        inboundVideoContinuation?.finish()
        inboundVideoContinuation = nil
        inboundVideoTask?.cancel()
        inboundVideoTask = nil
        capturedAudioContinuation?.finish()
        capturedAudioContinuation = nil
        capturedAudioTask?.cancel()
        capturedAudioTask = nil
        speakingExpiryTask?.cancel()
        speakingExpiryTask = nil
        connectTimeoutTask?.cancel()
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
        if locallySpeaking, let audioSSRC {
            try? await gateway.sendSpeaking(flags: 0, ssrc: audioSSRC)
        }
        updateLocalVoiceActivity(false)
        if let audioSSRC, let videoSSRC, let rtxSSRC {
            try? await gateway.sendVideo(
                audioSSRC: audioSSRC,
                videoSSRC: videoSSRC,
                rtxSSRC: rtxSSRC,
                width: VoiceVideoEngine.width,
                height: VoiceVideoEngine.height,
                framerate: VoiceVideoEngine.framerate,
                enabled: false
            )
        }
        await gateway.close()
        await udp?.close()
        if let audioEngine {
            await audioEngine.stop()
        }
        cameraGeneration &+= 1
        stopCameraPipeline()
        udp = nil
        audioEngine = nil
        cipher = nil
        participants.removeAll()
        lastRemoteAudioActivity.removeAll()
        ssrcToUserID.removeAll()
        rtxToVideoSSRC.removeAll()
        videoDepacketizers.removeAll()
        videoDecoders.removeAll()
        reorderBuffers.removeAll()
        videoAwaitingKeyframe.removeAll()
        lastVideoKeyframeRequest.removeAll()
        videoRetransmissionCache.removeAll()
        transition(to: .disconnected)
        eventContinuation.finish()
    }

    public func setMuted(_ muted: Bool) async {
        configuration.isMuted = muted
        if let audioEngine {
            await audioEngine.setMuted(muted)
        }
        if muted {
            updateLocalVoiceActivity(false)
            trailingSilenceFrames = 0
            if locallySpeaking, let audioSSRC {
                try? await gateway.sendSpeaking(flags: 0, ssrc: audioSSRC)
                locallySpeaking = false
            }
        }
    }

    public func setDeafened(_ deafened: Bool) async {
        configuration.isDeafened = deafened
        if let audioEngine {
            await audioEngine.setDeafened(deafened)
        }
    }

    public func setInputVolume(_ volume: Float) async {
        configuration.inputVolume = min(max(volume, 0), 2)
        if let audioEngine {
            await audioEngine.setInputVolume(configuration.inputVolume)
        }
    }

    public func setOutputVolume(_ volume: Float) async {
        configuration.outputVolume = min(max(volume, 0), 2)
        if let audioEngine {
            await audioEngine.setOutputVolume(configuration.outputVolume)
        }
    }

    public func selectInputDevice(_ deviceID: AudioDeviceID?) async throws {
        configuration.inputDeviceID = deviceID
        try await audioEngine?.selectInputDevice(deviceID)
    }

    public func selectOutputDevice(_ deviceID: AudioDeviceID?) async throws {
        configuration.outputDeviceID = deviceID
        try await audioEngine?.selectOutputDevice(deviceID)
    }

    public func setParticipantVolume(_ volume: Float, userID: String) async {
        let volume = min(max(volume, 0), 2)
        participants[userID]?.volume = volume
        if let participant = participants[userID] {
            eventContinuation.yield(.participantChanged(participant))
        }
        if let audioEngine {
            await audioEngine.setParticipantVolume(volume, userID: userID)
        }
    }

    public func setCameraEnabled(_ enabled: Bool) async throws {
        guard state == .connected,
              let audioSSRC,
              let videoSSRC,
              let rtxSSRC else { throw VoiceSessionError.videoTransportUnavailable }
        if enabled {
            if videoEngine == nil {
                cameraGeneration &+= 1
                let generation = cameraGeneration
                guard await VoiceVideoEngine.requestCameraPermission() else {
                    throw VoiceSessionError.cameraPermissionDenied
                }
                guard generation == cameraGeneration else { return }
                let encodedFrames = AsyncStream<EncodedVideoFrame>.makeStream(
                    bufferingPolicy: .unbounded
                )
                let previewFrames = AsyncStream<VoiceVideoFrame>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                encodedVideoContinuation = encodedFrames.continuation
                previewVideoContinuation = previewFrames.continuation
                encodedVideoTask = Task { [weak self] in
                    for await frame in encodedFrames.stream {
                        guard !Task.isCancelled else { return }
                        await self?.handleCapturedVideoFrame(frame, generation: generation)
                    }
                }
                previewVideoTask = Task { [weak self] in
                    for await frame in previewFrames.stream {
                        guard !Task.isCancelled else { return }
                        await self?.emitLocalVideoFrame(frame, generation: generation)
                    }
                }
                let engine = try VoiceVideoEngine(
                    encodedFrameHandler: { [continuation = encodedFrames.continuation] frame in
                        continuation.yield(frame)
                    },
                    previewFrameHandler: { [continuation = previewFrames.continuation] frame in
                        continuation.yield(frame)
                    }
                )
                do {
                    try engine.start(cameraUniqueID: configuration.cameraUniqueID)
                } catch {
                    stopCameraPipeline()
                    throw error
                }
                videoEngine = engine
                didLogCapturedVideo = false
                didLogSentVideo = false
                didLogSuppressedVideo = false
                voiceMediaLogger.info("Local camera capture started")
            }
        } else {
            cameraGeneration &+= 1
            stopCameraPipeline()
            voiceMediaLogger.info("Local camera capture stopped")
        }
        try await gateway.sendVideo(
            audioSSRC: audioSSRC,
            videoSSRC: videoSSRC,
            rtxSSRC: rtxSSRC,
            width: VoiceVideoEngine.width,
            height: VoiceVideoEngine.height,
            framerate: VoiceVideoEngine.framerate,
            enabled: enabled
        )
        voiceMediaLogger.info("Local video state advertised; enabled=\(enabled)")
    }

    public func selectCamera(uniqueID: String?) async throws {
        configuration.cameraUniqueID = uniqueID
        guard videoEngine != nil else { return }
        cameraGeneration &+= 1
        stopCameraPipeline()
        try await setCameraEnabled(true)
    }

    private func handleGatewayEvent(_ event: VoiceGatewayServerEvent) async {
        do {
            switch event {
            case let .ready(ready):
                try await setupUDP(ready)
            case let .sessionDescription(description):
                try await handleSessionDescription(description)
            case let .speaking(userID, ssrc, flags):
                ssrcToUserID[ssrc] = userID
                await dave.addUser(userId: userID)
                var participant = participants[userID] ?? VoiceRemoteParticipant(userID: userID)
                participant.audioSSRC = ssrc
                participant.isSpeaking = flags & 1 != 0
                participants[userID] = participant
                if participant.isSpeaking {
                    noteRemoteAudioActivity(userID: userID)
                } else {
                    lastRemoteAudioActivity[userID] = nil
                }
                eventContinuation.yield(.participantChanged(participant))
            case let .clientsConnected(userIDs):
                for userID in userIDs where userID != info.userID.description {
                    await dave.addUser(userId: userID)
                    if participants[userID] == nil {
                        participants[userID] = VoiceRemoteParticipant(userID: userID)
                    }
                }
            case let .clientDisconnected(userID):
                await dave.removeUser(userId: userID)
                participants[userID] = nil
                lastRemoteAudioActivity[userID] = nil
                ssrcToUserID = ssrcToUserID.filter { $0.value != userID }
                eventContinuation.yield(.participantLeft(userID: userID))
            case let .video(video):
                await handleVideoState(video)
            case let .videoSinkWants(wants, any):
                if let videoSSRC {
                    videoSendQuality = wants[videoSSRC] ?? any ?? 100
                    voiceMediaLogger.info(
                        "Video sink demand updated; quality=\(self.videoSendQuality), exact=\(wants[videoSSRC] != nil)"
                    )
                }
            case let .davePrepareTransition(transitionID, protocolVersion):
                await dave.prepareTransition(transitionId: transitionID, protocolVersion: protocolVersion)
            case let .daveExecuteTransition(transitionID):
                await dave.executeTransition(transitionId: transitionID)
                await requestCurrentRemoteKeyframes(reason: "DAVE transition became usable")
            case let .davePrepareEpoch(transitionID, epoch, protocolVersion):
                await dave.prepareEpoch(
                    transitionId: transitionID,
                    epoch: String(epoch),
                    protocolVersion: protocolVersion
                )
            case let .daveMLSExternalSender(data):
                await dave.mlsExternalSenderPackage(externalSenderPackage: data)
            case let .daveMLSProposals(data):
                await dave.mlsProposals(proposals: data)
            case let .daveMLSAnnounceCommit(transitionID, commit):
                await dave.mlsPrepareCommitTransition(transitionId: transitionID, commit: commit)
            case let .daveMLSWelcome(transitionID, welcome):
                await dave.mlsWelcome(transitionId: transitionID, welcome: welcome)
                await requestCurrentRemoteKeyframes(reason: "initial DAVE ratchets became usable")
            case .resumed:
                reconnectAttempts = 0
                transition(to: .connected)
            case .connectionClosed:
                await reconnectGateway()
            case let .heartbeatAcknowledged(nonce):
                let now = UInt64(max(0, Date.now.timeIntervalSince1970 * 1000))
                let latency = Int(clamping: now >= nonce ? now - nonce : 0)
                eventContinuation.yield(.latencyUpdated(milliseconds: latency))
            case .hello, .unknown:
                break
            }
        } catch {
            eventContinuation.yield(.error(error.localizedDescription))
            if state == .connecting {
                connectContinuation?.resume(throwing: error)
                connectContinuation = nil
                transition(to: .failed)
            }
        }
    }

    private func setupUDP(_ ready: VoiceGatewayReady) async throws {
        guard let mode = VoiceTransportMode.preferred(from: ready.modes) else {
            throw VoiceSessionError.unsupportedTransportEncryption
        }
        voiceMediaLogger.info(
            "Voice UDP setup; mode=\(mode.rawValue, privacy: .public), videoStreams=\(ready.streams.count)"
        )
        let udp = VoiceUDPConnection(host: ready.ip, port: ready.port)
        try await udp.start()
        let discovered = try await udp.discoverExternalAddress(ssrc: ready.ssrc)
        self.udp = udp
        audioSSRC = ready.ssrc
        await dave.assignAudioSSRC(ready.ssrc)
        let stream = ready.streams.first(where: { $0.quality == 100 }) ?? ready.streams.first
        let videoSSRC = stream?.ssrc ?? ready.ssrc &+ 1
        let rtxSSRC = stream?.rtxSSRC ?? ready.ssrc &+ 2
        self.videoSSRC = videoSSRC
        self.rtxSSRC = rtxSSRC
        videoRID = stream?.rid ?? "100"
        await dave.assignVideoSSRC(videoSSRC, codec: .h264)
        try await gateway.sendSelectProtocol(address: discovered.ip, port: discovered.port, mode: mode)
        // Discord requires every client to publish at least one Speaking state
        // before it will route remote audio to that client. Announce silence
        // after transport selection so receive audio works while muted or in DTX.
        try await gateway.sendSpeaking(flags: 0, ssrc: ready.ssrc)
        voiceMediaLogger.info("Initial silent speaking state advertised")
        voiceMediaLogger.info("Voice UDP discovery and protocol selection completed")
        await udp.beginReceiving()
        udpTask?.cancel()
        inboundVideoContinuation?.finish()
        inboundVideoTask?.cancel()
        let inboundVideoPackets = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        inboundVideoContinuation = inboundVideoPackets.continuation
        inboundVideoTask = Task { [weak self] in
            for await packet in inboundVideoPackets.stream {
                guard !Task.isCancelled else { return }
                await self?.handleUDPPacket(packet)
            }
        }
        udpTask = Task { [weak self, udp] in
            do {
                for try await packet in udp.packets {
                    guard !Task.isCancelled else { return }
                    // Video can arrive as hundreds of RTP datagrams per second. Keep it
                    // off the direct receive loop so a high-bitrate camera cannot leave
                    // Opus packets queued behind a persistent video backlog.
                    if !RTCPHeader.looksLikeRTCP(packet),
                       let payloadType = RTPHeader.parse(from: packet)?.header.payloadType
                    {
                        switch payloadType {
                        case 101, 102, 105, 106:
                            inboundVideoPackets.continuation.yield(packet)
                            continue
                        case 96:
                            // Discord reserves payload 96 for bandwidth probes. It is not
                            // decodable media and should not consume receive-pipeline time.
                            continue
                        default:
                            break
                        }
                    }
                    await self?.handleUDPPacket(packet)
                }
            } catch {
                await self?.report(error)
            }
        }
    }

    private func handleSessionDescription(_ description: VoiceGatewaySessionDescription) async throws {
        guard let mode = VoiceTransportMode(rawValue: description.mode) else {
            throw VoiceSessionError.unsupportedTransportEncryption
        }
        cipher = try VoiceTransportCipher(mode: mode, key: description.secretKey)
        voiceMediaLogger.info(
            "Voice session description accepted; mode=\(description.mode, privacy: .public), daveVersion=\(description.daveProtocolVersion), audioCodec=\(description.audioCodec ?? "unknown", privacy: .public), videoCodec=\(description.videoCodec ?? "unknown", privacy: .public), keyframeInterval=\(description.keyframeInterval ?? 0)"
        )
        await dave.selectProtocol(protocolVersion: description.daveProtocolVersion)
        eventContinuation.yield(.encryptionReady(protocolVersion: description.daveProtocolVersion))
        let permission = await VoiceAudioEngine.requestMicrophonePermission()
        guard permission else { throw VoiceSessionError.microphonePermissionDenied }
        let audio = try await VoiceAudioEngine()
        await audio.setInputVolume(configuration.inputVolume)
        await audio.setOutputVolume(configuration.outputVolume)
        await audio.setMuted(configuration.isMuted)
        await audio.setDeafened(configuration.isDeafened)
        let capturedFrames = AsyncStream<CapturedOpusFrame>.makeStream(bufferingPolicy: .unbounded)
        capturedAudioContinuation = capturedFrames.continuation
        capturedAudioTask = Task { [weak self] in
            for await frame in capturedFrames.stream {
                guard !Task.isCancelled else { return }
                await self?.handleCapturedFrame(frame)
            }
        }
        do {
            try await audio.start(
                inputDeviceID: configuration.inputDeviceID,
                outputDeviceID: configuration.outputDeviceID
            ) { [continuation = capturedFrames.continuation] frame in
                continuation.yield(frame)
            }
        } catch {
            capturedFrames.continuation.finish()
            capturedAudioTask?.cancel()
            capturedAudioContinuation = nil
            capturedAudioTask = nil
            throw error
        }
        audioEngine = audio
        voiceMediaLogger.info("Voice audio engine started")
        connectTimeoutTask?.cancel()
        connectContinuation?.resume()
        connectContinuation = nil
        transition(to: .connected)
    }

    private func handleCapturedFrame(_ frame: CapturedOpusFrame) async {
        guard state == .connected, audioSSRC != nil else { return }
        updateLocalVoiceActivity(frame.containsVoice && !configuration.isMuted)
        if !didLogCapturedAudio {
            didLogCapturedAudio = true
            voiceMediaLogger.info(
                "First microphone frame captured; bytes=\(frame.data.count), containsVoice=\(frame.containsVoice)"
            )
        }
        timestamp &+= UInt32(OpusCodec.frameSamples)
        if frame.containsVoice, !configuration.isMuted {
            trailingSilenceFrames = 0
            if !locallySpeaking, let audioSSRC {
                try? await gateway.sendSpeaking(flags: 1, ssrc: audioSSRC)
                locallySpeaking = true
            }
            try? await sendAudioPayload(frame.data)
        } else if locallySpeaking {
            if trailingSilenceFrames < 5 {
                trailingSilenceFrames += 1
                try? await sendAudioPayload(Self.opusSilence)
            } else if let audioSSRC {
                try? await gateway.sendSpeaking(flags: 0, ssrc: audioSSRC)
                locallySpeaking = false
                trailingSilenceFrames = 0
            }
        }
    }

    private func sendAudioPayload(_ opus: Data) async throws {
        guard let udp, let audioSSRC, cipher != nil else { return }
        let protectedFrame = opus == Self.opusSilence
            ? opus
            : try await dave.encrypt(ssrc: audioSSRC, data: opus)
        let header = RTPHeader(
            payloadType: 120,
            sequence: sequence,
            timestamp: timestamp,
            ssrc: audioSSRC
        ).encoded
        let packet = try sealTransport(header: header, plaintext: protectedFrame)
        sequence &+= 1
        try await udp.send(packet)
        if !didLogSentAudio {
            didLogSentAudio = true
            voiceMediaLogger.info("First encrypted audio packet sent; bytes=\(packet.count)")
        }
        audioSenderTracker.record(packets: 1, octets: protectedFrame.count)
        if let report = audioSenderTracker.reportIfDue(ssrc: audioSSRC, rtpTimestamp: timestamp) {
            try await sendSenderReport(report, udp: udp)
        }
    }

    private func handleCapturedVideoFrame(_ frame: EncodedVideoFrame, generation: UInt64) async {
        guard generation == cameraGeneration, videoEngine != nil, state == .connected else { return }
        if !didLogCapturedVideo {
            didLogCapturedVideo = true
            voiceMediaLogger.info(
                "First local H264 frame encoded; bytes=\(frame.data.count), keyframe=\(frame.isKeyframe), demand=\(self.videoSendQuality)"
            )
        }
        guard videoSendQuality > 0 else {
            if !didLogSuppressedVideo {
                didLogSuppressedVideo = true
                voiceMediaLogger.warning("Local video transmission paused because no sink requested a stream")
            }
            return
        }
        do {
            try await sendVideoFrame(frame)
        } catch {
            report(error)
        }
    }

    private func sendVideoFrame(_ frame: EncodedVideoFrame) async throws {
        guard let udp, let videoSSRC, cipher != nil else { return }
        let protectedFrame = try await dave.encrypt(
            ssrc: videoSSRC,
            data: frame.data,
            mediaType: .video
        )
        if !didLogSentVideo {
            let nalTypes = AnnexB.split(frame: protectedFrame).compactMap { $0.first.map { $0 & 0x1F } }
            voiceMediaLogger.info("First protected H264 NAL types: \(nalTypes.description, privacy: .public)")
        }
        let fragments = try H264RTPPacketizer.packetize(protectedFrame)
        for fragment in fragments {
            let originalSequence = videoSequence
            let extensionData = makeVideoHeaderExtension(repaired: false)
            let header = RTPHeader(
                marker: fragment.marker,
                payloadType: 105,
                sequence: originalSequence,
                timestamp: frame.rtpTimestamp,
                ssrc: videoSSRC,
                extensionProfile: 0xBEDE,
                extensionLengthInWords: UInt16(extensionData.count / 4)
            ).encoded
            let packet = try sealTransport(
                header: header,
                plaintext: extensionData + fragment.payload
            )
            videoRetransmissionCache.insert(RTPRetransmissionPacket(
                sequence: originalSequence,
                timestamp: frame.rtpTimestamp,
                marker: fragment.marker,
                payload: fragment.payload
            ))
            videoSequence &+= 1
            try await udp.send(packet)
            if !fragment.marker {
                try? await Task.sleep(for: .microseconds(375))
            }
        }
        if !didLogSentVideo {
            didLogSentVideo = true
            voiceMediaLogger.info(
                "First encrypted video frame sent; encodedBytes=\(frame.data.count), protectedBytes=\(protectedFrame.count), packets=\(fragments.count)"
            )
        }
        videoSenderTracker.record(
            packets: fragments.count,
            octets: fragments.reduce(0) { $0 + $1.payload.count }
        )
        if let report = videoSenderTracker.reportIfDue(ssrc: videoSSRC, rtpTimestamp: frame.rtpTimestamp) {
            try await sendSenderReport(report, udp: udp)
        }
    }

    private func sendSenderReport(
        _ report: RTCPSenderReport,
        udp: VoiceUDPConnection
    ) async throws {
        let packet = try sealTransport(header: report.header, plaintext: report.payload)
        try await udp.send(packet)
    }

    private func sealTransport(header: Data, plaintext: Data) throws -> Data {
        guard var cipher else { throw VoiceSessionError.transportUnavailable }
        let packet = try cipher.seal(header: header, plaintext: plaintext)
        // Persist the consumed nonce before the asynchronous UDP send. A failed
        // datagram must never cause the next packet to reuse an AEAD nonce.
        self.cipher = cipher
        return packet
    }

    private func handleUDPPacket(_ packet: Data) async {
        guard let cipher else { return }
        let diagnosticPayloadType = RTPHeader.parse(from: packet)?.header.payloadType
        do {
            if RTCPHeader.looksLikeRTCP(packet) {
                let opened = try cipher.openRTCP(packet: packet)
                try await handleRTCPPacket(header: opened.header, payload: opened.payload)
                return
            }
            let opened = try cipher.open(packet: packet)
            if opened.payload.isEmpty {
                return
            }
            let streamKey = (UInt64(opened.header.payloadType) << 32) | UInt64(opened.header.ssrc)
            let isFirstStreamPacket = loggedInboundStreams.insert(streamKey).inserted
            if isFirstStreamPacket {
                voiceMediaLogger.info(
                    "First inbound RTP stream packet; payload=\(opened.header.payloadType), ssrc=\(opened.header.ssrc), bytes=\(opened.payload.count)"
                )
            }
            switch opened.header.payloadType {
            case 120, 101, 105:
                if opened.header.payloadType == 120 {
                    inboundAudioPacketCount += 1
                    if inboundAudioPacketCount.isMultiple(of: 250) {
                        voiceMediaLogger.info(
                            "Inbound audio remains active; packets=\(self.inboundAudioPacketCount), ssrc=\(opened.header.ssrc)"
                        )
                    }
                } else {
                    inboundVideoPacketCount += 1
                }
                try await reorderAndProcess(header: opened.header, payload: opened.payload)
            case 102, 106:
                inboundVideoPacketCount += 1
                guard opened.payload.count > 2,
                      let primarySSRC = rtxToVideoSSRC[opened.header.ssrc] else { return }
                var header = opened.header
                header.payloadType = opened.header.payloadType == 106 ? 105 : 101
                header.ssrc = primarySSRC
                header.sequence = opened.payload.readUInt16BigEndian(at: 0) ?? header.sequence
                try await reorderAndProcess(header: header, payload: Data(opened.payload.dropFirst(2)))
            default:
                if isFirstStreamPacket {
                    voiceMediaLogger.warning(
                        "Ignoring unnegotiated RTP payload type \(opened.header.payloadType); ssrc=\(opened.header.ssrc)"
                    )
                }
                return
            }
        } catch {
            // Authentication, transition, and late-packet failures are isolated to this packet.
            rejectedPacketCount += 1
            if rejectedPacketCount <= 5 || rejectedPacketCount.isMultiple(of: 100) {
                let payload = diagnosticPayloadType.map(String.init) ?? "unknown"
                let message = "Media packet rejected (\(rejectedPacketCount), payload \(payload)): \(String(reflecting: error))"
                voiceMediaLogger.error("\(message, privacy: .public)")
                eventContinuation.yield(.error(message))
            }
        }
    }

    private func reorderAndProcess(header: RTPHeader, payload: Data) async throws {
        var buffer = reorderBuffers[header.ssrc] ?? RTPReorderBuffer(
            maximumHold: (header.payloadType == 101 || header.payloadType == 105) ? 64 : 8
        )
        let ordered = buffer.insert(RTPBufferedPacket(header: header, payload: payload))
        let newlyMissing = buffer.takeNewMissingSequences()
        let skippedGap = buffer.takeSkippedGap()
        reorderBuffers[header.ssrc] = buffer
        if header.payloadType == 101 || header.payloadType == 105, !newlyMissing.isEmpty {
            try? await sendGenericNACK(mediaSSRC: header.ssrc, lostSequences: newlyMissing)
        }
        if header.payloadType == 101 || header.payloadType == 105, skippedGap {
            await requestVideoKeyframe(mediaSSRC: header.ssrc, reason: "unrecovered RTP gap")
        }
        for packet in ordered {
            switch packet.header.payloadType {
            case 120:
                try await handleAudioPacket(header: packet.header, payload: packet.payload)
            case 101, 105:
                try await handleVideoPacket(header: packet.header, payload: packet.payload)
            default:
                break
            }
        }
    }

    private func handleRTCPPacket(header: RTCPHeader, payload: Data) async throws {
        if let nack = RTCPGenericNACK.parse(header: header, payload: payload),
           nack.mediaSSRC == videoSSRC
        {
            try await retransmitVideoPackets(nack.lostSequences)
            return
        }
        if let pli = RTCPPictureLossIndication.parse(header: header, payload: payload),
           pli.mediaSSRC == videoSSRC
        {
            videoEngine?.requestKeyframe()
            voiceMediaLogger.info("Remote receiver requested a local video keyframe")
        }
    }

    private func sendGenericNACK(mediaSSRC: UInt32, lostSequences: [UInt16]) async throws {
        guard let udp, let audioSSRC, !lostSequences.isEmpty else { return }
        let nack = RTCPGenericNACK(
            senderSSRC: audioSSRC,
            mediaSSRC: mediaSSRC,
            lostSequences: lostSequences
        )
        let packet = try sealTransport(header: nack.header, plaintext: nack.payload)
        try await udp.send(packet)
    }

    private func sendPictureLossIndication(mediaSSRC: UInt32) async throws {
        guard let udp, let audioSSRC else { return }
        let pli = RTCPPictureLossIndication(senderSSRC: audioSSRC, mediaSSRC: mediaSSRC)
        let packet = try sealTransport(header: pli.header, plaintext: pli.payload)
        try await udp.send(packet)
    }

    private func retransmitVideoPackets(_ sequences: [UInt16]) async throws {
        guard let udp, let rtxSSRC else { return }
        for sequence in sequences {
            guard let original = videoRetransmissionCache.packet(sequence: sequence) else { continue }
            let extensionData = makeVideoHeaderExtension(repaired: true)
            let header = RTPHeader(
                marker: original.marker,
                payloadType: 106,
                sequence: rtxSequence,
                timestamp: original.timestamp,
                ssrc: rtxSSRC,
                extensionProfile: 0xBEDE,
                extensionLengthInWords: UInt16(extensionData.count / 4)
            ).encoded
            var rtxPayload = Data()
            rtxPayload.appendBigEndian(original.sequence)
            rtxPayload.append(original.payload)
            let packet = try sealTransport(
                header: header,
                plaintext: extensionData + rtxPayload
            )
            rtxSequence &+= 1
            try await udp.send(packet)
        }
    }

    /// Native Discord UDP uses a fixed extension map rather than WebRTC's SDP IDs.
    /// Video packets need transport-wide sequence (5), playout delay (6), and the
    /// negotiated primary/repaired RID (11/12) so the SFU can route the SSRC layer.
    private func makeVideoHeaderExtension(repaired: Bool) -> Data {
        var data = Data()
        data.append(0x51) // ID 5, two-byte transport-wide sequence.
        data.appendBigEndian(videoTransportSequence)
        videoTransportSequence &+= 1
        data.append(contentsOf: [0x62, 0x00, 0x00, 0x0A]) // ID 6, 0-100 ms playout delay.

        let rid = Data(videoRID.utf8.prefix(16))
        if !rid.isEmpty {
            let identifier: UInt8 = repaired ? 12 : 11
            data.append((identifier << 4) | UInt8(rid.count - 1))
            data.append(rid)
        }
        while !data.count.isMultiple(of: 4) {
            data.append(0)
        }
        return data
    }

    private func handleAudioPacket(header: RTPHeader, payload: Data) async throws {
        let userID: String
        if let mapped = ssrcToUserID[header.ssrc] {
            userID = mapped
        } else if participants.count == 1, let inferred = participants.keys.first {
            userID = inferred
            ssrcToUserID[header.ssrc] = inferred
            participants[inferred]?.audioSSRC = header.ssrc
            if let participant = participants[inferred] {
                eventContinuation.yield(.participantChanged(participant))
            }
            voiceMediaLogger.info("Inferred the only remote participant's audio SSRC")
        } else {
            unmappedPacketCount += 1
            if unmappedPacketCount <= 5 || unmappedPacketCount.isMultiple(of: 100) {
                voiceMediaLogger.warning(
                    "Audio packet has no user mapping; count=\(self.unmappedPacketCount), ssrc=\(header.ssrc)"
                )
            }
            return
        }
        if !didLogReceivedAudio {
            didLogReceivedAudio = true
            voiceMediaLogger.info(
                "First mapped remote audio packet; user=\(userID, privacy: .public), ssrc=\(header.ssrc), bytes=\(payload.count)"
            )
        }
        let opus: Data
        if payload == Self.opusSilence {
            opus = payload
        } else {
            guard let decrypted = try await dave.decrypt(
                userId: userID,
                data: payload,
                mediaType: .audio
            ) else { return }
            opus = decrypted
        }
        if !didLogDecryptedAudio {
            didLogDecryptedAudio = true
            voiceMediaLogger.info("First remote Opus frame decrypted; bytes=\(opus.count)")
        }
        if opus == Self.opusSilence {
            return
        }
        noteRemoteAudioActivity(userID: userID)
        try await audioEngine?.play(opusPacket: opus, from: userID)
        scheduledAudioPacketCount += 1
        if scheduledAudioPacketCount.isMultiple(of: 250) {
            voiceMediaLogger.info(
                "Remote audio playback remains active; packets=\(self.scheduledAudioPacketCount), videoPackets=\(self.inboundVideoPacketCount)"
            )
        }
        if !didLogPlayedAudio {
            didLogPlayedAudio = true
            voiceMediaLogger.info("First remote audio packet decoded and scheduled")
        }
    }

    private func handleVideoPacket(header: RTPHeader, payload: Data) async throws {
        guard let userID = ssrcToUserID[header.ssrc] else { return }
        var depacketizer = videoDepacketizers[header.ssrc] ?? H264RTPDepacketizer()
        let completed = try depacketizer.append(header: header, payload: payload)
        videoDepacketizers[header.ssrc] = depacketizer
        guard let completed else { return }
        let decrypted: Data
        do {
            guard let frame = try await dave.decrypt(
                userId: userID,
                data: completed,
                mediaType: .video
            ) else { return }
            decrypted = frame
        } catch {
            await requestVideoKeyframe(mediaSSRC: header.ssrc, reason: "DAVE frame verification failed")
            throw error
        }
        if videoAwaitingKeyframe.contains(header.ssrc) {
            guard AnnexB.isKeyframe(decrypted) else { return }
            videoAwaitingKeyframe.remove(header.ssrc)
            voiceMediaLogger.info("Remote video recovered on an H264 keyframe")
        }
        if !didLogReceivedVideo {
            didLogReceivedVideo = true
            voiceMediaLogger.info("First remote encrypted video frame reassembled and decrypted")
        }
        guard participants[userID]?.videoSSRC == header.ssrc else { return }
        let decoder: H264VideoDecoder
        if let existing = videoDecoders[header.ssrc] {
            decoder = existing
        } else {
            decoder = H264VideoDecoder { [weak self] frame in
                Task { await self?.emitRemoteVideoFrame(frame, userID: userID) }
            }
            videoDecoders[header.ssrc] = decoder
        }
        let mediaSSRC = header.ssrc
        decoder.enqueue(annexBFrame: decrypted) { [weak self] in
            Task {
                await self?.requestVideoKeyframe(
                    mediaSSRC: mediaSSRC,
                    reason: "H264 decoder rejected a frame"
                )
            }
        }
    }

    private func handleVideoState(_ state: VoiceVideoState) async {
        guard state.userID != info.userID.description else { return }
        ssrcToUserID[state.audioSSRC] = state.userID
        var activeStreams = state.streams.filter { $0.active && $0.ssrc > 0 }
        if activeStreams.isEmpty, state.videoSSRC > 0 {
            activeStreams = [VoiceVideoStream(
                ssrc: state.videoSSRC,
                rtxSSRC: state.rtxSSRC,
                active: true
            )]
        }
        for stream in activeStreams {
            ssrcToUserID[stream.ssrc] = state.userID
            if stream.rtxSSRC > 0 {
                ssrcToUserID[stream.rtxSSRC] = state.userID
                rtxToVideoSSRC[stream.rtxSSRC] = stream.ssrc
            }
        }
        let selectedStream = activeStreams.max { lhs, rhs in
            if lhs.quality != rhs.quality {
                return lhs.quality < rhs.quality
            }
            return (lhs.maxBitrate ?? 0) < (rhs.maxBitrate ?? 0)
        }
        var participant = participants[state.userID] ?? VoiceRemoteParticipant(userID: state.userID)
        let previousVideoSSRC = participant.videoSSRC
        participant.audioSSRC = state.audioSSRC
        participant.videoSSRC = selectedStream?.ssrc
        participant.isCameraEnabled = selectedStream != nil
        participants[state.userID] = participant
        eventContinuation.yield(.participantChanged(participant))
        if activeStreams.isEmpty {
            if let previousVideoSSRC {
                ssrcToUserID[previousVideoSSRC] = nil
                videoDepacketizers[previousVideoSSRC] = nil
                reorderBuffers[previousVideoSSRC] = nil
                let rtxSSRCs = rtxToVideoSSRC.compactMap { key, value in
                    value == previousVideoSSRC ? key : nil
                }
                for rtxSSRC in rtxSSRCs {
                    ssrcToUserID[rtxSSRC] = nil
                    rtxToVideoSSRC[rtxSSRC] = nil
                    reorderBuffers[rtxSSRC] = nil
                }
            }
            for (ssrc, userID) in ssrcToUserID where userID == state.userID && ssrc != state.audioSSRC {
                videoDecoders[ssrc] = nil
            }
            eventContinuation.yield(.videoStopped(userID: state.userID))
        } else if previousVideoSSRC != selectedStream?.ssrc, let mediaSSRC = selectedStream?.ssrc {
            if let previousVideoSSRC {
                videoDecoders[previousVideoSSRC] = nil
            }
            await requestVideoKeyframe(mediaSSRC: mediaSSRC, reason: "remote video stream started")
        }
        let wants = Dictionary(uniqueKeysWithValues: activeStreams.map { stream in
            (stream.ssrc, stream.ssrc == selectedStream?.ssrc ? 100 : 0)
        })
        try? await gateway.sendVideoSinkWants(
            wants,
            // `any` covers every unspecified media SSRC, including Opus audio.
            // Setting it to zero while selecting a camera stream causes the SFU
            // to stop forwarding that participant's audio and remains sticky
            // after camera-off. Disable unwanted video layers explicitly above,
            // but leave all other media subscribed.
            any: 100
        )
        voiceMediaLogger.info(
            "Remote video layers updated; count=\(activeStreams.count), audioSSRC=\(state.audioSSRC), videoSSRC=\(selectedStream?.ssrc ?? 0), selectedQuality=\(selectedStream?.quality ?? 0), selectedBitrate=\(selectedStream?.maxBitrate ?? 0)"
        )
    }

    private func emitLocalVideoFrame(_ frame: VoiceVideoFrame, generation: UInt64) {
        guard generation == cameraGeneration, videoEngine != nil else { return }
        eventContinuation.yield(.videoFrame(userID: info.userID.description, frame: frame))
    }

    private func emitRemoteVideoFrame(_ frame: VoiceVideoFrame, userID: String) {
        eventContinuation.yield(.videoFrame(userID: userID, frame: frame))
    }

    private func noteRemoteAudioActivity(userID: String) {
        lastRemoteAudioActivity[userID] = .now
        if var participant = participants[userID], !participant.isSpeaking {
            participant.isSpeaking = true
            participants[userID] = participant
            eventContinuation.yield(.participantChanged(participant))
        }
        guard speakingExpiryTask == nil else { return }
        speakingExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                if await self?.expireInactiveSpeakers() != false {
                    return
                }
            }
        }
    }

    private func expireInactiveSpeakers() -> Bool {
        let now = ContinuousClock.now
        for (userID, instant) in lastRemoteAudioActivity
            where instant.duration(to: now) >= .milliseconds(120)
        {
            lastRemoteAudioActivity[userID] = nil
            if var participant = participants[userID], participant.isSpeaking {
                participant.isSpeaking = false
                participants[userID] = participant
                eventContinuation.yield(.participantChanged(participant))
            }
        }
        if lastRemoteAudioActivity.isEmpty {
            speakingExpiryTask = nil
            return true
        }
        return false
    }

    private func updateLocalVoiceActivity(_ active: Bool) {
        guard localVoiceActivity != active else { return }
        localVoiceActivity = active
        eventContinuation.yield(.localSpeakingChanged(active))
    }

    private func requestVideoKeyframe(mediaSSRC: UInt32, reason: String) async {
        videoAwaitingKeyframe.insert(mediaSSRC)
        videoDecoders[mediaSSRC] = nil
        let now = ContinuousClock.now
        if let previous = lastVideoKeyframeRequest[mediaSSRC],
           previous.duration(to: now) < .milliseconds(500)
        {
            return
        }
        lastVideoKeyframeRequest[mediaSSRC] = now
        try? await sendPictureLossIndication(mediaSSRC: mediaSSRC)
        voiceMediaLogger.info("Requested remote video keyframe; reason=\(reason, privacy: .public)")
    }

    private func requestCurrentRemoteKeyframes(reason: String) async {
        let mediaSSRCs = Set(participants.values.compactMap(\.videoSSRC))
        for mediaSSRC in mediaSSRCs {
            // A stream may be announced before the initial MLS welcome. Request a
            // fresh keyframe after ratchets exist instead of waiting for a camera toggle.
            lastVideoKeyframeRequest[mediaSSRC] = nil
            await requestVideoKeyframe(mediaSSRC: mediaSSRC, reason: reason)
        }
    }

    private func stopCameraPipeline() {
        encodedVideoContinuation?.finish()
        previewVideoContinuation?.finish()
        encodedVideoContinuation = nil
        previewVideoContinuation = nil
        encodedVideoTask?.cancel()
        previewVideoTask?.cancel()
        encodedVideoTask = nil
        previewVideoTask = nil
        let engine = videoEngine
        videoEngine = nil
        engine?.stop()
    }

    private func reconnectGateway() async {
        guard state == .connected || state == .reconnecting else { return }
        guard reconnectAttempts < 3 else {
            transition(to: .failed)
            eventContinuation.yield(.error("The Discord voice gateway could not be resumed."))
            return
        }
        reconnectAttempts += 1
        transition(to: .reconnecting)
        try? await Task.sleep(for: .seconds(pow(2, Double(reconnectAttempts - 1))))
        do {
            try await gateway.connect(resuming: true)
        } catch {
            await reconnectGateway()
        }
    }

    private func transition(to state: VoiceSessionState) {
        guard self.state != state else { return }
        self.state = state
        eventContinuation.yield(.stateChanged(state))
    }

    private func failConnectIfPending(id: UUID) {
        guard connectContinuation != nil else { return }
        connectContinuation?.resume(throwing: VoiceSessionError.connectionTimedOut)
        connectContinuation = nil
        transition(to: .failed)
    }

    private func cancelPendingConnect() {
        connectTimeoutTask?.cancel()
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
    }

    private func report(_ error: any Error) {
        eventContinuation.yield(.error(error.localizedDescription))
    }

    // MARK: DaveSessionDelegate

    public func mlsKeyPackage(keyPackage: Data) async {
        try? await gateway.sendDaveKeyPackage(keyPackage)
    }

    public func readyForTransition(transitionId: UInt16) async {
        try? await gateway.sendDaveTransitionReady(transitionId)
    }

    public func mlsCommitWelcome(welcome: Data) async {
        try? await gateway.sendDaveCommitWelcome(welcome)
    }

    public func mlsInvalidCommitWelcome(transitionId: UInt16) async {
        try? await gateway.sendDaveInvalidCommitWelcome(transitionId)
    }
}

public enum VoiceSessionError: Error, Equatable {
    case unsupportedTransportEncryption
    case microphonePermissionDenied
    case cameraPermissionDenied
    case videoTransportUnavailable
    case transportUnavailable
    case connectionTimedOut
}

private extension VoiceAudioEngine {
    func setMuted(_ value: Bool) {
        isMuted = value
    }

    func setDeafened(_ value: Bool) {
        isDeafened = value
    }

    func setInputVolume(_ value: Float) {
        inputVolume = value
    }

    func setOutputVolume(_ value: Float) {
        outputVolume = value
    }
}
