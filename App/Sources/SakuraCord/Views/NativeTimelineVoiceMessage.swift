import AppKit
import CoreText
import MediaPipeline
import SakuraCordModels

/// A voice message's player, laid out once with its row. Bars are reduced
/// from the stored waveform here so drawing never decodes or allocates.
struct NativeTimelineVoiceMessageRegion {
    enum Style {
        /// Drawn on its own capsule, outside a bubble.
        case plain
        case outgoingBubble
        case incomingBubble
        /// Discord's audio file player, the bottom row of its file card.
        case audioFile
    }

    let frame: CGRect
    let playFrame: CGRect
    let waveformFrame: CGRect
    let timeFrame: CGRect
    let speedFrame: CGRect
    let messageID: MessageID
    let attachment: Attachment
    let duration: TimeInterval
    let bars: [Float]
    let style: Style
    /// What an audio file's player draws on: its capsule, or a bubble.
    var surface: Style = .plain

    /// The style whose colours the player takes.
    var paletteStyle: Style { style == .audioFile ? surface : style }

    var playbackID: VoiceMessagePlaybackID {
        style == .audioFile ? .attachment(messageID, attachmentID: attachment.id) : .message(messageID)
    }

    var source: VoiceMessagePlaybackStore.Source {
        attachment.url.isFileURL ? .local(attachment.url) : .remote(attachment.url)
    }

    /// The length a voice message carries, or one learned for an audio file.
    func knownDuration(in playback: VoiceMessagePlaybackStore?) -> TimeInterval? {
        duration > 0 ? duration : playback?.knownDuration(of: source)
    }

    static func make(
        message: Message,
        origin: CGPoint,
        maximumWidth: CGFloat,
        style: Style
    ) -> Self? {
        guard (message.forwardedSnapshot?.flags ?? message.flags).contains(.voiceMessage),
              message.attachments.count == 1,
              let attachment = message.attachments.first,
              attachment.mediaKind == .audio
        else { return nil }
        let metrics = Metrics(style: style)
        let duration = max(0, attachment.durationSeconds ?? 0)
        let fixedWidth = metrics.leadingPadding + metrics.playDiameter + metrics.gap
            + metrics.gap + metrics.timeWidth + metrics.speedGap + metrics.speedSize.width
            + metrics.trailingPadding
        // Discord grows the waveform with duration, from 40 to 294 points.
        let nominal = duration <= 0.5 ? 40 : duration >= 45 ? 294 : 40 + (duration - 0.5) / 44.5 * 254
        let available = max(metrics.step * 4, maximumWidth - fixedWidth)
        let barCount = max(4, Int((min(InterfaceScale.metric(nominal), available) + metrics.spacing) / metrics.step))
        let waveformWidth = CGFloat(barCount) * metrics.step - metrics.spacing
        let frame = CGRect(
            x: origin.x,
            y: origin.y,
            width: fixedWidth + waveformWidth,
            height: metrics.height
        )
        var cursorX = frame.minX + metrics.leadingPadding
        let playFrame = CGRect(
            x: cursorX, y: frame.midY - metrics.playDiameter / 2,
            width: metrics.playDiameter, height: metrics.playDiameter
        )
        cursorX = playFrame.maxX + metrics.gap
        let waveformFrame = CGRect(
            x: cursorX, y: frame.midY - metrics.waveformHeight / 2,
            width: waveformWidth, height: metrics.waveformHeight
        )
        cursorX = waveformFrame.maxX + metrics.gap
        let timeFrame = CGRect(x: cursorX, y: frame.midY - metrics.timeHeight / 2, width: metrics.timeWidth, height: metrics.timeHeight)
        cursorX = timeFrame.maxX + metrics.speedGap
        let speedFrame = CGRect(
            x: cursorX, y: frame.midY - metrics.speedSize.height / 2,
            width: metrics.speedSize.width, height: metrics.speedSize.height
        )
        let values = VoiceMessageWaveform.decode(attachment.waveform) ?? []
        return Self(
            frame: frame,
            playFrame: playFrame,
            waveformFrame: waveformFrame,
            timeFrame: timeFrame,
            speedFrame: speedFrame,
            messageID: message.id,
            attachment: attachment,
            duration: duration,
            bars: VoiceMessageWaveform.bars(values, count: barCount),
            style: style
        )
    }

