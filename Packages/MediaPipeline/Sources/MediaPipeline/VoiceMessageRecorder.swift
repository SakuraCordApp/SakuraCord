@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import OSLog
import SakuraCordModels

private let voiceMessageLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "VoiceMessage")

/// A finished voice message ready to upload as Discord's `voice-message.ogg`.
public struct VoiceMessageRecording: Equatable, Sendable {
    public let fileURL: URL
    public let duration: TimeInterval
    /// Discord's 0–255 waveform bins.
    public let waveform: [UInt8]

    public init(fileURL: URL, duration: TimeInterval, waveform: [UInt8]) {
        self.fileURL = fileURL
        self.duration = duration
        self.waveform = waveform
    }

    public var metadata: VoiceMessageMetadata {
        VoiceMessageMetadata(durationSeconds: duration, waveform: VoiceMessageWaveform.encode(waveform))
    }

    /// Removes the recording's private directory.
    public func discard() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

public enum VoiceMessageRecorderError: Error, Equatable {
    case microphonePermissionDenied
    case inputUnavailable
    case encoderUnavailable
    case encodingFailed
    case notRecording
}

extension VoiceMessageRecorderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "SakuraCord needs microphone access to record voice messages. You can allow it in System Settings → Privacy & Security → Microphone."
        case .inputUnavailable:
            "The selected microphone is not available."
        case .encoderUnavailable:
            "Voice messages can't be encoded on this Mac."
        case .encodingFailed:
            "The voice message couldn't be encoded. Please record it again."
        case .notRecording:
            "No voice message is being recorded."
        }
    }
}

/// Records the microphone into an Ogg Opus voice message.
///
/// Capture uses AVCaptureSession for the same reason as calls: opening a
/// Bluetooth headset through AVAudioEngine's input node can switch the
/// headset's transport for the entire Mac.
@MainActor
public final class VoiceMessageRecorder {
    /// Discord's documented voice-message limit.
    public nonisolated static let maximumDuration: TimeInterval = 20 * 60
    /// Seconds of audio represented by one bar of the live waveform.
    public nonisolated static let liveBarInterval: TimeInterval = 0.1

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.sakuracord.voice-message.capture", qos: .userInitiated)
    private var processor: VoiceMessageCaptureProcessor?
    private var captureStartedAt: ContinuousClock.Instant?
    /// The recording's private directory, holding the capture spool and,
    /// once stopped, the encoded message.
    private var directory: URL?
    /// The output device and its rate before capture, when they may change.
    private var outputBeforeCapture: (deviceID: AudioDeviceID, sampleRate: Double)?

    public init() {}

    public var isRecording: Bool { processor != nil }

