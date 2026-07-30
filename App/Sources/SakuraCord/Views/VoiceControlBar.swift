import Foundation
import MediaPipeline
import SwiftUI

struct VoiceControlBar<SettingsControl: View>: View {
    let model: AppModel
    let settingsControl: SettingsControl
    @State private var showConnectionDetails = false
    @State private var showInputControls = false
    @State private var showOutputControls = false
    @State private var showCameraControls = false

    init(model: AppModel, @ViewBuilder settingsControl: () -> SettingsControl) {
        self.model = model
        self.settingsControl = settingsControl()
    }

    var body: some View {
        VStack(spacing: 9) {
            connectionRow
            controlRow
        }
        .padding(.horizontal, 9)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .task { await model.refreshMediaDevices() }
    }

    private var connectionRow: some View {
        HStack(spacing: 7) {
            Image(systemName: connectionSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                Text(connectionSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 3)

            Button {
                showConnectionDetails.toggle()
            } label: {
                Image(systemName: "cellularbars")
                    .font(.callout.weight(.medium))
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(.plain)
            .foregroundStyle(statusColor)
            .help("Voice Details")
            .popover(isPresented: $showConnectionDetails, arrowEdge: .trailing) {
                VoiceConnectionDetails(model: model, statusLabel: statusLabel, statusColor: statusColor)
            }

            Button(role: .destructive) {
                Task { await model.leaveVoice() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.callout.weight(.semibold))
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(hex: 0xDA373C))
            .help("Disconnect")
        }
    }

    private var controlRow: some View {
        HStack(spacing: 7) {
            VoiceSplitButton(
                systemImage: model.isCameraEnabled ? "video.fill" : "video.slash.fill",
                isAlert: !model.isCameraEnabled,
                isDisabled: model.voiceSessionState != .connected,
                primaryHelp: model.isCameraEnabled ? "Turn Off Camera" : "Turn On Camera",
                secondaryHelp: "Camera Device",
                primaryAction: { Task { await model.toggleCamera() } },
                secondaryAction: { showCameraControls.toggle() }
            )
            .popover(isPresented: $showCameraControls, arrowEdge: .trailing) {
                VoiceCameraControls(model: model)
            }
            .contextMenu { cameraMenu }

            VoiceSplitButton(
                systemImage: model.isVoiceMuted ? "mic.slash.fill" : "mic.fill",
                isAlert: model.isVoiceMuted,
                primaryHelp: model.isVoiceMuted ? "Unmute" : "Mute",
                secondaryHelp: "Input Device and Volume",
                primaryAction: { Task { await model.toggleVoiceMute() } },
                secondaryAction: { showInputControls.toggle() }
            )
            .popover(isPresented: $showInputControls, arrowEdge: .trailing) {
                VoiceInputControls(model: model)
            }

            VoiceSplitButton(
                systemImage: model.isVoiceDeafened ? "headphones.slash" : "headphones",
                isAlert: model.isVoiceDeafened,
                primaryHelp: model.isVoiceDeafened ? "Undeafen" : "Deafen",
                secondaryHelp: "Output Device and Volume",
                primaryAction: { Task { await model.toggleVoiceDeafen() } },
                secondaryAction: { showOutputControls.toggle() }
            )
            .popover(isPresented: $showOutputControls, arrowEdge: .trailing) {
                VoiceOutputControls(model: model)
            }

            settingsControl
                .frame(width: 34, height: 34)
                .contentShape(ConcentricRectangle(cornerRadius: 8, style: .continuous))
                .background(Color.primary.opacity(0.045), in: ConcentricRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var cameraMenu: some View {
        Button("System Default") { Task { await model.selectCamera(nil) } }
        Divider()
        ForEach(model.mediaDevices.cameras) { camera in
            Button {
                Task { await model.selectCamera(camera) }
            } label: {
                if camera.uniqueID == UserDefaults.standard.string(forKey: "voiceCameraUID") {
                    Label(camera.name, systemImage: "checkmark")
                } else {
                    Text(camera.name)
                }
            }
        }
        Divider()
        SettingsLink { Label("Voice & Video Settings…", systemImage: "gearshape") }
    }

    private var connectionSubtitle: String {
        let channel = model.activeVoiceChannel?.name ?? "Voice"
        guard let guildID = model.activeVoiceChannel?.guildID,
              let guild = model.snapshot?.guilds.first(where: { $0.id == guildID })
        else {
            return channel
        }
        return "\(channel) / \(guild.name)"
    }

    private var connectionSymbol: String {
        switch model.voiceSessionState {
        case .connected: "wave.3.right.circle.fill"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "wave.3.right.circle"
        }
    }

    private var statusLabel: String {
        switch model.voiceSessionState {
        case .idle: "Voice Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Voice Connected"
        case .reconnecting: "Reconnecting…"
        case .disconnecting: "Disconnecting…"
        case .disconnected: "Disconnected"
        case .failed: "Connection Failed"
        }
    }

    private var statusColor: Color {
        switch model.voiceSessionState {
        case .connected: Color(hex: 0x23A55A)
        case .connecting, .reconnecting: Color(hex: 0xF0B232)
        case .failed: Color(hex: 0xDA373C)
        default: .secondary
        }
    }
}

struct VoiceSidebarStatus: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                Text(connectionSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(role: .destructive) {
                Task { await model.leaveVoice() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(hex: 0xDA373C))
            .help("Disconnect")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
    }

    private var connectionSubtitle: String {
        let channel = model.activeVoiceChannel?.name ?? "Voice"
        guard let guildID = model.activeVoiceChannel?.guildID,
              let guild = model.snapshot?.guilds.first(where: { $0.id == guildID })
        else {
            return channel
        }
        return "\(channel) / \(guild.name)"
    }

    private var statusLabel: String {
        switch model.voiceSessionState {
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .failed: "Connection Failed"
        default: "Voice Connected"
        }
    }

    private var statusColor: Color {
        switch model.voiceSessionState {
        case .connecting, .reconnecting: Color(hex: 0xF0B232)
        case .failed: Color(hex: 0xDA373C)
        default: Color(hex: 0x23A55A)
        }
    }
}

struct VoiceCallControlDock: View {
    let model: AppModel
    @State private var showInputControls = false
    @State private var showOutputControls = false
    @State private var showCameraControls = false

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                CallDockSplitButton(
                    title: model.isCameraEnabled ? "Stop Video" : "Start Video",
                    systemImage: model.isCameraEnabled ? "video.slash.fill" : "video.fill",
                    isAlert: false,
                    isDisabled: model.voiceSessionState != .connected,
                    primaryAction: { Task { await model.toggleCamera() } },
                    secondaryAction: { showCameraControls.toggle() }
                )
                .popover(isPresented: $showCameraControls, arrowEdge: .bottom) {
                    VoiceCameraControls(model: model)
                }
                .contextMenu { cameraMenu }

                CallDockSplitButton(
                    title: model.isVoiceMuted ? "Unmute" : "Mute",
                    systemImage: model.isVoiceMuted ? "mic.slash.fill" : "mic.fill",
                    isAlert: model.isVoiceMuted,
                    primaryAction: { Task { await model.toggleVoiceMute() } },
                    secondaryAction: { showInputControls.toggle() }
                )
                .popover(isPresented: $showInputControls, arrowEdge: .bottom) {
                    VoiceInputControls(model: model)
                }

                CallDockSplitButton(
                    title: model.isVoiceDeafened ? "Undeafen" : "Deafen",
                    systemImage: model.isVoiceDeafened ? "headphones.slash" : "headphones",
                    isAlert: model.isVoiceDeafened,
                    primaryAction: { Task { await model.toggleVoiceDeafen() } },
                    secondaryAction: { showOutputControls.toggle() }
                )
                .popover(isPresented: $showOutputControls, arrowEdge: .bottom) {
                    VoiceOutputControls(model: model)
                }

                Button(role: .destructive) {
                    Task { await model.leaveVoice() }
                } label: {
                    Label("Leave", systemImage: "phone.down.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 15)
                        .frame(height: 40)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(
                    .regular.tint(Color(hex: 0xDA373C)).interactive(),
                    in: Capsule()
                )
                .help("Disconnect")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var cameraMenu: some View {
        Button("System Default") { Task { await model.selectCamera(nil) } }
        Divider()
        ForEach(model.mediaDevices.cameras) { camera in
            Button {
                Task { await model.selectCamera(camera) }
            } label: {
                if camera.uniqueID == UserDefaults.standard.string(forKey: "voiceCameraUID") {
                    Label(camera.name, systemImage: "checkmark")
                } else {
                    Text(camera.name)
                }
            }
        }
        Divider()
        SettingsLink { Label("Voice & Video Settings…", systemImage: "gearshape") }
    }
}

private struct CallDockButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .help(title)
    }
}

private struct CallDockSplitButton: View {
    let title: String
    let systemImage: String
    let isAlert: Bool
    var isDisabled = false
    let primaryAction: () -> Void
    let secondaryAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primaryAction) {
                Label(title, systemImage: systemImage)
                    .font(.callout.weight(.medium))
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .frame(height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 22)

            Button(action: secondaryAction) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 28, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(isAlert ? Color(hex: 0xF23F43) : Color.primary)
        .glassEffect(
            isAlert ? .regular.tint(Color(hex: 0xF23F43).opacity(0.18)).interactive() : .regular.interactive(),
            in: Capsule()
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
    }
}

private struct VoiceSquareButton: View {
    let systemImage: String
    let isAlert: Bool
    var isDisabled = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAlert ? Color(hex: 0xF23F43) : Color.primary)
        .background(buttonBackground, in: ConcentricRectangle(cornerRadius: 8, style: .continuous))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .help(help)
    }

    private var buttonBackground: Color {
        isAlert ? Color(hex: 0xF23F43).opacity(0.14) : Color.primary.opacity(0.045)
    }
}

private struct VoiceSplitButton: View {
    let systemImage: String
    let isAlert: Bool
    var isDisabled = false
    let primaryHelp: String
    let secondaryHelp: String
    let primaryAction: () -> Void
    let secondaryAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primaryAction) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 35, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(primaryHelp)

            Rectangle()
                .fill(isAlert ? Color(hex: 0xF23F43).opacity(0.25) : Color.primary.opacity(0.12))
                .frame(width: 1, height: 20)

            Button(action: secondaryAction) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(secondaryHelp)
        }
        .foregroundStyle(isAlert ? Color(hex: 0xF23F43) : Color.primary)
        .background(buttonBackground, in: ConcentricRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(ConcentricRectangle(cornerRadius: 8, style: .continuous))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
    }

    private var buttonBackground: Color {
        isAlert ? Color(hex: 0xF23F43).opacity(0.14) : Color.primary.opacity(0.045)
    }
}

private struct VoiceConnectionDetails: View {
    let model: AppModel
    let statusLabel: String
    let statusColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusLabel).font(.headline)
            }
            Divider()
            LabeledContent("Channel", value: model.activeVoiceChannel?.name ?? "Voice")
            LabeledContent("Encryption", value: encryptionLabel)
            LabeledContent("Latency", value: latencyLabel)
            LabeledContent("Participants", value: "\(max(1, model.voiceParticipants.count + 1))")
            if let error = model.voiceErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0xDA373C))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .padding(16)
        .frame(width: 260)
    }

    private var encryptionLabel: String {
        model.voiceEncryptionVersion.map { "DAVE v\($0)" } ?? "Negotiating"
    }

    private var latencyLabel: String {
        model.voiceLatencyMilliseconds.map { "\($0) ms" } ?? "Measuring"
    }
}