    /// An audio file card's player: its badge plays, and the seek row under
    /// its name holds the time, seek bar, and mute, with the seek bar in
    /// `waveformFrame` and mute in `speedFrame`.
    static func audioFile(in card: NativeTimelineFileCard, messageID: MessageID, surface: Style) -> Self {
        let row = card.playerRowFrame
        let mute = InterfaceScale.metric(24)
        let muteFrame = CGRect(
            x: card.downloadFrame.midX - mute / 2, y: row.midY - mute / 2, width: mute, height: mute
        )
        let duration = card.attachment.durationSeconds ?? 0
        let timeFrame = CGRect(x: row.minX, y: row.minY, width: audioFileTimeWidth(duration), height: row.height)
        let barMinX = timeFrame.maxX + InterfaceScale.metric(10)
        let barFrame = CGRect(
            x: barMinX, y: row.minY, width: max(1, muteFrame.minX - InterfaceScale.metric(8) - barMinX), height: row.height
        )
        return Self(
            frame: card.badgeFrame.union(row),
            playFrame: card.badgeFrame,
            waveformFrame: barFrame,
            timeFrame: timeFrame,
            speedFrame: muteFrame,
            messageID: messageID,
            attachment: card.attachment,
            duration: duration,
            bars: [],
            style: .audioFile,
            surface: surface
        )
    }

    /// The width of an audio file's "elapsed / length" label. Only a few
    /// lengths' digit counts occur, so drawing frames measure from a cache.
    private static func audioFileTimeWidth(_ duration: TimeInterval) -> CGFloat {
        let length = VoiceMessageDurationFormat.string(duration)
        let font = NativeTimelineVoiceMessagePainter.timeFont
        let key = "\(font.pointSize)|\(length)"
        if let width = audioFileTimeWidths[key] { return width }
        let width = ceil((length + "\u{2009}/\u{2009}" + length as NSString).size(withAttributes: [.font: font]).width)
        audioFileTimeWidths[key] = width
        return width
    }

    private static var audioFileTimeWidths: [String: CGFloat] = [:]

    /// An audio file's seek bar. Like Discord's flexible bar, it starts
    /// after the time label, which a length learned after layout can widen.
    func seekBarFrame(for duration: TimeInterval?) -> CGRect {
        let minX = max(waveformFrame.minX, timeFrame.minX + Self.audioFileTimeWidth(duration ?? 0) + InterfaceScale.metric(10))
        return CGRect(x: minX, y: waveformFrame.minY, width: max(1, waveformFrame.maxX - minX), height: waveformFrame.height)
    }

    struct Metrics {
        let style: Style
        var height: CGFloat { InterfaceScale.metric(style == .plain ? 48 : 36) }
        var leadingPadding: CGFloat { style == .plain ? InterfaceScale.metric(8) : 0 }
        var trailingPadding: CGFloat { style == .plain ? InterfaceScale.metric(12) : 0 }
        var playDiameter: CGFloat { InterfaceScale.metric(32) }
        var gap: CGFloat { InterfaceScale.metric(10) }
        var speedGap: CGFloat { InterfaceScale.metric(6) }
        var barWidth: CGFloat { InterfaceScale.metric(3) }
        var spacing: CGFloat { InterfaceScale.metric(3) }
        var step: CGFloat { barWidth + spacing }
        /// Taller than the tallest resting bar, so playback can bounce.
        var waveformHeight: CGFloat { InterfaceScale.metric(32) }
        var restingBarHeight: CGFloat { InterfaceScale.metric(22) }
        var minimumBarHeight: CGFloat { InterfaceScale.metric(3) }
        var timeHeight: CGFloat { InterfaceScale.metric(16) }
        var timeWidth: CGFloat {
            ceil(("00:00" as NSString).size(withAttributes: [.font: NativeTimelineVoiceMessagePainter.timeFont]).width)
        }
        var speedSize: CGSize { CGSize(width: InterfaceScale.metric(36), height: InterfaceScale.metric(20)) }
    }
}

/// What resting players in cached rows show beyond their own message.
struct VoiceMessageRestingPresentation: Equatable {
    var speed: Float = 1
    var isAudioFileMuted = false
    var knownDurationCount = 0

    init() {}

    init(_ playback: VoiceMessagePlaybackStore) {
        speed = playback.speed
        isAudioFileMuted = playback.isAudioFileMuted
        knownDurationCount = playback.knownDurationCount
    }
}

