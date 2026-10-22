import AppKit
import QuartzCore

/// One visible board item. Its chrome (fill, border, lift) is plain layer
/// state, so hover, press and selection animate on the compositor; only the
/// content bitmap is drawn, off the main thread, and only when its
/// presentation changes.
final class ForumBoardCard {
    enum Kind: Equatable {
        case card
        case placeholder
        case sectionHeader
        case paginationStatus
    }

    let layer = CALayer()
    let chrome = CALayer()
    let content = CALayer()
    private var shimmer: SkeletonShimmer?
    private let shimmerMask = CAShapeLayer()
    private(set) var kind: Kind = .card
    /// Records the content for a size and scale, in flipped, top-left-origin
    /// coordinates.
    var sceneBuilder: ((CGSize, CGFloat) -> ForumCardScene)?
    /// Runs after each new bitmap is on screen.
    var didCommit: (() -> Void)?
    private(set) var hasContent = false
    private var renderGeneration = 0
    private var pendingScene: ForumCardScene?
    private var isRasterizing = false
    private var rasterizingGeneration = 0
    private var rasterTask: Task<Void, Never>?
    private var fadesNextCommit: Bool?

    init() {
        layer.masksToBounds = false
        chrome.cornerCurve = .continuous
        chrome.borderWidth = 1
        chrome.shadowColor = NSColor.black.cgColor
        chrome.shadowRadius = 10
        chrome.shadowOffset = CGSize(width: 0, height: -3)
        layer.addSublayer(chrome)
        content.contentsGravity = .topLeft
        // While a card resizes, its previous bitmap stays pinned to the top
        // left, clipped to the card, until the redrawn one lands.
        content.masksToBounds = true
        // Content changes cross-fade only when the board asks for it.
        content.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(content)
    }

    var frame: CGRect {
        get { layer.frame }
        set {
            let sizeChanged = layer.bounds.size != newValue.size
            layer.frame = newValue
            guard sizeChanged else { return }
            let bounds = CGRect(origin: .zero, size: newValue.size)
            chrome.frame = bounds
            content.frame = bounds
            shimmer?.layer.frame = bounds
            shimmerMask.frame = bounds
        }
    }

    func configure(kind: Kind, cornerRadius: CGFloat) {
        self.kind = kind
        chrome.cornerRadius = cornerRadius
        chrome.isHidden = kind == .sectionHeader || kind == .paginationStatus
    }

    /// Rasterizes the content bitmap at `scale`. The scene is recorded now,
    /// on the main thread; a worker rasterizes it and the bitmap commits on
    /// the main thread, replacing the previous one only once complete, so a
    /// card never shows a partly drawn bitmap. `synchronously` rasterizes
    /// here instead, for changes the chrome shows at once (size, appearance).
    func render(scale: CGFloat, fading: Bool, synchronously: Bool = false) {
        let size = layer.bounds.size
        guard let sceneBuilder, size.width >= 1, size.height >= 1 else {
            discardContent()
            return
        }
        let scene = sceneBuilder(size, scale)
        renderGeneration &+= 1
        // Any instant request since the last commit keeps the commit instant,
        // so content never fades over the skeleton it replaces.
        fadesNextCommit = (fadesNextCommit ?? true) && fading
        if synchronously {
            pendingScene = nil
            commit(ForumCardRasterizer.image(for: scene), scale: scale)
            return
        }
        pendingScene = scene
        rasterizePendingScene()
    }

    /// Whether a bitmap for the current content is on its way, so a card
    /// need not ask again. A rasterization started before the card was
    /// cleared or reused does not count: its bitmap never commits.
    var isRendering: Bool {
        pendingScene != nil || isRasterizing && rasterizingGeneration == renderGeneration
    }

    /// One scene rasterizes at a time per card; requests made meanwhile
    /// collapse into the latest, and a superseded bitmap never commits.
    private func rasterizePendingScene() {
        guard !isRasterizing, let scene = pendingScene else { return }
        pendingScene = nil
        isRasterizing = true
        let generation = renderGeneration
        rasterizingGeneration = generation
        rasterTask = Task { [weak self] in
            let image = await ForumCardRasterizer.rasterize(scene)
            guard let self else { return }
            isRasterizing = false
            if generation == renderGeneration { commit(image, scale: scene.scale) }
            rasterizePendingScene()
        }
    }

