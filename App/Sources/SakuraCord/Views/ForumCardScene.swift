import AppKit
import CoreGraphics
import CoreText
import Foundation

/// A card's drawing, recorded on the main thread as resolved primitives so a
/// worker can shape its text and rasterize it.
///
/// Immutable once recorded. Its Core Foundation values (paths, colors, fonts
/// and images) are immutable and safe to read from any thread.
nonisolated struct ForumCardScene: @unchecked Sendable {
    struct Text {
        let value: String
        let font: CTFont
        let color: CGColor
        let frame: CGRect
        let alignment: CTTextAlignment
        let lineBreakMode: CTLineBreakMode
    }

    /// A pill that follows the last line of wrapped text, like the NEW badge.
    struct TrailingBadge {
        let size: CGSize
        let spacing: CGFloat
        let fill: CGColor
        let text: String
        let font: CTFont
        let textColor: CGColor
        let textLineHeight: CGFloat
    }

    struct Lines {
        let value: String
        let font: CTFont
        let color: CGColor
        let frame: CGRect
        let lineHeight: CGFloat
        let maximumLines: Int
        let lastLineReserve: CGFloat
        let badge: TrailingBadge?
    }

    enum Operation {
        case fill(CGPath, CGColor)
        case stroke(CGPath, CGColor, lineWidth: CGFloat)
        case text(Text)
        case lines(Lines)
        /// An image scaled into `destination`, clipped to `clip`.
        case image(CGImage, destination: CGRect, clip: CGPath?)
        /// A bitmap already rasterized at the scene's scale, pixel-aligned.
        case bitmap(CGImage, frame: CGRect)
        /// Excerpt text laid out with TextKit on the worker, at `width`,
        /// clipped to `clip`.
        case excerpt(ExcerptText, origin: CGPoint, width: CGFloat, clip: CGRect)
    }

    /// An excerpt's displayed text, made safe to lay out and draw off the
    /// main thread: colors are resolved and inline images are bitmaps.
    struct ExcerptText {
        let text: NSAttributedString
        let maximumLines: Int
    }

    let size: CGSize
    let scale: CGFloat
    /// The display's color space: Core Animation shows a bitmap in it as is,
    /// where any other would be converted on the main thread at commit.
    let colorSpace: CGColorSpace
    let operations: [Operation]

    static func empty(
        size: CGSize,
        scale: CGFloat,
        colorSpace: CGColorSpace = ForumCardRasterizer.defaultColorSpace
    ) -> ForumCardScene {
        ForumCardScene(size: size, scale: scale, colorSpace: colorSpace, operations: [])
    }
}

