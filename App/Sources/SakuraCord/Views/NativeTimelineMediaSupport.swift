import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

nonisolated enum NativeTimelineMediaMemoryPolicy {
    static let sharedStaticImageBytes = 32 * 1_024 * 1_024
    static let timelineImageBytes = 32 * 1_024 * 1_024
    static let pinnedImageBytes = 16 * 1_024 * 1_024
    static let sharedAnimatedImageBytes = 24 * 1_024 * 1_024
    static let displayedAnimatedImageBytes = 16 * 1_024 * 1_024
    static let timelineAnimatedImageBytes = 16 * 1_024 * 1_024
    static let rowBitmapBytes = 32 * 1_024 * 1_024

    /// Explicit cost limits for decoded image and row-bitmap caches. This does
    /// not claim to include encoded media data, Lottie objects, decoder
    /// temporaries, or AVFoundation buffers.
    static let decodedImageCacheBytes =
        sharedStaticImageBytes
        + timelineImageBytes
        + pinnedImageBytes
        + sharedAnimatedImageBytes
        + displayedAnimatedImageBytes
        + timelineAnimatedImageBytes
        + rowBitmapBytes

    static let declaredMemoryCacheBytes =
        decodedImageCacheBytes + SharedMediaDataMemoryPolicy.retainedBytes
}

struct NativeTimelineMediaKey: Hashable {
    let url: URL
    let fallbackURL: URL?
    let maximumPixelDimension: Int

    static func avatar(_ url: URL) -> Self {
        Self(url: url, fallbackURL: nil, maximumPixelDimension: 96)
    }

    static func avatarDecoration(_ url: URL) -> Self {
        Self(url: url, fallbackURL: nil, maximumPixelDimension: 128)
    }

    static func media(
        _ url: URL,
        fallbackURL: URL? = nil,
        maximumPixelDimension: Int = 1_024
    ) -> Self {
        Self(
            url: url,
            fallbackURL: fallbackURL == url ? nil : fallbackURL,
            maximumPixelDimension: maximumPixelDimension
        )
    }

