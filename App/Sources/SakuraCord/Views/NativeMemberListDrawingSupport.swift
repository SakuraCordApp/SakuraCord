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

    static func draw(line: CTLine, at point: CGPoint, context: CGContext, color: NSColor? = nil, isHovered: Bool = false) {
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y + ascent)
        context.scaleBy(x: 1, y: -1)
        if isHovered, let color {
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: InterfaceScale.metric(6),
                color: color.withAlphaComponent(0.6).cgColor
            )
            context.setFillColor(color.cgColor)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        CTLineDraw(line, context)
        if isHovered, let color {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: InterfaceScale.metric(4),
                color: color.withAlphaComponent(0.6).cgColor
            )
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 0, y: -InterfaceScale.metric(1.5)))
            context.addLine(to: CGPoint(x: width, y: -InterfaceScale.metric(1.5)))
            context.strokePath()
            context.restoreGState()
        }
        context.restoreGState()
    }

    static func draw(line: CTLine, at point: CGPoint, gradientColors: [NSColor], width: CGFloat, context: CGContext, isHovered: Bool = false) {
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y + ascent)
        context.scaleBy(x: 1, y: -1)
        let cgColors = gradientColors.map(\.cgColor) as CFArray
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let count = gradientColors.count
        let locations: [CGFloat] = count == 3 ? [0.0, 0.5, 1.0] : [0.0, 1.0]
        let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: locations)

        if isHovered, let primary = gradientColors.first {
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: InterfaceScale.metric(6),
                color: primary.withAlphaComponent(0.65).cgColor
            )
            context.setFillColor(primary.withAlphaComponent(0.4).cgColor)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        context.saveGState()
        context.setTextDrawingMode(.clip)
        CTLineDraw(line, context)
        if let gradient {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: max(1, width), y: 0),
                options: []
            )
        }
        context.restoreGState()

        if isHovered, let gradient {
            context.saveGState()
            if let primary = gradientColors.first {
                context.setShadow(
                    offset: .zero,
                    blur: InterfaceScale.metric(4),
                    color: primary.withAlphaComponent(0.65).cgColor
                )
            }
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let underlineRect = CGRect(x: 0, y: -InterfaceScale.metric(1.5), width: min(width, lineWidth), height: 1)
            context.clip(to: underlineRect)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: max(1, width), y: 0),
                options: []
            )
            context.restoreGState()
        }
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
