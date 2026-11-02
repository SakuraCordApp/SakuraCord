@testable import SakuraCord
import CoreAudio
import DiscordProtocol
import Foundation
import MediaPipeline
import Observation
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
@Test func `Deafening mutes and undeafening restores the previous mute`() async throws {
    let provider = MockChatProvider()
    let preferences = VoiceVideoPreferences(defaults: InMemoryPreferences())
    preferences.joinsDeafened = true
    preferences.playsFeedbackSounds = false
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        voiceVideoPreferences: preferences
    )
    await model.start()
    await model.joinVoice(try #require(model.visibleChannels.first { $0.kind == .voice }))

    #expect(try #require(await provider.voiceJoinRequests.last).selfMute)
    #expect(model.isVoiceDeafened && model.isVoiceMuted)
    await model.toggleVoiceDeafen()
    #expect(!model.isVoiceDeafened && !model.isVoiceMuted)

    await model.toggleVoiceDeafen()
    #expect(model.isVoiceDeafened && model.isVoiceMuted)
    await model.toggleVoiceDeafen()
    #expect(!model.isVoiceDeafened && !model.isVoiceMuted)

    await model.toggleVoiceMute()
    await model.toggleVoiceDeafen()
    await model.toggleVoiceDeafen()
    #expect(!model.isVoiceDeafened && model.isVoiceMuted)

    await model.toggleVoiceDeafen()
    await model.toggleVoiceMute()
    #expect(!model.isVoiceDeafened && !model.isVoiceMuted)
    await model.leaveVoice()
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
@Test(.timeLimit(.minutes(1))) func `Microphone test waits for playback and cancels queued audio on stop`() async {
    let fake = ControlledMicrophoneTestEngine()
    var permissionRequests = 0
    let playbackRequests = AsyncStream<AsyncStream<Void>.Continuation>.makeStream()
    var requests = playbackRequests.stream.makeAsyncIterator()
    let controller = VoiceVideoTestController(
        microphoneFactory: { fake },
        microphonePermissionRequester: {
            permissionRequests += 1
            return true
        },
        microphonePlaybackWait: { _ in
            let permit = AsyncStream<Void>.makeStream()
            playbackRequests.continuation.yield(permit.continuation)
            var ready = permit.stream.makeAsyncIterator()
            _ = await ready.next()
            try Task.checkCancellation()
            return true
        }
    )

    controller.prepareMicrophoneTest()
    #expect(fake.startRequest == nil)
    #expect(permissionRequests == 0)
    #expect(!controller.isMicrophoneTestRunning)

    await controller.startMicrophoneTest(
        inputDeviceID: 41,
        outputDeviceID: 42,
        inputVolume: 1.25,
        outputVolume: 0.75
    )

    #expect(controller.isMicrophoneTestRunning)
    #expect(permissionRequests == 1)
    #expect(fake.startRequest == ControlledMicrophoneTestEngine.StartRequest(
        inputDeviceID: 41,
        outputDeviceID: 42
    ))
    #expect(fake.inputVolume == 1.25)
    #expect(fake.outputVolume == 0.75)
    #expect(await controller.selectMicrophoneTestInput(43))
    #expect(fake.outputDeviceSelections.isEmpty)
    #expect(await controller.selectMicrophoneTestOutput(44))
    #expect(await controller.selectMicrophoneTestOutput(nil))
    #expect(fake.inputDeviceSelections == [43])
    #expect(fake.outputDeviceSelections == [44, nil])
    #expect(controller.isMicrophoneTestRunning)
    #expect(fake.stopCount == 0)
    fake.routeError = .outputUnavailable
    #expect(!(await controller.selectMicrophoneTestOutput(99)))
    #expect(controller.isMicrophoneTestRunning)
    #expect(controller.errorMessage != nil)
    #expect(fake.stopCount == 0)
    fake.routeError = nil
    #expect(await controller.selectMicrophoneTestInput(45))
    #expect(fake.inputDeviceSelections == [43, 45])
    #expect(fake.outputDeviceSelections == [44, nil])
    #expect(controller.isMicrophoneTestRunning)
    #expect(fake.stopCount == 0)
    controller.updateTestVolumes(input: 0.5, output: 1.5)
    #expect(fake.inputVolume == 0.5)
    #expect(fake.outputVolume == 1.5)
    let packet = Data([1, 2, 3])
    fake.emitFrame(packet)
    #expect(fake.playedPackets.isEmpty)
    var playback = fake.playback.stream.makeAsyncIterator()
    let permit = await requests.next()
    permit?.yield(())
    let played = await playback.next()
    #expect(played == packet)
    let levelChanges = AsyncStream<Void>.makeStream()
    withObservationTracking {
        _ = controller.microphoneLevel
    } onChange: {
        levelChanges.continuation.yield(())
    }
    fake.emitLevel(0.64)
    var changes = levelChanges.stream.makeAsyncIterator()
    _ = await changes.next()
    #expect(controller.microphoneLevel == 0.64)

    fake.emitFrame(Data([9]))
    _ = await requests.next()
    controller.stopMicrophoneTest()
    #expect(!controller.isMicrophoneTestRunning)
    #expect(controller.microphoneLevel == 0)
    #expect(fake.stopCount == 1)
    #expect(fake.inputLevelHandler == nil)

    await controller.startMicrophoneTest(
        inputDeviceID: 41, outputDeviceID: 42, inputVolume: 1, outputVolume: 1
    )
    let nextPacket = Data([4, 5, 6])
    fake.emitFrame(nextPacket)
    let nextPermit = await requests.next()
    nextPermit?.yield(())
    #expect(await playback.next() == nextPacket)
    #expect(fake.playedPackets == [packet, nextPacket])
    controller.stopAll()
}

