import Foundation
import MediaPipeline

nonisolated enum SharedMediaDataMemoryPolicy {
    static let remoteBytes = 24 * 1_024 * 1_024
    static let localBytes = 32 * 1_024 * 1_024
    static let retainedBytes = remoteBytes + localBytes
}

actor SharedMediaDataLoader {
    static let shared = SharedMediaDataLoader()
    private static let remoteDiskCostLimit: Int64 = 512 * 1024 * 1024
    nonisolated private static let remoteSession = URLSession(
        configuration: remoteSessionConfiguration()
    )

    private struct RemoteWaiter {
        let priority: MediaLoadPriority
        let continuation: CheckedContinuation<Data, any Error>
    }

    private struct PendingRemoteLoad {
        var waiters: [UUID: RemoteWaiter]
        var isPromotedToVisible = false

        var priority: MediaLoadPriority {
            let hasVisibleWaiter = waiters.values.contains {
                $0.priority == .visible
            }
            return isPromotedToVisible || hasVisibleWaiter
                ? .visible
                : .prefetch
        }
    }

    private struct ActiveRemoteLoad {
        let id: UUID
        var priority: MediaLoadPriority
        var isPromotedToVisible: Bool
        var waiters: [UUID: RemoteWaiter]
        let task: Task<Void, Never>
    }

    private let localFileCache = NSCache<NSURL, NSData>()
    private let remoteDataCache = NSCache<NSURL, NSData>()
    private let remoteDiskCache: MediaCache?
    private let remoteFetch: @Sendable (URL) async throws -> Data
    private var localFileLoads: [URL: Task<Data, any Error>] = [:]
    private var pendingRemoteLoads: [URL: PendingRemoteLoad] = [:]
    private var pendingRemoteOrder: [URL] = []
    private var activeRemoteLoads: [URL: ActiveRemoteLoad] = [:]

    init() {
        remoteDiskCache = try? MediaCache(
            maximumBytes: Self.remoteDiskCostLimit
        )
        remoteFetch = Self.download
        localFileCache.totalCostLimit = SharedMediaDataMemoryPolicy.localBytes
        localFileCache.countLimit = 256
        remoteDataCache.totalCostLimit = SharedMediaDataMemoryPolicy.remoteBytes
        remoteDataCache.countLimit = 128
    }

    init(
        remoteFetch: @escaping @Sendable (URL) async throws -> Data
    ) {
        remoteDiskCache = nil
        self.remoteFetch = remoteFetch
        localFileCache.totalCostLimit = SharedMediaDataMemoryPolicy.localBytes
        localFileCache.countLimit = 256
        remoteDataCache.totalCostLimit = SharedMediaDataMemoryPolicy.remoteBytes
        remoteDataCache.countLimit = 128
    }

    func data(
        for url: URL,
        priority: MediaLoadPriority = .visible
    ) async throws -> Data {
        if url.isFileURL {
            return try await localData(for: url)
        }
        if let value = remoteDataCache.object(forKey: url as NSURL) {
            return value as Data
        }
        if let remoteDiskCache {
            do {
                if let value = try await remoteDiskCache.data(for: url) {
                    remoteDataCache.setObject(
                        value as NSData,
                        forKey: url as NSURL,
                        cost: value.count
                    )
                    return value
                }
            } catch {
                // A disposable cache failure must never prevent media loading.
            }
        }
        if let value = remoteDataCache.object(forKey: url as NSURL) {
            return value as Data
        }
        try Task.checkCancellation()
        let waiterID = UUID()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueRemoteLoad(
                    for: url,
                    priority: priority,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelRemoteWaiter(
                    waiterID,
                    for: url
                )
            }
        }
        try Task.checkCancellation()
        return data
    }

    func promoteRemoteLoad(for url: URL) {
        if var pending = pendingRemoteLoads[url] {
            pending.isPromotedToVisible = true
            pendingRemoteLoads[url] = pending
        }
        if var active = activeRemoteLoads[url] {
            active.priority = .visible
            active.isPromotedToVisible = true
            activeRemoteLoads[url] = active
        }
        startEligibleRemoteLoads()
    }

