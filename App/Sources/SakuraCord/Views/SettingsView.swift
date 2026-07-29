import MediaPipeline
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @ObservedObject var updateController: AppUpdateController
    @AppStorage("sendWithReturn") private var sendWithReturn = true
    @AppStorage("mediaCacheLimit") private var mediaCacheLimit = 2_147_483_648
    @AppStorage("reduceAnimatedMedia") private var reduceAnimatedMedia = false
    @AppStorage("voiceInputDeviceUID") private var inputDeviceUID = ""
    @AppStorage("voiceOutputDeviceUID") private var outputDeviceUID = ""
    @AppStorage("voiceCameraUID") private var cameraUID = ""
    @AppStorage("voiceInputVolume") private var inputVolume = 1.0
    @AppStorage("voiceOutputVolume") private var outputVolume = 1.0
    @State private var mediaDevices: MediaDeviceSnapshot = .empty
    @State private var notificationPermission = "Checking…"

    var body: some View {
        @Bindable var notificationPreferences = model.notificationPreferences
        TabView {
            Form {
                Section("Messages and media") {
                    Toggle("Press Return to send messages", isOn: $sendWithReturn)
                    Toggle("Reduce animated media", isOn: $reduceAnimatedMedia)
                }

                Section("Software updates") {
                    Toggle(
                        "Automatically check for updates",
                        isOn: Binding(
                            get: {
                                updateController.automaticallyChecksForUpdates
                            },
                            set: {
                                updateController.setAutomaticallyChecksForUpdates($0)
                            }
                        )
                    )
                    .disabled(!updateController.isEnabled)
                    .accessibilityHint(
                        "Uses SakuraCord’s signed update feed on the configured schedule."
                    )

                    Toggle(
                        "Automatically download updates",
                        isOn: Binding(
                            get: {
                                updateController.automaticallyDownloadsUpdates
                            },
                            set: {
                                updateController.setAutomaticallyDownloadsUpdates($0)
                            }
                        )
                    )
                    .disabled(
                        !updateController.isEnabled
                            || !updateController.allowsAutomaticUpdates
                    )
                    .accessibilityHint(
                        "Downloaded updates remain cryptographically verified before installation."
                    )

                    LabeledContent("Update status") {
                        Text(updateController.availabilityDescription)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }

                    Button("Check for Updates…") {
                        updateController.checkForUpdates()
                    }
                    .disabled(!updateController.canCheckForUpdates)
                    .accessibilityHint(updateController.availabilityDescription)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("Media cache", selection: $mediaCacheLimit) {
                    Text("512 MB").tag(536_870_912)
                    Text("2 GB").tag(2_147_483_648)
                    Text("5 GB").tag(5_368_709_120)
                    Text("10 GB").tag(10_737_418_240)
                }
                Text("Credentials are stored only in the macOS Keychain. Cached message data never contains the account credential.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Storage", systemImage: "internaldrive") }

            Form {
                LabeledContent("System permission") {
                    Text(notificationPermission)
                        .foregroundStyle(.secondary)
                    Button("Request Permission") {
                        Task {
                            _ = await model.requestNotificationPermission()
                            await updateNotificationPermission()
                        }
                    }
                }
                Toggle("Enable native notifications", isOn: $notificationPreferences.isEnabled)
                Picker("Notification previews", selection: $notificationPreferences.previewStyle) {
                    ForEach(NotificationPreviewStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Play sound", isOn: $notificationPreferences.playsSound)
                Toggle("Show unread mentions in Dock", isOn: $notificationPreferences.showsDockBadge)
                Toggle("Quiet hours", isOn: $notificationPreferences.quietHoursEnabled)
                if notificationPreferences.quietHoursEnabled {
                    Stepper(
                        "Start: \(notificationPreferences.quietStartHour):00",
                        value: $notificationPreferences.quietStartHour,
                        in: 0 ... 23
                    )
                    Stepper(
                        "End: \(notificationPreferences.quietEndHour):00",
                        value: $notificationPreferences.quietEndHour,
                        in: 0 ... 23
                    )
                }
                Text("Discord’s server and channel notification settings remain authoritative. These controls only narrow local macOS presentation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Notifications", systemImage: "bell") }
            .task { await updateNotificationPermission() }
            .onChange(of: notificationPreferences.showsDockBadge) {
                model.refreshDockBadge()
            }

            Form {
                Picker("Input device", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(mediaDevices.audioInputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Output device", selection: $outputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(mediaDevices.audioOutputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Camera", selection: $cameraUID) {
                    Text("System Default").tag("")
                    ForEach(mediaDevices.cameras) { camera in
                        Text(camera.name).tag(camera.uniqueID)
                    }
                }
                LabeledContent("Input volume") {
                    Slider(value: $inputVolume, in: 0 ... 2)
                    Text("\(Int(inputVolume * 100))%")
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
                LabeledContent("Output volume") {
                    Slider(value: $outputVolume, in: 0 ... 2)
                    Text("\(Int(outputVolume * 100))%")
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Voice & Video", systemImage: "waveform.and.mic") }
            .task {
                mediaDevices = await Task.detached(priority: .userInitiated) {
                    MediaDeviceCatalog.snapshot()
                }.value
            }
            .onChange(of: inputDeviceUID) { _, uid in
                let device = mediaDevices.audioInputs.first { $0.uid == uid }
                Task { await model.selectInputDevice(device) }
            }
            .onChange(of: outputDeviceUID) { _, uid in
                let device = mediaDevices.audioOutputs.first { $0.uid == uid }
                Task { await model.selectOutputDevice(device) }
            }
            .onChange(of: cameraUID) { _, uid in
                let camera = mediaDevices.cameras.first { $0.uniqueID == uid }
                Task { await model.selectCamera(camera) }
            }
            .onChange(of: inputVolume) { _, value in
                Task { await model.updateInputVolume(Float(value)) }
            }
            .onChange(of: outputVolume) { _, value in
                Task { await model.updateOutputVolume(Float(value)) }
            }

            Form {
                Text("Plugins will run in a sandboxed WebAssembly host. This foundation build exposes the manifest and permission model but does not execute plugins yet.")
                    .font(.callout)
            }
            .formStyle(.grouped)
            .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 620, height: 470)
    }

    private func updateNotificationPermission() async {
        notificationPermission =
            switch await model.notificationAuthorizationStatus() {
            case .authorized, .provisional, .ephemeral: "Allowed"
            case .denied: "Denied in System Settings"
            case .notDetermined: "Not requested"
            @unknown default: "Unknown"
            }
    }
}
