import AppKit
import CoreAudio
import MediaPipeline
import SwiftUI

struct VoiceVideoSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var tests = VoiceVideoTestController()
    @State private var showsResetConfirmation = false
    @State private var operationMessage: String?

    var body: some View {
        SettingsPageForm(page: .voiceVideo, state: state) {
            VoiceAudioSettingsSection(
                model: model,
                tests: tests,
                state: state,
                refresh: refreshDevices
            )
            VoiceCallDefaultsSettingsSection(
                preferences: model.voiceVideoPreferences,
                state: state
            )
            VoiceCameraSettingsSection(model: model, tests: tests, state: state)
            ScreenShareDefaultsSettingsSection(
                model: model,
                state: state
            )
            VoicePermissionsSettingsSection(
                permissions: tests.permissions,
                state: state,
                openMicrophoneSettings: { openPrivacySettings("Privacy_Microphone") },
                openCameraSettings: { openPrivacySettings("Privacy_Camera") }
            )
            Section {
                Button("Reset All…", role: .destructive) {
                    showsResetConfirmation = true
                }
                .settingsControlAnchor(.voiceReset, state: state)
            }
        }
        .task {
            await model.refreshMediaDevices()
            tests.refreshPermissions()
            if !Task.isCancelled {
                tests.prepareMicrophoneTest()
            }
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
        .settingsResetConfirmation(
            "Reset Voice & Video Settings?",
            isPresented: $showsResetConfirmation,
            resetTitle: "Reset Voice & Video Settings",
            message: """
            This restores SakuraCord’s app-wide call and screen-share defaults. \
            It does not change macOS permissions, Discord settings, or mute, \
            deafen, camera, and sharing state in the current call.
            """,
            reset: resetPreferences
        )
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

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
              NSWorkspace.shared.open(url)
        else {
            operationMessage = "System Settings could not be opened. Open Privacy & Security in System Settings manually."
            return
        }
    }

    private func resetPreferences() {
        tests.stopAll()
        SettingsPreferenceStore.shared.reset(scope: .appWide, page: .voiceVideo)
        model.voiceVideoPreferences.reload()
        Task {
            _ = await model.selectInputDevice(nil)
            _ = await model.selectOutputDevice(nil)
            _ = await model.selectCamera(nil)
            await model.updateInputVolume(1)
            await model.updateOutputVolume(1)
        }
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
        } header: {
            Text("Calls", bundle: #bundle)
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
            Picker("Camera", selection: cameraSelection) {
                Text(systemDefaultCameraLabel(model.mediaDevices.cameras)).tag("")
                ForEach(model.mediaDevices.cameras) { camera in
                    Text(camera.name).tag(camera.uniqueID)
                }
            }
            .settingsControlAnchor(.voiceCamera, state: state)

            VoiceCameraPreviewSurface(
                tests: tests,
                mirrorsPreview: preferences.mirrorsLocalPreview,
                isCallActive: model.activeVoiceChannel != nil,
                togglePreview: togglePreview
            )
            .settingsControlAnchor(.voiceCameraPreview, state: state)

            Group {
                Toggle("Mirror my local preview", isOn: $preferences.mirrorsLocalPreview)
                    .settingsControlAnchor(.voiceMirrorPreview, state: state)
                Toggle("Remember selected camera", isOn: rememberCamera)
                    .settingsControlAnchor(.voiceRememberCamera, state: state)
                Toggle("Join calls with camera off", isOn: $preferences.joinsWithCameraOff)
                    .settingsControlAnchor(.voiceJoinCameraOff, state: state)
            }
        } header: {
            Text("Camera", bundle: #bundle)
        }
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

    private var rememberCamera: Binding<Bool> {
        Binding(
            get: { model.voiceVideoPreferences.remembersCamera },
            set: { model.updateCameraPersistence($0) }
        )
    }

    private func togglePreview() {
        if tests.isCameraPreviewRunning || tests.isCameraPreviewStarting {
            tests.stopCameraPreview()
        } else {
            Task { await tests.startCameraPreview(cameraUniqueID: model.selectedCameraUID) }
        }
    }
}

private struct VoiceCameraPreviewSurface: View {
    let tests: VoiceVideoTestController
    let mirrorsPreview: Bool
    let isCallActive: Bool
    let togglePreview: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let frame = tests.cameraFrame {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: mirrorsPreview ? -1 : 1, y: 1)
                    .accessibilityLabel("Live camera preview")
            }
            if !tests.isCameraPreviewRunning, !tests.isCameraPreviewStarting {
                MediaPreviewActionButton(title: "Start Camera", systemImage: "video.fill", action: togglePreview)
                    .disabled(isCallActive)
            } else if tests.cameraFrame == nil {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Starting camera")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: InterfaceScale.metric(240))
        .clipShape(.rect(cornerRadius: InterfaceScale.metric(10)))
        .overlay(alignment: .bottomTrailing) {
            if tests.isCameraPreviewRunning || tests.isCameraPreviewStarting {
                Button("Stop Camera", action: togglePreview)
                    .buttonStyle(.glass)
                    .padding(InterfaceScale.metric(12))
            }
        }
    }
}

private struct ScreenShareDefaultsSettingsSection: View {
    let model: AppModel
    let state: SettingsViewState

    var body: some View {
        @Bindable var preferences = model.voiceVideoPreferences
        Section {
            Picker("Default quality", selection: Binding(
                get: { model.allowedScreenShareSettings(preferences.screenShareDefaults).quality },
                set: { preferences.screenShareQuality = $0 }
            )) {
                ForEach(model.availableScreenShareQualities, id: \.self) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .settingsControlAnchor(.voiceScreenShareQuality, state: state)

            Picker("Default frame rate", selection: Binding(
                get: { model.allowedScreenShareSettings(preferences.screenShareDefaults).frameRate },
                set: { preferences.screenShareFrameRate = $0 }
            )) {
                ForEach(model.availableScreenShareFrameRates, id: \.self) { rate in
                    Text(rate.title).tag(rate)
                }
            }
            .settingsControlAnchor(.voiceScreenShareFrameRate, state: state)

            Toggle("Include system audio", isOn: $preferences.screenShareIncludesAudio)
                .settingsControlAnchor(.voiceScreenShareAudio, state: state)
            Toggle("Show pointer", isOn: $preferences.screenShareShowsPointer)
                .settingsControlAnchor(.voiceScreenSharePointer, state: state)
        } header: {
            Text("Screen Sharing", bundle: #bundle)
        }
    }
}

private struct VoicePermissionsSettingsSection: View {
    let permissions: VoiceMediaPermissionSnapshot
    let state: SettingsViewState
    let openMicrophoneSettings: () -> Void
    let openCameraSettings: () -> Void

    var body: some View {
        Section {
            SettingsPermissionRow(title: "Microphone", status: permissionTitle(permissions.microphone)) {
                Button("Open System Settings…", action: openMicrophoneSettings)
                    .accessibilityLabel("Open Microphone Settings")
            }
            .settingsControlAnchor(.voiceMicrophonePermission, state: state)

            SettingsPermissionRow(title: "Camera", status: permissionTitle(permissions.camera)) {
                Button("Open System Settings…", action: openCameraSettings)
                    .accessibilityLabel("Open Camera Settings")
            }
            .settingsControlAnchor(.voiceCameraPermission, state: state)

        } header: {
            Text("Permissions", bundle: #bundle)
        }
    }
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
