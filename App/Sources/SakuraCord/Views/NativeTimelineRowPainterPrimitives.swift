import AppKit

extension NativeTimelineRowPainter {
    private struct BubbleIntegratedSectionGeometry {
        let frame: CGRect
        let cornerRadius: CGFloat
        let ownsTopEdge: Bool
        let ownsBottomEdge: Bool

        var path: NSBezierPath {
            NSBezierPath(
                concentricRoundedRect: frame,
                cornerRadius: cornerRadius
            )
        }
    }

    static func bubbleIntegratedSection(
        _ frame: CGRect,
        bubbleRegion: NativeTimelineBubbleRegion,
        accentColor: UInt32?,
        drawsTopSeparator: Bool,
        drawsNeutralRail: Bool = false
    ) {
        let geometry = bubbleIntegratedSectionGeometry(
            frame,
            bubbleRegion: bubbleRegion
        )
        if let railColor = NSColor(discordColor: accentColor)
            ?? (drawsNeutralRail
                ? NSColor.secondaryLabelColor.withAlphaComponent(0.52)
                : nil)
        {
            NSGraphicsContext.saveGraphicsState()
            NativeTimelineBubbleDrawing.bodyPath(for: bubbleRegion).addClip()
            geometry.path.addClip()
            railColor.setFill()
            CGRect(
                x: geometry.frame.minX,
                y: geometry.frame.minY,
                width: InterfaceScale.metric(4),
                height: geometry.frame.height
            ).fill()
            NSGraphicsContext.restoreGraphicsState()
            // The rail runs along the leading edge, so it only reaches an
            // incoming bubble's tail.
            if geometry.ownsBottomEdge,
               bubbleRegion.showsTail,
               !bubbleRegion.isOutgoing,
               let accentColor = NSColor(discordColor: accentColor)
            {
                accentColor.setFill()
                NativeTimelineBubbleDrawing.fillTailProtrusion(of: bubbleRegion)
            }
        }

        if drawsTopSeparator {
            NSGraphicsContext.saveGraphicsState()
            NativeTimelineBubbleDrawing.bodyPath(for: bubbleRegion).addClip()
            NSBezierPath(rect: CGRect(
                x: geometry.frame.minX - 1,
                y: geometry.frame.minY - 1,
                width: geometry.frame.width + InterfaceScale.metric(2),
                height: geometry.cornerRadius + InterfaceScale.metric(2)
            )).addClip()
            NSColor.separatorColor.withAlphaComponent(0.28).setStroke()
            let separator = geometry.path
            separator.lineWidth = 0.75
            separator.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func bubbleIntegratedSectionsTint(
        _ frames: [CGRect],
        bubbleRegion: NativeTimelineBubbleRegion
    ) {
        let frames = frames
            .filter { !$0.isEmpty }
            .sorted { $0.minY < $1.minY }
        guard var currentGroup = frames.first else { return }

        var groups: [CGRect] = []
        for frame in frames.dropFirst() {
            if frame.minY - currentGroup.maxY <= 9 {
                currentGroup = currentGroup.union(frame)
            } else {
                groups.append(currentGroup)
                currentGroup = frame
            }
        }
        groups.append(currentGroup)

        for group in groups {
            let geometry = bubbleIntegratedSectionGeometry(
                group,
                bubbleRegion: bubbleRegion
            )
            bubbleIntegratedSectionTintColor.setFill()
            geometry.path.fill()
            // A section along the bottom edge continues into the tail.
            if geometry.ownsBottomEdge {
                NativeTimelineBubbleDrawing.fillTailProtrusion(of: bubbleRegion)
            }
        }
    }

    static let bubbleIntegratedSectionTintColor = NSColor(
        name: nil
    ) { appearance in
        appearance.isDark
            ? NSColor.black.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.055)
    }

    private static func bubbleIntegratedSectionGeometry(
        _ frame: CGRect,
        bubbleRegion: NativeTimelineBubbleRegion
    ) -> BubbleIntegratedSectionGeometry {
        let bubbleFrame = bubbleRegion.frame
        // Content within the bubble's own padding of an edge reaches it.
        let edgeSlack = NativeTimelineBubbleLayout.verticalPadding + 0.5
        let ownsTopEdge = frame.minY - bubbleFrame.minY <= edgeSlack
        let ownsBottomEdge = bubbleFrame.maxY - frame.maxY <= edgeSlack
        let sectionMinY = ownsTopEdge
            ? bubbleFrame.minY
            : max(bubbleFrame.minY, frame.minY - 4.5)
        let sectionMaxY = ownsBottomEdge
            ? bubbleFrame.maxY
            : min(bubbleFrame.maxY, frame.maxY + 4.5)
        let sectionFrame = CGRect(
            x: bubbleFrame.minX,
            y: sectionMinY,
            width: bubbleFrame.width,
            height: max(1, sectionMaxY - sectionMinY)
        )
        return BubbleIntegratedSectionGeometry(
            frame: sectionFrame,
            cornerRadius: min(
                NativeTimelineBubbleDrawing.cornerRadius,
                sectionFrame.height / 2
            ),
            ownsTopEdge: ownsTopEdge,
            ownsBottomEdge: ownsBottomEdge
        )
    }

    static func adjustedBrightness(
        _ color: NSColor,
        amount: CGFloat
    ) -> NSColor {
        guard abs(amount) > 0.0001,
              let rgb = color.usingColorSpace(.deviceRGB)
        else { return color }
        return NSColor(
            deviceRed: min(max(rgb.redComponent + amount, 0), 1),
            green: min(max(rgb.greenComponent + amount, 0), 1),
            blue: min(max(rgb.blueComponent + amount, 0), 1),
            alpha: rgb.alphaComponent
        )
    }

    static func systemSymbol(
        _ name: String,
        in frame: CGRect,
        color: NSColor,
        inset: CGFloat,
        weight: NSFont.Weight = .regular
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        let pointSize = max(
            10,
            min(frame.width, frame.height) - max(0, inset) * 2
        )
        let deviceSize = NSGraphicsContext.current?.cgContext
            .convertToDeviceSpace(CGSize(width: 1, height: 1))
        let backingScale = deviceSize.map {
            max(abs($0.width), abs($0.height))
        } ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let image = SystemSymbolImageCache
            .rasterizedConfiguredImage(
            named: name,
            pointSize: pointSize,
            weight: weight,
            color: color,
            scale: backingScale
        )
        else { return }
        let target = frame.insetBy(
            dx: min(max(0, inset), frame.width / 2 - 1),
            dy: min(max(0, inset), frame.height / 2 - 1)
        )
        let fittedTarget = SymbolGeometry.opticallyFitted(
            sourceSize: image.size,
            alignmentRect: image.alignmentRect,
            in: target
        )
        image.draw(
            in: fittedTarget,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    /// A media tile: an optional tinted backdrop, then the loaded image, its
    /// ThumbHash placeholder or a fallback symbol, and a play glyph on video.
    static func drawMediaSurface(
        in frame: CGRect,
        cornerRadius: CGFloat,
        backdrop: NSColor?,
        image: NSImage?,
        fillsFrame: Bool,
        placeholder: @autoclosure () -> NativeTimelineMediaPlaceholder?,
        placeholderFillsFrame: Bool = true,
        fallbackSymbol: (name: String, inset: CGFloat)?,
        isVideo: Bool = false
    ) {
        if let backdrop {
            backdrop.setFill()
            NSBezierPath(concentricRoundedRect: frame, cornerRadius: cornerRadius).fill()
        }
        if let image {
            drawImage(image, in: frame, cornerRadius: cornerRadius, fillsFrame: fillsFrame)
        } else if let placeholder = placeholder()?.image {
            drawImage(placeholder, in: frame, cornerRadius: cornerRadius, fillsFrame: placeholderFillsFrame)
        } else if let fallbackSymbol {
            systemSymbol(fallbackSymbol.name, in: frame, color: .secondaryLabelColor, inset: fallbackSymbol.inset)
        }
        if isVideo { mediaPlayGlyph(in: frame) }
    }

    /// Where an image of `size` lands when it fills or fits `frame`, centred.
    static func drawImage(
        _ image: NSImage,
        in frame: CGRect,
        cornerRadius: CGFloat,
        fillsFrame: Bool
    ) {
        guard frame.width > 0, frame.height > 0,
              image.size.width > 0, image.size.height > 0
        else { return }
        let destination = aspectRect(for: image.size, in: frame, fillsFrame: fillsFrame)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: cornerRadius
        ).addClip()
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws `body` at `opacity` composited as one layer, so images, symbols
    /// and text fade together; at full opacity it draws directly.
    static func drawing(opacity: CGFloat, in context: CGContext?, _ body: () -> Void) {
        if opacity < 1 {
            context?.setAlpha(opacity)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        body()
        if opacity < 1 { context?.endTransparencyLayer() }
    }

    /// Scales what is drawn next about `frame`'s centre; at full scale the
    /// context is left as it is.
    static func concatScale(_ scale: CGFloat, aboutCenterOf frame: CGRect) {
        guard abs(scale - 1) > 0.0001 else { return }
        let transform = NSAffineTransform()
        transform.translateX(by: frame.midX, yBy: frame.midY)
        transform.scaleX(by: scale, yBy: scale)
        transform.translateX(by: -frame.midX, yBy: -frame.midY)
        transform.concat()
    }

    static func card(_ frame: CGRect, tint: NSColor) {
        tint.withAlphaComponent(0.09).setFill()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: InterfaceScale.metric(8)
        ).fill()
        tint.withAlphaComponent(0.55).setStroke()
        let edge = NSBezierPath()
        edge.lineWidth = 3
        edge.move(to: CGPoint(x: frame.minX + InterfaceScale.metric(1.5), y: frame.minY + InterfaceScale.metric(7)))
        edge.line(to: CGPoint(x: frame.minX + InterfaceScale.metric(1.5), y: frame.maxY - InterfaceScale.metric(7)))
        edge.stroke()
    }

    /// The card behind both an embed and a component container, so the two
    /// always look alike: Discord's surface and subtle border, with an
    /// accent drawn as a thicker left border. Discord rounds an embed's card
    /// tighter than a container's, so each passes its own radius.
    static func discordCard(_ frame: CGRect, cornerRadius: CGFloat, accent: NSColor?) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(concentricRoundedRect: frame, cornerRadius: cornerRadius).addClip()
        DiscordEmbedPalette.cardFill.setFill()
        frame.fill()
        if let accent {
            let barWidth = InterfaceScale.metric(4)
            accent.setFill()
            CGRect(x: frame.minX, y: frame.minY, width: barWidth, height: frame.height).fill()
            // The 1 pt border runs along the other three sides only.
            NSBezierPath.clip(CGRect(x: frame.minX + barWidth, y: frame.minY, width: frame.width - barWidth, height: frame.height))
        }
        DiscordEmbedPalette.cardBorder.setStroke()
        NSBezierPath.strokeHairline(frame, cornerRadius: cornerRadius)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `isUnread` folds the NEW divider in, as Discord does when both fall on
    /// the same message: the rule and date turn red and the pill ends the line.
    static func dateSeparator(date: Date, frame: CGRect, isUnread: Bool = false) {
        let label = date.formatted(
            .dateTime.day().month(.wide).year()
        )
        let pill = newMessagesPillFrame(in: frame)
        let pillLineEnd = lineEnd(before: pill)
        var labelFrame = NativeTimelineDateSeparatorMetrics.labelFrame(
            for: label,
            in: frame
        )
        // In a narrow timeline the date keeps clear of where NEW folds in,
        // so it stays put while NEW fades in or out over it.
        if labelFrame.maxX > pillLineEnd {
            labelFrame.origin.x = max(frame.minX, pillLineEnd - labelFrame.width)
            labelFrame.size.width = pillLineEnd - labelFrame.minX
        }
        let ruleEnd = isUnread ? pillLineEnd : frame.maxX
        if isUnread { drawNewMessagesPill(pill) }
        (isUnread ? MentionRed.nsColor : NSColor.labelColor.withAlphaComponent(0.16)).setFill()
        CGRect(
            x: frame.minX,
            y: frame.midY,
            width: max(
                0,
                labelFrame.minX
                    - NativeTimelineDateSeparatorMetrics.lineSpacing
                    - frame.minX
            ),
            height: 1
        ).fill()
        CGRect(
            x: labelFrame.maxX
                + NativeTimelineDateSeparatorMetrics.lineSpacing,
            y: frame.midY,
            width: max(
                0,
                ruleEnd
                    - labelFrame.maxX
                    - NativeTimelineDateSeparatorMetrics.lineSpacing
            ),
            height: 1
        ).fill()
        text(
            label,
            in: labelFrame,
            font: NativeTimelineDateSeparatorMetrics.font,
            color: isUnread ? MentionRed.nsColor : .secondaryLabelColor,
            alignment: .center,
            lineBreakMode: .byClipping
        )
    }

    static func newMessagesSeparator(frame: CGRect) {
        let pill = newMessagesPillFrame(in: frame)
        drawNewMessagesPill(pill)
        MentionRed.nsColor.setFill()
        CGRect(x: frame.minX, y: frame.midY, width: max(0, lineEnd(before: pill) - frame.minX), height: 1).fill()
    }

    /// Where a divider's line stops short of the NEW pill.
    private static func lineEnd(before pill: CGRect) -> CGFloat {
        pill.minX - InterfaceScale.metric(8)
    }

    private static var newMessagesPillFont: NSFont { .interfaceSystemFont(ofSize: 10, weight: .bold) }

    /// Where the red NEW pill sits at the end of a divider's `frame`.
    private static func newMessagesPillFrame(in frame: CGRect) -> CGRect {
        let width = ceil(measuredTextWidth("NEW", font: newMessagesPillFont) + 14)
        let height = NativeTimelineUnreadSeparatorMetrics.capsuleHeight
        return CGRect(x: frame.maxX - width, y: frame.midY - height / 2, width: width, height: height)
    }

    private static func drawNewMessagesPill(_ pill: CGRect) {
        MentionRed.nsColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text(
            "NEW",
            in: pill,
            font: newMessagesPillFont,
            color: .white,
            alignment: .center,
            lineBreakMode: .byClipping
        )
    }

    static func gradientButton(
        title: String, frame: CGRect, isHovered: Bool, pressProgress: CGFloat = 0,
        colors: [NSColor], foreground: NSColor = .white, isEnabled: Bool = true
    ) {
        let pressProgress = min(max(pressProgress, 0), 1)
        let scale = NativeTimelineComponentButtonVisualState.scale(
            pressProgress: pressProgress
        )
        let brightness = NativeTimelineComponentButtonVisualState.brightness(
            isHovered: isHovered,
            pressProgress: pressProgress
        )
        let buttonColors = colors.map {
            adjustedBrightness($0, amount: brightness)
        }
        NSGraphicsContext.saveGraphicsState()
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
        concatScale(scale, aboutCenterOf: frame)
        let buttonPath = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: frame.height / 2
        )
        gradient(buttonColors)?.draw(in: buttonPath, angle: 0)
        NSColor.black.withAlphaComponent(0.12).setFill()
        buttonPath.fill()
        adjustedBrightness(
            foreground,
            amount: brightness
        ).withAlphaComponent(
            NativeTimelineComponentButtonVisualState.borderAlpha(
                isHovered: isHovered,
                isEnabled: isEnabled
            )
        ).setStroke()
        NSBezierPath.strokeHairline(frame, cornerRadius: frame.height / 2)
        text(
            title,
            in: frame,
            font: NativeTimelineComponentButtonMetrics.font,
            color: adjustedBrightness(
                foreground,
                amount: brightness
            ),
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    static func gradient(_ colors: [NSColor]) -> NSGradient? {
        guard let first = colors.first else { return nil }
        return NSGradient(colors: colors.count == 1 ? [first, first] : colors)
    }
}