    private func commit(_ image: CGImage?, scale: CGFloat) {
        guard let image else { return }
        let fades = fadesNextCommit == true && hasContent
        fadesNextCommit = nil
        // Bitmaps land outside the board's transactions; nothing about the
        // swap may animate implicitly (a fresh layer's scale would zoom).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if fades {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.add(transition, forKey: Self.contentsFadeKey)
        } else {
            // An instant swap also ends a fade still showing older content.
            content.removeAnimation(forKey: Self.contentsFadeKey)
        }
        content.contentsScale = scale
        content.contents = image
        hasContent = true
        didCommit?()
    }

    private static let contentsFadeKey = "contents-fade"

    private func discardContent() {
        // A bitmap still queued for the old content need not be drawn.
        rasterTask?.cancel()
        renderGeneration &+= 1
        pendingScene = nil
        fadesNextCommit = nil
        content.removeAnimation(forKey: Self.contentsFadeKey)
        content.contents = nil
        hasContent = false
    }

    func clearContent() {
        discardContent()
        sceneBuilder = nil
        didCommit = nil
    }

    /// Applies the card's resting, hover, pressed and selected looks. Colors
    /// resolve against the board's appearance.
    func applyChrome(
        isHovered: Bool,
        isKeyboardFocused: Bool,
        isPressed: Bool,
        isSelected: Bool,
        appearance: NSAppearance,
        animated: Bool
    ) {
        var fill = NSColor.clear.cgColor
        var border = NSColor.separatorColor.cgColor
        var shadowOpacity: Float = 0
        appearance.performAsCurrentDrawingAppearance {
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch kind {
            case .card:
                let fillAlpha: CGFloat = isPressed ? 0.09 : isSelected ? 0.055 : isHovered ? 0.04 : 0
                fill = NSColor.labelColor.withAlphaComponent(fillAlpha).cgColor
                border = (
                    isSelected
                        ? NSColor.labelColor.withAlphaComponent(0.24)
                        : isHovered
                            ? NSColor.labelColor.withAlphaComponent(isDark ? 0.2 : 0.16)
                            : NSColor.separatorColor
                ).cgColor
                shadowOpacity = isHovered && !isPressed ? (isDark ? 0.32 : 0.12) : 0
            case .placeholder:
                fill = NSColor.labelColor.withAlphaComponent(0.015).cgColor
                border = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
            case .sectionHeader, .paginationStatus:
                break
            }
        }
        if isKeyboardFocused, kind == .card {
            appearance.performAsCurrentDrawingAppearance {
                border = NSColor.keyboardFocusIndicatorColor.cgColor
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(isPressed ? 0.08 : 0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        chrome.backgroundColor = fill
        chrome.borderColor = border
        chrome.borderWidth = isKeyboardFocused && kind == .card ? 2 : 1
        chrome.shadowOpacity = shadowOpacity
        let scale: CGFloat = isPressed && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.985 : 1
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    /// Masks a shimmer to `frames` (card coordinates); empty frames stop it.
    func updateShimmer(frames: [CGRect], color: NSColor, animates: Bool) {
        guard !frames.isEmpty, animates else {
            shimmer?.layer.removeFromSuperlayer()
            shimmer = nil
            return
        }
        let shimmer = self.shimmer ?? {
            let value = SkeletonShimmer()
            value.layer.mask = shimmerMask
            layer.addSublayer(value.layer)
            self.shimmer = value
            return value
        }()
        let path = CGMutablePath()
        for frame in frames {
            let radius = min(InterfaceScale.metric(7), frame.height / 2)
            path.addRoundedRect(in: frame, cornerWidth: radius, cornerHeight: radius)
        }
        let bounds = CGRect(origin: .zero, size: layer.bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmerMask.frame = bounds
        shimmerMask.path = path
        CATransaction.commit()
        shimmer.update(frame: bounds, color: color, animates: true)
    }
}
