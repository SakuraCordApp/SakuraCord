import AppKit
import MessageRendering
import OSLog
import SakuraCordModels
import SwiftUI
import Synchronization

struct SelectableMessageTextView: NSViewRepresentable {
    var model: AppModel?
    let source: String
    var markdownRules = DiscordMarkdown.Rules.message
    let emojiSize: CGFloat
    var baseFontSize: CGFloat?
    var maximumNumberOfLines: Int?
    var isSelectable = true
    var foregroundColor: NSColor?
    let mentionPresentations: [String: MentionPresentation]
    var revealedSpoilerLocations: Set<Int> = []
    var onRevealSpoiler: (Int) -> Void = { _ in }
    var onMentionClick: (MentionPresentation, StablePopoverAnchor) -> Void = { _, _ in }
    var onURLClick: (URL) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RichMessageNSTextView {
        let textView = RichMessageNSTextView()
        textView.textContainer?.replaceLayoutManager(MarkdownLayoutManager())
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
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.onMentionClick = onMentionClick
        textView.onURLClick = onURLClick
        textView.onRevealSpoiler = onRevealSpoiler
        textView.model = model
        return textView
    }

    func updateNSView(_ textView: RichMessageNSTextView, context: Context) {
        textView.onMentionClick = onMentionClick
        textView.onURLClick = onURLClick
        textView.onRevealSpoiler = onRevealSpoiler
        textView.model = model
        textView.isSelectable = isSelectable
        configureTextContainer(textView.textContainer)
        let coordinator = context.coordinator
        if !TimestampMentionPresentation.tokens(in: source).isEmpty {
            textView.timestampRefresh = { [weak textView, weak coordinator] date in
                guard let textView, let coordinator else { return }
                render(in: textView, coordinator: coordinator, at: date)
            }
        } else {
            textView.timestampRefresh = nil
        }
        textView.updateTimestampObservation()
        render(in: textView, coordinator: coordinator, at: .now)
    }

    func render(in textView: RichMessageNSTextView, coordinator: Coordinator, at date: Date) {
        let currentMentions = TimestampMentionPresentation.refreshed(
            mentionPresentations, source: source, at: date
        )
        let signature = RichMessageRenderSignature(
            source: source,
            markdownRules: markdownRules,
            emojiSize: emojiSize,
            baseFontSize: baseFontSize,
            maximumNumberOfLines: maximumNumberOfLines,
            isSelectable: isSelectable,
            foregroundColor: foregroundColor.map(String.init(describing:)),
            mentionPresentations: currentMentions,
            revealedSpoilerLocations: revealedSpoilerLocations
        )
        guard textView.renderSignature != signature else { return }
        textView.clearHoveredLink()
        textView.invalidateMeasurementCache()
        let selectedRanges = textView.renderSignature?.source == source ? textView.selectedRanges : []
        textView.renderSignature = signature
        let rendered = NSMutableAttributedString(
            attributedString: RichMessageAttributedText.make(
                source: source,
                rules: markdownRules,
                emojiSize: emojiSize,
                baseFontSize: baseFontSize,
                mentionPresentations: currentMentions
            )
        )
        if let foregroundColor {
            rendered.addAttribute(
                .foregroundColor,
                value: foregroundColor,
                range: NSRange(location: 0, length: rendered.length)
            )
        }
        RichMessageAttributedText.concealSpoilers(
            in: rendered,
            revealedLocations: revealedSpoilerLocations
        )
        textView.textStorage?.setAttributedString(rendered)
        let validRanges = selectedRanges.filter { NSMaxRange($0.rangeValue) <= rendered.length }
        if !validRanges.isEmpty { textView.selectedRanges = validRanges }
        textView.invalidateIntrinsicContentSize()
        coordinator.loadEmojiImages(in: textView)
        coordinator.loadMentionAvatars(in: textView)
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
        RelativeTimestampClock.shared.remove(nsView)
        nsView.timestampRefresh = nil
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
                longestEffectiveRange: &linkRange,
                in: NSRange(location: 0, length: richTextView.attributedString().length)
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

private struct RichMessageRenderSignature: Equatable {
    let source: String
    let markdownRules: DiscordMarkdown.Rules
    let emojiSize: CGFloat
    let baseFontSize: CGFloat?
    let maximumNumberOfLines: Int?
    let isSelectable: Bool
    let foregroundColor: String?
    let mentionPresentations: [String: MentionPresentation]
    let revealedSpoilerLocations: Set<Int>
}

final class RichMessageNSTextView: NSTextView {
    var timestampRefresh: ((Date) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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

    fileprivate var renderSignature: RichMessageRenderSignature?
    weak var model: AppModel?
    var onMentionClick: (MentionPresentation, StablePopoverAnchor) -> Void = { _, _ in }
    var onURLClick: (URL) -> Bool = { _ in false }
    var onRevealSpoiler: (Int) -> Void = { _ in }
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
        // Popovers stay non-key until clicked; their mentions still hover.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        mentionTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredMention(at: point)
        setHoveredLink(link(at: point)?.range)
        super.mouseMoved(with: event)
        // NSTextView restores the I-beam on every move, even over a mention.
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredMention(nil)
        clearHoveredLink()
        super.mouseExited(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at point: NSPoint) {
        if mentionAttachment(at: point) == nil, link(at: point) == nil, hiddenSpoiler(at: point) == nil {
            NSCursor.iBeam.set()
        } else {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        claimSelectionOwnership()
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]) {
            if let spoiler = hiddenSpoiler(at: point) {
                onRevealSpoiler(spoiler.location)
                return
            }
            if let (index, attachment) = mentionAttachment(at: point) {
                let rawToken = attachment.presentation.rawToken
                guard let anchor = mentionPopoverAnchor(at: index, rawToken: rawToken) else { return }
                onMentionClick(attachment.presentation, anchor)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func hiddenSpoiler(at point: NSPoint) -> NSRange? {
        SelectableTextSpoilerGeometry.hiddenSpoilerRange(at: point, in: self)
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
              as? MentionTextAttachment, attachment.presentation.isInteractive
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
            longestEffectiveRange: &range,
            in: NSRange(location: 0, length: attributedString().length)
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
        SelectableTextSpoilerGeometry.draw(in: self, dirtyRect: dirtyRect)
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let value = RichMessageCopySerializer.string(from: attributedString(), range: range)
        Pasteboard.copy(value)
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
