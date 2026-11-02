import SwiftUI

/// An audio file in the media viewer: the file's icon, name, and size over a
/// seek bar, skip and Liquid Glass play buttons, and volume. It plays through
/// the app's voice message and audio file playback, so a message's file
/// keeps one position with its timeline card.
struct MediaViewerAudio: View {
    let item: RichMediaItem
    let playbackID: VoiceMessagePlaybackID
    /// False from the moment the viewer starts closing.
    let isVisible: Bool
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
        VStack(spacing: InterfaceScale.metric(24)) {
            VStack(spacing: InterfaceScale.metric(14)) {
                Image(nsImage: MediaViewerFile.icon(for: item))
                    .resizable()
                    .frame(width: InterfaceScale.metric(128), height: InterfaceScale.metric(128))
                    .accessibilityHidden(true)
                VStack(spacing: InterfaceScale.metric(4)) {
                    Text(item.title)
                        .font(.interface(.title2).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(MediaViewerDetails.fileDetail(item))
                        .font(.interface(.body).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            MediaViewerAudioSeekBar(
                duration: duration ?? 0,
                isPlaying: isPlaying,
                position: { playback.position(of: playbackID) },
                beginScrub: { playback.beginScrub(playbackID, source: source, duration: duration) },
                seek: { playback.seek(playbackID, source: source, duration: duration, fraction: $0) },
                endScrub: { playback.endScrub(playbackID) }
            )
            HStack(spacing: InterfaceScale.metric(28)) {
                skipButton(by: -10)
                playButton
                skipButton(by: 10)
            }
            MediaViewerAudioVolume()
        }
        .padding(InterfaceScale.metric(36))
        // The file icon's artwork sits inside its frame; this evens the
        // space above it with the space below the volume.
        .padding(.bottom, InterfaceScale.metric(10))
        .frame(width: InterfaceScale.metric(540))
        .mediaViewerPanel()
        .onAppear { playback.measureDuration(of: source) }
        .onReceive(NotificationCenter.default.publisher(for: VoiceMessagePlaybackStore.didChange, object: playback)) { _ in
            revision += 1
        }
        // Leaving the file pauses it where it is, or stops it starting. A
        // closing viewer does so as it starts to close: the timeline takes
        // input then and may play the same file before the viewer is gone.
        .onChange(of: isVisible) { _, isVisible in
            if !isVisible { pause() }
        }
        .onDisappear {
            if isVisible { pause() }
        }
    }

    private func pause() {
        if playback.phase(of: playbackID) != .paused, playback.isActive(playbackID) {
            playback.toggle(playbackID, source: source, duration: duration)
        }
    }

    private var playButton: some View {
        Button {
            playback.toggle(playbackID, source: source, duration: duration)
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                .font(.interfaceSystem(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: InterfaceScale.metric(60), height: InterfaceScale.metric(60))
                // The whole circle, not just the glyph, takes the pointer, so
                // the glass responds anywhere on the button.
                .contentShape(.circle)
                // Interactive glass keeps its tint and depth while pressed,
                // where the prominent button style flattens to a pale fill.
                .glassEffect(.regular.tint(SakuraCordAccentColor.color).interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private func skipButton(by seconds: Double) -> some View {
        MediaViewerAudioSkipButton(seconds: seconds) {
            guard let duration, duration > 0 else { return }
            let position = playback.position(of: playbackID) + seconds
            playback.seek(playbackID, source: source, duration: duration, fraction: position / duration)
        }
        .disabled(duration == nil)
    }
}

/// Skips by ten seconds, its arrow turning the way it skips.
private struct MediaViewerAudioSkipButton: View {
    let seconds: Double
    let action: () -> Void
    @State private var skips = 0

    var body: some View {
        Button {
            skips += 1
            action()
        } label: {
            HoverActionControlLabel(diameter: InterfaceScale.metric(52)) {
                Image(systemName: seconds < 0 ? "gobackward.10" : "goforward.10")
                    .font(.interfaceSystem(size: 26, weight: .medium))
                    .symbolEffect(
                        seconds < 0 ? .rotate.byLayer.counterClockwise : .rotate.byLayer.clockwise,
                        options: .speed(3),
                        value: skips
                    )
            }
        }
        .buttonStyle(MediaViewerAudioPressStyle())
        .help(seconds < 0 ? "Back 10 Seconds" : "Forward 10 Seconds")
        .accessibilityLabel(seconds < 0 ? "Back 10 Seconds" : "Forward 10 Seconds")
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
                .font(.interface(.callout).monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let isActive = hoverX != nil || scrubFraction != nil
            let height = InterfaceScale.metric(isActive ? 10 : 6)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.16))
                if let hoverX, scrubFraction == nil {
                    Capsule().fill(.primary.opacity(0.14)).frame(width: max(height, hoverX))
                }
                Capsule().fill(SakuraCordAccentColor.color).frame(width: max(height, width * fraction))
            }
            .frame(height: height)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .frame(width: InterfaceScale.metric(16), height: InterfaceScale.metric(16))
                    .offset(x: width * fraction - InterfaceScale.metric(8))
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
                        .position(x: pointer, y: -InterfaceScale.metric(18))
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
        .frame(height: InterfaceScale.metric(20))
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

/// The audio file volume, between quiet and loud speakers.
private struct MediaViewerAudioVolume: View {
    @Environment(VoiceMessagePlaybackStore.self) private var playback

    var body: some View {
        Slider(
            value: Binding(get: { playback.audioFileVolume }, set: playback.setAudioFileVolume),
            in: 0 ... 1
        ) {
            Text("Volume")
        } minimumValueLabel: {
            Image(systemName: "speaker.fill")
        } maximumValueLabel: {
            Image(systemName: "speaker.wave.3.fill")
        }
        .labelsHidden()
        .font(.interface(.body))
        .foregroundStyle(.secondary)
        .tint(SakuraCordAccentColor.color)
        .frame(width: InterfaceScale.metric(260))
    }
}

/// Dips while pressed.
private struct MediaViewerAudioPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}
