import AppKit
import SwiftUI

/// A saved bio, rendered with Discord's bio rules. Its channel mentions and
/// links resolve through the profile presentation's model.
struct ProfileBioText: View {
    let source: String
    @Environment(\.serverTagCardModel) private var model

    var body: some View {
        CustomEmojiRichText(
            model: model,
            content: source,
            markdownRules: .profileBio,
            emojiSize: InterfaceScale.metric(18),
            baseFontSize: InterfaceScale.fontSize(14),
            mentionPresentation: { mention in
                model.map { MessageMentionResolver(model: $0).presentation(mention) }
                    ?? MentionPresentation.fallback(for: mention)
            }
        )
    }
}

/// The bio editor, which shows the bio's source with its emoji, as Discord's
/// bio field does.
struct ProfileBioEditorText: View {
    let source: String
    let editing: ProfileBioTextEditing
    @State private var emojiImages: [String: NSImage] = [:]

    var body: some View {
        ProfileTextRepresentable(source: source, emojiImages: emojiImages, editing: editing)
            .task(id: source) {
                emojiImages = [:]
                for emoji in Set(EmojiDescriptor.all(in: source)) {
                    guard !Task.isCancelled,
                          let image = await ComposerEmojiImageStore.shared.image(for: emoji.rawToken)
                    else { continue }
                    emojiImages[emoji.rawToken] = image
                }
            }
    }
}

struct ProfileStatusTextView: View {
    let source: String
    let isExpanded: Bool
    var fontSize: CGFloat = 14
    var usesSecondaryColor = false
    var onHoverChange: (Bool) -> Void = { _ in }
    @State private var emojiImages: [String: NSImage] = [:]

    var body: some View {
        ProfileStatusTextRepresentable(
            source: source,
            emojiImages: emojiImages,
            isExpanded: isExpanded,
            fontSize: fontSize,
            usesSecondaryColor: usesSecondaryColor,
            onHoverChange: onHoverChange
        )
        .task(id: source) {
            emojiImages = [:]
            for emoji in Set(EmojiDescriptor.all(in: source)) {
                guard !Task.isCancelled,
                      let image = await ComposerEmojiImageStore.shared.image(for: emoji.rawToken)
                else { continue }
                emojiImages[emoji.rawToken] = image
            }
        }
    }
}

private struct EmojiDescriptor: Hashable {
    private static let expression = RegularExpressionFactory.make(
        #"<(a?):([A-Za-z0-9_~]+):([0-9]+)>"#
    )

    let rawToken: String

    static func all(in source: String) -> [EmojiDescriptor] {
        let sourceString = source as NSString
        let range = NSRange(location: 0, length: sourceString.length)
        return expression.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges == 4 else { return nil }
            return EmojiDescriptor(
                rawToken: sourceString.substring(with: match.range)
            )
        }
    }
}

private struct ProfileStatusTextRepresentable: NSViewRepresentable {
    let source: String
    let emojiImages: [String: NSImage]
    let isExpanded: Bool
    let fontSize: CGFloat
    let usesSecondaryColor: Bool
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProfileStatusNSTextView {
        let textView = ProfileStatusNSTextView()
        textView.onHoverChange = onHoverChange
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        return textView
    }

    func updateNSView(_ textView: ProfileStatusNSTextView, context: Context) {
        let selection = textView.selectedRange()
        textView.onHoverChange = onHoverChange
        textView.textContainer?.maximumNumberOfLines = isExpanded ? 0 : 1
        textView.textContainer?.lineBreakMode = isExpanded ? .byWordWrapping : .byTruncatingTail
        textView.textStorage?.setAttributedString(attributedText())
        textView.setSelectedRange(selection.clamped(toLength: textView.string.utf16.count))
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: ProfileStatusNSTextView,
        context: Context
    ) -> CGSize? {
        // SwiftUI probes with an infinite width. A text view given that frame
        // scrolls its enclosing scroll view during the update.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? InterfaceScale.metric(isExpanded ? 188 : 143)
        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
            return CGSize(width: width, height: InterfaceScale.fontSize(fontSize) + InterfaceScale.metric(3))
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        return CGSize(width: width, height: max(InterfaceScale.fontSize(fontSize) + InterfaceScale.metric(3), usedHeight))
    }

    private func attributedText() -> NSAttributedString {
        ProfileInlineAttributedText.make(
            source: source,
            font: NSFont.interfaceSystemFont(ofSize: fontSize),
            color: usesSecondaryColor ? .secondaryLabelColor : .labelColor,
            emojiImages: emojiImages
        )
    }
}

private struct ProfileTextRepresentable: NSViewRepresentable {
    let source: String
    let emojiImages: [String: NSImage]
    let editing: ProfileBioTextEditing

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ProfileBioNSTextView {
        let textView = ProfileBioNSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        return textView
    }

