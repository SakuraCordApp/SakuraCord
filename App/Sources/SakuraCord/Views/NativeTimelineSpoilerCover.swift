import AppKit
import CoreImage
import SwiftUI

/// Draws a hidden spoiler the way Discord does for every kind of item: the
/// item itself blurred past recognition over the spoiler fill, with a
/// "SPOILER" pill in the middle.
enum NativeTimelineSpoilerCover {
    /// The item is drawn at this fraction of its size before blurring, which
    /// keeps the blur cheap; at Discord's radius the detail lost is invisible.
    private static let blurScale: CGFloat = 1 / 8
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// Blurs by the reduced drawing, so a cover spanning several tiles, or
    /// drawn again unchanged, blurs once.
    private static let blurs: NSCache<NSNumber, CGImage> = {
        let cache = NSCache<NSNumber, CGImage>()
        cache.countLimit = 64
        return cache
    }()
    private static let backdropColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    }

    /// Draws `content`, under the cover when `isCovered`, in the current
    /// flipped context.
    static func draw(
        covering isCovered: Bool,
        in frame: CGRect,
        cornerRadius: CGFloat,
        content: () -> Void
    ) {
        guard isCovered else { return content() }
        // Rows draw in tiles; a cover outside this one costs nothing.
        guard frame.width >= 1, frame.height >= 1,
              NSGraphicsContext.current?.cgContext.boundingBoxOfClipPath.intersects(frame) != false
        else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(concentricRoundedRect: frame, cornerRadius: cornerRadius).addClip()
        NativeTimelineSpoilerAppearance.hiddenColor.setFill()
        frame.fill()
        // Unclamped, so the edges blur into the fill as Discord's do.
        if let blurred = blurredImage(of: frame, content: content) {
            NSImage(cgImage: blurred, size: frame.size).draw(
                in: frame,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        drawPill(in: frame)
    }

    /// The cover as an image, for surfaces that composite images rather than
    /// draw, such as forum cards.
    static func image(size: CGSize, cornerRadius: CGFloat, content: () -> Void) -> NSImage? {
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics.cgContext, flipped: true)
        graphics.cgContext.scaleBy(x: scale, y: scale)
        graphics.cgContext.translateBy(x: 0, y: size.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        draw(covering: true, in: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius, content: content)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    /// The pill on a cover, sized to it; nil when the cover is too small to
    /// carry one.
    static func pill(in frame: CGRect) -> (frame: CGRect, label: NSAttributedString)? {
        guard let scale = NativeTimelineSpoilerAppearance.pillScale(forTileWidth: frame.width) else { return nil }
        let label = NativeTimelineSpoilerAppearance.pillLabel(isHovered: false, scale: scale)
        let pill = NativeTimelineSpoilerAppearance.pillFrame(
            in: frame, measuredLabelWidth: label.size().width, scale: scale
        )
        return (pill, label)
    }

    private static func drawPill(in frame: CGRect) {
        guard let pill = Self.pill(in: frame) else { return }
        NativeTimelineSpoilerAppearance.pillColor.setFill()
        NSBezierPath(roundedRect: pill.frame, xRadius: pill.frame.height / 2, yRadius: pill.frame.height / 2).fill()
        pill.label.draw(
            in: NativeTimelineSpoilerAppearance.labelFrame(in: pill.frame, measuredLabelHeight: pill.label.size().height)
        )
    }

    private static func blurredImage(of frame: CGRect, content: () -> Void) -> CGImage? {
        let width = max(1, Int(ceil(frame.width * blurScale)))
        let height = max(1, Int(ceil(frame.height * blurScale)))
        guard let bitmap = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: blurScale, y: -blurScale)
        bitmap.translateBy(x: -frame.minX, y: -frame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
        // Over the timeline's own background, as Discord blurs an item, so a
        // translucent card blurs as dark or as light as it reads in place.
        backdropColor.setFill()
        frame.fill()
        content()
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = bitmap.data, let small = bitmap.makeImage() else { return nil }
        var hasher = Hasher()
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(bytes: UnsafeRawBufferPointer(start: pixels, count: bitmap.bytesPerRow * height))
        let key = NSNumber(value: hasher.finalize())
        if let cached = blurs.object(forKey: key) { return cached }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let blurred = CIImage(cgImage: small)
            .applyingGaussianBlur(sigma: NativeTimelineSpoilerAppearance.blurRadius * blurScale)
            .cropped(to: extent)
        guard let image = context.createCGImage(blurred, from: extent) else { return nil }
        blurs.setObject(image, forKey: key)
        return image
    }
}

extension NativeTimelineCanvasView {
    /// Fades a spoiler's cover off what its reveal uncovers, as Discord does.
    /// Call it before revealing, while the cover is still drawn. A media
    /// cover's pill leaves at once, as Discord's does, so only the blur fades.
    func fadeOutSpoilerCover(
        _ frames: [CGRect],
        cornerRadius: CGFloat,
        duration: CFTimeInterval,
        dropsPill: Bool = false
    ) {
        guard let bounds = frames.reduce(nil, { ($0 as CGRect?)?.union($1) ?? $1 })?.integral,
              !bounds.isEmpty,
              let snapshot = bitmapImageRepForCachingDisplay(in: bounds)
        else { return }
        cacheDisplay(in: bounds, to: snapshot)
        if dropsPill, let pill = frames.first.flatMap(NativeTimelineSpoilerCover.pill(in:)) {
            Self.fillFromEdges(
                pill.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
                in: snapshot,
                pointSize: bounds.size
            )
        }
        let fade = NSView(frame: bounds)
        fade.wantsLayer = true
        fade.layer?.contents = snapshot.cgImage
        // The fade view is unflipped, so its shapes count up from the bottom.
        let shape = CGMutablePath()
        for frame in frames {
            let local = CGRect(
                x: frame.minX - bounds.minX,
                y: bounds.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
            let radius = min(cornerRadius, local.width / 2, local.height / 2)
            shape.addRoundedRect(in: local, cornerWidth: radius, cornerHeight: radius)
        }
        let mask = CAShapeLayer()
        mask.path = shape
        fade.layer?.mask = mask
        addSubview(fade, positioned: .below, relativeTo: mediaViewerHost)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.animator().alphaValue = 0
        } completionHandler: {
            fade.removeFromSuperview()
        }
    }

    /// Paints over `rect` with what lies just above and below it. The blur
    /// under a pill is smooth enough that this is the cover without it.
    private static func fillFromEdges(_ rect: CGRect, in bitmap: NSBitmapImageRep, pointSize: CGSize) {
        let scaleX = CGFloat(bitmap.pixelsWide) / pointSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / pointSize.height
        let minX = max(0, Int((rect.minX * scaleX).rounded(.down)))
        let maxX = min(bitmap.pixelsWide - 1, Int((rect.maxX * scaleX).rounded(.up)))
        let top = max(0, Int((rect.minY * scaleY).rounded(.down)) - 1)
        let bottom = min(bitmap.pixelsHigh - 1, Int((rect.maxY * scaleY).rounded(.up)) + 1)
        guard minX <= maxX, top < bottom else { return }
        for column in minX ... maxX {
            guard let above = bitmap.colorAt(x: column, y: top),
                  let below = bitmap.colorAt(x: column, y: bottom)
            else { continue }
            for row in top + 1 ..< bottom {
                let fraction = CGFloat(row - top) / CGFloat(bottom - top)
                bitmap.setColor(above.blended(withFraction: fraction, of: below) ?? above, atX: column, y: row)
            }
        }
    }
}

extension View {
    /// The timeline's spoiler cover for SwiftUI surfaces such as staged
    /// attachments: the view blurred over the spoiler fill, with the pill.
    func spoilerCover(_ isHidden: Bool, pillScale: CGFloat? = 1) -> some View {
        blur(radius: isHidden ? NativeTimelineSpoilerAppearance.blurRadius : 0)
            .background {
                if isHidden { Color(nsColor: NativeTimelineSpoilerAppearance.hiddenColor) }
            }
            .overlay {
                if isHidden, let pillScale {
                    Text(AttributedString(NativeTimelineSpoilerAppearance.pillLabel(isHovered: false)))
                        .padding(.horizontal, NativeTimelineSpoilerAppearance.pillHorizontalPadding)
                        .frame(height: NativeTimelineSpoilerAppearance.pillHeight)
                        .background(Capsule().fill(Color(nsColor: NativeTimelineSpoilerAppearance.pillColor)))
                        .scaleEffect(pillScale)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: NativeTimelineSpoilerAppearance.mediaRevealDuration), value: isHidden)
    }
}