struct NativeTimelineVoiceMessageDrawState {
    var progress: CGFloat = 0
    var isPlaying = false
    var isLoading = false
    /// Fetching, before the spinner appears; frames keep coming so it can.
    var isFetching = false
    /// Seconds left while active; the full duration otherwise.
    var displayedTime: TimeInterval
    var speedLabel: String
    var level: CGFloat = 0
    /// Animation clock in seconds.
    var clock: TimeInterval = 0
    /// Reduce Motion keeps progress moving but stills the waveform ripple.
    var reducesMotion = false
    var isPlayHovered = false
    var isSpeedHovered = false
    /// An audio file's length, once known.
    var duration: TimeInterval?
    /// Where the pointer rests on an audio file's seek bar.
    var hoverFraction: CGFloat?
    var isMuted = false
    /// The row already draws this resting audio file, so its hover overlay
    /// adds only what the pointer changes.
    var isResting = false
}

enum NativeTimelineVoiceMessagePainter {
    private struct Fonts {
        let factor: CGFloat
        let time: NSFont
        let speed: NSFont
        let bubble: NSFont
    }

    private static var fonts: Fonts?

    /// Fonts are rebuilt only when the interface scale changes.
    private static var scaledFonts: Fonts {
        if let fonts, fonts.factor == InterfaceScale.factor { return fonts }
        let created = Fonts(
            factor: InterfaceScale.factor,
            time: .interfaceMonospacedDigitSystemFont(ofSize: 12, weight: .medium),
            speed: .interfaceSystemFont(ofSize: 11, weight: .semibold),
            bubble: .interfaceSystemFont(ofSize: 12, weight: .semibold)
        )
        fonts = created
        return created
    }

    static var timeFont: NSFont { scaledFonts.time }
    static var speedFont: NSFont { scaledFonts.speed }
    static var audioFileBubbleFont: NSFont { scaledFonts.bubble }

