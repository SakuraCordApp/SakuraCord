import CoreAudio
import MediaPipeline
import Observation

@MainActor
protocol VoiceMicrophoneTesting: AnyObject, Sendable {
    var inputVolume: Float { get set }
    var inputLevelHandler: (@Sendable (Float) -> Void)? { get set }

    func start(
        inputDeviceID: AudioDeviceID?,
        outputDeviceID: AudioDeviceID?,
        voiceProcessingEnabled: Bool,
        onCapturedFrame: @escaping @Sendable (CapturedOpusFrame) -> Void
    ) throws
    func stop()
}

extension VoiceAudioEngine: VoiceMicrophoneTesting {}

@MainActor
@Observable
final class VoiceVideoTestController {
    private(set) var microphoneLevel: Float = 0
    private(set) var isMicrophoneTestRunning = false
    private(set) var isSpeakerTestRunning = false
    private(set) var isCameraPreviewRunning = false
    private(set) var cameraFrame: VoiceVideoFrame?
    private(set) var permissions = VoiceMediaPermissionSnapshot.current()
    var errorMessage: String?

    @ObservationIgnored private let microphoneFactory:
        @MainActor () throws -> any VoiceMicrophoneTesting
    @ObservationIgnored private let microphonePermissionRequester:
        @MainActor () async -> Bool
    @ObservationIgnored private var microphoneEngine: (any VoiceMicrophoneTesting)?
    @ObservationIgnored private var speakerEngine: VoiceSpeakerTestEngine?
    @ObservationIgnored private var cameraEngine: CameraPreviewEngine?
    @ObservationIgnored private var cameraFrameTask: Task<Void, Never>?

    init(
        microphoneFactory: @escaping @MainActor () throws -> any VoiceMicrophoneTesting = {
            try VoiceAudioEngine()
        },
        microphonePermissionRequester: @escaping @MainActor () async -> Bool = {
            await VoiceAudioEngine.requestMicrophonePermission()
        }
    ) {
        self.microphoneFactory = microphoneFactory
        self.microphonePermissionRequester = microphonePermissionRequester
    }

    func refreshPermissions() {
        permissions = VoiceMediaPermissionSnapshot.current()
    }

    func startMicrophoneTest(
        inputDeviceID: AudioDeviceID?,
        outputDeviceID: AudioDeviceID?,
        inputVolume: Float,
        noiseSuppressionEnabled: Bool
    ) async {
        stopMicrophoneTest()
        guard await microphonePermissionRequester() else {
            refreshPermissions()
            errorMessage = "Microphone access is required to run the microphone test."
            return
        }
        refreshPermissions()
        do {
            let engine = try microphoneFactory()
            engine.inputVolume = inputVolume
            engine.inputLevelHandler = { [weak self, weak engine] level in
                Task { @MainActor [weak self, weak engine] in
                    guard let self,
                          let engine,
                          self.microphoneEngine === engine
                    else { return }
                    self.microphoneLevel = level
                }
            }
            try engine.start(
                inputDeviceID: inputDeviceID,
                outputDeviceID: outputDeviceID,
                voiceProcessingEnabled: noiseSuppressionEnabled,
                onCapturedFrame: { _ in }
            )
            microphoneEngine = engine
            isMicrophoneTestRunning = true
            errorMessage = nil
        } catch {
            microphoneEngine?.stop()
            microphoneEngine = nil
            microphoneLevel = 0
            isMicrophoneTestRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func stopMicrophoneTest() {
        microphoneEngine?.stop()
        microphoneEngine = nil
        microphoneLevel = 0
        isMicrophoneTestRunning = false
    }

    func startSpeakerTest(outputDeviceID: AudioDeviceID?, outputVolume: Float) {
        stopSpeakerTest()
        do {
            let engine = VoiceSpeakerTestEngine()
            try engine.start(outputDeviceID: outputDeviceID, volume: outputVolume)
            speakerEngine = engine
            isSpeakerTestRunning = true
            errorMessage = nil
        } catch {
            speakerEngine = nil
            isSpeakerTestRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func stopSpeakerTest() {
        speakerEngine?.stop()
        speakerEngine = nil
        isSpeakerTestRunning = false
    }

    func startCameraPreview(cameraUniqueID: String?) async {
        stopCameraPreview()
        guard await VoiceVideoEngine.requestCameraPermission() else {
            refreshPermissions()
            errorMessage = "Camera access is required to show a preview."
            return
        }
        refreshPermissions()
        do {
            let engine = CameraPreviewEngine()
            try engine.start(cameraUniqueID: cameraUniqueID)
            cameraEngine = engine
            isCameraPreviewRunning = true
            cameraFrameTask = Task { @MainActor [weak self, engine] in
                for await frame in engine.frames {
                    guard let self,
                          !Task.isCancelled,
                          self.cameraEngine === engine
                    else { return }
                    self.cameraFrame = frame
                }
            }
            errorMessage = nil
        } catch {
            cameraEngine = nil
            isCameraPreviewRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func stopCameraPreview() {
        cameraFrameTask?.cancel()
        cameraFrameTask = nil
        cameraEngine?.stop()
        cameraEngine = nil
        cameraFrame = nil
        isCameraPreviewRunning = false
    }

    func stopAll() {
        stopMicrophoneTest()
        stopSpeakerTest()
        stopCameraPreview()
    }
}
