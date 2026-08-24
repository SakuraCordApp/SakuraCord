import Foundation
import MediaPipeline

nonisolated enum SharedMediaDataMemoryPolicy {
    static let remoteBytes = 24 * 1_024 * 1_024
    static let localBytes = 32 * 1_024 * 1_024
    static let retainedBytes = remoteBytes + localBytes
}

nonisolated struct SharedMediaDownloadedFile: Sendable {
    let url: URL
    let cleanupDirectory: URL?
}

actor SharedMediaDataLoader {
    static let shared = SharedMediaDataLoader()
    private static let defaultRemoteDiskCostLimit: Int64 = 2 * 1024 * 1024 * 1024
    nonisolated private static let remoteSession = URLSession(
        configuration: remoteSessionConfiguration()
    )

    private enum RemoteWaiter {
        case data(
            priority: MediaLoadPriority,
            continuation: CheckedContinuation<Data, any Error>
        )
        case fileCopy(
            priority: MediaLoadPriority,
            destination: URL,
            continuation: CheckedContinuation<Void, any Error>
        )

        var priority: MediaLoadPriority {
            switch self {
            case let .data(priority, _),
                 let .fileCopy(priority, _, _):
                priority
            }
        }

        var requiresFileDownload: Bool {
            if case .fileCopy = self { return true }
            return false
        }

        func cancel() {
            resume(throwing: CancellationError())
        }

        func resume(throwing error: any Error) {
            switch self {
            case let .data(_, continuation):
                continuation.resume(throwing: error)
            case let .fileCopy(_, _, continuation):
                continuation.resume(throwing: error)
            }
        }
    }

    private enum RemoteLoadResult: Sendable {
        case data(Data)
        case file(SharedMediaDownloadedFile)
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
    private let remoteDownload: @Sendable (URL) async throws -> SharedMediaDownloadedFile
    private var localFileLoads: [URL: Task<Data, any Error>] = [:]
    private var pendingRemoteLoads: [URL: PendingRemoteLoad] = [:]
    private var pendingRemoteOrder: [URL] = []
    private var activeRemoteLoads: [URL: ActiveRemoteLoad] = [:]

    init() {
        let configuredLimit = (UserDefaults.standard.object(
            forKey: "mediaCacheLimit"
        ) as? NSNumber)?.int64Value ?? Self.defaultRemoteDiskCostLimit
        remoteDiskCache = try? MediaCache(
            maximumBytes: configuredLimit
        )
        remoteFetch = Self.download
        remoteDownload = Self.downloadToTemporaryFile
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
        remoteDownload = Self.downloadToTemporaryFile
        localFileCache.totalCostLimit = SharedMediaDataMemoryPolicy.localBytes
        localFileCache.countLimit = 256
        remoteDataCache.totalCostLimit = SharedMediaDataMemoryPolicy.remoteBytes
        remoteDataCache.countLimit = 128
    }

    init(
        remoteFetch: @escaping @Sendable (URL) async throws -> Data,
        remoteDownload: @escaping @Sendable (URL) async throws -> SharedMediaDownloadedFile
    ) {
        remoteDiskCache = nil
        self.remoteFetch = remoteFetch
        self.remoteDownload = remoteDownload
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
                    waiterID: waiterID,
                    waiter: .data(
                        priority: priority,
                        continuation: continuation
                    )
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

    func copyRemoteMedia(
        from url: URL,
        to destination: URL,
        priority: MediaLoadPriority = .visible
    ) async throws {
        precondition(!url.isFileURL)
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueRemoteLoad(
                    for: url,
                    waiterID: waiterID,
                    waiter: .fileCopy(
                        priority: priority,
                        destination: destination,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancelRemoteWaiter(waiterID, for: url)
            }
        }
        try Task.checkCancellation()
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

    func diskCacheStatus() async throws -> MediaCache.Status? {
        try await remoteDiskCache?.status()
    }

    func setDiskCacheLimit(_ maximumBytes: Int64) async throws {
        try await remoteDiskCache?.setMaximumBytes(maximumBytes)
    }

    func clearDiskCache() async throws {
        try await remoteDiskCache?.removeAll()
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
        waiterID: UUID,
        waiter: RemoteWaiter
    ) {
        if var active = activeRemoteLoads[url] {
            active.waiters[waiterID] = waiter
            if waiter.priority == .visible {
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
                guard waiter.priority == .visible,
                      discardOldestPendingPrefetch()
                else {
                    waiter.cancel()
                    return
                }
            }
            if waiter.priority == .prefetch {
                let pendingPrefetchCount =
                    pendingRemoteLoads.values.count(where: {
                        $0.priority == .prefetch
                    })
                guard SharedMediaRequestSchedulingPolicy.acceptsPrefetch(
                    pendingPrefetchCount: pendingPrefetchCount
                ) else {
                    waiter.cancel()
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
            waiter.cancel()
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
        let remoteDownload = remoteDownload
        let requiresFileDownload = pending.waiters.values.contains {
            $0.requiresFileDownload
        }
        let task = Task.detached(priority: taskPriority) {
            let result: Result<RemoteLoadResult, any Error>
            do {
                if requiresFileDownload {
                    result = .success(.file(try await remoteDownload(url)))
                } else {
                    result = .success(.data(try await remoteFetch(url)))
                }
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

    nonisolated private static func downloadToTemporaryFile(
        _ url: URL
    ) async throws -> SharedMediaDownloadedFile {
        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 60
        )
        let (temporaryURL, response) = try await remoteSession.download(
            for: request
        )
        let invalidResponse = (response as? HTTPURLResponse).map {
            !(200 ..< 300).contains($0.statusCode)
        } ?? false
        if invalidResponse {
            throw URLError(.badServerResponse)
        }
        let directory = incompleteDownloadRootDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let fileURL = directory.appendingPathComponent("download")
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            return SharedMediaDownloadedFile(
                url: fileURL,
                cleanupDirectory: directory
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    nonisolated static func incompleteDownloadRootDirectory(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        temporaryDirectory
            .appendingPathComponent("SakuraCord", isDirectory: true)
            .appendingPathComponent("Media Downloads", isDirectory: true)
    }

    private func finishRemoteLoad(
        for url: URL,
        loadID: UUID,
        result: Result<RemoteLoadResult, any Error>
    ) {
        guard let active = activeRemoteLoads[url],
              active.id == loadID
        else {
            Self.discardDownloadedFile(in: result)
            return
        }
        activeRemoteLoads[url] = nil
        startEligibleRemoteLoads()
        Task.detached(priority: .utility) {
            if let data = Self.fulfillRemoteWaiters(
                active.waiters.values,
                result: result
            ) {
                await self.retainRemoteData(data, for: url)
            }
        }
    }

    nonisolated private static func discardDownloadedFile(
        in result: Result<RemoteLoadResult, any Error>
    ) {
        guard case let .success(.file(downloadedFile)) = result,
              let cleanupDirectory = downloadedFile.cleanupDirectory
        else { return }
        try? FileManager.default.removeItem(at: cleanupDirectory)
    }

    nonisolated private static func fulfillRemoteWaiters(
        _ waiters: Dictionary<UUID, RemoteWaiter>.Values,
        result: Result<RemoteLoadResult, any Error>
    ) -> Data? {
        switch result {
        case let .failure(error):
            for waiter in waiters {
                waiter.resume(throwing: error)
            }
            return nil
        case let .success(.data(data)):
            fulfillRemoteWaiters(waiters, with: data)
            return data
        case let .success(.file(downloadedFile)):
            return fulfillRemoteWaiters(waiters, with: downloadedFile)
        }
    }

    nonisolated private static func fulfillRemoteWaiters(
        _ waiters: Dictionary<UUID, RemoteWaiter>.Values,
        with data: Data
    ) {
        for waiter in waiters {
            switch waiter {
            case let .data(_, continuation):
                continuation.resume(returning: data)
            case let .fileCopy(_, destination, continuation):
                do {
                    try data.write(to: destination, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func fulfillRemoteWaiters(
        _ waiters: Dictionary<UUID, RemoteWaiter>.Values,
        with downloadedFile: SharedMediaDownloadedFile
    ) -> Data? {
        defer {
            if let cleanupDirectory = downloadedFile.cleanupDirectory {
                try? FileManager.default.removeItem(at: cleanupDirectory)
            }
        }
        let dataResult: Result<Data, any Error>? = waiters.contains {
            if case .data = $0 { return true }
            return false
        } ? Result { try Data(contentsOf: downloadedFile.url) } : nil
        for waiter in waiters {
            switch waiter {
            case let .data(_, continuation):
                continuation.resume(with: dataResult ?? .failure(URLError(.cannotDecodeContentData)))
            case let .fileCopy(_, destination, continuation):
                do {
                    try FileManager.default.copyItem(
                        at: downloadedFile.url,
                        to: destination
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return try? dataResult?.get()
    }

    private func retainRemoteData(
        _ data: Data,
        for url: URL
    ) {
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
        waiter.cancel()
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
        waiter.cancel()
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
