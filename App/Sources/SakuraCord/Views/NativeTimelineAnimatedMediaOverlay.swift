import AppKit
import QuartzCore
import SwiftUI

final class NativeTimelineAnimatedMediaOverlay: NSView {
    let imageClipView = NSView()
    let imageView = AnimatedImageCanvas()
    let selectionView = NSView()
    private var isScrollSuppressed = false
    private var isHoverPlaybackEnabled = true

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        imageClipView.wantsLayer = true
        imageClipView.layer?.masksToBounds = true
        addSubview(imageClipView)

        imageView.frame = imageClipView.bounds
        imageView.autoresizingMask = [.width, .height]
        imageClipView.addSubview(imageView)

        selectionView.wantsLayer = true
        updateSelectionColor()
        selectionView.isHidden = true
        addSubview(selectionView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSelectionColor()
    }

    func display(
        _ image: DecodedAnimatedImage,
        mediaFrame: CGRect,
        selectionFrame: CGRect?,
        cornerRadius: CGFloat,
        isLooping: Bool,
        opacity: CGFloat,
        fillsFrame: Bool
    ) {
        updateSelectionColor()
        imageClipView.frame = mediaFrame
        imageClipView.alphaValue = opacity
        imageClipView.layer?.cornerRadius = cornerRadius
        imageClipView.layer?.cornerCurve = .continuous
        imageView.display(
            image,
            animates: true,
            isLooping: isLooping,
            contentMode: fillsFrame ? .fill : .fit
        )
        if let selectionFrame {
            selectionView.frame = selectionFrame
            selectionView.isHidden = false
        } else {
            selectionView.isHidden = true
        }
    }

    func updateSelectionColor() {
        let isEmphasized = window?.isKeyWindow == true
            && (window?.firstResponder as? NSView).map { isDescendant(of: $0) } == true
        let color: NSColor = isEmphasized ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionView.layer?.backgroundColor = color.withAlphaComponent(0.5).cgColor
        }
    }

    func setPlaybackSuppressed(_ isSuppressed: Bool) {
        isScrollSuppressed = isSuppressed
        updatePlaybackSuppression()
    }

    func setHoverPlaybackEnabled(_ isEnabled: Bool) {
        isHoverPlaybackEnabled = isEnabled
        updatePlaybackSuppression()
    }

    private func updatePlaybackSuppression() {
        imageView.setPlaybackSuppressed(isScrollSuppressed || !isHoverPlaybackEnabled)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
