import AppKit

/// Records a card's drawing as a `ForumCardScene` on the main thread.
///
/// Colors resolve against the current drawing appearance as they are
/// recorded, and images resolve from the main-thread caches, so the worker
/// that rasterizes the scene reads no AppKit state. Drawing that needs
/// AppKit itself (TextKit excerpts, the shared reaction pill) is pre-rendered
/// here into small cached bitmaps.
final class ForumCardCanvas {
    let size: CGSize
    let scale: CGFloat
    let colorSpace: CGColorSpace
    private let cache: ForumCardRasterCache
    private let appearance = NSAppearance.currentDrawing().name
    private var operations: [ForumCardScene.Operation] = []
    /// While the board follows a width change, excerpts are laid out on the
    /// worker at each width rather than drawn here.
    var laysOutExcerptsOffMain = false

    init(size: CGSize, scale: CGFloat, colorSpace: CGColorSpace, cache: ForumCardRasterCache) {
        self.size = size
        self.scale = scale
        self.colorSpace = colorSpace
        self.cache = cache
    }

    var scene: ForumCardScene {
        ForumCardScene(size: size, scale: scale, colorSpace: colorSpace, operations: operations)
    }

    // MARK: Shapes

    func fill(_ rect: CGRect, cornerRadius: CGFloat = 0, color: NSColor) {
        operations.append(.fill(Self.roundedPath(rect, cornerRadius: cornerRadius), color.cgColor))
    }

    func fillOval(_ rect: CGRect, color: NSColor) {
        operations.append(.fill(CGPath(ellipseIn: rect, transform: nil), color.cgColor))
    }

    func stroke(_ rect: CGRect, cornerRadius: CGFloat = 0, color: NSColor, lineWidth: CGFloat = 1) {
        operations.append(.stroke(Self.roundedPath(rect, cornerRadius: cornerRadius), color.cgColor, lineWidth: lineWidth))
    }

    /// Matches `NSBezierPath(roundedRect:xRadius:yRadius:)`, which clamps the
    /// radius to half the shorter side.
    private static func roundedPath(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let radius = max(0, min(cornerRadius, rect.width / 2, rect.height / 2))
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    // MARK: Text

    func text(
        _ value: String,
        in frame: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        operations.append(.text(ForumCardScene.Text(
            value: value,
            font: font as CTFont,
            color: color.cgColor,
            frame: frame,
            alignment: alignment == .center ? .center : alignment == .right ? .right : .left,
            lineBreakMode: lineBreakMode == .byClipping ? .byClipping : .byTruncatingTail
        )))
    }

    struct Badge {
        let size: CGSize
        let spacing: CGFloat
        let fill: NSColor
        let text: String
        let font: NSFont
        let textColor: NSColor
    }

    /// Wrapped text, truncated on its last line, optionally followed by a
    /// badge where that line ends.
    func lines(
        _ value: String,
        font: NSFont,
        color: NSColor,
        in frame: CGRect,
        lineHeight: CGFloat,
        maximumLines: Int,
        lastLineReserve: CGFloat = 0,
        badge: Badge? = nil
    ) {
        guard frame.width > 0 else { return }
        operations.append(.lines(ForumCardScene.Lines(
            value: value,
            font: font as CTFont,
            color: color.cgColor,
            frame: frame,
            lineHeight: lineHeight,
            maximumLines: maximumLines,
            lastLineReserve: lastLineReserve,
            badge: badge.map {
                ForumCardScene.TrailingBadge(
                    size: $0.size,
                    spacing: $0.spacing,
                    fill: $0.fill.cgColor,
                    text: $0.text,
                    font: $0.font as CTFont,
                    textColor: $0.textColor.cgColor,
                    textLineHeight: ForumBoardMetrics.lineHeight(of: $0.font)
                )
            }
        )))
    }

    // MARK: Images

    /// Matches the timeline's system symbol drawing: rasterized at the
    /// scene's scale and optically centered.
    func symbol(_ name: String, in frame: CGRect, color: NSColor, inset: CGFloat, weight: NSFont.Weight = .regular) {
        guard frame.width > 0, frame.height > 0 else { return }
        let pointSize = max(10, min(frame.width, frame.height) - max(0, inset) * 2)
        guard let image = NativeTimelineSystemSymbolCache.rasterizedConfiguredImage(
            named: name,
            pointSize: pointSize,
            weight: weight,
            color: color,
            scale: scale
        ), let cgImage = cache.cgImage(for: image) else { return }
        let target = frame.insetBy(
            dx: min(max(0, inset), frame.width / 2 - 1),
            dy: min(max(0, inset), frame.height / 2 - 1)
        )
        let fitted = NativeTimelineSymbolGeometry.opticallyFitted(
            sourceSize: image.size,
            alignmentRect: image.alignmentRect,
            in: target
        )
        operations.append(.image(cgImage, destination: fitted, clip: nil))
    }

    /// Matches the timeline's image drawing: aspect fill or fit, clipped to
    /// a concentric rounded rect.
    func image(_ image: NSImage, in frame: CGRect, cornerRadius: CGFloat, fillsFrame: Bool) {
        guard frame.width > 0, frame.height > 0, image.size.width > 0, image.size.height > 0,
              let cgImage = cache.cgImage(for: image)
        else { return }
        let fit = fillsFrame
            ? max(frame.width / image.size.width, frame.height / image.size.height)
            : min(frame.width / image.size.width, frame.height / image.size.height)
        let destination = CGRect(
            x: frame.midX - image.size.width * fit / 2,
            y: frame.midY - image.size.height * fit / 2,
            width: image.size.width * fit,
            height: image.size.height * fit
        )
        let clip = NSBezierPath(concentricRoundedRect: frame, cornerRadius: cornerRadius).cgPath
        operations.append(.image(cgImage, destination: destination, clip: clip))
    }

    func excerpt(_ excerpt: ForumCardScene.ExcerptText, at origin: CGPoint, width: CGFloat, clippedTo clip: CGRect) {
        guard clip.width > 0, clip.height > 0 else { return }
        operations.append(.excerpt(excerpt, origin: origin, width: width, clip: clip))
    }

    /// Draws AppKit content into a cached bitmap covering `clip`, aligned to
    /// device pixels. `key` must identify everything the drawing depends on
    /// besides its size, pixel phase, scale and appearance, including any
    /// position relative to `clip`.
    func prerendered(key: AnyHashable, clip: CGRect, draw: () -> Void) {
        guard clip.width > 0, clip.height > 0 else { return }
        let pixelMinX = floor(clip.minX * scale)
        let pixelMinY = floor(clip.minY * scale)
        let pixelWidth = Int(ceil(clip.maxX * scale) - pixelMinX)
        let pixelHeight = Int(ceil(clip.maxY * scale) - pixelMinY)
        let frame = CGRect(
            x: pixelMinX / scale,
            y: pixelMinY / scale,
            width: CGFloat(pixelWidth) / scale,
            height: CGFloat(pixelHeight) / scale
        )
        let cacheKey = ForumCardRasterCache.PrerenderKey(
            content: key,
            phaseX: clip.minX * scale - floor(clip.minX * scale),
            phaseY: clip.minY * scale - floor(clip.minY * scale),
            width: clip.width,
            height: clip.height,
            scale: scale,
            appearance: appearance
        )
        if let image = cache.prerendered[cacheKey] {
            operations.append(.bitmap(image, frame: frame))
            return
        }
        guard let context = ForumCardRasterizer.makeContext(width: pixelWidth, height: pixelHeight, colorSpace: colorSpace) else { return }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        context.clip(to: clip)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return }
        cache.storePrerendered(image, for: cacheKey)
        operations.append(.bitmap(image, frame: frame))
    }
}

