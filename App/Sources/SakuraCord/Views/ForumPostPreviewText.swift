import AppKit
import SakuraCordModels
import SwiftUI

/// A forum post's message preview in the Inbox. It renders
/// the message's rich text, conceals hidden text spoilers like the timeline,
/// and reveals a spoiler in place when it is clicked. Every other click passes
/// through to the entry, which opens the post.
struct ForumPostPreviewText: NSViewRepresentable {
    let model: AppModel
    let message: Message
    let maximumNumberOfLines: Int
    let isEmphasized: Bool
    var textStyle: NSFont.TextStyle = .body
    var prefix: ForumPostPreviewTextView.Prefix?

    func makeNSView(context _: Context) -> ForumPostPreviewTextView {
        ForumPostPreviewTextView()
    }

    func updateNSView(_ view: ForumPostPreviewTextView, context _: Context) {
        view.configure(
            ForumPostPreviewTextView.Configuration(
                resolving: message,
                model: model,
                fontSize: NSFont.interfacePreferredFont(forTextStyle: textStyle).pointSize,
                maximumNumberOfLines: maximumNumberOfLines,
                isEmphasized: isEmphasized,
                underlinesLinks: model.accessibilitySettings.underlinesLinks,
                prefix: prefix
            ),
            revealStore: model.timelineSpoilerRevealStore
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView view: ForumPostPreviewTextView,
        context _: Context
    ) -> CGSize? {
        view.measuredSize(proposedWidth: proposal.width)
    }

    static func dismantleNSView(_ view: ForumPostPreviewTextView, coordinator _: Void) {
        view.stopObservingReveals()
    }
}

/// Lays out, conceals and draws a forum post preview. The Inbox hosts it in
/// `ForumPostPreviewTextView`; the forum board draws it straight into card
/// layers, so both share spoiler, emoji and truncation behaviour.
@MainActor
final class ForumPostPreviewTextRenderer {
    typealias Prefix = ForumPostPreviewTextView.Prefix
    typealias Configuration = ForumPostPreviewTextView.Configuration

    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()
    private(set) var configuration: Configuration?
    /// The message content without concealment. Reveal keys and
    /// accessibility use it; only the displayed copy conceals spoilers.
    private(set) var content = NSAttributedString()
    private var prefixLength = 0
    private weak var revealStore: NativeTimelineSpoilerRevealStore?
    private var revealObserverID: UUID?
    private(set) var hiddenSpoilerRanges: [NSRange] = []
    private(set) var hoveredSpoilerLocation: Int?
    private var imageLoadTask: Task<Void, Never>?
    /// Called whenever the displayed text changes without a new configuration:
    /// a spoiler reveal, a hover change or newly loaded inline images.
    var onDisplayChange: (() -> Void)?
    var size: CGSize = .zero {
        didSet {
            textContainer.containerSize = NSSize(width: max(1, size.width), height: .greatestFiniteMagnitude)
            if size != oldValue { noteDisplayChange() }
        }
    }

    /// Changes whenever what `draw(at:)` produces may change, unique across
    /// renderers, so a cached drawing of one revision is never reused for
    /// different text.
    private(set) var displayRevision = 0
    /// Changes only when the displayed text does, unlike `displayRevision`,
    /// which a new size also changes.
    private var textRevision = 0
    private static var nextDisplayRevision = 0

    private func noteDisplayChange() {
        Self.nextDisplayRevision &+= 1
        displayRevision = Self.nextDisplayRevision
    }

    init() {
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byTruncatingTail
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    isolated deinit {
        imageLoadTask?.cancel()
        if let revealObserverID {
            revealStore?.removeObserver(revealObserverID)
        }
    }

    func configure(
        _ configuration: Configuration,
        revealStore: NativeTimelineSpoilerRevealStore
    ) {
        if self.revealStore !== revealStore {
            stopObservingReveals()
            self.revealStore = revealStore
            revealObserverID = revealStore.observe { [weak self] messageID in
                guard let self, messageID == self.configuration?.messageID else { return }
                applySpoilerPresentation()
                onDisplayChange?()
            }
        }
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        textContainer.maximumNumberOfLines = configuration.maximumNumberOfLines
        rebuildContent()
        loadMissingImages()
    }

    func stopObservingReveals() {
        if let revealObserverID {
            revealStore?.removeObserver(revealObserverID)
        }
        revealObserverID = nil
        imageLoadTask?.cancel()
        imageLoadTask = nil
    }

    func measuredSize(proposedWidth: CGFloat?) -> CGSize {
        let width = RichMessageTextMeasurement.constrainedWidth(proposedWidth)
        textContainer.containerSize = NSSize(
            width: width ?? RichMessageTextMeasurement.maximumWidth,
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(
            width: width ?? max(1, ceil(used.width)),
            height: max(1, ceil(used.height))
        )
    }

    // MARK: Content

    private func rebuildContent() {
        guard let configuration else { return }
        let value = NSMutableAttributedString(
            attributedString: RichMessageAttributedText.make(
                source: configuration.source,
                emojiSize: configuration.emojiSize,
                baseFontSize: configuration.fontSize,
                mentionPresentations: configuration.mentionPresentations
            )
        )
        // Match the timeline: links underline only with the accessibility
        // setting, and a card that is not emphasized dims its other text.
        value.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: value.length)
        ) { link, range, _ in
            if link != nil {
                if configuration.underlinesLinks {
                    value.addAttribute(
                        .underlineStyle,
                        value: NativeTimelineLinkAppearance.hoverUnderlineStyle,
                        range: range
                    )
                }
            } else if !configuration.isEmphasized {
                value.addAttribute(
                    .foregroundColor,
                    value: NSColor.secondaryLabelColor,
                    range: range
                )
            }
        }
        content = value
        prefixLength = configuration.prefix?.value.length ?? 0
        applySpoilerPresentation()
    }

