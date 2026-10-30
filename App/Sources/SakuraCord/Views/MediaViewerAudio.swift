import AVFoundation
import SwiftUI

/// An audio file in the media viewer: a player card with the file's name and
/// size, a seek bar that names the time under the pointer, and transport,
/// volume, and download controls.
struct MediaViewerAudio: View {
    let item: RichMediaItem
    let download: () -> Void
    @State private var player = MediaViewerAudioPlayer()

    var body: some View {
        VStack(spacing: InterfaceScale.metric(18)) {
            MediaViewerAudioArtwork(isPlaying: player.isPlaying)
            VStack(spacing: InterfaceScale.metric(3)) {
                Text(item.title)
                    .font(.interface(.title3).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(MediaViewerDetails.fileDetail(item))
                    .font(.interface(.callout).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            MediaViewerAudioSeekBar(player: player)
            transport
        }
        .padding(InterfaceScale.metric(26))
        .frame(width: InterfaceScale.metric(460))
        .glassEffect(.regular, in: .rect(cornerRadius: MediaViewerStage.contentCornerRadius))
        .task(id: item.url) { await player.load(item.url) }
        .onDisappear(perform: player.stop)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            MediaViewerAudioVolume(player: player)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: InterfaceScale.metric(14)) {
                skipButton(by: -15)
                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace.offUp))
                        .font(.interfaceSystem(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: InterfaceScale.metric(56), height: InterfaceScale.metric(56))
                        .background(SakuraCordAccentColor.color, in: Circle())
                }
                .buttonStyle(MediaViewerAudioPressStyle(hoverScale: 1.05))
                .keyboardShortcut(.space, modifiers: [])
                .disabled(player.duration == nil)
                .help(player.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
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
            player.skip(by: seconds)
        } label: {
            HoverActionControlLabel(diameter: InterfaceScale.metric(38)) {
                Image(systemName: seconds < 0 ? "gobackward.15" : "goforward.15")
                    .font(.interface(.title3).weight(.medium))
            }
        }
        .buttonStyle(MediaViewerAudioPressStyle())
        .disabled(player.duration == nil)
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
    let player: MediaViewerAudioPlayer
    @State private var hoverX: CGFloat?
    @State private var scrubFraction: Double?

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying || scrubFraction != nil)) { _ in
            let duration = player.duration ?? 0
            let fraction = scrubFraction ?? (duration > 0 ? min(max(player.currentTime / duration, 0), 1) : 0)
            VStack(spacing: InterfaceScale.metric(6)) {
                bar(fraction: fraction, duration: duration)
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

    private func bar(fraction: Double, duration: TimeInterval) -> some View {
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
            .overlay(alignment: .topLeading) {
                if let pointer = scrubFraction.map({ $0 * width }) ?? hoverX, duration > 0 {
                    Text(Self.time(Double(pointer / max(width, 1)) * duration))
                        .font(.interface(.caption).monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, InterfaceScale.metric(7))
                        .padding(.vertical, InterfaceScale.metric(3))
                        .background(SakuraCordAccentColor.color, in: Capsule())
                        .fixedSize()
                        .alignmentGuide(.leading) { $0.width / 2 - pointer }
                        .offset(y: -InterfaceScale.metric(30))
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
                        if scrubFraction == nil { player.beginScrub() }
                        scrubFraction = min(max(value.location.x / max(width, 1), 0), 1)
                        hoverX = min(max(value.location.x, 0), width)
                    }
                    .onEnded { _ in
                        if let scrubFraction { player.endScrub(at: scrubFraction) }
                        scrubFraction = nil
                    }
            )
        }
        .frame(height: InterfaceScale.metric(18))
        .disabled(duration <= 0)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Self.time(fraction * duration))
        .accessibilityAdjustableAction { direction in
            player.skip(by: direction == .increment ? 5 : -5)
        }
    }

    static func time(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded(.down))).formatted(.time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// Mute and a volume slider.
private struct MediaViewerAudioVolume: View {
    @Bindable var player: MediaViewerAudioPlayer

    var body: some View {
        HStack(spacing: InterfaceScale.metric(4)) {
            Button {
                player.isMuted.toggle()
            } label: {
                HoverActionControlLabel(diameter: InterfaceScale.metric(34)) {
                    Image(systemName: "speaker.wave.3.fill", variableValue: player.isMuted ? 0 : Double(player.volume))
                        .symbolVariant(player.isMuted ? .slash : .none)
                        .contentTransition(.symbolEffect(.replace))
                        .font(.interface(.body).weight(.medium))
                        .frame(width: InterfaceScale.metric(22))
                }
            }
            .buttonStyle(MediaViewerAudioPressStyle())
            .help(player.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
            Slider(value: $player.volume, in: 0 ... 1)
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

/// Plays the viewer's audio file with AVPlayer, which streams it.
@MainActor
@Observable
final class MediaViewerAudioPlayer {
    private(set) var duration: TimeInterval?
    private(set) var isPlaying = false
    var volume: Float = 1 {
        didSet {
            player.volume = volume
            if volume > 0 { isMuted = false }
        }
    }

    var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    /// Where a seek is headed until it lands, which also redraws a paused
    /// player's seek bar.
    private var seekTarget: TimeInterval?
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var resumesAfterScrub = false
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?

    var currentTime: TimeInterval {
        seekTarget ?? (player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
    }

    func load(_ url: URL) async {
        stop()
        duration = nil
        let source = await MediaViewerActionService.resolveRemoteURL?(url) ?? url
        guard !Task.isCancelled else { return }
        let item = AVPlayerItem(url: source)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.seek(to: 0)
            }
        }
        let seconds = try? await item.asset.load(.duration).seconds
        guard !Task.isCancelled, let seconds, seconds.isFinite, seconds > 0 else { return }
        duration = seconds
    }

    func togglePlayback() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func skip(by seconds: TimeInterval) {
        guard let duration else { return }
        seek(to: min(max(currentTime + seconds, 0), duration))
    }

    func beginScrub() {
        resumesAfterScrub = isPlaying
        player.pause()
        isPlaying = false
    }

    func endScrub(at fraction: Double) {
        guard let duration else { return }
        seek(to: fraction * duration)
        if resumesAfterScrub { togglePlayback() }
    }

    func stop() {
        player.pause()
        isPlaying = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private func seek(to seconds: TimeInterval) {
        seekTarget = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in
                if self?.seekTarget == seconds { self?.seekTarget = nil }
            }
        }
    }
}
