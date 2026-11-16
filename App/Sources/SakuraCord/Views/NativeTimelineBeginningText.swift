import AppKit

enum NativeTimelineBeginningText {
    static func title(
        _ beginning: NativeTimelineBeginning
    ) -> NativeTimelineAttributedTextBox {
        .plain(
            beginning.title,
            font: .interfaceSystemFont(
                ofSize: NSFont.preferredFont(
                    forTextStyle: .largeTitle
                ).pointSize,
                weight: .bold
            ),
            color: .labelColor
        )
    }

    static func description(
        _ beginning: NativeTimelineBeginning,
        source: AppModel? = nil,
        relativeTo date: Date = .now
    ) -> NativeTimelineAttributedTextBox {
        let font = NSFont.interfacePreferredFont(forTextStyle: .body)
        // Only a channel's own topic is Markdown; generated descriptions embed
        // names that must render literally.
        guard let topic = beginning.topic else {
            return .plain(beginning.description, font: font, color: .secondaryLabelColor)
        }
        let baseFontSize = font.pointSize
        let prepared = RichMessageAttributedText.prepare(source: topic)
        let mentions = TimestampMentionPresentation.refreshed(
            MessageMentionResolver.presentations(for: prepared, model: source, message: nil),
            source: topic,
            at: date
        )
        let emojiSize = InterfaceScale.metric(22)
        let attributed = NSMutableAttributedString(
            attributedString: NativeTimelineCoreText.make(
                prepared: prepared,
                emojiSize: emojiSize,
                baseFontSize: baseFontSize,
                mentionPresentations: mentions
            )
        )
        attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let color = value as? NSColor, color == NSColor.labelColor {
                attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            }
        }
        return NativeTimelineAttributedTextBox(attributed)
    }
}

final class NativeTimelineBeginningSelectionOverlay: NSImageView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}