    var revealedLocations: Set<Int> {
        guard let configuration, let revealStore else { return [] }
        return revealStore.revealedTextLocations(
            messageID: configuration.messageID,
            contentID: NativeTimelineTextSpoilerRevealKey.messageContentID,
            value: content
        )
    }

    private func applySpoilerPresentation() {
        hiddenSpoilerRanges = NativeTimelineTextSpoilers.hiddenRanges(
            in: content,
            revealedLocations: revealedLocations
        )
        if let hoveredSpoilerLocation,
           !hiddenSpoilerRanges.contains(where: { $0.location == hoveredSpoilerLocation })
        {
            self.hoveredSpoilerLocation = nil
        }
        let displayed = NSMutableAttributedString()
        if let prefix = configuration?.prefix {
            displayed.append(prefix.value)
        }
        let body = NSMutableAttributedString(attributedString: content)
        // Links keep their color but, like the rest of the card, open the
        // post; Text Kit would otherwise add its own link underline.
        body.removeAttribute(.link, range: NSRange(location: 0, length: body.length))
        for range in hiddenSpoilerRanges {
            Self.conceal(body, range: range)
        }
        displayed.append(body)
        textStorage.setAttributedString(displayed)
        textRevision &+= 1
        noteDisplayChange()
    }

    /// Hides a spoiler's glyphs and inline images while keeping its
    /// layout, so revealing it does not reflow the preview.
    private static func conceal(_ value: NSMutableAttributedString, range: NSRange) {
        NativeTimelineSpoilerAppearance.concealText(in: value, range: range)
        value.enumerateAttribute(.attachment, in: range) { rawValue, attachmentRange, _ in
            guard let attachment = rawValue as? NSTextAttachment else { return }
            let placeholder = NSTextAttachment()
            placeholder.image = NSImage(size: attachment.bounds.size)
            placeholder.bounds = attachment.bounds
            value.addAttribute(.attachment, value: placeholder, range: attachmentRange)
        }
    }

    /// Inline images render from the shared caches. Rebuild once missing
    /// emoji and mention avatars have loaded.
    private func loadMissingImages() {
        imageLoadTask?.cancel()
        var emojiTokens = Set<String>()
        var avatarURLs = Set<URL>()
        content.enumerateAttributes(
            in: NSRange(location: 0, length: content.length)
        ) { attributes, _, _ in
            if let token = attributes[.discordEmojiToken] as? String,
               ComposerEmojiImageStore.shared.cachedImage(for: token) == nil
            {
                emojiTokens.insert(token)
            }
            if let url = (attributes[.attachment] as? MentionTextAttachment)?
                .presentation.avatarURL,
                MentionAvatarImageStore.shared.cachedImage(for: url) == nil
            {
                avatarURLs.insert(url)
            }
        }
        guard !emojiTokens.isEmpty || !avatarURLs.isEmpty else { return }
        imageLoadTask = Task { [weak self] in
            for token in emojiTokens {
                _ = await ComposerEmojiImageStore.shared.image(for: token)
            }
            for url in avatarURLs {
                _ = await MentionAvatarImageStore.shared.image(for: url)
            }
            guard !Task.isCancelled, let self else { return }
            rebuildContent()
            onDisplayChange?()
        }
    }

    // MARK: Geometry and drawing

