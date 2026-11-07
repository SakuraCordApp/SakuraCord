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

extension ComposerNSTextView {
    func refreshMarkdownPresentation() {
        guard !hasMarkedText(), let textStorage else { return }
        let rendered = ComposerMarkdownPresentation.rendered(textStorage, style: plainTextStyle)
        // Only changed runs should invalidate layout. Most keystrokes leave all
        // existing attributes intact, even though delimiter recognition is global.
        defer {
            restorePlainTypingAttributes()
            revealMarkdownSyntax()
        }
        guard !rendered.isEqual(to: textStorage) else { return }
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
    }

    /// Shows the Markdown syntax around the selection, once the text it
    /// marks is settled.
    func revealMarkdownSyntax() {
        guard !hasMarkedText(), let textStorage, textStorage.editedMask.isEmpty else { return }
        (layoutManager as? ComposerLayoutManager)?.reveal(around: selectedRange())
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        revealMarkdownSyntax()
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
