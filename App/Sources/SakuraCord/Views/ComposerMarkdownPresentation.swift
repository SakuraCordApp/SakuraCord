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
        let font = style.font
        let text = NSMutableAttributedString(string: original.string, attributes: style.attributes)
        // Start with one plain run rather than resetting every previous style run.
        // Only app-owned token attachments survive incoming rich-text formatting.
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
        // Token attachments are single characters here, so these ranges remain
        // correct even while a newly typed token is awaiting normalization.
        var fonts: [UInt: NSFont] = [0: font]
        for format in DiscordMarkdown.sourceFormats(text.string) {
            let range = format.range
            var traits: NSFontTraitMask = []
            if format.isBold { traits.insert(.boldFontMask) }
            if format.isItalic { traits.insert(.italicFontMask) }
            let styledFont = fonts[traits.rawValue] ?? NSFontManager.shared.convert(font, toHaveTrait: traits)
            fonts[traits.rawValue] = styledFont
            text.addAttribute(.font, value: styledFont, range: range)
            if format.isUnderlined {
                text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return text
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
