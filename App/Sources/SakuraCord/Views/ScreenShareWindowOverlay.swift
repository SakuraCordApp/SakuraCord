import MediaPipeline
import SwiftUI

private struct ScreenShareOverlayPresentation: Identifiable {
    let id = "screen-share-preview"
}

struct CommunicationWindowOverlays: View {
    let model: AppModel

    var body: some View {
        ZStack {
            ForwardMessageWindowOverlay(model: model)
            ScreenShareWindowOverlay(model: model)
        }
    }
}

struct ScreenShareWindowOverlay: View {
    let model: AppModel

    var body: some View {
        WindowModalOverlay(
            presentation: model.isScreenSharePreviewPresented
                ? ScreenShareOverlayPresentation() : nil,
            zPosition: 100_150,
            dismiss: {
                Task { await model.dismissScreenSharePreview() }
            },
            content: { _, animationState in
                ScreenSharePreviewOverlay(
                    model: model,
                    animationState: animationState
                )
            }
        )
    }
}

private struct ScreenSharePreviewOverlay: View {
    let model: AppModel
    let animationState: WindowModalAnimationState

    var body: some View {
        ZStack {
            Color.black
                .opacity(WindowModalVisualStyle.menuBackgroundDimmingOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    animationState.dismiss(committingPresentation: true)
                }

            VStack(spacing: 20) {
                ScreenSharePreviewHeader(
                    model: model,
                    animationState: animationState
                )
                ScreenSharePreviewSurface(model: model)
                ScreenSharePreviewFooter(model: model)
            }
            .padding(24)
            .frame(maxWidth: 1_200, maxHeight: 820)
            .background(
                .regularMaterial,
                in: ConcentricRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                ConcentricRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.primary.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
            .padding(36)
            .scaleEffect(animationState.isVisible ? 1 : 0.96)
            .opacity(animationState.isVisible ? 1 : 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screen share preview")
    }

}

private struct ScreenSharePreviewHeader: View {
    let model: AppModel
    let animationState: WindowModalAnimationState

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.localApplicationStreamKey == nil ? "Share Your Screen" : "Your Screen Share")
                    .font(.title2.weight(.bold))
                if model.isScreenShareCaptureAvailable {
                    Text(model.screenShareSourceName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HoverCloseButton(
                help: "Close",
                accessibilityIdentifier: "screenShare.close"
            ) {
                animationState.dismiss(committingPresentation: true)
            }
        }
    }

}

private struct ScreenSharePreviewSurface: View {
    let model: AppModel
    @State private var isHovered = false

    var body: some View {
        ZStack {
            if model.screenSharePreviewFrame == nil {
                Color.primary.opacity(0.045)
            } else {
                Color.black.opacity(0.88)
            }

            if let frame = model.screenSharePreviewFrame {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    if model.screenShareCaptureState == .starting {
                        ProgressView()
                            .controlSize(.large)
                    } else {
                        Image(systemName: previewStatusIcon)
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                    Text(previewStatus)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if model.screenShareCaptureState != .starting {
                        chooseSourceButton
                    }
                }
            }

            if model.screenSharePreviewFrame != nil,
               isHovered,
               model.isScreenShareCaptureAvailable
            {
                chooseSourceButton
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(ConcentricRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            ConcentricRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    model.screenSharePreviewFrame == nil
                        ? Color.primary.opacity(0.1) : Color.white.opacity(0.12),
                    lineWidth: 1
                )
        }
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.16)) {
                isHovered = hovering
            }
        }
    }

