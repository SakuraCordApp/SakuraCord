import AppKit
import ImageIO
import OSLog

actor SharedAnimatedImageLoader {
    static let shared = SharedAnimatedImageLoader()
    private static let cacheLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "AnimatedMediaPerformance")

    private struct InFlightRequest {
        let id: UUID
        let task: Task<DecodedAnimatedImage, any Error>
        var waiterIDs: Set<UUID>
    }

    private struct RequestKey: Hashable, Sendable {
        let url: URL
        let maximumPixelDimension: Int?

        var cacheKey: NSString {
            "\(url.absoluteString)#pixel-max=\(maximumPixelDimension ?? 0)" as NSString
        }
    }

    private let cache = NSCache<NSString, DecodedAnimatedImage>()
    private var inFlight: [RequestKey: InFlightRequest] = [:]

    init() {
        cache.totalCostLimit =
            MediaMemoryPolicy.sharedAnimatedImageBytes
        cache.countLimit = 96
    }

    func image(for url: URL, maximumPixelDimension: Int?) async throws -> DecodedAnimatedImage {
        let key = RequestKey(
            url: url,
            maximumPixelDimension: maximumPixelDimension.map { max(1, $0) }
        )
        if let cached = cache.object(forKey: key.cacheKey) { return cached }
        let waiterID = UUID()
        let requestID: UUID
        let task: Task<DecodedAnimatedImage, any Error>
        if var request = inFlight[key] {
            request.waiterIDs.insert(waiterID)
            inFlight[key] = request
            requestID = request.id
            task = request.task
        } else {
            requestID = UUID()
            task = Task {
                let data = try await SharedMediaDataLoader.shared.data(
                    for: url,
                    priority: .visible
                )
                try Task.checkCancellation()
                let preparedKey = url.isFileURL ? nil : PreparedAnimatedImage.key(
                    source: data, maximumPixelDimension: key.maximumPixelDimension
                )
                if let preparedKey,
                   let prepared = await SharedMediaDataLoader.shared.cachedPreparedMedia(for: preparedKey),
                   let image = await PreparedAnimatedImage.restore(prepared)
                {
                    try Task.checkCancellation()
                    if AppLaunchConfiguration.current.requestsGestureScrollBenchmark {
                        Self.cacheLogger.notice("Prepared animation cache hit: \(prepared.count, privacy: .public) bytes; \(image.frames.count, privacy: .public) frames")
                    }
                    return image
                }
                let image = try await SharedAnimatedImageDecodeScheduler.shared
                    .decode(
                        data: data,
                        maximumPixelDimension: key.maximumPixelDimension
                    )
                if let preparedKey,
                   let prepared = await PreparedAnimatedImage.archive(image),
                   !Task.isCancelled,
                   let mapped = await SharedMediaDataLoader.shared.storePreparedMedia(prepared, for: preparedKey),
                   let restored = await PreparedAnimatedImage.restore(mapped)
                {
                    try Task.checkCancellation()
                    return restored
                }
                try Task.checkCancellation()
                return image
            }
            inFlight[key] = InFlightRequest(
                id: requestID,
                task: task,
                waiterIDs: [waiterID]
            )
        }

        let result: Result<DecodedAnimatedImage, any Error>
        do {
            let image = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task {
                    await self.cancelWaiter(
                        waiterID,
                        requestID: requestID,
                        for: key
                    )
                }
            }
            result = .success(image)
        } catch {
            result = .failure(error)
        }
        if Task.isCancelled {
            cancelWaiter(
                waiterID,
                requestID: requestID,
                for: key
            )
            throw CancellationError()
        }
        return try finishWaiter(
            waiterID,
            requestID: requestID,
            for: key,
            result: result
        ).get()
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
        result: Result<DecodedAnimatedImage, any Error>
    ) -> Result<DecodedAnimatedImage, any Error> {
        guard var request = inFlight[key],
              request.id == requestID,
              request.waiterIDs.remove(waiterID) != nil
        else { return .failure(CancellationError()) }
        if request.waiterIDs.isEmpty {
            inFlight[key] = nil
        } else {
            inFlight[key] = request
        }
        if case let .success(image) = result {
            cache.setObject(
                image,
                forKey: key.cacheKey,
                cost: image.storedByteCount
            )
        }
        return result
    }
}

