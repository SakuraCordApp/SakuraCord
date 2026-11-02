import AppKit

/// The copy button over a hovered code block. The canvas owns its hover,
/// press, and click; this view fades in and out with the block's hover,
/// shows a plate under the pointer, and confirms a copy by drawing a
/// checkmark in place of its glyph for a moment.
@MainActor
final class NativeTimelineCodeCopyControl: NSView {
    private let plate = CALayer()
    private let glyphs = NSView()
    private let copyGlyph = NSImageView()
    private let copiedGlyph = NSImageView()
    private var shown: NativeTimelineCodeBlockPointerTarget?
    private var revert: Task<Void, Never>?
    private var state = State(isShown: false, isHovered: false, isPressed: false)

    private struct State: Equatable {
        let isShown: Bool
        let isHovered: Bool
        let isPressed: Bool
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.opacity = 0
        plate.cornerCurve = .continuous
        layer?.addSublayer(plate)
        glyphs.wantsLayer = true
        glyphs.layer?.opacity = 0.7
        addSubview(glyphs)
        for glyph in [copyGlyph, copiedGlyph] {
            // A symbol keeps its point size in every state instead of
            // scaling to the view.
            glyph.imageScaling = .scaleNone
            glyph.wantsLayer = true
            glyphs.addSubview(glyph)
        }
        hideCopiedGlyph()
        // The canvas voices the button as its own element.
        setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The canvas hit tests the button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the button over `target`'s block, or hides it.
    func update(target: NativeTimelineCodeBlockPointerTarget?, isHovered: Bool, isPressed: Bool) {
        if let target, target != shown {
            // A different block shows its own copy glyph at once.
            let isAnotherBlock = shown.map {
                $0.itemIdentifier != target.itemIdentifier || $0.region != target.region
                    || $0.rangeLocation != target.rangeLocation
            } ?? true
            // Interface Size may have changed since the button last showed.
            let copyImage = Self.symbol("doc.on.doc", pointSize: 13, color: .labelColor)
            if isAnotherBlock || copyGlyph.image?.size != copyImage.size {
                copyGlyph.image = copyImage
                // A checkmark is a lighter shape than the copy glyph, so it
                // is set larger to look the same size.
                copiedGlyph.image = Self.symbol("checkmark", pointSize: 15, color: Self.copiedColor)
                resetGlyph(animated: false)
            }
            frame = target.copyButtonFrame
            glyphs.frame = bounds
            for glyph in [copyGlyph, copiedGlyph] { centre(glyph) }
            withoutActions {
                plate.frame = bounds
                plate.cornerRadius = NativeTimelineMarkdownChromeMetrics.codeCopyButtonCornerRadius
            }
        }
        let state = State(isShown: target != nil, isHovered: isHovered, isPressed: isPressed)
        shown = target ?? shown
        guard state != self.state else { return }
        let duration = isPressed ? 0.08 : 0.15
        if state.isShown != self.state.isShown {
            animate(layer, "opacity", to: state.isShown ? 1 : 0, duration: duration)
        }
        self.state = state
        animate(glyphs.layer, "opacity", to: isHovered ? 1 : 0.7, duration: duration)
        animate(plate, "backgroundColor", to: plateColor, duration: duration)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withoutActions { plate.backgroundColor = plateColor }
    }

    /// The plate's fill for the current state, in the view's appearance.
    private var plateColor: CGColor {
        var color = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor
                .withAlphaComponent(state.isPressed ? 0.22 : state.isHovered ? 0.1 : 0).cgColor
        }
        return color
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    /// Centres a symbol by its outline, its alignment rect, rather than by
    /// its image's padded box.
    private func centre(_ glyph: NSImageView) {
        guard let image = glyph.image else { return }
        let outline = image.alignmentRect
        glyph.frame = bounds.offsetBy(
            dx: image.size.width / 2 - outline.midX,
            // `glyphs` is unflipped, so a positive offset moves a glyph up.
            dy: image.size.height / 2 - outline.midY
        )
    }

    /// Moves `layer`'s value to `value` from wherever it is on screen, so a
    /// change that interrupts another continues without a jump.
    private func animate(
        _ layer: CALayer?,
        _ key: String,
        to value: Any,
        duration: CFTimeInterval,
        delay: CFTimeInterval = 0
    ) {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = (layer.presentation() ?? layer).value(forKey: key)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        }
        withoutActions { layer.setValue(value, forKey: key) }
        layer.add(animation, forKey: key)
    }

    /// Fades the copy glyph out, draws a checkmark on in its place, and
    /// later fades back. One glyph is gone before the other shows, so the
    /// two never overlap.
    func confirmCopy() {
        revert?.cancel()
        animate(copyGlyph.layer, "opacity", to: 0, duration: 0.12)
        revert = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.12))
            guard !Task.isCancelled, let self else { return }
            hideCopiedGlyph()
            copiedGlyph.addSymbolEffect(.drawOn)
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            resetGlyph(animated: true)
        }
    }

    private func resetGlyph(animated: Bool) {
        revert?.cancel()
        revert = nil
        guard animated else {
            copyGlyph.layer?.removeAllAnimations()
            copyGlyph.layer?.opacity = 1
            hideCopiedGlyph()
            return
        }
        // A drawn-off checkmark lingers in fragments, so it fades instead.
        animate(copiedGlyph.layer, "opacity", to: 0, duration: 0.12)
        animate(copyGlyph.layer, "opacity", to: 1, duration: 0.15, delay: 0.12)
        revert = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.12))
            guard !Task.isCancelled else { return }
            self?.hideCopiedGlyph()
        }
    }

    /// Takes the checkmark off without animation, ready to draw on again.
    private func hideCopiedGlyph() {
        copiedGlyph.addSymbolEffect(.drawOff, animated: false)
        copiedGlyph.layer?.removeAllAnimations()
        copiedGlyph.layer?.opacity = 1
    }

    /// Discord's success green, as the app's other confirmations use.
    private static let copiedColor = NSColor(srgbRed: 0x23 / 255, green: 0xA5 / 255, blue: 0x5A / 255, alpha: 1)

    /// Each glyph carries its colour, so neither tints when the other shows.
    private static func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: InterfaceScale.fontSize(pointSize), weight: .medium)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
    }
}