private struct VoiceInputControls: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Input").font(.headline)
            VoiceDevicePicker(
                title: "Input Device",
                systemImage: "mic",
                devices: model.mediaDevices.audioInputs,
                selectedUID: UserDefaults.standard.string(forKey: "voiceInputDeviceUID"),
                select: { device in Task { await model.selectInputDevice(device) } }
            )
            VolumeControl(
                title: "Input Volume",
                systemImage: "mic.fill",
                value: Binding(
                    get: { Double(model.inputVolume) },
                    set: { value in Task { await model.updateInputVolume(Float(value)) } }
                )
            )
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct VoiceOutputControls: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Output").font(.headline)
            VoiceDevicePicker(
                title: "Output Device",
                systemImage: "speaker.wave.2",
                devices: model.mediaDevices.audioOutputs,
                selectedUID: UserDefaults.standard.string(forKey: "voiceOutputDeviceUID"),
                select: { device in Task { await model.selectOutputDevice(device) } }
            )
            VolumeControl(
                title: "Output Volume",
                systemImage: "speaker.wave.2.fill",
                value: Binding(
                    get: { Double(model.outputVolume) },
                    set: { value in Task { await model.updateOutputVolume(Float(value)) } }
                )
            )
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct VoiceCameraControls: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Camera").font(.headline)
            CameraDevicePicker(
                devices: model.mediaDevices.cameras,
                selectedUID: UserDefaults.standard.string(forKey: "voiceCameraUID"),
                select: { camera in Task { await model.selectCamera(camera) } }
            )
        }
        .padding(16)
        .frame(width: 300)
        .task { await model.refreshMediaDevices() }
    }
}

