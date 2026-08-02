@testable import SakuraCord
import CoreGraphics
import Foundation
import SakuraCordModels
import Testing

@Test func `cancelling the final media waiter cancels its fetch`() async throws {
    let probe = SuspendedRemoteMediaFetch()
    let loader = SharedMediaDataLoader(remoteFetch: probe.fetch)
    let url = try #require(URL(string: "https://cdn.example/only.png"))
    let request = Task {
        try await loader.data(for: url)
    }

    #expect(await waitUntil {
        await probe.fetchCount == 1
    })
    request.cancel()
    await expectCancellation(of: request)

    #expect(await waitUntil {
        await probe.cancellationCount == 1
    })
    #expect(
        await loader.remoteLoadSnapshot()
            == .init(pendingCount: 0, activeCount: 0, waiterCount: 0)
    )
}

@Test func `cancelling one shared media waiter preserves the fetch`() async throws {
    let probe = SuspendedRemoteMediaFetch()
    let loader = SharedMediaDataLoader(remoteFetch: probe.fetch)
    let url = try #require(URL(string: "https://cdn.example/shared.png"))
    let first = Task {
        try await loader.data(for: url)
    }
    let second = Task {
        try await loader.data(for: url)
    }

    #expect(await waitUntil {
        await loader.remoteLoadSnapshot().waiterCount == 2
    })
    first.cancel()
    await expectCancellation(of: first)
    #expect(await probe.cancellationCount == 0)
    #expect(await loader.remoteLoadSnapshot().activeCount == 1)

    let expected = Data("fixture".utf8)
    await probe.finish(url, with: expected)
    #expect(try await second.value == expected)
    #expect(await loader.remoteLoadSnapshot().waiterCount == 0)
}

@Test func `visible media queue and started requests stay bounded`() async throws {
    let probe = SuspendedRemoteMediaFetch()
    let loader = SharedMediaDataLoader(remoteFetch: probe.fetch)
    let activeRequests = try makeMediaRequests(
        count: SharedMediaRequestSchedulingPolicy.maximumConcurrentRemoteLoads,
        offset: 0,
        loader: loader
    )
    #expect(await waitUntil {
        await loader.remoteLoadSnapshot().activeCount
            == SharedMediaRequestSchedulingPolicy.maximumConcurrentRemoteLoads
    })

    let queuedRequests = try makeMediaRequests(
        count: SharedMediaRequestSchedulingPolicy.maximumPendingRemoteLoads + 10,
        offset: activeRequests.count,
        loader: loader
    )
    #expect(await waitUntil {
        await loader.remoteLoadSnapshot().pendingCount
            == SharedMediaRequestSchedulingPolicy.maximumPendingRemoteLoads
    })
    #expect(
        await loader.remoteLoadSnapshot().waiterCount
            <= SharedMediaRequestSchedulingPolicy.maximumConcurrentRemoteLoads
                + SharedMediaRequestSchedulingPolicy.maximumPendingRemoteLoads
    )

    await cancelAndAwait(queuedRequests)
    #expect(await waitUntil {
        await loader.remoteLoadSnapshot().pendingCount == 0
    })
    #expect(
        await probe.fetchCount
            == SharedMediaRequestSchedulingPolicy.maximumConcurrentRemoteLoads
    )

    await cancelAndAwait(activeRequests)
    #expect(await waitUntil {
        await loader.remoteLoadSnapshot().activeCount == 0
    })
}

