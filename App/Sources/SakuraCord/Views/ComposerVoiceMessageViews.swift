import MediaPipeline
import SwiftUI

/// The composer's trailing button. One symbol morphs between sending text,
/// starting a voice message, stopping it, and sending the recording, so the
/// control never jumps between views.
struct ComposerSendSlot: View {
    enum Mode: Equatable {
        case send
        case voice
        case stop
        case sendVoice
    }

    /// A press shorter than this starts a hands-free recording; a longer
    /// one records only while held.
    static let holdThreshold: Duration = .milliseconds(350)

    let mode: Mode
    var appearance: ComposerBarAppearance = .defaultStyle
    var isSlowmodeBlocked = false
    let send: () -> Void
    let startRecording: () -> Void
    let stopRecording: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var press: (mode: Mode, began: ContinuousClock.Instant)?

    var body: some View {
        Group {
            if mode == .send || mode == .sendVoice {
                Button(action: send) { symbolView }
                    .buttonStyle(.plain)
            } else {
                symbolView
                    .gesture(pressGesture, isEnabled: isEnabled)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { activateWithoutHold() }
            }
        }
        .onModalHover { isHovering = appearance == .legacy && $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var symbolView: some View {
        Image(systemName: symbol)
            .font(.interfaceSystem(size: 19, weight: .medium))
            .foregroundStyle(foreground)
            .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
            .frame(width: ChatChromeMetrics.composerButtonSize, height: ChatChromeMetrics.composerButtonSize)
            .scaleEffect(press != nil ? 0.86 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: press != nil)
            .background {
                if mode == .stop {
                    Circle()
                        .fill(Color.red.opacity(0.18))
                        .phaseAnimator([false, true]) { circle, expanded in
                            circle.scaleEffect(expanded ? 1.18 : 0.92).opacity(expanded ? 0.2 : 1)
                        } animation: { _ in .easeInOut(duration: 0.9) }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .background(hoverColor, in: shape)
            .contentShape(shape)
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard press == nil else { return }
                press = (mode, .now)
                if mode == .voice { startRecording() }
            }
            .onEnded { _ in
                guard let press else { return }
                self.press = nil
                switch press.mode {
                case .send, .sendVoice:
                    break
                case .stop:
                    stopRecording()
                case .voice:
                    // A held press records only while held.
                    if ContinuousClock.now - press.began >= Self.holdThreshold { stopRecording() }
                }
            }
    }

    private func activateWithoutHold() {
        switch mode {
        case .send, .sendVoice: send()
        case .voice: startRecording()
        case .stop: stopRecording()
        }
    }

    private var symbol: String {
        switch mode {
        case .send, .sendVoice: "paperplane"
        case .voice: "waveform"
        case .stop: "stop.circle"
        }
    }

    private var help: String {
        switch mode {
        case .send: "Send message"
        case .voice: "Record a voice message — click to start, or hold to record"
        case .stop: "Stop recording"
        case .sendVoice: "Send voice message"
        }
    }

    private var foreground: Color {
        if mode == .stop { return .red }
        guard isEnabled, !isSlowmodeBlocked else { return Color.gray.opacity(0.62) }
        return colorScheme == .dark ? .white : .black
    }

    private var shape: AnyShape {
        switch appearance {
        case .defaultStyle: AnyShape(Circle())
        case .legacy: AnyShape(RoundedRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous))
        }
    }

    private var hoverColor: Color {
        appearance == .legacy && isHovering && isEnabled && !isSlowmodeBlocked ? .primary.opacity(0.14) : .clear
    }
}

/// Replaces the text field while a voice message is recorded or reviewed.
struct ComposerVoiceMessageField: View {
    let state: VoiceMessageComposerState
    let playback: VoiceMessagePlaybackStore

    /// The dragged position, shown directly: a paused player's position
    /// doesn't redraw the field.
    @State private var scrubProgress: Double?

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            if state.phase.recording == nil {
                recordingIndicator
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            TimelineView(.animation(paused: !isAnimating)) { context in
                GeometryReader { proxy in
                    waveform(size: proxy.size, now: context.date)
                }
            }
            .frame(height: InterfaceScale.metric(24))
            if let recording = state.phase.recording {
                TimelineView(.animation(paused: playback.phase(of: state.playbackID) != .playing || scrubProgress != nil)) { _ in
                    Text(VoiceMessageDurationFormat.string(remaining(of: recording)))
                        .font(.interfaceSystem(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(countsDown: true))
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: ChatChromeMetrics.composerControlHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.phase.recording == nil ? "Recording voice message" : "Voice message")
    }

    private var isAnimating: Bool {
        switch state.phase {
        case .starting, .recording: true
        case .recorded: playback.phase(of: state.playbackID) == .playing
        default: false
        }
    }

    private var recordingIndicator: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            Circle()
                .fill(.red)
                .frame(width: InterfaceScale.metric(8), height: InterfaceScale.metric(8))
                .phaseAnimator([1.0, 0.25]) { dot, opacity in
                    // Pulses once the microphone delivers sound.
                    dot.opacity(state.phase == .recording && state.elapsed > 0 ? opacity : 1)
                } animation: { _ in .easeInOut(duration: 0.7) }
            Text(VoiceMessageDurationFormat.string(state.elapsed))
                .font(.interfaceSystem(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(state.elapsed))
        }
    }

    /// One view for both phases, so the live bars morph into the overview.
    private func waveform(size: CGSize, now: Date) -> some View {
        let metrics = VoiceWaveformMetrics(height: size.height)
        let count = metrics.barCount(fitting: size.width)
        let recording = state.phase.recording
        let levels = recording.map {
            VoiceMessageWaveform.overview($0.waveform.map { Float($0) / 255 }, count: count)
        } ?? liveLevels(count: count)
        let shape = VoiceWaveformShape(levels: WaveformLevels(levels), metrics: metrics)
        let progress = recording.map(progress(of:)) ?? 0
        // Bars are right-aligned; progress and scrubbing span the bars only.
        let barsWidth = CGFloat(count) * metrics.step - metrics.spacing
        let barsMinX = size.width - barsWidth
        return ZStack(alignment: .leading) {
            shape.fill(recording == nil ? SakuraCordAccentColor.color : Color.primary.opacity(0.28))
            shape.fill(SakuraCordAccentColor.color)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: max(0, barsMinX + barsWidth * progress))
                }
        }
        .offset(x: -livePosition(now: now) * metrics.step)
        .frame(width: size.width, height: size.height, alignment: .trailing)
        .clipped()
        .mask {
            // Older bars fade out as they scroll away while recording.
            LinearGradient(
                stops: [
                    .init(color: recording == nil ? .clear : .black, location: 0),
                    .init(color: .black, location: recording == nil ? 0.12 : 0.01),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .contentShape(Rectangle())
        .gesture(
            scrubGesture(minX: barsMinX, width: barsWidth, recording: recording),
            isEnabled: recording != nil && state.canPreview
        )
    }

    /// How far, in bars, the newest bar has scrolled in since it was completed.
    private func livePosition(now: Date) -> CGFloat {
        guard state.phase == .recording else { return 0 }
        let extrapolated = state.elapsed + min(now.timeIntervalSince(state.elapsedSampledAt), 0.1)
        let bars = extrapolated / VoiceMessageRecorder.liveBarInterval
        return CGFloat(min(max(bars - Double(state.totalBars), 0), 1))
    }

    private func liveLevels(count: Int) -> [Float] {
        let recent = state.displayedLiveLevels(count: count)
        return [Float](repeating: 0, count: max(0, count - recent.count)) + recent
    }

    private func progress(of recording: VoiceMessageRecording) -> CGFloat {
        if let scrubProgress { return CGFloat(scrubProgress) }
        guard playback.isActive(state.playbackID), recording.duration > 0 else { return 0 }
        return CGFloat(min(max(playback.position(of: state.playbackID) / recording.duration, 0), 1))
    }

    private func remaining(of recording: VoiceMessageRecording) -> TimeInterval {
        if let scrubProgress { return recording.duration * (1 - scrubProgress) }
        guard playback.isActive(state.playbackID) else { return recording.duration }
        return max(0, recording.duration - playback.position(of: state.playbackID))
    }

    private func scrubGesture(minX: CGFloat, width: CGFloat, recording: VoiceMessageRecording?) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let recording else { return }
                let source = VoiceMessagePlaybackStore.Source.local(recording.fileURL)
                if scrubProgress == nil {
                    playback.beginScrub(state.playbackID, source: source, duration: recording.duration)
                }
                let fraction = min(max(Double((value.location.x - minX) / max(width, 1)), 0), 1)
                scrubProgress = fraction
                playback.seek(state.playbackID, source: source, duration: recording.duration, fraction: fraction)
            }
            .onEnded { _ in
                scrubProgress = nil
                playback.endScrub(state.playbackID)
            }
    }
}

nonisolated enum VoiceMessageDurationFormat {
    /// `m:ss`, rounding up like Discord's player.
    static func string(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

nonisolated struct VoiceWaveformMetrics {
    let height: CGFloat
    var barWidth: CGFloat { InterfaceScale.metric(3) }
    var spacing: CGFloat { InterfaceScale.metric(2) }
    var step: CGFloat { barWidth + spacing }
    var minimumBarHeight: CGFloat { InterfaceScale.metric(3) }

    func barCount(fitting width: CGFloat) -> Int {
        max(1, Int((width + spacing) / step))
    }
}

/// Bars that animate their heights, so a live recording morphs into its
/// finished overview instead of being replaced.
nonisolated struct VoiceWaveformShape: Shape {
    var levels: WaveformLevels
    let metrics: VoiceWaveformMetrics

    var animatableData: WaveformLevels {
        get { levels }
        set { levels = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let values = levels.values
        let originX = rect.maxX - CGFloat(values.count) * metrics.step + metrics.spacing
        for (index, value) in values.enumerated() {
            // The timeline player's scale: silence rests at the minimum height.
            let height = metrics.minimumBarHeight
                + (rect.height - metrics.minimumBarHeight) * CGFloat(min(max(value, 0), 1))
            let bar = CGRect(
                x: originX + CGFloat(index) * metrics.step,
                y: rect.midY - height / 2,
                width: metrics.barWidth,
                height: height
            )
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: metrics.barWidth / 2, height: metrics.barWidth / 2))
        }
        return path
    }
}

nonisolated struct WaveformLevels: VectorArithmetic {
    var values: [Double]

    init(_ levels: [Float]) { values = levels.map(Double.init) }
    private init(values: [Double]) { self.values = values }

    static var zero: Self { Self(values: []) }

    static func + (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs, +) }
    static func - (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs, -) }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    private static func combine(_ lhs: Self, _ rhs: Self, _ operation: (Double, Double) -> Double) -> Self {
        let count = max(lhs.values.count, rhs.values.count)
        // Right-align, so bars keep their positions as recordings grow.
        let left = [Double](repeating: 0, count: count - lhs.values.count) + lhs.values
        let right = [Double](repeating: 0, count: count - rhs.values.count) + rhs.values
        return Self(values: zip(left, right).map(operation))
    }
}
