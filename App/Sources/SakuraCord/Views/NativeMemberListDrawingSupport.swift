import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
extension NativeMemberListCanvasView {
    struct SectionHeaderLineKey: Hashable {
        let text: String
        let font: NSFont
        let color: NSColor
    }

    struct FittedTextLineKey: Hashable {
        let source: ObjectIdentifier
        let token: ObjectIdentifier
        let width: CGFloat
    }

    struct FittedTextLine {
        // Retain inputs so their identities cannot be reused while cached.
        let source: CTLine
        let token: CTLine
        let result: CTLine
    }

    func cachedSectionHeaderLine(_ text: String, font: NSFont, color: NSColor) -> CTLine {
        // Fresh dynamic providers can render the same color but compare unequal.
        let color = color.usingColorSpace(.sRGB) ?? color
        let key = SectionHeaderLineKey(text: text, font: font, color: color)
        if let cached = sectionHeaderLines[key] { return cached }
        let result = Self.line(text, font: font, color: color)
        if sectionHeaderLines.count >= 128 { sectionHeaderLines.removeAll(keepingCapacity: true) }
        sectionHeaderLines[key] = result
        return result
    }

    func cachedFittedTextLine(_ line: CTLine, token: CTLine, maximumWidth: CGFloat) -> CTLine {
        let key = FittedTextLineKey(
            source: ObjectIdentifier(line), token: ObjectIdentifier(token), width: maximumWidth
        )
        if let cached = fittedTextLines[key] { return cached.result }
        let result = Self.truncatedLine(line, token: token, maximumWidth: maximumWidth)
        if fittedTextLines.count >= 512 { fittedTextLines.removeAll(keepingCapacity: true) }
        fittedTextLines[key] = FittedTextLine(source: line, token: token, result: result)
        return result
    }

    nonisolated static func line(
        _ text: String,
        font: NSFont,
        color: NSColor
    ) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        ))
    }

    static func draw(line: CTLine, at point: CGPoint, context: CGContext) {
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.drawCoreText(in: CGRect(x: point.x, y: point.y, width: 0, height: ascent)) { context in
            CTLineDraw(line, context)
        }
    }

    /// A role gradient name, scrolling and glowing while its row is hovered.
    static func draw(line: CTLine, at point: CGPoint, gradientColors: [NSColor], context: CGContext, isHovered: Bool) {
        var ascent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
        context.drawCoreText(in: CGRect(x: point.x, y: point.y, width: 0, height: ascent)) { context in
            RoleGradientPaint.draw(line, at: .zero, width: width, colors: gradientColors, isHovered: isHovered, context: context)
        }
    }

    static func truncatedLine(
        _ line: CTLine,
        token: CTLine,
        maximumWidth: CGFloat
    ) -> CTLine {
        guard maximumWidth > 0 else { return line }
        return CoreTextLinePlacement.truncating(
            line,
            width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)),
            to: maximumWidth,
            truncation: .end
        ) { token }
    }

    func activityTextFrame(at index: Int) -> CGRect {
        let row = paintedRowRect(at: index)
        let iconOffset: CGFloat
        if let iconType = preparedText[items[index].id]?.activityIconType,
           let iconData = MemberActivityIconCache.shared.icon(for: iconType)
        {
            iconOffset = InterfaceScale.metric(iconData.size.width) + InterfaceScale.metric(4)
        } else {
            iconOffset = 0
        }
        let textX = textOriginX(at: index) + iconOffset
        return CGRect(
            x: textX,
            y: row.minY + InterfaceScale.metric(24),
            width: max(0, row.maxX - textX - 4 - InterfaceScale.metric(presentation.trailingAccessoryWidth)),
            height: NativeMemberListMetrics.activityEmojiSize
        )
    }

    static func fillRounded(
        _ rect: CGRect,
        radius: CGFloat = NativeMemberListMetrics.rowCornerRadius,
        color: NSColor,
        context: CGContext
    ) {
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.fillPath()
    }

    static func draw(image: CGImage, in rect: CGRect, context: CGContext, fills: Bool) {
        let destination = fills
            ? aspectRect(for: CGSize(width: image.width, height: image.height), in: rect, fillsFrame: true)
            : rect
        context.saveGState()
        context.translateBy(x: 0, y: destination.minY * 2 + destination.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: destination)
        context.restoreGState()
    }

    static func draw(image: CGImage, aspectFitIn rect: CGRect, context: CGContext) {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        draw(
            image: image,
            in: aspectRect(for: imageSize, in: rect, fillsFrame: false),
            context: context,
            fills: false
        )
    }
}

nonisolated final class MemberActivityIconCache: @unchecked Sendable {
    static let shared = MemberActivityIconCache()
    private var cachedIcons: [MemberActivityIconType: (image: CGImage, size: CGSize)] = [:]
    private let lock = NSLock()

    func icon(for type: MemberActivityIconType) -> (image: CGImage, size: CGSize)? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cachedIcons[type] {
            return existing
        }
        let symbolName = switch type {
        case .game: "gamecontroller.fill"
        case .music: "music.note"
        }
        let tint = NSColor(srgbRed: 35 / 255.0, green: 165 / 255.0, blue: 90 / 255.0, alpha: 1.0)
        let pointSize: CGFloat = switch type {
        case .game: 10.0
        case .music: 10.5
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(paletteColors: [tint]))
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return nil
        }
        let logicalSize = symbol.size
        let pixelScale: CGFloat = 2.0
        let pixelWidth = ceil(logicalSize.width * pixelScale)
        let pixelHeight = ceil(logicalSize.height * pixelScale)
        guard let bitmapContext = CGContext(
            data: nil,
            width: Int(pixelWidth),
            height: Int(pixelHeight),
            bitsPerComponent: 8,
            bytesPerRow: Int(pixelWidth) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        let nsContext = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        symbol.draw(
            in: NSRect(origin: .zero, size: NSSize(width: pixelWidth, height: pixelHeight)),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        if let cgImage = bitmapContext.makeImage() {
            let entry = (image: cgImage, size: logicalSize)
            cachedIcons[type] = entry
            return entry
        }
        return nil
    }
}