private struct VolumeControl: View {
    let title: String
    let systemImage: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text("\(Int(value * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: $value, in: 0 ... 2)
        }
    }
}

private struct VoiceDevicePicker: View {
    let title: String
    let systemImage: String
    let devices: [AudioDeviceInfo]
    let select: (AudioDeviceInfo?) -> Void
    @State private var selectionUID: String

    init(
        title: String,
        systemImage: String,
        devices: [AudioDeviceInfo],
        selectedUID: String?,
        select: @escaping (AudioDeviceInfo?) -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.devices = devices
        self.select = select
        _selectionUID = State(initialValue: selectedUID ?? "")
    }

    var body: some View {
        LabeledContent {
            Picker(title, selection: $selectionUID) {
                Text("System Default").tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 170)
            .onChange(of: selectionUID) { _, uid in
                select(devices.first(where: { $0.uid == uid }))
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout)
        }
    }
}

private struct CameraDevicePicker: View {
    let devices: [CameraDeviceInfo]
    let select: (CameraDeviceInfo?) -> Void
    @State private var selectionUID: String

    init(
        devices: [CameraDeviceInfo],
        selectedUID: String?,
        select: @escaping (CameraDeviceInfo?) -> Void
    ) {
        self.devices = devices
        self.select = select
        _selectionUID = State(initialValue: selectedUID ?? "")
    }

    var body: some View {
        LabeledContent {
            Picker("Camera Device", selection: $selectionUID) {
                Text("System Default").tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.uniqueID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 170)
            .onChange(of: selectionUID) { _, uid in
                select(devices.first(where: { $0.uniqueID == uid }))
            }
        } label: {
            Label("Camera Device", systemImage: "video")
                .font(.callout)
        }
    }
}