@Test func `simultaneous image waiters create one queued decode`() async throws {
    let probe = SuspendedRemoteMediaFetch()
    let dataLoader = SharedMediaDataLoader(remoteFetch: probe.fetch)
    let decodeScheduler = NativeTimelineMediaDecodeScheduler()
    let decodedLoader = SharedDecodedImageLoader(
        dataLoader: dataLoader,
        decodeScheduler: decodeScheduler
    )
    let url = try #require(
        URL(string: "https://cdn.example/coalesced-static.png")
    )
    #expect(await decodeScheduler.acquirePermitForTesting(priority: .visible))
    #expect(await decodeScheduler.acquirePermitForTesting(priority: .visible))
    let first = Task {
        await decodedLoader.image(
            for: url,
            maximumPixelDimension: 32,
            priority: .prefetch
        )
    }
    let second = Task {
        await decodedLoader.image(
            for: url,
            maximumPixelDimension: 32,
            priority: .prefetch
        )
    }

    #expect(await waitUntil { await probe.fetchCount == 1 })
    let encoded = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+3vYjWQAAAABJRU5ErkJggg=="
    ))
    await probe.finish(url, with: encoded)
    #expect(await waitUntil {
        await decodeScheduler.snapshot().prefetchWaiterCount == 1
    })

    await decodeScheduler.releasePermitForTesting(priority: .visible)
    #expect(await first.value != nil)
    #expect(await second.value != nil)
    #expect(await probe.fetchCount == 1)
    await decodeScheduler.releasePermitForTesting(priority: .visible)
}

@MainActor
@Test func `visible duplicate keeps a later fallback at visible priority`() async throws {
    let primaryURL = try #require(
        URL(string: "https://cdn.example/primary-static.png")
    )
    let fallbackURL = try #require(
        URL(string: "https://cdn.example/fallback-static.png")
    )
    let probe = ControlledDecodedImageLoad()
    let store = NativeTimelineMediaStore { url, dimension, priority in
        await probe.load(url: url, dimension: dimension, priority: priority)
    }
    let key = NativeTimelineMediaKey.media(
        primaryURL,
        fallbackURL: fallbackURL,
        maximumPixelDimension: 32
    )
    store.request(
        key,
        owner: UUID(),
        subscriber: .message(MessageID(rawValue: 1)),
        priority: .prefetch
    ) { _ in }
    await probe.waitForCall(to: primaryURL)

    store.request(
        key,
        owner: UUID(),
        subscriber: .message(MessageID(rawValue: 2)),
        priority: .visible
    ) { _ in }
    await probe.finish(primaryURL, image: nil)
    await probe.waitForCall(to: fallbackURL)
    #expect(await probe.priority(for: fallbackURL) == .visible)

    await probe.finish(fallbackURL, image: nil)
    for _ in 0 ..< 100 where store.loading.contains(key) {
        await Task.yield()
    }
    #expect(!store.loading.contains(key))
}

@MainActor
@Test func `cancelling an offscreen static request cancels its owned callback`()
    async throws
{
    let url = try #require(
        URL(string: "https://cdn.example/cancelled-visible-static.png")
    )
    let key = NativeTimelineMediaKey.media(url, maximumPixelDimension: 32)
    let probe = ControlledDecodedImageLoad()
    let store = NativeTimelineMediaStore { url, dimension, priority in
        await probe.load(url: url, dimension: dimension, priority: priority)
    }
    let owner = UUID()
    var outcomes: [NativeTimelineStaticMediaLoadOutcome] = []
    store.request(
        key,
        owner: owner,
        subscriber: .message(MessageID(rawValue: 98_111)),
        priority: .visible
    ) { outcome in
        outcomes.append(outcome)
    }
    await probe.waitForCall(to: url)

    store.cancelStaticRequestsOutsideVisibleSet(owner: owner)

    #expect(outcomes == [.cancelled])
    await probe.finish(url, image: nil)
}

