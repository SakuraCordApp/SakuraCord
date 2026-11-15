import AppKit
import SakuraCordModels

extension NativeTimelineRowPainter {
    static func sakuraCordDeepLinkCard(
        _ region: NativeTimelineRowLayout.SakuraCordDeepLinkRegion,
        bubbleRegion: NativeTimelineBubbleRegion? = nil,
        isButtonHovered: Bool,
        buttonPressProgress: CGFloat
    ) {
        let colors = sakuraCordDeepLinkColors(for: region.action)
        let outgoing = bubbleRegion?.isOutgoing == true
        let accent = outgoing ? NSColor.sakuraCordLabelOnAccentColor : colors.first ?? NSColor.sakuraCordAccentColor
        let cardCornerRadius = ChatChromeMetrics.composerCornerRadius
        let shape = NSBezierPath(
            concentricRoundedRect: region.cardFrame,
            cornerRadius: cardCornerRadius
        )

        if let bubbleRegion {
            bubbleIntegratedSection(region.frame, bubbleRegion: bubbleRegion, accentColor: nil,
                drawsTopSeparator: region.drawsTopSeparator)
        } else {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = accent.withAlphaComponent(0.28)
            glow.shadowBlurRadius = 13
            glow.shadowOffset = .zero
            glow.set()
            accent.withAlphaComponent(0.20).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            gradient(colors)?.draw(in: shape, angle: 0)
            NativeTimelineSemanticColor.opacity(.controlBackgroundColor, 0.94).setFill()
            NSBezierPath(concentricRoundedRect: region.cardFrame.insetBy(dx: 1, dy: 1), cornerRadius: cardCornerRadius - 1).fill()
        }

        accent.withAlphaComponent(0.16).setFill()
        NSBezierPath(
            ovalIn: region.symbolBackgroundFrame
        ).fill()
        systemSymbol(
            region.action.systemImage,
            in: region.symbolFrame,
            color: accent,
            inset: InterfaceScale.metric(2),
            weight: .semibold
        )
        text(
            region.action.title,
            in: region.titleFrame,
            font: .interfaceSystemFont(ofSize: 14, weight: .semibold),
            color: NativeTimelineBubbleDrawing.foregroundColor(for: bubbleRegion),
            lineBreakMode: .byTruncatingTail
        )

        for (frame, color) in zip(region.paletteFrames, colors) {
            color.setFill()
            NSBezierPath(ovalIn: frame).fill()
            NativeTimelineSemanticColor.opacity(
                .controlBackgroundColor,
                0.92
            ).setStroke()
            let outline = NSBezierPath(ovalIn: frame.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }

        gradientButton(title: region.action.buttonTitle, frame: region.buttonFrame,
            isHovered: isButtonHovered, pressProgress: buttonPressProgress,
            colors: outgoing ? [.sakuraCordLabelOnAccentColor] : colors, foreground: outgoing ? .sakuraCordAccentColor
                : SakuraCordAccentColor.labelNSColor(on: colors.first ?? .sakuraCordAccentColor))
    }

    static func sakuraCordDeepLinkColors(
        for action: SakuraCordDeepLinkAction
    ) -> [NSColor] {
        guard let preview = action.themePreview else {
            return [.sakuraCordAccentColor]
        }
        let appearance = NSAppearance.currentDrawing().isDark ? SakuraCordThemeAppearance.dark : .light
        return preview.theme.activeColors.map {
            NSColor(preview.theme.renderedRGB($0, for: appearance))
        }
    }
}
