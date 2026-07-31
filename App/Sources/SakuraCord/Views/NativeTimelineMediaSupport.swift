import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

struct NativeTimelineMediaKey: Hashable {
    let url: URL
    let maximumPixelDimension: Int

    static func avatar(_ url: URL) -> Self {
        Self(url: url, maximumPixelDimension: 96)
    }

    static func avatarDecoration(_ url: URL) -> Self {
        Self(url: url, maximumPixelDimension: 128)
    }

    static func media(_ url: URL, maximumPixelDimension: Int = 1_024) -> Self {
        Self(url: url, maximumPixelDimension: maximumPixelDimension)
    }

    var cacheKey: NSString {
        "\(url.absoluteString)#native-timeline-pixel-max=\(maximumPixelDimension)" as NSString
    }
}

enum NativeTimelineReplyMediaPolicy {
    static func avatarKey(
        for preview: MessageReplyPreview?
    ) -> NativeTimelineMediaKey? {
        preview?.author.avatarURL.map(NativeTimelineMediaKey.avatar)
    }
}

@MainActor
final class NativeTimelineAnimatedMedia {
    let decoded: DecodedAnimatedImage
    let firstFrame: NSImage?

    init(_ decoded: DecodedAnimatedImage) {
        self.decoded = decoded
        firstFrame = decoded.frames.first.map {
            NSImage(
                cgImage: $0,
                size: NSSize(width: $0.width, height: $0.height)
            )
        }
    }

    var isAnimated: Bool {
        decoded.frames.count > 1
            && decoded.frameDurations.reduce(0, +) > 0
    }
}

@MainActor
final class NativeTimelineMediaStore {
    static let shared = NativeTimelineMediaStore()

    struct CachedImage {
        let image: NSImage
        let cost: Int
    }

    struct PinnedImageReference {
        let image: NSImage
        let cost: Int
        var ownerCount: Int
    }

    static let imageCacheCostLimit = 48 * 1_024 * 1_024
    static let imageCacheCountLimit = 192
    static let pinnedImageCostLimit = 32 * 1_024 * 1_024

