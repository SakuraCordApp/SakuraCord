import AppKit
import MessageRendering
import SakuraCordModels
import SwiftUI

struct ProfileRichTextView: View {
    let source: String
    var editing: ProfileBioTextEditing?
    @State private var emojiImages: [String: NSImage] = [:]
    @State private var revealedSpoilerLocations: Set<Int> = []

    var body: some View {
        ProfileTextRepresentable(
            source: source,
            emojiImages: emojiImages,
            editing: editing,
            revealedSpoilerLocations: revealedSpoilerLocations,
            onRevealSpoiler: { revealedSpoilerLocations.insert($0) }
        )
        .task(id: source) {
            revealedSpoilerLocations = []
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
    @State private var revealedSpoilerLocations: Set<Int> = []

    var body: some View {
        ProfileStatusTextRepresentable(
            source: source,
            emojiImages: emojiImages,
            isExpanded: isExpanded,
            fontSize: fontSize,
            usesSecondaryColor: usesSecondaryColor,
            revealedSpoilerLocations: revealedSpoilerLocations,
            onRevealSpoiler: { revealedSpoilerLocations.insert($0) },
            onHoverChange: onHoverChange
        )
        .task(id: source) {
            revealedSpoilerLocations = []
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
        var results = Set<EmojiDescriptor>()
        let sourceString = source as NSString
        let range = NSRange(location: 0, length: sourceString.length)
        for match in expression.matches(in: source, range: range) {
            guard match.numberOfRanges == 4 else { continue }
            results.insert(EmojiDescriptor(rawToken: sourceString.substring(with: match.range)))
        }
        for segment in MessageDocument(source: source).segments {
            if case let .customEmoji(emoji) = segment {
                results.insert(EmojiDescriptor(rawToken: emoji.rawToken))
            }
        }
        return Array(results)
    }
}

private struct ProfileStatusTextRepresentable: NSViewRepresentable {
    let source: String
    let emojiImages: [String: NSImage]
    let isExpanded: Bool
    let fontSize: CGFloat
    let usesSecondaryColor: Bool
    var revealedSpoilerLocations: Set<Int> = []
    var onRevealSpoiler: (Int) -> Void = { _ in }
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProfileStatusNSTextView {
        let textView = ProfileStatusNSTextView()
        textView.onHoverChange = onHoverChange
        textView.onRevealSpoiler = onRevealSpoiler
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        return textView
    }

    func updateNSView(_ textView: ProfileStatusNSTextView, context: Context) {
        let selection = textView.selectedRange()
        textView.onHoverChange = onHoverChange
        textView.onRevealSpoiler = onRevealSpoiler
        textView.textContainer?.maximumNumberOfLines = isExpanded ? 0 : 1
        textView.textContainer?.lineBreakMode = isExpanded ? .byWordWrapping : .byTruncatingTail
        if source.contains("<t:") {
            textView.timestampRefresh = { [weak textView] date in
                guard let textView else { return }
                textView.textStorage?.setAttributedString(self.attributedText(at: date))
                textView.invalidateIntrinsicContentSize()
            }
        } else {
            textView.timestampRefresh = nil
        }
        textView.updateTimestampObservation()
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
        let trailingOverflow = isExpanded ? NativeTimelineMarkdownChromeMetrics.trailingVisualOverflow(in: textView.attributedString()) : 0
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height) + trailingOverflow
        return CGSize(width: width, height: max(InterfaceScale.fontSize(fontSize) + InterfaceScale.metric(3), usedHeight))
    }

    static func dismantleNSView(_ nsView: ProfileStatusNSTextView, coordinator: ()) {
        nsView.dismissHoverLabel()
        RelativeTimestampClock.shared.remove(nsView)
        nsView.timestampRefresh = nil
    }

    private func attributedText(at date: Date = .now) -> NSAttributedString {
        ProfileInlineAttributedText.make(
            source: source,
            font: NSFont.interfaceSystemFont(ofSize: fontSize),
            color: usesSecondaryColor ? .secondaryLabelColor : .labelColor,
            emojiImages: emojiImages,
            stylesLinks: false,
            date: date,
            revealedSpoilerLocations: revealedSpoilerLocations
        )
    }
}

private struct ProfileTextRepresentable: NSViewRepresentable {
    let source: String
    let emojiImages: [String: NSImage]
    let editing: ProfileBioTextEditing?
    var revealedSpoilerLocations: Set<Int> = []
    var onRevealSpoiler: (Int) -> Void = { _ in }

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
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: 0
        ]
        return textView
    }

