import AppKit

/// An audio file's player, in a voice message's colours: the card's badge
/// plays, and the seek row holds the time, a seek capsule, and mute.
extension NativeTimelineVoiceMessagePainter {
    static func drawAudioFilePlayer(
        _ region: NativeTimelineVoiceMessageRegion,
        state: NativeTimelineVoiceMessageDrawState,
        palette: Palette,
        context: CGContext
    ) {
        let bar = region.seekBarFrame(for: state.duration)
        // A hover overlay above a resting player adds only what the pointer
        // changes; the opaque play button covers the row's own.
        if state.isResting {
            if state.isPlayHovered { drawPlayButton(region, state: state, palette: palette, context: context) }
            // A second resting fill brings the row's chip to its hover shade.
            if state.isSpeedHovered {
                drawMuteChip(region, fill: palette.chipFill, palette: palette, isMuted: state.isMuted, context: context)
            }
            drawAudioFileSeekHover(bar, state: state, palette: palette, context: context)
            return
        }
        drawPlayButton(region, state: state, palette: palette, context: context)
        let time = state.duration.map {
            "\(Self.timeText(Double(state.progress) * $0))\u{2009}/\u{2009}\(Self.timeText($0))"
        } ?? "-:--\u{2009}/\u{2009}-:--"
        VoiceMessageLabelCache.draw(time, font: timeFont, color: palette.text, centeredIn: region.timeFrame, alignment: .left)
        let track = seekTrack(in: bar)
        let radius = track.height / 2
        context.setFillColor(palette.unplayed.cgColor)
        context.addPath(CGPath(roundedRect: track, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        var played = track
        played.size.width = max(track.height, track.width * state.progress)
        if state.progress > 0 {
            context.setFillColor(palette.played.cgColor)
            context.addPath(CGPath(roundedRect: played, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        drawMuteChip(
            region, fill: state.isSpeedHovered ? palette.chipHoverFill : palette.chipFill,
            palette: palette, isMuted: state.isMuted, context: context
        )
        drawAudioFileSeekHover(bar, state: state, palette: palette, context: context)
    }

    /// Whole seconds, rounding down.
    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func seekTrack(in bar: CGRect) -> CGRect {
        let height = InterfaceScale.metric(4)
        return CGRect(x: bar.minX, y: bar.midY - height / 2, width: bar.width, height: height)
    }

    /// The voice message speed chip's look, holding the mute toggle.
    private static func drawMuteChip(
        _ region: NativeTimelineVoiceMessageRegion, fill: NSColor, palette: Palette, isMuted: Bool, context: CGContext
    ) {
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: region.speedFrame)
        NativeTimelineRowPainter.systemSymbol(
            isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            in: region.speedFrame, color: palette.chipText, inset: InterfaceScale.metric(6), weight: .semibold
        )
    }

    /// Under the pointer: the preview fill to the pointer, a grabber at the
    /// playhead, and a capsule naming the time there.
    private static func drawAudioFileSeekHover(
        _ bar: CGRect,
        state: NativeTimelineVoiceMessageDrawState,
        palette: Palette,
        context: CGContext
    ) {
        guard let hover = state.hoverFraction else { return }
        let track = seekTrack(in: bar)
        let radius = track.height / 2
        let preview = CGRect(x: track.minX, y: track.minY, width: track.width * hover, height: track.height)
        context.setFillColor(palette.played.withAlphaComponent(0.35).cgColor)
        context.addPath(CGPath(roundedRect: preview, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        let grabber = InterfaceScale.metric(10)
        context.setFillColor(palette.played.cgColor)
        context.fillEllipse(in: CGRect(
            x: track.minX + track.width * state.progress - grabber / 2, y: track.midY - grabber / 2,
            width: grabber, height: grabber
        ))
        guard let duration = state.duration else { return }
        let text = timeText(Double(hover) * duration)
        let font = audioFileBubbleFont
        let width = NativeTimelineRowLayout.measuredTextWidth(text, font: font) + InterfaceScale.metric(14)
        let label = CGRect(
            x: track.minX + track.width * hover - width / 2, y: track.minY - InterfaceScale.metric(26),
            width: width, height: InterfaceScale.metric(18)
        )
        context.setFillColor(palette.buttonFill.cgColor)
        context.addPath(CGPath(roundedRect: label, cornerWidth: label.height / 2, cornerHeight: label.height / 2, transform: nil))
        context.fillPath()
        VoiceMessageLabelCache.draw(text, font: font, color: palette.glyph, centeredIn: label, alignment: .center)
    }
}