    private var chooseSourceButton: some View {
        Button {
            Task { await model.changeScreenShareSource() }
        } label: {
            Label(
                sourceButtonTitle,
                systemImage: "rectangle.on.rectangle.angled"
            )
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(height: 42)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(
            .regular.tint(Color.accentColor).interactive(),
            in: Capsule()
        )
        .disabled(model.isStartingScreenShare)
    }

    private var previewStatus: String {
        switch model.screenShareCaptureState {
        case .idle: "Choose something to share."
        case .starting: "Getting your preview ready…"
        case .previewing: "Getting your preview ready…"
        case .sharing: "Sharing"
        case .interrupted: "This source isn’t available right now."
        case .failed(let message): message
        case .stopped: "Screen sharing stopped."
        }
    }

    private var previewStatusIcon: String {
        if case .failed = model.screenShareCaptureState {
            return "exclamationmark.triangle"
        }
        return "rectangle.dashed"
    }

    private var sourceButtonTitle: String {
        if model.screenShareErrorMessage != nil {
            return "Try Again"
        }
        return model.isScreenShareCaptureAvailable ? "Change Source" : "Select Source"
    }
}

private struct ScreenSharePreviewFooter: View {
    let model: AppModel
    @State private var showFrameRateControls = false
    @State private var showQualityControls = false

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                settingsButton(
                    title: model.screenShareSettings.frameRate.title,
                    systemImage: "gauge.with.dots.needle.67percent"
                ) { showFrameRateControls.toggle() }
                .popover(isPresented: $showFrameRateControls, arrowEdge: .bottom) {
                    ScreenShareFrameRatePopover(model: model)
                }

                settingsButton(
                    title: model.screenShareSettings.quality.title,
                    systemImage: "sparkles.tv"
                ) { showQualityControls.toggle() }
                .popover(isPresented: $showQualityControls, arrowEdge: .bottom) {
                    ScreenShareQualityPopover(model: model)
                }

                audioButton
            }

            HStack {
                Spacer()
                primaryButton
            }
        }
        .frame(minHeight: 44)
    }

    private func settingsButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .disabled(model.isStartingScreenShare)
    }

    private var audioButton: some View {
        let includesAudio = model.screenShareSettings.includesAudio
        return Button {
            Task {
                var settings = model.screenShareSettings
                settings.includesAudio.toggle()
                await model.updateScreenShareSettings(settings)
            }
        } label: {
            Label(
                "Share Audio",
                systemImage: includesAudio ? "speaker.wave.2.fill" : "speaker.slash.fill"
            )
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(includesAudio ? Color.primary : Color(hex: 0xF23F43))
        .glassEffect(
            includesAudio
                ? .regular.interactive()
                : .regular.tint(Color(hex: 0xF23F43).opacity(0.18)).interactive(),
            in: Capsule()
        )
        .disabled(model.isStartingScreenShare)
    }

    @ViewBuilder private var primaryButton: some View {
        if model.localApplicationStreamKey != nil {
            Button(role: .destructive) {
                Task { await model.stopScreenSharing() }
            } label: {
                Label("Stop Sharing", systemImage: "stop.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 17)
                    .frame(height: 42)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .glassEffect(
                .regular.tint(Color(hex: 0xDA373C)).interactive(),
                in: Capsule()
            )
        } else {
            Button {
                Task { await model.startScreenSharing() }
            } label: {
                HStack(spacing: 8) {
                    if model.isStartingScreenShare {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(primaryButtonTitle)
                }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(height: 42)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canStartSharing ? Color.white : Color.secondary)
            .glassEffect(
                canStartSharing
                    ? .regular.tint(Color.accentColor).interactive()
                    : .regular,
                in: Capsule()
            )
            .disabled(!canStartSharing)
        }
    }

    private var primaryButtonTitle: String {
        if model.isStartingScreenShare {
            return "Starting…"
        }
        return "Start Sharing"
    }

    private var canStartSharing: Bool {
        model.isScreenShareCaptureAvailable
            && model.screenShareErrorMessage == nil
            && !model.isStartingScreenShare
    }
}

struct ScreenShareFrameRatePopover: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Frame Rate")
                .font(.headline)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            ForEach(ScreenShareFrameRate.allCases, id: \.self) { frameRate in
                Button {
                    Task {
                        var settings = model.screenShareSettings
                        settings.frameRate = frameRate
                        await model.updateScreenShareSettings(settings)
                    }
                } label: {
                    HStack {
                        Text(frameRate.title)
                        Spacer()
                        if model.screenShareSettings.frameRate == frameRate {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .screenSharePopoverHoverEffect()
            }
        }
        .font(.callout)
        .padding(12)
        .frame(width: 190)
    }
}
