import AppKit

/// Discord's badge for a message sent with `@silent`: a bell with a "z",
/// 4/3 of the timestamp's size, with the tooltip below.
enum NativeTimelineSilentBadge {
    static let help = "This is a @silent message."
    static var spacing: CGFloat { InterfaceScale.metric(5) }

    static func side(for timestampFont: NSFont) -> CGFloat {
        (timestampFont.pointSize * 4 / 3).rounded()
    }

    /// Drawn at the timestamp's point size, which fills the frame the way
    /// Discord's icon does, and at its natural size so the "z" stays sharp.
    static func draw(in frame: CGRect) {
        let scale = NSGraphicsContext.current?.cgContext.convertToDeviceSpace(CGSize(width: 1, height: 1)).height
            .magnitude ?? 2
        // A palette colour's alpha is applied twice, so the bell is rendered
        // opaque and given the muted colour's alpha as it is drawn.
        let color = NSColor.secondaryLabelColor
        guard let image = NativeTimelineSystemSymbolCache.rasterizedConfiguredImage(
            named: SakuraCordSystemSymbol.silentBell,
            pointSize: frame.height * 3 / 4,
            weight: .regular,
            color: color.withAlphaComponent(1),
            scale: scale
        ) else { return }
        // The symbol's cap band is centred where the frame centres on the
        // timestamp's capitals, putting both on one baseline.
        let origin = CGPoint(
            x: frame.midX - image.size.width / 2,
            y: frame.midY - image.size.height + image.alignmentRect.midY
        )
        image.draw(
            in: CGRect(
                origin: CGPoint(x: (origin.x * scale).rounded() / scale, y: (origin.y * scale).rounded() / scale),
                size: image.size
            ),
            from: .zero, operation: .sourceOver, fraction: color.alphaComponent, respectFlipped: true, hints: nil
        )
    }
}