    public func start(inputDeviceID: AudioDeviceID? = nil) throws {
        cancel()
        let device = MediaDeviceCatalog.audioCaptureDevice(deviceID: inputDeviceID)
            ?? MediaDeviceCatalog.audioCaptureDevice(deviceID: nil)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            throw VoiceMessageRecorderError.inputUnavailable
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SakuraCordVoiceMessages", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        if let deviceID = MediaDeviceCatalog.defaultOutputDeviceID(),
           let sampleRate = MediaDeviceCatalog.defaultOutputSampleRate() {
            outputBeforeCapture = (deviceID, sampleRate)
        } else {
            outputBeforeCapture = nil
        }
        let processor: VoiceMessageCaptureProcessor
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            processor = try VoiceMessageCaptureProcessor(spoolURL: directory.appending(path: "capture.pcm"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error as? VoiceMessageRecorderError ?? .encodingFailed
        }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(processor, queue: queue)
        do {
            try queue.sync { [session] in
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.inputs.forEach(session.removeInput)
                session.outputs.forEach(session.removeOutput)
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    throw VoiceMessageRecorderError.inputUnavailable
                }
                session.addInput(input)
                session.addOutput(output)
            }
        } catch {
            processor.discard()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.processor = processor
        self.directory = directory
        captureStartedAt = .now
        queue.async { [session] in session.startRunning() }
        voiceMessageLogger.info("Voice message recording started")
    }

    /// Captured duration so far.
    public var elapsed: TimeInterval { processor?.elapsed ?? 0 }

    public var hasReachedMaximumDuration: Bool {
        if elapsed >= Self.maximumDuration { return true }
        // Muted or stalled devices may never advance the captured sample count.
        guard let captureStartedAt else { return false }
        return ContinuousClock.now - captureStartedAt >= .seconds(Self.maximumDuration)
    }

    /// Capture can't continue once a frame failed to encode; stopping reports the error.
    public var hasFailed: Bool { processor?.hasFailed ?? false }

    /// The gain levelling would apply if recording stopped now, so live
    /// bars can be shown at the scale the finished waveform will have.
    public var loudnessGain: Float { processor?.loudnessGain ?? 1 }

    /// Live waveform bars completed since the previous call, each the RMS
    /// level over `liveBarInterval`, plus the level of the bar in progress.
    public func drainLevels() -> (completed: [Float], current: Float) {
        processor?.drainLevels() ?? ([], 0)
    }

    public func stop() async throws -> VoiceMessageRecording {
        guard let processor, let directory else { throw VoiceMessageRecorderError.notRecording }
        self.processor = nil
        self.directory = nil
        captureStartedAt = nil
        await stopSession()
        let fileURL = directory.appending(path: VoiceMessageMetadata.filename)
        let recording = try await Task.detached(priority: .userInitiated) {
            do {
                let result = try processor.finish()
                try result.data.write(to: fileURL, options: .atomic)
                return VoiceMessageRecording(fileURL: fileURL, duration: result.duration, waveform: result.waveform)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
        voiceMessageLogger.info("Voice message recording finished duration=\(recording.duration, format: .fixed(precision: 2))")
        return recording
    }

    public func cancel() {
        guard let processor else { return }
        let directory = directory
        self.processor = nil
        self.directory = nil
        captureStartedAt = nil
        processor.discard()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        // Enqueue teardown before returning so a new start cannot be followed
        // by this recording's delayed stop on the shared capture session.
        enqueueSessionStop()
    }

    /// A Bluetooth headset lowers its output rate while its microphone is
    /// open and restores it a moment after capture stops. That switch stops
    /// any playback in progress, so previews wait for this after `stop`.
    public func waitForOutputToSettle() async {
        guard let before = outputBeforeCapture else { return }
        outputBeforeCapture = nil
        let start = ContinuousClock.now
        while ContinuousClock.now < start + .seconds(3),
              MediaDeviceCatalog.defaultOutputDeviceID() == before.deviceID,
              let sampleRate = MediaDeviceCatalog.defaultOutputSampleRate(),
              sampleRate != before.sampleRate {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let waited = ContinuousClock.now - start
        if waited > .milliseconds(50) {
            voiceMessageLogger.info("Voice message output settled after \(waited, privacy: .public)")
        }
    }

    private func stopSession() async {
        await withCheckedContinuation { continuation in
            enqueueSessionStop { continuation.resume() }
        }
    }

    private func enqueueSessionStop(completion: @escaping @Sendable () -> Void = {}) {
        queue.async { [session] in
            session.stopRunning()
            session.outputs.forEach { ($0 as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil) }
            completion()
        }
    }
}

/// Brings speech to a consistent playback level. Capture applies no gain,
/// so microphones deliver speech anywhere from about −40 to −15 dBFS; a
/// voice message is levelled as a whole once recording stops.
enum VoiceMessageLoudness {
    /// The speech level the gain aims for, as linear RMS (−16 dBFS, the
    /// usual loudness target for spoken audio).
    static let targetRMS: Float = 0.158
    /// At most +18 dB, so a silent room isn't raised into loud hiss.
    static let maximumGain: Float = 8
    static let minimumGain: Float = 0.5
    /// Windows quieter than −60 dBFS are silence.
    static let silenceMeanSquare: Float = 1e-6
    /// Speech is the windows within 10 dB of the average non-silent level,
    /// so pauses between words don't lower the measurement.
    static let relativeGate: Float = 0.1
    /// Samples above this are compressed smoothly towards full scale.
    static let limiterThreshold: Float = 0.8

    /// The gain for a recording measured as mean squares of short windows.
    static func gain(meanSquares: [Float]) -> Float {
        let audible = meanSquares.filter { $0 > silenceMeanSquare }
        guard !audible.isEmpty else { return 1 }
        let gate = audible.reduce(0, +) / Float(audible.count) * relativeGate
        let speech = audible.filter { $0 >= gate }
        let rms = (speech.reduce(0, +) / Float(speech.count)).squareRoot()
        return min(max(targetRMS / rms, minimumGain), maximumGain)
    }

    /// A soft limiter, so raised peaks round off instead of clipping.
    static func limited(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > limiterThreshold else { return sample }
        let knee = 1 - limiterThreshold
        let limited = limiterThreshold + knee * tanh((magnitude - limiterThreshold) / knee)
        return sample < 0 ? -limited : limited
    }
}

/// Measures and spools captured audio while recording, then levels and
/// encodes it when recording stops.
final class VoiceMessageCaptureProcessor: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    static let preSkip: UInt16 = 312
    static let samplesPerBar = Int(VoiceMessageRecorder.liveBarInterval * OpusCodec.sampleRate)
    /// About one second of audio per spool write.
    static let spoolChunkSamples = 48_000
    /// A starting microphone delivers digital silence until it is ready,
    /// while even a quiet room measures far above −90 dBFS.
    static let warmUpSilence: Float = 0.000_031_6

    private let lock = NSLock()
    private let codec: OpusCodec
    private let spoolURL: URL
    private let spool: FileHandle
    private var spoolBuffer: [Int16] = []
    private var converter: AVAudioConverter?
    private var capturedSamples = 0
    /// Every completed bar's mean square, for levelling.
    private var barMeanSquares: [Float] = []
    /// Completed bars' RMS levels not yet drained by presentation.
    private var completedBars: [Float] = []
    private var barEnergy: Float = 0
    private var barSamples = 0
    private var isFinished = false
    /// Whether the microphone has delivered sound yet.
    private var hasStarted = false
    /// A lost chunk would leave a gap the waveform and duration don't show.
    private var captureFailed = false

    /// - Parameter spoolURL: Where captured audio waits, as 16-bit PCM, until it is encoded.
    init(spoolURL: URL, bitRate: Int = 32_000) throws {
        do {
            codec = try OpusCodec(bitRate: bitRate, channels: 1)
        } catch {
            throw VoiceMessageRecorderError.encoderUnavailable
        }
        guard FileManager.default.createFile(atPath: spoolURL.path, contents: nil),
              let spool = try? FileHandle(forWritingTo: spoolURL)
        else { throw VoiceMessageRecorderError.encodingFailed }
        self.spoolURL = spoolURL
        self.spool = spool
        super.init()
    }

    var elapsed: TimeInterval {
        lock.withLock { Double(capturedSamples) / OpusCodec.sampleRate }
    }

    var hasFailed: Bool {
        lock.withLock { captureFailed }
    }

    /// The gain the recording would be levelled by if it stopped now.
    var loudnessGain: Float {
        lock.withLock { VoiceMessageLoudness.gain(meanSquares: barMeanSquares) }
    }

    /// Completed bars and the bar in progress, as linear RMS levels.
    func drainLevels() -> (completed: [Float], current: Float) {
        lock.withLock {
            defer { completedBars.removeAll(keepingCapacity: true) }
            let current = barSamples > 0 ? (barEnergy / Float(barSamples)).squareRoot() : 0
            return (completedBars, current)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = AVAudioPCMBuffer(copying: sampleBuffer) else { return }
        process(buffer)
    }

    func process(_ input: AVAudioPCMBuffer) {
        lock.withLock {
            let remaining = Int(VoiceMessageRecorder.maximumDuration * OpusCodec.sampleRate) - capturedSamples
            guard !isFinished, !captureFailed, remaining > 0,
                  let converted = convert(input),
                  let samples = converted.floatChannelData?[0]
            else { return }
            var start = 0
            if !hasStarted {
                // Recording begins with the first sound, not the warm-up.
                let frames = UnsafeBufferPointer(start: samples, count: Int(converted.frameLength))
                guard let first = frames.firstIndex(where: { abs($0) > Self.warmUpSilence }) else { return }
                hasStarted = true
                start = first
            }
            // The buffer that crosses the limit is trimmed to it.
            let buffer = UnsafeBufferPointer(
                start: samples + start,
                count: min(Int(converted.frameLength) - start, remaining)
            )
            capturedSamples += buffer.count
            updateLevels(buffer)
            spoolBuffer.append(contentsOf: buffer.lazy.map { Int16(min(max($0, -1), 1) * Float(Int16.max)) })
            if spoolBuffer.count >= Self.spoolChunkSamples { flushSpool() }
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: codec.pcmFormat)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * OpusCodec.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// Bars are RMS over `liveBarInterval`, the same measure as the finished
    /// waveform's ten bins per second.
    private func updateLevels(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            barEnergy += sample * sample
            barSamples += 1
            if barSamples == Self.samplesPerBar {
                let meanSquare = barEnergy / Float(Self.samplesPerBar)
                barMeanSquares.append(meanSquare)
                completedBars.append(meanSquare.squareRoot())
                barEnergy = 0
                barSamples = 0
            }
        }
    }

    private func flushSpool() {
        guard !spoolBuffer.isEmpty else { return }
        do {
            try spool.write(contentsOf: spoolBuffer.withUnsafeBytes { Data($0) })
        } catch {
            captureFailed = true
            voiceMessageLogger.error("Voice message capture couldn't be spooled")
        }
        spoolBuffer.removeAll(keepingCapacity: true)
    }

    struct Result {
        let data: Data
        let duration: TimeInterval
        let waveform: [UInt8]
    }

    /// Stops accepting audio and removes the spool.
    func discard() {
        lock.withLock {
            isFinished = true
            spoolBuffer.removeAll()
            try? spool.close()
        }
        try? FileManager.default.removeItem(at: spoolURL)
    }

    /// Levels the spooled audio, then encodes it and its waveform.
    func finish() throws -> Result {
        let (sampleCount, gain) = try lock.withLock {
            isFinished = true
            flushSpool()
            try? spool.close()
            guard !captureFailed else { throw VoiceMessageRecorderError.encodingFailed }
            var meanSquares = barMeanSquares
            if barSamples > 0 { meanSquares.append(barEnergy / Float(barSamples)) }
            return (capturedSamples, VoiceMessageLoudness.gain(meanSquares: meanSquares))
        }
        defer { try? FileManager.default.removeItem(at: spoolURL) }
        let reader = try FileHandle(forReadingFrom: spoolURL)
        defer { try? reader.close() }
        var writer = OggOpusWriter(channelCount: 1, preSkip: Self.preSkip)
        var accumulator = VoiceMessageWaveform.Accumulator()
        var pending: [Float] = []
        let frame = Int(OpusCodec.frameSamples)
        let scale = gain / Float(Int16.max)
        while let chunk = try reader.read(upToCount: Self.spoolChunkSamples * MemoryLayout<Int16>.size), !chunk.isEmpty {
            let levelled = chunk.withUnsafeBytes { raw in
                (0 ..< raw.count / MemoryLayout<Int16>.size).map { index in
                    VoiceMessageLoudness.limited(
                        Float(raw.loadUnaligned(fromByteOffset: index * MemoryLayout<Int16>.size, as: Int16.self)) * scale
                    )
                }
            }
            levelled.withUnsafeBufferPointer { accumulator.append($0) }
            pending.append(contentsOf: levelled)
            var offset = 0
            while pending.count - offset >= frame {
                try encode(pending[offset ..< offset + frame], into: &writer)
                offset += frame
            }
            pending.removeFirst(offset)
        }
        // Flush the encoder's delay using the partial frame's padding first.
        // An unnecessary extra packet can flush a page beyond the EOS granule.
        let padding = pending.isEmpty ? 0 : frame - pending.count
        if !pending.isEmpty { try encode(pending[...], into: &writer) }
        if padding < Int(Self.preSkip) { try encode([], into: &writer) }
        return Result(
            data: writer.finish(sampleCount: sampleCount),
            duration: Double(sampleCount) / OpusCodec.sampleRate,
            waveform: VoiceMessageWaveform.bins(from: accumulator)
        )
    }

    private func encode(_ samples: ArraySlice<Float>, into writer: inout OggOpusWriter) throws {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: OpusCodec.frameSamples),
              let channel = pcm.floatChannelData?[0]
        else { throw VoiceMessageRecorderError.encodingFailed }
        pcm.frameLength = OpusCodec.frameSamples
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        for index in samples.count ..< Int(OpusCodec.frameSamples) { channel[index] = 0 }
        do {
            writer.append(packet: try codec.encode(pcm), samples: Int(OpusCodec.frameSamples))
        } catch {
            voiceMessageLogger.error("Voice message frame encoding failed")
            throw VoiceMessageRecorderError.encodingFailed
        }
    }
}
