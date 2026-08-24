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
    public private(set) var isVoiceProcessingEnabled = false
    public var inputLevelHandler: (@Sendable (Float) -> Void)? {
        didSet { captureEncoder.levelHandler = inputLevelHandler }
    }
    public var inputVolume: Float = 1 {
        didSet { captureEncoder.inputVolume = min(max(inputVolume, 0), 2) }
    }

    public var outputVolume: Float = 1 {
        didSet { applyOutputVolume() }
    }

    public var isMuted = false {
        didSet {
            captureEncoder.isMuted = isMuted
            if isVoiceProcessingEnabled {
                playbackEngine.inputNode.isVoiceProcessingInputMuted = isMuted
            }
        }
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
    private var hasVoiceProcessingTap = false

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
        voiceProcessingEnabled: Bool = false,
        onCapturedFrame: @escaping @Sendable (CapturedOpusFrame) -> Void
    ) throws {
        stop()
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID
        isVoiceProcessingEnabled = voiceProcessingEnabled
        captureEncoder.handler = onCapturedFrame
        do {
            if isVoiceProcessingEnabled {
                try startVoiceProcessingGraph()
            } else {
                try startPlaybackGraph()
                try startCaptureGraph()
            }
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
        tearDownVoiceProcessingCapture()
        tearDownPlaybackGraph()
        isVoiceProcessingEnabled = false
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

    private func startVoiceProcessingGraph(
        allowsInputDefaultFallback: Bool = true,
        allowsOutputDefaultFallback: Bool = true
    ) throws {
        let inputNode = playbackEngine.inputNode
        do {
            let resolvedInputID = inputDeviceID
                ?? MediaDeviceCatalog.defaultInputDeviceID()
            guard let resolvedInputID else {
                throw VoiceAudioEngineError.inputUnavailable
            }
            do {
                try MediaDeviceCatalog.selectInput(resolvedInputID, on: playbackEngine)
            } catch {
                guard inputDeviceID != nil, allowsInputDefaultFallback,
                      let defaultInputID = MediaDeviceCatalog.defaultInputDeviceID()
                else { throw VoiceAudioEngineError.inputUnavailable }
                self.inputDeviceID = nil
                try MediaDeviceCatalog.selectInput(defaultInputID, on: playbackEngine)
                voiceAudioLogger.warning(
                    "Selected voice-processing input failed; using the system default"
                )
            }
            let resolvedOutputID = outputDeviceID
                ?? MediaDeviceCatalog.defaultOutputDeviceID()
            guard let resolvedOutputID else {
                throw VoiceAudioEngineError.outputUnavailable
            }
            do {
                try MediaDeviceCatalog.selectOutput(resolvedOutputID, on: playbackEngine)
            } catch {
                guard outputDeviceID != nil, allowsOutputDefaultFallback,
                      let defaultOutputID = MediaDeviceCatalog.defaultOutputDeviceID()
                else { throw VoiceAudioEngineError.outputUnavailable }
                self.outputDeviceID = nil
                try MediaDeviceCatalog.selectOutput(defaultOutputID, on: playbackEngine)
                voiceAudioLogger.warning(
                    "Selected voice-processing output failed; using the system default"
                )
            }
            try inputNode.setVoiceProcessingEnabled(true)
            inputNode.isVoiceProcessingInputMuted = isMuted
            try inputNode.__installTap(
                onBus: 0,
                bufferSize: OpusCodec.frameSamples,
                format: nil,
                error: (),
                block: { [captureEncoder] buffer, _ in
                    captureEncoder.process(buffer)
                }
            )
            hasVoiceProcessingTap = true
            playbackEngine.mainMixerNode.outputVolume = isDeafened
                ? 0
                : min(max(outputVolume, 0), 2)
            playbackEngine.prepare()
            try playbackEngine.start()
            voiceAudioLogger.info(
                "Voice capture started with Apple's voice-processing I/O path"
            )
        } catch {
            if hasVoiceProcessingTap {
                inputNode.removeTap(onBus: 0)
                hasVoiceProcessingTap = false
            }
            playbackEngine.stop()
            try? inputNode.setVoiceProcessingEnabled(false)
            if error is VoiceAudioEngineError {
                throw error
            }
            throw VoiceAudioEngineError.voiceProcessingUnavailable
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
        if isVoiceProcessingEnabled {
            tearDownVoiceProcessingCapture()
            tearDownPlaybackGraph()
            try startVoiceProcessingGraph()
            voiceAudioLogger.info(
                "Voice-processing capture and playback recovered after a hardware change"
            )
            return
        }
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
        captureEncoder.reset()
    }

    private func tearDownVoiceProcessingCapture() {
        guard hasVoiceProcessingTap || playbackEngine.inputNode.isVoiceProcessingEnabled else {
            return
        }
        playbackEngine.stop()
        if hasVoiceProcessingTap {
            playbackEngine.inputNode.removeTap(onBus: 0)
            hasVoiceProcessingTap = false
        }
        try? playbackEngine.inputNode.setVoiceProcessingEnabled(false)
        captureEncoder.reset()
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
        if isVoiceProcessingEnabled {
            try restartVoiceProcessingGraph(
                inputDeviceID: deviceID,
                outputDeviceID: outputDeviceID
            )
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
        if isVoiceProcessingEnabled {
            try restartVoiceProcessingGraph(
                inputDeviceID: inputDeviceID,
                outputDeviceID: deviceID
            )
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

    public func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        guard enabled != isVoiceProcessingEnabled else { return }
        guard isRunning else {
            isVoiceProcessingEnabled = enabled
            return
        }
        inputRouteGeneration &+= 1
        outputRouteGeneration &+= 1
        captureRecoveryTask?.cancel()
        captureRecoveryTask = nil
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        let previousValue = isVoiceProcessingEnabled
        tearDownCaptureGraph()
        tearDownVoiceProcessingCapture()
        tearDownPlaybackGraph()
        isVoiceProcessingEnabled = enabled
        do {
            if enabled {
                try startVoiceProcessingGraph(
                    allowsInputDefaultFallback: false,
                    allowsOutputDefaultFallback: false
                )
            } else {
                try startPlaybackGraph(allowsDefaultFallback: false)
                try startCaptureGraph()
            }
        } catch {
            let transitionError = error
            tearDownCaptureGraph()
            tearDownVoiceProcessingCapture()
            tearDownPlaybackGraph()
            isVoiceProcessingEnabled = previousValue
            do {
                if previousValue {
                    try startVoiceProcessingGraph()
                } else {
                    try startPlaybackGraph()
                    try startCaptureGraph()
                }
            } catch {
                isRunning = false
                voiceAudioLogger.error(
                    "The previous voice capture graph could not be restored"
                )
            }
            throw transitionError
        }
    }

    private func restartVoiceProcessingGraph(
        inputDeviceID: AudioDeviceID?,
        outputDeviceID: AudioDeviceID?
    ) throws {
        inputRouteGeneration &+= 1
        outputRouteGeneration &+= 1
        captureRecoveryTask?.cancel()
        captureRecoveryTask = nil
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        isChangingCaptureRoute = true
        isChangingPlaybackRoute = true
        defer {
            isChangingCaptureRoute = false
            isChangingPlaybackRoute = false
        }
        let previousInputDeviceID = self.inputDeviceID
        let previousOutputDeviceID = self.outputDeviceID
        tearDownVoiceProcessingCapture()
        tearDownPlaybackGraph()
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID
        do {
            try startVoiceProcessingGraph(
                allowsInputDefaultFallback: false,
                allowsOutputDefaultFallback: false
            )
        } catch {
            let selectionError = error
            tearDownVoiceProcessingCapture()
            tearDownPlaybackGraph()
            self.inputDeviceID = previousInputDeviceID
            self.outputDeviceID = previousOutputDeviceID
            do {
                try startVoiceProcessingGraph()
            } catch {
                isRunning = false
                voiceAudioLogger.error(
                    "The previous voice-processing routes could not be restored"
                )
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

    var levelHandler: (@Sendable (Float) -> Void)? {
        get { lock.withLock { _levelHandler } }
        set { lock.withLock { _levelHandler = newValue } }
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
    private var _levelHandler: (@Sendable (Float) -> Void)?
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

    func process(_ input: AVAudioPCMBuffer) {
        do { try configure(inputFormat: input.format) } catch { return }
        let result: (frames: [CapturedOpusFrame], level: Float) = lock.withLock {
            guard let converter else { return ([], 0) }
            let ratio = OpusCodec.sampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: OpusCodec.pcmFormat,
                frameCapacity: capacity
            ) else { return ([], 0) }
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
                  converted.frameLength > 0 else { return ([], 0) }
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(converted.frameLength)))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: Int(converted.frameLength)))

            var output: [CapturedOpusFrame] = []
            var maximumLevel: Float = 0
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
                    maximumLevel = max(maximumLevel, Self.normalizedLevel(rms: rms))
                    output.append(CapturedOpusFrame(
                        data: packet,
                        containsVoice: !_isMuted && rms > activityThreshold,
                        sampleOffset: encodedSampleOffset
                    ))
                }
            }
            compactBufferedSamples(frameCount: frameCount)
            return (output, maximumLevel)
        }
        let handler = handler
        for frame in result.frames {
            handler?(frame)
        }
        levelHandler?(result.level)
    }

    private static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 60) / 60, 0), 1)
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
    case voiceProcessingUnavailable
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
        case .voiceProcessingUnavailable:
            "Apple voice processing is unavailable for the selected audio routes."
        }
    }
}
