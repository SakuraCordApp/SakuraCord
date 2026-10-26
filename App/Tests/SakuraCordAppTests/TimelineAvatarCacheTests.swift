import AppKit
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test(arguments: [false, true], [false, true])
func `timeline replaces cached avatar placeholders without hover`(
    detachesConversation: Bool, finishesBeforeEnqueue: Bool
) async throws {
    let url = URL(fileURLWithPath: "/tmp/avatar-cache-\(UUID()).png")
    let key = NativeTimelineMediaKey.avatar(url)
    let message = Message(
        id: MessageID(rawValue: 8_900),
        channelID: ChannelID(rawValue: 8_901),
        author: User(
            id: UserID(rawValue: 8_902),
            username: "avatar.fixture",
            displayName: "Avatar Fixture",
            avatarURL: url
        ),
        content: "Avatar cache regression"
    )
    let item = NativeMessageTimelineItem.message(
        MessageRowPresentation(
            message: message,
            startsGroup: true,
            startsDay: false,
            replyPreview: nil,
            isReplyAvailable: false
        ),
        isUnreadBoundary: false,
        isHighlighted: false
    )
    let layout = NativeTimelineRowLayout.make(item: item, width: 560)
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: 560, height: layout.height)
    )
    canvas.storage.items = [item]
    canvas.storage.layouts = [layout]
    canvas.storage.rowOrigins = [0]
    canvas.storage.contentHeight = layout.height
    let scrollView = NSScrollView(frame: canvas.frame)
    scrollView.documentView = canvas
    #expect(canvas.rowFrame(at: 0).intersects(scrollView.documentVisibleRect))
    let store = NativeTimelineMediaStore.shared
    defer {
        scrollView.documentView = nil
        canvas.clearBitmapCache(keepingCapacity: false)
        store.releaseVisibleImages(owner: canvas.visibleMediaPinOwner)
        store.evictVolatileImageForTesting(for: key)
    }

    _ = canvas.bitmap(
        for: item, at: 0, layout: layout, width: 560,
        preparedMediaKeys: [key]
    )
    #expect(canvas.cachedBitmap(for: item, width: 560) != nil)
    func finishSharedLoad() {
        store.retainVisibleImages(for: [key], owner: canvas.visibleMediaPinOwner)
        store.cacheImageForTesting(NSImage(size: NSSize(width: 32, height: 32)), for: key)
    }
    if finishesBeforeEnqueue { finishSharedLoad() }
    if !finishesBeforeEnqueue {
        canvas.enqueueVisibleMediaRequests(identifier: item.identifier, keys: [key])
    }
    if detachesConversation {
        canvas.invalidateConversationTransientCaches()
    }
    if !finishesBeforeEnqueue { finishSharedLoad() }
    if !detachesConversation, !finishesBeforeEnqueue {
        let request = try #require(canvas.visibleMediaRequestTask)
        await request.value
        let invalidation = try #require(canvas.mediaInvalidationTask)
        await invalidation.value
        #expect(canvas.bitmapCache[item.identifier] == nil)
    }

    // Exercise the real draw ordering: enqueue requests, validate the cached
    // pixels, then raster. A cache hit here needs no later invalidation.
    let representation = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 560,
        pixelsHigh: Int(ceil(layout.height)), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    let context = try #require(NSGraphicsContext(bitmapImageRep: representation))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    canvas.draw(canvas.bounds)
    #expect(canvas.rowRasterCount == 2)
    #expect(canvas.bitmapCache[item.identifier]?.missingMediaKeys.isEmpty == true)
    #expect(canvas.cachedBitmap(for: item, width: 560) != nil)
    #expect(canvas.mediaInvalidationTask == nil)
    #expect(canvas.pendingMediaInvalidations.isEmpty)

    // Repeated draws must keep the repaired row warm without new work.
    canvas.draw(canvas.bounds)
    #expect(canvas.rowRasterCount == 2)
    #expect(canvas.visibleMediaRequestTask == nil)
    #expect(canvas.pendingVisibleMediaRequests.isEmpty)
    #expect(canvas.mediaInvalidationTask == nil)
    #expect(canvas.pendingMediaInvalidations.isEmpty)
}