@MainActor
@Test(.timeLimit(.minutes(1))) func `Stopping a microphone test cancels a pending permission request`() async {
    let requested = AsyncStream<Void>.makeStream()
    let permission = AsyncStream<Bool>.makeStream()
    let fake = ControlledMicrophoneTestEngine()
    let controller = VoiceVideoTestController(
        microphoneFactory: { fake },
        microphonePermissionRequester: {
            requested.continuation.yield(())
            var response = permission.stream.makeAsyncIterator()
            return await response.next() ?? false
        }
    )
    let start = Task {
        await controller.startMicrophoneTest(
            inputDeviceID: nil, outputDeviceID: nil, inputVolume: 1, outputVolume: 1
        )
    }
    var request = requested.stream.makeAsyncIterator()
    _ = await request.next()
    #expect(controller.isMicrophoneTestStarting)
    controller.stopAll()
    permission.continuation.yield(true)
    await start.value
    #expect(fake.startRequest == nil)
    #expect(!controller.isMicrophoneTestStarting)
    #expect(!controller.isMicrophoneTestRunning)
}

@MainActor
@Test func `Failed microphone test startup releases partially opened audio devices`() async {
    let fake = ControlledMicrophoneTestEngine()
    fake.startError = VoiceAudioEngineError.outputUnavailable
    let controller = VoiceVideoTestController(
        microphoneFactory: { fake },
        microphonePermissionRequester: { true }
    )
    await controller.startMicrophoneTest(
        inputDeviceID: nil, outputDeviceID: nil, inputVolume: 1, outputVolume: 1
    )
    #expect(fake.stopCount == 1)
    #expect(fake.inputLevelHandler == nil)
    #expect(!controller.isMicrophoneTestRunning)
    #expect(controller.errorMessage != nil)
}

@MainActor
@Test func `Voice settings metadata describes system-owned permissions`() {
    let catalog = SettingsCatalog.foundation
    let permissions = [
        SettingsControlID.voiceMicrophonePermission,
        .voiceCameraPermission,
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
    var outputVolume: Float = 1
    var startError: VoiceAudioEngineError?
    var routeError: VoiceAudioEngineError?
    private(set) var inputDeviceSelections: [AudioDeviceID?] = []
    private(set) var outputDeviceSelections: [AudioDeviceID?] = []
    let playback = AsyncStream<Data>.makeStream()
    private(set) var playedPackets: [Data] = []
    private var capturedFrameHandler: (@Sendable (CapturedOpusFrame) -> Void)?
    var inputLevelHandler: (@Sendable (Float) -> Void)?
    private(set) var startRequest: StartRequest?
    private(set) var stopCount = 0

    func startMicrophoneTest(
        inputDeviceID: AudioDeviceID?,
        outputDeviceID: AudioDeviceID?,
        onCapturedFrame: @escaping @Sendable (CapturedOpusFrame) -> Void
    ) throws {
        startRequest = StartRequest(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID
        )
        capturedFrameHandler = onCapturedFrame
        if let startError { throw startError }
    }

    func selectInputDevice(_ deviceID: AudioDeviceID?) async throws {
        if let routeError { throw routeError }
        inputDeviceSelections.append(deviceID)
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID?) async throws {
        if let routeError { throw routeError }
        outputDeviceSelections.append(deviceID)
    }

    func play(opusPacket: Data, from _: String) throws {
        playedPackets.append(opusPacket)
        playback.continuation.yield(opusPacket)
    }

    func emitFrame(_ data: Data) {
        capturedFrameHandler?(CapturedOpusFrame(data: data, containsVoice: true))
    }

    func stop() {
        stopCount += 1
        capturedFrameHandler = nil
        inputLevelHandler = nil
    }

    func emitLevel(_ level: Float) {
        inputLevelHandler?(level)
    }
}
