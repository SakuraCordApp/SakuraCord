import AppKit

/// Discord's audio file player. Discord draws its controls in the dark theme
/// whatever the app's appearance, so their colours are fixed.
extension NativeTimelineVoiceMessagePainter {
    private static let iconColor = NSColor.white
    private static let trackColor = NSColor(srgbRed: 200 / 255, green: 201 / 255, blue: 206 / 255, alpha: 0.3)
    private static let bubbleTextColor = NSColor(srgbRed: 242 / 255, green: 243 / 255, blue: 245 / 255, alpha: 1)

    static func drawAudioFilePlayer(
        _ region: NativeTimelineVoiceMessageRegion,
        state: NativeTimelineVoiceMessageDrawState,
        context: CGContext
    ) {
        let controls = region.controlsFrame
        let radius = InterfaceScale.metric(8)
        let shape = CGPath(roundedRect: controls, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // The live overlay covers the row's resting player, so it lays the
        // card's opaque colour first.
        context.setFillColor(NativeTimelineFileCard.audioBackgroundColor.cgColor)
        context.addPath(shape)
        context.fillPath()
        context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        context.addPath(shape)
        context.fillPath()
        drawAudioFilePlayGlyph(in: region.playFrame, isPlaying: state.isPlaying, context: context)
        let elapsed = state.duration.map { Double(state.progress) * $0 }
        let time = state.duration == nil || elapsed == nil
            ? "-:--\u{2009}/\u{2009}-:--"
            : "\(Self.timeText(elapsed ?? 0))\u{2009}/\u{2009}\(Self.timeText(state.duration ?? 0))"
        VoiceMessageLabelCache.draw(
            time, font: audioFileTimeFont, color: iconColor, centeredIn: region.timeFrame, alignment: .left
        )
        drawAudioFileSeekBar(region.seekBarFrame(for: state.duration), state: state, context: context)
        NativeTimelineRowPainter.systemSymbol(
            state.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill",
            in: region.speedFrame,
            color: iconColor,
            inset: InterfaceScale.metric(6)
        )
    }

    /// Discord's media player counts whole seconds, rounding down.
    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func drawAudioFilePlayGlyph(in frame: CGRect, isPlaying: Bool, context: CGContext) {
        let unit = frame.width / 32
        context.setFillColor(iconColor.cgColor)
        if isPlaying {
            for barX in [10.0, 18.0] {
                let bar = CGRect(x: frame.minX + barX * unit, y: frame.minY + 8 * unit, width: 4 * unit, height: 16 * unit)
                context.addPath(CGPath(roundedRect: bar, cornerWidth: unit, cornerHeight: unit, transform: nil))
            }
            context.fillPath()
            return
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: frame.minX + 11 * unit, y: frame.minY + 7 * unit))
        path.addLine(to: CGPoint(x: frame.minX + 24 * unit, y: frame.minY + 16 * unit))
        path.addLine(to: CGPoint(x: frame.minX + 11 * unit, y: frame.minY + 25 * unit))
        path.closeSubpath()
        context.addPath(path)
        context.setLineJoin(.round)
        context.setLineWidth(2 * unit)
        context.setStrokeColor(iconColor.cgColor)
        context.drawPath(using: .fillStroke)
    }

    /// The seek bar, with the hover preview, grabber, and time bubble.
    private static func drawAudioFileSeekBar(
        _ area: CGRect,
        state: NativeTimelineVoiceMessageDrawState,
        context: CGContext
    ) {
        let height = InterfaceScale.metric(6)
        let bar = CGRect(x: area.minX, y: area.midY - height / 2, width: area.width, height: height)
        func fill(_ rect: CGRect, _ color: NSColor) {
            // Discord's bar grows three-point rounded ends past its edges.
            let ends = rect.insetBy(dx: -InterfaceScale.metric(3), dy: 0)
            context.setFillColor(color.cgColor)
            context.addPath(CGPath(roundedRect: ends, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
            context.fillPath()
        }
        fill(bar, trackColor)
        if let hover = state.hoverFraction {
            fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * hover, height: height), NSColor.white.withAlphaComponent(0.3))
        }
        // An unplayed bar still shows its rounded start in the accent.
        let played = CGRect(x: bar.minX, y: bar.minY, width: bar.width * state.progress, height: height)
        fill(played, .sakuraCordAccentColor)
        guard let hover = state.hoverFraction else { return }
        let grabber = InterfaceScale.metric(10)
        context.setFillColor((NSColor.sakuraCordAccentColor.blended(withFraction: 0.25, of: .black) ?? .sakuraCordAccentColor).cgColor)
        context.fillEllipse(in: CGRect(x: played.maxX - grabber / 2, y: bar.midY - grabber / 2, width: grabber, height: grabber))
        guard let duration = state.duration else { return }
        drawAudioFileBubble(Self.timeText(Double(hover) * duration), at: bar.minX + bar.width * hover, above: bar.minY, context: context)
    }

    private static func drawAudioFileBubble(_ text: String, at centerX: CGFloat, above barTop: CGFloat, context: CGContext) {
        let font = audioFileBubbleFont
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + InterfaceScale.metric(16)
        let box = CGRect(
            x: centerX - width / 2, y: barTop - InterfaceScale.metric(28),
            width: width, height: InterfaceScale.metric(18)
        )
        let radius = InterfaceScale.metric(3)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        let tip = InterfaceScale.metric(5)
        context.move(to: CGPoint(x: centerX - tip, y: box.maxY))
        context.addLine(to: CGPoint(x: centerX + tip, y: box.maxY))
        context.addLine(to: CGPoint(x: centerX, y: box.maxY + tip))
        context.closePath()
        context.fillPath()
        VoiceMessageLabelCache.draw(text, font: font, color: bubbleTextColor, centeredIn: box, alignment: .center)
    }
}
