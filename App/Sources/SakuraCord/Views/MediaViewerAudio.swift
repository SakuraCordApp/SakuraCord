import SwiftUI

/// An audio file in the media viewer: a player card with the file's name and
/// size, a seek bar that names the time under the pointer, and transport,
/// volume, and download controls. It plays through the app's voice message
/// and audio file playback, so a message's file keeps one position with its
/// timeline card.
struct MediaViewerAudio: View {
    let item: RichMediaItem
    let playbackID: VoiceMessagePlaybackID
    let download: () -> Void
    @Environment(VoiceMessagePlaybackStore.self) private var playback
    /// Follows the playback's change notifications, which also cover what
    /// it keeps out of Observation, such as a newly learned length.
    @State private var revision = 0

    private var source: VoiceMessagePlaybackStore.Source {
        item.url.isFileURL ? .local(item.url) : .remote(item.url)
    }

    private var duration: TimeInterval? {
        _ = revision
        return playback.duration(of: playbackID) ?? playback.knownDuration(of: source)
    }

    private var isPlaying: Bool { playback.phase(of: playbackID) == .playing }

    var body: some View {
        VStack(spacing: InterfaceScale.metric(18)) {
            MediaViewerAudioArtwork(isPlaying: isPlaying)
            VStack(spacing: InterfaceScale.metric(3)) {
                Text(item.title)
                    .font(.interface(.title3).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(MediaViewerDetails.fileDetail(item))
                    .font(.interface(.callout).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            MediaViewerAudioSeekBar(
                duration: duration ?? 0,
                isPlaying: isPlaying,
                position: { playback.position(of: playbackID) },
                beginScrub: { playback.beginScrub(playbackID, source: source, duration: duration) },
                seek: { playback.seek(playbackID, source: source, duration: duration, fraction: $0) },
                endScrub: { playback.endScrub(playbackID) }
            )
            transport
        }
        .padding(InterfaceScale.metric(26))
        .frame(width: InterfaceScale.metric(460))
        .glassEffect(.regular, in: .rect(cornerRadius: MediaViewerStage.contentCornerRadius))
        .onAppear { playback.measureDuration(of: source) }
        .onReceive(NotificationCenter.default.publisher(for: VoiceMessagePlaybackStore.didChange, object: playback)) { _ in
            revision += 1
        }
        // Leaving the file pauses it where it is, or stops it starting.
        .onDisappear {
            if playback.phase(of: playbackID) != .paused, playback.isActive(playbackID) {
                playback.toggle(playbackID, source: source, duration: duration)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            MediaViewerAudioVolume()
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: InterfaceScale.metric(14)) {
                skipButton(by: -15)
                Button {
                    playback.toggle(playbackID, source: source, duration: duration)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace.offUp))
                        .font(.interfaceSystem(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: InterfaceScale.metric(56), height: InterfaceScale.metric(56))
                        .background(SakuraCordAccentColor.color, in: Circle())
                }
                .buttonStyle(MediaViewerAudioPressStyle(hoverScale: 1.05))
                .keyboardShortcut(.space, modifiers: [])
                .help(isPlaying ? "Pause" : "Play")
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                skipButton(by: 15)
            }
            Button(action: download) {
                HoverActionControlLabel(diameter: InterfaceScale.metric(34)) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.interface(.body).weight(.medium))
                }
            }
            .buttonStyle(MediaViewerAudioPressStyle())
            .help("Download")
            .accessibilityLabel("Download \(item.title)")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func skipButton(by seconds: Double) -> some View {
        Button {
            guard let duration, duration > 0 else { return }
            let position = playback.position(of: playbackID) + seconds
            playback.seek(playbackID, source: source, duration: duration, fraction: position / duration)
        } label: {
            HoverActionControlLabel(diameter: InterfaceScale.metric(38)) {
                Image(systemName: seconds < 0 ? "gobackward.15" : "goforward.15")
                    .font(.interface(.title3).weight(.medium))
            }
        }
        .buttonStyle(MediaViewerAudioPressStyle())
        .disabled(duration == nil)
        .help(seconds < 0 ? "Back 15 Seconds" : "Forward 15 Seconds")
    }
}

/// A rounded tile in the accent colour whose waveform ripples while the
/// file plays.
private struct MediaViewerAudioArtwork: View {
    let isPlaying: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InterfaceScale.metric(22), style: .continuous)
        Image(systemName: "waveform")
            .font(.interfaceSystem(size: 46, weight: .semibold))
            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, isActive: isPlaying)
            .foregroundStyle(.white)
            .frame(width: InterfaceScale.metric(112), height: InterfaceScale.metric(112))
            .background(SakuraCordAccentColor.color.gradient, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.14)))
            .shadow(color: SakuraCordAccentColor.color.opacity(isPlaying ? 0.45 : 0.25), radius: InterfaceScale.metric(18), y: 6)
            .scaleEffect(isPlaying ? 1 : 0.94)
            .animation(.snappy(duration: 0.3), value: isPlaying)
            .accessibilityHidden(true)
    }
}

