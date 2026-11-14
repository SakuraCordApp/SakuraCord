import AppKit

/// Discord's code and quote chrome, which the timeline, the composer and
/// Markdown documents draw alike.
enum MarkdownBlockChrome {
    /// Discord's code chrome, which inline code and code blocks share.
    static func drawCode(in rect: CGRect) {
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
