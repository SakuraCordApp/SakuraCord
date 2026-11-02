@preconcurrency import AVFoundation
import Foundation

/// Plays one Ogg Opus voice message with seeking and pitch-preserving speed.
///
/// AVAudioPlayer cannot prepare Ogg Opus, while AVAudioFile decodes it
/// natively, so playback schedules file segments on an engine instead.
///
/// Starting must feel immediate. The time-pitch unit adds about 85 ms of
/// latency even when bypassed, so it joins the graph only at other speeds,
/// and pausing keeps the engine's output running for a while so resuming
/// doesn't wait for the output device, which Bluetooth headsets make slow.
@MainActor
public final class VoiceMessagePlayer {
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying = false {
        didSet {
            positionTask?.cancel()
            positionTask = nil
            if isPlaying { trackRenderedPosition() }
        }
    }
    /// Called once playback reaches the end of the file.
    public var onFinish: (@MainActor () -> Void)?
    /// Called when the output device stopped playback and it couldn't resume.
    public var onInterruption: (@MainActor () -> Void)?

    public var rate: Float = 1 {
        didSet {
            timePitch.rate = rate
            routeThroughTimePitch(rate != 1)
        }
    }

    /// Output gain, 0–1.
    public var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = newValue }
    }

    /// How long a paused player keeps the output device running.
    public nonisolated static let idleOutputDuration: Duration = .seconds(15)

    /// Recent output loudness, 0–1, for presentation.
    public var outputLevel: Float { meter.level }

    private let meter = VoiceMessageOutputMeter()
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var file: AVAudioFile?
    private var usesTimePitch = false
    private var idleTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var configurationObserver: (any NSObjectProtocol)?
    /// The last position read from the render clock, for resuming after the
    /// output device stops the engine.
    private var lastRenderedTime: TimeInterval = 0
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var pausedTime: TimeInterval = 0
    /// Distinguishes the current segment's completion from one stopped by a seek.
    private var scheduleGeneration = 0

    public init(fileURL: URL) throws {
        // Time-pitch units reject AVAudioFile's default interleaved mono layout.
        let file = try AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        self.file = file
        duration = Double(file.length) / file.processingFormat.sampleRate
        engine.attach(playerNode)
        engine.attach(timePitch)
        try engine.connectNode(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
        try engine.connectNode(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: nil, block: Self.meteringTap(meter))
        engine.prepare()
        // A headset leaving its microphone mode after a recording changes
        // the output sample rate, which stops the engine mid-playback.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil,
            using: Self.configurationChange { [weak self] in self?.outputConfigurationChanged() }
        )
    }

    isolated deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        idleTask?.cancel()
        positionTask?.cancel()
        engine.mainMixerNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
    }

    /// Whether audio has begun reaching the output since `play`.
    public var isRendering: Bool {
        guard isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return false }
        return playerTime.sampleTime > 0
    }

    public var currentTime: TimeInterval {
        guard isPlaying,
              let file,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return pausedTime }
        let frame = segmentStartFrame + max(0, playerTime.sampleTime)
        let time = min(duration, Double(frame) / file.processingFormat.sampleRate)
        lastRenderedTime = time
        return time
    }

    public func play() throws {
        guard !isPlaying else { return }
        idleTask?.cancel()
        idleTask = nil
        if pausedTime >= duration { pausedTime = 0 }
        if !engine.isRunning { try engine.start() }
        schedule(from: pausedTime)
        try playerNode.playAudio(at: nil)
        isPlaying = true
    }

    public func pause() {
        guard isPlaying else { return }
        pausedTime = currentTime
        isPlaying = false
        meter.reset()
        scheduleGeneration += 1
        playerNode.stop()
        pauseOutputWhenIdle()
    }

    public func seek(to time: TimeInterval) {
        let target = min(max(0, time), duration)
        guard isPlaying else {
            pausedTime = target
            return
        }
        scheduleGeneration += 1
        playerNode.stop()
        schedule(from: target)
        do {
            try playerNode.playAudio(at: nil)
        } catch {
            interrupt(at: pausedTime)
        }
    }

    public func stop() {
        pause()
        idleTask?.cancel()
        idleTask = nil
        pausedTime = 0
        engine.stop()
    }

    /// Moves the player between the direct path and the time-pitch unit,
    /// carrying on from the same position.
    private func routeThroughTimePitch(_ enabled: Bool) {
        guard enabled != usesTimePitch, let file else { return }
        let resumeAt = isPlaying ? currentTime : nil
        if resumeAt != nil {
            scheduleGeneration += 1
            playerNode.stop()
        }
        engine.disconnectNodeOutput(playerNode)
        do {
            try engine.connectNode(playerNode, to: enabled ? timePitch : engine.mainMixerNode, format: file.processingFormat)
            usesTimePitch = enabled
        } catch {
            // The direct path always connects; it plays at normal speed.
            try? engine.connectNode(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
            usesTimePitch = false
        }
        guard let resumeAt else { return }
        schedule(from: resumeAt)
        do {
            try playerNode.playAudio(at: nil)
        } catch {
            interrupt(at: pausedTime)
        }
    }

    /// The engine has stopped itself; the output node converts to the new
    /// rate, so restarting it and rescheduling is enough.
    private func outputConfigurationChanged() {
        // The notification can also arrive while the engine keeps running;
        // restarting then would only cause a gap.
        guard isPlaying, !engine.isRunning else { return }
        let resumeAt = lastRenderedTime
        scheduleGeneration += 1
        playerNode.stop()
        do {
            try engine.start()
            schedule(from: resumeAt)
            try playerNode.playAudio(at: nil)
        } catch {
            interrupt(at: resumeAt)
        }
    }

    private func interrupt(at time: TimeInterval) {
        isPlaying = false
        pausedTime = time
        meter.reset()
        pauseOutputWhenIdle()
        onInterruption?()
    }

    private func pauseOutputWhenIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleOutputDuration)
            guard !Task.isCancelled, let self, !self.isPlaying else { return }
            self.engine.pause()
        }
    }

    /// Device-change recovery must advance even when no visible waveform
    /// is querying the render clock. Only the playing engine is sampled.
    private func trackRenderedPosition() {
        positionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, self.isPlaying else { return }
                if self.engine.isRunning { _ = self.currentTime }
            }
        }
    }

    private func schedule(from time: TimeInterval) {
        guard let file else { return }
        let sampleRate = file.processingFormat.sampleRate
        let start = min(AVAudioFramePosition(time * sampleRate), max(0, file.length - 1))
        segmentStartFrame = start
        pausedTime = Double(start) / sampleRate
        lastRenderedTime = pausedTime
        scheduleGeneration += 1
        let generation = scheduleGeneration
        playerNode.scheduleSegment(
            file,
            startingFrame: start,
            frameCount: AVAudioFrameCount(file.length - start),
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: Self.segmentCompletion { [weak self] in
                self?.segmentFinished(generation: generation)
            }
        )
    }

    private func segmentFinished(generation: Int) {
        guard scheduleGeneration == generation, isPlaying else { return }
        isPlaying = false
        pausedTime = duration
        playerNode.stop()
        pauseOutputWhenIdle()
        onFinish?()
    }

    // AVFAudio calls these on its own queues. Closures formed inside this
    // main-actor type would inherit its isolation and trap there.
    private nonisolated static func meteringTap(_ meter: VoiceMessageOutputMeter) -> AVAudioNodeTapBlock {
        { buffer, _ in meter.measure(buffer) }
    }

    private nonisolated static func configurationChange(
        _ changed: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable (Notification) -> Void {
        { _ in Task { @MainActor in changed() } }
    }

    private nonisolated static func segmentCompletion(
        _ finished: @escaping @MainActor @Sendable () -> Void
    ) -> AVAudioPlayerNodeCompletionHandler {
        { _ in Task { @MainActor in finished() } }
    }
}

private final class VoiceMessageOutputMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    var level: Float { lock.withLock { value } }

    func reset() { lock.withLock { value = 0 } }

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var energy: Float = 0
        for index in 0 ..< Int(buffer.frameLength) { energy += samples[index] * samples[index] }
        let rms = (energy / Float(buffer.frameLength)).squareRoot()
        let level = rms > 0 ? min(max((20 * log10(rms) + 50) / 50, 0), 1) : 0
        // Rise quickly and fall gently, like a VU meter.
        lock.withLock { value = level > value ? level : value * 0.6 + level * 0.4 }
    }
}
