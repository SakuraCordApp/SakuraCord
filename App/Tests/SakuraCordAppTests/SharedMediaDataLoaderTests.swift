@testable import SakuraCord
import Foundation
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
