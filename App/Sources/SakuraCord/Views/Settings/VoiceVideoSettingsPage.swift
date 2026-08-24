import MediaPipeline
import SwiftUI

struct VoiceVideoSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var inputDeviceUID =
        UserDefaults.standard.string(forKey: "voiceInputDeviceUID") ?? ""
    @State private var outputDeviceUID =
        UserDefaults.standard.string(forKey: "voiceOutputDeviceUID") ?? ""
    @AppStorage("voiceCameraUID") private var cameraUID = ""
    @AppStorage("voiceInputVolume") private var inputVolume = 1.0
    @AppStorage("voiceOutputVolume") private var outputVolume = 1.0

    var body: some View {
        SettingsPageForm(page: .voiceVideo, state: state) {
            VoiceDevicesSettingsSection(
                audioInputs: model.mediaDevices.audioInputs,
                audioOutputs: model.mediaDevices.audioOutputs,
                cameras: model.mediaDevices.cameras,
                statusMessage: model.voiceDeviceStatusMessage,
                inputDeviceUID: $inputDeviceUID,
                outputDeviceUID: $outputDeviceUID,
                cameraUID: $cameraUID,
                state: state
            )
            VoiceLevelsSettingsSection(
                inputVolume: $inputVolume,
                outputVolume: $outputVolume,
                state: state
            )
        }
        .task {
            await model.refreshMediaDevices()
        }
        .onChange(of: inputDeviceUID) { _, uid in
            guard uid != (UserDefaults.standard.string(
                forKey: "voiceInputDeviceUID"
            ) ?? "") else { return }
            let device = model.mediaDevices.audioInputs.first { $0.uid == uid }
            Task {
                guard await model.selectInputDevice(device) else {
                    inputDeviceUID = UserDefaults.standard.string(
                        forKey: "voiceInputDeviceUID"
                    ) ?? ""
                    return
                }
            }
        }
        .onChange(of: outputDeviceUID) { _, uid in
            guard uid != (UserDefaults.standard.string(
                forKey: "voiceOutputDeviceUID"
            ) ?? "") else { return }
            let device = model.mediaDevices.audioOutputs.first { $0.uid == uid }
            Task {
                guard await model.selectOutputDevice(device) else {
                    outputDeviceUID = UserDefaults.standard.string(
                        forKey: "voiceOutputDeviceUID"
                    ) ?? ""
                    return
                }
            }
        }
        .onChange(of: cameraUID) { _, uid in
            let camera = model.mediaDevices.cameras.first { $0.uniqueID == uid }
            Task { await model.selectCamera(camera) }
        }
        .onChange(of: inputVolume) { _, value in
            Task { await model.updateInputVolume(Float(value)) }
        }
        .onChange(of: outputVolume) { _, value in
            Task { await model.updateOutputVolume(Float(value)) }
        }
        .onChange(of: model.mediaDevices) {
            inputDeviceUID = UserDefaults.standard.string(
                forKey: "voiceInputDeviceUID"
            ) ?? ""
            outputDeviceUID = UserDefaults.standard.string(
                forKey: "voiceOutputDeviceUID"
            ) ?? ""
        }
    }
}

private struct VoiceDevicesSettingsSection: View {
    let audioInputs: [AudioDeviceInfo]
    let audioOutputs: [AudioDeviceInfo]
    let cameras: [CameraDeviceInfo]
    let statusMessage: String?
    @Binding var inputDeviceUID: String
    @Binding var outputDeviceUID: String
    @Binding var cameraUID: String
    let state: SettingsViewState

    var body: some View {
        Section {
            Picker("Input device", selection: $inputDeviceUID) {
                Text(systemDefaultAudioDeviceLabel(audioInputs)).tag("")
                ForEach(audioInputs) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .settingsControlAnchor(.voiceInputDevice, state: state)

            Picker("Output device", selection: $outputDeviceUID) {
                Text(systemDefaultAudioDeviceLabel(audioOutputs)).tag("")
                ForEach(audioOutputs) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .settingsControlAnchor(.voiceOutputDevice, state: state)

            Picker("Camera", selection: $cameraUID) {
                Text("System Default").tag("")
                ForEach(cameras) { camera in
                    Text(camera.name).tag(camera.uniqueID)
                }
            }
            .settingsControlAnchor(.voiceCamera, state: state)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Devices", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
    }
}

private struct VoiceLevelsSettingsSection: View {
    @Binding var inputVolume: Double
    @Binding var outputVolume: Double
    let state: SettingsViewState

    var body: some View {
        Section {
            LabeledContent("Input volume") {
                Slider(value: $inputVolume, in: 0 ... 2)
                Text("\(Int(inputVolume * 100))%")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            .settingsControlAnchor(.voiceInputVolume, state: state)

            LabeledContent("Output volume") {
                Slider(value: $outputVolume, in: 0 ... 2)
                Text("\(Int(outputVolume * 100))%")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            .settingsControlAnchor(.voiceOutputVolume, state: state)
        } header: {
            Text("Levels", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
    }
}

private func systemDefaultAudioDeviceLabel(_ devices: [AudioDeviceInfo]) -> String {
    guard let device = devices.first(where: \.isDefault) else { return "System Default" }
    return "System Default (\(device.name))"
}
