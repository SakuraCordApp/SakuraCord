import AppKit
import QuartzCore

/// Discord's one spoiler look, shared by text, media, files, embeds and
/// components. Lengths are Discord's CSS pixels at SakuraCord's text size.
nonisolated enum SpoilerAppearance {
    static var pillHeight: CGFloat { DiscordRichMessageMetrics.px(31) }
    static var pillHorizontalPadding: CGFloat { DiscordRichMessageMetrics.px(12) }
    static var textCornerRadius: CGFloat { DiscordRichMessageMetrics.px(4) }
    /// Discord blurs hidden media by 44 pixels, past recognition.
    static var blurRadius: CGFloat { DiscordRichMessageMetrics.px(44) }
    static let mediaRevealDuration: CFTimeInterval = 0.1
    static let textRevealDuration: CFTimeInterval = 0.2

    /// Behind hidden media and over hidden text: Discord's midnight theme in
    /// dark mode, which matches SakuraCord's near-black timeline, and its
    /// light theme otherwise.
    static let hiddenColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0x59 / 255, green: 0x5A / 255, blue: 0x63 / 255, alpha: 1)
            : NSColor(srgbRed: 0x8F / 255, green: 0x90 / 255, blue: 0x97 / 255, alpha: 1)
    }

    /// How far hover tints a hidden spoiler, the one strength every kind
    /// shares: text's fill, and half as much over a media cover, whose pill
    /// also darkens. Dark mode lightens toward white and light mode darkens
    /// toward black, as Discord's hover does: dark text goes #595A63 →
    /// #84858C, light #8F9097 → #6A6B70.
    static let hoverTint: CGFloat = 0.26

    static let hoverTintColor = NSColor(name: nil, dynamicProvider: hoverTintBase)

    /// Over a media cover, which the hover tints by half of text's.
    static let mediaHoverTintColor = NSColor(name: nil) { hoverTintBase($0).withAlphaComponent(hoverTint / 2) }

    private static func hoverTintBase(_ appearance: NSAppearance) -> NSColor {
        appearance.isDark ? .white : .black
    }

    /// A revealed text spoiler keeps a faint fill, so it still reads as one.
    /// The light timeline is close to the fill's gray, so it takes more of it
    /// to show as much.
    static let revealedTextColor = NSColor(name: nil) { appearance in
        NSColor(
            srgbRed: 0x97 / 255, green: 0x97 / 255, blue: 0x9F / 255,
            alpha: appearance.isDark ? 0.12 : 0.24
        )
    }

    static let pillColor = NSColor.black.withAlphaComponent(0.6)
    /// Over the drawn pill, this darkens it to Discord's hovered 88 percent.
    static let hoveredPillOverlayColor = NSColor.black.withAlphaComponent(0.7)

    /// Discord's pill sits on items at least as wide as its 216-pixel upload
    /// tiles. A smaller tile, such as a staged attachment, scales the pill to
    /// match; on a thumbnail too small to read it, the blur stands alone.
    static func pillScale(forTileWidth width: CGFloat) -> CGFloat? {
        let scale = min(1, width / DiscordRichMessageMetrics.px(216))
        return scale >= 0.5 ? scale : nil
    }

    /// A hidden text spoiler's fill, `hover` of the way into its hover.
    static func textBackgroundColor(hover: CGFloat) -> NSColor {
        guard hover > 0 else { return hiddenColor }
        return hiddenColor.blended(withFraction: hoverTint * hover, of: hoverTintColor) ?? hiddenColor
    }

    static func pillLabel(isHovered: Bool, scale: CGFloat = 1) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(
            string: "SPOILER",
            attributes: [
                .font: NSFont.systemFont(ofSize: DiscordRichMessageMetrics.px(15) * scale, weight: .semibold),
                .foregroundColor: isHovered
                    ? NSColor.white
                    : NSColor(srgbRed: 0xE4 / 255, green: 0xE4 / 255, blue: 0xE6 / 255, alpha: 1),
                .kern: DiscordRichMessageMetrics.px(0.5) * scale,
                .paragraphStyle: paragraph,
            ]
        )
    }

    /// Hides the glyphs and text decorations of a hidden text spoiler while
    /// keeping its layout. Apply it after every other color adjustment; a
    /// revealed spoiler omits it and keeps its real colors.
    static func concealText(
        in value: NSMutableAttributedString,
        range: NSRange
    ) {
        for key: NSAttributedString.Key in [
            .foregroundColor,
            .underlineColor,
            .strikethroughColor,
        ] {
            value.addAttribute(key, value: NSColor.clear, range: range)
        }
    }

    static func pillFrame(
        in bounds: CGRect,
        measuredLabelWidth: CGFloat,
        scale: CGFloat
    ) -> CGRect {
        let width = min(
            max(1, bounds.width),
            ceil(measuredLabelWidth) + pillHorizontalPadding * 2 * scale
        )
        let height = min(max(1, bounds.height), pillHeight * scale)
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func labelFrame(
        in bounds: CGRect,
        measuredLabelHeight: CGFloat
    ) -> CGRect {
        let height = min(
            max(1, bounds.height),
            ceil(measuredLabelHeight)
        )
        return CGRect(
            x: bounds.minX,
            y: bounds.midY - height / 2,
            width: bounds.width,
            height: height
        )
    }

    static func isActivationKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 36, 49, 76:
            return true
        default:
            return false
        }
    }
}
