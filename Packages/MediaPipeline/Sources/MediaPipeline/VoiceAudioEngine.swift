import AVFAudio
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import OSLog

private let voiceAudioLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "VoiceAudio")

public struct CapturedOpusFrame: Sendable {
    public var data: Data
    public var containsVoice: Bool
    public var sampleOffset: UInt64

    public init(data: Data, containsVoice: Bool, sampleOffset: UInt64 = 0) {
        self.data = data
        self.containsVoice = containsVoice
        self.sampleOffset = sampleOffset
    }
}

@MainActor
public final class VoiceAudioEngine {
    public private(set) var isRunning = false
    public private(set) var inputDeviceID: AudioDeviceID?
    public private(set) var outputDeviceID: AudioDeviceID?
    public var inputVolume: Float = 1 {
        didSet { captureEncoder.inputVolume = min(max(inputVolume, 0), 2) }
    }

    public var outputVolume: Float = 1 {
        didSet { applyOutputVolume() }
    }

    public var isMuted = false {
        didSet { captureEncoder.isMuted = isMuted }
    }

    public var isDeafened = false {
        didSet { applyOutputVolume() }
    }

    // Capture uses AVCaptureSession rather than AVAudioEngine's full-duplex
    // HAL node. Merely opening the default Bluetooth input through an
    // AVAudioEngine can switch the headset transport for the entire Mac, even
    // when the node is immediately redirected to the built-in microphone.
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "app.sakuracord.audio.capture", qos: .userInteractive)
    private var captureOutput: AVCaptureAudioDataOutput?
    private let playbackEngine = AVAudioEngine()
    private let codec: OpusCodec
    private let captureEncoder: OpusSampleBufferEncoder
    private var players: [String: AVAudioPlayerNode] = [:]
    private var participantVolumes: [String: Float] = [:]
    private var captureSessionObservers: [NSObjectProtocol] = []
    private var captureRecoveryTask: Task<Void, Never>?
    private var playbackConfigurationObserver: NSObjectProtocol?
    private var playbackRecoveryTask: Task<Void, Never>?
    private var inputRouteGeneration: UInt64 = 0
    private var outputRouteGeneration: UInt64 = 0
    private var isChangingCaptureRoute = false
    private var isChangingPlaybackRoute = false

    public init(bitRate: Int = 64000) throws {
        let codec = try OpusCodec(bitRate: bitRate)
        self.codec = codec
        captureEncoder = OpusSampleBufferEncoder(codec: codec)
        playbackConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: playbackEngine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackConfigurationChanged()
            }
        }
        captureSessionObservers = [
            AVCaptureSession.runtimeErrorNotification,
            AVCaptureSession.didStopRunningNotification,
            AVCaptureSession.interruptionEndedNotification
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: captureSession,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.captureSessionChanged()
                }
            }
        }
    }

    isolated deinit {
        captureRecoveryTask?.cancel()
        playbackRecoveryTask?.cancel()
        for observer in captureSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let playbackConfigurationObserver {
            NotificationCenter.default.removeObserver(playbackConfigurationObserver)
        }
    }

    public static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    public func start(
        inputDeviceID: AudioDeviceID? = nil,
        outputDeviceID: AudioDeviceID? = nil,
        onCapturedFrame: @escaping @Sendable (CapturedOpusFrame) -> Void
    ) throws {
        stop()
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID
        captureEncoder.handler = onCapturedFrame
        do {
            try startPlaybackGraph()
            try startCaptureGraph()
            isRunning = true
        } catch {
            tearDownAudioGraph()
            throw error
        }
    }

    public func stop() {
        tearDownAudioGraph()
    }

    private func tearDownAudioGraph() {
        isRunning = false
        inputRouteGeneration &+= 1
        outputRouteGeneration &+= 1
        captureRecoveryTask?.cancel()
        captureRecoveryTask = nil
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        tearDownCaptureGraph()
        tearDownPlaybackGraph()
        captureEncoder.handler = nil
    }

    private func startCaptureGraph() throws {
        let (input, resolvedDeviceID) = try makeCaptureInput(
            deviceID: inputDeviceID,
            allowsDefaultFallback: true
        )
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(captureEncoder, queue: captureQueue)
        do {
            try captureQueue.sync { [captureSession] in
                captureSession.beginConfiguration()
                defer { captureSession.commitConfiguration() }
                for existing in captureSession.inputs {
                    captureSession.removeInput(existing)
                }
                for existing in captureSession.outputs {
                    captureSession.removeOutput(existing)
                }
                guard captureSession.canAddInput(input),
                      captureSession.canAddOutput(output)
                else { throw VoiceAudioEngineError.inputUnavailable }
                captureSession.addInput(input)
                captureSession.addOutput(output)
            }
        } catch {
            output.setSampleBufferDelegate(nil, queue: nil)
            throw error
        }
        inputDeviceID = resolvedDeviceID
        captureOutput = output
        voiceAudioLogger.info("Voice capture configured without opening a shared output route")
        captureQueue.async { [captureSession] in
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    private func makeCaptureInput(
        deviceID: AudioDeviceID?,
        allowsDefaultFallback: Bool
    ) throws -> (AVCaptureDeviceInput, AudioDeviceID?) {
        var resolvedDeviceID = deviceID
        var device = MediaDeviceCatalog.audioCaptureDevice(deviceID: deviceID)
        if device == nil, deviceID != nil, allowsDefaultFallback {
            voiceAudioLogger.warning(
                "Selected input device failed; falling back to the system default"
            )
            resolvedDeviceID = nil
            device = MediaDeviceCatalog.audioCaptureDevice(deviceID: nil)
        }
        guard let device else { throw VoiceAudioEngineError.inputUnavailable }
        do {
            return (try AVCaptureDeviceInput(device: device), resolvedDeviceID)
        } catch {
            throw VoiceAudioEngineError.inputUnavailable
        }
    }

    private func captureSessionChanged() {
        guard isRunning, !isChangingCaptureRoute, !captureSession.isRunning else { return }
        voiceAudioLogger.warning("The microphone capture session stopped unexpectedly")
        scheduleCaptureRecovery()
    }

    private func scheduleCaptureRecovery() {
        guard captureRecoveryTask == nil else { return }
        let generation = inputRouteGeneration
        captureRecoveryTask = Task { @MainActor [weak self] in
            defer {
                if self?.inputRouteGeneration == generation {
                    self?.captureRecoveryTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self,
                      self.isRunning,
                      generation == self.inputRouteGeneration
                else { return }
                try await self.recoverCaptureRoute(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                voiceAudioLogger.error(
                    "Microphone recovery failed: \(String(reflecting: error), privacy: .public)"
                )
            }
        }
    }

    private func recoverCaptureRoute(generation: UInt64) async throws {
        guard generation == inputRouteGeneration else {
            throw CancellationError()
        }
        isChangingCaptureRoute = true
        defer { isChangingCaptureRoute = false }
        do {
            try await stabilizeCaptureSession(generation: generation)
        } catch {
            guard generation == inputRouteGeneration else {
                throw CancellationError()
            }
            voiceAudioLogger.warning(
                "Selected microphone could not recover; trying the system default"
            )
            tearDownCaptureGraph()
            inputDeviceID = nil
            try startCaptureGraph()
            try await stabilizeCaptureSession(generation: generation)
        }
        voiceAudioLogger.info("Voice capture recovered after a hardware configuration change")
    }

    private func stabilizeCaptureSession(
        generation: UInt64,
        maximumAttempts: Int = 5
    ) async throws {
        for attempt in 0 ..< maximumAttempts {
            guard generation == inputRouteGeneration else {
                throw CancellationError()
            }
            captureQueue.sync { [captureSession] in
                if !captureSession.isRunning, !captureSession.inputs.isEmpty {
                    captureSession.startRunning()
                }
            }
            try await Task.sleep(for: .milliseconds(200 + attempt * 100))
            if captureSession.isRunning {
                return
            }
        }
        throw VoiceAudioEngineError.inputUnavailable
    }

    private func startPlaybackGraph(allowsDefaultFallback: Bool = true) throws {
        do {
            try startPlaybackGraph(on: outputDeviceID)
        } catch {
            guard outputDeviceID != nil, allowsDefaultFallback else { throw error }
            voiceAudioLogger.warning(
                "Selected output device failed; falling back to the system default"
            )
            outputDeviceID = nil
            try startPlaybackGraph(on: nil)
        }
    }

    private func startPlaybackGraph(on deviceID: AudioDeviceID?) throws {
        guard let resolvedDeviceID = deviceID ?? MediaDeviceCatalog.defaultOutputDeviceID() else {
            throw VoiceAudioEngineError.outputUnavailable
        }
        try MediaDeviceCatalog.selectOutput(resolvedDeviceID, on: playbackEngine)
        playbackEngine.mainMixerNode.outputVolume = isDeafened ? 0 : min(max(outputVolume, 0), 2)
        playbackEngine.prepare()
        try playbackEngine.start()
        let format = playbackEngine.mainMixerNode.outputFormat(forBus: 0)
        voiceAudioLogger.info(
            "Voice playback graph started; selectedDevice=\(resolvedDeviceID), sampleRate=\(format.sampleRate), channels=\(format.channelCount)"
        )
    }

    private func playbackConfigurationChanged() {
        guard isRunning, !isChangingPlaybackRoute else { return }
        voiceAudioLogger.warning(
            "Core Audio stopped the playback engine after a hardware configuration change"
        )
        schedulePlaybackRecovery()
    }

    private func schedulePlaybackRecovery() {
        guard playbackRecoveryTask == nil else { return }
        let generation = outputRouteGeneration
        playbackRecoveryTask = Task { @MainActor [weak self] in
            defer {
                if self?.outputRouteGeneration == generation {
                    self?.playbackRecoveryTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self,
                      self.isRunning,
                      generation == self.outputRouteGeneration
                else { return }
                try await self.recoverPlaybackRoute(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                voiceAudioLogger.error(
                    "Playback recovery failed: \(String(reflecting: error), privacy: .public)"
                )
            }
        }
    }

    private func recoverPlaybackRoute(generation: UInt64) async throws {
        guard generation == outputRouteGeneration else {
            throw CancellationError()
        }
        isChangingPlaybackRoute = true
        defer { isChangingPlaybackRoute = false }
        do {
            try await stabilizePlaybackEngine(generation: generation)
        } catch {
            guard generation == outputRouteGeneration else {
                throw CancellationError()
            }
            voiceAudioLogger.warning(
                "Selected output route could not recover; trying the system default"
            )
            tearDownPlaybackGraph()
            outputDeviceID = nil
            try startPlaybackGraph(allowsDefaultFallback: false)
            try await stabilizePlaybackEngine(generation: generation)
        }
        voiceAudioLogger.info("Voice playback recovered after a hardware configuration change")
    }

    private func stabilizePlaybackEngine(
        generation: UInt64,
        maximumAttempts: Int = 5
    ) async throws {
        var lastError: Error = VoiceAudioEngineError.outputUnavailable
        for attempt in 0 ..< maximumAttempts {
            guard generation == outputRouteGeneration else {
                throw CancellationError()
            }
            if !playbackEngine.isRunning {
                do {
                    playbackEngine.prepare()
                    try playbackEngine.start()
                    voiceAudioLogger.info(
                        "Restarted playback after configuration change; attempt=\(attempt + 1)"
                    )
                } catch {
                    lastError = error
                }
            }
            try await Task.sleep(for: .milliseconds(200 + attempt * 100))
            if playbackEngine.isRunning {
                return
            }
        }
        throw lastError
    }

    private func tearDownCaptureGraph() {
        captureOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureOutput = nil
        captureQueue.sync { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
            captureSession.beginConfiguration()
            for input in captureSession.inputs {
                captureSession.removeInput(input)
            }
            for output in captureSession.outputs {
                captureSession.removeOutput(output)
            }
            captureSession.commitConfiguration()
        }
    }

    private func tearDownPlaybackGraph() {
        for player in players.values {
            player.stop()
            playbackEngine.disconnectNodeOutput(player)
            playbackEngine.detach(player)
        }
        playbackEngine.stop()
        playbackEngine.reset()
        players.removeAll()
    }

    public func selectInputDevice(_ deviceID: AudioDeviceID?) async throws {
        guard isRunning else {
            inputDeviceID = deviceID
            return
        }
        inputRouteGeneration &+= 1
        let generation = inputRouteGeneration
        captureRecoveryTask?.cancel()
        captureRecoveryTask = nil
        isChangingCaptureRoute = true
        defer {
            if generation == inputRouteGeneration {
                isChangingCaptureRoute = false
            }
        }
        let (input, resolvedDeviceID) = try makeCaptureInput(
            deviceID: deviceID,
            allowsDefaultFallback: false
        )
        let previousInputs = try captureQueue.sync { [captureSession] in
            let previousInputs = captureSession.inputs
            captureSession.beginConfiguration()
            defer { captureSession.commitConfiguration() }
            for previousInput in previousInputs {
                captureSession.removeInput(previousInput)
            }
            guard captureSession.canAddInput(input) else {
                for previousInput in previousInputs where captureSession.canAddInput(previousInput) {
                    captureSession.addInput(previousInput)
                }
                throw VoiceAudioEngineError.inputUnavailable
            }
            captureSession.addInput(input)
            return previousInputs
        }
        do {
            try await stabilizeCaptureSession(generation: generation)
            inputDeviceID = resolvedDeviceID
            voiceAudioLogger.info("Voice capture switched without ending the voice session")
        } catch {
            guard generation == inputRouteGeneration else {
                throw CancellationError()
            }
            captureQueue.sync { [captureSession] in
                captureSession.beginConfiguration()
                defer { captureSession.commitConfiguration() }
                for currentInput in captureSession.inputs {
                    captureSession.removeInput(currentInput)
                }
                for previousInput in previousInputs where captureSession.canAddInput(previousInput) {
                    captureSession.addInput(previousInput)
                }
            }
            try? await stabilizeCaptureSession(generation: generation)
            throw error
        }
    }

    public func selectOutputDevice(_ deviceID: AudioDeviceID?) async throws {
        guard isRunning else {
            outputDeviceID = deviceID
            return
        }
        outputRouteGeneration &+= 1
        let generation = outputRouteGeneration
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        let previousDeviceID = outputDeviceID
        isChangingPlaybackRoute = true
        defer {
            if generation == outputRouteGeneration {
                isChangingPlaybackRoute = false
            }
        }
        tearDownPlaybackGraph()
        outputDeviceID = deviceID
        do {
            try startPlaybackGraph(allowsDefaultFallback: false)
            try await stabilizePlaybackEngine(generation: generation)
        } catch {
            guard generation == outputRouteGeneration else {
                throw CancellationError()
            }
            let selectionError = error
            tearDownPlaybackGraph()
            outputDeviceID = previousDeviceID
            do {
                try startPlaybackGraph(allowsDefaultFallback: false)
                try await stabilizePlaybackEngine(generation: generation)
            } catch {
                voiceAudioLogger.error(
                    "Previous output route could not be restored; trying the system default"
                )
                tearDownPlaybackGraph()
                outputDeviceID = nil
                do {
                    try startPlaybackGraph(allowsDefaultFallback: false)
                    try? await stabilizePlaybackEngine(generation: generation)
                } catch {
                    voiceAudioLogger.error(
                        "System-default output route could not be started: \(String(reflecting: error), privacy: .public)"
                    )
                }
            }
            throw selectionError
        }
    }

    public func setParticipantVolume(_ volume: Float, userID: String) {
        let volume = min(max(volume, 0), 2)
        participantVolumes[userID] = volume
        players[userID]?.volume = volume
    }

    public func play(opusPacket: Data, from userID: String) throws {
        guard !isDeafened, !isChangingPlaybackRoute else { return }
        if !playbackEngine.isRunning {
            schedulePlaybackRecovery()
            return
        }
        let buffer = try codec.decode(opusPacket)
        let player = try player(for: userID)
        player.scheduleBuffer(buffer)
        if !player.isPlaying {
            do {
                try player.playAudio()
            } catch {
                schedulePlaybackRecovery()
            }
        }
    }

    private func player(for userID: String) throws -> AVAudioPlayerNode {
        if let player = players[userID] {
            return player
        }
        let player = AVAudioPlayerNode()
        player.volume = participantVolumes[userID] ?? 1
        playbackEngine.attach(player)
        try playbackEngine.connectNode(player, to: playbackEngine.mainMixerNode, format: OpusCodec.pcmFormat)
        players[userID] = player
        return player
    }

    private func applyOutputVolume() {
        playbackEngine.mainMixerNode.outputVolume = isDeafened ? 0 : min(max(outputVolume, 0), 2)
    }
}

final class OpusSampleBufferEncoder: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    var handler: (@Sendable (CapturedOpusFrame) -> Void)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    var inputVolume: Float {
        get { lock.withLock { _inputVolume } }
        set { lock.withLock { _inputVolume = newValue } }
    }

    var isMuted: Bool {
        get { lock.withLock { _isMuted } }
        set { lock.withLock { _isMuted = newValue } }
    }

    private let codec: OpusCodec
    private let activityThreshold: Float
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var left: [Float] = []
    private var right: [Float] = []
    private var bufferedSampleOffset = 0
    private var encodedSampleOffset: UInt64 = 0
    private var _handler: (@Sendable (CapturedOpusFrame) -> Void)?
    private var _inputVolume: Float = 1
    private var _isMuted = false

    init(codec: OpusCodec, activityThreshold: Float = 0.003) {
        self.codec = codec
        self.activityThreshold = activityThreshold
        super.init()
    }

    convenience init(bitRate: Int = 64_000, activityThreshold: Float = 0.003) throws {
        try self.init(
            codec: OpusCodec(bitRate: bitRate),
            activityThreshold: activityThreshold
        )
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        process(sampleBuffer)
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let format = AVAudioFormat(formatDescription: description) else { return }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        ) == noErr else { return }
        do { try configure(inputFormat: format) } catch { return }
        process(buffer)
    }

    func configure(inputFormat: AVAudioFormat) throws {
        try lock.withLock {
            if let converter, converter.inputFormat == inputFormat {
                return
            }
            guard let converter = AVAudioConverter(from: inputFormat, to: OpusCodec.pcmFormat) else {
                throw VoiceAudioEngineError.converterUnavailable
            }
            self.converter = converter
            left.removeAll(keepingCapacity: true)
            right.removeAll(keepingCapacity: true)
            bufferedSampleOffset = 0
        }
    }

    func reset() {
        lock.withLock {
            left.removeAll(keepingCapacity: true)
            right.removeAll(keepingCapacity: true)
            bufferedSampleOffset = 0
        }
    }

    private func process(_ input: AVAudioPCMBuffer) {
        let frames: [CapturedOpusFrame] = lock.withLock {
            guard let converter else { return [] }
            let ratio = OpusCodec.sampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: OpusCodec.pcmFormat, frameCapacity: capacity) else { return [] }
            var supplied = false
            var error: NSError?
            _ = converter.convert(to: converted, error: &error) { _, status in
                guard !supplied else {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            guard error == nil,
                  let channels = converted.floatChannelData,
                  converted.frameLength > 0 else { return [] }
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(converted.frameLength)))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: Int(converted.frameLength)))

            var output: [CapturedOpusFrame] = []
            let frameCount = Int(OpusCodec.frameSamples)
            while left.count - bufferedSampleOffset >= frameCount,
                  right.count - bufferedSampleOffset >= frameCount
            {
                guard let pcm = AVAudioPCMBuffer(pcmFormat: OpusCodec.pcmFormat, frameCapacity: OpusCodec.frameSamples),
                      let outputChannels = pcm.floatChannelData else { break }
                pcm.frameLength = OpusCodec.frameSamples
                var energy: Float = 0
                for index in 0 ..< frameCount {
                    let bufferedIndex = bufferedSampleOffset + index
                    let leftSample = _isMuted ? 0 : left[bufferedIndex] * _inputVolume
                    let rightSample = _isMuted ? 0 : right[bufferedIndex] * _inputVolume
                    outputChannels[0][index] = leftSample
                    outputChannels[1][index] = rightSample
                    energy += leftSample * leftSample + rightSample * rightSample
                }
                bufferedSampleOffset += frameCount
                if let packet = try? codec.encode(pcm) {
                    encodedSampleOffset &+= UInt64(frameCount)
                    let rms = sqrt(energy / Float(frameCount * 2))
                    output.append(CapturedOpusFrame(
                        data: packet,
                        containsVoice: !_isMuted && rms > activityThreshold,
                        sampleOffset: encodedSampleOffset
                    ))
                }
            }
            compactBufferedSamples(frameCount: frameCount)
            return output
        }
        let handler = handler
        for frame in frames {
            handler?(frame)
        }
    }

    private func compactBufferedSamples(frameCount: Int) {
        guard bufferedSampleOffset > 0 else { return }
        if bufferedSampleOffset == left.count {
            left.removeAll(keepingCapacity: true)
            right.removeAll(keepingCapacity: true)
            bufferedSampleOffset = 0
        } else if bufferedSampleOffset >= frameCount * 4 {
            left.removeFirst(bufferedSampleOffset)
            right.removeFirst(bufferedSampleOffset)
            bufferedSampleOffset = 0
        }
    }
}

public enum VoiceAudioEngineError: Error, Equatable {
    case inputUnavailable
    case outputUnavailable
    case converterUnavailable
}

extension VoiceAudioEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            "The selected microphone is not available."
        case .outputUnavailable:
            "The selected speaker is not available."
        case .converterUnavailable:
            "The selected microphone uses an unsupported audio format."
        }
    }
}