    func hiddenSpoilerFrames(for range: NSRange) -> [CGRect] {
        let visibleGlyphs = layoutManager.glyphRange(for: textContainer)
        let glyphs = NSIntersectionRange(
            layoutManager.glyphRange(
                forCharacterRange: NSRange(
                    location: range.location + prefixLength,
                    length: range.length
                ),
                actualCharacterRange: nil
            ),
            visibleGlyphs
        )
        guard glyphs.length > 0 else { return [] }
        return SelectableTextSpoilerGeometry.rects(
            forGlyphRange: glyphs, manager: layoutManager,
            container: textContainer, bounds: CGRect(origin: .zero, size: size)
        )
    }

    func hiddenSpoilerLocation(at point: CGPoint) -> Int? {
        hiddenSpoilerRanges.first { range in
            hiddenSpoilerFrames(for: range).contains { $0.contains(point) }
        }?.location
    }

    private struct WorkerTextCache {
        let textRevision: Int
        let appearance: NSAppearance.Name
        let scale: CGFloat
        let text: ForumCardScene.ExcerptText
    }

    private struct AttachmentVariant: Hashable {
        let appearance: NSAppearance.Name
        let scale: CGFloat
    }

    /// An image's bitmap copies, one per appearance and scale: inline
    /// images such as mentions draw appearance-dependent colors.
    private final class AttachmentBitmaps {
        var byVariant: [AttachmentVariant: NSImage] = [:]
    }

    private var workerTextCache: WorkerTextCache?
    private static let attachmentBitmaps = NSMapTable<NSImage, AttachmentBitmaps>.weakToStrongObjects()

    /// Whether `workerText` can describe this text: hidden spoilers need
    /// main-thread geometry for their covers.
    var supportsWorkerText: Bool {
        hiddenSpoilerRanges.isEmpty && configuration != nil
    }

    /// The displayed text for laying out and drawing on a worker thread,
    /// with colors resolved for the current drawing appearance and inline
    /// images as bitmaps (their own drawing runs on the main thread). Nil
    /// while spoilers are hidden: their covers need main-thread geometry.
    func workerText(scale: CGFloat) -> ForumCardScene.ExcerptText? {
        guard supportsWorkerText, let configuration else { return nil }
        let appearance = NSAppearance.currentDrawing().name
        if let cached = workerTextCache, cached.textRevision == textRevision,
           cached.appearance == appearance, cached.scale == scale
        {
            return cached.text
        }
        let text = NSMutableAttributedString(attributedString: textStorage)
        let whole = NSRange(location: 0, length: text.length)
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineColor, .strikethroughColor] {
            text.enumerateAttribute(key, in: whole) { value, range, _ in
                guard let color = value as? NSColor, let resolved = NSColor(cgColor: color.cgColor) else { return }
                text.addAttribute(key, value: resolved, range: range)
            }
        }
        text.enumerateAttribute(.attachment, in: whole) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image else { return }
            let copy = NSTextAttachment()
            copy.image = Self.bitmap(of: image, appearance: appearance, scale: scale)
            copy.bounds = attachment.bounds
            text.addAttribute(.attachment, value: copy, range: range)
        }
        let result = ForumCardScene.ExcerptText(text: text, maximumLines: configuration.maximumNumberOfLines)
        workerTextCache = WorkerTextCache(textRevision: textRevision, appearance: appearance, scale: scale, text: result)
        return result
    }

    /// A bitmap copy of an image at the display's scale, drawn under the
    /// current appearance, cached per image, appearance and scale.
    private static func bitmap(of image: NSImage, appearance: NSAppearance.Name, scale: CGFloat) -> NSImage {
        let variant = AttachmentVariant(appearance: appearance, scale: scale)
        let bitmaps = attachmentBitmaps.object(forKey: image) ?? {
            let value = AttachmentBitmaps()
            attachmentBitmaps.setObject(value, forKey: image)
            return value
        }()
        if let cached = bitmaps.byVariant[variant] { return cached }
        let size = image.size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return image }
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: representation) else { return image }
        representation.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let copy = NSImage(size: size)
        copy.addRepresentation(representation)
        bitmaps.byVariant[variant] = copy
        return copy
    }

    /// Draws into the current flipped graphics context at `origin`.
    func draw(at origin: CGPoint) {
        for range in hiddenSpoilerRanges {
            NativeTimelineSpoilerAppearance.textBackgroundColor(
                isHovered: hoveredSpoilerLocation == range.location
            ).setFill()
            for frame in hiddenSpoilerFrames(for: range) {
                NSBezierPath(
                    roundedRect: frame.offsetBy(dx: origin.x, dy: origin.y),
                    xRadius: NativeTimelineSpoilerAppearance.textCornerRadius,
                    yRadius: NativeTimelineSpoilerAppearance.textCornerRadius
                ).fill()
            }
        }
        let glyphs = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    @discardableResult
    func setHoveredSpoiler(_ location: Int?) -> Bool {
        guard hoveredSpoilerLocation != location else { return false }
        hoveredSpoilerLocation = location
        noteDisplayChange()
        return true
    }

    func revealSpoiler(at location: Int) {
        guard let configuration, let revealStore else { return }
        revealStore.revealText(NativeTimelineTextSpoilerRevealKey(
            messageID: configuration.messageID,
            contentID: NativeTimelineTextSpoilerRevealKey.messageContentID,
            contentHash: content.string.hashValue,
            rangeLocation: location
        ))
    }

    var accessibilityText: String {
        (configuration?.prefix?.accessibilityText ?? "")
            + TimelineTextAccessibility.text(
                content,
                revealedLocations: revealedLocations
            )
    }
}