    func updateNSView(_ textView: ProfileBioNSTextView, context: Context) {
        context.coordinator.parent = self
        editing.interaction.textView = textView
        textView.onBeginEditing = editing.onBegin
        textView.onEndEditing = editing.onEnd
        textView.onCancelEditing = editing.onCancel
        textView.setAccessibilityLabel(String(localized: "Edit Bio", bundle: #bundle))
        let selection = textView.selectedRange()
        // Preserve the live text storage and native caret during keystrokes.
        if ComposerEmojiAttributedText.serialize(textView.attributedString()) != source
            || context.coordinator.images != emojiImages || context.coordinator.wasActive != editing.isActive {
            textView.textStorage?.setAttributedString(attributedText())
            textView.setSelectedRange(selection.clamped(toLength: textView.string.utf16.count))
        }
        context.coordinator.images = emojiImages
        context.coordinator.wasActive = editing.isActive
        textView.typingAttributes = ComposerTextStyle.composer(.interfaceSystemFont(ofSize: 14)).attributes
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: ProfileBioNSTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 298
        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
            return CGSize(width: width, height: InterfaceScale.metric(20))
        }
        layoutManager.ensureLayout(for: textContainer)
        return CGSize(width: width, height: max(InterfaceScale.metric(18), ceil(layoutManager.usedRect(for: textContainer).height)))
    }

    private func attributedText() -> NSAttributedString {
        ProfileInlineAttributedText.make(
            source: source,
            font: NSFont.interfaceSystemFont(ofSize: 14),
            color: .labelColor,
            emojiImages: emojiImages
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProfileTextRepresentable
        var images: [String: NSImage] = [:]
        var wasActive: Bool?

        init(parent: ProfileTextRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.editing.onChange(ComposerEmojiAttributedText.serialize(textView.attributedString()))
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textView.typingAttributes = ComposerTextStyle.composer(.interfaceSystemFont(ofSize: 14)).attributes
        }
    }
}

enum ProfileInlineAttributedText {
    private static let emojiExpression = RegularExpressionFactory.make(
        #"<(a?):([A-Za-z0-9_~]+):([0-9]+)>"#
    )

    static func make(
        source: String,
        font: NSFont,
        color: NSColor,
        emojiImages: [String: NSImage]
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let sourceString = source as NSString
        let matches = emojiExpression.matches(
            in: source,
            range: NSRange(location: 0, length: sourceString.length)
        )
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                output.append(styledText(
                    sourceString.substring(with: NSRange(
                        location: cursor,
                        length: match.range.location - cursor
                    )),
                    font: font,
                    color: color
                ))
            }
            let token = sourceString.substring(with: match.range)
            let size = font.pointSize * 1.15
            let image = emojiImages[token] ?? ComposerEmojiImageStore.shared.cachedImage(for: token)
                ?? ComposerEmojiAttributedText.placeholderImage(name: sourceString.substring(with: match.range(at: 2)), size: size)
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0,
                y: ComposerEmojiAttributedText.attachmentOriginY(font: font, size: size),
                width: size,
                height: size
            )
            let value = NSMutableAttributedString(attachment: attachment)
            value.addAttributes(
                [
                    .discordEmojiToken: token,
                    .font: font,
                    .foregroundColor: color
                ],
                range: NSRange(location: 0, length: value.length)
            )
            output.append(value)
            cursor = NSMaxRange(match.range)
        }
        if cursor < sourceString.length {
            output.append(styledText(sourceString.substring(from: cursor), font: font, color: color))
        }
        return output
    }

    private static func styledText(
        _ text: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        var attributes = ComposerTextStyle.composer(font).attributes
        attributes[.foregroundColor] = color
        return NSAttributedString(string: text, attributes: attributes)
    }
}

class ProfileSelectableTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawSelectionOverAttachments(in: dirtyRect)
    }

    override func resetCursorRects() {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let value = ComposerEmojiAttributedText.serialize(attributedString(), range: range)
        Pasteboard.copy(value)
    }

}

private final class ProfileStatusNSTextView: ProfileSelectableTextView, WindowModalInputParticipant {
    func modalInputDidChange() {
        if !WindowModalCoordinator.allowsInput(for: self) { onHoverChange(false) }
        updateTrackingAreas()
    }

    var onHoverChange: (Bool) -> Void = { _ in }
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInKeyWindow,
                .mouseEnteredAndExited,
                .inVisibleRect,
                .enabledDuringMouseDrag
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        super.mouseEntered(with: event)
        onHoverChange(WindowModalCoordinator.allowsInput(for: self))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange(false)
    }
}

private final class ProfileBioNSTextView: ProfileSelectableTextView {
    var onBeginEditing: () -> Void = {}
    var onEndEditing: () -> Void = {}
    var onCancelEditing: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBeginEditing() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onEndEditing() }
        return accepted
    }

    override func cancelOperation(_ sender: Any?) { onCancelEditing() }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }

    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
}

private extension NSRange {
    func clamped(toLength length: Int) -> NSRange {
        let location = min(max(0, location), length)
        let maximumLength = max(0, length - location)
        return NSRange(location: location, length: min(max(0, self.length), maximumLength))
    }
}
