import AVFAudio
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import OSLog

private let voiceAudioLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "VoiceAudio")

public struct CapturedOpusFrame: Sendable {
    public var data: Data
    public var containsVoice: Bool

    public init(data: Data, containsVoice: Bool) {
        self.data = data
        self.containsVoice = containsVoice
    }
}

@MainActor
public final class VoiceAudioEngine {
    public private(set) var isRunning = false
    public private(set) var inputDeviceID: AudioDeviceID?
    public private(set) var outputDeviceID: AudioDeviceID?
    public var inputVolume: Float = 1 {
        didSet { captureBridge.inputVolume = min(max(inputVolume, 0), 2) }
    }

    public var outputVolume: Float = 1 {
        didSet { applyOutputVolume() }
    }

    public var isMuted = false {
        didSet { captureBridge.isMuted = isMuted }
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
    private let captureBridge: AudioCaptureBridge
    private var players: [String: AVAudioPlayerNode] = [:]
    private var participantVolumes: [String: Float] = [:]

    public init(bitRate: Int = 64000) throws {
        let codec = try OpusCodec(bitRate: bitRate)
        self.codec = codec
        captureBridge = AudioCaptureBridge(codec: codec)
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
        captureBridge.handler = onCapturedFrame
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
        tearDownCaptureGraph()
        tearDownPlaybackGraph()
        captureBridge.handler = nil
        isRunning = false
    }

    private func startCaptureGraph() throws {
        var device = MediaDeviceCatalog.audioCaptureDevice(deviceID: inputDeviceID)
        if device == nil, inputDeviceID != nil {
            voiceAudioLogger.warning("Selected input device failed; falling back to the system default")
            inputDeviceID = nil
            device = MediaDeviceCatalog.audioCaptureDevice(deviceID: nil)
        }
        guard let device else { throw VoiceAudioEngineError.inputUnavailable }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw VoiceAudioEngineError.inputUnavailable }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        for existing in captureSession.inputs {
            captureSession.removeInput(existing)
        }
        for existing in captureSession.outputs {
            captureSession.removeOutput(existing)
        }
        guard captureSession.canAddInput(input) else { throw VoiceAudioEngineError.inputUnavailable }
        captureSession.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(captureBridge, queue: captureQueue)
        guard captureSession.canAddOutput(output) else { throw VoiceAudioEngineError.inputUnavailable }
        captureSession.addOutput(output)
        captureOutput = output
        voiceAudioLogger.info("Voice capture configured without opening a shared output route")
        captureQueue.async { [captureSession] in
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    private func startPlaybackGraph() throws {
        if let outputDeviceID {
            do {
                try MediaDeviceCatalog.selectOutput(outputDeviceID, on: playbackEngine)
            } catch {
                voiceAudioLogger.warning("Selected output device failed; falling back to the system default")
                self.outputDeviceID = nil
            }
        }
        playbackEngine.mainMixerNode.outputVolume = isDeafened ? 0 : min(max(outputVolume, 0), 2)
        playbackEngine.prepare()
        try playbackEngine.start()
        let format = playbackEngine.mainMixerNode.outputFormat(forBus: 0)
        voiceAudioLogger.info(
            "Voice playback graph started; selectedDevice=\(self.outputDeviceID ?? 0), sampleRate=\(format.sampleRate), channels=\(format.channelCount)"
        )
    }

    private func tearDownCaptureGraph() {
        captureOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureOutput = nil
        captureQueue.sync { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
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

    private func tearDownPlaybackGraph() {
        for player in players.values {
            player.stop()
            playbackEngine.disconnectNodeOutput(player)
            playbackEngine.detach(player)
        }
        playbackEngine.stop()
        players.removeAll()
    }

    public func selectInputDevice(_ deviceID: AudioDeviceID?) throws {
        inputDeviceID = deviceID
        guard isRunning else { return }
        tearDownCaptureGraph()
        do {
            try startCaptureGraph()
        } catch {
            isRunning = false
            throw error
        }
    }

    public func selectOutputDevice(_ deviceID: AudioDeviceID?) throws {
        outputDeviceID = deviceID
        guard isRunning else { return }
        tearDownPlaybackGraph()
        do {
            try startPlaybackGraph()
        } catch {
            isRunning = false
            throw error
        }
    }

    public func setParticipantVolume(_ volume: Float, userID: String) {
        let volume = min(max(volume, 0), 2)
        participantVolumes[userID] = volume
        players[userID]?.volume = volume
    }

    public func play(opusPacket: Data, from userID: String) throws {
        guard !isDeafened else { return }
        let buffer = try codec.decode(opusPacket)
        let player = try player(for: userID)
        player.scheduleBuffer(buffer)
        if !player.isPlaying {
            try player.playAudio()
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

private final class AudioCaptureBridge: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
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
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var left: [Float] = []
    private var right: [Float] = []
    private var bufferedSampleOffset = 0
    private var _handler: (@Sendable (CapturedOpusFrame) -> Void)?
    private var _inputVolume: Float = 1
    private var _isMuted = false

    init(codec: OpusCodec) {
        self.codec = codec
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
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
                    let rms = sqrt(energy / Float(frameCount * 2))
                    output.append(CapturedOpusFrame(data: packet, containsVoice: !_isMuted && rms > 0.003))
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
    case converterUnavailable
}
