import AppKit

/// An audio file's mini player, Discord's audio controls without times or
/// volume: a bare play glyph, and a seek bar that previews to the pointer
/// and shows its grabber there.
extension NativeTimelineVoiceMessagePainter {
    static func drawAudioFilePlayer(
        _ region: NativeTimelineVoiceMessageRegion,
        state: NativeTimelineVoiceMessageDrawState,
        palette: Palette,
        context: CGContext
    ) {
        let track = seekTrack(in: region.waveformFrame)
        let playScale = 1 + 0.1 * (state.playHover ?? (state.isPlayHovered && !state.isPlayPressed ? 1 : 0))
        // A hover overlay above a resting player adds only what the pointer
        // changes; at rest its glyph and track are the row's own.
        if !state.isResting || playScale != 1 {
            drawAudioFileGlyph(region, state: state, scale: playScale, palette: palette, context: context)
        }
        if !state.isResting {
            fillTrack(track, to: 1, color: palette.unplayed, context: context)
            if state.progress > 0 || state.isPlaying {
                fillTrack(track, to: state.progress, color: palette.played, context: context)
            }
        }
        let grabber = state.grabberScale ?? (state.hoverFraction == nil ? 0 : 1)
        guard grabber > 0, let hover = state.hoverFraction else { return }
        // Discord's preview: a white wash to the pointer, under the progress.
        fillTrack(track, to: hover, color: palette.symbol.withAlphaComponent(0.3 * grabber), context: context)
        if state.progress > 0 || state.isPlaying {
            fillTrack(track, to: state.progress, color: palette.played, context: context)
        }
        let side = DiscordRichMessageMetrics.px(10) * grabber
        context.setFillColor(palette.played.cgColor)
        context.fillEllipse(in: CGRect(
            x: track.minX + track.width * state.progress - side / 2, y: track.midY - side / 2, width: side, height: side
        ))
    }

    /// Play or pause, centred on its outline under the card's icon. While
    /// loading, the overlay's spinner stands in.
    private static func drawAudioFileGlyph(
        _ region: NativeTimelineVoiceMessageRegion,
        state: NativeTimelineVoiceMessageDrawState,
        scale: CGFloat,
        palette: Palette,
        context: CGContext
    ) {
        guard !state.isLoading else { return }
        // Discord's play triangle is 18 pixels tall, like this glyph's 16
        // units with its stroke.
        let unit = DiscordRichMessageMetrics.px(18) / 16 * scale
        let pause = state.pauseMorph ?? (state.isPlaying ? 1 : 0)
        // Play's outline sits 1.5 units right of centre, for a round button.
        let center = CGPoint(x: region.playFrame.midX - 1.5 * unit * (1 - pause), y: region.playFrame.midY)
        drawPlayGlyph(at: center, unit: unit, pause: pause, color: palette.symbol, context: context)
    }

    /// Discord's 6-pixel bar with rounded ends.
    private static func seekTrack(in bar: CGRect) -> CGRect {
        let height = DiscordRichMessageMetrics.px(6)
        return CGRect(x: bar.minX, y: bar.midY - height / 2, width: bar.width, height: height)
    }

    private static func fillTrack(_ track: CGRect, to fraction: CGFloat, color: NSColor, context: CGContext) {
        var filled = track
        filled.size.width = max(track.height, track.width * min(max(fraction, 0), 1))
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(
            roundedRect: filled, cornerWidth: track.height / 2, cornerHeight: track.height / 2, transform: nil
        ))
        context.fillPath()
    }
}
