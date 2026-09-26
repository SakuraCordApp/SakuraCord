import AppKit
import SwiftUI

/// The grid uses lightweight native controls and cached pixels, like timeline
/// reactions. The shared picker document still owns all row virtualization.
struct NativeEmojiPickerRow: NSViewRepresentable {
    let cells: [EmojiPickerCell]
    let skinTone: NativeEmojiSkinTone
    let selectedCellID: String?
    let isFavorite: (EmojiPickerItem) -> Bool
    let choose: (EmojiPickerCell, Bool) -> Void
    let hover: (EmojiPickerCell) -> Void
    let toggleFavorite: (EmojiPickerItem) -> Void
    let lockReason: (EmojiPickerItem) -> String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playsAnimatedImages
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NativeEmojiPickerRowView { NativeEmojiPickerRowView() }

    func updateNSView(_ view: NativeEmojiPickerRowView, context: Context) {
        view.configure(self, colorScheme: colorScheme, animates: !reduceMotion && playsAnimatedImages, isEnabled: isEnabled)
    }

    static func dismantleNSView(_ view: NativeEmojiPickerRowView, coordinator: Void) {
        view.clear()
    }
}

final class NativeEmojiPickerRowView: NSView, NativePickerReusableRow {
    private var buttons: [NativeEmojiPickerCell] = []
    override var isFlipped: Bool { true }

