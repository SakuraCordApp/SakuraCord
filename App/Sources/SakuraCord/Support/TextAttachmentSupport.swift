import AppKit

extension NSTextView {
    func attachmentSelectionRects() -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        let origin = textContainerOrigin
        var result: [NSRect] = []
        for selectedValue in selectedRanges {
            let selectedRange = selectedValue.rangeValue
            guard selectedRange.length > 0 else { continue }
            attributedString().enumerateAttribute(.attachment, in: selectedRange) {
                value, range, _ in
                guard value is NSTextAttachment else { return }
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: range,
                    actualCharacterRange: nil
                )
                var rect = layoutManager.boundingRect(
                    forGlyphRange: glyphRange,
                    in: textContainer
                )
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                result.append(rect)
            }
        }
        return result
    }

    func drawSelectionOverAttachments(in dirtyRect: NSRect) {
        let emphasized = window?.isKeyWindow == true && window?.firstResponder === self
        let color = emphasized
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
        color.withAlphaComponent(emphasized ? 0.5 : 0.38).setFill()
        for rect in attachmentSelectionRects() where rect.intersects(dirtyRect) {
            NSBezierPath(rect: rect).fill()
        }
    }
}

@MainActor
final class InlineAttachmentImageLoader {
    private var emojiTasks: [String: Task<Void, Never>] = [:]
    private var mentionAvatarTasks: [String: Task<Void, Never>] = [:]

    isolated deinit {
        cancel()
    }

    func loadEmojiImages(
        in textView: NSTextView,
        addsAccessibilityDescriptions: Bool = false
    ) {
        let attributed = textView.attributedString()
        var tokens = Set<String>()
        attributed.enumerateAttribute(
            .discordEmojiToken,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let token = value as? String {
                tokens.insert(token)
            }
        }

        for token in tokens where emojiTasks[token] == nil {
            if let image = ComposerEmojiImageStore.shared.cachedImage(for: token) {
                apply(
                    image,
                    for: token,
                    in: textView,
                    addsAccessibilityDescription: addsAccessibilityDescriptions
                )
                continue
            }
            emojiTasks[token] = Task { @MainActor [weak self, weak textView] in
                let image = await ComposerEmojiImageStore.shared.image(for: token)
                guard let self else { return }
                defer { self.emojiTasks[token] = nil }
                guard !Task.isCancelled, let textView, let image else { return }
                self.apply(
                    image,
                    for: token,
                    in: textView,
                    addsAccessibilityDescription: addsAccessibilityDescriptions
                )
            }
        }

        for token in Array(emojiTasks.keys) where !tokens.contains(token) {
            emojiTasks[token]?.cancel()
            emojiTasks[token] = nil
        }
    }

    func loadMentionAvatars(in textView: NSTextView) {
        let attributed = textView.attributedString()
        var values: [String: URL] = [:]
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let attachment = value as? MentionTextAttachment,
                  let url = attachment.presentation.avatarURL
            else { return }
            values[attachment.presentation.rawToken] = url
        }

        for (token, url) in values where mentionAvatarTasks[token] == nil {
            mentionAvatarTasks[token] = Task { @MainActor [weak self, weak textView] in
                let image = await MentionAvatarImageStore.shared.image(for: url)
                guard let self else { return }
                defer { self.mentionAvatarTasks[token] = nil }
                guard !Task.isCancelled, let textView, let image else { return }
                self.applyMentionAvatar(image, token: token, in: textView)
            }
        }
    }

    func cancel() {
        for task in emojiTasks.values {
            task.cancel()
        }
        emojiTasks.removeAll()
        for task in mentionAvatarTasks.values {
            task.cancel()
        }
        mentionAvatarTasks.removeAll()
    }

    private func apply(
        _ image: NSImage,
        for token: String,
        in textView: NSTextView,
        addsAccessibilityDescription: Bool
    ) {
        guard let storage = textView.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        storage.enumerateAttributes(in: range) { attributes, _, _ in
            guard attributes[.discordEmojiToken] as? String == token,
                  let attachment = attributes[.attachment] as? NSTextAttachment
            else { return }
            attachment.image = image
            if addsAccessibilityDescription {
                attachment.image?.accessibilityDescription = token
            }
        }
        textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
        textView.needsDisplay = true
    }

    private func applyMentionAvatar(_ image: NSImage, token: String, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
            guard let attachment = value as? MentionTextAttachment,
                  attachment.presentation.rawToken == token
            else { return }
            attachment.updateImages(avatar: image)
        }
        textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
        textView.needsDisplay = true
    }
}