/// The seek bar and its times. It thickens under the pointer, shows the time
/// there in a capsule, and seeks on a click or drag.
private struct MediaViewerAudioSeekBar: View {
    let duration: TimeInterval
    let isPlaying: Bool
    let position: () -> TimeInterval
    let beginScrub: () -> Void
    let seek: (Double) -> Void
    let endScrub: () -> Void
    @State private var hoverX: CGFloat?
    @State private var scrubFraction: Double?

    var body: some View {
        TimelineView(.animation(paused: !isPlaying || scrubFraction != nil)) { _ in
            let fraction = scrubFraction ?? (duration > 0 ? min(max(position() / duration, 0), 1) : 0)
            VStack(spacing: InterfaceScale.metric(6)) {
                bar(fraction: fraction)
                HStack {
                    Text(Self.time(fraction * duration))
                    Spacer()
                    Text("-" + Self.time(duration - fraction * duration))
                }
                .font(.interface(.caption).monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let isActive = hoverX != nil || scrubFraction != nil
            let height = InterfaceScale.metric(isActive ? 8 : 5)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                if let hoverX, scrubFraction == nil {
                    Capsule().fill(.white.opacity(0.14)).frame(width: max(height, hoverX))
                }
                Capsule().fill(SakuraCordAccentColor.color).frame(width: max(height, width * fraction))
            }
            .frame(height: height)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .frame(width: InterfaceScale.metric(14), height: InterfaceScale.metric(14))
                    .offset(x: width * fraction - InterfaceScale.metric(7))
                    .scaleEffect(isActive ? 1 : 0.3)
                    .opacity(isActive ? 1 : 0)
            }
            .overlay {
                if let pointer = scrubFraction.map({ $0 * width }) ?? hoverX, duration > 0 {
                    Text(Self.time(Double(pointer / max(width, 1)) * duration))
                        .font(.interface(.caption).monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, InterfaceScale.metric(7))
                        .padding(.vertical, InterfaceScale.metric(3))
                        .background(SakuraCordAccentColor.color, in: Capsule())
                        .fixedSize()
                        .position(x: pointer, y: -InterfaceScale.metric(16))
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.18), value: isActive)
            .onContinuousHover { phase in
                if case let .active(point) = phase { hoverX = min(max(point.x, 0), width) } else { hoverX = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if scrubFraction == nil { beginScrub() }
                        let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                        scrubFraction = fraction
                        hoverX = fraction * width
                        seek(fraction)
                    }
                    .onEnded { _ in
                        scrubFraction = nil
                        endScrub()
                    }
            )
        }
        .frame(height: InterfaceScale.metric(18))
        .disabled(duration <= 0)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Self.time(fraction * duration))
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            seek((position() + (direction == .increment ? 5 : -5)) / duration)
        }
    }

    static func time(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded(.down))).formatted(.time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// Mute, shared with the timeline's audio files, and a volume slider.
private struct MediaViewerAudioVolume: View {
    @Environment(VoiceMessagePlaybackStore.self) private var playback

    var body: some View {
        let isMuted = playback.isAudioFileMuted
        HStack(spacing: InterfaceScale.metric(4)) {
            Button(action: playback.toggleAudioFileMute) {
                HoverActionControlLabel(diameter: InterfaceScale.metric(34)) {
                    Image(systemName: "speaker.wave.3.fill", variableValue: isMuted ? 0 : Double(playback.audioFileVolume))
                        .symbolVariant(isMuted ? .slash : .none)
                        .contentTransition(.symbolEffect(.replace))
                        .font(.interface(.body).weight(.medium))
                        .frame(width: InterfaceScale.metric(22))
                }
            }
            .buttonStyle(MediaViewerAudioPressStyle())
            .help(isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(isMuted ? "Unmute" : "Mute")
            Slider(
                value: Binding(get: { playback.audioFileVolume }, set: playback.setAudioFileVolume),
                in: 0 ... 1
            )
            .controlSize(.small)
            .tint(SakuraCordAccentColor.color)
            .frame(width: InterfaceScale.metric(64))
            .accessibilityLabel("Volume")
        }
    }
}

/// Grows a little under the pointer and dips while pressed.
private struct MediaViewerAudioPressStyle: ButtonStyle {
    var hoverScale: CGFloat = 1
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : isHovering ? hoverScale : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
            .animation(.snappy(duration: 0.2), value: isHovering)
            .onHover { isHovering = $0 }
    }
}
