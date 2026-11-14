import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

nonisolated enum MediaMemoryPolicy {
    static let sharedStaticImageBytes = 32 * 1_024 * 1_024
    static let timelineImageBytes = 32 * 1_024 * 1_024
    static let pinnedImageBytes = 16 * 1_024 * 1_024
    static let sharedAnimatedImageBytes = 24 * 1_024 * 1_024
    static let displayedAnimatedImageBytes = 16 * 1_024 * 1_024
    static let animatedImagePosterBytes = 8 * 1_024 * 1_024
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
        + animatedImagePosterBytes
        + timelineAnimatedImageBytes
        + rowBitmapBytes
}

struct MediaImageKey: Hashable {
    let url: URL
    let fallbackURL: URL?
    let maximumPixelDimension: Int

    static let avatarPixelDimension = 96

    static func avatar(_ url: URL) -> Self {
        Self(url: url, fallbackURL: nil, maximumPixelDimension: avatarPixelDimension)
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

    static let videoPosterPixelDimension = 1_024

    /// A video this Mac sent keeps its own first frame, so its poster stays
    /// as the server's attachment replaces it; the server's poster stands
    /// in once the file is gone.
    static func videoPoster(_ attachment: Attachment) -> Self? {
        let remote = attachment.videoPosterURL(maximumPixelDimension: videoPosterPixelDimension)
        guard let local = attachment.localPreviewURL else { return remote.map { .media($0) } }
        return .media(local, fallbackURL: remote, maximumPixelDimension: videoPosterPixelDimension)
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

@MainActor
final class MediaImageStore {
    static let shared = MediaImageStore()

    typealias DecodedImageLoad = (
        URL,
        Int,
        MediaLoadPriority
    ) async -> CGImage?
    typealias DecodedImagePromotion = (URL, Int) async -> Void

    /// One subscription to a key: the owner, and whatever the owner names
    /// its subscriber by, such as a timeline row or a forum post.
    struct SubscriberID: Hashable {
        let owner: UUID
        let subscriber: AnyHashable
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
        MediaMemoryPolicy.timelineImageBytes
    static let imageCacheCountLimit = 192
    static let pinnedImageCostLimit =
        MediaMemoryPolicy.pinnedImageBytes

    // NSCache may discard every decoded image during ordinary memory pressure,
    // even while a cached row bitmap is still on screen. Hovering that row
    // switches to the direct painter, which then replaces the intact bitmap's
    // images with placeholders. A small explicit LRU gives this renderer a
    // predictable working set while preserving a hard decoded-pixel budget.
    var cachedImages: [MediaImageKey: CachedImage] = [:]
    var imageCacheRecency: [MediaImageKey] = []
    var imageCacheCost = 0
    var visibleKeysByOwner:
        [UUID: Set<MediaImageKey>] = [:]
    // Keep failures only while visible, so redraws cannot repeatedly fetch a
    // broken resource. Leaving and re-entering the viewport allows a retry,
    // as does a URL the key offers later, such as a fallback: each key keeps
    // every URL that failed for it.
    private var failedKeys: [MediaImageKey: Set<URL>] = [:]
    var loading: Set<MediaImageKey> = []
    var loadingPriorities: [MediaImageKey: MediaLoadPriority] = [:]
    var loadingTaskIDs: [MediaImageKey: UUID] = [:]
    var loadingTasks: [MediaImageKey: Task<Void, Never>] = [:]
    var subscribers:
        [MediaImageKey:
            [SubscriberID: (MediaImageLoadOutcome) -> Void]] = [:]
    let animatedCache: NSCache<NSString, NativeTimelineAnimatedMedia> = {
        let cache = NSCache<NSString, NativeTimelineAnimatedMedia>()
        cache.countLimit = 32
        cache.totalCostLimit =
            MediaMemoryPolicy.timelineAnimatedImageBytes
        return cache
    }()
    var animatedLoading: Set<MediaImageKey> = []
    var animatedLoadingTaskIDs: [MediaImageKey: UUID] = [:]
    var animatedLoadingTasks:
        [MediaImageKey: Task<Void, Never>] = [:]
    var animatedSubscribers:
        [MediaImageKey: [SubscriberID: () -> Void]] = [:]
    // Row bitmaps can outlive NSCache's volatile decoded-media entry. Keep
    // the exact source images used by each retained bitmap strongly reachable
    // so a hover/direct-paint pass cannot replace an already-visible
    // attachment with its loading placeholder. Owners are released together
    // with the bounded bitmap cache, keeping this retention bounded too.
    var pinnedKeysByOwner:
        [UUID: Set<MediaImageKey>] = [:]
    var pinnedImages:
        [MediaImageKey: PinnedImageReference] = [:]
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
            priority: priority,
            preparesForTimeline: true
        )
    }

    private nonisolated static func promoteDecodedImageLoad(
        _ url: URL,
        _ dimension: Int
    ) async {
        await SharedDecodedImageLoader.shared.promoteImageLoad(
            for: url,
            maximumPixelDimension: dimension,
            preparesForTimeline: true
        )
    }

    func image(for key: MediaImageKey) -> NSImage? {
        if let pinned = pinnedImages[key] {
            return pinned.image
        }
        guard let cached = cachedImages[key] else { return nil }
        touchCachedImage(key)
        return cached.image
    }

    func firstAnimatedFrame(
        for key: MediaImageKey
    ) -> NSImage? {
        animatedCache.object(forKey: key.cacheKey)?.firstFrame
    }

    func decodedAnimatedImage(
        for key: MediaImageKey
    ) -> DecodedAnimatedImage? {
        guard let media = animatedCache.object(forKey: key.cacheKey),
              media.isAnimated
        else { return nil }
        return media.decoded
    }

    func decodedImage(
        for key: MediaImageKey
    ) -> DecodedAnimatedImage? {
        animatedCache.object(forKey: key.cacheKey)?.decoded
    }

    func cacheDecodedImage(
        _ decoded: DecodedAnimatedImage,
        for key: MediaImageKey
    ) {
        let media = NativeTimelineAnimatedMedia(decoded)
        animatedCache.setObject(
            media,
            forKey: key.cacheKey,
            cost: decoded.storedByteCount
        )
        if let firstFrame = media.firstFrame {
            cacheImage(firstFrame, for: key)
        }
    }

    func requestAnimated(
        _ key: MediaImageKey,
        owner: UUID,
        subscriber: AnyHashable,
        completion: @escaping () -> Void
    ) {
        guard animatedCache.object(forKey: key.cacheKey) == nil else {
            return
        }
        let subscriberID = SubscriberID(owner: owner, subscriber: subscriber)
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
                    cost: decoded.storedByteCount
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

    /// Whether every URL `key` offers has failed; one it gained since, such
    /// as a fallback, is tried.
    private func hasFailed(_ key: MediaImageKey) -> Bool {
        failedKeys[key].map { Set(key.loadURLs).isSubset(of: $0) } ?? false
    }

    func request(
        _ key: MediaImageKey,
        owner: UUID,
        subscriber: AnyHashable,
        priority: MediaLoadPriority = .visible,
        completion: @escaping (MediaImageLoadOutcome) -> Void
    ) {
        guard image(for: key) == nil else { return }
        guard !hasFailed(key) else {
            completion(.failed)
            return
        }
        let subscriberID = SubscriberID(owner: owner, subscriber: subscriber)
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
            } else if visibleKeysByOwner.values.contains(where: { $0.contains(key) }) {
                failedKeys[key, default: []].formUnion(key.loadURLs)
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
        where shouldRemove: (MediaImageKey) -> Bool,
        outcome: MediaImageLoadOutcome? = nil
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
        for keys: Set<MediaImageKey>,
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
        for keys: Set<MediaImageKey>,
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

    func releasePinnedImage(for key: MediaImageKey) {
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
        for key: MediaImageKey
    ) {
        failedKeys[key] = nil
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

    func touchCachedImage(_ key: MediaImageKey) {
        imageCacheRecency.removeAll { $0 == key }
        imageCacheRecency.append(key)
    }

    func evictCachedImagesIfNeeded() {
        let visibleKeys = visibleKeysByOwner.values.reduce(
            into: Set<MediaImageKey>()
        ) { $0.formUnion($1) }
        failedKeys = failedKeys.filter { visibleKeys.contains($0.key) }
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
        for key: MediaImageKey
    ) {
        cacheImage(image, for: key)
    }

    func evictVolatileImageForTesting(
        for key: MediaImageKey
    ) {
        imageCacheRecency.removeAll { $0 == key }
        if let removed = cachedImages.removeValue(forKey: key) {
            imageCacheCost -= removed.cost
        }
    }
#endif
}

enum MediaImageLoadOutcome: Equatable {
    case ready
    case failed
    case cancelled
}
