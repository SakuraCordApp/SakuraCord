import AppKit
import QuartzCore

/// The interactive part of a media spoiler cover. The row draws the cover
/// itself, so the cover is never missing while this view comes and goes;
/// this view adds hover, keyboard focus and activation.
@MainActor
final class NativeTimelineSpoilerOverlayHost: NSView {
    let cornerRadius: CGFloat
    /// Reveals the spoiler; false when the timeline refused the press, so the cover stays usable.
    let revealAction: () -> Bool
    /// Tints the cover while the pointer is over it, as a text spoiler's
    /// fill tints.
    let tintView = NSView()
    /// Darkens the row's pill while the pointer is over the cover.
    let pillView = NSView()
    let pillLabel = NSTextField(labelWithString: "SPOILER")
    var trackingArea: NSTrackingArea?
    var isHovered = false {
        didSet { updateHover(animated: true) }
    }
    var isPressed = false
    var didActivate = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        frame: CGRect,
        cornerRadius: CGFloat,
        reveal: @escaping () -> Bool
    ) {
        self.cornerRadius = cornerRadius
        revealAction = reveal
        super.init(frame: frame)
        wantsLayer = true
        tintView.wantsLayer = true
        tintView.layer?.cornerRadius = cornerRadius
        tintView.layer?.cornerCurve = .continuous
        tintView.alphaValue = 0
        tintView.setAccessibilityElement(false)
        addSubview(tintView)
        pillView.wantsLayer = true
        pillView.layer?.masksToBounds = true
        pillView.layer?.backgroundColor =
            SpoilerAppearance.hoveredPillOverlayColor.cgColor
        pillView.setAccessibilityElement(false)
        addSubview(pillView)
        pillLabel.alignment = .center
        pillLabel.lineBreakMode = .byClipping
        pillLabel.setAccessibilityElement(false)
        pillView.addSubview(pillLabel)
        pillView.alphaValue = 0
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
        tintView.frame = bounds
        updateHover(animated: false)
        // The same pill the row draws under this view.
        guard let pill = NativeTimelineSpoilerCover.pill(in: bounds, isHovered: true) else { return }
        pillLabel.attributedStringValue = pill.label
        pillView.frame = pill.frame
        pillView.layer?.cornerRadius = pill.frame.height / 2
        pillLabel.frame = SpoilerAppearance.labelFrame(
            in: pillView.bounds,
            measuredLabelHeight: pill.label.size().height
        )
    }

    /// Eases the hover in or out on the timeline's hover curve.
    private func updateHover(animated: Bool) {
        // A cover too small for the row to draw a pill on has none to darken.
        let hasPill = SpoilerAppearance.pillScale(forTileWidth: bounds.width) != nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && AppMotionPolicy.animatesUncategorized
                ? NativeTimelineComponentButtonVisualState.hoverAnimationDuration : 0
            context.timingFunction = NativeTimelineComponentButtonVisualState.hoverTimingFunction
            tintView.animator().alphaValue = isHovered ? 1 : 0
            pillView.animator().alphaValue = isHovered && hasPill ? 1 : 0
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTintColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTintColor()
    }

    private func updateTintColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tintView.layer?.backgroundColor = SpoilerAppearance.mediaHoverTintColor.cgColor
        }
    }

    override func resetCursorRects() {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        addCursorRect(bounds, cursor: .pointingHand)
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
        if SpoilerAppearance.isActivationKey(event) {
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
            return didActivate
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
        didActivate = revealAction()
    }
}

#if DEBUG
    extension NativeTimelineCanvasView {
        var spoilerOverlayFramesForTesting:
            [NativeTimelineComponentRevealKey: CGRect]
        {
            spoilerOverlays.mapValues(\.frame)
        }

        var spoilerOverlayPillKeysForTesting:
            Set<NativeTimelineComponentRevealKey>
        {
            Set(
                spoilerOverlays.compactMap { key, overlay in
                    overlay.hasPersistentPillForTesting ? key : nil
                }
            )
        }
    }
#endif
