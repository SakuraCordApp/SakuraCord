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

    static func glyphPathAndColorRuns(line: CTLine) -> (path: CGPath, colorRuns: [CTRun]) {
        let runs = (CTLineGetGlyphRuns(line) as [AnyObject]) as? [CTRun] ?? []
        let path = CGMutablePath()
        var colorRuns: [CTRun] = []
        for run in runs {
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            guard let nsFont = runAttributes[kCTFontAttributeName] as? NSFont else { continue }
            if CTFontGetSymbolicTraits(nsFont).contains(.traitColorGlyphs) {
                colorRuns.append(run)
                continue
            }
            let runFont = nsFont as CTFont
            let glyphCount = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)
            for glyphIndex in 0 ..< glyphCount {
                if let subPath = CTFontCreatePathForGlyph(runFont, glyphs[glyphIndex], nil) {
                    let transform = CGAffineTransform(translationX: positions[glyphIndex].x, y: positions[glyphIndex].y)
                    path.addPath(subPath, transform: transform)
                }
            }
        }
        return (path, colorRuns)
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
                blur: InterfaceScale.metric(3.5),
                color: color.withAlphaComponent(0.45).cgColor
            )
            context.setFillColor(color.cgColor)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        if let color {
            context.setFillColor(color.cgColor)
        }
        CTLineDraw(line, context)
        if isHovered, let color {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let phase = CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4)
                let highlightX = width * (phase * 1.6 - 0.3)
                let bandWidth = max(InterfaceScale.metric(28), width * 0.4)
                let shimmerColors = [
                    NSColor.white.withAlphaComponent(0).cgColor,
                    NSColor.white.withAlphaComponent(0.55).cgColor,
                    NSColor.white.withAlphaComponent(0).cgColor,
                ] as CFArray
                let shimmerLocs: [CGFloat] = [0.0, 0.5, 1.0]
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                if let shimmerGradient = CGGradient(colorsSpace: colorSpace, colors: shimmerColors, locations: shimmerLocs) {
                    context.saveGState()
                    let (path, _) = glyphPathAndColorRuns(line: line)
                    context.addPath(path)
                    context.clip()
                    context.setBlendMode(.plusLighter)
                    context.drawLinearGradient(
                        shimmerGradient,
                        start: CGPoint(x: highlightX - bandWidth / 2, y: 0),
                        end: CGPoint(x: highlightX + bandWidth / 2, y: 0),
                        options: []
                    )
                    context.restoreGState()
                }
            }

            context.saveGState()
            context.setStrokeColor(color.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 0, y: -InterfaceScale.metric(1.5)))
            context.addLine(to: CGPoint(x: width, y: -InterfaceScale.metric(1.5)))
            context.strokePath()
            context.restoreGState()
        }
        context.restoreGState()
    }

    static func draw(line: CTLine, at point: CGPoint, gradientColors: [NSColor], width: CGFloat, context: CGContext, isHovered: Bool = false) {
        guard !gradientColors.isEmpty else { return }
        if gradientColors.count == 1 {
            draw(line: line, at: point, context: context, color: gradientColors[0], isHovered: isHovered)
            return
        }
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
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: locations) else {
            context.restoreGState()
            return
        }

        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let effectiveWidth = min(width, lineWidth)
        let (path, colorRuns) = glyphPathAndColorRuns(line: line)

        if isHovered, let primary = gradientColors.first {
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: InterfaceScale.metric(3.5),
                color: primary.withAlphaComponent(0.45).cgColor
            )
            context.setFillColor(primary.withAlphaComponent(0.45).cgColor)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: max(1, effectiveWidth), y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        if isHovered, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let phase = CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4)
            let highlightX = effectiveWidth * (phase * 1.6 - 0.3)
            let bandWidth = max(InterfaceScale.metric(28), effectiveWidth * 0.4)
            let shimmerColors = [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(0.6).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ] as CFArray
            let shimmerLocs: [CGFloat] = [0.0, 0.5, 1.0]
            if let shimmerGradient = CGGradient(colorsSpace: colorSpace, colors: shimmerColors, locations: shimmerLocs) {
                context.setBlendMode(.plusLighter)
                context.drawLinearGradient(
                    shimmerGradient,
                    start: CGPoint(x: highlightX - bandWidth / 2, y: 0),
                    end: CGPoint(x: highlightX + bandWidth / 2, y: 0),
                    options: []
                )
            }
        }
        context.restoreGState()

        if !colorRuns.isEmpty {
            context.saveGState()
            context.textPosition = .zero
            for run in colorRuns {
                CTRunDraw(run, context, CFRange())
            }
            context.restoreGState()
        }

        if isHovered {
            context.saveGState()
            let underlineRect = CGRect(x: 0, y: -InterfaceScale.metric(1.5), width: max(1, effectiveWidth), height: 1)
            context.clip(to: underlineRect)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: max(1, effectiveWidth), y: 0),
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
