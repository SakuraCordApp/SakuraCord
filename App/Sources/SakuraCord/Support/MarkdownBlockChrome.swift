import AppKit
import CoreText

/// Discord's code, quote and list-marker chrome, which the timeline, the
/// composer and Markdown documents draw alike.
enum MarkdownBlockChrome {
    /// Discord's code chrome, which inline code and code blocks share. A
    /// rect too small to outline, such as a wrapped zero-width joiner's, has
    /// no border path to draw.
    static func drawCode(in rect: CGRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        let radius = NativeTimelineMarkdownChromeMetrics.codeBlockCornerRadius
        codeBackgroundColor.setFill()
        NSBezierPath(concentricRoundedRect: rect, cornerRadius: radius).fill()
        codeBorderColor.setStroke()
        let border = NSBezierPath(concentricRoundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius)
        border.lineWidth = 1
        border.stroke()
    }

    /// Discord's fully rounded quote bar.
    static func drawQuoteBar(in bar: CGRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
    }

    /// Discord centers its 5.5 px list disc 12 px before the item text,
    /// which starts one 16 px gutter after the marker's `frame`.
    nonisolated static func listMarkerDisc(for frame: CGRect, em: CGFloat) -> CGRect {
        let diameter = 5.5 * em
        return CGRect(x: frame.minX + 4 * em - diameter / 2, y: frame.midY - diameter / 2, width: diameter, height: diameter)
    }

    /// Discord's list marker: a disc, or a 1 px ring once nested.
    nonisolated static func drawListMarker(in disc: CGRect, color: NSColor, isHollow: Bool) {
        color.set()
        if isHollow {
            let ring = NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        } else {
            NSBezierPath(ovalIn: disc).fill()
        }
    }

    /// Discord tints code with its blurple and outlines it in a translucent
    /// gray, so both read on any background and in either appearance.
    static let codeBackgroundColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 89 / 255, green: 102 / 255, blue: 242 / 255, alpha: 0.08)
            : NSColor(srgbRed: 77 / 255, green: 102 / 255, blue: 230 / 255, alpha: 0.04)
    }

    static let codeBorderColor = NSColor(name: nil) { appearance in
        NSColor(
            srgbRed: 150 / 255,
            green: 150 / 255,
            blue: 160 / 255,
            alpha: appearance.isDark ? 0.2 : 0.4
        )
    }
}

nonisolated enum NativeTimelineMarkdownChromeMetrics {
    /// Discord's 8 px code block padding, at the block's text size.
    static func codeBlockInset(in value: NSAttributedString, at location: Int) -> CGFloat {
        8 * em(in: value, at: location)
    }

    static var codeBlockCornerRadius: CGFloat { InterfaceScale.metric(4) }

    /// Discord's 4 px quote bar, at the quote's text size.
    static func quoteBarWidth(in value: NSAttributedString, at location: Int) -> CGFloat {
        4 * em(in: value, at: location)
    }

    /// The copy button's inset from its block's top and trailing edges:
    /// Discord's 4 px from the trailing edge.
    static var codeCopyButtonInset: CGFloat { InterfaceScale.metric(4) }
    /// A radius concentric with the block's would be square at this inset.
    static var codeCopyButtonCornerRadius: CGFloat { InterfaceScale.metric(2) }

    /// The width `value` needs within `maximumWidth`. CoreText's suggestion
    /// counts a code line's head indent but not its tail indent, which only
    /// narrows lines within a set width, so a block fitted to its text would
    /// end at its last glyph, under its copy button.
    static func fittedWidth(
        _ framesetter: CTFramesetter,
        value: NSAttributedString,
        maximumWidth: CGFloat
    ) -> CGFloat {
        let range = CFRange(location: 0, length: value.length)
        var width = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            range,
            nil,
            CGSize(width: max(1, maximumWidth), height: .greatestFiniteMagnitude),
            nil
        ).width
        guard NativeTimelineCodeBlockGeometry.containsCodeBlock(value) else { return width }
        let frame = coreTextFrame(
            value: value,
            framesetter: framesetter,
            size: CGSize(width: max(1, maximumWidth), height: 1_000_000)
        )
        for line in CTFrameGetLines(frame) as? [CTLine] ?? [] {
            let location = CTLineGetStringRange(line).location
            guard value.attribute(.discordMarkdownBlock, at: location, effectiveRange: nil) as? String == "code",
                  let paragraph = value.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            else { continue }
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            width = max(width, paragraph.headIndent + textWidth - paragraph.tailIndent)
        }
        return width
    }

    /// One of Discord's CSS pixels at the size of the markdown block or
    /// list marker at `location`.
    static func em(in value: NSAttributedString, at location: Int) -> CGFloat {
        CGFloat((value.attribute(.discordMarkdownEm, at: location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 1)
    }
    // The painter gives CoreText one point of extra layout headroom and its
    // selection-derived block rect has fractional vertical bounds. Preserve
    // the established three-point message-highlight inset after that painted
    // geometry instead of merely making the block fit the row.
    static var codeBlockTerminalPaintAndHighlightInset: CGFloat { InterfaceScale.metric(5.5) }

    /// CoreText ignores the first paragraph's spacing before, so layout
    /// moves the text frame down by it instead. This keeps Discord's top
    /// margin and a leading code block's padding clear of the content above.
    static func leadingVisualInset(in value: NSAttributedString) -> CGFloat {
        guard value.length > 0 else { return 0 }
        return (value.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
            .paragraphSpacingBefore ?? 0
    }

    static func trailingVisualOverflow(
        in value: NSAttributedString
    ) -> CGFloat {
        guard value.length > 0 else { return 0 }
        let source = value.string as NSString
        var index = value.length - 1
        while index >= 0 {
            let scalar = source.character(at: index)
            if let unicodeScalar = UnicodeScalar(scalar),
               CharacterSet.whitespacesAndNewlines
                .contains(unicodeScalar)
            {
                index -= 1
                continue
            }
            break
        }
        guard index >= 0,
              value.attribute(
                  .discordMarkdownBlock,
                  at: index,
                  effectiveRange: nil
              ) as? String == "code"
        else { return 0 }
        return codeBlockInset(in: value, at: index) + codeBlockTerminalPaintAndHighlightInset
    }
}
