import AppKit
import QuartzCore

struct NativeTimelineSpoilerOverlayPresentation: Hashable {
    let cornerRadius: CGFloat
}

/// Discord's one spoiler look, shared by text, media, files, embeds and
/// components. Lengths are Discord's CSS pixels at SakuraCord's text size.
nonisolated enum NativeTimelineSpoilerAppearance {
    static var pillHeight: CGFloat { DiscordRichMessageMetrics.px(31) }
    static var pillHorizontalPadding: CGFloat { DiscordRichMessageMetrics.px(12) }
    static var textCornerRadius: CGFloat { DiscordRichMessageMetrics.px(4) }
    /// Discord blurs hidden media by 44 pixels, past recognition.
    static var blurRadius: CGFloat { DiscordRichMessageMetrics.px(44) }
    static let mediaRevealDuration: CFTimeInterval = 0.1
    static let textRevealDuration: CFTimeInterval = 0.2

    /// Behind hidden media and over hidden text: Discord's midnight theme in
    /// dark mode, which matches SakuraCord's near-black timeline, and its
    /// light theme otherwise.
    static let hiddenColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x59 / 255, green: 0x5A / 255, blue: 0x63 / 255, alpha: 1)
            : NSColor(srgbRed: 0x8F / 255, green: 0x90 / 255, blue: 0x97 / 255, alpha: 1)
    }

    static let hoveredTextColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x76 / 255, green: 0x77 / 255, blue: 0x80 / 255, alpha: 1)
            : NSColor(srgbRed: 0x70 / 255, green: 0x71 / 255, blue: 0x7A / 255, alpha: 1)
    }

    /// A revealed text spoiler keeps a faint fill, so it still reads as one.
    static let revealedTextColor = NSColor(srgbRed: 0x97 / 255, green: 0x97 / 255, blue: 0x9F / 255, alpha: 0.12)

    static let pillColor = NSColor.black.withAlphaComponent(0.6)
    /// Over the drawn pill, this darkens it to Discord's hovered 88 percent.
    static let hoveredPillOverlayColor = NSColor.black.withAlphaComponent(0.7)

    /// Discord's pill sits on items at least as wide as its 216-pixel upload
    /// tiles. A smaller tile, such as a staged attachment, scales the pill to
    /// match; on a thumbnail too small to read it, the blur stands alone.
    static func pillScale(forTileWidth width: CGFloat) -> CGFloat? {
        let scale = min(1, width / DiscordRichMessageMetrics.px(216))
        return scale >= 0.5 ? scale : nil
    }

    static func textBackgroundColor(isHovered: Bool) -> NSColor {
        isHovered ? hoveredTextColor : hiddenColor
    }

    static func pillLabel(isHovered: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(
            string: "SPOILER",
            attributes: [
                .font: NSFont.systemFont(ofSize: DiscordRichMessageMetrics.px(15), weight: .semibold),
                .foregroundColor: isHovered
                    ? NSColor.white
                    : NSColor(srgbRed: 0xE4 / 255, green: 0xE4 / 255, blue: 0xE6 / 255, alpha: 1),
                .kern: DiscordRichMessageMetrics.px(0.5),
                .paragraphStyle: paragraph,
            ]
        )
    }

    /// Hides the glyphs and text decorations of a hidden text spoiler while
    /// keeping its layout. Apply it after every other color adjustment; a
    /// revealed spoiler omits it and keeps its real colors.
    static func concealText(
        in value: NSMutableAttributedString,
        range: NSRange
    ) {
        for key: NSAttributedString.Key in [
            .foregroundColor,
            .underlineColor,
            .strikethroughColor,
        ] {
            value.addAttribute(key, value: NSColor.clear, range: range)
        }
    }

    static func pillFrame(
        in bounds: CGRect,
        measuredLabelWidth: CGFloat
    ) -> CGRect {
        let width = min(
            max(1, bounds.width),
            ceil(measuredLabelWidth) + pillHorizontalPadding * 2
        )
        let height = min(max(1, bounds.height), pillHeight)
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func labelFrame(
        in bounds: CGRect,
        measuredLabelHeight: CGFloat
    ) -> CGRect {
        let height = min(
            max(1, bounds.height),
            ceil(measuredLabelHeight)
        )
        return CGRect(
            x: bounds.minX,
            y: bounds.midY - height / 2,
            width: bounds.width,
            height: height
        )
    }

    static func isActivationKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 36, 49, 76:
            return true
        default:
            return false
        }
    }
}