/// Rasterizes forum card scenes off the main thread.
nonisolated enum ForumCardRasterizer {
    @concurrent
    static func rasterize(_ scene: ForumCardScene) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return image(for: scene)
    }

    /// Draws `scene` into a new bitmap with a flipped, top-left origin.
    static func image(for scene: ForumCardScene) -> CGImage? {
        let pixelWidth = Int((scene.size.width * scene.scale).rounded(.up))
        let pixelHeight = Int((scene.size.height * scene.scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0, let context = makeContext(width: pixelWidth, height: pixelHeight, colorSpace: scene.colorSpace) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scene.scale, y: -scene.scale)
        context.interpolationQuality = .high
        for operation in scene.operations {
            draw(operation, in: context)
        }
        return context.makeImage()
    }

    static let defaultColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    private static func draw(_ operation: ForumCardScene.Operation, in context: CGContext) {
        switch operation {
        case let .fill(path, color):
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath()
        case let .stroke(path, color, lineWidth):
            context.addPath(path)
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.strokePath()
        case let .text(text):
            draw(text, in: context)
        case let .lines(lines):
            draw(lines, in: context)
        case let .image(image, destination, clip):
            context.saveGState()
            if let clip {
                context.addPath(clip)
                context.clip()
            }
            drawUpright(image, in: destination, context: context)
            context.restoreGState()
        case let .bitmap(image, frame):
            context.saveGState()
            context.interpolationQuality = .none
            drawUpright(image, in: frame, context: context)
            context.restoreGState()
        case let .excerpt(excerpt, origin, width, clip):
            draw(excerpt, at: origin, width: width, clippedTo: clip, in: context)
        }
    }

    /// Lays out and draws an excerpt the way its main-thread renderer does,
    /// with a TextKit stack confined to this call.
    private static func draw(
        _ excerpt: ForumCardScene.ExcerptText,
        at origin: CGPoint,
        width: CGFloat,
        clippedTo clip: CGRect,
        in context: CGContext
    ) {
        let storage = NSTextStorage(attributedString: excerpt.text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byTruncatingTail
        container.maximumNumberOfLines = excerpt.maximumLines
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        context.saveGState()
        context.clip(to: clip)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    /// Images draw right side up in the flipped context.
    private static func drawUpright(_ image: CGImage, in frame: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
        context.restoreGState()
    }

    // MARK: Text

    private static func attributed(
        _ value: String,
        font: CTFont,
        color: CGColor,
        alignment: CTTextAlignment = .left,
        lineBreakMode: CTLineBreakMode = .byTruncatingTail
    ) -> CFAttributedString {
        var alignment = alignment
        var lineBreakMode = lineBreakMode
        let paragraph = withUnsafePointer(to: &alignment) { alignmentPointer in
            withUnsafePointer(to: &lineBreakMode) { breakPointer in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentPointer),
                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: breakPointer),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
            kCTParagraphStyleAttributeName: paragraph,
        ]
        return CFAttributedStringCreate(nil, value as CFString, attributes as CFDictionary)
    }

    private static func ellipsis(font: CTFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(attributed("…", font: font, color: color))
    }

    /// One line of text vertically centered in its frame, truncated or
    /// clipped to its width; text with line breaks lays out as a frame.
    /// Matches the timeline's single-line text drawing.
    private static func draw(_ text: ForumCardScene.Text, in context: CGContext) {
        let frame = text.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let value = attributed(text.value, font: text.font, color: text.color, alignment: text.alignment, lineBreakMode: text.lineBreakMode)
        guard !text.value.contains("\n") else {
            let framesetter = CTFramesetterCreateWithAttributedString(value)
            let path = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
            let textFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            CTFrameDraw(textFrame, context)
            context.restoreGState()
            return
        }
        var line = CTLineCreateWithAttributedString(value)
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > frame.width, text.lineBreakMode == .byTruncatingTail {
            line = CTLineCreateTruncatedLine(line, Double(frame.width), .end, ellipsis(font: text.font, color: text.color)) ?? line
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let horizontalPosition: CGFloat = switch text.alignment {
        case .center: max(0, (frame.width - lineWidth) / 2)
        case .right: max(0, frame.width - lineWidth)
        default: 0
        }
        let baseline = max(descent, (frame.height - ascent - descent - leading) / 2 + descent)
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: horizontalPosition, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Breaks text into at most `maximumLines` lines, truncating the last
    /// with an ellipsis, then places the trailing badge after the last line.
    private static func draw(_ lines: ForumCardScene.Lines, in context: CGContext) {
        let frame = lines.frame
        guard frame.width > 0 else { return }
        let value = attributed(lines.value, font: lines.font, color: lines.color)
        let typesetter = CTTypesetterCreateWithAttributedString(value)
        let length = CFAttributedStringGetLength(value)
        let ascender = CTFontGetAscent(lines.font)
        let descender = CTFontGetDescent(lines.font)
        let reserve = lines.lastLineReserve
        var location = 0
        var lineIndex = 0
        var end = frame.origin
        while location < length, lineIndex < lines.maximumLines {
            var isLast = lineIndex == lines.maximumLines - 1
            var width = Double(max(1, frame.width - (isLast ? reserve : 0)))
            var count = CTTypesetterSuggestLineBreak(typesetter, location, width)
            if count <= 0 { break }
            // A line that ends the text carries the trailing badge too.
            if !isLast, reserve > 0, location + count >= length {
                width = Double(max(1, frame.width - reserve))
                count = CTTypesetterSuggestLineBreak(typesetter, location, width)
                if count <= 0 { break }
                isLast = location + count >= length
            }
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: location, length: count))
            if isLast, location + count < length {
                count = length - location
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: location, length: count))
                line = CTLineCreateTruncatedLine(rest, width, .end, ellipsis(font: lines.font, color: lines.color)) ?? line
            }
            let lineY = frame.minY + CGFloat(lineIndex) * lines.lineHeight
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: frame.minX, y: lineY + ascender + (lines.lineHeight - (ascender + descender)) / 2)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            end = CGPoint(x: frame.minX + ceil(lineWidth), y: lineY)
            location += count
            lineIndex += 1
        }
        guard let badge = lines.badge else { return }
        let badgeFrame = CGRect(
            x: end.x + badge.spacing,
            y: end.y + (lines.lineHeight - badge.size.height) / 2,
            width: badge.size.width,
            height: badge.size.height
        )
        let radius = badgeFrame.height / 2
        context.addPath(CGPath(roundedRect: badgeFrame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(badge.fill)
        context.fillPath()
        draw(ForumCardScene.Text(
            value: badge.text,
            font: badge.font,
            color: badge.textColor,
            frame: CGRect(
                x: badgeFrame.minX,
                y: badgeFrame.midY - badge.textLineHeight / 2,
                width: badgeFrame.width,
                height: badge.textLineHeight
            ),
            alignment: .center,
            lineBreakMode: .byClipping
        ), in: context)
    }
}
