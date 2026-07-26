import AppKit
import MessageRendering
import SakuraCordModels
import SwiftUI

enum MentionTarget: Hashable {
    case unresolved
    case user(UserID)
    case role(RoleID)
    case channel(ChannelID)
    case linkedChannel(guildID: GuildID?, channelID: ChannelID)
    case message(guildID: GuildID?, channelID: ChannelID, messageID: MessageID)
}

struct DiscordChannelLink: Hashable {
    let guildID: GuildID?
    let channelID: ChannelID

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              Self.hosts.contains(host)
        else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 3,
              components[0] == "channels",
              components[1] == "@me" || UInt64(components[1]) != nil,
              let channelID = ChannelID(components[2])
        else { return nil }
        guildID = components[1] == "@me" ? nil : GuildID(components[1])
        self.channelID = channelID
    }

    private static let hosts: Set<String> = [
        "discord.com", "www.discord.com", "canary.discord.com", "ptb.discord.com",
        "discordapp.com", "www.discordapp.com", "canary.discordapp.com", "ptb.discordapp.com"
    ]
}

struct MentionPresentation: Hashable, Identifiable {
    let rawToken: String
    let label: String
    let target: MentionTarget
    var avatarURL: URL?
    var colorHex: UInt32?
    var systemImage: String?

    var id: String { rawToken }

    static func fallback(for mention: RenderedMention) -> MentionPresentation {
        switch mention.kind {
        case .user:
            guard let id = UserID(mention.id) else {
                return unresolved(mention, label: "@unknown-user")
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "@unknown-user",
                target: .user(id)
            )
        case .role:
            guard let id = RoleID(mention.id) else {
                return unresolved(mention, label: "@unknown-role")
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "@unknown-role",
                target: .role(id)
            )
        case .channel:
            guard let id = ChannelID(mention.id) else {
                return unresolved(
                    mention,
                    label: "unknown-channel",
                    systemImage: ChannelIconPresentation.systemImage(for: .unknown, isHidden: false)
                )
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "unknown-channel",
                target: .channel(id),
                systemImage: ChannelIconPresentation.systemImage(for: .unknown, isHidden: false)
            )
        case .channelLink:
            guard let id = ChannelID(mention.id) else {
                return unresolved(
                    mention,
                    label: "unknown-post",
                    systemImage: ChannelIconPresentation.forumPostSystemImage
                )
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "unknown-post",
                target: .linkedChannel(
                    guildID: mention.messageGuildID.flatMap(GuildID.init),
                    channelID: id
                ),
                systemImage: ChannelIconPresentation.forumPostSystemImage
            )
        case .message:
            guard let channelID = mention.messageChannelID.flatMap(ChannelID.init),
                  let messageID = MessageID(mention.id)
            else {
                return unresolved(
                    mention,
                    label: "unknown-channel ›",
                    systemImage: "bubble.left.fill"
                )
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "unknown-channel ›",
                target: .message(
                    guildID: mention.messageGuildID.flatMap(GuildID.init),
                    channelID: channelID,
                    messageID: messageID
                ),
                systemImage: "bubble.left.fill"
            )
        }
    }

    private static func unresolved(
        _ mention: RenderedMention,
        label: String,
        systemImage: String? = nil
    ) -> MentionPresentation {
        MentionPresentation(
            rawToken: mention.rawToken,
            label: label,
            target: .unresolved,
            systemImage: systemImage
        )
    }
}

struct SelectableMessageTextView: NSViewRepresentable {
    let source: String
    let emojiSize: CGFloat
    let mentionPresentations: [String: MentionPresentation]
    var onMentionClick: (MentionPresentation, StablePopoverAnchor) -> Void = { _, _ in }
    var onURLClick: (URL) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RichMessageNSTextView {
        let textView = RichMessageNSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        // Lay out unbounded vertically. `widthTracksTextView` keeps the width in
        // sync with the frame SwiftUI assigns; nothing else sets this now that
        // sizing no longer reaches into the displayed view.
        textView.textContainer?.size = NSSize(
            width: textView.bounds.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        // SwiftUI owns this view's height. Letting the text view resize itself
        // to fit re-wrapped text lets its rendered height drift from the height
        // SwiftUI measured, which the scroll view then has to correct.
        textView.isVerticallyResizable = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: 0
        ]
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.onMentionClick = onMentionClick
        textView.onURLClick = onURLClick
        return textView
    }

