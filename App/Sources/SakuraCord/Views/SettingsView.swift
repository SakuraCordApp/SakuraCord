import DiscordProtocol
import MediaPipeline
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @ObservedObject var updateController: AppUpdateController
    @AppStorage("sendWithReturn") private var sendWithReturn = true
    @AppStorage("mediaCacheLimit") private var mediaCacheLimit = 2_147_483_648
    @AppStorage("reduceAnimatedMedia") private var reduceAnimatedMedia = false
    @State private var inputDeviceUID =
        UserDefaults.standard.string(forKey: "voiceInputDeviceUID") ?? ""
    @State private var outputDeviceUID =
        UserDefaults.standard.string(forKey: "voiceOutputDeviceUID") ?? ""
    @AppStorage("voiceCameraUID") private var cameraUID = ""
    @AppStorage("voiceInputVolume") private var inputVolume = 1.0
    @AppStorage("voiceOutputVolume") private var outputVolume = 1.0
    @AppStorage("saveAPIDiagnosticsToDisk") private var savesAPIDiagnosticsToDisk = false
    @State private var notificationPermission = "Checking…"
    @State private var apiDiagnosticEntryCount = 0
    @State private var apiDiagnosticStatus: String?
    @State private var capturesDetailedAPIPayloads =
        DiscordAPIDiagnosticStore.shared.capturesPayloadDetails

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
                    Text(systemDefaultAudioDeviceLabel(model.mediaDevices.audioInputs)).tag("")
                    ForEach(model.mediaDevices.audioInputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Output device", selection: $outputDeviceUID) {
                    Text(systemDefaultAudioDeviceLabel(model.mediaDevices.audioOutputs)).tag("")
                    ForEach(model.mediaDevices.audioOutputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Camera", selection: $cameraUID) {
                    Text("System Default").tag("")
                    ForEach(model.mediaDevices.cameras) { camera in
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
                if let status = model.voiceDeviceStatusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Voice & Video", systemImage: "waveform.and.mic") }
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

            Form {
                Text("Plugins will run in a sandboxed WebAssembly host. This foundation build exposes the manifest and permission model but does not execute plugins yet.")
                    .font(.callout)
            }
            .formStyle(.grouped)
            .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }

            Form {
                Section("Discord API logs") {
                    Toggle(
                        "Capture detailed sanitized payloads",
                        isOn: $capturesDetailedAPIPayloads
                    )
                    .onChange(of: capturesDetailedAPIPayloads) { _, captures in
                        DiscordAPIDiagnosticStore.shared.capturesPayloadDetails =
                            captures
                    }

                    Toggle(
                        "Save diagnostics to disk",
                        isOn: $savesAPIDiagnosticsToDisk
                    )
                    .onChange(of: savesAPIDiagnosticsToDisk) { _, savesToDisk in
                        updateDiskLogging(savesToDisk)
                    }

                    LabeledContent("Retained entries") {
                        Text(apiDiagnosticEntryCount.formatted())
                            .monospacedDigit()
                    }

                    Text(
                        "Exports retained Discord REST, attachment, authentication, and Gateway request/response metadata from this app session. "
                            + "Detailed sanitized payload capture is off by default because processing large responses increases CPU and energy use. "
                            + "Message text, names, usernames, profile text, credentials, cookies, challenge data, filenames, and URLs are discarded before logging. "
                            + "IDs, nonces, request IDs, and rate-limit bucket IDs are always redacted. "
                            + "Disk capture is off by default and keeps at most four private JSON Lines session files of up to 64 MiB each in Application Support/SakuraCord/Diagnostics."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Button("Export API Logs…") {
                            Task { await exportAPILogs() }
                        }
                        Button("Clear Logs", role: .destructive) {
                            clearAPILogs()
                        }
                    }

                    if let apiDiagnosticStatus {
                        Text(apiDiagnosticStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            .task {
                refreshAPIDiagnosticCount()
            }
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

    private func refreshAPIDiagnosticCount() {
        apiDiagnosticEntryCount =
            DiscordAPIDiagnosticStore.shared.retainedEntryCount
    }

    private func clearAPILogs() {
        let store = DiscordAPIDiagnosticStore.shared
        let wasSavingToDisk = store.savesDiagnosticsToDisk
        do {
            try store.clearMemoryAndDisk()
            apiDiagnosticEntryCount = 0
            if wasSavingToDisk, let fileURL = store.currentDiskLogURL {
                apiDiagnosticStatus =
                    "Retained and saved API logs were cleared. Saving continues to \(fileURL.lastPathComponent)."
            } else {
                apiDiagnosticStatus = "Retained and saved API logs were cleared."
            }
        } catch {
            savesAPIDiagnosticsToDisk = store.savesDiagnosticsToDisk
            apiDiagnosticStatus =
                "Could not clear every saved API log: \(error.localizedDescription)"
        }
    }

    private func updateDiskLogging(_ savesToDisk: Bool) {
        do {
            try DiscordAPIDiagnosticStore.shared
                .setSavesDiagnosticsToDisk(savesToDisk)
            if savesToDisk,
               let fileURL = DiscordAPIDiagnosticStore.shared.currentDiskLogURL
            {
                apiDiagnosticStatus = "Saving diagnostics to \(fileURL.lastPathComponent)"
            } else {
                apiDiagnosticStatus = "Diagnostics are no longer being saved to disk."
            }
        } catch {
            savesAPIDiagnosticsToDisk = false
            apiDiagnosticStatus =
                "Could not save diagnostics to disk: \(error.localizedDescription)"
        }
    }

    private func exportAPILogs() async {
        do {
            guard let url = try await DiscordAPILogExporter.export() else {
                apiDiagnosticStatus = "Export cancelled."
                refreshAPIDiagnosticCount()
                return
            }
            apiDiagnosticStatus = "Exported \(url.lastPathComponent)"
        } catch {
            apiDiagnosticStatus = "Export failed: \(error.localizedDescription)"
        }
        refreshAPIDiagnosticCount()
    }
}

private func systemDefaultAudioDeviceLabel(_ devices: [AudioDeviceInfo]) -> String {
    guard let device = devices.first(where: \.isDefault) else { return "System Default" }
    return "System Default (\(device.name))"
}