    func updateNSView(_ textView: HoverLinkTextView, context: Context) {
        context.coordinator.parent = self
        editing?.interaction.textView = textView
        textView.onBeginEditing = editing?.onBegin
        textView.onEndEditing = editing?.onEnd
        textView.onCancelEditing = editing?.onCancel
        textView.onRevealSpoiler = onRevealSpoiler
        textView.isEditable = editing != nil
        textView.setAccessibilityLabel(editing == nil ? nil : String(localized: "Edit Bio", bundle: #bundle))
        let selection = textView.selectedRange()

        if editing == nil, source.contains("<t:") {
            textView.timestampRefresh = { [weak textView] date in
                guard let textView else { return }
                textView.textStorage?.setAttributedString(self.attributedText(at: date))
                textView.invalidateIntrinsicContentSize()
            }
        } else {
            textView.timestampRefresh = nil
        }
        textView.updateTimestampObservation()

        // Preserve the live text storage and native caret during keystrokes.
        if editing == nil || ComposerEmojiAttributedText.serialize(textView.attributedString()) != source
            || context.coordinator.images != emojiImages || context.coordinator.wasActive != editing?.isActive
            || context.coordinator.revealedSpoilers != revealedSpoilerLocations {
            textView.textStorage?.setAttributedString(attributedText())
            textView.setSelectedRange(selection.clamped(toLength: textView.string.utf16.count))
        }
        context.coordinator.images = emojiImages
        context.coordinator.wasActive = editing?.isActive
        context.coordinator.revealedSpoilers = revealedSpoilerLocations
        textView.typingAttributes = ComposerTextStyle.composer(.interfaceSystemFont(ofSize: 14)).attributes
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
        let trailingOverflow = NativeTimelineMarkdownChromeMetrics.trailingVisualOverflow(in: textView.attributedString())
        return CGSize(width: width, height: max(InterfaceScale.metric(18), ceil(layoutManager.usedRect(for: textContainer).height) + trailingOverflow))
    }

    static func dismantleNSView(_ nsView: HoverLinkTextView, coordinator: Coordinator) {
        nsView.dismissHoverLabel()
        RelativeTimestampClock.shared.remove(nsView)
        nsView.timestampRefresh = nil
    }

    private func attributedText(at date: Date = .now) -> NSAttributedString {
        if editing != nil {
            return ProfileInlineAttributedText.makeEditable(
                source: source,
                font: NSFont.interfaceSystemFont(ofSize: 14),
                color: .labelColor,
                emojiImages: emojiImages
            )
        }
        return ProfileInlineAttributedText.make(
            source: source,
            font: NSFont.interfaceSystemFont(ofSize: 14),
            color: .labelColor,
            emojiImages: emojiImages,
            stylesLinks: true,
            date: date,
            revealedSpoilerLocations: revealedSpoilerLocations
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProfileTextRepresentable
        var images: [String: NSImage] = [:]
        var wasActive: Bool?
        var revealedSpoilers: Set<Int> = []

        init(parent: ProfileTextRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.editing?.onChange(ComposerEmojiAttributedText.serialize(textView.attributedString()))
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard parent.editing != nil, let textView = notification.object as? NSTextView else { return }
            textView.typingAttributes = ComposerTextStyle.composer(.interfaceSystemFont(ofSize: 14)).attributes
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

    @MainActor
    static func make(
        source: String,
        font: NSFont,
        color: NSColor,
        emojiImages: [String: NSImage],
        stylesLinks: Bool,
        date: Date = .now,
        revealedSpoilerLocations: Set<Int> = []
    ) -> NSAttributedString {
        guard !source.isEmpty else { return NSAttributedString() }

        let prepared = RichMessageAttributedText.prepare(source: source)
        let baseFontSize = font.pointSize
        let output = NSMutableAttributedString(
            attributedString: NativeTimelineCoreText.scaledMarkdown(
                prepared.markdownPlan,
                baseFontSize: baseFontSize
            )
        )

        if color != .labelColor {
            output.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: output.length)) { value, range, _ in
                if let runColor = value as? NSColor, runColor == .labelColor {
                    output.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
        }

        let placeholderRanges = RichMessageAttributedText.ranges(of: "\u{FFFC}", in: output.string)
        let emojiSize = baseFontSize * 1.15

        for (range, token) in zip(placeholderRanges.reversed(), prepared.tokens.reversed()) {
            let spoiler = output.attribute(
                .discordMarkdownSpoiler,
                at: range.location,
                effectiveRange: nil
            )
            let replacement: NSAttributedString
            switch token {
            case let .customEmoji(emoji):
                let image = emojiImages[emoji.rawToken]
                    ?? ComposerEmojiImageStore.shared.cachedImage(for: emoji.rawToken)
                    ?? ComposerEmojiAttributedText.placeholderImage(name: emoji.name, size: emojiSize)
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(
                    x: 0,
                    y: ComposerEmojiAttributedText.attachmentOriginY(font: font, size: emojiSize),
                    width: emojiSize,
                    height: emojiSize
                )
                let value = NSMutableAttributedString(attachment: attachment)
                value.addAttributes(
                    [
                        .discordEmojiToken: emoji.rawToken,
                        .font: font,
                        .foregroundColor: color
                    ],
                    range: NSRange(location: 0, length: value.length)
                )
                replacement = value
            case let .mention(mention):
                let presentation: MentionPresentation
                if mention.kind == .timestamp {
                    presentation = MentionPresentation.timestamp(mention, at: date)
                } else {
                    presentation = MentionPresentation.fallback(for: mention)
                }
                replacement = MentionAttachmentRenderer.attributedString(presentation: presentation, font: font)
            }
            let retainedAttributes = output.attributes(at: range.location, effectiveRange: nil)
                .filter { [.paragraphStyle, .discordMarkdownBlock, .discordMarkdownEm, .link].contains($0.key) }
            output.replaceCharacters(in: range, with: replacement)
            output.addAttributes(
                retainedAttributes,
                range: NSRange(location: range.location, length: replacement.length)
            )
            if let spoiler {
                output.addAttribute(
                    .discordMarkdownSpoiler,
                    value: spoiler,
                    range: NSRange(location: range.location, length: replacement.length)
                )
            }
        }

        if stylesLinks {
            styleLinks(in: output)
        }

        NativeTimelineCoreText.normalizeParagraphMetrics(in: output, spoilersOnly: true)
        RichMessageAttributedText.concealSpoilers(in: output, revealedLocations: revealedSpoilerLocations)

        return output
    }

    @MainActor
    static func makeEditable(
        source: String,
        font: NSFont,
        color: NSColor,
        emojiImages: [String: NSImage]
    ) -> NSAttributedString {
        var style = ComposerTextStyle.composer(font)
        var attributes = style.attributes
        attributes[.foregroundColor] = color
        style = ComposerTextStyle(
            font: font,
            attributes: attributes,
            usesMessageLineHeight: style.usesMessageLineHeight
        )
        return ComposerEmojiAttributedText.make(
            source,
            style: style,
            mentionPresentations: [:],
            imageProvider: { emojiImages[$0] ?? ComposerEmojiImageStore.shared.cachedImage(for: $0) }
        )
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
            var existingRange = NSRange(location: 0, length: 0)
            if value.attribute(.link, at: range.location, effectiveRange: &existingRange) != nil {
                continue
            }
            if value.attribute(.discordMarkdownInlineCode, at: range.location, effectiveRange: nil) != nil
                || value.attribute(.discordMarkdownBlock, at: range.location, effectiveRange: nil) as? String == "code" {
                continue
            }
            while range.length > 0 {
                let last = fullString.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))
                guard last.rangeOfCharacter(from: trailingPunctuation) != nil else { break }
                range.length -= 1
            }
            guard range.length > 0,
                  let url = URL(string: fullString.substring(with: range)) else { continue }
            value.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: range)
        }
    }
}

nonisolated class ProfileLayoutManager: MarkdownLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let textStorage else { return false }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let paragraph = textStorage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle
        let top = lineFragmentUsedRect.pointee.minY - lineFragmentRect.pointee.minY
        baselineOffset.pointee -= max(0, baselineOffset.pointee - top - maximumAscent(characters, in: textStorage)) / 2
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
        MainActor.assumeIsolated {
            for (rect, isCode) in blocks {
                if isCode {
                    MarkdownBlockChrome.drawCode(in: rect)
                } else {
                    MarkdownBlockChrome.drawQuoteBar(in: rect)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    func blockRects() -> [(rect: NSRect, isCode: Bool)] {
        guard let textStorage else { return [] }
        var result: [(NSRect, Bool)] = []
        let containerWidth = textContainers.first?.containerSize.width ?? 0

        for range in codeBlockRanges(in: textStorage) {
            let runGlyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard runGlyphs.length > 0 else { continue }
            var extent: NSRect?
            enumerateLineFragments(forGlyphRange: runGlyphs) { rect, used, _, _, _ in
                let width = (containerWidth.isFinite && containerWidth > 0) ? min(rect.width, containerWidth) : rect.width
                let line = NSRect(x: rect.minX, y: used.minY, width: width, height: used.height)
                extent = extent?.union(line) ?? line
            }
            guard let extent else { continue }
            let inset = NativeTimelineMarkdownChromeMetrics.codeBlockInset(in: textStorage, at: range.location)
            result.append((extent.insetBy(dx: 0, dy: -inset), true))
        }

        for range in quoteRanges(in: textStorage) {
            let runGlyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard runGlyphs.length > 0 else { continue }
            var extent: NSRect?
            enumerateLineFragments(forGlyphRange: runGlyphs) { rect, used, _, _, _ in
                let width = (containerWidth.isFinite && containerWidth > 0) ? min(rect.width, containerWidth) : rect.width
                let line = NSRect(x: rect.minX, y: used.minY, width: width, height: used.height)
                extent = extent?.union(line) ?? line
            }
            guard let extent else { continue }
            let width = NativeTimelineMarkdownChromeMetrics.quoteBarWidth(in: textStorage, at: range.location)
            result.append((NSRect(x: extent.minX, y: extent.minY, width: width, height: extent.height), false))
        }

        return result
    }

    private func codeBlockRanges(in value: NSAttributedString) -> [NSRange] {
        guard value.length > 0 else { return [] }
        let fullRange = NSRange(location: 0, length: value.length)
        let source = value.string as NSString
        var blocks: [NSRange] = []
        value.enumerateAttribute(
            .discordMarkdownBlock,
            in: fullRange
        ) { rawValue, range, _ in
            guard rawValue as? String == "code", range.length > 0 else { return }
            var lineStart = range.location
            while lineStart < NSMaxRange(range) {
                let newline = source.range(
                    of: "\n",
                    range: NSRange(location: lineStart, length: NSMaxRange(range) - lineStart)
                )
                let lineEnd = newline.location == NSNotFound ? NSMaxRange(range) : NSMaxRange(newline)
                let line = NSRange(location: lineStart, length: lineEnd - lineStart)
                let paragraph = value.attribute(
                    .paragraphStyle,
                    at: lineStart,
                    effectiveRange: nil
                ) as? NSParagraphStyle
                if let last = blocks.last, (paragraph?.paragraphSpacingBefore ?? 0) <= 0 {
                    blocks[blocks.count - 1] = NSUnionRange(last, line)
                } else {
                    blocks.append(line)
                }
                lineStart = lineEnd
            }
        }
        return blocks
    }

    private func quoteRanges(in value: NSAttributedString) -> [NSRange] {
        guard value.length > 0 else { return [] }
        let fullRange = NSRange(location: 0, length: value.length)
        var quoteRanges: [NSRange] = []
        value.enumerateAttribute(
            .discordMarkdownBlock,
            in: fullRange
        ) { rawValue, range, _ in
            guard rawValue as? String == "quote", range.length > 0 else { return }
            if let last = quoteRanges.last, range.location - NSMaxRange(last) <= 1 {
                quoteRanges[quoteRanges.count - 1] = NSUnionRange(last, range)
            } else {
                quoteRanges.append(range)
            }
        }
        return quoteRanges
    }
}

class ProfileSelectableTextView: NSTextView {
    var timestampRefresh: ((Date) -> Void)?
    var onRevealSpoiler: (Int) -> Void = { _ in }
    private var hoveredMentionLocation: Int?
    private let hoverLabelCoordinator = StableAnchoredPopoverPresenter<NativeHoverHelpLabel>.Coordinator()
    private var hoveredTimestampToken: (index: Int, rawToken: String)?
    private var dismissedTimestampToken: String?

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = ProfileLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        super.init(frame: .zero, textContainer: textContainer)
    }

    override convenience init(frame frameRect: NSRect) {
        self.init()
        self.frame = frameRect
    }

    override init(frame frameRect: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: textContainer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dismissHoverLabel()
        updateTimestampObservation()
        if window != nil { timestampRefresh?(.now) }
    }

    func updateTimestampObservation() {
        guard window != nil, timestampRefresh != nil else {
            RelativeTimestampClock.shared.remove(self)
            return
        }
        RelativeTimestampClock.shared.observe(self) { [weak self] date in
            guard let self, RelativeTimestampClock.isShowing(self), !visibleRect.isEmpty else { return }
            timestampRefresh?(date)
        }
    }

    func mentionAttachment(at point: NSPoint) -> (Int, MentionTextAttachment)? {
        guard let layoutManager, let textContainer, attributedString().length > 0 else { return nil }
        var location = point
        location.x -= textContainerOrigin.x
        location.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < attributedString().length,
              let attachment = attributedString().attribute(.attachment, at: index, effectiveRange: nil)
              as? MentionTextAttachment
        else { return nil }
        return (index, attachment)
    }

    func mentionAttachmentRect(at index: Int, rawToken: String) -> CGRect? {
        guard let layoutManager, let textContainer,
              index >= 0, index < attributedString().length,
              let attachment = attributedString().attribute(
                  .attachment,
                  at: index,
                  effectiveRange: nil
              ) as? MentionTextAttachment,
              attachment.presentation.rawToken == rawToken
        else { return nil }
        let characterRange = NSRange(location: index, length: 1)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        layoutManager.ensureLayout(for: textContainer)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        let values = [rect.minX, rect.minY, rect.width, rect.height]
        return values.allSatisfy(\.isFinite) && !rect.isEmpty ? rect : nil
    }

    func updateHoveredMention(at point: NSPoint) {
        let hit = mentionAttachment(at: point)
        setHoveredMention(hit?.0)
        updateHoverLabel(hit: hit, at: point)
    }

    private struct TimestampHit {
        let index: Int
        let token: DiscordTimestampToken
        let rawToken: String
    }

    private func updateHoverLabel(hit: (Int, MentionTextAttachment)?, at point: NSPoint) {
        let timestampHit: TimestampHit? = {
            guard WindowModalCoordinator.allowsInput(for: self),
                  NSEvent.pressedMouseButtons == 0,
                  let (index, attachment) = hit,
                  let token = DiscordTimestampToken(rawToken: attachment.presentation.rawToken),
                  hiddenSpoiler(at: point) == nil
            else { return nil }
            return TimestampHit(index: index, token: token, rawToken: attachment.presentation.rawToken)
        }()

        guard let hit = timestampHit else {
            dismissHoverLabel()
            return
        }

        if hit.rawToken != dismissedTimestampToken {
            dismissedTimestampToken = nil
        }
        guard dismissedTimestampToken == nil else {
            hoverLabelCoordinator.close()
            return
        }

        if hoveredTimestampToken?.rawToken == hit.rawToken, hoveredTimestampToken?.index == hit.index {
            return
        }
        hoveredTimestampToken = (hit.index, hit.rawToken)
        let title = hit.token.date.formatted(date: .complete, time: .shortened)
        let anchor = StablePopoverAnchor(sourceView: self) { [weak self] in
            self?.mentionAttachmentRect(at: hit.index, rawToken: hit.rawToken)
        }
        hoverLabelCoordinator.update(
            anchor: anchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: .intrinsicHoverLabel,
            onDismiss: {},
            content: NativeHoverHelpLabel(title: title)
        )
    }

    func dismissHoverLabel() {
        hoveredTimestampToken = nil
        dismissedTimestampToken = nil
        hoverLabelCoordinator.close()
    }

    func setHoveredMention(_ location: Int?) {
        guard location != hoveredMentionLocation else { return }
        let old = hoveredMentionLocation
        hoveredMentionLocation = location
        for index in [old, location].compactMap({ $0 }) where index < attributedString().length {
            guard let attachment = attributedString().attribute(.attachment, at: index, effectiveRange: nil)
                as? MentionTextAttachment else { continue }
            attachment.image = index == location ? attachment.hoverImage : attachment.normalImage
        }
        needsDisplay = true
    }

    func hiddenSpoiler(at point: NSPoint) -> NSRange? {
        SelectableTextSpoilerGeometry.hiddenSpoilerRange(at: point, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        dismissHoverLabel()
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]) {
            if let spoiler = hiddenSpoiler(at: point) {
                onRevealSpoiler(spoiler.location)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        dismissHoverLabel()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        dismissHoverLabel()
        super.otherMouseDown(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredMention(nil)
        dismissHoverLabel()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawSelectionOverAttachments(in: dirtyRect)
        SelectableTextSpoilerGeometry.draw(in: self, dirtyRect: dirtyRect)
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
                .mouseMoved,
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

    override func mouseMoved(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredMention(at: point)
        if mentionAttachment(at: point) != nil || hiddenSpoiler(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredMention(nil)
        dismissHoverLabel()
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
        updateHoveredMention(at: point)
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
            if mentionAttachment(at: point) != nil || hiddenSpoiler(at: point) != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.iBeam.set()
            }
            return
        }
        var linkRange = NSRange(location: 0, length: 0)
        let hasLink = textStorage.attribute(.link, at: characterIndex, effectiveRange: &linkRange) != nil
        if hasLink {
            updateUnderline(linkRange)
            NSCursor.pointingHand.set()
        } else {
            updateUnderline(nil)
            if mentionAttachment(at: point) != nil || hiddenSpoiler(at: point) != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.iBeam.set()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredMention(nil)
        dismissHoverLabel()
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