    // NSCache may discard every decoded image during ordinary memory pressure,
    // even while a cached row bitmap is still on screen. Hovering that row
    // switches to the direct painter, which then replaces the intact bitmap's
    // images with placeholders. A small explicit LRU gives this renderer a
    // predictable working set while preserving a hard decoded-pixel budget.
    var cachedImages: [NativeTimelineMediaKey: CachedImage] = [:]
    var imageCacheRecency: [NativeTimelineMediaKey] = []
    var imageCacheCost = 0
    var visibleKeysByOwner:
        [UUID: Set<NativeTimelineMediaKey>] = [:]
    var loading: Set<NativeTimelineMediaKey> = []
    var subscribers:
        [NativeTimelineMediaKey: [NativeMessageTimelineItem.Identifier: () -> Void]] = [:]
    let animatedCache: NSCache<NSString, NativeTimelineAnimatedMedia> = {
        let cache = NSCache<NSString, NativeTimelineAnimatedMedia>()
        cache.countLimit = 32
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()
    var animatedLoading: Set<NativeTimelineMediaKey> = []
    var animatedSubscribers:
        [NativeTimelineMediaKey: [NativeMessageTimelineItem.Identifier: () -> Void]] = [:]
    // Row bitmaps can outlive NSCache's volatile decoded-media entry. Keep
    // the exact source images used by each retained bitmap strongly reachable
    // so a hover/direct-paint pass cannot replace an already-visible
    // attachment with its loading placeholder. Owners are released together
    // with the bounded bitmap cache, keeping this retention bounded too.
    var pinnedKeysByOwner:
        [UUID: Set<NativeTimelineMediaKey>] = [:]
    var pinnedImages:
        [NativeTimelineMediaKey: PinnedImageReference] = [:]
    var pinnedImageCost = 0

    func image(for key: NativeTimelineMediaKey) -> NSImage? {
        if let pinned = pinnedImages[key] {
            return pinned.image
        }
        guard let cached = cachedImages[key] else { return nil }
        touchCachedImage(key)
        return cached.image
    }

    func firstAnimatedFrame(
        for key: NativeTimelineMediaKey
    ) -> NSImage? {
        animatedCache.object(forKey: key.cacheKey)?.firstFrame
    }

    func decodedAnimatedImage(
        for key: NativeTimelineMediaKey
    ) -> DecodedAnimatedImage? {
        guard let media = animatedCache.object(forKey: key.cacheKey),
              media.isAnimated
        else { return nil }
        return media.decoded
    }

    func decodedImage(
        for key: NativeTimelineMediaKey
    ) -> DecodedAnimatedImage? {
        animatedCache.object(forKey: key.cacheKey)?.decoded
    }

    func requestAnimated(
        _ key: NativeTimelineMediaKey,
        subscriber: NativeMessageTimelineItem.Identifier,
        completion: @escaping () -> Void
    ) {
        guard animatedCache.object(forKey: key.cacheKey) == nil else {
            return
        }
        animatedSubscribers[key, default: [:]][subscriber] = completion
        guard animatedLoading.insert(key).inserted else { return }

        Task { [weak self] in
            let decoded: DecodedAnimatedImage?
            do {
                decoded = try await SharedAnimatedImageLoader.shared.image(
                    for: key.url,
                    maximumPixelDimension: key.maximumPixelDimension
                )
            } catch {
                decoded = nil
            }
            guard let self else { return }
            animatedLoading.remove(key)
            let completions =
                animatedSubscribers.removeValue(forKey: key)?.values
                ?? [:].values
            if let decoded {
                let media = NativeTimelineAnimatedMedia(decoded)
                animatedCache.setObject(
                    media,
                    forKey: key.cacheKey,
                    cost: decoded.estimatedByteCount
                )
            }
            for completion in completions {
                completion()
            }
        }
    }

    func request(
        _ key: NativeTimelineMediaKey,
        subscriber: NativeMessageTimelineItem.Identifier,
        priority: MediaLoadPriority = .visible,
        completion: @escaping () -> Void
    ) {
        guard image(for: key) == nil else { return }
        subscribers[key, default: [:]][subscriber] = completion
        guard loading.insert(key).inserted else {
            if priority == .visible {
                Task {
                    await SharedMediaDataLoader.shared.promotePendingLoad(
                        for: key.url
                    )
                }
            }
            return
        }

        Task { [weak self] in
            let image: NSImage?
            do {
                let data = try await SharedMediaDataLoader.shared.data(
                    for: key.url,
                    priority: priority
                )
                let decodePriority: TaskPriority =
                    priority == .visible ? .userInitiated : .utility
                let decoded = await Task.detached(priority: decodePriority) {
                    NativeTimelineMediaDecoder.decode(
                        data,
                        maximumPixelDimension: key.maximumPixelDimension
                    )
                }.value
                image = decoded.map {
                    NSImage(
                        cgImage: $0,
                        size: NSSize(width: $0.width, height: $0.height)
                    )
                }
            } catch {
                image = nil
            }
            guard let self else { return }
            loading.remove(key)
            let completions = subscribers.removeValue(forKey: key)?.values ?? [:].values
            if let image {
                cacheImage(image, for: key)
            }
            for completion in completions {
                completion()
            }
        }
    }

    func pinLoadedImages(
        for keys: Set<NativeTimelineMediaKey>,
        owner: UUID
    ) {
        let previouslyLoadedKeys = pinnedKeysByOwner[owner] ?? []
        var loadedKeys = previouslyLoadedKeys.intersection(keys)

        for key in previouslyLoadedKeys.subtracting(keys) {
            releasePinnedImage(for: key)
        }
        for key in keys.subtracting(loadedKeys) {
            if var pinned = pinnedImages[key] {
                pinned.ownerCount += 1
                pinnedImages[key] = pinned
                loadedKeys.insert(key)
            } else if let image = cachedImages[key]?.image {
                let cost = Self.estimatedCost(of: image)
                guard pinnedImageCost + cost <= Self.pinnedImageCostLimit
                else { continue }
                pinnedImages[key] = PinnedImageReference(
                    image: image,
                    cost: cost,
                    ownerCount: 1
                )
                pinnedImageCost += cost
                loadedKeys.insert(key)
            }
        }
        if !loadedKeys.isEmpty {
            pinnedKeysByOwner[owner] = loadedKeys
        } else {
            pinnedKeysByOwner[owner] = nil
        }
    }

    func retainVisibleImages(
        for keys: Set<NativeTimelineMediaKey>,
        owner: UUID
    ) {
        if keys.isEmpty {
            visibleKeysByOwner[owner] = nil
        } else {
            visibleKeysByOwner[owner] = keys
        }
        // A row-bitmap owner may be the final strong reference after its
        // background LRU entry was trimmed. Promote that source back into the
        // protected decoded working set before the row switches to live paint.
        for key in keys where cachedImages[key] == nil {
            if let pinned = pinnedImages[key] {
                cacheImage(pinned.image, for: key)
            }
        }
        evictCachedImagesIfNeeded()
    }

    func releaseVisibleImages(owner: UUID) {
        visibleKeysByOwner[owner] = nil
        evictCachedImagesIfNeeded()
    }

    func releasePinnedImages(owner: UUID) {
        guard let keys = pinnedKeysByOwner.removeValue(forKey: owner)
        else { return }
        for key in keys {
            releasePinnedImage(for: key)
        }
    }

    func releasePinnedImage(for key: NativeTimelineMediaKey) {
        guard var pinned = pinnedImages[key] else { return }
        pinned.ownerCount -= 1
        if pinned.ownerCount <= 0 {
            pinnedImageCost -= pinned.cost
            pinnedImages[key] = nil
        } else {
            pinnedImages[key] = pinned
        }
    }

    static func estimatedCost(of image: NSImage) -> Int {
        let representation = image.representations.first
        let width = representation?.pixelsWide ?? Int(image.size.width)
        let height = representation?.pixelsHigh ?? Int(image.size.height)
        return max(1, width * height * 4)
    }

    func cacheImage(
        _ image: NSImage,
        for key: NativeTimelineMediaKey
    ) {
        let cost = Self.estimatedCost(of: image)
        if let previous = cachedImages.updateValue(
            CachedImage(image: image, cost: cost),
            forKey: key
        ) {
            imageCacheCost -= previous.cost
        }
        imageCacheCost += cost
        touchCachedImage(key)
        evictCachedImagesIfNeeded()
    }

    func touchCachedImage(_ key: NativeTimelineMediaKey) {
        imageCacheRecency.removeAll { $0 == key }
        imageCacheRecency.append(key)
    }

    func evictCachedImagesIfNeeded() {
        let visibleKeys = visibleKeysByOwner.values.reduce(
            into: Set<NativeTimelineMediaKey>()
        ) { $0.formUnion($1) }
        while imageCacheCost > Self.imageCacheCostLimit
            || cachedImages.count > Self.imageCacheCountLimit
        {
            guard let evictionIndex = imageCacheRecency.firstIndex(where: {
                !visibleKeys.contains($0)
            }) else {
                // The visible viewport is intrinsically bounded. Preserve it
                // intact even if an unusually dense gallery temporarily
                // exceeds the background LRU budget.
                return
            }
            let key = imageCacheRecency.remove(at: evictionIndex)
            if let removed = cachedImages.removeValue(forKey: key) {
                imageCacheCost -= removed.cost
            }
        }
    }

#if DEBUG
    var pinnedImageCostForTesting: Int {
        pinnedImageCost
    }

    var pinnedImageCostLimitForTesting: Int {
        Self.pinnedImageCostLimit
    }

    func cacheImageForTesting(
        _ image: NSImage,
        for key: NativeTimelineMediaKey
    ) {
        cacheImage(image, for: key)
    }

    func evictVolatileImageForTesting(
        for key: NativeTimelineMediaKey
    ) {
        imageCacheRecency.removeAll { $0 == key }
        if let removed = cachedImages.removeValue(forKey: key) {
            imageCacheCost -= removed.cost
        }
    }
#endif
}

enum NativeTimelineMediaDecoder {
    nonisolated static func decode(
        _ data: Data,
        maximumPixelDimension: Int
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelDimension),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

struct NativeTimelineInlineEmojiRegion {
    let rawToken: String
    let characterRange: NSRange
    let mediaFrame: CGRect
    let selectionFrame: CGRect?
}

enum NativeTimelineInlineEmojiGeometry {
    static func regions(
        in value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        selectionRange: NSRange?
    ) -> [NativeTimelineInlineEmojiRegion] {
        guard value.length > 0, frame.width > 0, frame.height > 0
        else { return [] }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return [] }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        var result: [NativeTimelineInlineEmojiRegion] = []
        for lineIndex in 0 ..< lines.count {
            let line = coreTextLine(lines[lineIndex])
            let lineOrigin = origins[lineIndex]
            let runs = CTLineGetGlyphRuns(line) as NSArray
            for case let run as CTRun in runs {
                let range = CTRunGetStringRange(run)
                guard range.location >= 0,
                      range.location < value.length,
                      let rawToken = value.attribute(
                          .discordEmojiToken,
                          at: range.location,
                          effectiveRange: nil
                      ) as? String
                else { continue }

                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let width = CGFloat(CTRunGetTypographicBounds(
                    run,
                    CFRange(location: 0, length: 0),
                    &ascent,
                    &descent,
                    &leading
                ))
                let horizontalPosition = lineOrigin.x + CTLineGetOffsetForStringIndex(
                    line,
                    range.location,
                    nil
                )
                let size = CGSize(
                    width: max(1, width),
                    height: max(1, ascent + descent)
                )
                let localBottom = lineOrigin.y - descent
                let mediaFrame = CGRect(
                    x: frame.minX + horizontalPosition,
                    y: frame.maxY - localBottom - size.height,
                    width: size.width,
                    height: size.height
                )
                let isSelected =
                    NativeTimelineTextSelectionGeometry.intersects(
                        characterRange: range,
                        selectionRange: selectionRange
                    )
                let selectionFrame = isSelected
                    ? NativeTimelineTextSelectionGeometry.rects(
                        in: textFrame,
                        outerFrame: frame,
                        range: NSRange(
                            location: range.location,
                            length: max(1, range.length)
                        )
                    ).first
                    : nil
                result.append(NativeTimelineInlineEmojiRegion(
                    rawToken: rawToken,
                    characterRange: NSRange(
                        location: range.location,
                        length: max(1, range.length)
                    ),
                    mediaFrame: mediaFrame,
                    selectionFrame: selectionFrame
                ))
            }
        }
        return result
    }
}

@MainActor
final class NativeTimelineCanvasStorage {
    var items: [NativeMessageTimelineItem] = []
    var layouts: [NativeTimelineRowLayout] = []
    var rowHeights: [CGFloat] = []
    var rowOrigins: [CGFloat] = []
    var contentHeight: CGFloat = 0
}

nonisolated final class NativeTimelineAccessibilityElement:
    NSAccessibilityElement
{
    let press: (@MainActor @Sendable () -> Bool)?

    nonisolated init(
        press: (@MainActor @Sendable () -> Bool)? = nil
    ) {
        self.press = press
        super.init()
    }

    nonisolated override func accessibilityActionNames()
        -> [NSAccessibility.Action]
    {
        press == nil ? [] : [.press]
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        let action = press
        return MainActor.assumeIsolated {
            action?() ?? false
        }
    }

    @MainActor
    func performPressIfAvailable() -> Bool {
        press?() ?? false
    }
}

@MainActor
final class NativeTimelineAccessibilityProxyView: NSView {
    nonisolated let press: (@MainActor @Sendable () -> Bool)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func isAccessibilityElement() -> Bool {
        true
    }

