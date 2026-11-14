import Foundation
import MediaPipeline
import SwiftUI

struct VoiceSidebarControlPanel: View {
    let model: AppModel
    let navigateToChannel: () -> Void
    @State private var isHeaderHovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: navigateToChannel) {
                HStack(spacing: InterfaceScale.metric(9)) {
                    Image(systemName: statusSymbol)
                        .font(.interfaceSystem(size: 18, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: InterfaceScale.metric(24))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(statusLabel)
                            .font(.interfaceSystem(size: 12, weight: .bold))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                        Text(connectionSubtitle)
                            .font(.interface(.caption))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        connectionDuration
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, InterfaceScale.metric(12))
                .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(54), alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    Color.primary.opacity(isHeaderHovering ? 0.09 : 0)
                )
            }
            .buttonStyle(.plain)
            .onModalHover { hovering in
                withAnimation(.snappy(duration: 0.14)) {
                    isHeaderHovering = hovering
                }
            }
            .help("Open \(connectionSubtitle)")

            GeometryReader { proxy in
                let spacing = Self.controlSpacing(for: proxy.size.width)
                let diameter = Self.controlDiameter(
                    for: proxy.size.width,
                    spacing: spacing
                )

                HStack(spacing: spacing) {
                    SidebarVoiceGlassButton(
                        systemImage: model.localApplicationStreamKey == nil
                            ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash",
                        help: model.localApplicationStreamKey == nil
                            ? "Share Screen" : "Screen Share Options",
                        diameter: diameter,
                        tintColor: model.localApplicationStreamKey != nil
                            ? Color(hex: 0x5865F2) : nil,
                        isDisabled: model.voiceSessionState != .connected
                            && model.localApplicationStreamKey == nil
                    ) {
                        Task { await model.presentScreenSharePreview() }
                    }

                    SidebarVoiceGlassButton(
                        systemImage: model.isCameraEnabled
                            ? "video.fill" : "video.slash.fill",
                        help: model.isCameraEnabled
                            ? "Turn Off Camera" : "Turn On Camera",
                        diameter: diameter,
                        tintColor: model.isCameraEnabled
                            ? Color(hex: 0x23A55A) : nil,
                        isDisabled: model.voiceSessionState != .connected
                            && !model.isCameraEnabled
                    ) {
                        Task { await model.toggleCamera() }
                    }

                    SidebarVoiceGlassButton(
                        systemImage: model.isVoiceMuted ? "mic.slash.fill" : "mic.fill",
                        help: model.isVoiceMuted ? "Unmute" : "Mute",
                        diameter: diameter,
                        isAlert: model.isVoiceMuted
                    ) {
                        Task { await model.toggleVoiceMute() }
                    }

                    SidebarVoiceGlassButton(
                        systemImage: model.isVoiceDeafened
                            ? "headphones.slash" : "headphones",
                        help: model.isVoiceDeafened ? "Undeafen" : "Deafen",
                        diameter: diameter,
                        isAlert: model.isVoiceDeafened
                    ) {
                        Task { await model.toggleVoiceDeafen() }
                    }

                    SidebarVoiceGlassButton(
                        systemImage: "phone.down.fill",
                        help: "Disconnect",
                        diameter: diameter,
                        role: .destructive
                    ) {
                        Task { await model.leaveVoice() }
                    }
                }
                .padding(.horizontal, Self.controlHorizontalPadding)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height
                )
            }
            .frame(height: InterfaceScale.metric(46))
        }
        .clipShape(panelShape)
        .glassEffect(
            .regular,
            in: panelShape
        )
    }

    @ViewBuilder
    private var connectionDuration: some View {
        if let connectedAt = model.voiceConnectedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.durationLabel(from: connectedAt, to: context.date))
                    .font(.interface(.caption2))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var connectionSubtitle: String {
        let channel = model.activeVoiceChannel?.name ?? "Voice"
        guard let guildID = model.activeVoiceChannel?.guildID,
              let guild = model.serverRailGuildsByID[guildID]
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
        case .disconnected: "Disconnected"
        default: "Voice Connected"
        }
    }

    private var statusColor: Color {
        switch model.voiceSessionState {
        case .connecting, .reconnecting: Color(hex: 0xF0B232)
        case .failed, .disconnected: Color.leaveCallRed
        default: Color(hex: 0x23A55A)
        }
    }

    private var statusSymbol: String {
        switch model.voiceSessionState {
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath.circle.fill"
        case .failed, .disconnected: "wifi.exclamationmark"
        default: "wifi"
        }
    }

    private var panelShape: ConcentricRectangle {
        ConcentricRectangle(
            cornerRadius: SidebarAccountControlMetrics.cornerRadius,
            style: .continuous
        )
    }

    private static let controlCount: CGFloat = 5
    private static var controlHorizontalPadding: CGFloat { InterfaceScale.metric(6) }
    private static var preferredControlDiameter: CGFloat { InterfaceScale.metric(36) }
    private static var preferredControlSpacing: CGFloat { InterfaceScale.metric(7) }
    private static var minimumControlSpacing: CGFloat { InterfaceScale.metric(2) }

    private static func controlSpacing(for width: CGFloat) -> CGFloat {
        let contentWidth = max(0, width - (controlHorizontalPadding * 2))
        return min(
            preferredControlSpacing,
            max(minimumControlSpacing, contentWidth * 0.025)
        )
    }

    private static func controlDiameter(
        for width: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let contentWidth = max(0, width - (controlHorizontalPadding * 2))
        let totalSpacing = spacing * (controlCount - 1)
        return min(
            preferredControlDiameter,
            max(0, (contentWidth - totalSpacing) / controlCount)
        )
    }

    private static func durationLabel(from start: Date, to end: Date) -> String {
        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct SidebarVoiceGlassButton: View {
    let systemImage: String
    let help: String
    let diameter: CGFloat
    var role: ButtonRole?
    var isAlert = false
    var tintColor: Color?
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .symbolVariant(.none)
                .font(.interface(.callout).weight(.semibold))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .glassEffect(
            glass,
            in: Circle()
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .help(help)
        .accessibilityLabel(help)
    }

    private var effectiveTint: Color? {
        tintColor ?? (isAlert ? MentionRed.color : nil)
    }

    private var foregroundColor: Color {
        role == .destructive ? .white : (effectiveTint ?? .primary)
    }

    private var glass: Glass {
        if role == .destructive {
            return .regular.tint(Color.leaveCallRed).interactive()
        }
        if let effectiveTint {
            return .regular.tint(effectiveTint.opacity(0.18)).interactive()
        }
        return .regular.interactive()
    }
}

struct VoiceCallControlDock: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var showInputControls = false
    @State private var showOutputControls = false
    @State private var showCameraControls = false
    @State private var showScreenShareControls = false
    @State private var showSoundboard = false
    @State private var showActivities = false

    var body: some View {
        GlassEffectContainer(spacing: InterfaceScale.metric(8)) {
            ViewThatFits(in: .horizontal) {
                controlRow(showsTitles: true)
                    .fixedSize(horizontal: true, vertical: false)
                controlRow(showsTitles: false)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .sakuracordToggleSoundboard)) { _ in
            showSoundboard.toggle()
        }
        .onChange(of: model.isVoiceDeafened) { _, isDeafened in
            if isDeafened { showSoundboard = false }
        }
    }

    private func controlRow(showsTitles: Bool) -> some View {
        HStack(spacing: InterfaceScale.metric(8)) {
                if model.localApplicationStreamKey == nil {
                    CallDockButton(
                        title: "Share Screen",
                        systemImage: "rectangle.on.rectangle",
                        showsTitle: showsTitles
                    ) {
                        Task { await model.presentScreenSharePreview() }
                    }
                    .disabled(model.voiceSessionState != .connected)
                } else {
                    CallDockSplitButton(
                        title: "Stop Sharing",
                        systemImage: "rectangle.on.rectangle.slash",
                        isAlert: false,
                        tintColor: Color(hex: 0x5865F2),
                        isDisabled: false,
                        showsTitle: showsTitles,
                        primaryAction: { Task { await model.stopScreenSharing() } },
                        secondaryAction: { showScreenShareControls.toggle() }
                    )
                    .escapeDismissiblePopover(
                        isPresented: $showScreenShareControls,
                        arrowEdge: .bottom
                    ) {
                        ScreenShareControlsPopover(model: model)
                    }
                }

                CallDockSplitButton(
                    title: model.isCameraEnabled ? "Stop Video" : "Start Video",
                    systemImage: model.isCameraEnabled ? "video.slash.fill" : "video.fill",
                    isAlert: false,
                    tintColor: model.isCameraEnabled ? Color(hex: 0x23A55A) : nil,
                    isDisabled: model.voiceSessionState != .connected
                        && !model.isCameraEnabled,
                    showsTitle: showsTitles,
                    primaryAction: { Task { await model.toggleCamera() } },
                    secondaryAction: { showCameraControls.toggle() }
                )
                .escapeDismissiblePopover(
                    isPresented: $showCameraControls,
                    arrowEdge: .bottom
                ) {
                    VoiceCameraControls(model: model)
                }
                .contextMenu { cameraMenu }

                CallDockSplitButton(
                    title: model.isVoiceMuted ? "Unmute" : "Mute",
                    systemImage: model.isVoiceMuted ? "mic.slash.fill" : "mic.fill",
                    isAlert: model.isVoiceMuted,
                    tintColor: nil,
                    showsTitle: showsTitles,
                    primaryAction: { Task { await model.toggleVoiceMute() } },
                    secondaryAction: { showInputControls.toggle() }
                )
                .escapeDismissiblePopover(
                    isPresented: $showInputControls,
                    arrowEdge: .bottom
                ) {
                    VoiceAudioControls(model: model, direction: .input)
                }

                CallDockSplitButton(
                    title: model.isVoiceDeafened ? "Undeafen" : "Deafen",
                    systemImage: model.isVoiceDeafened ? "headphones.slash" : "headphones",
                    isAlert: model.isVoiceDeafened,
                    tintColor: nil,
                    showsTitle: showsTitles,
                    primaryAction: { Task { await model.toggleVoiceDeafen() } },
                    secondaryAction: { showOutputControls.toggle() }
                )
                .escapeDismissiblePopover(
                    isPresented: $showOutputControls,
                    arrowEdge: .bottom
                ) {
                    VoiceAudioControls(model: model, direction: .output)
                }

                CallDockButton(
                    title: "Soundboard",
                    systemImage: "waveform",
                    showsTitle: showsTitles
                ) {
                    showSoundboard.toggle()
                }
                .disabled(model.voiceSessionState != .connected || model.isVoiceDeafened)
                .background {
                    StableReactionPickerPresenter(
                        isPresented: $showSoundboard,
                        preferredEdge: .maxY,
                        accessibilityIdentifier: "voice-call-soundboard-picker"
                    ) {
                        SoundboardPickerView(model: model)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                activitiesButton(showsTitle: showsTitles)

                CallDockLeaveButton(showsTitle: showsTitles) {
                    Task { await model.leaveVoice() }
                }
            }
    }

    @ViewBuilder private func activitiesButton(showsTitle: Bool) -> some View {
        if let channel = model.activeVoiceChannel {
            CallDockButton(title: "Activities", systemImage: "gamecontroller.fill", showsTitle: showsTitle) {
                showActivities.toggle()
            }
            .disabled(model.voiceSessionState != .connected || !model.canStartActivity(in: channel))
            .background {
                StableReactionPickerPresenter(
                    isPresented: $showActivities,
                    preferredEdge: .maxY,
                    accessibilityIdentifier: "voice-call-activity-shelf"
                ) {
                    ActivityShelfView(model: model, channel: channel, isFromCall: true) { showActivities = false }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var cameraMenu: some View {
        Button("System Default") { Task { _ = await model.selectCamera(nil) } }
        Divider()
        ForEach(model.mediaDevices.cameras) { camera in
            Button {
                Task { _ = await model.selectCamera(camera) }
            } label: {
                if camera.uniqueID == model.selectedCameraUID {
                    Label(camera.name, systemImage: "checkmark")
                } else {
                    Text(camera.name)
                }
            }
        }
        Divider()
        Button {
            SettingsNavigationRouter.shared.open(page: .voiceVideo)
            openSettings()
        } label: {
            Label("Voice & Video Settings…", systemImage: "gearshape")
        }
    }
}

private struct ScreenShareControlsPopover: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFrameRateControls = false
    @State private var showQualityControls = false

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            actionRow(
                title: "Stop Sharing",
                systemImage: "rectangle.on.rectangle.slash",
                color: MentionRed.color
            ) {
                dismiss()
                Task { await model.stopScreenSharing() }
            }

            actionRow(
                title: "Change Stream",
                systemImage: "rectangle.on.rectangle.angled"
            ) {
                dismiss()
                Task { await model.presentScreenSharePreview() }
            }

            Button { showFrameRateControls.toggle() } label: {
                HStack(spacing: InterfaceScale.metric(10)) {
                    Label("Frame Rate", systemImage: "gauge.with.dots.needle.67percent")
                    Spacer(minLength: InterfaceScale.metric(24))
                    Image(systemName: "chevron.right")
                        .font(.interface(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, InterfaceScale.metric(8))
                .frame(maxWidth: .infinity)
                .frame(height: InterfaceScale.metric(34))
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
            .escapeDismissiblePopover(
                isPresented: $showFrameRateControls,
                arrowEdge: .trailing
            ) {
                ScreenShareFrameRatePopover(model: model)
            }

            Button { showQualityControls.toggle() } label: {
                HStack(spacing: InterfaceScale.metric(10)) {
                    Label("Stream Quality", systemImage: "sparkles.tv")
                    Spacer(minLength: InterfaceScale.metric(24))
                    Image(systemName: "chevron.right")
                        .font(.interface(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, InterfaceScale.metric(8))
                .frame(maxWidth: .infinity)
                .frame(height: InterfaceScale.metric(34))
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
            .escapeDismissiblePopover(
                isPresented: $showQualityControls,
                arrowEdge: .trailing
            ) {
                ScreenShareQualityPopover(model: model)
            }

            Button {
                Task {
                    var settings = model.screenShareSettings
                    settings.includesAudio.toggle()
                    await model.updateScreenShareSettings(settings)
                }
            } label: {
                HStack(spacing: InterfaceScale.metric(10)) {
                    Label("Share Audio", systemImage: model.screenShareSettings.includesAudio
                        ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    Spacer(minLength: InterfaceScale.metric(24))
                    Image(systemName: model.screenShareSettings.includesAudio
                        ? "checkmark.square.fill" : "square")
                        .foregroundStyle(model.screenShareSettings.includesAudio
                            ? SakuraCordAccentColor.color : Color.secondary)
                }
                .padding(.horizontal, InterfaceScale.metric(8))
                .frame(maxWidth: .infinity)
                .frame(height: InterfaceScale.metric(34))
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
        }
        .font(.interface(.callout))
        .padding(InterfaceScale.metric(12))
        .frame(width: InterfaceScale.metric(255))
    }

    private func actionRow(
        title: String,
        systemImage: String,
        color: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(color)
                .padding(.horizontal, InterfaceScale.metric(8))
                .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(34), alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowButtonStyle())
    }
}

struct ScreenShareQualityPopover: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            Text("Stream Quality")
                .font(.interface(.headline))
                .padding(.horizontal, InterfaceScale.metric(4))
                .padding(.bottom, InterfaceScale.metric(4))
            ForEach(model.availableScreenShareQualities, id: \.self) { quality in
                Button {
                    Task {
                        var settings = model.screenShareSettings
                        settings.quality = quality
                        await model.updateScreenShareSettings(settings)
                    }
                } label: {
                    HStack {
                        Text(quality.title)
                        Spacer()
                        if model.screenShareSettings.quality == quality {
                            Image(systemName: "checkmark")
                                .foregroundStyle(SakuraCordAccentColor.color)
                        }
                    }
                    .padding(.horizontal, InterfaceScale.metric(8))
                    .frame(maxWidth: .infinity)
                    .frame(height: InterfaceScale.metric(30))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PopoverRowButtonStyle())
            }
        }
        .font(.interface(.callout))
        .padding(InterfaceScale.metric(12))
        .frame(width: InterfaceScale.metric(190))
    }
}

private struct CallDockButton: View {
    let title: String
    let systemImage: String
    var showsTitle = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if showsTitle {
                    Label(title, systemImage: systemImage)
                } else {
                    Label(title, systemImage: systemImage)
                        .labelStyle(.iconOnly)
                }
            }
                .font(.interface(.callout).weight(.medium))
                .padding(.horizontal, showsTitle ? InterfaceScale.metric(14) : InterfaceScale.metric(13))
                .frame(height: InterfaceScale.metric(40))
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
    var tintColor: Color?
    var isDisabled = false
    var showsTitle = true
    let primaryAction: () -> Void
    let secondaryAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primaryAction) {
                Group {
                    if showsTitle {
                        Label(title, systemImage: systemImage)
                    } else {
                        Label(title, systemImage: systemImage)
                            .labelStyle(.iconOnly)
                    }
                }
                    .font(.interface(.callout).weight(.medium))
                    .padding(.leading, showsTitle ? InterfaceScale.metric(14) : InterfaceScale.metric(13))
                    .padding(.trailing, showsTitle ? InterfaceScale.metric(10) : InterfaceScale.metric(12))
                    .frame(height: InterfaceScale.metric(40))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: InterfaceScale.metric(22))

            Button(action: secondaryAction) {
                Image(systemName: "chevron.down")
                    .font(.interfaceSystem(size: 9, weight: .bold))
                    .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(40))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(effectiveTint ?? Color.primary)
        .glassEffect(
            effectiveTint.map { .regular.tint($0.opacity(0.18)).interactive() }
                ?? .regular.interactive(),
            in: Capsule()
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
    }

    private var effectiveTint: Color? {
        tintColor ?? (isAlert ? MentionRed.color : nil)
    }
}

private struct CallDockLeaveButton: View {
    let showsTitle: Bool
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Group {
                if showsTitle {
                    Label("Leave", systemImage: "phone.down.fill")
                } else {
                    Label("Leave", systemImage: "phone.down.fill")
                        .labelStyle(.iconOnly)
                }
            }
            .font(.interface(.callout).weight(.semibold))
            .padding(.horizontal, showsTitle ? InterfaceScale.metric(15) : InterfaceScale.metric(14))
            .frame(height: InterfaceScale.metric(40))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(
            .regular.tint(Color.leaveCallRed).interactive(),
            in: Capsule()
        )
        .help("Disconnect")
    }
}

/// A call's input or output device and volume.
private struct VoiceAudioControls: View {
    enum Direction { case input, output }

    let model: AppModel
    let direction: Direction

    var body: some View {
        let isInput = direction == .input
        VStack(alignment: .leading, spacing: InterfaceScale.metric(14)) {
            Text(isInput ? "Input" : "Output").font(.interface(.headline))
            VoiceDevicePicker(
                title: isInput ? "Input Device" : "Output Device",
                systemImage: isInput ? "mic" : "speaker.wave.2",
                devices: isInput ? model.mediaDevices.audioInputs : model.mediaDevices.audioOutputs,
                selectedUID: isInput ? model.voiceVideoPreferences.inputDeviceUID : model.voiceVideoPreferences.outputDeviceUID,
                select: { device in
                    isInput ? await model.selectInputDevice(device) : await model.selectOutputDevice(device)
                }
            )
            VolumeControl(
                title: isInput ? "Input Volume" : "Output Volume",
                systemImage: isInput ? "mic.fill" : "speaker.wave.2.fill",
                value: Binding(
                    get: { Double(isInput ? model.inputVolume : model.outputVolume) },
                    set: { value in
                        Task {
                            if isInput {
                                await model.updateInputVolume(Float(value))
                            } else {
                                await model.updateOutputVolume(Float(value))
                            }
                        }
                    }
                )
            )
            if let status = model.voiceDeviceStatusMessage {
                Text(status)
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(InterfaceScale.metric(16))
        .frame(width: InterfaceScale.metric(300))
        .task { await model.refreshMediaDevices() }
    }
}

private struct VoiceCameraControls: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(14)) {
            Text("Camera").font(.interface(.headline))
            CameraDevicePicker(
                devices: model.mediaDevices.cameras,
                selectedUID: model.selectedCameraUID,
                select: { camera in Task { _ = await model.selectCamera(camera) } }
            )
        }
        .padding(InterfaceScale.metric(16))
        .frame(width: InterfaceScale.metric(300))
        .task { await model.refreshMediaDevices() }
    }
}

private struct VolumeControl: View {
    let title: String
    let systemImage: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(5)) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text("\(Int(value * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.interface(.caption))
            Slider(value: $value, in: 0 ... 2)
        }
    }
}

private struct VoiceDevicePicker: View {
    let title: String
    let systemImage: String
    let devices: [AudioDeviceInfo]
    let selectedUID: String?
    let select: (AudioDeviceInfo?) async -> Bool
    @State private var selectionUID: String

    init(
        title: String,
        systemImage: String,
        devices: [AudioDeviceInfo],
        selectedUID: String?,
        select: @escaping (AudioDeviceInfo?) async -> Bool
    ) {
        self.title = title
        self.systemImage = systemImage
        self.devices = devices
        self.selectedUID = selectedUID
        self.select = select
        _selectionUID = State(initialValue: selectedUID ?? "")
    }

    var body: some View {
        LabeledContent {
            Picker(title, selection: $selectionUID) {
                Text(systemDefaultDeviceLabel(devices.first(where: \.isDefault)?.name)).tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: InterfaceScale.metric(170))
            .onChange(of: selectionUID) { _, uid in
                let previousUID = selectedUID ?? ""
                Task {
                    guard await select(devices.first(where: { $0.uid == uid })) else {
                        selectionUID = previousUID
                        return
                    }
                }
            }
            .onChange(of: selectedUID) { _, uid in
                selectionUID = uid ?? ""
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.interface(.callout))
        }
    }
}

/// A device menu's System Default entry, naming the device it stands for.
func systemDefaultDeviceLabel(_ defaultDeviceName: String?) -> String {
    defaultDeviceName.map { "System Default (\($0))" } ?? "System Default"
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
            .frame(maxWidth: InterfaceScale.metric(170))
            .onChange(of: selectionUID) { _, uid in
                select(devices.first(where: { $0.uniqueID == uid }))
            }
        } label: {
            Label("Camera Device", systemImage: "video")
                .font(.interface(.callout))
        }
    }
}
