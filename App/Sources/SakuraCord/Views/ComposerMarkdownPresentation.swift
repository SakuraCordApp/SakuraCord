import AppKit
import MessageRendering

/// Markdown is the document; AppKit attributes are only its presentation.
@MainActor
enum ComposerMarkdownPresentation {
    /// Every run starts from the draft's plain `style`.
    static func apply(to text: NSMutableAttributedString, style: ComposerTextStyle) {
        text.setAttributedString(rendered(text, style: style))
    }

    static func rendered(_ original: NSAttributedString, style: ComposerTextStyle) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: original.length)
        let text = DiscordMarkdown.appKitSourceAttributed(
            original.string, attributes: style.attributes,
            baseFontSize: style.font.pointSize, usesMessageLineHeight: style.usesMessageLineHeight
        )
        // Only app-owned token attachments survive incoming rich-text formatting.
        // They are single characters here, so the source keeps their ranges
        // even while a newly typed token is awaiting normalization.
        original.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            original.enumerateAttributes(in: range) { attributes, tokenRange, _ in
                for key in [NSAttributedString.Key.discordEmojiToken, .discordMentionToken] {
                    if let token = attributes[key] as? String {
                        text.addAttributes([key: token, .attachment: attachment], range: tokenRange)
                    }
                }
            }
        }
        return text
    }
}

/// Draws a draft's code blocks, quotes and spoilers as the timeline draws
/// them, beneath the selection.
nonisolated final class ComposerLayoutManager: MarkdownLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let blocks = blockRects().map { ($0.rect.offsetBy(dx: origin.x, dy: origin.y), $0.isCode) }
        let spoilers = rects(of: .discordMarkdownSpoiler, forGlyphRange: glyphsToShow) { _ in 0 }
            .map { $0.offsetBy(dx: origin.x, dy: origin.y) }
        // AppKit draws text on the main thread.
        MainActor.assumeIsolated {
            for (rect, isCode) in blocks {
                if isCode { NativeTimelineRowPainter.drawCodeChrome(in: rect) } else { NativeTimelineRowPainter.drawQuoteBar(in: rect) }
            }
            // A draft's spoilers stay readable, as a revealed one does.
            NativeTimelineSpoilerAppearance.revealedTextColor.setFill()
            let radius = NativeTimelineSpoilerAppearance.textCornerRadius
            for rect in spoilers {
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Each code block's padded background and each quote's bar, as wide
    /// as their lines and as tall as their text, without its paragraph spacing.
    private func blockRects() -> [(rect: NSRect, isCode: Bool)] {
        guard let textStorage else { return [] }
        var result: [(NSRect, Bool)] = []
        textStorage.enumerateAttribute(.discordMarkdownBlock, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let name = value as? String else { return }
            var extent: NSRect?
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, used, _, _, _ in
                let line = NSRect(x: rect.minX, y: used.minY, width: rect.width, height: used.height)
                extent = extent?.union(line) ?? line
            }
            guard let extent else { return }
            let em = NativeTimelineMarkdownChromeMetrics.em(in: textStorage, at: range.location)
            if name == "code" {
                var box = extent.insetBy(dx: 0, dy: -NativeTimelineMarkdownChromeMetrics.codeBlockInset(in: textStorage, at: range.location))
                // A block still awaiting its closing fence ends the draft,
                // whose view is only as tall as its text.
                if let container = textContainers.first {
                    box.size.height = min(box.height, usedRect(for: container).maxY - box.minY)
                }
                result.append((box, true))
            } else {
                // Discord's bar is 4 px wide.
                result.append((NSRect(x: extent.minX, y: extent.minY, width: 4 * em, height: extent.height), false))
            }
        }
        return result
    }
}

extension ComposerNSTextView {
    func refreshMarkdownPresentation() {
        guard !hasMarkedText(), let textStorage else { return }
        let rendered = ComposerMarkdownPresentation.rendered(textStorage, style: plainTextStyle)
        // Only changed runs should invalidate layout. Most keystrokes leave all
        // existing attributes intact, even though delimiter recognition is global.
        guard !rendered.isEqual(to: textStorage) else {
            restorePlainTypingAttributes()
            return
        }
        var updates: [(NSRange, [NSAttributedString.Key: Any])] = []
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, range, _ in
            textStorage.enumerateAttributes(in: range) { current, subrange, _ in
                if !(current as NSDictionary).isEqual(to: attributes) {
                    updates.append((subrange, attributes))
                }
            }
        }
        if !updates.isEmpty {
            textStorage.beginEditing()
            for (range, attributes) in updates { textStorage.setAttributes(attributes, range: range) }
            textStorage.endEditing()
        }
        restorePlainTypingAttributes()
    }

    override func didChangeText() {
        refreshMarkdownPresentation()
        super.didChangeText()
    }

    override func unmarkText() {
        super.unmarkText()
        refreshMarkdownPresentation()
    }
}
