@testable import SakuraCord
import CoreAudio
import DiscordProtocol
import MediaPipeline
import SakuraCordModels
import Testing

@MainActor
@Test func `Voice and Video preferences persist export and reset as app wide values`() {
    let defaults = InMemoryPreferences()
    let preferences = VoiceVideoPreferences(defaults: defaults)
    preferences.inputDeviceUID = "input"
    preferences.outputDeviceUID = "output"
    preferences.cameraUID = "camera"
    preferences.inputVolume = 1.4
    preferences.outputVolume = 0.7
    preferences.joinsMuted = true
    preferences.joinsDeafened = true
    preferences.playsFeedbackSounds = false
    preferences.remembersCamera = false
    preferences.mirrorsLocalPreview = false
    preferences.joinsWithCameraOff = false
    preferences.screenShareQuality = .source
    preferences.screenShareFrameRate = .fps60
    preferences.screenShareIncludesAudio = false
    preferences.screenShareShowsPointer = false

    let restored = VoiceVideoPreferences(defaults: defaults)
    #expect(restored.inputDeviceUID == "input")
    #expect(restored.outputDeviceUID == "output")
    #expect(restored.cameraUID == "camera")
    #expect(restored.inputVolume == 1.4)
    #expect(restored.outputVolume == 0.7)
    #expect(restored.joinsMuted)
    #expect(restored.joinsDeafened)
    #expect(!restored.playsFeedbackSounds)
    #expect(!restored.remembersCamera)
    #expect(!restored.mirrorsLocalPreview)
    #expect(!restored.joinsWithCameraOff)
    #expect(restored.screenShareDefaults == ScreenShareSettings(
        frameRate: .fps60,
        quality: .source,
        includesAudio: false,
        showsCursor: false
    ))

    let store = SettingsPreferenceStore(defaults: defaults)
    let export = store.export(scope: .appWide, page: .voiceVideo)
    #expect(export.values.count == 15)
    #expect(export.values[SettingsControlID.voiceInputDevice.rawValue] == .string("input"))
    #expect(export.values[SettingsControlID.voiceJoinMuted.rawValue] == .bool(true))
    #expect(
        export.values[SettingsControlID.voiceScreenShareQuality.rawValue]
            == .string(ScreenShareQuality.source.rawValue)
    )
    #expect(export.values[SettingsControlID.notificationEnabled.rawValue] == nil)

    store.reset(scope: .appWide, page: .voiceVideo)
    restored.reload()
    #expect(restored.inputDeviceUID.isEmpty)
    #expect(restored.outputDeviceUID.isEmpty)
    #expect(restored.cameraUID.isEmpty)
    #expect(restored.inputVolume == 1)
    #expect(restored.outputVolume == 1)
    #expect(!restored.joinsMuted)
    #expect(!restored.joinsDeafened)
    #expect(restored.playsFeedbackSounds)
    #expect(restored.remembersCamera)
    #expect(restored.mirrorsLocalPreview)
    #expect(restored.joinsWithCameraOff)
    #expect(restored.screenShareDefaults == ScreenShareSettings())
}

@MainActor
@Test func `Voice join defaults reach the provider and do not become live toggles`() async throws {
    let provider = MockChatProvider()
    let preferences = VoiceVideoPreferences(defaults: InMemoryPreferences())
    preferences.joinsMuted = true
    preferences.joinsDeafened = true
    preferences.playsFeedbackSounds = false
    let sounds = RecordingAppSoundPlayer()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        soundPlayer: sounds,
        voiceVideoPreferences: preferences
    )
    await model.start()
    let channel = try #require(model.visibleChannels.first { $0.kind == .voice })

    await model.joinVoice(channel)

    let request = try #require(await provider.voiceJoinRequests.last)
    #expect(request.channelID == channel.id)
    #expect(request.selfMute)
    #expect(request.selfDeaf)
    #expect(model.isVoiceMuted)
    #expect(model.isVoiceDeafened)
    #expect(sounds.played.isEmpty)

    preferences.joinsMuted = false
    preferences.joinsDeafened = false
    #expect(model.isVoiceMuted)
    #expect(model.isVoiceDeafened)

    await model.leaveVoice()
    #expect(sounds.played.isEmpty)
}

