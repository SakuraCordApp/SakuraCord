import AppKit
import SwiftUI

struct ProfileRichTextView: View {
    let source: String
    var editing: ProfileBioTextEditing?
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
        textView.applySakuraCordTextSelectionAppearance()
        return textView
    }

    func updateNSView(_ textView: ProfileStatusNSTextView, context: Context) {
        let selection = textView.selectedRange()
        textView.onHoverChange = onHoverChange
        textView.applySakuraCordTextSelectionAppearance()
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
            emojiImages: emojiImages,
            stylesLinks: false
        )
    }
}

private struct ProfileTextRepresentable: NSViewRepresentable {
    let source: String
    let emojiImages: [String: NSImage]
    let editing: ProfileBioTextEditing?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> HoverLinkTextView {
        let textView = HoverLinkTextView()
        textView.delegate = context.coordinator
        textView.isEditable = editing != nil
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
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: 0
        ]
        textView.applySakuraCordTextSelectionAppearance()
        return textView
    }

    func updateNSView(_ textView: HoverLinkTextView, context: Context) {
        context.coordinator.parent = self
        editing?.interaction.textView = textView
        textView.onBeginEditing = editing?.onBegin
        textView.onEndEditing = editing?.onEnd
        textView.onCancelEditing = editing?.onCancel
        textView.isEditable = editing != nil
        textView.setAccessibilityLabel(editing == nil ? nil : String(localized: "Edit Bio", bundle: #bundle))
        let selection = textView.selectedRange()
        textView.applySakuraCordTextSelectionAppearance()
        // Preserve the live text storage and native caret during keystrokes.
        if editing == nil || ComposerEmojiAttributedText.serialize(textView.attributedString()) != source
            || context.coordinator.images != emojiImages || context.coordinator.wasActive != editing?.isActive {
            textView.textStorage?.setAttributedString(attributedText())
            textView.setSelectedRange(selection.clamped(toLength: textView.string.utf16.count))
        }
        context.coordinator.images = emojiImages
        context.coordinator.wasActive = editing?.isActive
        textView.typingAttributes = ComposerEmojiAttributedText.textAttributes(.interfaceSystemFont(ofSize: 14))
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: HoverLinkTextView,
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
            emojiImages: emojiImages,
            stylesLinks: true
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProfileTextRepresentable
        var images: [String: NSImage] = [:]
        var wasActive: Bool?

        init(parent: ProfileTextRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.editing?.onChange(ComposerEmojiAttributedText.serialize(textView.attributedString()))
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard parent.editing != nil, let textView = notification.object as? NSTextView else { return }
            textView.typingAttributes = ComposerEmojiAttributedText.textAttributes(.interfaceSystemFont(ofSize: 14))
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if parent.editing != nil { return true }
            guard let url = link as? URL else { return false }
            var linkRange = NSRange(location: 0, length: 0)
            textView.attributedString().attribute(
                .link,
                at: charIndex,
                effectiveRange: &linkRange
            )
            let displayedText = linkRange.length > 0
                ? textView.attributedString().attributedSubstring(
                    from: linkRange
                ).string
                : nil
            return MessageLinkActivator.activate(
                url,
                model: nil,
                displayedText: displayedText
            )
        }
    }
}

enum ProfileInlineAttributedText {
    private static let emojiExpression = RegularExpressionFactory.make(
        #"<(a?):([A-Za-z0-9_~]+):([0-9]+)>"#
    )
    private static let linkExpression = RegularExpressionFactory.make(
        #"https?://[^\s<>]+"#,
        options: .caseInsensitive
    )

    static func make(
        source: String,
        font: NSFont,
        color: NSColor,
        emojiImages: [String: NSImage],
        stylesLinks: Bool
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
        if stylesLinks {
            styleLinks(in: output)
        }
        return output
    }

    private static func styledText(
        _ text: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        var attributes = ComposerEmojiAttributedText.textAttributes(font)
        attributes[.foregroundColor] = color
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func styleLinks(in value: NSMutableAttributedString) {
        let fullString = value.string as NSString
        let matches = linkExpression.matches(
            in: value.string,
            range: NSRange(location: 0, length: fullString.length)
        )
        let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}")
        for match in matches {
            var range = match.range
            while range.length > 0 {
                let last = fullString.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))
                guard last.rangeOfCharacter(from: trailingPunctuation) != nil else { break }
                range.length -= 1
            }
            guard range.length > 0,
                  let url = URL(string: fullString.substring(with: range)) else { continue }
            value.addAttributes([.link: url, .foregroundColor: NSColor.systemBlue], range: range)
        }
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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

private final class HoverLinkTextView: ProfileSelectableTextView {
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onCancelEditing: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBeginEditing?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onEndEditing?() }
        return accepted
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancelEditing { onCancelEditing() } else { super.cancelOperation(sender) }
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func insertTab(_ sender: Any?) {
        if onBeginEditing != nil { window?.selectNextKeyView(sender) } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if onBeginEditing != nil { window?.selectPreviousKeyView(sender) } else { super.insertBacktab(sender) }
    }
    private var tracking: NSTrackingArea?
    private var underlinedRange: NSRange?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        super.mouseMoved(with: event)
        guard let layoutManager, let textContainer, let textStorage else { return }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length else {
            updateUnderline(nil)
            return
        }
        var linkRange = NSRange(location: 0, length: 0)
        if textStorage.attribute(.link, at: characterIndex, effectiveRange: &linkRange) != nil {
            updateUnderline(linkRange)
            NSCursor.pointingHand.set()
        } else {
            updateUnderline(nil)
            NSCursor.iBeam.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateUnderline(nil)
    }

    private func updateUnderline(_ range: NSRange?) {
        guard range != underlinedRange else { return }
        if let underlinedRange {
            layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: underlinedRange)
        }
        underlinedRange = range
        if let range {
            layoutManager?.addTemporaryAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                forCharacterRange: range
            )
        }
    }
}

private extension NSRange {
    func clamped(toLength length: Int) -> NSRange {
        let location = min(max(0, location), length)
        let maximumLength = max(0, length - location)
        return NSRange(location: location, length: min(max(0, self.length), maximumLength))
    }
}