    static func attachment(_ attachment: Attachment) -> Self? {
        switch attachment.mediaKind {
        case .image, .animatedImage:
            let displayURL = attachment.proxyURL ?? attachment.url
            return .media(
                displayURL,
                fallbackURL: displayURL == attachment.url
                    ? nil
                    : attachment.url
            )
        case .video, .audio, .file:
            return nil
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // A fallback changes how the same primary resource can be loaded, not
        // its decoded-image identity. Keeping it out of equality lets an
        // optimistic local attachment acquire a CDN fallback without losing
        // the image already retained by the timeline.
        lhs.url == rhs.url
            && lhs.maximumPixelDimension == rhs.maximumPixelDimension
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(maximumPixelDimension)
    }

    var cacheKey: NSString {
        "\(url.absoluteString)#native-timeline-pixel-max=\(maximumPixelDimension)"
            as NSString
    }

    var loadURLs: [URL] {
        if let fallbackURL, fallbackURL != url {
            return [url, fallbackURL]
        }
        return [url]
    }
}

nonisolated final class SharedDecodedImageBox: NSObject, @unchecked Sendable {
    let image: CGImage
    let cost: Int

    init(_ image: CGImage) {
        self.image = image
        cost = max(1, image.bytesPerRow * image.height)
    }
}

actor SharedDecodedImageLoader {
    static let shared = SharedDecodedImageLoader()

    private struct InFlightRequest {
        let id: UUID
        let task: Task<CGImage?, Never>
        var waiterIDs: Set<UUID>
        var priority: MediaLoadPriority
    }

    struct RequestKey: Hashable, Sendable {
        let url: URL
        let maximumPixelDimension: Int

        var cacheKey: NSString {
            "\(url.absoluteString)#shared-static-pixel-max=\(maximumPixelDimension)"
                as NSString
        }
    }

    private let cache: NSCache<NSString, SharedDecodedImageBox> = {
        let cache = NSCache<NSString, SharedDecodedImageBox>()
        cache.totalCostLimit =
            NativeTimelineMediaMemoryPolicy.sharedStaticImageBytes
        cache.countLimit = 256
        return cache
    }()
    private var inFlight: [RequestKey: InFlightRequest] = [:]
    private let dataLoader: SharedMediaDataLoader
    private let decodeScheduler: NativeTimelineMediaDecodeScheduler

    init(
        dataLoader: SharedMediaDataLoader = .shared,
        decodeScheduler: NativeTimelineMediaDecodeScheduler = .shared
    ) {
        self.dataLoader = dataLoader
        self.decodeScheduler = decodeScheduler
    }

    func image(
        for url: URL,
        maximumPixelDimension: Int,
        priority: MediaLoadPriority
    ) async -> CGImage? {
        let key = RequestKey(
            url: url,
            maximumPixelDimension: max(1, maximumPixelDimension)
        )
        if let cached = cache.object(forKey: key.cacheKey) {
            return cached.image
        }

        let waiterID = UUID()
        let requestID: UUID
        let task: Task<CGImage?, Never>
        if var request = inFlight[key] {
            request.waiterIDs.insert(waiterID)
            let promotesToVisible =
                priority == .visible && request.priority == .prefetch
            if promotesToVisible {
                request.priority = .visible
            }
            inFlight[key] = request
            if promotesToVisible {
                await dataLoader.promoteRemoteLoad(for: url)
                await decodeScheduler.promoteWaiter(request.id)
            }
            requestID = request.id
            task = request.task
        } else {
            let createdRequestID = UUID()
            requestID = createdRequestID
            let dataLoader = self.dataLoader
            let decodeScheduler = self.decodeScheduler
            task = Task { [weak self] in
                do {
                    let data = try await dataLoader.data(
                        for: url,
                        priority: priority
                    )
                    try Task.checkCancellation()
                    let effectivePriority = await self?.priority(
                        for: key,
                        requestID: createdRequestID
                    ) ?? priority
                    return await decodeScheduler.decode(
                        data,
                        maximumPixelDimension: key.maximumPixelDimension,
                        priority: effectivePriority,
                        waiterID: createdRequestID
                    )
                } catch {
                    return nil
                }
            }
            inFlight[key] = InFlightRequest(
                id: requestID,
                task: task,
                waiterIDs: [waiterID],
                priority: priority
            )
        }

        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    requestID: requestID,
                    for: key
                )
            }
        }
        if Task.isCancelled {
            cancelWaiter(waiterID, requestID: requestID, for: key)
            return nil
        }
        return finishWaiter(
            waiterID,
            requestID: requestID,
            for: key,
            image: image
        )
    }

    func promoteImageLoad(
        for url: URL,
        maximumPixelDimension: Int
    ) async {
        let key = RequestKey(
            url: url,
            maximumPixelDimension: max(1, maximumPixelDimension)
        )
        guard var request = inFlight[key],
              request.priority == .prefetch
        else { return }
        request.priority = .visible
        inFlight[key] = request
        await dataLoader.promoteRemoteLoad(for: url)
        await decodeScheduler.promoteWaiter(request.id)
    }

    private func priority(
        for key: RequestKey,
        requestID: UUID
    ) -> MediaLoadPriority? {
        guard let request = inFlight[key], request.id == requestID else {
            return nil
        }
        return request.priority
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        requestID: UUID,
        for key: RequestKey
    ) {
        guard var request = inFlight[key],
              request.id == requestID,
              request.waiterIDs.remove(waiterID) != nil
        else { return }
        if request.waiterIDs.isEmpty {
            inFlight[key] = nil
            request.task.cancel()
        } else {
            inFlight[key] = request
        }
    }

    private func finishWaiter(
        _ waiterID: UUID,
        requestID: UUID,
        for key: RequestKey,
        image: CGImage?
    ) -> CGImage? {
        guard var request = inFlight[key],
              request.id == requestID,
              request.waiterIDs.remove(waiterID) != nil
        else { return nil }
        if request.waiterIDs.isEmpty {
            inFlight[key] = nil
        } else {
            inFlight[key] = request
        }
        if let image {
            let box = SharedDecodedImageBox(image)
            cache.setObject(box, forKey: key.cacheKey, cost: box.cost)
        }
        return image
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

    typealias DecodedImageLoad = (
        URL,
        Int,
        MediaLoadPriority
    ) async -> CGImage?
    typealias DecodedImagePromotion = (URL, Int) async -> Void

    struct AnimatedSubscriberID: Hashable {
        let owner: UUID
        let row: NativeMessageTimelineItem.Identifier
    }

    struct StaticSubscriberID: Hashable {
        let owner: UUID
        let row: NativeMessageTimelineItem.Identifier
    }

    struct CachedImage {
        let image: NSImage
        let cost: Int
    }

    struct PinnedImageReference {
        let image: NSImage
        let cost: Int
        var ownerCount: Int
    }

    static let imageCacheCostLimit =
        NativeTimelineMediaMemoryPolicy.timelineImageBytes
    static let imageCacheCountLimit = 192
    static let pinnedImageCostLimit =
        NativeTimelineMediaMemoryPolicy.pinnedImageBytes

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
    var loadingPriorities: [NativeTimelineMediaKey: MediaLoadPriority] = [:]
    var loadingTaskIDs: [NativeTimelineMediaKey: UUID] = [:]
    var loadingTasks: [NativeTimelineMediaKey: Task<Void, Never>] = [:]
    var subscribers:
        [NativeTimelineMediaKey:
            [StaticSubscriberID: (NativeTimelineStaticMediaLoadOutcome) -> Void]] = [:]
    let animatedCache: NSCache<NSString, NativeTimelineAnimatedMedia> = {
        let cache = NSCache<NSString, NativeTimelineAnimatedMedia>()
        cache.countLimit = 32
        cache.totalCostLimit =
            NativeTimelineMediaMemoryPolicy.timelineAnimatedImageBytes
        return cache
    }()
    var animatedLoading: Set<NativeTimelineMediaKey> = []
    var animatedLoadingTaskIDs: [NativeTimelineMediaKey: UUID] = [:]
    var animatedLoadingTasks:
        [NativeTimelineMediaKey: Task<Void, Never>] = [:]
    var animatedSubscribers:
        [NativeTimelineMediaKey: [AnimatedSubscriberID: () -> Void]] = [:]
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
    private let decodedImageLoad: DecodedImageLoad
    private let decodedImagePromotion: DecodedImagePromotion

    init() {
        decodedImageLoad = Self.loadDecodedImage
        decodedImagePromotion = Self.promoteDecodedImageLoad
    }

    init(
        decodedImageLoad: @escaping DecodedImageLoad,
        decodedImagePromotion: @escaping DecodedImagePromotion = { _, _ in }
    ) {
        self.decodedImageLoad = decodedImageLoad
        self.decodedImagePromotion = decodedImagePromotion
    }

    private nonisolated static func loadDecodedImage(
        _ url: URL,
        _ dimension: Int,
        _ priority: MediaLoadPriority
    ) async -> CGImage? {
        await SharedDecodedImageLoader.shared.image(
            for: url,
            maximumPixelDimension: dimension,
            priority: priority
        )
    }

    private nonisolated static func promoteDecodedImageLoad(
        _ url: URL,
        _ dimension: Int
    ) async {
        await SharedDecodedImageLoader.shared.promoteImageLoad(
            for: url,
            maximumPixelDimension: dimension
        )
    }

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
        owner: UUID,
        subscriber: NativeMessageTimelineItem.Identifier,
        completion: @escaping () -> Void
    ) {
        guard animatedCache.object(forKey: key.cacheKey) == nil else {
            return
        }
        let subscriberID = AnimatedSubscriberID(
            owner: owner,
            row: subscriber
        )
        animatedSubscribers[key, default: [:]][subscriberID] = completion
        guard animatedLoading.insert(key).inserted else { return }

        let loadID = UUID()
        animatedLoadingTaskIDs[key] = loadID
        let task = Task { [weak self] in
            let decoded: DecodedAnimatedImage?
            var loaded: DecodedAnimatedImage?
            for url in key.loadURLs where loaded == nil {
                guard !Task.isCancelled else { break }
                do {
                    loaded = try await SharedAnimatedImageLoader.shared.image(
                        for: url,
                        maximumPixelDimension: key.maximumPixelDimension
                    )
                } catch is CancellationError {
                    break
                } catch {
                    continue
                }
            }
            decoded = loaded
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard animatedLoadingTaskIDs[key] == loadID else { return }
            animatedLoadingTaskIDs[key] = nil
            animatedLoadingTasks[key] = nil
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
        animatedLoadingTasks[key] = task
    }

    func cancelAnimatedRequests(owner: UUID) {
        for key in Array(animatedSubscribers.keys) {
            guard var subscriptions = animatedSubscribers[key] else {
                continue
            }
            subscriptions = subscriptions.filter { subscriber, _ in
                subscriber.owner != owner
            }
            if subscriptions.isEmpty {
                animatedSubscribers[key] = nil
                animatedLoadingTasks.removeValue(forKey: key)?.cancel()
                animatedLoadingTaskIDs[key] = nil
                animatedLoading.remove(key)
            } else {
                animatedSubscribers[key] = subscriptions
            }
        }
    }

    func request(
        _ key: NativeTimelineMediaKey,
        owner: UUID,
        subscriber: NativeMessageTimelineItem.Identifier,
        priority: MediaLoadPriority = .visible,
        completion: @escaping (NativeTimelineStaticMediaLoadOutcome) -> Void
    ) {
        guard image(for: key) == nil else { return }
        let subscriberID = StaticSubscriberID(owner: owner, row: subscriber)
        subscribers[key, default: [:]][subscriberID] = completion
        guard loading.insert(key).inserted else {
            guard priority == .visible,
                  loadingPriorities[key] == .prefetch,
                  let loadID = loadingTaskIDs[key]
            else { return }
            loadingPriorities[key] = .visible
            let decodedImagePromotion = decodedImagePromotion
            Task { [weak self] in
                for url in key.loadURLs {
                    guard self?.loadingTaskIDs[key] == loadID else { return }
                    await decodedImagePromotion(
                        url,
                        key.maximumPixelDimension
                    )
                }
            }
            return
        }

        let loadID = UUID()
        loadingPriorities[key] = priority
        loadingTaskIDs[key] = loadID
        let task = Task { [weak self] in
            guard let decodedImageLoad = self?.decodedImageLoad else { return }
            let image: NSImage?
            var decoded: CGImage?
            for url in key.loadURLs where decoded == nil {
                guard !Task.isCancelled else { break }
                let effectivePriority = self?.loadingPriorities[key] ?? priority
                decoded = await decodedImageLoad(
                    url,
                    key.maximumPixelDimension,
                    effectivePriority
                )
            }
            guard !Task.isCancelled else { return }
            image = decoded.map {
                NSImage(
                    cgImage: $0,
                    size: NSSize(width: $0.width, height: $0.height)
                )
            }
            guard let self else { return }
            guard loadingTaskIDs[key] == loadID else { return }
            loadingTaskIDs[key] = nil
            loadingTasks[key] = nil
            loading.remove(key)
            loadingPriorities[key] = nil
            let completions = subscribers.removeValue(forKey: key)?.values ?? [:].values
            if let image {
                cacheImage(image, for: key)
            }
            for completion in completions {
                completion(image == nil ? .failed : .ready)
            }
        }
        loadingTasks[key] = task
    }

    func cancelStaticRequestsOutsideVisibleSet(owner: UUID) {
        let visibleKeys = visibleKeysByOwner[owner] ?? []
        removeStaticSubscriptions(
            owner: owner,
            where: { !visibleKeys.contains($0) },
            outcome: .cancelled
        )
    }

    /// Canvas teardown already closes its owned signpost explicitly. Remove
    /// its callbacks silently so another canvas sharing the same media key can
    /// keep the coalesced load and receive its own completion.
    func removeStaticRequests(owner: UUID) {
        removeStaticSubscriptions(owner: owner, where: { _ in true })
    }

    private func removeStaticSubscriptions(
        owner: UUID,
        where shouldRemove: (NativeTimelineMediaKey) -> Bool,
        outcome: NativeTimelineStaticMediaLoadOutcome? = nil
    ) {
        for key in Array(subscribers.keys) where shouldRemove(key) {
            guard var subscriptions = subscribers[key] else { continue }
            let removed = subscriptions.filter { $0.key.owner == owner }
            guard !removed.isEmpty else { continue }
            subscriptions = subscriptions.filter { $0.key.owner != owner }
            if subscriptions.isEmpty {
                subscribers[key] = nil
                loadingTasks.removeValue(forKey: key)?.cancel()
                loadingTaskIDs[key] = nil
                loading.remove(key)
                loadingPriorities[key] = nil
            } else {
                subscribers[key] = subscriptions
            }
            if let outcome {
                for completion in removed.values {
                    completion(outcome)
                }
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

actor NativeTimelineMediaDecodeScheduler {
    typealias DecodeOperation = @Sendable (Data, Int) -> CGImage?

    static let shared = NativeTimelineMediaDecodeScheduler()
    static let maximumConcurrentDecodes = 2
    static let maximumConcurrentPrefetchDecodes = 1

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<MediaLoadPriority?, Never>
    }

    private var activeCount = 0
    private var activePrefetchCount = 0
    private var visibleWaiters: [Waiter] = []
    private var prefetchWaiters: [Waiter] = []
    private let decodeOperation: DecodeOperation

    init(
        decodeOperation: @escaping DecodeOperation = { data, maximumPixelDimension in
            NativeTimelineMediaDecoder.decode(
                data,
                maximumPixelDimension: maximumPixelDimension
            )
        }
    ) {
        self.decodeOperation = decodeOperation
    }

    func decode(
        _ data: Data,
        maximumPixelDimension: Int,
        priority: MediaLoadPriority,
        waiterID: UUID = UUID()
    ) async -> CGImage? {
        let acquiredPriority = await withTaskCancellationHandler {
            await acquire(waiterID: waiterID, priority: priority)
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        guard let acquiredPriority, !Task.isCancelled else {
            if let acquiredPriority {
                release(priority: acquiredPriority)
            }
            return nil
        }

        let taskPriority: TaskPriority =
            acquiredPriority == .visible ? .userInitiated : .utility
        let worker: Task<CGImage?, Never> = Task.detached(
            priority: taskPriority
        ) { [decodeOperation] in
            guard !Task.isCancelled else { return nil }
            let image = AppPerformanceSignposts.measureSync(
                acquiredPriority == .visible
                    ? "TimelineVisibleStaticMediaDecode"
                    : "TimelinePrefetchStaticMediaDecode"
            ) {
                decodeOperation(data, maximumPixelDimension)
            }
            return Task.isCancelled ? nil : image
        }
        let image = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        release(priority: acquiredPriority)
        return Task.isCancelled ? nil : image
    }

    func promoteWaiter(_ id: UUID) {
        guard let index = prefetchWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = prefetchWaiters.remove(at: index)
        if activeCount < Self.maximumConcurrentDecodes {
            activeCount += 1
            waiter.continuation.resume(returning: .visible)
        } else {
            visibleWaiters.append(waiter)
        }
    }

    private func acquire(
        waiterID: UUID,
        priority: MediaLoadPriority
    ) async -> MediaLoadPriority? {
        guard !Task.isCancelled else { return nil }
        if activeCount < Self.maximumConcurrentDecodes,
           priority == .visible
            || activePrefetchCount < Self.maximumConcurrentPrefetchDecodes
        {
            activeCount += 1
            if priority == .prefetch {
                activePrefetchCount += 1
            }
            return priority
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let waiter = Waiter(
                    id: waiterID,
                    continuation: continuation
                )
                switch priority {
                case .visible:
                    visibleWaiters.append(waiter)
                case .prefetch:
                    prefetchWaiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = visibleWaiters.firstIndex(where: { $0.id == id }) {
            visibleWaiters.remove(at: index).continuation.resume(returning: nil)
            return
        }
        if let index = prefetchWaiters.firstIndex(where: { $0.id == id }) {
            prefetchWaiters.remove(at: index).continuation.resume(returning: nil)
        }
    }

    private func release(priority: MediaLoadPriority) {
        activeCount = max(0, activeCount - 1)
        if priority == .prefetch {
            activePrefetchCount = max(0, activePrefetchCount - 1)
        }
        if !visibleWaiters.isEmpty {
            activeCount += 1
            visibleWaiters.removeFirst().continuation.resume(returning: .visible)
        } else if !prefetchWaiters.isEmpty,
                  activePrefetchCount < Self.maximumConcurrentPrefetchDecodes
        {
            activeCount += 1
            activePrefetchCount += 1
            prefetchWaiters.removeFirst().continuation.resume(returning: .prefetch)
        }
    }

#if DEBUG
    struct Snapshot: Equatable, Sendable {
        let activeCount: Int
        let visibleWaiterCount: Int
        let prefetchWaiterCount: Int
    }

    func snapshot() -> Snapshot {
        Snapshot(
            activeCount: activeCount,
            visibleWaiterCount: visibleWaiters.count,
            prefetchWaiterCount: prefetchWaiters.count
        )
    }

    func acquirePermitForTesting(
        priority: MediaLoadPriority
    ) async -> Bool {
        await acquire(waiterID: UUID(), priority: priority) != nil
    }

    func releasePermitForTesting(priority: MediaLoadPriority) {
        release(priority: priority)
    }
#endif
}

enum NativeTimelineStaticMediaLoadOutcome: Equatable {
    case ready
    case failed
    case cancelled
}

enum NativeTimelineMediaDecoder {
    nonisolated static func decode(
        _ data: Data,
        maximumPixelDimension: Int
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
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
        editingItemIdentifier: NativeMessageTimelineItem.Identifier?
    ) -> Int? {
        guard let editingItemIdentifier,
              let rowIndex = rowIdentifiers.firstIndex(
                  of: editingItemIdentifier
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
            presentationDidChange?(isPresentationActive)
        }
    }

    @Published var isDeleteConfirmationPresented = false {
        didSet {
            guard oldValue != isDeleteConfirmationPresented else { return }
            presentationDidChange?(isPresentationActive)
        }
    }

    var isPresentationActive: Bool {
        isReactionPickerPresented || isDeleteConfirmationPresented
    }

    var presentationDidChange: ((Bool) -> Void)?
}

struct NativeTimelineActionCapsuleOverlay: View {
    let model: AppModel
    let message: Message
    let canEdit: Bool
    @ObservedObject var state: NativeTimelineActionCapsuleState
    let jumpToMessage: (() -> Void)?
    let retry: (() -> Void)?
    let edit: () -> Void
    let reply: (() -> Void)?
    let forward: (() -> Void)?
    let react: (String) -> Void
    let copy: () -> Void
    let copyLink: () -> Void
    let openThread: (() -> Void)?
    let delete: () -> Void

    var body: some View {
        Group {
            if let jumpToMessage {
                HoverActionPill {
                    HoverActionButton(
                        systemImage: NativeTimelineSearchResultPresentation
                            .jumpToMessageSystemImage,
                        help: "Jump to Message",
                        action: jumpToMessage
                    )
                }
            } else {
                MessageActionCapsule(
                    model: model,
                    message: message,
                    canEdit: canEdit,
                    isReactionPickerPresented: $state.isReactionPickerPresented,
                    isDeleteConfirmationPresented:
                        $state.isDeleteConfirmationPresented,
                    retry: retry,
                    edit: edit,
                    reply: reply,
                    forward: forward,
                    react: react,
                    copy: copy,
                    copyLink: copyLink,
                    openThread: openThread,
                    delete: delete
                )
            }
        }
        .fixedSize()
    }
}

struct MediaViewerTransitionSource {
    let itemID: String
    let image: NSImage
    let frameInWindow: CGRect
    let visibleFrameInWindow: CGRect
    let cornerRadius: CGFloat
    let fillsFrame: Bool
}

struct NativeTimelineMediaViewerPresentation: Identifiable {
    let id: UUID
    let messageID: MessageID?
    let items: [RichMediaItem]
    let selection: Int
    let authorName: String
    let authorAvatarURL: URL?
    let timestamp: Date
    let timelinePreviewImages: [String: NSImage]
    let transitionSource: MediaViewerTransitionSource?

    init(
        id: UUID = UUID(),
        messageID: MessageID? = nil,
        items: [RichMediaItem],
        selection: Int,
        authorName: String,
        authorAvatarURL: URL?,
        timestamp: Date,
        timelinePreviewImages: [String: NSImage] = [:],
        transitionSource: MediaViewerTransitionSource? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.items = items
        self.selection = selection
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.timestamp = timestamp
        self.timelinePreviewImages = timelinePreviewImages
        self.transitionSource = transitionSource
    }

    func withTimelinePreviewImages(
        _ timelinePreviewImages: [String: NSImage]
    ) -> Self {
        Self(
            id: id,
            messageID: messageID,
            items: items,
            selection: selection,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            timestamp: timestamp,
            timelinePreviewImages: timelinePreviewImages,
            transitionSource: transitionSource
        )
    }

    func withTransitionSource(
        _ transitionSource: MediaViewerTransitionSource
    ) -> Self {
        Self(
            id: id,
            messageID: messageID,
            items: items,
            selection: selection,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            timestamp: timestamp,
            timelinePreviewImages: timelinePreviewImages,
            transitionSource: transitionSource
        )
    }
}

enum NativeTimelineMediaViewerPlan {
    static func composerAttachments(
        _ attachments: [ForumPostAttachment],
        selectedAttachmentID: UUID,
        author: User
    ) -> NativeTimelineMediaViewerPresentation? {
        let items = attachments.enumerated().compactMap { index, attachment -> RichMediaItem? in
            var optimistic = OptimisticAttachmentPresentation.attachment(
                for: attachment.url,
                index: index,
                id: attachment.id.uuidString
            )
            optimistic.filename = attachment.filename
            optimistic.description = attachment.description
            optimistic.isSpoiler = attachment.isSpoiler
            guard optimistic.mediaKind == .image
                    || optimistic.mediaKind == .animatedImage
            else { return nil }
            return RichMediaItem(optimistic)
        }
        guard let selection = items.firstIndex(where: {
            $0.id == selectedAttachmentID.uuidString
        }) else { return nil }
        return NativeTimelineMediaViewerPresentation(
            items: items,
            selection: selection,
            authorName: author.displayName,
            authorAvatarURL: author.avatarURL,
            timestamp: .now
        )
    }

    static func attachments(
        in message: Message,
        selectedAttachmentID: String,
        isRevealed: (String) -> Bool = { _ in true }
    ) -> NativeTimelineMediaViewerPresentation? {
        let items = message.attachments.filter { attachment in
            !attachment.isSpoiler
                || isRevealed(
                    NativeTimelineComponentRevealKey
                        .attachmentComponentID(attachment.id)
                )
        }.map(RichMediaItem.init)
        return presentation(
            items: items,
            selectedID: selectedAttachmentID,
            message: message
        )
    }

    static func linkedImages(
        in message: Message,
        selectedReferenceID: String
    ) -> NativeTimelineMediaViewerPresentation? {
        let items = LinkedImagePresentation(content: message.content)
            .images.map { reference in
                RichMediaItem(
                    imageID: reference.id,
                    url: reference.url,
                    previewURL: reference.displayURL == reference.url
                        ? nil
                        : reference.displayURL,
                    title: reference.label
                )
            }
        return presentation(
            items: items,
            selectedID: selectedReferenceID,
            message: message
        )
    }

    static func components(
        in message: Message,
        layouts: [NativeTimelineComponentLayout],
        selectedComponentID: String,
        isRevealed: (String) -> Bool
    ) -> NativeTimelineMediaViewerPresentation? {
        let items = layouts.flatMap { layout -> [RichMediaItem] in
            let hiddenContainers = layout.containers.filter {
                $0.isSpoiler && !isRevealed($0.componentID)
            }
            func isVisible(_ frame: CGRect, isSpoiler: Bool, id: String) -> Bool {
                (!isSpoiler || isRevealed(id))
                    && !hiddenContainers.contains(where: {
                        $0.frame.contains(frame)
                    })
            }

            let images: [RichMediaItem] = layout.images.compactMap { region in
                guard isVisible(
                    region.frame,
                    isSpoiler: region.isSpoiler,
                    id: region.componentID
                ) else { return nil }
                return componentItem(
                    id: region.componentID,
                    url: region.openURL,
                    previewURL: region.displayURL,
                    title: region.description,
                    isVideo: false,
                    message: message
                )
            }
            let media: [RichMediaItem] = layout.media.compactMap { region in
                guard isVisible(
                    region.frame,
                    isSpoiler: region.isSpoiler,
                    id: region.componentID
                ) else { return nil }
                return componentItem(
                    id: region.componentID,
                    url: region.openURL,
                    previewURL: region.displayURL,
                    title: region.description,
                    isVideo: region.isVideo,
                    message: message
                )
            }
            let files: [RichMediaItem] = layout.files.compactMap { region in
                guard isVisible(
                    region.frame,
                    isSpoiler: region.isSpoiler,
                    id: region.componentID
                ) else { return nil }
                return componentImageFileItem(
                    region,
                    message: message
                )
            }
            return images + media + files
        }
        return presentation(
            items: items,
            selectedID: selectedComponentID,
            message: message
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
        return presentation(
            items: [item],
            selectedID: item.id,
            message: message
        )
    }

    private static func presentation(
        items: [RichMediaItem],
        selectedID: String,
        message: Message
    ) -> NativeTimelineMediaViewerPresentation? {
        guard let selection = items.firstIndex(where: {
            $0.id == selectedID
        }) else { return nil }
        return NativeTimelineMediaViewerPresentation(
            messageID: message.id,
            items: items,
            selection: selection,
            authorName: message.guildMember?.nickname
                ?? message.author.displayName,
            authorAvatarURL: message.guildMember?.avatarURL
                ?? message.author.avatarURL,
            timestamp: message.timestamp
        )
    }

    private static func componentItem(
        id: String,
        url: URL,
        previewURL: URL,
        title: String,
        isVideo: Bool,
        message: Message
    ) -> RichMediaItem {
        if var item = message.attachments
            .first(where: { $0.url == url })
            .map(RichMediaItem.init)
        {
            item.id = id
            item.title = title
            item.previewURL = previewURL == url ? item.previewURL : previewURL
            return item
        }
        return RichMediaItem(
            componentID: id,
            url: url,
            previewURL: previewURL == url ? nil : previewURL,
            title: title,
            isVideo: isVideo
        )
    }

    private static func componentImageFileItem(
        _ region: NativeTimelineComponentLayout.FileRegion,
        message: Message
    ) -> RichMediaItem? {
        if let attachment = message.attachments.first(where: {
            $0.url == region.openURL
        }) {
            var item = RichMediaItem(attachment)
            guard case .image = item.kind else { return nil }
            item.id = region.componentID
            item.title = region.title
            item.description = region.description
            return item
        }
        guard RichMediaItem.isSupportedImageURL(region.openURL) else {
            return nil
        }
        return RichMediaItem(
            imageID: region.componentID,
            url: region.openURL,
            title: region.title,
            description: region.description
        )
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
