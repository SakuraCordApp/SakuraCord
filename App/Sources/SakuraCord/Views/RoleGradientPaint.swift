import AppKit
import CoreText
import QuartzCore

/// Discord paints a role gradient as a 100-point tile that returns to its
/// first colour, scrolls it once every 1.5 seconds while the name is hovered,
/// and adds a soft glow behind the hovered name.
nonisolated enum RoleGradientPaint {
    static let scrollPeriod: CFTimeInterval = 1.5
    /// A hovered row repaints whole; a 100-point scroll over 1.5 seconds
    /// stays smooth at 30 frames per second.
    static let scrollFrameRate = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
    static var tileWidth: CGFloat { InterfaceScale.metric(100) }

    static func colors(primary: NSColor?, secondary: NSColor?, tertiary: NSColor?) -> [NSColor]? {
        guard let primary, let secondary else { return nil }
        return [primary, secondary] + (tertiary.map { [$0] } ?? [])
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    /// Fills the current clip across `rect`'s horizontal extent.
    static func fill(
        _ colors: [NSColor], in rect: CGRect, tileWidth: CGFloat = RoleGradientPaint.tileWidth,
        isScrolling: Bool = false, context: CGContext
    ) {
        let stops = colors + [colors[0]]
        guard tileWidth > 0, let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: stops.map(\.cgColor) as CFArray,
            locations: stops.indices.map { CGFloat($0) / CGFloat(stops.count - 1) }
        ) else { return }
        let phase = isScrolling
            ? CGFloat(CACurrentMediaTime().truncatingRemainder(dividingBy: scrollPeriod) / scrollPeriod) * tileWidth
            : 0
        var tileX = rect.minX + phase - tileWidth
        while tileX < rect.maxX {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: tileX, y: 0), end: CGPoint(x: tileX + tileWidth, y: 0), options: []
            )
            tileX += tileWidth
        }
    }

    /// A role dot: one colour, or the gradient across the dot.
    static func fillDot(_ colors: [NSColor], in rect: CGRect, context: CGContext) {
        context.saveGState()
        if colors.count == 1 {
            context.setFillColor(colors[0].cgColor)
            context.fillEllipse(in: rect)
        } else {
            context.addEllipse(in: rect)
            context.clip()
            fill(colors, in: rect, tileWidth: rect.width, context: context)
        }
        context.restoreGState()
    }

    /// Draws `line` with its baseline at `origin` in a flipped-for-text
    /// context. Colour glyphs such as emoji keep their own colours.
    @MainActor static func draw(
        _ line: CTLine, at origin: CGPoint, width: CGFloat, colors: [NSColor],
        isHovered: Bool, context: CGContext
    ) {
        // Discord dims gradient names to 85% on light backgrounds.
        let isLight = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .aqua
        let colors = isLight ? colors.map { $0.shadow(withLevel: 0.15) ?? $0 } : colors
        let bounds = CGRect(x: origin.x, y: origin.y, width: width, height: 0)
        if isHovered {
            context.saveGState()
            context.setShadow(offset: .zero, blur: 4, color: colors[0].withAlphaComponent(0.7).cgColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            clipped(to: line, at: origin, context: context) {
                fill(colors, in: bounds, isScrolling: AppMotionPolicy.animatesUncategorized, context: context)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        } else {
            clipped(to: line, at: origin, context: context) {
                fill(colors, in: bounds, context: context)
            }
        }
        let colorRuns = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).filter { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[kCTFontAttributeName] as? NSFont else { return false }
            return CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        }
        guard !colorRuns.isEmpty else { return }
        context.textPosition = origin
        for run in colorRuns { CTRunDraw(run, context, CFRange()) }
    }

    /// Text clip mode intersects each run with the clip so far, so a line of
    /// several runs (a truncated name, a fallback font) is filled run by run.
    private static func clipped(to line: CTLine, at origin: CGPoint, context: CGContext, fill: () -> Void) {
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            context.saveGState()
            context.setTextDrawingMode(.clip)
            context.textPosition = origin
            CTRunDraw(run, context, CFRange())
            fill()
            context.restoreGState()
        }
    }
}
