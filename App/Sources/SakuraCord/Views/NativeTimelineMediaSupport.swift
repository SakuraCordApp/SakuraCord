import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

nonisolated final class SharedDecodedImageBox: NSObject, @unchecked Sendable {
    let image: CGImage
    let cost: Int

    init(_ image: CGImage) {
        self.image = image
        cost = max(1, image.bytesPerRow * image.height)
    }
}

nonisolated final class SharedDecodedImageCache: @unchecked Sendable {
    private let storage: NSCache<NSString, SharedDecodedImageBox> = {
        let cache = NSCache<NSString, SharedDecodedImageBox>()
        cache.totalCostLimit =
            MediaMemoryPolicy.sharedStaticImageBytes
        cache.countLimit = 256
        return cache
    }()

    func image(for key: NSString) -> CGImage? {
        storage.object(forKey: key)?.image
    }

    func insert(_ image: CGImage, for key: NSString) {
        let box = SharedDecodedImageBox(image)
        storage.setObject(box, forKey: key, cost: box.cost)
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
        var preparesForTimeline = false

        var cacheKey: NSString {
            "\(url.absoluteString)#shared-static-pixel-max=\(maximumPixelDimension)#timeline=\(preparesForTimeline)"
                as NSString
        }
    }

    nonisolated private let cache = SharedDecodedImageCache()
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

    nonisolated func cachedImage(
        for url: URL,
        maximumPixelDimension: Int,
        preparesForTimeline: Bool = false
    ) -> CGImage? {
        let key = RequestKey(
            url: url,
            maximumPixelDimension: max(1, maximumPixelDimension),
            preparesForTimeline: preparesForTimeline
        )
        return cache.image(for: key.cacheKey)
    }

    func image(
        for url: URL,
        maximumPixelDimension: Int,
        priority: MediaLoadPriority,
        preparesForTimeline: Bool = false
    ) async -> CGImage? {
        let key = RequestKey(
            url: url,
            maximumPixelDimension: max(1, maximumPixelDimension),
            preparesForTimeline: preparesForTimeline
        )
        if let cached = cachedImage(
            for: key.url,
            maximumPixelDimension: key.maximumPixelDimension,
            preparesForTimeline: key.preparesForTimeline
        ) {
            return cached
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
                // A local video's poster is its first frame.
                if LocalVideo.isVideo(url) {
                    return await LocalVideo.frame(at: url, maximumPixelDimension: key.maximumPixelDimension)
                }
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
                        waiterID: createdRequestID,
                        preparesForTimeline: key.preparesForTimeline
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
        maximumPixelDimension: Int,
        preparesForTimeline: Bool = false
    ) async {
        let key = RequestKey(
            url: url,
            maximumPixelDimension: max(1, maximumPixelDimension),
            preparesForTimeline: preparesForTimeline
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
            cache.insert(image, for: key.cacheKey)
        }
        return image
    }

#if DEBUG
    func waiterCountForTesting(
        for url: URL,
        maximumPixelDimension: Int
    ) -> Int {
        let key = RequestKey(
            url: url,
            maximumPixelDimension: max(1, maximumPixelDimension)
        )
        return inFlight[key]?.waiterIDs.count ?? 0
    }
#endif
}

enum NativeTimelineReplyMediaPolicy {
    static func avatarKey(
        for preview: MessageReplyPreview?
    ) -> MediaImageKey? {
        preview?.author.avatarURL.map(MediaImageKey.avatar)
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
        waiterID: UUID = UUID(),
        preparesForTimeline: Bool = false
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
                guard let image = decodeOperation(data, maximumPixelDimension) else { return nil as CGImage? }
                return preparesForTimeline
                    ? NativeTimelineMediaDecoder.prepareForTimeline(image)
                    : image
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
    nonisolated static func prepareForTimeline(_ image: CGImage) -> CGImage {
        // The row cache uses eight-bit device RGB. Perform high-bit-depth
        // color conversion once on the decode worker instead of repeating it
        // on the main thread whenever a row (or another tile) is drawn.
        // Other shared-image consumers retain the original color precision.
        guard image.bitsPerComponent > 8,
              let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    nonisolated static func decode(
        _ data: Data,
        maximumPixelDimension: Int
    ) -> CGImage? {
        if let lottie = LottieStickerFrameRenderer(
            data: data,
            maximumPixelDimension: maximumPixelDimension
        ) {
            return lottie.frame(at: 0)
        }
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
