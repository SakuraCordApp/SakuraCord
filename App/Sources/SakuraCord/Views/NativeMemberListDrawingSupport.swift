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
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y + ascent)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// A role gradient name, scrolling and glowing while its row is hovered.
    @MainActor
    static func draw(line: CTLine, at point: CGPoint, gradientColors: [NSColor], context: CGContext, isHovered: Bool) {
        var ascent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y + ascent)
        context.scaleBy(x: 1, y: -1)
        RoleGradientPaint.draw(line, at: .zero, width: width, colors: gradientColors, isHovered: isHovered, context: context)
        context.restoreGState()
    }

    static func truncatedLine(
        _ line: CTLine,
        token: CTLine,
        maximumWidth: CGFloat
    ) -> CTLine {
        guard maximumWidth > 0,
              CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maximumWidth,
              let truncated = CTLineCreateTruncatedLine(
                  line,
                  Double(maximumWidth),
                  .end,
                  token
              )
        else { return line }
        return truncated
    }

    nonisolated static let memberActivityColor = NSColor(
        srgbRed: 122 / 255,
        green: 123 / 255,
        blue: 131 / 255,
        alpha: 1
    )

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
        let imageRatio = CGFloat(image.width) / CGFloat(image.height)
        let rectRatio = rect.width / rect.height
        let destination: CGRect
        if fills {
            if imageRatio > rectRatio {
                let width = rect.height * imageRatio
                destination = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
            } else {
                let height = rect.width / imageRatio
                destination = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
            }
        } else {
            destination = rect
        }
        context.saveGState()
        context.translateBy(x: 0, y: destination.minY * 2 + destination.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: destination)
        context.restoreGState()
    }

    static func draw(image: CGImage, aspectFitIn rect: CGRect, context: CGContext) {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        draw(
            image: image,
            in: CGRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            context: context,
            fills: false
        )
    }

    nonisolated static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