    func configure(_ row: NativeEmojiPickerRow, colorScheme: ColorScheme, animates: Bool, isEnabled: Bool) {
        while buttons.count > row.cells.count {
            let button = buttons.removeLast()
            button.clear()
            button.removeFromSuperview()
        }
        while buttons.count < row.cells.count {
            let button = NativeEmojiPickerCell()
            buttons.append(button)
            addSubview(button)
        }
        for (button, cell) in zip(buttons, row.cells) {
            button.configure(cell, row: row, colorScheme: colorScheme, animates: animates, isEnabled: isEnabled)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let columnWidth = bounds.width / CGFloat(EmojiPickerGridMetrics.columns)
        let scale = window?.backingScaleFactor ?? 2
        for (index, button) in buttons.enumerated() {
            let originX = (CGFloat(index) * columnWidth + (columnWidth - 43) / 2) * scale
            button.frame = CGRect(x: originX.rounded() / scale, y: 0, width: 43, height: 43)
        }
    }

    func clear() {
        for button in buttons { button.clear(); button.removeFromSuperview() }
        buttons.removeAll()
    }
}

private final class NativeEmojiPickerCell: NSView {
    private var pickerCell: EmojiPickerCell?
    private var choose: ((EmojiPickerCell, Bool) -> Void)?
    private var hover: ((EmojiPickerCell) -> Void)?
    private var menuCoordinator: EmojiPickerContextMenu?
    private var previewImage: NSImage?
    private var selectedBackground: NSImage?
    private var lockImage: NSImage?
    private var mediaTask: Task<Void, Never>?
    private var mediaIdentity: String?
    private var animation: AnimatedImageCanvas?
    private var tracking: NSTrackingArea?
    private let lockOverlay = NSImageView()
    private var isSelected = false
    private var isLocked = false
    private var animates = true
    private var drawsFullCell = false
    private var isTrackingPress = false
    private var isEnabled = true
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
        lockOverlay.setAccessibilityElement(false)
        lockOverlay.imageScaling = .scaleNone
        addSubview(lockOverlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ cell: EmojiPickerCell, row: NativeEmojiPickerRow, colorScheme: ColorScheme, animates: Bool, isEnabled: Bool) {
        if pickerCell?.id != cell.id { isTrackingPress = false }
        self.pickerCell = cell
        choose = row.choose
        hover = row.hover
        isSelected = row.selectedCellID == cell.id
        let reason = row.lockReason(cell.item)
        isLocked = reason != nil
        self.animates = animates
        self.isEnabled = isEnabled
        setAccessibilityEnabled(isEnabled)
        toolTip = reason.map { "\(cell.item.shortcode): \($0)" } ?? cell.item.shortcode
        setAccessibilityHelp(toolTip)
        setAccessibilityLabel(cell.item.shortcode)
        let favorite = row.isFavorite(cell.item)
        if let menuCoordinator {
            menuCoordinator.update(item: cell.item, skinTone: row.skinTone, isFavorite: favorite, toggleFavorite: { row.toggleFavorite(cell.item) })
        } else {
            menuCoordinator = EmojiPickerContextMenu(item: cell.item, skinTone: row.skinTone, isFavorite: favorite, toggleFavorite: { row.toggleFavorite(cell.item) })
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        selectedBackground = NativeEmojiPickerPixels.background(colorScheme: colorScheme, scale: scale)
        lockImage = isLocked ? NativeEmojiPickerPixels.lock(colorScheme: colorScheme, scale: scale) : nil
        lockOverlay.image = lockImage
        lockOverlay.isHidden = !isLocked
        switch cell.item {
        case .native(let emoji):
            let value = emoji.value(for: row.skinTone)
            if mediaIdentity != "native:\(value):\(scale)" {
                resetMedia()
                mediaIdentity = "native:\(value):\(scale)"
                previewImage = NativeEmojiPickerPixels.emoji(emoji, skinTone: row.skinTone, scale: scale)
            }
            drawsFullCell = true
            setAccessibilityLabel(value)
        case .custom(let emoji):
            let identity = "custom:\(emoji.imageURL?.absoluteString ?? emoji.id):\(emoji.isAnimated)"
            if mediaIdentity != identity {
                resetMedia()
                mediaIdentity = identity
                if let url = emoji.imageURL {
                    load(url: url, animated: emoji.isAnimated, identity: identity)
                } else {
                    previewImage = NativeEmojiPickerPixels.fallback(colorScheme: colorScheme, scale: scale)
                }
            }
            drawsFullCell = emoji.imageURL == nil
        }
        animation?.alphaValue = isLocked ? 0.4 : 1
        if let decoded = animation?.displayedImage {
            animation?.display(decoded, animates: animates, isLooping: true)
        }
        needsDisplay = true
    }

    private func load(url: URL, animated: Bool, identity: String) {
        if animated, let cached = AnimatedRemoteImageDisplayCache.shared.image(for: url, maximumPixelDimension: nil) {
            display(cached)
            return
        }
        if animated, let poster = AnimatedImagePosterCache.shared.image(for: url, maximumPixelDimension: nil) {
            previewImage = NSImage(cgImage: poster, size: .zero)
        }
        if !animated, let cached = SharedDecodedImageLoader.shared.cachedImage(for: url, maximumPixelDimension: 128) {
            previewImage = NSImage(cgImage: cached, size: .zero)
            return
        }
        mediaTask = Task { @MainActor [weak self] in
            if animated {
                guard let decoded = try? await SharedAnimatedImageLoader.shared.image(for: url, maximumPixelDimension: nil),
                      !Task.isCancelled, let self, self.mediaIdentity == identity else { return }
                AnimatedRemoteImageDisplayCache.shared.insert(decoded, for: url, maximumPixelDimension: nil)
                self.display(decoded)
            } else {
                guard let decoded = await SharedDecodedImageLoader.shared.image(for: url, maximumPixelDimension: 128, priority: .visible),
                      !Task.isCancelled, let self, self.mediaIdentity == identity else { return }
                self.previewImage = NSImage(cgImage: decoded, size: .zero)
                self.needsDisplay = true
            }
        }
    }

    private func display(_ decoded: DecodedAnimatedImage) {
        previewImage = nil
        let canvas = animation ?? AnimatedImageCanvas()
        canvas.display(decoded, animates: animates, isLooping: true)
        canvas.alphaValue = isLocked ? 0.4 : 1
        canvas.frame = bounds.insetBy(dx: 2.5, dy: 2.5)
        canvas.setAccessibilityElement(false)
        if canvas.superview == nil { addSubview(canvas) }
        addSubview(lockOverlay, positioned: .above, relativeTo: canvas)
        animation = canvas
    }

    override func layout() {
        super.layout()
        animation?.frame = bounds.insetBy(dx: 2.5, dy: 2.5)
        lockOverlay.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        if isSelected { selectedBackground?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        if let image = previewImage {
            let rect: CGRect
            if drawsFullCell { rect = bounds } else {
                let ratio = min(38 / max(1, image.size.width), 38 / max(1, image.size.height))
                let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                rect = CGRect(x: (43 - size.width) / 2, y: (43 - size.height) / 2, width: size.width, height: size.height)
            }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isLocked ? 0.4 : 1, respectFlipped: true, hints: nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self), let cell = pickerCell else { return }
        hover?(cell)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, WindowModalCoordinator.allowsInput(for: self) else { return }
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        isTrackingPress = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { isTrackingPress = false }
        guard isTrackingPress, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    override func isAccessibilityElement() -> Bool { true }

    nonisolated override func accessibilityActionNames() -> [NSAccessibility.Action] { [.press] }

    nonisolated override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            guard choose != nil, isEnabled, WindowModalCoordinator.allowsInput(for: self) else { return false }
            activate()
            return true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        WindowModalCoordinator.allowsInput(for: self) ? menuCoordinator?.makeMenu() : nil
    }

    @objc private func activate() {
        guard isEnabled, WindowModalCoordinator.allowsInput(for: self), let cell = pickerCell else { return }
        choose?(cell, NSEvent.modifierFlags.contains(.shift))
    }

    private func resetMedia() {
        mediaTask?.cancel()
        mediaTask = nil
        previewImage = nil
        animation?.clear()
        animation?.removeFromSuperview()
        animation = nil
    }

    func clear() {
        resetMedia()
        pickerCell = nil
        choose = nil
        hover = nil
        menuCoordinator = nil
    }
}

@MainActor private enum NativeEmojiPickerPixels {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func emoji(_ emoji: NativeEmoji, skinTone: NativeEmojiSkinTone, scale: CGFloat) -> NSImage? {
        let value = emoji.value(for: skinTone)
        let key = "emoji:\(value):\(scale)" as NSString
        if let image = cache.object(forKey: key) { return image }
        // Use the same font, centered text line and one-point upward offset as
        // EmojiPickerItem.preview. Core Text avoids constructing a SwiftUI
        // render graph for every cold glyph during a large scrollbar jump.
        let text = NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 38)])
        let size = text.size()
        let pixels = Int(ceil(43 * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = CGSize(width: 43, height: 43)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: 43, height: 43))
        text.draw(at: CGPoint(x: (43 - size.width) / 2, y: (43 - size.height) / 2 + 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = bitmap.cgImage else { return nil }
        let image = NSImage(cgImage: pixels, size: CGSize(width: 43, height: 43))
        cache.setObject(image, forKey: key, cost: pixels.bytesPerRow * pixels.height)
        return image
    }

    static func fallback(colorScheme: ColorScheme, scale: CGFloat) -> NSImage? {
        render(key: "fallback:\(colorScheme):\(scale)", scale: scale) {
            Image(systemName: "face.dashed").frame(width: 43, height: 43)
                .environment(\.colorScheme, colorScheme)
        }
    }

    static func background(colorScheme: ColorScheme, scale: CGFloat) -> NSImage? {
        render(key: "background:\(colorScheme):\(scale)", scale: scale) {
            ConcentricRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.13))
                .frame(width: 43, height: 43).environment(\.colorScheme, colorScheme)
        }
    }

    static func lock(colorScheme: ColorScheme, scale: CGFloat) -> NSImage? {
        render(key: "lock:\(colorScheme):\(scale)", scale: scale) {
            Color.clear.frame(width: 43, height: 43).overlay(alignment: .bottomTrailing) {
                Image(systemName: "lock.fill").font(.caption2).padding(3)
            }.environment(\.colorScheme, colorScheme)
        }
    }

    private static func render<Content: View>(key: String, scale: CGFloat, @ViewBuilder content: () -> Content) -> NSImage? {
        if let image = cache.object(forKey: key as NSString) { return image }
        let renderer = ImageRenderer(content: content())
        renderer.scale = scale
        guard let pixels = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: pixels, size: CGSize(width: 43, height: 43))
        cache.setObject(image, forKey: key as NSString, cost: pixels.bytesPerRow * pixels.height)
        return image
    }
}
