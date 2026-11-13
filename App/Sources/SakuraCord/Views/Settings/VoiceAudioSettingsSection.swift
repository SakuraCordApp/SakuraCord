import CoreAudio
import MediaPipeline
import SwiftUI

struct VoiceAudioSettingsSection: View {
    let model: AppModel
    let tests: VoiceVideoTestController
    let state: SettingsViewState
    let refresh: () -> Void

    var body: some View {
        Section {
            Picker("Microphone", selection: inputSelection) {
                Text(systemDefaultLabel(model.mediaDevices.audioInputs)).tag("")
                ForEach(model.mediaDevices.audioInputs) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .disabled(tests.isMicrophoneRouteChanging)
            .settingsControlAnchor(.voiceInputDevice, state: state)

            VoiceVolumeSettingsRow(title: "Microphone volume", volume: inputVolume)
                .settingsControlAnchor(.voiceInputVolume, state: state)

            Picker("Speaker", selection: outputSelection) {
                Text(systemDefaultLabel(model.mediaDevices.audioOutputs)).tag("")
                ForEach(model.mediaDevices.audioOutputs) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .disabled(tests.isMicrophoneRouteChanging)
            .settingsControlAnchor(.voiceOutputDevice, state: state)

            VoiceVolumeSettingsRow(title: "Speaker volume", volume: outputVolume)
                .settingsControlAnchor(.voiceOutputVolume, state: state)

            VoiceMicrophoneTestRow(model: model, tests: tests, state: state)
        } header: {
            HStack {
                Text("Voice", bundle: #bundle)
                Spacer()
                Button("Refresh Devices", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Refresh devices")
                    .settingsControlAnchor(.voiceRefreshDevices, state: state)
            }
        }
        .onChange(of: model.voiceVideoPreferences.inputVolume) { updateTestVolumes() }
        .onChange(of: model.voiceVideoPreferences.outputVolume) { updateTestVolumes() }
    }

    private var inputSelection: Binding<String> {
        Binding(
            get: { model.voiceVideoPreferences.inputDeviceUID },
            set: { uid in
                let device = model.mediaDevices.audioInputs.first { $0.uid == uid }
                Task {
                    guard await tests.selectMicrophoneTestInput(device?.id) else { return }
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
                let device = model.mediaDevices.audioOutputs.first { $0.uid == uid }
                Task {
                    guard await tests.selectMicrophoneTestOutput(device?.id) else { return }
                    if !(await model.selectOutputDevice(device)) {
                        tests.errorMessage = model.voiceErrorMessage
                    }
                }
            }
        )
    }

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

    private func updateTestVolumes() {
        tests.updateTestVolumes(
            input: Float(model.voiceVideoPreferences.inputVolume),
            output: Float(model.voiceVideoPreferences.outputVolume)
        )
    }
}

private struct VoiceVolumeSettingsRow: View {
    let title: LocalizedStringKey
    @Binding var volume: Double

    var body: some View {
        LabeledContent {
            Slider(value: $volume, in: 0 ... 2) {
                Text(title, bundle: #bundle)
            }
            .labelsHidden()
            Text(volume, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: InterfaceScale.metric(46), alignment: .trailing)
        } label: {
            Text(title, bundle: #bundle)
        }
    }
}

private func systemDefaultLabel(_ devices: [AudioDeviceInfo]) -> String {
    guard let device = devices.first(where: \.isDefault) else { return "System Default" }
    return "System Default (\(device.name))"
}

private struct VoiceMicrophoneTestRow: View {
    let model: AppModel
    let tests: VoiceVideoTestController
    let state: SettingsViewState

    var body: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            VoiceMicrophoneLevelMeter(tests: tests)
            Spacer(minLength: InterfaceScale.metric(12))
            Button(tests.isMicrophoneTestRunning || tests.isMicrophoneTestStarting ? "Stop Test" : "Test Microphone") {
                toggleTest()
            }
            .buttonStyle(.bordered)
            .disabled(model.activeVoiceChannel != nil)
            .help(model.activeVoiceChannel != nil
                ? "Mic test is unavailable during a call."
                : "Hear your microphone through the selected speaker with a short delay.")
        }
        .settingsControlAnchor(.voiceMicrophoneTest, state: state)
    }

    private func toggleTest() {
        if tests.isMicrophoneTestRunning || tests.isMicrophoneTestStarting {
            tests.stopMicrophoneTest()
            return
        }
        let preferences = model.voiceVideoPreferences
        let inputID = model.mediaDevices.audioInputs.first { $0.uid == preferences.inputDeviceUID }?.id
        let outputID = model.mediaDevices.audioOutputs.first { $0.uid == preferences.outputDeviceUID }?.id
        Task {
            await tests.startMicrophoneTest(
                inputDeviceID: inputID,
                outputDeviceID: outputID,
                inputVolume: Float(preferences.inputVolume),
                outputVolume: Float(preferences.outputVolume)
            )
        }
    }
}

private struct VoiceMicrophoneLevelMeter: View {
    let tests: VoiceVideoTestController

    var body: some View {
        let level = CGFloat(tests.microphoneLevel)
        Canvas { context, size in
            let count = max(1, Int(size.width / 6))
            let spacing: CGFloat = InterfaceScale.metric(2)
            let width = (size.width - CGFloat(count - 1) * spacing) / CGFloat(count)
            let activeCount = Int((level * CGFloat(count)).rounded(.up))
            for index in 0 ..< count {
                let rect = CGRect(x: CGFloat(index) * (width + spacing), y: 0, width: width, height: size.height)
                let strip = Path(roundedRect: rect, cornerRadius: width / 2)
                context.fill(strip, with: .color(index < activeCount
                    ? SakuraCordAccentColor.color
                    : Color.secondary.opacity(0.25)))
            }
        }
        .frame(width: InterfaceScale.metric(520), height: InterfaceScale.metric(16))
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(Text(Double(level), format: .percent.precision(.fractionLength(0))))
    }
}