@MainActor
@Test func `same row media subscribers remain isolated by canvas owner`() async throws {
    let url = try #require(
        URL(string: "https://cdn.example/two-canvas-static.png")
    )
    let key = NativeTimelineMediaKey.media(url, maximumPixelDimension: 32)
    let probe = ControlledDecodedImageLoad()
    let store = NativeTimelineMediaStore { url, dimension, priority in
        await probe.load(url: url, dimension: dimension, priority: priority)
    }
    let firstOwner = UUID()
    let secondOwner = UUID()
    let sharedRow = NativeMessageTimelineItem.Identifier.message(
        MessageID(rawValue: 98_113)
    )
    var callbackOutcomes:
        [UUID: [NativeTimelineStaticMediaLoadOutcome]] = [:]
    var invalidationOwners: [UUID] = []

    store.retainVisibleImages(for: [key], owner: firstOwner)
    store.retainVisibleImages(for: [key], owner: secondOwner)
    store.request(
        key,
        owner: firstOwner,
        subscriber: sharedRow,
        priority: .visible
    ) { outcome in
        callbackOutcomes[firstOwner, default: []].append(outcome)
        invalidationOwners.append(firstOwner)
    }
    store.request(
        key,
        owner: secondOwner,
        subscriber: sharedRow,
        priority: .visible
    ) { outcome in
        callbackOutcomes[secondOwner, default: []].append(outcome)
        invalidationOwners.append(secondOwner)
    }
    await probe.waitForCall(to: url)

    store.retainVisibleImages(for: [], owner: firstOwner)
    store.cancelStaticRequestsOutsideVisibleSet(owner: firstOwner)

    #expect(callbackOutcomes[firstOwner] == [.cancelled])
    #expect(callbackOutcomes[secondOwner] == nil)
    #expect(store.loading.contains(key))
    #expect(store.subscribers[key]?.count == 1)
    #expect(store.subscribers[key]?.keys.first?.owner == secondOwner)

    let encoded = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+3vYjWQAAAABJRU5ErkJggg=="
    ))
    let image = try #require(NativeTimelineMediaDecoder.decode(
        encoded,
        maximumPixelDimension: 32
    ))
    await probe.finish(url, image: image)
    for _ in 0 ..< 100 where store.loading.contains(key) {
        await Task.yield()
    }

    #expect(callbackOutcomes[secondOwner] == [.ready])
    #expect(Set(invalidationOwners) == [firstOwner, secondOwner])
    #expect(store.subscribers[key] == nil)
}

private actor ControlledDecodedImageLoad {
    private var calls: [(url: URL, priority: MediaLoadPriority)] = []
    private var continuations: [URL: CheckedContinuation<CGImage?, Never>] = [:]
    private var callWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func load(
        url: URL,
        dimension _: Int,
        priority: MediaLoadPriority
    ) async -> CGImage? {
        calls.append((url, priority))
        for waiter in callWaiters.removeValue(forKey: url) ?? [] {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            continuations[url] = continuation
        }
    }

    func waitForCall(to url: URL) async {
        guard !calls.contains(where: { $0.url == url }) else { return }
        await withCheckedContinuation { continuation in
            callWaiters[url, default: []].append(continuation)
        }
    }

    func priority(for url: URL) -> MediaLoadPriority? {
        calls.last(where: { $0.url == url })?.priority
    }

    func finish(_ url: URL, image: CGImage?) {
        continuations.removeValue(forKey: url)?.resume(returning: image)
    }
}

private actor SuspendedRemoteMediaFetch {
    private var continuations:
        [URL: CheckedContinuation<Data, any Error>] = [:]
    private(set) var fetchCount = 0
    private(set) var cancellationCount = 0

    func fetch(_ url: URL) async throws -> Data {
        fetchCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[url] = continuation
            }
        } onCancel: {
            Task {
                await self.cancel(url)
            }
        }
    }

    func finish(_ url: URL, with data: Data) {
        continuations.removeValue(forKey: url)?.resume(returning: data)
    }

    private func cancel(_ url: URL) {
        guard let continuation = continuations.removeValue(forKey: url)
        else { return }
        cancellationCount += 1
        continuation.resume(throwing: CancellationError())
    }
}

private func makeMediaRequests(
    count: Int,
    offset: Int,
    loader: SharedMediaDataLoader
) throws -> [Task<Data, any Error>] {
    try (0 ..< count).map { index in
        let url = try #require(
            URL(string: "https://cdn.example/\(offset + index).png")
        )
        return Task {
            try await loader.data(for: url)
        }
    }
}

private func cancelAndAwait(
    _ requests: [Task<Data, any Error>]
) async {
    for request in requests {
        request.cancel()
    }
    for request in requests {
        _ = try? await request.value
    }
}

private func expectCancellation(
    of request: Task<Data, any Error>
) async {
    do {
        _ = try await request.value
        Issue.record("Expected the media request to be cancelled.")
    } catch is CancellationError {
        return
    } catch {
        Issue.record("Expected cancellation, received \(error).")
    }
}

private func waitUntil(
    maximumYields: Int = 10_000,
    _ condition: () async -> Bool
) async -> Bool {
    for _ in 0 ..< maximumYields {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return false
}
