import AppKit
import SakuraCordModels

extension NativeTimelineRowPainter {
    private static let unavailableInviteSymbol = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [.systemRed]))

    static func inviteCard(_ card: NativeTimelineInviteLayout, isHovered: Bool, pressProgress: CGFloat, isModalPreview: Bool = false) {
        let background = isModalPreview ? NSColor.windowBackgroundColor : .controlBackgroundColor
        let radius = NativeTimelineInviteLayout.cornerRadius
        let shape = NSBezierPath(roundedRect: card.frame, xRadius: isModalPreview ? 0 : radius, yRadius: isModalPreview ? 0 : radius)
        background.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let invite = card.content {
            inviteGradient(card.gradientColor ?? 0x242424, in: card.bannerFrame)
            background.setFill()
            NSBezierPath(roundedRect: card.iconFrame.insetBy(dx: -3, dy: -3), xRadius: 22, yRadius: 22).fill()
            if let url = invite.iconURL, let image = mediaImage(for: .media(url, maximumPixelDimension: 128)) {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: card.iconFrame, xRadius: 19, yRadius: 19).addClip()
                drawImage(image, in: card.iconFrame, cornerRadius: 0, fillsFrame: true)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: card.iconFrame, xRadius: 19, yRadius: 19).fill()
                let initials = invite.name.split(separator: " ").prefix(3).compactMap(\.first).map(String.init).joined()
                text(initials, in: card.iconFrame.insetBy(dx: 3, dy: 19), font: .systemFont(ofSize: 20, weight: .semibold), color: .white, alignment: .center)
            }
        } else if card.isUnavailable {
            NSColor.systemRed.withAlphaComponent(0.12).setFill()
            NSBezierPath(concentricRoundedRect: card.iconFrame, cornerRadius: 12).fill()
            if let image = unavailableInviteSymbol {
                drawImage(image, in: card.iconFrame.insetBy(dx: 11, dy: 11), cornerRadius: 0, fillsFrame: false)
            }
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: card.frame.minX, y: card.frame.minY, width: card.frame.width,
                                 height: card.contentBottom - card.frame.minY + (card.hasCollapsedContent ? 16 : 1))).addClip()
        if let avatarFrame = card.inviterAvatarFrame, let url = card.content?.inviter?.avatarURL,
           let image = mediaImage(for: .media(url, maximumPixelDimension: 32)) {
            drawImage(image, in: avatarFrame, cornerRadius: 8, fillsFrame: true)
        }
        for label in card.labels {
            let color: NSColor = card.isUnavailable && label.bold ? .systemRed : label.secondary ? .secondaryLabelColor : .labelColor
            attributedText(label.attributedText(color: color), in: label.frame, model: nil)
        }
        for (index, dot) in card.countDots.enumerated() {
            (index == 0 && card.content?.onlineCount != nil ? NSColor.systemGreen : .secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        for trait in card.traits {
            NativeTimelineSemanticColor.opacity(.labelColor, 0.13).setStroke()
            let pill = NSBezierPath(concentricRoundedRect: trait.frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 13.5)
            pill.lineWidth = 1
            pill.stroke()
            var textFrame = trait.frame.insetBy(dx: 8, dy: 4)
            if trait.value.emoji != nil || trait.value.emojiURL != nil {
                let emojiFrame = CGRect(x: textFrame.minX, y: textFrame.minY + 2, width: 16, height: 16)
                if let url = trait.value.emojiURL, let image = mediaImage(for: .media(url, maximumPixelDimension: 32)) {
                    drawImage(image, in: emojiFrame, cornerRadius: 0, fillsFrame: false)
                } else if let emoji = trait.value.emoji {
                    let value = NativeEmojiCatalogMetadata.value(forShortcode: emoji) ?? emoji
                    drawImage(ComponentUnicodeEmojiRenderer.image(for: value), in: emojiFrame, cornerRadius: 0, fillsFrame: false)
                }
                textFrame.origin.x += 20
                textFrame.size.width -= 20
            }
            text(trait.value.label, in: textFrame, font: .systemFont(ofSize: 14), color: .labelColor)
        }
        NSGraphicsContext.restoreGraphicsState()
        if card.hasCollapsedContent {
            let fade = CGRect(x: card.frame.minX, y: card.contentBottom - 48, width: card.frame.width, height: 64)
            NSGradient(starting: background.withAlphaComponent(0), ending: background)?.draw(in: fade, angle: 90)
        }
        if let details = card.detailsFrame, card.isExpanded {
            text("Hide Details", in: details, font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor, alignment: .center)
        }
        if card.buttonFrame.height > 0, !isModalPreview {
            sakuraCordButton(
                title: card.buttonTitle, frame: card.buttonFrame,
                isHovered: isHovered && !card.isDisabled,
                pressProgress: card.isDisabled ? 0 : pressProgress,
                colors: [.sakuraCordAccentColor], isEnabled: !card.isDisabled
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        guard !isModalPreview else { return }
        NativeTimelineSemanticColor.opacity(.labelColor, 0.10).setStroke()
        let border = NSBezierPath(roundedRect: card.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        border.lineWidth = 1
        border.stroke()
    }

    /// The first-party profile gradient brightens the preset by 1.75 CIELAB steps (31.5 L*).
    private static func inviteGradient(_ hex: UInt32, in frame: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext, frame.height > 0 else { return }
        let base = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        let bright = inviteBrightColor(base)
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [bright.cgColor, base.cgColor] as CFArray, locations: [0.2065, 0.8516]) else { return }
        context.saveGState()
        context.clip(to: frame)
        context.translateBy(x: frame.minX + frame.width * 0.501, y: frame.minY + frame.height * 1.2705)
        context.scaleBy(x: frame.width * 1.0543, y: frame.height * 1.2705)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                   endCenter: .zero, endRadius: 1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private static func inviteBrightColor(_ color: NSColor) -> NSColor {
        func linear(_ value: CGFloat) -> CGFloat { value > 0.04045 ? pow((value + 0.055) / 1.055, 2.4) : value / 12.92 }
        func labTransform(_ value: CGFloat) -> CGFloat { value > 0.008856 ? pow(value, 1 / 3.0) : 7.787 * value + 16 / 116.0 }
        func inverse(_ value: CGFloat) -> CGFloat { pow(value, 3) > 0.008856 ? pow(value, 3) : (value - 16 / 116.0) / 7.787 }
        func gamma(_ value: CGFloat) -> CGFloat { min(1, max(0, value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055)) }
        let red = linear(color.redComponent), green = linear(color.greenComponent), blue = linear(color.blueComponent)
        let labX = labTransform((0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / 0.95047)
        let labY = labTransform(0.2126729 * red + 0.7151522 * green + 0.0721750 * blue)
        let labZ = labTransform((0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / 1.08883)
        let newY = labY + 31.5 / 116
        let xx = 0.95047 * inverse(labX + newY - labY), yy = inverse(newY), zz = 1.08883 * inverse(labZ + newY - labY)
        return NSColor(srgbRed: gamma(3.2404542 * xx - 1.5371385 * yy - 0.4985314 * zz),
                       green: gamma(-0.9692660 * xx + 1.8760108 * yy + 0.0415560 * zz),
                       blue: gamma(0.0556434 * xx - 0.2040259 * yy + 1.0572252 * zz), alpha: 1)
    }
}