    /// The capsule behind a plain-style player. Bubble styles draw on the bubble.
    static func drawBackground(_ region: NativeTimelineVoiceMessageRegion) {
        guard region.style == .plain, let context = NSGraphicsContext.current?.cgContext else { return }
        // Matches the attachment placeholder; dynamic colours resolve without
        // a colour-space conversion on every raster.
        context.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.10).cgColor)
        let radius = region.frame.height / 2
        context.addPath(CGPath(roundedRect: region.frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    static func drawContent(_ region: NativeTimelineVoiceMessageRegion, state: NativeTimelineVoiceMessageDrawState) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if region.style == .audioFile {
            drawAudioFilePlayer(region, state: state, palette: Palette(style: region.paletteStyle), context: context)
            return
        }
        let palette = Palette(style: region.style)
        drawPlayButton(region, state: state, palette: palette, context: context)
        drawBars(region, state: state, palette: palette, context: context)
        drawTime(region, state: state, palette: palette)
        drawSpeed(region, state: state, palette: palette)
    }

    static func spinnerColor(for style: NativeTimelineVoiceMessageRegion.Style) -> NSColor {
        Palette(style: style).glyph
    }

    struct Palette {
        let buttonFill: NSColor
        let glyph: NSColor
        let played: NSColor
        let unplayed: NSColor
        let text: NSColor
        let chipFill: NSColor
        let chipHoverFill: NSColor
        let chipText: NSColor

        init(style: NativeTimelineVoiceMessageRegion.Style) {
            let accent = NSColor.sakuraCordAccentColor
            switch style {
            case .outgoingBubble:
                buttonFill = .white
                glyph = accent
                played = .white
                unplayed = NSColor.white.withAlphaComponent(0.42)
                text = NSColor.white.withAlphaComponent(0.88)
                chipFill = NSColor.white.withAlphaComponent(0.2)
                chipHoverFill = NSColor.white.withAlphaComponent(0.32)
                chipText = .white
            case .plain, .incomingBubble, .audioFile:
                buttonFill = accent
                glyph = .white
                played = accent
                unplayed = NSColor.labelColor.withAlphaComponent(0.3)
                text = .secondaryLabelColor
                chipFill = NSColor.labelColor.withAlphaComponent(0.09)
                chipHoverFill = NSColor.labelColor.withAlphaComponent(0.16)
                chipText = .secondaryLabelColor
            }
        }
    }

    static func drawPlayButton(
        _ region: NativeTimelineVoiceMessageRegion,
        state: NativeTimelineVoiceMessageDrawState,
        palette: Palette,
        context: CGContext
    ) {
        let frame = region.playFrame
        let scale: CGFloat = state.isPlayHovered ? 1.06 : 1
        let button = frame.insetBy(dx: frame.width * (1 - scale) / 2, dy: frame.height * (1 - scale) / 2)
        context.setFillColor(palette.buttonFill.cgColor)
        context.fillEllipse(in: button)
        context.setFillColor(palette.glyph.cgColor)
        let unit = frame.width / 32
        if state.isLoading {
            // The overlay's spinner layer turns on the render server, so it
            // keeps moving while the main thread is busy starting playback.
            return
        } else if state.isPlaying {
            for offset in [-4.0, 4.0] {
                let bar = CGRect(x: frame.midX + offset * unit - 1.75 * unit, y: frame.midY - 6.5 * unit,
                                 width: 3.5 * unit, height: 13 * unit)
                context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.2 * unit, cornerHeight: 1.2 * unit, transform: nil))
            }
            context.fillPath()
        } else {
            // Optically centred: a triangle's mass sits left of its bounds.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.midX - 4.5 * unit, y: frame.midY - 7 * unit))
            path.addLine(to: CGPoint(x: frame.midX + 7.5 * unit, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.midX - 4.5 * unit, y: frame.midY + 7 * unit))
            path.closeSubpath()
            context.addPath(path)
            context.setLineJoin(.round)
            context.setLineWidth(2 * unit)
            context.setStrokeColor(palette.glyph.cgColor)
            context.drawPath(using: .fillStroke)
        }
    }

    private static func drawBars(
        _ region: NativeTimelineVoiceMessageRegion,
        state: NativeTimelineVoiceMessageDrawState,
        palette: Palette,
        context: CGContext
    ) {
        let metrics = NativeTimelineVoiceMessageRegion.Metrics(style: region.style)
        let frame = region.waveformFrame
        let count = region.bars.count
        let playhead = state.progress * CGFloat(count)
        let playedCount = Int(playhead.rounded())
        let radius = metrics.barWidth / 2
        // Two fills per player rather than one per bar.
        let played = CGMutablePath()
        let unplayed = CGMutablePath()
        for (index, value) in region.bars.enumerated() {
            var height = metrics.minimumBarHeight + (metrics.restingBarHeight - metrics.minimumBarHeight) * CGFloat(value)
            if state.isPlaying, !state.reducesMotion {
                // Bars around the playhead swell with the audio being heard,
                // in a gentle travelling ripple.
                let distance = CGFloat(index) + 0.5 - playhead
                let swell = exp(-(distance * distance) / 5)
                let ripple = 0.72 + 0.28 * sin(CGFloat(state.clock) * 10 - CGFloat(index) * 0.85)
                height *= 1 + (0.18 + state.level * 0.95) * swell * ripple
            }
            height = min(frame.height, height)
            let bar = CGRect(
                x: frame.minX + CGFloat(index) * metrics.step,
                y: frame.midY - height / 2,
                width: metrics.barWidth,
                height: height
            )
            (index < playedCount ? played : unplayed)
                .addRoundedRect(in: bar, cornerWidth: radius, cornerHeight: radius)
        }
        for (path, color) in [(played, palette.played), (unplayed, palette.unplayed)] where !path.isEmpty {
            context.setFillColor(color.cgColor)
            context.addPath(path)
            context.fillPath()
        }
    }

    private static func drawTime(
        _ region: NativeTimelineVoiceMessageRegion,
        state: NativeTimelineVoiceMessageDrawState,
        palette: Palette
    ) {
        let text = region.duration > 0 || state.displayedTime > 0
            ? VoiceMessageDurationFormat.string(state.displayedTime)
            : "--:--"
        VoiceMessageLabelCache.draw(text, font: timeFont, color: palette.text, centeredIn: region.timeFrame, alignment: .left)
    }

    private static func drawSpeed(
        _ region: NativeTimelineVoiceMessageRegion,
        state: NativeTimelineVoiceMessageDrawState,
        palette: Palette
    ) {
        let frame = region.speedFrame
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor((state.isSpeedHovered ? palette.chipHoverFill : palette.chipFill).cgColor)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil))
        context.fillPath()
        VoiceMessageLabelCache.draw(state.speedLabel, font: speedFont, color: palette.chipText, centeredIn: frame, alignment: .center)
    }

    /// The resting appearance painted into cached row bitmaps.
    static func drawIdle(_ region: NativeTimelineVoiceMessageRegion, playback: VoiceMessagePlaybackStore?) {
        drawBackground(region)
        // The live overlay draws the active player above the row.
        guard playback?.isActive(region.playbackID) != true else { return }
        var state = NativeTimelineVoiceMessageDrawState(displayedTime: region.duration, speedLabel: playback?.speedLabel ?? "1×")
        if region.style == .audioFile {
            state.duration = region.knownDuration(in: playback)
            state.isMuted = playback?.isAudioFileMuted == true
            // An audio file left partway shows where it will resume.
            if let duration = state.duration, duration > 0, let position = playback?.position(of: region.playbackID) {
                state.progress = CGFloat(min(max(position / duration, 0), 1))
            }
        }
        drawContent(region, state: state)
    }
}