nonisolated enum AnimatedImageDecodePolicy {
    /// Full GIF/APNG/WebP frame expansion is memory-bandwidth intensive, and
    /// a burst of visible avatars and emoji would saturate several cores.
    /// Static first frames use the separate two-lane thumbnail scheduler, so
    /// animation expansion runs one at a time at background priority without
    /// delaying first paint.
    static let maximumConcurrentDecodes = 1
    static let taskPriority = TaskPriority.background
}

actor SharedAnimatedImageDecodeScheduler {
    static let shared = SharedAnimatedImageDecodeScheduler()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeCount = 0
    private var waiters: [Waiter] = []
    private var interactiveScrollingSources: Set<AnimatedImageInteractiveScrollSource> = []
    private var interactiveScrollingRevisions: [AnimatedImageInteractiveScrollSource: UInt64] = [:]

    private var defersForInteractiveScrolling: Bool {
        !interactiveScrollingSources.isEmpty
    }

    /// Full frame expansion is optional background work. Keep already decoded
    /// animations playing, but do not start another memory-bandwidth-heavy
    /// expansion while a timeline gesture is live. Static first-frame and
    /// ordinary thumbnail loading use separate schedulers and remain
    /// available for immediate visual feedback.
    func setInteractiveScrolling(
        _ isScrolling: Bool,
        source: AnimatedImageInteractiveScrollSource,
        revision: UInt64
    ) {
        guard revision >= interactiveScrollingRevisions[source, default: 0]
        else { return }
        interactiveScrollingRevisions[source] = revision
        if isScrolling {
            interactiveScrollingSources.insert(source)
        } else {
            interactiveScrollingSources.remove(source)
        }
        resumeNextIfPossible()
    }

    func decode(
        data: Data,
        maximumPixelDimension: Int?
    ) async throws -> DecodedAnimatedImage {
        while true {
            await AppScrollWorkGate.waitUntilInactive()
            try Task.checkCancellation()
            let waiterID = UUID()
            let acquired = await withTaskCancellationHandler {
                await acquire(waiterID: waiterID)
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            }
            guard acquired, !Task.isCancelled else {
                if acquired {
                    release()
                }
                throw CancellationError()
            }
            let task = Task.detached(
                priority: AnimatedImageDecodePolicy.taskPriority
            ) {
                try DecodedAnimatedImage(
                    data: data,
                    maximumPixelDimension: maximumPixelDimension,
                    shouldInterrupt: { AppScrollWorkGate.isActive }
                )
            }
            do {
                let image = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                release()
                return image
            } catch AnimatedImageDecodeInterruption.scrollActivity {
                release()
                AppPerformanceSignposts.signposter.emitEvent(
                    "AnimatedImageDecodeInterruptedForScroll"
                )
                try Task.checkCancellation()
            } catch {
                release()
                throw error
            }
        }
    }

    private func acquire(waiterID: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if !defersForInteractiveScrolling,
           activeCount
            < AnimatedImageDecodePolicy
                .maximumConcurrentDecodes
        {
            activeCount += 1
            return true
        }
        return await withCheckedContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(returning: false)
                return
            }
            waiters.append(Waiter(
                id: waiterID,
                continuation: continuation
            ))
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        activeCount = max(0, activeCount - 1)
        resumeNextIfPossible()
    }

    private func resumeNextIfPossible() {
        guard !defersForInteractiveScrolling else { return }
        while activeCount
                < AnimatedImageDecodePolicy.maximumConcurrentDecodes,
              !waiters.isEmpty
        {
            activeCount += 1
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

#if DEBUG
    var stateForTesting: AnimatedImageDecodeSchedulerState {
        AnimatedImageDecodeSchedulerState(
            activeCount: activeCount,
            waitingCount: waiters.count,
            isDeferred: defersForInteractiveScrolling
        )
    }
#endif
}

nonisolated enum AnimatedImageInteractiveScrollSource: Hashable, Sendable {
    case timeline
    case memberList(UUID)
}

nonisolated struct AnimatedImageDecodeSchedulerState: Equatable, Sendable {
    let activeCount: Int
    let waitingCount: Int
    let isDeferred: Bool
}
