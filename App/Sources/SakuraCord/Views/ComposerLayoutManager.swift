import AppKit
import MessageRendering

/// Lays a draft's Markdown out where the timeline draws the message: its
/// syntax takes no room unless the selection is in or beside the span it
/// formats, lines sit on CoreText's baselines, and code blocks, quotes and
/// spoilers are drawn as the timeline draws them, beneath the selection.
nonisolated final class ComposerLayoutManager: MarkdownLayoutManager, NSLayoutManagerDelegate {
    /// The selection whose spans show their syntax.
    private var selection = NSRange(location: 0, length: 0)

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    /// Shows the syntax of the spans `selection` is in or beside and hides
    /// the rest, laying out again only the syntax whose glyphs change.
    func reveal(around selection: NSRange) {
        self.selection = selection
        guard let textStorage else { return }
        var changes = IndexSet()
        textStorage.enumerateAttribute(.discordMarkdownSyntax, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard value != nil else { return }
            for index in range.location ..< NSMaxRange(range)
            where (propertyForGlyph(at: glyphIndexForCharacter(at: index)) == .controlCharacter) != isHidden(index, in: textStorage) {
                changes.insert(index)
            }
        }
        for range in changes.rangeView {
            invalidateGlyphs(forCharacterRange: NSRange(range), changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: NSRange(range), actualCharacterRange: nil)
        }
    }

    /// Syntax hides unless the selection is in or beside its span.
    private func isHidden(_ index: Int, in text: NSAttributedString) -> Bool {
        guard let place = (text.attribute(.discordMarkdownSyntax, at: index, effectiveRange: nil) as? NSValue)?.rangeValue else {
            return false
        }
        let start = index - place.location
        return selection.location > start + place.length || NSMaxRange(selection) < start
    }

    // Hidden syntax becomes a control character that takes no room. Unlike a
    // null glyph, it stays in its own paragraph's line, which keeps that
    // paragraph's spacing. With C++ interoperability, glyph properties
    // import as their raw values.
    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<Int>, characterIndexes: UnsafePointer<Int>,
        font: NSFont, forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let textStorage else { return 0 }
        var hidden: [Int]?
        for index in 0 ..< glyphRange.length where isHidden(characterIndexes[index], in: textStorage) {
            if hidden == nil { hidden = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length)) }
            hidden?[index] = NSLayoutManager.GlyphProperty.controlCharacter.rawValue
        }
        guard let hidden else { return 0 }
        setGlyphs(glyphs, properties: hidden, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        guard let textStorage, isHidden(charIndex, in: textStorage) else { return action }
        return .zeroAdvancement
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let textStorage else { return false }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let paragraph = textStorage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle
        // A hidden code fence keeps just its spacing: none, or a closing
        // fence's room for its block's padding.
        if isHiddenFence(characters, in: textStorage) {
            let height = paragraph?.paragraphSpacingBefore ?? 0
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee = NSRect(origin: lineFragmentRect.pointee.origin, size: NSSize(width: 0, height: height))
            baselineOffset.pointee = 0
            return true
        }
        // CoreText, which draws the timeline, splits a line's extra height
        // above and below its text; TextKit puts it all above.
        let top = lineFragmentUsedRect.pointee.minY - lineFragmentRect.pointee.minY
        baselineOffset.pointee -= max(0, baselineOffset.pointee - top - maximumAscent(characters, in: textStorage)) / 2
        // TextKit leaves out a paragraph's spacing at the top of the text,
        // even below a hidden fence, which the timeline keeps.
        let startsParagraph = characters.location == 0
            || (textStorage.string as NSString).character(at: characters.location - 1) == 0x0A
        let missing = (paragraph?.paragraphSpacingBefore ?? 0) - top
        if startsParagraph, missing > 0 {
            lineFragmentRect.pointee.size.height += missing
            lineFragmentUsedRect.pointee.origin.y += missing
            baselineOffset.pointee += missing
        }
        return true
    }

    private func isHiddenFence(_ characters: NSRange, in text: NSAttributedString) -> Bool {
        text.attribute(.discordMarkdownBlock, at: characters.location, effectiveRange: nil) as? String == "fence"
            && isHidden(characters.location, in: text)
    }

    private func maximumAscent(_ characters: NSRange, in text: NSAttributedString) -> CGFloat {
        var ascent: CGFloat = 0
        text.enumerateAttributes(in: characters) { attributes, _, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                ascent = max(ascent, attachment.bounds.maxY)
            } else if let font = attributes[.font] as? NSFont {
                ascent = max(ascent, font.ascender)
            }
        }
        return ascent
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let blocks = blockRects().map { ($0.rect.offsetBy(dx: origin.x, dy: origin.y), $0.isCode) }
        let spoilers = rects(of: .discordMarkdownSpoiler, forGlyphRange: glyphsToShow)
            .map { $0.offsetBy(dx: origin.x, dy: origin.y) }
        // AppKit draws text on the main thread.
        MainActor.assumeIsolated {
            for (rect, isCode) in blocks {
                if isCode { NativeTimelineRowPainter.drawCodeChrome(in: rect) } else { NativeTimelineRowPainter.drawQuoteBar(in: rect) }
            }
            // A draft's spoilers stay readable, as a revealed one does.
            NativeTimelineSpoilerAppearance.revealedTextColor.setFill()
            for rect in spoilers {
                NSBezierPath(concentricRoundedRect: rect, cornerRadius: NativeTimelineSpoilerAppearance.textCornerRadius).fill()
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
            guard let name = value as? String, name != "fence" else { return }
            var extent: NSRect?
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, used, _, _, _ in
                let line = NSRect(x: rect.minX, y: used.minY, width: rect.width, height: used.height)
                extent = extent?.union(line) ?? line
            }
            guard let extent else { return }
            if name == "code" {
                let inset = NativeTimelineMarkdownChromeMetrics.codeBlockInset(in: textStorage, at: range.location)
                result.append((extent.insetBy(dx: 0, dy: -inset), true))
            } else {
                let width = NativeTimelineMarkdownChromeMetrics.quoteBarWidth(in: textStorage, at: range.location)
                result.append((NSRect(x: extent.minX, y: extent.minY, width: width, height: extent.height), false))
            }
        }
        return result
    }
}
