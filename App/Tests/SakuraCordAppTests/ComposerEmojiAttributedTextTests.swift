import AppKit
@testable import SakuraCord
import Testing

@MainActor @Test func `composer emoji attachments serialize exact raw tokens`() {
    let source = "before <a:party_blob:123456> after <:still:987>"
    let attributed = ComposerEmojiAttributedText.make(source)
    #expect(attributed.string.contains("\u{FFFC}"))
    #expect(ComposerEmojiAttributedText.serialize(attributed) == source)
}

@MainActor @Test func `composer emoji selection maps between raw and displayed coordinates`() {
    let source = "A <:wave:123> B"
    let raw = NSRange(location: ("A <:wave:123>" as NSString).length, length: 0)
    let displayed = ComposerEmojiAttributedText.displayRange(forRaw: raw, source: source)
    let restored = ComposerEmojiAttributedText.rawRange(
        forDisplay: displayed, attributed: ComposerEmojiAttributedText.make(source)
    )
    #expect(restored == raw)
}

@MainActor @Test func `composer custom emoji attachment uses the resolved CDN image`() throws {
    let resolved = NSImage(size: NSSize(width: 32, height: 32))
    let attributed = ComposerEmojiAttributedText.make("<:wave:123>") { token in
        token == "<:wave:123>" ? resolved : nil
    }
    let attachment = try #require(
        attributed.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
    )
    #expect(attachment.image === resolved)
    #expect(ComposerEmojiAttributedText.serialize(attributed) == "<:wave:123>")
}

@MainActor @Test func `composer exposes an overlay rect for a selected custom emoji`() throws {
    let textView = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.containerSize = NSSize(width: 240, height: 40)
    textView.textStorage?.setAttributedString(
        ComposerEmojiAttributedText.make("a<:wave:123>b") { _ in
            NSImage(size: NSSize(width: 18, height: 18))
        }
    )
    textView.setSelectedRange(NSRange(location: 1, length: 1))
    textView.layoutManager?.ensureLayout(for: try #require(textView.textContainer))

    let rect = try #require(textView.attachmentSelectionRects().first)
    #expect(rect.width > 0)
    #expect(rect.height > 0)
}

@MainActor @Test func `typing after custom emoji does not inherit its attachment`() throws {
    let token = "<:wave:123>"
    let attributedEmoji = ComposerEmojiAttributedText.make(token)
    let leakedAttributes = attributedEmoji.attributes(at: 0, effectiveRange: nil)
    let contaminated = NSMutableAttributedString(attributedString: attributedEmoji)
    contaminated.append(NSAttributedString(string: "x", attributes: leakedAttributes))

    #expect(contaminated.string == "\u{FFFC}x")
    #expect(ComposerEmojiAttributedText.serialize(contaminated) == token + "x")

    let textView = ComposerNSTextView()
    textView.plainTypingAttributes = [
        .font: NSFont.systemFont(ofSize: 15),
        .foregroundColor: NSColor.labelColor
    ]
    textView.textStorage?.setAttributedString(attributedEmoji)
    textView.setSelectedRange(NSRange(location: attributedEmoji.length, length: 0))
    textView.typingAttributes = leakedAttributes
    textView.insertText("x", replacementRange: textView.selectedRange())

    #expect(ComposerEmojiAttributedText.serialize(textView.attributedString()) == token + "x")
    #expect(textView.attribute(.discordEmojiToken, at: 1) == nil)
}

@MainActor @Test func `custom emoji attachment is centered on the font metrics`() {
    let font = NSFont.systemFont(ofSize: 15)
    let size = font.pointSize * 1.15
    let origin = ComposerEmojiAttributedText.attachmentOriginY(font: font, size: size)

    #expect(origin + size / 2 == (font.ascender + font.descender) / 2)
}

@MainActor @Test func `inline emoji image preparation preserves a rectangular aspect ratio`() {
    let source = NSImage(size: NSSize(width: 40, height: 20))
    let prepared = ComposerEmojiImageStore.preparedForInlineDisplay(source)
    let fittedRect = ComposerEmojiImageStore.aspectFitRect(
        imageSize: source.size,
        in: NSRect(x: 0, y: 0, width: 40, height: 40)
    )

    #expect(prepared.size == NSSize(width: 40, height: 40))
    #expect(fittedRect == NSRect(x: 0, y: 10, width: 40, height: 20))
}

@MainActor @Test func `profile emoji attachments share chat baseline metrics and copy tokens`() throws {
    let token = "<:wide_wave:123456>"
    let font = NSFont.systemFont(ofSize: 14)
    let value = ProfileInlineAttributedText.make(
        source: "hello \(token)",
        font: font,
        color: .labelColor,
        emojiImages: [token: NSImage(size: NSSize(width: 40, height: 20))],
        stylesLinks: true
    )
    let attachmentLocation = (value.string as NSString).range(of: "\u{FFFC}").location
    #expect(attachmentLocation != NSNotFound)
    let attachment = try #require(
        value.attribute(.attachment, at: attachmentLocation, effectiveRange: nil)
            as? NSTextAttachment
    )
    let size = font.pointSize * 1.15

    #expect(attachment.bounds.size == NSSize(width: size, height: size))
    #expect(
        attachment.bounds.origin.y
            == ComposerEmojiAttributedText.attachmentOriginY(font: font, size: size)
    )
    #expect(ComposerEmojiAttributedText.serialize(value) == "hello \(token)")
}

@MainActor @Test func `profile selectable text draws selected custom emoji above the attachment`() throws {
    let token = "<:wide_wave:123456>"
    let textView = ProfileSelectableTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.containerSize = NSSize(width: 240, height: 40)
    textView.textStorage?.setAttributedString(
        ProfileInlineAttributedText.make(
            source: "a\(token)b",
            font: .systemFont(ofSize: 14),
            color: .labelColor,
            emojiImages: [token: NSImage(size: NSSize(width: 40, height: 20))],
            stylesLinks: false
        )
    )
    textView.setSelectedRange(NSRange(location: 1, length: 1))
    textView.layoutManager?.ensureLayout(for: try #require(textView.textContainer))

    let rect = try #require(textView.attachmentSelectionRects().first)
    #expect(rect.width > 0)
    #expect(rect.height > 0)
}

@MainActor @Test func `composer emoji line metrics remain stable beside text`() {
    let token = "<:aurora_glow:900000000000000101>"

    func metrics(_ source: String) -> (usedHeight: CGFloat, lineHeight: CGFloat) {
        let storage = NSTextStorage(
            attributedString: ComposerEmojiAttributedText.make(
                source,
                imageProvider: { _ in NSImage(size: NSSize(width: 18, height: 18)) }
            )
        )
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return (
            manager.usedRect(for: container).height,
            manager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil).height
        )
    }

    let emojiOnly = metrics(token)
    let mixed = metrics(token + "h")
    #expect(emojiOnly.usedHeight == mixed.usedHeight)
    #expect(emojiOnly.lineHeight == mixed.lineHeight)
}

private extension NSTextView {
    func attribute(_ key: NSAttributedString.Key, at location: Int) -> Any? {
        attributedString().attribute(key, at: location, effectiveRange: nil)
    }
}
