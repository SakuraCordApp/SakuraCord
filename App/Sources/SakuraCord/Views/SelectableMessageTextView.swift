import AppKit
import MessageRendering
import OSLog
import SakuraCordModels
import SwiftUI
import Synchronization

nonisolated enum MentionTarget: Hashable, Sendable {
    case unresolved
    case user(UserID)
    case role(RoleID)
    case channel(ChannelID)
    case linkedChannel(guildID: GuildID?, channelID: ChannelID)
    case message(guildID: GuildID?, channelID: ChannelID, messageID: MessageID)
}

nonisolated struct MentionPresentation: Hashable, Identifiable, Sendable {
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
    var model: AppModel?
    let source: String
    let emojiSize: CGFloat
    var baseFontSize: CGFloat?
    var maximumNumberOfLines: Int?
    var isSelectable = true
    var foregroundColor: NSColor?
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
        textView.isSelectable = isSelectable
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.widthTracksTextView = true
        configureTextContainer(textView.textContainer)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
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
        textView.model = model
        return textView
    }

    func updateNSView(_ textView: RichMessageNSTextView, context: Context) {
        textView.onMentionClick = onMentionClick
        textView.onURLClick = onURLClick
        textView.model = model
        textView.isSelectable = isSelectable
        configureTextContainer(textView.textContainer)
        let signature = RichMessageRenderSignature(
            source: source,
            emojiSize: emojiSize,
            baseFontSize: baseFontSize,
            maximumNumberOfLines: maximumNumberOfLines,
            isSelectable: isSelectable,
            foregroundColor: foregroundColor.map(String.init(describing:)),
            mentionPresentations: mentionPresentations
        )
        guard textView.renderSignature != signature else { return }
        textView.clearHoveredLink()
        textView.invalidateMeasurementCache()
        textView.renderSignature = signature
        let rendered = NSMutableAttributedString(
            attributedString: RichMessageAttributedText.make(
                source: source,
                emojiSize: emojiSize,
                baseFontSize: baseFontSize,
                mentionPresentations: mentionPresentations
            )
        )
        if let foregroundColor {
            rendered.addAttribute(
                .foregroundColor,
                value: foregroundColor,
                range: NSRange(location: 0, length: rendered.length)
            )
        }
        textView.textStorage?.setAttributedString(rendered)
        textView.invalidateIntrinsicContentSize()
        context.coordinator.loadEmojiImages(in: textView)
        context.coordinator.loadMentionAvatars(in: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: RichMessageNSTextView,
        context: Context
    ) -> CGSize? {
        textView.measuredSize(
            proposedWidth: proposal.width,
            minimumHeight: MessageRowLayoutMetrics.compactContentHeight
        )
    }

    static func dismantleNSView(_ nsView: RichMessageNSTextView, coordinator: Coordinator) {
        coordinator.cancelEmojiLoads()
        RichMessageSelectionOwnership.remove(nsView)
    }

    private func configureTextContainer(_ textContainer: NSTextContainer?) {
        textContainer?.maximumNumberOfLines = maximumNumberOfLines ?? 0
        textContainer?.lineBreakMode = maximumNumberOfLines == nil
            ? .byWordWrapping
            : .byTruncatingTail
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
            guard let richTextView = textView as? RichMessageNSTextView else {
                return false
            }
            var linkRange = NSRange(location: 0, length: 0)
            richTextView.attributedString().attribute(
                .link,
                at: charIndex,
                effectiveRange: &linkRange
            )
            let displayedText = linkRange.length > 0
                ? richTextView.attributedString().attributedSubstring(
                    from: linkRange
                ).string
                : nil
            return MessageLinkActivator.activate(
                url,
                model: richTextView.model,
                displayedText: displayedText,
                customHandler: richTextView.onURLClick
            )
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

private struct RichMessageRenderSignature: Equatable {
    let source: String
    let emojiSize: CGFloat
    let baseFontSize: CGFloat?
    let maximumNumberOfLines: Int?
    let isSelectable: Bool
    let foregroundColor: String?
    let mentionPresentations: [String: MentionPresentation]
}

nonisolated enum RichMessageAttributedText {
    private struct PreparedCacheState: Sendable {
        var values: [String: Prepared] = [:]
        var insertionOrder: [String] = []
        var evictionIndex = 0
    }

    private static let maximumPreparedCacheEntries = 2_048
    private static let preparedCache = Mutex(PreparedCacheState())
    private static let performanceSignposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PointsOfInterest"
    )

    enum InlineToken: Hashable, Sendable {
        case customEmoji(RenderedEmoji)
        case mention(RenderedMention)
    }

    struct Prepared: Hashable, Sendable {
        let markdownPlan: DiscordMarkdown.AppKitPlan
        let tokens: [InlineToken]
        let isEmojiOnly: Bool
    }

    nonisolated static func prepare(source: String) -> Prepared {
        if let cached = preparedCache.withLock({ $0.values[source] }) {
            return cached
        }
        let signpost = performanceSignposter.beginInterval(
            "RichTextParse",
            id: performanceSignposter.makeSignpostID()
        )
        defer {
            performanceSignposter.endInterval("RichTextParse", signpost)
        }
        let document = MessageDocument(source: source)
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
        let prepared = Prepared(
            markdownPlan: DiscordMarkdown.appKitPlan(transformed),
            tokens: tokens,
            isEmojiOnly: document.isEmojiOnly
        )
        return preparedCache.withLock { state in
            if let existing = state.values[source] {
                return existing
            }
            state.values[source] = prepared
            state.insertionOrder.append(source)
            while state.values.count > maximumPreparedCacheEntries,
                  state.evictionIndex < state.insertionOrder.count
            {
                let evicted = state.insertionOrder[state.evictionIndex]
                state.evictionIndex += 1
                state.values[evicted] = nil
            }
            if state.evictionIndex > 1_024,
               state.evictionIndex * 2 > state.insertionOrder.count
            {
                state.insertionOrder.removeFirst(state.evictionIndex)
                state.evictionIndex = 0
            }
            return prepared
        }
    }

    @MainActor
    static func make(
        source: String,
        emojiSize: CGFloat,
        baseFontSize: CGFloat? = nil,
        mentionPresentations: [String: MentionPresentation]
    ) -> NSAttributedString {
        make(
            prepared: prepare(source: source),
            emojiSize: emojiSize,
            baseFontSize: baseFontSize,
            mentionPresentations: mentionPresentations
        )
    }

    @MainActor
    static func make(
        prepared: Prepared,
        emojiSize: CGFloat,
        baseFontSize: CGFloat? = nil,
        mentionPresentations: [String: MentionPresentation]
    ) -> NSAttributedString {
        let resolvedBaseFontSize = baseFontSize ?? (prepared.isEmojiOnly ? emojiSize : 15)
        let baseFont = NSFont.systemFont(ofSize: resolvedBaseFontSize)
        let output = NSMutableAttributedString(
            attributedString: DiscordMarkdown.appKitAttributed(
                prepared.markdownPlan,
                baseFontSize: resolvedBaseFontSize
            )
        )
        let placeholderRanges = ranges(of: "\u{FFFC}", in: output.string)

        for (range, token) in zip(
            placeholderRanges.reversed(),
            prepared.tokens.reversed()
        ) {
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

    @MainActor
    private static func customEmoji(
        _ emoji: RenderedEmoji,
        size: CGFloat,
        font: NSFont
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let image = ComposerEmojiImageStore.shared.cachedImage(for: emoji.rawToken)
            ?? SakuraCordSystemSymbol.image(
                named: SakuraCordSystemSymbol.emojiFaceGrinning,
                accessibilityDescription: emoji.name
            )
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

    @MainActor
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
    weak var model: AppModel?
    var onMentionClick: (MentionPresentation, StablePopoverAnchor) -> Void = { _, _ in }
    var onURLClick: (URL) -> Bool = { _ in false }
    private var hoveredMentionLocation: Int?
    private var hoveredLinkRange: NSRange?
    private var mentionTrackingArea: NSTrackingArea?
    private var unconstrainedMeasurement: CGSize?
    private var measuredHeights: [CGFloat: CGFloat] = [:]

    fileprivate func invalidateMeasurementCache() {
        unconstrainedMeasurement = nil
        measuredHeights.removeAll(keepingCapacity: true)
    }

    fileprivate func measuredSize(proposedWidth: CGFloat?, minimumHeight: CGFloat) -> CGSize {
        if let width = RichMessageTextMeasurement.constrainedWidth(proposedWidth) {
            configureTextContainer(width: width)
            if let height = measuredHeights[width] {
                return CGSize(width: width, height: height)
            }
            let height = measuredHeight(minimumHeight: minimumHeight)
            if measuredHeights.count >= 4 {
                measuredHeights.removeAll(keepingCapacity: true)
            }
            measuredHeights[width] = height
            return CGSize(width: width, height: height)
        }

        if let unconstrainedMeasurement {
            return unconstrainedMeasurement
        }
        configureTextContainer(width: RichMessageTextMeasurement.maximumWidth)
        guard let layoutManager, let textContainer else {
            let value = CGSize(width: 1, height: minimumHeight)
            unconstrainedMeasurement = value
            return value
        }
        let tracksTextViewWidth = textContainer.widthTracksTextView
        textContainer.widthTracksTextView = false
        textContainer.containerSize = NSSize(
            width: RichMessageTextMeasurement.maximumWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var usedBounds = CGRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            guard lineGlyphRange.length > 0 else { return }
            usedBounds = usedBounds.union(usedRect)
        }
        let width = RichMessageTextMeasurement.constrainedWidth(
            ceil(usedBounds.isNull ? 0 : usedBounds.maxX)
        ) ?? 1
        textContainer.widthTracksTextView = tracksTextViewWidth
        configureTextContainer(width: width)
        let value = CGSize(width: width, height: measuredHeight(minimumHeight: minimumHeight))
        unconstrainedMeasurement = value
        return value
    }

    private func configureTextContainer(width: CGFloat) {
        frame.size.width = width
        textContainer?.containerSize = NSSize(
            width: width,
            height: .greatestFiniteMagnitude
        )
    }

    private func measuredHeight(minimumHeight: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return minimumHeight }
        layoutManager.ensureLayout(for: textContainer)
        return max(minimumHeight, ceil(layoutManager.usedRect(for: textContainer).height))
    }

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
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredMention(at: point)
        setHoveredLink(link(at: point)?.range)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredMention(nil)
        clearHoveredLink()
        super.mouseExited(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if mentionAttachment(at: point) == nil, link(at: point) == nil {
            NSCursor.iBeam.set()
        } else {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        claimSelectionOwnership()
        if event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
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

    private func link(at point: NSPoint) -> (url: URL, range: NSRange)? {
        guard let layoutManager, let textContainer,
              attributedString().length > 0
        else { return nil }
        var location = point
        location.x -= textContainerOrigin.x
        location.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < attributedString().length else { return nil }
        var range = NSRange(location: 0, length: 0)
        let rawLink = attributedString().attribute(
            .link,
            at: index,
            effectiveRange: &range
        )
        let url: URL? = switch rawLink {
        case let value as URL:
            value
        case let value as NSURL:
            value as URL
        case let value as String:
            URL(string: value)
        default:
            nil
        }
        guard let url, range.length > 0 else { return nil }
        return (url, range)
    }

    fileprivate func clearHoveredLink() {
        setHoveredLink(nil)
    }

    private func setHoveredLink(_ range: NSRange?) {
        if let hoveredLinkRange, let range,
           NSEqualRanges(hoveredLinkRange, range)
        {
            return
        }
        if let hoveredLinkRange {
            layoutManager?.removeTemporaryAttribute(
                .underlineStyle,
                forCharacterRange: hoveredLinkRange
            )
        }
        hoveredLinkRange = range
        if let range {
            layoutManager?.addTemporaryAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                forCharacterRange: range
            )
        }
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