#if DEBUG
    struct RemoteLoadSnapshot: Equatable, Sendable {
        let pendingCount: Int
        let activeCount: Int
        let waiterCount: Int
    }

    func remoteLoadSnapshot() -> RemoteLoadSnapshot {
        RemoteLoadSnapshot(
            pendingCount: pendingRemoteLoads.count,
            activeCount: activeRemoteLoads.count,
            waiterCount:
                pendingRemoteLoads.values.reduce(0) {
                    $0 + $1.waiters.count
                }
                + activeRemoteLoads.values.reduce(0) {
                    $0 + $1.waiters.count
                }
        )
    }

    func remotePriorityForTesting(_ url: URL) -> MediaLoadPriority? {
        pendingRemoteLoads[url]?.priority
            ?? activeRemoteLoads[url]?.priority
    }
#endif

    private func localData(for url: URL) async throws -> Data {
        if let value = localFileCache.object(forKey: url as NSURL) {
            return value as Data
        }
        if let task = localFileLoads[url] {
            return try await task.value
        }
        let task = Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }
        localFileLoads[url] = task
        do {
            let value = try await task.value
            localFileLoads[url] = nil
            localFileCache.setObject(
                value as NSData,
                forKey: url as NSURL,
                cost: value.count
            )
            return value
        } catch {
            localFileLoads[url] = nil
            throw error
        }
    }

    private func enqueueRemoteLoad(
        for url: URL,
        priority: MediaLoadPriority,
        waiterID: UUID,
        continuation: CheckedContinuation<Data, any Error>
    ) {
        let waiter = RemoteWaiter(
            priority: priority,
            continuation: continuation
        )
        if var active = activeRemoteLoads[url] {
            active.waiters[waiterID] = waiter
            if priority == .visible {
                active.priority = .visible
            }
            activeRemoteLoads[url] = active
            startEligibleRemoteLoads()
            return
        }
        if var pending = pendingRemoteLoads[url] {
            pending.waiters[waiterID] = waiter
            pendingRemoteLoads[url] = pending
        } else {
            if !SharedMediaRequestSchedulingPolicy.acceptsRemoteLoad(
                pendingRemoteCount: pendingRemoteLoads.count
            ) {
                // A disconnected or very slow network can fill the bounded
                // queue with speculative offscreen work. A newly mounted,
                // user-visible image must displace that prefetch instead of
                // failing once and remaining blank until the view or app is
                // recreated.
                guard priority == .visible,
                      discardOldestPendingPrefetch()
                else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
            }
            if priority == .prefetch {
                let pendingPrefetchCount =
                    pendingRemoteLoads.values.count(where: {
                        $0.priority == .prefetch
                    })
                guard SharedMediaRequestSchedulingPolicy.acceptsPrefetch(
                    pendingPrefetchCount: pendingPrefetchCount
                ) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
            }
            pendingRemoteLoads[url] = PendingRemoteLoad(
                waiters: [waiterID: waiter]
            )
            pendingRemoteOrder.append(url)
        }
        startEligibleRemoteLoads()
    }

    @discardableResult
    private func discardOldestPendingPrefetch() -> Bool {
        guard let url = pendingRemoteOrder.first(where: {
            pendingRemoteLoads[$0]?.priority == .prefetch
        }), let pending = pendingRemoteLoads.removeValue(forKey: url)
        else { return false }
        pendingRemoteOrder.removeAll { $0 == url }
        for waiter in pending.waiters.values {
            waiter.continuation.resume(throwing: CancellationError())
        }
        return true
    }

    private func startEligibleRemoteLoads() {
        while let url = SharedMediaRequestSchedulingPolicy.nextURL(
            in: pendingRemoteOrder,
            priorities: pendingRemoteLoads.mapValues(\.priority),
            activeCount: activeRemoteLoads.count,
            activePrefetchCount:
                activeRemoteLoads.values.count(where: {
                    $0.priority == .prefetch
                })
        ), let pending = pendingRemoteLoads.removeValue(forKey: url) {
            pendingRemoteOrder.removeAll { $0 == url }
            startRemoteLoad(pending, for: url)
        }
    }

    private func startRemoteLoad(
        _ pending: PendingRemoteLoad,
        for url: URL
    ) {
        let loadID = UUID()
        let taskPriority: TaskPriority =
            pending.priority == .visible ? .userInitiated : .utility
        let remoteFetch = remoteFetch
        let task = Task.detached(priority: taskPriority) {
            let result: Result<Data, any Error>
            do {
                result = .success(try await remoteFetch(url))
            } catch {
                result = .failure(error)
            }
            await self.finishRemoteLoad(
                for: url,
                loadID: loadID,
                result: result
            )
        }
        activeRemoteLoads[url] = ActiveRemoteLoad(
            id: loadID,
            priority: pending.priority,
            isPromotedToVisible: pending.isPromotedToVisible,
            waiters: pending.waiters,
            task: task
        )
    }

    nonisolated static func remoteSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    nonisolated private static func download(_ url: URL) async throws -> Data {
        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 30
        )
        let (data, response) = try await remoteSession.data(for: request)
        let invalidResponse = (response as? HTTPURLResponse).map {
            !(200 ..< 300).contains($0.statusCode)
        } ?? false
        if invalidResponse {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func finishRemoteLoad(
        for url: URL,
        loadID: UUID,
        result: Result<Data, any Error>
    ) {
        guard let active = activeRemoteLoads[url],
              active.id == loadID
        else { return }
        activeRemoteLoads[url] = nil
        retainRemoteDataIfSuccessful(result, for: url)
        for waiter in active.waiters.values {
            switch result {
            case let .success(data):
                waiter.continuation.resume(returning: data)
            case let .failure(error):
                waiter.continuation.resume(throwing: error)
            }
        }
        startEligibleRemoteLoads()
    }

    private func retainRemoteDataIfSuccessful(
        _ result: Result<Data, any Error>,
        for url: URL
    ) {
        guard case let .success(data) = result else { return }
        remoteDataCache.setObject(
            data as NSData,
            forKey: url as NSURL,
            cost: data.count
        )
        if let remoteDiskCache {
            Task {
                try? await remoteDiskCache.insert(data, for: url)
            }
        }
    }

    private func cancelRemoteWaiter(
        _ waiterID: UUID,
        for url: URL
    ) {
        if cancelPendingRemoteWaiter(waiterID, for: url) {
            return
        }
        guard var active = activeRemoteLoads[url],
              let waiter = active.waiters.removeValue(forKey: waiterID)
        else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if active.waiters.isEmpty {
            activeRemoteLoads[url] = nil
            active.task.cancel()
        } else {
            active.priority = remainingPriority(for: active)
            activeRemoteLoads[url] = active
        }
        startEligibleRemoteLoads()
    }

    private func remainingPriority(
        for active: ActiveRemoteLoad
    ) -> MediaLoadPriority {
        let hasVisibleWaiter = active.waiters.values.contains {
            $0.priority == .visible
        }
        return active.isPromotedToVisible || hasVisibleWaiter
            ? .visible
            : .prefetch
    }

    private func cancelPendingRemoteWaiter(
        _ waiterID: UUID,
        for url: URL
    ) -> Bool {
        guard var pending = pendingRemoteLoads[url],
              let waiter = pending.waiters.removeValue(forKey: waiterID)
        else { return false }
        waiter.continuation.resume(throwing: CancellationError())
        if pending.waiters.isEmpty {
            pendingRemoteLoads[url] = nil
            pendingRemoteOrder.removeAll { $0 == url }
        } else {
            pendingRemoteLoads[url] = pending
        }
        startEligibleRemoteLoads()
        return true
    }
}