    func updateNSView(_ textView: RichMessageNSTextView, context: Context) {
        textView.onMentionClick = onMentionClick
        textView.onURLClick = onURLClick
        let signature = RichMessageRenderSignature(
            source: source,
            emojiSize: emojiSize,
            mentionPresentations: mentionPresentations
        )
        guard textView.renderSignature != signature else { return }
        textView.renderSignature = signature
        textView.textStorage?.setAttributedString(
            RichMessageAttributedText.make(
                source: source,
                emojiSize: emojiSize,
                mentionPresentations: mentionPresentations
            )
        )
        textView.invalidateIntrinsicContentSize()
        context.coordinator.loadEmojiImages(in: textView)
        context.coordinator.loadMentionAvatars(in: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: RichMessageNSTextView,
        context: Context
    ) -> CGSize? {
        let minimumHeight = MessageRowLayoutMetrics.compactContentHeight
        let signature = RichMessageRenderSignature(
            source: source,
            emojiSize: emojiSize,
            mentionPresentations: mentionPresentations
        )

        if let width = RichMessageTextMeasurement.constrainedWidth(proposal.width) {
            return CGSize(
                width: width,
                height: height(
                    for: signature,
                    textView: textView,
                    width: width,
                    minimumHeight: minimumHeight
                )
            )
        }

        let value = attributedValue(for: signature, textView: textView)
        let width = RichMessageTextMeasurer.idealWidth(of: value)
        return CGSize(
            width: width,
            height: height(
                for: signature,
                textView: textView,
                width: width,
                minimumHeight: minimumHeight
            )
        )
    }

    private func height(
        for signature: RichMessageRenderSignature,
        textView: RichMessageNSTextView,
        width: CGFloat,
        minimumHeight: CGFloat
    ) -> CGFloat {
        if let cached = RichMessageHeightCache.height(
            signature: signature,
            width: width,
            minimumHeight: minimumHeight
        ) {
            return cached
        }
        let value = RichMessageTextMeasurer.height(
            of: attributedValue(for: signature, textView: textView),
            width: width,
            minimumHeight: minimumHeight
        )
        RichMessageHeightCache.insert(
            value,
            signature: signature,
            width: width,
            minimumHeight: minimumHeight
        )
        return value
    }

    /// Reuses the text view's own storage when it already matches, so a plain
    /// re-measure does not rebuild attachments.
    private func attributedValue(
        for signature: RichMessageRenderSignature,
        textView: RichMessageNSTextView
    ) -> NSAttributedString {
        if textView.renderSignature == signature, let storage = textView.textStorage {
            return storage
        }
        return RichMessageAttributedText.make(
            source: source,
            emojiSize: emojiSize,
            mentionPresentations: mentionPresentations
        )
    }

    static func dismantleNSView(_ nsView: RichMessageNSTextView, coordinator: Coordinator) {
        coordinator.cancelEmojiLoads()
        RichMessageSelectionOwnership.remove(nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let attachmentImageLoader = InlineAttachmentImageLoader()

        func loadEmojiImages(in textView: NSTextView) {
            attachmentImageLoader.loadEmojiImages(
                in: textView,
                addsAccessibilityDescriptions: true
            )
        }

        func cancelEmojiLoads() {
            attachmentImageLoader.cancel()
        }

        func loadMentionAvatars(in textView: NSTextView) {
            attachmentImageLoader.loadMentionAvatars(in: textView)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            if (textView as? RichMessageNSTextView)?.onURLClick(url) == true {
                return true
            }
            NSWorkspace.shared.open(url)
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? RichMessageNSTextView else { return }
            if textView.selectedRange().length > 0 {
                textView.claimSelectionOwnership()
            }
            textView.needsDisplay = true
        }

    }
}

nonisolated enum RichMessageTextMeasurement {
    static let maximumWidth: CGFloat = 10_000

    static func constrainedWidth(_ proposedWidth: CGFloat?) -> CGFloat? {
        guard let proposedWidth, proposedWidth.isFinite else { return nil }
        return min(max(1, proposedWidth), maximumWidth)
    }
}

struct RichMessageRenderSignature: Equatable, Hashable {
    let source: String
    let emojiSize: CGFloat
    let mentionPresentations: [String: MentionPresentation]
}

/// Text layout results shared across rows.
///
/// `NSTextView` measurement used to live on the view instance, so a row that
/// scrolled out of the `LazyVStack` and back re-ran TextKit layout from
/// scratch inside SwiftUI's layout pass. Keying by signature and width lets a
/// recycled row reuse the height it already computed.
@MainActor
enum RichMessageHeightCache {
    private struct Key: Hashable {
        let signature: RichMessageRenderSignature
        let width: CGFloat
        let minimumHeight: CGFloat
    }

    private static var values: [Key: CGFloat] = [:]
    private static var insertionOrder: [Key] = []
    private static let limit = 4_000

    static func height(
        signature: RichMessageRenderSignature?,
        width: CGFloat,
        minimumHeight: CGFloat
    ) -> CGFloat? {
        guard let signature else { return nil }
        return values[Key(signature: signature, width: width, minimumHeight: minimumHeight)]
    }

    static func insert(
        _ height: CGFloat,
        signature: RichMessageRenderSignature?,
        width: CGFloat,
        minimumHeight: CGFloat
    ) {
        guard let signature else { return }
        let key = Key(signature: signature, width: width, minimumHeight: minimumHeight)
        guard values.updateValue(height, forKey: key) == nil else { return }
        insertionOrder.append(key)
        guard insertionOrder.count > limit else { return }
        let evictionCount = limit / 4
        for key in insertionOrder.prefix(evictionCount) {
            values.removeValue(forKey: key)
        }
        insertionOrder.removeFirst(evictionCount)
    }
}

/// Measures message text without touching any displayed view.
///
/// Sizing used to run against the live `NSTextView`, mutating its frame and
/// text container mid-query. Combined with `widthTracksTextView`, the width the
/// text actually wrapped at could differ from the width it was measured at, so
/// a row's rendered height drifted from the height SwiftUI was told — which the
/// scroll view then corrected, over and over, as rows were realized.
@MainActor
enum RichMessageTextMeasurer {
    private static let storage = NSTextStorage()
    private static let layoutManager = NSLayoutManager()
    private static let container = NSTextContainer(
        size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
    )
    private static var isConfigured = false

    private static func prepare(_ value: NSAttributedString, width: CGFloat) {
        if !isConfigured {
            isConfigured = true
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.lineBreakMode = NSLineBreakMode.byWordWrapping
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
        }
        storage.setAttributedString(value)
        container.size = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
    }

    static func height(
        of value: NSAttributedString,
        width: CGFloat,
        minimumHeight: CGFloat
    ) -> CGFloat {
        prepare(value, width: width)
        return max(minimumHeight, ceil(layoutManager.usedRect(for: container).height))
    }

    /// The width the text would occupy laid out on a single unbounded line,
    /// used when SwiftUI proposes no width.
    static func idealWidth(of value: NSAttributedString) -> CGFloat {
        prepare(value, width: RichMessageTextMeasurement.maximumWidth)
        let glyphRange = layoutManager.glyphRange(for: container)
        var usedBounds = CGRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, usedRect, _, lineGlyphRange, _ in
            guard lineGlyphRange.length > 0 else { return }
            usedBounds = usedBounds.union(usedRect)
        }
        return RichMessageTextMeasurement.constrainedWidth(
            ceil(usedBounds.isNull ? 0 : usedBounds.maxX)
        ) ?? 1
    }
}

@MainActor
private enum RichMessageAttributedText {
    private enum InlineToken {
        case customEmoji(RenderedEmoji)
        case mention(RenderedMention)
    }

