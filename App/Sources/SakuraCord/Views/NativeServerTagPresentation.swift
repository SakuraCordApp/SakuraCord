import AppKit
import CoreText
import SakuraCordModels
import Synchronization

nonisolated enum NativeAppBadgePresentation {
    private static let cachedText = Mutex<(size: CGFloat, text: NativeIdentityTextPresentation)?>(nil)

    /// Prepared once per interface size.
    static var text: NativeIdentityTextPresentation {
        let size = InterfaceScale.fontSize(ServerTagAppearance.fontSize)
        return cachedText.withLock { cached in
            if let cached, cached.size == size { return cached.text }
            let text = NativeIdentityTextPresentation("APP", font: .systemFont(ofSize: size, weight: .bold))
            cached = (size, text)
            return text
        }
    }

    static var width: CGFloat { text.width + ServerTagAppearance.horizontalPadding * 2 }

    @MainActor
    static func draw(in frame: CGRect, color: NSColor, context: CGContext, text: NativeIdentityTextPresentation? = nil) {
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(
            roundedRect: frame, cornerWidth: ServerTagAppearance.cornerRadius,
            cornerHeight: ServerTagAppearance.cornerRadius, transform: nil
        ))
        context.fillPath()
        (text ?? Self.text).draw(
            in: frame.insetBy(dx: ServerTagAppearance.horizontalPadding, dy: 0),
            color: .white, context: context
        )
        context.restoreGState()
    }
}

