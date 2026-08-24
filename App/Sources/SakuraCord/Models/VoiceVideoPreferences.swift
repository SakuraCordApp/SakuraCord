import Foundation
import MediaPipeline
import Observation

@MainActor
@Observable
final class VoiceVideoPreferences {
    enum Key {
        static let inputDeviceUID = "voiceInputDeviceUID"
        static let outputDeviceUID = "voiceOutputDeviceUID"
        static let cameraUID = "voiceCameraUID"
        static let inputVolume = "voiceInputVolume"
        static let outputVolume = "voiceOutputVolume"
        static let joinMuted = "voice.joinMuted"
        static let joinDeafened = "voice.joinDeafened"
        static let feedbackSounds = "voice.feedbackSounds"
        static let remembersCamera = "voice.remembersCamera"
        static let mirrorsLocalPreview = "voice.mirrorsLocalPreview"
        static let joinsWithCameraOff = "voice.joinsWithCameraOff"
        static let noiseSuppression = "voice.noiseSuppression"
        static let screenShareQuality = "voice.screenShare.quality"
        static let screenShareFrameRate = "voice.screenShare.frameRate"
        static let screenShareIncludesAudio = "voice.screenShare.includesAudio"
        static let screenShareShowsPointer = "voice.screenShare.showsPointer"
    }

    var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID) }
    }
    var outputDeviceUID: String {
        didSet { defaults.set(outputDeviceUID, forKey: Key.outputDeviceUID) }
    }
    var cameraUID: String {
        didSet { defaults.set(cameraUID, forKey: Key.cameraUID) }
    }
    var inputVolume: Double {
        didSet { defaults.set(inputVolume, forKey: Key.inputVolume) }
    }
    var outputVolume: Double {
        didSet { defaults.set(outputVolume, forKey: Key.outputVolume) }
    }
    var joinsMuted: Bool {
        didSet { defaults.set(joinsMuted, forKey: Key.joinMuted) }
    }
    var joinsDeafened: Bool {
        didSet { defaults.set(joinsDeafened, forKey: Key.joinDeafened) }
    }
    var playsFeedbackSounds: Bool {
        didSet { defaults.set(playsFeedbackSounds, forKey: Key.feedbackSounds) }
    }
    var remembersCamera: Bool {
        didSet { defaults.set(remembersCamera, forKey: Key.remembersCamera) }
    }
    var mirrorsLocalPreview: Bool {
        didSet { defaults.set(mirrorsLocalPreview, forKey: Key.mirrorsLocalPreview) }
    }
    var joinsWithCameraOff: Bool {
        didSet { defaults.set(joinsWithCameraOff, forKey: Key.joinsWithCameraOff) }
    }
    var noiseSuppressionEnabled: Bool {
        didSet { defaults.set(noiseSuppressionEnabled, forKey: Key.noiseSuppression) }
    }
    var screenShareQuality: ScreenShareQuality {
        didSet { defaults.set(screenShareQuality.rawValue, forKey: Key.screenShareQuality) }
    }
    var screenShareFrameRate: ScreenShareFrameRate {
        didSet { defaults.set(screenShareFrameRate.rawValue, forKey: Key.screenShareFrameRate) }
    }
    var screenShareIncludesAudio: Bool {
        didSet { defaults.set(screenShareIncludesAudio, forKey: Key.screenShareIncludesAudio) }
    }
    var screenShareShowsPointer: Bool {
        didSet { defaults.set(screenShareShowsPointer, forKey: Key.screenShareShowsPointer) }
    }

    @ObservationIgnored private let defaults: any PreferenceStoring

    init(defaults: any PreferenceStoring = UserDefaults.standard) {
        self.defaults = defaults
        inputDeviceUID = ""
        outputDeviceUID = ""
        cameraUID = ""
        inputVolume = 1
        outputVolume = 1
        joinsMuted = false
        joinsDeafened = false
        playsFeedbackSounds = true
        remembersCamera = true
        mirrorsLocalPreview = true
        joinsWithCameraOff = true
        noiseSuppressionEnabled = true
        screenShareQuality = .p1080
        screenShareFrameRate = .fps30
        screenShareIncludesAudio = true
        screenShareShowsPointer = true
        reload()
    }

    var screenShareDefaults: ScreenShareSettings {
        ScreenShareSettings(
            frameRate: screenShareFrameRate,
            quality: screenShareQuality,
            includesAudio: screenShareIncludesAudio,
            showsCursor: screenShareShowsPointer
        )
    }

    func reload() {
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID) ?? ""
        outputDeviceUID = defaults.string(forKey: Key.outputDeviceUID) ?? ""
        cameraUID = defaults.string(forKey: Key.cameraUID) ?? ""
        inputVolume = clampedVolume(defaults.object(forKey: Key.inputVolume) as? Double ?? 1)
        outputVolume = clampedVolume(defaults.object(forKey: Key.outputVolume) as? Double ?? 1)
        joinsMuted = bool(Key.joinMuted, default: false)
        joinsDeafened = bool(Key.joinDeafened, default: false)
        playsFeedbackSounds = bool(Key.feedbackSounds, default: true)
        remembersCamera = bool(Key.remembersCamera, default: true)
        mirrorsLocalPreview = bool(Key.mirrorsLocalPreview, default: true)
        joinsWithCameraOff = bool(Key.joinsWithCameraOff, default: true)
        noiseSuppressionEnabled = bool(Key.noiseSuppression, default: true)
        screenShareQuality = defaults.string(forKey: Key.screenShareQuality)
            .flatMap(ScreenShareQuality.init(rawValue:)) ?? .p1080
        screenShareFrameRate = (defaults.object(forKey: Key.screenShareFrameRate) as? Int)
            .flatMap(ScreenShareFrameRate.init(rawValue:)) ?? .fps30
        screenShareIncludesAudio = bool(Key.screenShareIncludesAudio, default: true)
        screenShareShowsPointer = bool(Key.screenShareShowsPointer, default: true)
    }

    func forgetSavedCamera() {
        cameraUID = ""
        defaults.removeObject(forKey: Key.cameraUID)
    }

    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    private func clampedVolume(_ value: Double) -> Double {
        min(max(value, 0), 2)
    }
}