/// Main-thread caches behind `ForumCardCanvas`: CGImages for AppKit images
/// and pre-rendered excerpt and reaction bitmaps.
final class ForumCardRasterCache {
    /// A drawing's identity apart from where it sits: the same content at
    /// the same pixel phase reuses one bitmap wherever the clip moves.
    struct PrerenderKey: Hashable {
        let content: AnyHashable
        let phaseX: CGFloat
        let phaseY: CGFloat
        let width: CGFloat
        let height: CGFloat
        let scale: CGFloat
        let appearance: NSAppearance.Name
    }

    private struct ImageEntry {
        let image: NSImage
        let cgImage: CGImage
    }

    private(set) var prerendered: [PrerenderKey: CGImage] = [:]
    /// Insertion order, so the oldest bitmaps go first; excerpts are the
    /// largest entries, so the limit stays near a few screens of cards.
    private var prerenderedOrder: [PrerenderKey] = []
    private let prerenderedLimit = 128
    private var images: [ObjectIdentifier: ImageEntry] = [:]
    private let limit = 384

    func storePrerendered(_ image: CGImage, for key: PrerenderKey) {
        if prerendered.updateValue(image, forKey: key) == nil { prerenderedOrder.append(key) }
        if prerenderedOrder.count > prerenderedLimit {
            let evicted = prerenderedOrder.prefix(prerenderedOrder.count - prerenderedLimit)
            for key in evicted { prerendered[key] = nil }
            prerenderedOrder.removeFirst(evicted.count)
        }
    }

    /// The image's bitmap. Small images (symbols, emoji) convert once per
    /// image; entries keep their image alive, so an identifier is never
    /// reused while cached. Media is left to the media store's own cache.
    func cgImage(for image: NSImage) -> CGImage? {
        let id = ObjectIdentifier(image)
        if let entry = images[id] { return entry.cgImage }
        let converted: CGImage? = if image.representations.count == 1,
                                     let representation = image.representations.first as? NSBitmapImageRep
        {
            representation.cgImage
        } else {
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let converted else { return nil }
        guard converted.width * converted.height <= 256 * 256 else { return converted }
        if images.count >= limit { images.removeAll(keepingCapacity: true) }
        images[id] = ImageEntry(image: image, cgImage: converted)
        return converted
    }
}