/// The interactive part of a media spoiler cover. The row draws the cover
/// itself, so the cover is never missing while this view comes and goes;
/// this view adds hover, keyboard focus and activation.
@MainActor
final class NativeTimelineSpoilerOverlayHost: NSView {
    let cornerRadius: CGFloat
    let revealAction: () -> Void
    /// Darkens the row's pill while the pointer is over the cover.
    let pillView = NSView()
    let pillLabel = NSTextField(labelWithString: "SPOILER")
    var trackingArea: NSTrackingArea?
    var isHovered = false {
        didSet { pillView.isHidden = !isHovered }
    }
    var isPressed = false
    var didActivate = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        frame: CGRect,
        cornerRadius: CGFloat,
        reveal: @escaping () -> Void
    ) {
        self.cornerRadius = cornerRadius
        revealAction = reveal
        super.init(frame: frame)
        wantsLayer = true
        pillView.wantsLayer = true
        pillView.layer?.cornerRadius =
            NativeTimelineSpoilerAppearance.pillHeight / 2
        pillView.layer?.masksToBounds = true
        pillView.layer?.backgroundColor =
            NativeTimelineSpoilerAppearance.hoveredPillOverlayColor.cgColor
        pillView.setAccessibilityElement(false)
        addSubview(pillView)
        pillLabel.attributedStringValue =
            NativeTimelineSpoilerAppearance.pillLabel(isHovered: true)
        pillLabel.alignment = .center
        pillLabel.lineBreakMode = .byClipping
        pillLabel.setAccessibilityElement(false)
        pillView.addSubview(pillLabel)
        pillView.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Reveal spoiler")
        setAccessibilityHelp("Reveals the spoiler without opening it")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let labelSize = pillLabel.attributedStringValue.size()
        pillView.frame = NativeTimelineSpoilerAppearance.pillFrame(
            in: bounds,
            measuredLabelWidth: labelSize.width
        )
        pillLabel.frame = NativeTimelineSpoilerAppearance.labelFrame(
            in: pillView.bounds,
            measuredLabelHeight: labelSize.height
        )
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates.
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        window?.makeFirstResponder(self)
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        let activates =
            isPressed
            && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if activates {
            activate()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func otherMouseDown(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        if NativeTimelineSpoilerAppearance.isActivationKey(event) {
            activate()
        } else {
            super.keyDown(with: event)
        }
    }

    nonisolated override func accessibilityActionNames()
        -> [NSAccessibility.Action]
    {
        [.press]
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            activate()
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.sakuraCordAccentColor.setStroke()
            let focus = NSBezierPath(
                concentricRoundedRect: bounds.insetBy(dx: InterfaceScale.metric(2), dy: InterfaceScale.metric(2)),
                cornerRadius: max(1, cornerRadius - 2)
            )
            focus.lineWidth = 2
            focus.stroke()
        }
    }

#if DEBUG
    var hasPersistentPillForTesting: Bool {
        pillView.superview === self
            && pillLabel.superview === pillView
    }
#endif

    func activate() {
        guard !didActivate else { return }
        didActivate = true
        revealAction()
    }
}

/// Presents decoded raster animation frames on Core Animation's compositor.
/// The outer view is deliberately transparent so the selection tint can
/// extend beyond the clipped media box exactly as the Core Text painter does.