@MainActor
@Test func `Camera persistence forgets its identifier without changing the active selection`() {
    let defaults = InMemoryPreferences()
    let preferences = VoiceVideoPreferences(defaults: defaults)
    preferences.cameraUID = "camera-a"
    let model = AppModel(
        launchMode: .offlineTesting,
        voiceVideoPreferences: preferences
    )

    #expect(model.selectedCameraUID == "camera-a")
    model.updateCameraPersistence(false)
    #expect(model.selectedCameraUID == "camera-a")
    #expect(preferences.cameraUID.isEmpty)
    #expect(defaults.string(forKey: "voiceCameraUID") == nil)

    model.updateCameraPersistence(true)
    #expect(preferences.cameraUID == "camera-a")
}

@MainActor
@Test func `Missing saved camera falls back to the system default with an honest status`() async {
    let preferences = VoiceVideoPreferences(defaults: InMemoryPreferences())
    preferences.cameraUID = "disconnected-camera"
    let model = AppModel(
        launchMode: .offlineTesting,
        voiceVideoPreferences: preferences
    )
    let availableCamera = CameraDeviceInfo(uniqueID: "available-camera", name: "Camera")

    await model.installMediaDeviceSnapshot(MediaDeviceSnapshot(
        audioInputs: [],
        audioOutputs: [],
        cameras: [availableCamera]
    ))

    #expect(model.selectedCameraUID == nil)
    #expect(preferences.cameraUID.isEmpty)
    #expect(
        model.voiceDeviceStatusMessage
            == "The saved camera is unavailable; using the system default."
    )
}

@MainActor
@Test func `Microphone test passes selected routes and releases its engine`() async {
    let fake = ControlledMicrophoneTestEngine()
    let controller = VoiceVideoTestController(
        microphoneFactory: { fake },
        microphonePermissionRequester: { true }
    )

    await controller.startMicrophoneTest(
        inputDeviceID: 41,
        outputDeviceID: 42,
        inputVolume: 1.25
    )

    #expect(controller.isMicrophoneTestRunning)
    #expect(fake.startRequest == ControlledMicrophoneTestEngine.StartRequest(
        inputDeviceID: 41,
        outputDeviceID: 42
    ))
    #expect(fake.inputVolume == 1.25)
    fake.emitLevel(0.64)
    await Task.yield()
    #expect(controller.microphoneLevel == 0.64)

    controller.stopMicrophoneTest()
    #expect(!controller.isMicrophoneTestRunning)
    #expect(controller.microphoneLevel == 0)
    #expect(fake.stopCount == 1)
    #expect(fake.inputLevelHandler == nil)

}

@MainActor
@Test func `Voice settings metadata describes system-owned permissions`() {
    let catalog = SettingsCatalog.foundation
    let permissions = [
        SettingsControlID.voiceMicrophonePermission,
        .voiceCameraPermission,
        .voiceScreenPermission,
    ]
    for id in permissions {
        let control = catalog.controls.first { $0.id == id }
        #expect(control?.owner == .macOS)
        #expect(control?.persistence == .systemManaged)
        #expect(control?.resetCapability == .notApplicable)
    }

}

@MainActor
private final class ControlledMicrophoneTestEngine: VoiceMicrophoneTesting {
    struct StartRequest: Equatable {
        var inputDeviceID: AudioDeviceID?
        var outputDeviceID: AudioDeviceID?
    }

    var inputVolume: Float = 1
    var inputLevelHandler: (@Sendable (Float) -> Void)?
    private(set) var startRequest: StartRequest?
    private(set) var stopCount = 0

    func start(
        inputDeviceID: AudioDeviceID?,
        outputDeviceID: AudioDeviceID?,
        onCapturedFrame _: @escaping @Sendable (CapturedOpusFrame) -> Void
    ) throws {
        startRequest = StartRequest(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID
        )
    }

    func stop() {
        stopCount += 1
        inputLevelHandler = nil
    }

    func emitLevel(_ level: Float) {
        inputLevelHandler?(level)
    }
}