/// Immutable CoreText content prepared with the row, including its visible
/// glyph bounds. Drawing never measures or truncates identity text.
nonisolated struct NativeIdentityTextPresentation: @unchecked Sendable {
    let line: CTLine
    let width: CGFloat
    private let glyphBounds: CGRect
    /// Whether the whole text fits at its own width, which any wider
    /// maximum reproduces exactly.
    private let isNatural: Bool

    /// Untruncated lines by text and font: a row laid out again at another
    /// width, as on every frame of a resize, reuses its identity's line.
    private static let untruncated = Mutex<[UntruncatedKey: NativeIdentityTextPresentation]>([:])

    /// Fonts are immutable.
    private struct UntruncatedKey: Hashable, @unchecked Sendable {
        let value: String
        let font: NSFont
    }

    init(_ value: String, font: NSFont, maximumWidth: CGFloat = .greatestFiniteMagnitude) {
        let key = UntruncatedKey(value: value, font: font)
        if let cached = Self.untruncated.withLock({ $0[key] }), cached.width <= maximumWidth {
            self = cached
            return
        }
        self.init(uncached: value, font: font, maximumWidth: maximumWidth)
        guard isNatural else { return }
        let presentation = self
        Self.untruncated.withLock { cache in
            if cache.count >= 4_096 { cache.removeAll(keepingCapacity: true) }
            cache[key] = presentation
        }
    }

    private init(uncached value: String, font: NSFont, maximumWidth: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let source = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        let naturalWidth = CGFloat(CTLineGetTypographicBounds(source, nil, nil, nil))
        if naturalWidth > maximumWidth {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(source, max(0, maximumWidth), .end, token) ?? token
        } else {
            line = source
        }
        let lineWidth = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        width = min(max(0, maximumWidth), lineWidth)
        isNatural = naturalWidth <= maximumWidth && lineWidth <= maximumWidth
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if bounds.isNull || bounds.isEmpty {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            glyphBounds = CGRect(x: 0, y: -descent, width: width, height: ascent + descent)
        } else {
            glyphBounds = bounds
        }
    }

    /// Distance from the top of a vertically centered glyph run to its baseline.
    func baselineOffset(inHeight height: CGFloat) -> CGFloat {
        height / 2 + glyphBounds.midY
    }

    private func glyphPathAndColorRuns(baseline: CGFloat) -> (path: CGPath, colorRuns: [CTRun]) {
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
                    let transform = CGAffineTransform(translationX: positions[glyphIndex].x, y: positions[glyphIndex].y + baseline)
                    path.addPath(subPath, transform: transform)
                }
            }
        }
        return (path, colorRuns)
    }

    @MainActor
    func draw(in frame: CGRect, color: NSColor, context: CGContext, isUnderlined: Bool = false) {
        guard frame.width > 0, frame.height > 0 else { return }
        context.saveGState()
        context.clip(to: frame)
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let baseline = frame.height / 2 - glyphBounds.midY
        if isUnderlined {
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: InterfaceScale.metric(3.5),
                color: color.withAlphaComponent(0.45).cgColor
            )
            context.setFillColor(color.cgColor)
            context.textPosition = CGPoint(x: 0, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.setFillColor(color.cgColor)
        context.textPosition = CGPoint(x: 0, y: baseline)
        CTLineDraw(line, context)

        if isUnderlined {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let phase = CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4)
                let textWidth = min(width, frame.width)
                let highlightX = textWidth * (phase * 1.6 - 0.3)
                let bandWidth = max(InterfaceScale.metric(28), textWidth * 0.4)
                let shimmerColors = [
                    NSColor.white.withAlphaComponent(0).cgColor,
                    NSColor.white.withAlphaComponent(0.55).cgColor,
                    NSColor.white.withAlphaComponent(0).cgColor,
                ] as CFArray
                let shimmerLocs: [CGFloat] = [0.0, 0.5, 1.0]
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                if let shimmerGradient = CGGradient(colorsSpace: colorSpace, colors: shimmerColors, locations: shimmerLocs) {
                    context.saveGState()
                    let (path, _) = glyphPathAndColorRuns(baseline: baseline)
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
            context.move(to: CGPoint(x: 0, y: baseline - InterfaceScale.metric(1.5)))
            context.addLine(to: CGPoint(x: min(width, frame.width), y: baseline - InterfaceScale.metric(1.5)))
            context.strokePath()
            context.restoreGState()
        }
        context.restoreGState()
    }

    @MainActor
    func draw(in frame: CGRect, gradientColors: [NSColor], context: CGContext, isUnderlined: Bool = false) {
        guard frame.width > 0, frame.height > 0, !gradientColors.isEmpty else { return }
        if gradientColors.count == 1 {
            draw(in: frame, color: gradientColors[0], context: context, isUnderlined: isUnderlined)
            return
        }
        context.saveGState()
        context.clip(to: frame)
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity

        let baseline = frame.height / 2 - glyphBounds.midY
        let cgColors = gradientColors.map(\.cgColor) as CFArray
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let count = gradientColors.count
        let locations: [CGFloat] = count == 3 ? [0.0, 0.5, 1.0] : [0.0, 1.0]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: locations) else {
            context.restoreGState()
            return
        }

        let (path, colorRuns) = glyphPathAndColorRuns(baseline: baseline)

        if isUnderlined {
            context.saveGState()
            let primary = gradientColors[0]
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
            end: CGPoint(x: min(width, frame.width), y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        if isUnderlined, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let phase = CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4)
            let textWidth = min(width, frame.width)
            let highlightX = textWidth * (phase * 1.6 - 0.3)
            let bandWidth = max(InterfaceScale.metric(28), textWidth * 0.4)
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
            context.textPosition = CGPoint(x: 0, y: baseline)
            for run in colorRuns {
                CTRunDraw(run, context, CFRange())
            }
            context.restoreGState()
        }

        if isUnderlined {
            context.saveGState()
            let underlineRect = CGRect(
                x: 0,
                y: baseline - InterfaceScale.metric(1.5),
                width: min(width, frame.width),
                height: 1
            )
            context.clip(to: underlineRect)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: min(width, frame.width), y: 0),
                options: []
            )
            context.restoreGState()
        }
        context.restoreGState()
    }
}

