import AppKit
import CoreAudio
import MediaPipeline
import SwiftUI

struct VoiceVideoSettingsPage: View {
    private enum Confirmation {
        case reset
    }

    let model: AppModel
    let state: SettingsViewState

    @State private var tests = VoiceVideoTestController()
    @State private var confirmation: Confirmation?
    @State private var exportedPreferences: SettingsPreferenceExportFile?
    @State private var isExporting = false
    @State private var operationMessage: String?

    var body: some View {
        SettingsPageForm(page: .voiceVideo, state: state) {
            VoiceDevicesSettingsSection(
                model: model,
                tests: tests,
                state: state,
                refresh: refreshDevices
            )
            VoiceLevelsSettingsSection(model: model, tests: tests, state: state)
            VoiceCallDefaultsSettingsSection(
                preferences: model.voiceVideoPreferences,
                state: state
            )
            VoiceCameraSettingsSection(model: model, tests: tests, state: state)
            VoiceProcessingSettingsSection(model: model, tests: tests, state: state)
            ScreenShareDefaultsSettingsSection(
                preferences: model.voiceVideoPreferences,
                state: state
            )
            VoicePermissionsSettingsSection(
                permissions: tests.permissions,
                state: state,
                refresh: tests.refreshPermissions,
                openSystemSettings: openPrivacySettings
            )
            Section {
                Button("Export Voice & Video Settings…") { exportPreferences() }
                    .settingsControlAnchor(.voiceExport, state: state)
                Button("Reset Voice & Video Settings…", role: .destructive) {
                    confirmation = .reset
                }
                .settingsControlAnchor(.voiceReset, state: state)
            } header: {
                Text("Local data", bundle: #bundle)
            }
        }
        .task {
            await model.refreshMediaDevices()
            tests.refreshPermissions()
        }
        .onDisappear { tests.stopAll() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            tests.refreshPermissions()
        }
        .onChange(of: model.activeVoiceChannel?.id) {
            if model.activeVoiceChannel != nil {
                tests.stopAll()
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            item: exportedPreferences,
            contentTypes: [.json],
            defaultFilename: "SakuraCord-Voice-Video-Settings"
        ) { result in
            if case let .failure(error) = result {
                operationMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Reset Voice & Video Settings?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Reset Voice & Video Settings", role: .destructive) {
                resetPreferences()
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(
                "This restores SakuraCord’s app-wide call and screen-share defaults. "
                    + "It does not change macOS permissions, Discord settings, or mute, "
                    + "deafen, camera, and sharing state in the current call."
            )
        }
        .alert(
            "Voice & Video",
            isPresented: Binding(
                get: { operationMessage != nil || tests.errorMessage != nil },
                set: {
                    if !$0 {
                        operationMessage = nil
                        tests.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                operationMessage = nil
                tests.errorMessage = nil
            }
        } message: {
            Text(operationMessage ?? tests.errorMessage ?? "")
        }
    }

    private func refreshDevices() {
        tests.stopAll()
        Task { await model.refreshMediaDevices() }
    }

    private func openPrivacySettings() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ), NSWorkspace.shared.open(url) else {
            operationMessage = "System Settings could not be opened. Open Privacy & Security in System Settings manually."
            return
        }
    }

    private func exportPreferences() {
        exportedPreferences = SettingsPreferenceExportFile(
            export: SettingsPreferenceStore.shared.export(
                scope: .appWide,
                page: .voiceVideo
            )
        )
        isExporting = true
    }

    private func resetPreferences() {
        confirmation = nil
        tests.stopAll()
        SettingsPreferenceStore.shared.reset(scope: .appWide, page: .voiceVideo)
        model.voiceVideoPreferences.reload()
        Task {
            _ = await model.selectInputDevice(nil)
            _ = await model.selectOutputDevice(nil)
            _ = await model.selectCamera(nil)
            await model.updateInputVolume(1)
            await model.updateOutputVolume(1)
            _ = await model.updateNoiseSuppression(true)
            operationMessage = "Restored Voice & Video settings to their defaults. Current mute, deafen, camera, and sharing state were left unchanged."
        }
    }
}

private struct VoiceDevicesSettingsSection: View {
    let model: AppModel
    let tests: VoiceVideoTestController
    let state: SettingsViewState
    let refresh: () -> Void

    var body: some View {
        Section {
            Picker("Input device", selection: inputSelection) {
                Text(systemDefaultAudioDeviceLabel(model.mediaDevices.audioInputs)).tag("")
                ForEach(model.mediaDevices.audioInputs) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .settingsControlAnchor(.voiceInputDevice, state: state)

            Picker("Output device", selection: outputSelection) {
                Text(systemDefaultAudioDeviceLabel(model.mediaDevices.audioOutputs)).tag("")
                ForEach(model.mediaDevices.audioOutputs) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .settingsControlAnchor(.voiceOutputDevice, state: state)

            Picker("Camera", selection: cameraSelection) {
                Text(systemDefaultCameraLabel(model.mediaDevices.cameras)).tag("")
                ForEach(model.mediaDevices.cameras) { camera in
                    Text(camera.name).tag(camera.uniqueID)
                }
            }
            .settingsControlAnchor(.voiceCamera, state: state)

            LabeledContent("Devices") {
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
            }
            .settingsControlAnchor(.voiceRefreshDevices, state: state)

            if let statusMessage = model.voiceDeviceStatusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Devices", bundle: #bundle)
        } footer: {
            Text("System Default follows changes made in macOS. If a saved device disappears, SakuraCord uses and saves the system default instead.")
        }
    }

    private var inputSelection: Binding<String> {
        Binding(
            get: { model.voiceVideoPreferences.inputDeviceUID },
            set: { uid in
                tests.stopMicrophoneTest()
                let device = model.mediaDevices.audioInputs.first { $0.uid == uid }
                Task {
                    if !(await model.selectInputDevice(device)) {
                        tests.errorMessage = model.voiceErrorMessage
                    }
                }
            }
        )
    }

    private var outputSelection: Binding<String> {
        Binding(
            get: { model.voiceVideoPreferences.outputDeviceUID },
            set: { uid in
                tests.stopMicrophoneTest()
                tests.stopSpeakerTest()
                let device = model.mediaDevices.audioOutputs.first { $0.uid == uid }
                Task {
                    if !(await model.selectOutputDevice(device)) {
                        tests.errorMessage = model.voiceErrorMessage
                    }
                }
            }
        )
    }

    private var cameraSelection: Binding<String> {
        Binding(
            get: { model.selectedCameraUID ?? "" },
            set: { uid in
                tests.stopCameraPreview()
                let camera = model.mediaDevices.cameras.first { $0.uniqueID == uid }
                Task {
                    if !(await model.selectCamera(camera)) {
                        tests.errorMessage = model.voiceErrorMessage
                    }
                }
            }
        )
    }
}

private struct VoiceLevelsSettingsSection: View {
    let model: AppModel
    let tests: VoiceVideoTestController
    let state: SettingsViewState

    var body: some View {
        Section {
            LabeledContent("Input volume") {
                Slider(value: inputVolume, in: 0 ... 2)
                    .tint(SakuraCordAccentColor.color)
                Text("\(Int(model.voiceVideoPreferences.inputVolume * 100))%")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            .settingsControlAnchor(.voiceInputVolume, state: state)

            LabeledContent("Microphone level") {
                ProgressView(value: Double(tests.microphoneLevel))
                    .tint(SakuraCordAccentColor.color)
                    .frame(width: 160)
                    .accessibilityLabel("Microphone level")
                    .accessibilityValue("\(Int(tests.microphoneLevel * 100)) percent")
                Button(tests.isMicrophoneTestRunning ? "Stop Test" : "Test Microphone") {
                    toggleMicrophoneTest()
                }
                .disabled(isCallActive)
            }
            .settingsControlAnchor(.voiceMicrophoneTest, state: state)

            LabeledContent("Output volume") {
                Slider(value: outputVolume, in: 0 ... 2)
                    .tint(SakuraCordAccentColor.color)
                Text("\(Int(model.voiceVideoPreferences.outputVolume * 100))%")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            .settingsControlAnchor(.voiceOutputVolume, state: state)

            LabeledContent("Speaker") {
                Button(tests.isSpeakerTestRunning ? "Stop Test" : "Test Speaker") {
                    toggleSpeakerTest()
                }
                .disabled(isCallActive)
            }
            .settingsControlAnchor(.voiceSpeakerTest, state: state)
        } header: {
            Text("Levels & tests", bundle: #bundle)
        } footer: {
            if isCallActive {
                Text("Device tests are unavailable during a call so they cannot interfere with live audio.")
            } else {
                Text("Tests run only while their Stop button is visible. Microphone samples are metered in memory and are never retained.")
            }
        }
    }

    private var isCallActive: Bool { model.activeVoiceChannel != nil }

    private var inputVolume: Binding<Double> {
        Binding(
            get: { model.voiceVideoPreferences.inputVolume },
            set: { value in Task { await model.updateInputVolume(Float(value)) } }
        )
    }

    private var outputVolume: Binding<Double> {
        Binding(
            get: { model.voiceVideoPreferences.outputVolume },
            set: { value in Task { await model.updateOutputVolume(Float(value)) } }
        )
    }

    private func toggleMicrophoneTest() {
        if tests.isMicrophoneTestRunning {
            tests.stopMicrophoneTest()
            return
        }
        tests.stopSpeakerTest()
        let inputID = selectedInputDeviceID(model)
        let outputID = selectedOutputDeviceID(model)
        Task {
            await tests.startMicrophoneTest(
                inputDeviceID: inputID,
                outputDeviceID: outputID,
                inputVolume: Float(model.voiceVideoPreferences.inputVolume),
                noiseSuppressionEnabled: model.voiceVideoPreferences.noiseSuppressionEnabled
            )
        }
    }

    private func toggleSpeakerTest() {
        if tests.isSpeakerTestRunning {
            tests.stopSpeakerTest()
            return
        }
        tests.stopMicrophoneTest()
        tests.startSpeakerTest(
            outputDeviceID: selectedOutputDeviceID(model),
            outputVolume: Float(model.voiceVideoPreferences.outputVolume)
        )
    }
}

private struct VoiceCallDefaultsSettingsSection: View {
    let preferences: VoiceVideoPreferences
    let state: SettingsViewState

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Group {
                Toggle("Join calls muted", isOn: $preferences.joinsMuted)
                    .settingsControlAnchor(.voiceJoinMuted, state: state)
                Toggle("Join calls deafened", isOn: $preferences.joinsDeafened)
                    .settingsControlAnchor(.voiceJoinDeafened, state: state)
                Toggle("Play call feedback sounds", isOn: $preferences.playsFeedbackSounds)
                    .settingsControlAnchor(.voiceFeedbackSounds, state: state)
            }
            .tint(SakuraCordAccentColor.color)
        } header: {
            Text("Call defaults", bundle: #bundle)
        } footer: {
            Text("Join defaults apply when entering the next call. Changing them never mutes or deafens a call already in progress.")
        }
    }
}

private struct VoiceCameraSettingsSection: View {
    let model: AppModel
    let tests: VoiceVideoTestController
    let state: SettingsViewState

    var body: some View {
        @Bindable var preferences = model.voiceVideoPreferences
        Section {
            Group {
                if let frame = tests.cameraFrame {
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(x: preferences.mirrorsLocalPreview ? -1 : 1, y: 1)
                } else {
                    ContentUnavailableView(
                        "Camera Preview",
                        systemImage: "video",
                        description: Text("Start the preview to check the selected camera.")
                    )
                    .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 240)
            .clipped()
            .background(.black.opacity(0.75))
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityLabel(
                tests.isCameraPreviewRunning
                    ? "Live camera preview"
                    : "Camera preview stopped"
            )

            LabeledContent("Preview") {
                Button(tests.isCameraPreviewRunning ? "Stop Preview" : "Start Preview") {
                    togglePreview()
                }
                .disabled(model.activeVoiceChannel != nil)
            }
            .settingsControlAnchor(.voiceCameraPreview, state: state)

            Group {
                Toggle("Mirror my local preview", isOn: $preferences.mirrorsLocalPreview)
                    .settingsControlAnchor(.voiceMirrorPreview, state: state)
                Toggle("Remember selected camera", isOn: rememberCamera)
                    .settingsControlAnchor(.voiceRememberCamera, state: state)
                Toggle("Join calls with camera off", isOn: $preferences.joinsWithCameraOff)
                    .settingsControlAnchor(.voiceJoinCameraOff, state: state)
            }
            .tint(SakuraCordAccentColor.color)
        } header: {
            Text("Camera", bundle: #bundle)
        } footer: {
            Text("Mirroring affects only your local preview. Camera defaults apply when joining the next call; live camera controls remain in the call.")
        }
    }

    private var rememberCamera: Binding<Bool> {
        Binding(
            get: { model.voiceVideoPreferences.remembersCamera },
            set: { model.updateCameraPersistence($0) }
        )
    }

    private func togglePreview() {
        if tests.isCameraPreviewRunning {
            tests.stopCameraPreview()
        } else {
            Task { await tests.startCameraPreview(cameraUniqueID: model.selectedCameraUID) }
        }
    }
}

private struct VoiceProcessingSettingsSection: View {
    let model: AppModel
    let tests: VoiceVideoTestController
    let state: SettingsViewState

    var body: some View {
        Section {
            Toggle("Noise suppression", isOn: noiseSuppression)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.voiceNoiseSuppression, state: state)
        } header: {
            Text("Audio processing", bundle: #bundle)
        } footer: {
            Text(
                "Uses Apple’s built-in voice-processing input/output path to reduce "
                    + "steady background noise and acoustic echo. Changing it restarts "
                    + "SakuraCord’s audio graph and reports any device error without "
                    + "changing the saved value."
            )
        }
    }

    private var noiseSuppression: Binding<Bool> {
        Binding(
            get: { model.voiceVideoPreferences.noiseSuppressionEnabled },
            set: { enabled in
                tests.stopMicrophoneTest()
                Task {
                    if !(await model.updateNoiseSuppression(enabled)) {
                        tests.errorMessage = model.voiceErrorMessage
                    }
                }
            }
        )
    }
}

private struct ScreenShareDefaultsSettingsSection: View {
    let preferences: VoiceVideoPreferences
    let state: SettingsViewState

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Picker("Quality", selection: $preferences.screenShareQuality) {
                ForEach(ScreenShareQuality.allCases, id: \.self) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .settingsControlAnchor(.voiceScreenShareQuality, state: state)

            Picker("Frame rate", selection: $preferences.screenShareFrameRate) {
                ForEach(ScreenShareFrameRate.allCases, id: \.self) { rate in
                    Text(rate.title).tag(rate)
                }
            }
            .settingsControlAnchor(.voiceScreenShareFrameRate, state: state)

            Toggle("Include system audio", isOn: $preferences.screenShareIncludesAudio)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.voiceScreenShareAudio, state: state)
            Toggle("Show pointer", isOn: $preferences.screenShareShowsPointer)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.voiceScreenSharePointer, state: state)
        } header: {
            Text("Screen share defaults", bundle: #bundle)
        } footer: {
            Text("These values initialize the next share. The existing share preview remains the place to change quality, frame rate, audio, and pointer capture for the active share.")
        }
    }
}

private struct VoicePermissionsSettingsSection: View {
    let permissions: VoiceMediaPermissionSnapshot
    let state: SettingsViewState
    let refresh: () -> Void
    let openSystemSettings: () -> Void

    var body: some View {
        Section {
            LabeledContent("Microphone") {
                Text(permissionTitle(permissions.microphone))
                    .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.voiceMicrophonePermission, state: state)

            LabeledContent("Camera") {
                Text(permissionTitle(permissions.camera))
                    .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.voiceCameraPermission, state: state)

            LabeledContent("Screen & system audio recording") {
                Text(permissions.screenRecordingAllowed ? "Allowed" : "Not allowed")
                    .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.voiceScreenPermission, state: state)

            LabeledContent("Privacy & Security") {
                Button("Refresh", action: refresh)
                Button("Open System Settings", action: openSystemSettings)
            }
        } header: {
            Text("Permissions", bundle: #bundle)
        } footer: {
            Text("macOS owns and persists these permissions. SakuraCord reports their current state and requests access only when a feature needs it.")
        }
    }
}

private func selectedInputDeviceID(_ model: AppModel) -> AudioDeviceID? {
    let uid = model.voiceVideoPreferences.inputDeviceUID
    return model.mediaDevices.audioInputs.first { $0.uid == uid }?.id
}

private func selectedOutputDeviceID(_ model: AppModel) -> AudioDeviceID? {
    let uid = model.voiceVideoPreferences.outputDeviceUID
    return model.mediaDevices.audioOutputs.first { $0.uid == uid }?.id
}

private func systemDefaultAudioDeviceLabel(_ devices: [AudioDeviceInfo]) -> String {
    guard let device = devices.first(where: \.isDefault) else { return "System Default" }
    return "System Default (\(device.name))"
}

private func systemDefaultCameraLabel(_ cameras: [CameraDeviceInfo]) -> String {
    cameras.first(where: \.isDefault)
        .map { "System Default (\($0.name))" } ?? "System Default"
}

private func permissionTitle(_ authorization: VoiceMediaAuthorization) -> String {
    switch authorization {
    case .authorized: "Allowed"
    case .denied: "Denied"
    case .restricted: "Restricted"
    case .notDetermined: "Not requested"
    }
}