    static func make(
        source: String,
        emojiSize: CGFloat,
        mentionPresentations: [String: MentionPresentation]
    ) -> NSAttributedString {
        let document = MessageDocumentCache.shared.document(for: source)
        var transformed = ""
        var tokens: [InlineToken] = []

        for segment in document.segments {
            switch segment {
            case let .markdown(value):
                transformed += value
            case let .customEmoji(emoji):
                transformed.append("\u{FFFC}")
                tokens.append(.customEmoji(emoji))
            case let .mention(mention):
                transformed.append("\u{FFFC}")
                tokens.append(.mention(mention))
            }
        }

        let baseFontSize: CGFloat = document.isEmojiOnly ? emojiSize : 15
        let baseFont = NSFont.systemFont(ofSize: baseFontSize)
        let output = NSMutableAttributedString(
            attributedString: DiscordMarkdown.appKitAttributed(
                transformed,
                baseFontSize: baseFontSize
            )
        )
        let placeholderRanges = ranges(of: "\u{FFFC}", in: output.string)

        for (range, token) in zip(placeholderRanges.reversed(), tokens.reversed()) {
            switch token {
            case let .customEmoji(emoji):
                output.replaceCharacters(
                    in: range,
                    with: customEmoji(emoji, size: emojiSize, font: baseFont)
                )
            case let .mention(mention):
                output.replaceCharacters(
                    in: range,
                    with: mentionAttributedString(
                        mentionPresentations[mention.rawToken]
                            ?? MentionPresentation.fallback(for: mention),
                        font: baseFont
                    )
                )
            }
        }
        return output
    }

