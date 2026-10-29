import AppKit

@MainActor
enum SelectionFieldLayoutMetrics {
    static var font: NSFont { .interfaceSystemFont(ofSize: 13, weight: .medium) }
    /// Discord's 16-pixel placeholder, at the message text's size.
    static var placeholderFont: NSFont {
        .interfaceSystemFont(ofSize: InterfaceTypographyMetrics.messageTextSize, weight: .medium)
    }
    /// Discord's 40-point field with an 8-point radius and 12-point inset.
    static var minimumHeight: CGFloat { InterfaceScale.metric(40) }
    static var cornerRadius: CGFloat { InterfaceScale.metric(8) }
    static var leadingInset: CGFloat { InterfaceScale.metric(12) }
    /// Token geometry shared by measurement, the native painter and the open field.
    static var tokenHeight: CGFloat { InterfaceScale.metric(28) }
    static var tokenSpacing: CGFloat { InterfaceScale.metric(6) }
    static var tokenVerticalPadding: CGFloat { InterfaceScale.metric(6) }
    /// Width reserved beside the tokens for the chevron and insets.
    static var tokenTrailingReserve: CGFloat { InterfaceScale.metric(50) }

    static func tokenAvailableWidth(in width: CGFloat) -> CGFloat {
        max(InterfaceScale.metric(40), width - tokenTrailingReserve)
    }

    static func tokenWidth<ID: Hashable & Sendable>(_ option: SelectionFieldOption<ID>, availableWidth: CGFloat) -> CGFloat {
        let titleWidth = (option.title as NSString).size(withAttributes: [.font: font]).width
        let leadingWidth: CGFloat = option.leading == .none ? 0 : InterfaceScale.metric(28)
        return min(max(InterfaceScale.metric(40), availableWidth), min(InterfaceScale.metric(220), ceil(titleWidth + leadingWidth + InterfaceScale.metric(35))))
    }

    static func preferredHeight<ID: Hashable & Sendable>(
        options: [SelectionFieldOption<ID>],
        width: CGFloat
    ) -> CGFloat {
        let available = tokenAvailableWidth(in: width)
        var lineWidth: CGFloat = 0
        var lines = 1
        let widths = options.map { tokenWidth($0, availableWidth: available) }
        for tokenWidth in widths {
            if lineWidth > 0, lineWidth + tokenWidth > available {
                lines += 1
                lineWidth = 0
            }
            lineWidth += tokenWidth + tokenSpacing
        }
        return max(
            minimumHeight,
            CGFloat(lines) * tokenHeight + CGFloat(lines - 1) * tokenSpacing + tokenVerticalPadding * 2
        )
    }

}

