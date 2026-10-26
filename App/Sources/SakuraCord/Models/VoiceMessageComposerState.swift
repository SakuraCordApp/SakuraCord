import CoreAudio
import Foundation
import MediaPipeline
import Observation
import SakuraCordModels

/// One composer's voice-message recording, from the first press of the
/// microphone button until the recording is sent or discarded.
@MainActor
@Observable
final class VoiceMessageComposerState {
    enum Phase: Equatable {
        case idle
        /// Waiting for microphone permission or the capture device.
        case starting
        case recording
        /// Encoding the captured audio after the user stopped.
        case finishing
        case recorded(VoiceMessageRecording)

        var isActive: Bool { self != .idle }

        var recording: VoiceMessageRecording? {
            if case let .recorded(recording) = self { return recording }
            return nil
        }
    }

    /// Shorter presses are treated as accidental and discarded.
    static let minimumDuration: TimeInterval = 0.5
    /// Live bars retained for the scrolling recording waveform.
    static let maximumLiveBars = 400

    let destination: MessageComposerDestination
    private(set) var phase: Phase = .idle
    /// Completed live bars as RMS levels, oldest first.
    private(set) var liveBars: [Float] = []
    /// The bar still being filled.
    private(set) var currentLevel: Float = 0
    /// The loudest bar so far, including those trimmed from `liveBars`.
    private(set) var peakLevel: Float = 0
    /// The gain the recording will be levelled by, as measured so far.
    private(set) var loudnessGain: Float = 1
    private(set) var elapsed: TimeInterval = 0
    /// Bars completed since recording began, including those trimmed from `liveBars`.
    private(set) var totalBars = 0
    /// When `elapsed` was sampled, so presentation can extrapolate between samples.
    private(set) var elapsedSampledAt = Date.now
    private(set) var errorMessage: String?
    /// False while a headset is still leaving its microphone mode, which
    /// would cut into a preview.
    private(set) var canPreview = true

    @ObservationIgnored private let recorder = VoiceMessageRecorder()
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var stopRequestedWhileStarting = false
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored private var timeoutPreservedChannelID: ChannelID?

    init(destination: MessageComposerDestination) {
        self.destination = destination
    }

    var playbackID: VoiceMessagePlaybackID { .composer(destination) }

    func start(inputDeviceID: AudioDeviceID?) {
        guard phase == .idle else { return }
        phase = .starting
        errorMessage = nil
        stopRequestedWhileStarting = false
        liveBars = []
        currentLevel = 0
        peakLevel = 0
        loudnessGain = 1
        elapsed = 0
        totalBars = 0
        elapsedSampledAt = .now
        startGeneration += 1
        let generation = startGeneration
        Task {
            guard await VoiceMessageRecorder.requestMicrophonePermission() else {
                guard generation == startGeneration, phase == .starting else { return }
                phase = .idle
                errorMessage = VoiceMessageRecorderError.microphonePermissionDenied.localizedDescription
                return
            }
            guard generation == startGeneration, phase == .starting else { return }
            do {
                try recorder.start(inputDeviceID: inputDeviceID)
            } catch {
                phase = .idle
                errorMessage = error.localizedDescription
                return
            }
            phase = .recording
            startMetering()
            if stopRequestedWhileStarting { stop() }
        }
    }

    /// Stops capture and prepares the recording for preview.
    func stop() {
        switch phase {
        case .starting:
            stopRequestedWhileStarting = true
        case .recording:
            meterTask?.cancel()
            meterTask = nil
            phase = .finishing
            let generation = startGeneration
            Task {
                do {
                    let recording = try await recorder.stop()
                    guard generation == startGeneration, phase == .finishing else {
                        recording.discard()
                        return
                    }
                    if recording.duration < Self.minimumDuration {
                        recording.discard()
                        reset()
                    } else {
                        phase = .recorded(recording)
                        canPreview = false
                        await recorder.waitForOutputToSettle()
                        if generation == startGeneration { canPreview = true }
                    }
                } catch {
                    guard generation == startGeneration else { return }
                    reset()
                    errorMessage = error.localizedDescription
                }
            }
        default:
            break
        }
    }

    /// Discards any recording in progress or awaiting send.
    func discard(playback: VoiceMessagePlaybackStore?) {
        playback?.stop(playbackID)
        recorder.cancel()
        phase.recording?.discard()
        reset()
    }

    /// A timeout hides the composer without abandoning its conversation.
    /// Finish captured audio and retain it until that same composer returns.
    func preserveForGuildTimeout(in channelID: ChannelID, playback: VoiceMessagePlaybackStore) {
        guard phase.isActive else { return }
        if phase == .starting {
            // No audio exists yet; do not start capture after permission returns.
            discard(playback: playback)
            return
        }
        if let recording = phase.recording,
           playback.phase(of: playbackID) == .playing || playback.phase(of: playbackID) == .loading {
            playback.toggle(playbackID, source: .local(recording.fileURL), duration: recording.duration)
        }
        timeoutPreservedChannelID = channelID
        stop()
    }

    /// Consume the one-time exception to the composer's appearance cleanup.
    func restoreAfterGuildTimeout(in channelID: ChannelID?) -> Bool {
        guard let channelID, timeoutPreservedChannelID == channelID else { return false }
        timeoutPreservedChannelID = nil
        return true
    }

    /// Hands the recording to the sender; the file now belongs to the outbox.
    func takeRecording(playback: VoiceMessagePlaybackStore?) -> VoiceMessageRecording? {
        guard let recording = phase.recording else { return nil }
        playback?.stop(playbackID)
        reset()
        return recording
    }

    func clearError() { errorMessage = nil }

    private func reset() {
        meterTask?.cancel()
        meterTask = nil
        startGeneration += 1
        timeoutPreservedChannelID = nil
        phase = .idle
        canPreview = true
        liveBars = []
        currentLevel = 0
        peakLevel = 0
        loudnessGain = 1
        elapsed = 0
        totalBars = 0
    }

    /// Up to `count` of the most recent bars, the last still filling, at the
    /// scale the finished waveform will have.
    func displayedLiveLevels(count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let recent = Array(liveBars.suffix(count - 1)) + [currentLevel]
        return VoiceMessageWaveform.normalized(recent.map { $0 * loudnessGain }, peak: peakLevel * loudnessGain)
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .recording else { return }
                let levels = self.recorder.drainLevels()
                self.elapsed = self.recorder.elapsed
                self.elapsedSampledAt = .now
                if !levels.completed.isEmpty {
                    self.liveBars.append(contentsOf: levels.completed)
                    self.totalBars += levels.completed.count
                    if self.liveBars.count > Self.maximumLiveBars {
                        self.liveBars.removeFirst(self.liveBars.count - Self.maximumLiveBars)
                    }
                }
                self.currentLevel = levels.current
                self.peakLevel = max(self.peakLevel, levels.completed.max() ?? 0, levels.current)
                self.loudnessGain = self.recorder.loudnessGain
                if self.recorder.hasReachedMaximumDuration || self.recorder.hasFailed {
                    self.stop()
                    return
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }
}