    init(source: NSAccessibilityElement) {
        if let source = source as? NativeTimelineAccessibilityElement {
            press = {
                source.performPressIfAvailable()
            }
        } else {
            press = nil
        }
        super.init(frame: .zero)
        setAccessibilityRole(source.accessibilityRole())
        setAccessibilitySubrole(source.accessibilitySubrole())
        setAccessibilityLabel(source.accessibilityLabel())
        setAccessibilityValue(source.accessibilityValue())
        setAccessibilityHelp(source.accessibilityHelp())
        setAccessibilityIdentifier(source.accessibilityIdentifier())
        setAccessibilityEnabled(source.isAccessibilityEnabled())
        setAccessibilityCustomActions(
            source.accessibilityCustomActions()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {}

    nonisolated override func accessibilityActionNames()
        -> [NSAccessibility.Action]
    {
        press == nil ? [] : [.press]
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        let action = press
        return MainActor.assumeIsolated {
            action?() ?? false
        }
    }
}

nonisolated enum NativeTimelineAccessibilityPresentation {
    static func attachmentLabel(_ attachment: Attachment) -> String {
        let label =
            nonblank(attachment.description)
            ?? nonblank(attachment.title)
            ?? attachment.filename
        if attachment.isSpoiler {
            return "Spoiler attachment, \(label)"
        }
        return label
    }

    static func stickerLabel(_ sticker: MessageSticker) -> String {
        nonblank(sticker.description) ?? sticker.name
    }

    static func threadLabel(_ thread: MessageThreadSummary) -> String {
        let replyCount = thread.messageCount
        return "\(thread.name), \(replyCount) "
            + (replyCount == 1 ? "reply" : "replies")
    }

    static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum NativeTimelineAccessibilityPolicy {
    static func bufferedViewport(
        around viewport: CGRect,
        contentHeight: CGFloat
    ) -> CGRect {
        let minY = max(0, viewport.minY - viewport.height)
        let maxY = min(
            max(minY, contentHeight),
            viewport.maxY + viewport.height
        )
        return CGRect(
            x: 0,
            y: minY,
            width: viewport.width,
            height: max(0, maxY - minY)
        )
    }

    static func showsMessageBody(
        messageID: MessageID,
        editingMessageID: MessageID?
    ) -> Bool {
        messageID != editingMessageID
    }

    static func editingOverlayInsertionIndex(
        in rowIdentifiers: [NativeMessageTimelineItem.Identifier],
        editingMessageID: MessageID?
    ) -> Int? {
        guard let editingMessageID,
              let rowIndex = rowIdentifiers.firstIndex(
                  of: .message(editingMessageID)
              )
        else { return nil }
        return rowIndex + 1
    }
}

nonisolated enum NativeTimelineEditingGeometry {
    static func rowHeight(
        avatarMaxY: CGFloat?,
        contentOriginY: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        max(
            avatarMaxY ?? 0,
            contentOriginY + contentHeight + 3
        )
    }
}

struct NativeTimelineComponentRevealKey: Hashable {
    let messageID: MessageID
    let componentID: String

    static func attachmentComponentID(_ attachmentID: String) -> String {
        "attachment:\(attachmentID)"
    }

    static func attachment(
        messageID: MessageID,
        attachmentID: String
    ) -> Self {
        Self(
            messageID: messageID,
            componentID: attachmentComponentID(attachmentID)
        )
    }
}

nonisolated enum NativeTimelineTransientRowGeometry {
    static func contentOriginY(
        base: CGFloat,
        heightDelta: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        guard base > minimum + 0.5 else { return base }
        return max(minimum, base - heightDelta)
    }

    static func contentHeight(
        base: CGFloat,
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        base + heightDelta(
            replacementHeight: replacementHeight,
            baseRowHeight: baseRowHeight
        )
    }

    static func rowOrigin(
        base: CGFloat,
        rowIndex: Int,
        replacementIndex: Int?,
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        guard let replacementIndex, rowIndex > replacementIndex else {
            return base
        }
        return base + heightDelta(
            replacementHeight: replacementHeight,
            baseRowHeight: baseRowHeight
        )
    }

    static func rowHeight(
        base: CGFloat,
        rowIndex: Int,
        replacementIndex: Int?,
        replacementHeight: CGFloat?
    ) -> CGFloat {
        guard rowIndex == replacementIndex, let replacementHeight else {
            return base
        }
        return replacementHeight
    }

    static func heightDelta(
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        guard let replacementHeight, let baseRowHeight else { return 0 }
        return replacementHeight - baseRowHeight
    }
}

@MainActor
final class NativeTimelineActionCapsuleState: ObservableObject {
    @Published var isReactionPickerPresented = false {
        didSet {
            guard oldValue != isReactionPickerPresented else { return }
            presentationDidChange?(isReactionPickerPresented)
        }
    }

    var presentationDidChange: ((Bool) -> Void)?
}

struct NativeTimelineActionCapsuleOverlay: View {
    let model: AppModel
    let message: Message
    let canEdit: Bool
    @ObservedObject var state: NativeTimelineActionCapsuleState
    let retry: (() -> Void)?
    let edit: () -> Void
    let reply: (() -> Void)?
    let react: (String) -> Void
    let copy: () -> Void
    let copyLink: () -> Void
    let openThread: (() -> Void)?
    let delete: () -> Void

    var body: some View {
        MessageActionCapsule(
            model: model,
            message: message,
            canEdit: canEdit,
            isReactionPickerPresented: $state.isReactionPickerPresented,
            retry: retry,
            edit: edit,
            reply: reply,
            react: react,
            copy: copy,
            copyLink: copyLink,
            openThread: openThread,
            delete: delete
        )
        .fixedSize()
    }
}

struct NativeTimelineMediaViewerPresentation: Identifiable {
    let id = UUID()
    let items: [RichMediaItem]
    let selection: Int
}

enum NativeTimelineMediaViewerPlan {
    static func attachments(
        in message: Message,
        selectedAttachmentID: String
    ) -> NativeTimelineMediaViewerPresentation? {
        guard let selection = message.attachments.firstIndex(where: {
            $0.id == selectedAttachmentID
        }) else { return nil }
        return NativeTimelineMediaViewerPresentation(
            items: message.attachments.map(RichMediaItem.init),
            selection: selection
        )
    }

    static func embed(
        in message: Message,
        id: String
    ) -> NativeTimelineMediaViewerPresentation? {
        guard let embed = message.embeds.first(where: { $0.id == id }),
              let item = RichMediaItem(
                  embed: embed,
                  attachments: message.attachments
              )
        else { return nil }
        return NativeTimelineMediaViewerPresentation(
            items: [item],
            selection: 0
        )
    }
}

@MainActor
final class NativeTimelineMediaViewerState: ObservableObject {
    @Published var presentation: NativeTimelineMediaViewerPresentation?

    func present(_ value: NativeTimelineMediaViewerPresentation) {
        presentation = value
    }

    func dismiss() {
        presentation = nil
    }
}

struct NativeTimelineMediaViewerLayer: View {
    @ObservedObject var state: NativeTimelineMediaViewerState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: $state.presentation) { presentation in
                MediaViewer(
                    items: presentation.items,
                    selection: presentation.selection,
                    close: state.dismiss
                )
            }
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