/// AppKit rendering for collapsed message-component fields; interactive fields use SwiftUI.
/// Geometry, type and colours mirror `SelectionField` so opening a field does
/// not move or restyle anything.
@MainActor
enum SelectionFieldRenderer {
    /// The open field's 22×28 chevron button, inside its leading inset.
    static func chevronRect(in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.maxX - SelectionFieldLayoutMetrics.leadingInset - InterfaceScale.metric(22),
            y: frame.midY - InterfaceScale.metric(14),
            width: InterfaceScale.metric(22),
            height: InterfaceScale.metric(28)
        )
    }

    /// SwiftUI centres a text line by its line box, not the font's glyph bounds.
    static func lineHeight(of font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func drawText(
        _ value: String,
        in frame: CGRect,
        color: NSColor,
        opacity: CGFloat = 1
    ) {
        guard !value.isEmpty else { return }
        let font = SelectionFieldLayoutMetrics.placeholderFont
        let lineHeight = lineHeight(of: font)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(
            in: CGRect(
                x: frame.minX + SelectionFieldLayoutMetrics.leadingInset,
                y: (frame.midY - lineHeight / 2).rounded(),
                width: max(1, frame.width - InterfaceScale.metric(50)),
                height: lineHeight
            ),
            withAttributes: [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: color.withAlphaComponent(
                    color.alphaComponent * opacity
                ),
            ]
        )
    }

    static func drawChevron(
        in frame: CGRect,
        opacity: CGFloat = 1
    ) {
        drawSymbol(
            "chevron.down",
            pointSize: 11,
            centeredIn: chevronRect(in: frame),
            color: .secondaryLabelColor,
            opacity: opacity
        )
    }

    /// Draws a symbol at its natural point size, as SwiftUI's `Image` does,
    /// rather than scaling it to fill a rectangle. The timeline's raster cache
    /// resolves the dynamic colour for the current appearance.
    private static func drawSymbol(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight = .semibold, centeredIn rect: CGRect, color: NSColor,
        opacity: CGFloat = 1
    ) {
        let device = NSGraphicsContext.current?.cgContext.convertToDeviceSpace(CGSize(width: 1, height: 1))
        // Symbol palettes ignore alpha, which turns dark-mode secondary label
        // (translucent white) opaque. Draw the opaque colour at its alpha.
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        guard let image = NativeTimelineSystemSymbolCache.rasterizedConfiguredImage(
            named: name, pointSize: pointSize, weight: weight, color: resolved.withAlphaComponent(1),
            scale: device.map { max(abs($0.width), abs($0.height)) } ?? 2
        ) else { return }
        let size = image.size
        image.draw(
            in: CGRect(
                x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded(),
                width: size.width, height: size.height
            ),
            from: .zero, operation: .sourceOver, fraction: resolved.alphaComponent * opacity, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    static func tokenImage<ID: Hashable & Sendable>(
        option: SelectionFieldOption<ID>,
        font: NSFont,
        leadingImage: NSImage?,
        maximumWidth: CGFloat = 180
    ) -> NSImage {
        let labelFont = NSFont.systemFont(
            ofSize: font.pointSize,
            weight: .medium
        )
        let height: CGFloat = InterfaceScale.metric(28)
        let leadingSize: CGFloat = InterfaceScale.metric(20)
        let hasLeading = option.leading != .none
        let closeWidth: CGFloat = InterfaceScale.metric(26)
        let contentWidth = maximumWidth
        return NSImage(size: NSSize(width: contentWidth, height: height), flipped: false) { bounds in
            let card = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: contentWidth,
                height: bounds.height
            )
            let shape = NSBezierPath(
                concentricRoundedRect: card,
                cornerRadius: height / 2
            )
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            shape.fill()

            var contentX: CGFloat = InterfaceScale.metric(9)
            if hasLeading {
                let rect = CGRect(
                    x: contentX,
                    y: (height - leadingSize) / 2,
                    width: leadingSize,
                    height: leadingSize
                )
                draw(
                    option.leading,
                    image: leadingImage,
                    in: rect
                )
                contentX = rect.maxX + 8
            }
            let textHeight = lineHeight(of: labelFont)
            let textY = ((height - textHeight) / 2).rounded()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (option.title as NSString).draw(
                in: CGRect(x: contentX, y: textY, width: max(0, contentWidth - contentX - closeWidth), height: textHeight),
                withAttributes: [
                    .font: labelFont,
                    .paragraphStyle: paragraph,
                    .foregroundColor: titleColor(
                        for: option.titleStyle
                    ),
                ]
            )
            // The open token's 16×28 remove button, 5 points from its edge.
            drawSymbol("xmark", pointSize: 9, centeredIn: CGRect(x: contentWidth - InterfaceScale.metric(21), y: 0, width: InterfaceScale.metric(16), height: height),
                       color: .secondaryLabelColor)
            return true
        }
    }

    private static func draw(
        _ leading: SelectionFieldLeading,
        image: NSImage?,
        in rect: CGRect
    ) {
        switch leading {
        case .none:
            return
        case .systemImage(let name):
            drawSymbol(name, pointSize: 13, weight: .regular, centeredIn: rect, color: .secondaryLabelColor)
        case .text(let value):
            let font = NSFont.systemFont(ofSize: rect.height * 0.75)
            let size = (value as NSString).size(withAttributes: [.font: font])
            (value as NSString).draw(
                at: CGPoint(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2
                ),
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        case let .role(colorHex, _, unicodeEmoji):
            if let image {
                image.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            } else if let unicodeEmoji, !unicodeEmoji.isEmpty {
                let font = NSFont.systemFont(ofSize: rect.height * 0.75)
                let size = (unicodeEmoji as NSString).size(
                    withAttributes: [.font: font]
                )
                (unicodeEmoji as NSString).draw(
                    at: CGPoint(
                        x: rect.midX - size.width / 2,
                        y: rect.midY - size.height / 2
                    ),
                    withAttributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
            } else {
                RoleColorIndicatorRenderer.draw(
                    colorHex: colorHex,
                    in: rect.insetBy(dx: InterfaceScale.metric(3), dy: InterfaceScale.metric(3))
                )
            }
        case .remoteImage(_, let fallback, let shape):
            let path = switch shape {
            case .circle:
                NSBezierPath(ovalIn: rect)
            case .roundedRectangle:
                NSBezierPath(roundedRect: rect, xRadius: InterfaceScale.metric(4), yRadius: InterfaceScale.metric(4))
            }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            if let image {
                image.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            } else {
                NSColor.sakuraCordAccentColor.withAlphaComponent(0.65).setFill()
                path.fill()
                let value = String(fallback.prefix(1)).uppercased() as NSString
                let font = NSFont.interfaceSystemFont(ofSize: 10, weight: .semibold)
                let size = value.size(withAttributes: [.font: font])
                value.draw(
                    at: CGPoint(
                        x: rect.midX - size.width / 2,
                        y: rect.midY - size.height / 2
                    ),
                    withAttributes: [
                        .font: font,
                        .foregroundColor: NSColor.white,
                    ]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func titleColor(
        for style: SelectionFieldTitleStyle
    ) -> NSColor {
        switch style {
        case .standard:
            .labelColor
        case .memberColor(let colorHex):
            if SakuraCordAccentColor.usesAccentFallback(
                forRoleColorHex: colorHex
            ) {
                .labelColor
            } else {
                SakuraCordAccentColor.nsColor(
                    forRoleColorHex: colorHex
                )
            }
        case .roleColor(let colorHex):
            SakuraCordAccentColor.nsColor(forRoleColorHex: colorHex)
        }
    }
}