/// Players repeat a handful of labels ("0:07", "1×"), so their shaped lines
/// are reused. Lines take their colour from the context, so one entry serves
/// every appearance.
@MainActor
enum VoiceMessageLabelCache {
    private static var lines: [String: CTLine] = [:]

    static func draw(_ text: String, font: NSFont, color: NSColor, centeredIn frame: CGRect, alignment: NSTextAlignment) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let key = "\(font.fontName)|\(font.pointSize)|\(text)"
        let line: CTLine
        if let cached = lines[key] {
            line = cached
        } else {
            if lines.count > 256 { lines.removeAll(keepingCapacity: true) }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            lines[key] = line
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let originX = alignment == .center ? frame.midX - width / 2 : frame.minX
        context.saveGState()
        context.setFillColor(color.cgColor)
        // Row and overlay contexts are flipped; Core Text draws upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: originX, y: frame.midY + (ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Draws the one active voice message above its cached row, so playback
/// animates without re-rasterizing timeline rows.
final class NativeTimelineVoiceMessageOverlay: NSView {
    var region: NativeTimelineVoiceMessageRegion {
        didSet {
            needsDisplay = true
            layoutSpinner()
        }
    }

    var state: NativeTimelineVoiceMessageDrawState {
        didSet {
            needsDisplay = true
            if state.isLoading != oldValue.isLoading { updateSpinner() }
        }
    }

    private let spinner = CAShapeLayer()

    /// Supplies the live state for each animation frame.
    var refresh: (() -> NativeTimelineVoiceMessageDrawState?)?
    private let ticker = NativeTimelineDisplayLinkTicker()
    private var clockOrigin = ProcessInfo.processInfo.systemUptime

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(region: NativeTimelineVoiceMessageRegion, state: NativeTimelineVoiceMessageDrawState) {
        self.region = region
        self.state = state
        super.init(frame: region.frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        spinner.fillColor = nil
        spinner.lineCap = .round
        spinner.strokeEnd = 0.7
        layer?.addSublayer(spinner)
        layoutSpinner()
        updateSpinner()
    }

    private func layoutSpinner() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let button = region.playFrame.offsetBy(dx: -region.frame.minX, dy: -region.frame.minY)
        let unit = button.width / 32
        spinner.frame = button
        spinner.path = CGPath(
            ellipseIn: CGRect(x: button.width / 2 - 8 * unit, y: button.height / 2 - 8 * unit, width: 16 * unit, height: 16 * unit),
            transform: nil
        )
        spinner.lineWidth = 2.4 * unit
        effectiveAppearance.performAsCurrentDrawingAppearance {
            spinner.strokeColor = NativeTimelineVoiceMessagePainter.spinnerColor(for: region.paletteStyle).cgColor
        }
    }

    private func updateSpinner() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        spinner.isHidden = !state.isLoading
        guard state.isLoading else {
            spinner.removeAnimation(forKey: "spin")
            return
        }
        guard spinner.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 0.8
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        spinner.add(spin, forKey: "spin")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutSpinner()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    /// Runs a display link only while something moves.
    func updateAnimation() {
        let animates = window != nil && (state.isPlaying || state.isLoading || state.isFetching)
        if animates, ticker.displayLink == nil {
            ticker.start(on: self) { [weak self] in self?.tick() }
        } else if !animates, ticker.displayLink != nil {
            ticker.stop()
        }
    }

    private func tick() {
        guard var next = refresh?() else { return }
        next.clock = ProcessInfo.processInfo.systemUptime - clockOrigin
        state = next
    }

    func stop() {
        ticker.stop()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // The overlay's bounds are the region's frame.
        context.translateBy(x: -region.frame.minX, y: -region.frame.minY)
        NativeTimelineVoiceMessagePainter.drawContent(region, state: state)
        context.restoreGState()
    }
}

extension NativeTimelineCanvasView {
    enum VoiceMessageControl: Equatable {
        case play
        case waveform
        case speed
    }

    struct VoiceMessagePointerHit {
        let row: NativeMessageTimelineItem.Identifier
        let region: NativeTimelineVoiceMessageRegion
        let control: VoiceMessageControl
        let origin: CGFloat

        /// Whether a release lands on the control this press began on. A row
        /// can hold several audio files, so the player has to match too.
        func isReleased(on released: VoiceMessagePointerHit?) -> Bool {
            released?.row == row && released?.region.playbackID == region.playbackID && released?.control == control
        }
    }

    /// The voice message or audio file control under `point`. An audio
    /// file's controls fill its player row, so they take no extra margin.
    func voiceMessagePointerHit(at point: CGPoint) -> VoiceMessagePointerHit? {
        guard WindowModalCoordinator.allowsInput(for: self),
              let index = rowIndex(at: point.y),
              layouts.indices.contains(index), items.indices.contains(index)
        else { return nil }
        let origin = displayedRowOrigin(at: index)
        let local = CGPoint(x: point.x, y: point.y - origin)
        for region in layouts[index].audioPlayers where region.frame.contains(local) && !isConcealedSpoiler(region.attachment, in: region.messageID) {
            let slop: CGFloat = region.style == .audioFile ? 0 : 1
            let control: VoiceMessageControl
            if region.playFrame.insetBy(dx: -4 * slop, dy: -4 * slop).contains(local) {
                control = .play
            } else if region.speedFrame.insetBy(dx: -3 * slop, dy: -6 * slop).contains(local) {
                control = .speed
            } else if region.waveformFrame.insetBy(dx: -4 * slop, dy: -6 * slop).contains(local) {
                control = .waveform
            } else {
                continue
            }
            return VoiceMessagePointerHit(row: items[index].identifier, region: region, control: control, origin: origin)
        }
        return nil
    }

    /// Returns true when the press belongs to a voice message.
    func beginVoiceMessagePress(at point: CGPoint) -> Bool {
        guard let hit = voiceMessagePointerHit(at: point), let playback = model?.voiceMessagePlayback else { return false }
        voiceMessagePress = hit
        if hit.control == .waveform {
            playback.beginScrub(hit.region.playbackID, source: hit.region.source, duration: hit.region.knownDuration(in: playback))
            scrubVoiceMessage(hit, to: point)
        }
        return true
    }

    func dragVoiceMessagePress(to point: CGPoint) -> Bool {
        guard let press = voiceMessagePress else { return false }
        if press.control == .waveform { scrubVoiceMessage(press, to: point) }
        return true
    }

    func endVoiceMessagePress(at point: CGPoint) -> Bool {
        guard let press = voiceMessagePress else { return false }
        voiceMessagePress = nil
        guard let playback = model?.voiceMessagePlayback else { return true }
        let released = voiceMessagePointerHit(at: point)
        switch press.control {
        case .waveform:
            playback.endScrub(press.region.playbackID)
        case .play:
            if press.isReleased(on: released) {
                playback.toggle(press.region.playbackID, source: press.region.source, duration: press.region.knownDuration(in: playback))
            }
        case .speed:
            guard press.isReleased(on: released) else { break }
            if press.region.style == .audioFile { playback.toggleAudioFileMute() } else { playback.cycleSpeed() }
        }
        return true
    }

    private func scrubVoiceMessage(_ press: VoiceMessagePointerHit, to point: CGPoint) {
        guard let playback = model?.voiceMessagePlayback else { return }
        let region = press.region
        let frame = region.style == .audioFile
            ? region.seekBarFrame(for: playback.duration(of: region.playbackID) ?? region.knownDuration(in: playback))
            : region.waveformFrame
        let fraction = (point.x - frame.minX) / max(frame.width, 1)
        playback.seek(press.region.playbackID, source: press.region.source,
                      duration: press.region.knownDuration(in: playback), fraction: Double(fraction))
    }

    func updateVoiceMessageHover(at point: CGPoint?) {
        let hit = point.flatMap { voiceMessagePointerHit(at: $0) }
        let hovered = hit.map {
            VoiceMessageHover(
                playbackID: $0.region.playbackID, control: $0.control,
                // An audio file's seek bar follows the pointer.
                pointerX: $0.region.style == .audioFile && $0.control == .waveform ? point?.x : nil
            )
        }
        guard hovered != hoveredVoiceMessage else { return }
        if let hit, hit.region.style == .audioFile, hovered?.playbackID != hoveredVoiceMessage?.playbackID {
            model?.voiceMessagePlayback.measureDuration(of: hit.region.source)
        }
        // Moving along a seek bar only redraws; reaching or leaving an audio
        // file places or removes its hover overlay.
        let reconciles = hovered?.playbackID != hoveredVoiceMessage?.playbackID
            && (hovered?.playbackID.isAudioFile == true || hoveredVoiceMessage?.playbackID.isAudioFile == true)
        hoveredVoiceMessage = hovered
        if reconciles { reconcileVoiceMessageOverlay() } else { refreshVoiceMessageOverlay() }
    }

    /// Fetches on-screen voice messages into the media cache, as images are.
    /// Audio files, which can be large, wait to be hovered or played.
    func prefetchVisibleVoiceMessages() {
        let viewport = enclosingScrollView?.documentVisibleRect ?? visibleRect
        guard let playback = model?.voiceMessagePlayback, var index = rowIndex(at: max(0, viewport.minY)) else { return }
        while items.indices.contains(index), layouts.indices.contains(index), displayedRowOrigin(at: index) < viewport.maxY {
            if case let .remote(url) = layouts[index].voiceMessageRegion?.source { playback.prefetch(url) }
            index += 1
        }
    }

    struct VoiceMessageHover: Equatable {
        let playbackID: VoiceMessagePlaybackID
        let control: VoiceMessageControl
        /// The pointer's position over an audio file's seek bar.
        var pointerX: CGFloat?
    }

    // MARK: Overlay

    @objc func voiceMessagePlaybackDidChange(_ notification: Notification) {
        guard let playback = model?.voiceMessagePlayback, notification.object as AnyObject === playback else { return }
        if playback.activeID != voiceMessageActiveID {
            let previous = voiceMessageActiveID
            voiceMessageActiveID = playback.activeID
            // Row bitmaps omit the active player's content; repaint both rows.
            invalidateVoiceMessageBitmaps(playbackIDs: Set([previous, playback.activeID].compactMap { $0 }))
        }
        // Cached rows hold the speed label, mute state, and learned lengths
        // too, including other conversations.
        let resting = VoiceMessageRestingPresentation(playback)
        if resting != voiceMessageResting {
            voiceMessageResting = resting
            invalidateVoiceMessageBitmaps()
        }
        reconcileVoiceMessageOverlay()
    }

    func invalidateVoiceMessageRow(_ identifier: NativeMessageTimelineItem.Identifier) {
        invalidateBitmap(identifier)
        if let index = visibleRowIndex(of: identifier) { setNeedsDisplay(rowFrame(at: index)) }
    }

    private func invalidateVoiceMessageBitmaps(playbackIDs: Set<VoiceMessagePlaybackID>? = nil) {
        // Bitmaps survive navigation, so the current layouts alone cannot
        // identify every row whose playback presentation has changed.
        let identifiers = bitmapCache.compactMap { identifier, cached in
            guard let message = cached.item.messageRow?.message else { return nil as NativeMessageTimelineItem.Identifier? }
            var players = message.attachments.filter { $0.mediaKind == .audio }.map { VoiceMessagePlaybackID.attachment(message.id, attachmentID: $0.id) }
            if (message.forwardedSnapshot?.flags ?? message.flags).contains(.voiceMessage) { players.append(.message(message.id)) }
            guard !players.isEmpty, playbackIDs.map({ !$0.isDisjoint(with: players) }) ?? true else { return nil }
            return identifier
        }
        for identifier in identifiers {
            invalidateBitmap(identifier)
        }
        setNeedsDisplay(visibleRect)
    }

    /// Searches only the rows on screen, so scrolling stays independent of
    /// conversation length.
    private func visibleRowIndex(of identifier: NativeMessageTimelineItem.Identifier) -> Int? {
        guard var index = rowIndex(at: max(0, visibleRect.minY)) else { return nil }
        while items.indices.contains(index), displayedRowOrigin(at: index) < visibleRect.maxY {
            if items[index].identifier == identifier { return index }
            index += 1
        }
        return nil
    }

    /// Shows the live overlay while the active voice message or audio file
    /// is on screen, and a second over a hovered audio file's seek bar.
    func reconcileVoiceMessageOverlay() {
        // A timeline opened mid-playback has not seen a change notification yet.
        if let playback = model?.voiceMessagePlayback { voiceMessageActiveID = playback.activeID }
        let hoveredAudioFile = hoveredVoiceMessage.flatMap { $0.playbackID.isAudioFile ? $0.playbackID : nil }
        placeVoiceMessageOverlay(&voiceMessageOverlay, for: voiceMessageActiveID)
        placeVoiceMessageOverlay(
            &voiceMessageHoverOverlay, for: hoveredAudioFile == voiceMessageActiveID ? nil : hoveredAudioFile
        )
    }

    private func placeVoiceMessageOverlay(
        _ overlay: inout NativeTimelineVoiceMessageOverlay?,
        for playbackID: VoiceMessagePlaybackID?
    ) {
        var found: (region: NativeTimelineVoiceMessageRegion, origin: CGFloat)?
        if let playbackID, var index = rowIndex(at: max(0, visibleRect.minY)) {
            while found == nil, items.indices.contains(index), layouts.indices.contains(index),
                  displayedRowOrigin(at: index) < visibleRect.maxY
            {
                found = layouts[index].audioPlayers.first { $0.playbackID == playbackID }
                    .map { ($0, displayedRowOrigin(at: index)) }
                index += 1
            }
        }
        guard let found, let playback = model?.voiceMessagePlayback else {
            Self.remove(&overlay)
            return
        }
        let frame = found.region.frame.offsetBy(dx: 0, dy: found.origin)
        let state = voiceMessageDrawState(for: found.region, playback: playback)
        if let overlay {
            overlay.region = found.region
            overlay.frame = frame
            overlay.state = state
            overlay.updateAnimation()
        } else {
            let created = NativeTimelineVoiceMessageOverlay(region: found.region, state: state)
            created.frame = frame
            created.refresh = { [weak self, weak created] in
                guard let self, let created, let playback = self.model?.voiceMessagePlayback else { return nil }
                return self.voiceMessageDrawState(for: created.region, playback: playback)
            }
            addSubview(created, positioned: .below, relativeTo: mediaViewerHost)
            overlay = created
            created.updateAnimation()
        }
    }

    func refreshVoiceMessageOverlay() {
        guard let playback = model?.voiceMessagePlayback else { return }
        for overlay in [voiceMessageOverlay, voiceMessageHoverOverlay].compactMap(\.self) {
            var state = voiceMessageDrawState(for: overlay.region, playback: playback)
            state.clock = overlay.state.clock
            overlay.state = state
        }
    }

    func removeVoiceMessageOverlay() {
        Self.remove(&voiceMessageOverlay)
        Self.remove(&voiceMessageHoverOverlay)
    }

    private static func remove(_ overlay: inout NativeTimelineVoiceMessageOverlay?) {
        overlay?.stop()
        overlay?.removeFromSuperview()
        overlay = nil
    }

    func voiceMessageDrawState(
        for region: NativeTimelineVoiceMessageRegion,
        playback: VoiceMessagePlaybackStore
    ) -> NativeTimelineVoiceMessageDrawState {
        let id = region.playbackID
        let knownDuration = playback.duration(of: id) ?? region.knownDuration(in: playback)
        let duration = knownDuration ?? 0
        let position = playback.position(of: id)
        let phase = playback.phase(of: id)
        let hovered = hoveredVoiceMessage?.playbackID == id ? hoveredVoiceMessage : nil
        let hover = hovered?.control
        var state = NativeTimelineVoiceMessageDrawState(
            progress: duration > 0 ? CGFloat(min(max(position / duration, 0), 1)) : 0,
            isPlaying: phase == .playing,
            isLoading: playback.isLoading(id),
            isFetching: phase == .loading,
            displayedTime: phase == nil ? region.duration : max(0, duration - position),
            speedLabel: playback.speedLabel,
            level: CGFloat(playback.outputLevel),
            reducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            isPlayHovered: hover == .play,
            isSpeedHovered: hover == .speed
        )
        if region.style == .audioFile {
            state.duration = knownDuration
            state.isMuted = playback.isAudioFileMuted
            state.isResting = !playback.isActive(id)
            let bar = region.seekBarFrame(for: state.duration)
            state.hoverFraction = hovered?.pointerX.map { min(max(($0 - bar.minX) / max(bar.width, 1), 0), 1) }
        }
        return state
    }
}
