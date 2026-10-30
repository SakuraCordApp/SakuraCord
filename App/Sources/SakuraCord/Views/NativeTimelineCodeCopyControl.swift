import AppKit

/// The copy button over a hovered code block. The canvas owns its hover,
/// press, and click; this view shows them like the timeline's other round
/// controls, fades in and out with the block's hover, and confirms a copy
/// by turning its glyph into a checkmark for a moment.
@MainActor
final class NativeTimelineCodeCopyControl: NSView {
    private static let copySymbol = "doc.on.doc"
    private static let copiedSymbol = "checkmark"
    private static var glyphInset: CGFloat { InterfaceScale.metric(7) }

    private let glyph = NSImageView()
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
        layer?.cornerCurve = .continuous
        alphaValue = 0
        // The canvas voices the button as its own element.
        setAccessibilityHidden(true)
        glyph.image = Self.symbol(Self.copySymbol)
        addSubview(glyph)
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
            if isAnotherBlock { resetGlyph(animated: false) }
            // Interface Size may have changed since the button last showed.
            layer?.cornerRadius = InterfaceScale.metric(6)
            glyph.symbolConfiguration = .init(pointSize: InterfaceScale.fontSize(13), weight: .medium)
            frame = target.copyButtonFrame
            glyph.frame = bounds.insetBy(dx: Self.glyphInset, dy: Self.glyphInset)
        }
        let state = State(isShown: target != nil, isHovered: isHovered, isPressed: isPressed)
        shown = target ?? shown
        guard state != self.state else { return }
        self.state = state
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isPressed ? 0.08 : 0.16
            context.allowsImplicitAnimation = true
            animator().alphaValue = target == nil ? 0 : 1
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isPressed ? 0.16 : isHovered ? 0.1 : 0).cgColor
            }
            glyph.animator().alphaValue = isHovered ? 1 : 0.7
            // Pressing sinks the glyph a little, as the timeline's buttons dip.
            glyph.animator().frame = bounds.insetBy(
                dx: Self.glyphInset + (isPressed ? 1.5 : 0), dy: Self.glyphInset + (isPressed ? 1.5 : 0)
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(state.isPressed ? 0.16 : state.isHovered ? 0.1 : 0).cgColor
        }
    }

    /// Turns the glyph into a checkmark, then back.
    func confirmCopy() {
        glyph.setSymbolImage(Self.symbol(Self.copiedSymbol), contentTransition: .replace.downUp)
        glyph.contentTintColor = .systemGreen
        revert?.cancel()
        revert = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.resetGlyph(animated: true)
        }
    }

    private func resetGlyph(animated: Bool) {
        revert?.cancel()
        revert = nil
        glyph.contentTintColor = nil
        if animated {
            glyph.setSymbolImage(Self.symbol(Self.copySymbol), contentTransition: .replace.upUp)
        } else {
            glyph.image = Self.symbol(Self.copySymbol)
        }
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }
}