/// The same server-tag chrome as ProfileServerTag, shared by native canvases.
/// Badge space belongs to the identity even before its cached image arrives.
nonisolated struct NativeServerTagPresentation: @unchecked Sendable {
    static var height: CGFloat { ServerTagAppearance.height }
    let identity: PrimaryGuildIdentity
    let width: CGFloat
    private let text: NativeIdentityTextPresentation
    private let font: NSFont
    private var badgeInset: CGFloat { identity.badgeURL == nil ? 0 : ServerTagAppearance.badgeSize + ServerTagAppearance.spacing }
    private var textInset: CGFloat { ServerTagAppearance.horizontalPadding + badgeInset }

    init?(identity: PrimaryGuildIdentity, font: NSFont = .interfaceSystemFont(ofSize: ServerTagAppearance.fontSize, weight: .medium)) {
        guard let tag = identity.tag, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.identity = identity
        self.font = font
        text = NativeIdentityTextPresentation(tag, font: font)
        width = text.width + ServerTagAppearance.horizontalPadding * 2 + (identity.badgeURL == nil ? 0 : ServerTagAppearance.badgeSize + ServerTagAppearance.spacing)
    }

    private init(identity: PrimaryGuildIdentity, font: NSFont, maximumWidth: CGFloat) {
        self.identity = identity
        self.font = font
        let inset = ServerTagAppearance.horizontalPadding * 2 + (identity.badgeURL == nil ? 0 : ServerTagAppearance.badgeSize + ServerTagAppearance.spacing)
        text = NativeIdentityTextPresentation(identity.tag ?? "", font: font, maximumWidth: maximumWidth - inset)
        width = min(maximumWidth, text.width + inset)
    }

    func fitting(maximumWidth: CGFloat) -> Self? {
        guard maximumWidth >= textInset + ServerTagAppearance.horizontalPadding + 14 else { return nil }
        return maximumWidth >= width ? self : Self(identity: identity, font: font, maximumWidth: maximumWidth)
    }

    var textBaselineOffset: CGFloat {
        text.baselineOffset(inHeight: Self.height)
    }

    func badgeFrame(in frame: CGRect) -> CGRect? {
        guard identity.badgeURL != nil else { return nil }
        return CGRect(
            x: frame.minX + ServerTagAppearance.horizontalPadding, y: frame.midY - ServerTagAppearance.badgeSize / 2,
            width: ServerTagAppearance.badgeSize, height: ServerTagAppearance.badgeSize
        )
    }

    @MainActor
    func draw(in frame: CGRect, badgeImage: CGImage?, isHighlighted: Bool, context: CGContext) {
        context.saveGState()
        let shape = CGPath(roundedRect: frame, cornerWidth: ServerTagAppearance.cornerRadius, cornerHeight: ServerTagAppearance.cornerRadius, transform: nil)
        context.setFillColor(NSColor.labelColor.withAlphaComponent(isHighlighted ? ServerTagAppearance.highlightedBackgroundOpacity : ServerTagAppearance.backgroundOpacity).cgColor)
        context.addPath(shape)
        context.fillPath()
        if let badgeImage, let badgeFrame = badgeFrame(in: frame) {
            let scale = min(badgeFrame.width / CGFloat(badgeImage.width), badgeFrame.height / CGFloat(badgeImage.height))
            let size = CGSize(width: CGFloat(badgeImage.width) * scale, height: CGFloat(badgeImage.height) * scale)
            context.saveGState()
            context.translateBy(x: badgeFrame.midX - size.width / 2, y: badgeFrame.midY + size.height / 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(badgeImage, in: CGRect(origin: .zero, size: size))
            context.restoreGState()
        }
        let textFrame = CGRect(
            x: frame.minX + textInset, y: frame.minY,
            width: max(0, frame.width - textInset - ServerTagAppearance.horizontalPadding), height: frame.height
        )
        text.draw(in: textFrame, color: .labelColor, context: context)
        context.restoreGState()
    }
}