final class ForumPostPreviewTextView: NSView {
    struct Prefix: Equatable {
        let value: NSAttributedString
        let accessibilityText: String
    }

    struct Configuration: Equatable {
        let messageID: MessageID
        let source: String
        let mentionPresentations: [String: MentionPresentation]
        let fontSize: CGFloat
        let emojiSize: CGFloat
        let maximumNumberOfLines: Int
        let isEmphasized: Bool
        let underlinesLinks: Bool
        let prefix: Prefix?
    }

    private let renderer = ForumPostPreviewTextRenderer()
    private var hoverTrackingArea: NSTrackingArea?

    var content: NSAttributedString { renderer.content }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        renderer.onDisplayChange = { [weak self] in
            guard let self else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    func configure(
        _ configuration: Configuration,
        revealStore: NativeTimelineSpoilerRevealStore
    ) {
        let previous = renderer.configuration
        renderer.configure(configuration, revealStore: revealStore)
        guard previous != configuration else { return }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func stopObservingReveals() {
        renderer.stopObservingReveals()
    }

    func measuredSize(proposedWidth: CGFloat?) -> CGSize {
        renderer.measuredSize(proposedWidth: proposedWidth)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderer.size = newSize
    }

    func hiddenSpoilerFrames(for range: NSRange) -> [CGRect] {
        renderer.hiddenSpoilerFrames(for: range)
    }

    func hiddenSpoilerLocation(at point: CGPoint) -> Int? {
        renderer.hiddenSpoilerLocation(at: point)
    }

    override func draw(_: NSRect) {
        renderer.draw(at: .zero)
    }

    // MARK: Pointer

    /// Only hidden spoilers take clicks; the rest of the preview belongs to
    /// the card, which opens the post.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return hiddenSpoilerLocation(at: local) == nil ? nil : self
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let location = hiddenSpoilerLocation(
            at: convert(event.locationInWindow, from: nil)
        ) else {
            super.mouseDown(with: event)
            return
        }
        renderer.revealSpoiler(at: location)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHoveredSpoiler(hiddenSpoilerLocation(at: convert(event.locationInWindow, from: nil)))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredSpoiler(nil)
        super.mouseExited(with: event)
    }

    override func resetCursorRects() {
        for range in renderer.hiddenSpoilerRanges {
            for frame in hiddenSpoilerFrames(for: range) {
                addCursorRect(frame, cursor: .pointingHand)
            }
        }
    }

    private func setHoveredSpoiler(_ location: Int?) {
        if renderer.setHoveredSpoiler(location) { needsDisplay = true }
    }

    func revealSpoiler(at location: Int) {
        renderer.revealSpoiler(at: location)
    }

    // MARK: Accessibility

    override func accessibilityValue() -> Any? {
        renderer.accessibilityText
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let location = renderer.hiddenSpoilerRanges.first?.location else { return nil }
        return [
            NSAccessibilityCustomAction(name: "Reveal spoiler") { [weak self] in
                self?.revealSpoiler(at: location)
                return true
            },
        ]
    }
}

extension ForumPostPreviewTextView.Configuration {
    /// Resolves the message's mentions and sizes inline emoji from the body font.
    init(
        resolving message: Message,
        model: AppModel,
        fontSize: CGFloat,
        maximumNumberOfLines: Int,
        isEmphasized: Bool,
        underlinesLinks: Bool,
        prefix: ForumPostPreviewTextView.Prefix?
    ) {
        let resolver = MessageMentionResolver(model: model, message: message)
        let prepared = RichMessageAttributedText.prepare(source: message.content)
        var mentions: [String: MentionPresentation] = [:]
        for case let .mention(mention) in prepared.tokens {
            mentions[mention.rawToken] = resolver.presentation(mention)
        }
        self.init(
            messageID: message.id,
            source: message.content,
            mentionPresentations: mentions,
            fontSize: fontSize,
            emojiSize: (fontSize * 1.375).rounded(),
            maximumNumberOfLines: maximumNumberOfLines,
            isEmphasized: isEmphasized,
            underlinesLinks: underlinesLinks,
            prefix: prefix
        )
    }
}