    private static func ranges(of value: String, in source: String) -> [NSRange] {
        let source = source as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let range = source.range(of: value, options: [], range: searchRange)
            guard range.location != NSNotFound else { break }
            ranges.append(range)
            let nextLocation = NSMaxRange(range)
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
        return ranges
    }

    private static func customEmoji(
        _ emoji: RenderedEmoji,
        size: CGFloat,
        font: NSFont
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let image = ComposerEmojiImageStore.shared.cachedImage(for: emoji.rawToken)
            ?? NSImage(systemSymbolName: "face.smiling", accessibilityDescription: emoji.name)
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: ComposerEmojiAttributedText.attachmentOriginY(font: font, size: size),
            width: size,
            height: size
        )
        let value = NSMutableAttributedString(attachment: attachment)
        value.addAttribute(
            .discordEmojiToken,
            value: emoji.rawToken,
            range: NSRange(location: 0, length: value.length)
        )
        return value
    }

    private static func mentionAttributedString(
        _ presentation: MentionPresentation,
        font: NSFont
    ) -> NSAttributedString {
        MentionAttachmentRenderer.attributedString(presentation: presentation, font: font)
    }

}

enum RichMessageCopySerializer {
    nonisolated static func string(from value: NSAttributedString, range: NSRange) -> String {
        var output = ""
        value.enumerateAttributes(in: range) { attributes, effectiveRange, _ in
            if let token = (attributes[.discordEmojiToken] ?? attributes[.discordMentionToken]) as? String {
                output += token
            } else {
                output += value.attributedSubstring(from: effectiveRange).string
            }
        }
        return output
    }
}

final class RichMessageNSTextView: NSTextView {
    fileprivate var renderSignature: RichMessageRenderSignature?
    var onMentionClick: (MentionPresentation, StablePopoverAnchor) -> Void = { _, _ in }
    var onURLClick: (URL) -> Bool = { _ in false }
    private var hoveredMentionLocation: Int?
    private var mentionTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mentionTrackingArea { removeTrackingArea(mentionTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        mentionTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredMention(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredMention(nil)
        super.mouseExited(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        mentionAttachment(at: convert(event.locationInWindow, from: nil)) == nil
            ? NSCursor.iBeam.set()
            : NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        claimSelectionOwnership()
        if event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           let (index, attachment) = mentionAttachment(at: convert(event.locationInWindow, from: nil))
        {
            let rawToken = attachment.presentation.rawToken
            guard let anchor = mentionPopoverAnchor(at: index, rawToken: rawToken) else { return }
            onMentionClick(attachment.presentation, anchor)
            return
        }
        super.mouseDown(with: event)
    }

    private func mentionAttachment(at point: NSPoint) -> (Int, MentionTextAttachment)? {
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

    func mentionPopoverAnchor(at index: Int, rawToken: String) -> StablePopoverAnchor? {
        guard mentionAttachmentRect(at: index, rawToken: rawToken) != nil else { return nil }
        return StablePopoverAnchor(sourceView: self) { [weak self] in
            self?.mentionAttachmentRect(at: index, rawToken: rawToken)
        }
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

    private func updateHoveredMention(at point: NSPoint) {
        setHoveredMention(mentionAttachment(at: point)?.0)
    }

    private func setHoveredMention(_ location: Int?) {
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawSelectionOverAttachments(in: dirtyRect)
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let value = RichMessageCopySerializer.string(from: attributedString(), range: range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func claimSelectionOwnership() {
        RichMessageSelectionOwnership.claim(self)
    }

}

@MainActor
private enum RichMessageSelectionOwnership {
    private static let textViews = NSHashTable<RichMessageNSTextView>.weakObjects()

    static func claim(_ owner: RichMessageNSTextView) {
        textViews.add(owner)
        for textView in textViews.allObjects where textView !== owner {
            guard belongsToSameWindow(textView, owner) else { continue }
            let selection = textView.selectedRange()
            guard selection.length > 0 else { continue }
            textView.setSelectedRange(NSRange(location: selection.location, length: 0))
            textView.needsDisplay = true
        }
    }

    static func remove(_ textView: RichMessageNSTextView) {
        textViews.remove(textView)
    }

    private static func belongsToSameWindow(
        _ lhs: RichMessageNSTextView,
        _ rhs: RichMessageNSTextView
    ) -> Bool {
        guard let lhsWindow = lhs.window, let rhsWindow = rhs.window else {
            return lhs.window == nil && rhs.window == nil
        }
        return lhsWindow === rhsWindow
    }
}
