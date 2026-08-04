import Dispatch
import Foundation
@testable import MediaPipeline
import Testing

@Test
func `media cache persists bytes without storing the source URL`() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try MediaCache(maximumBytes: 1_024, directory: root)
    let url = try #require(URL(
        string: "https://cdn.example/image.png?signature=private-shape"
    ))
    let expected = Data("cached-media".utf8)

    try await cache.insert(expected, for: url)

    #expect(try await cache.data(for: url) == expected)
    let cacheDirectory = root.appending(
        path: "SakuraCord/Media",
        directoryHint: .isDirectory
    )
    let filenames = try FileManager.default.contentsOfDirectory(
        atPath: cacheDirectory.path
    )
    #expect(filenames.count == 1)
    #expect(!filenames[0].contains("cdn.example"))
    #expect(!filenames[0].contains("signature"))
}

@Test
func `media cache enforces its byte budget and can be cleared`() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try MediaCache(maximumBytes: 12, directory: root)
    let firstURL = try #require(URL(string: "https://cdn.example/first"))
    let secondURL = try #require(URL(string: "https://cdn.example/second"))

    try await cache.insert(Data(repeating: 1, count: 8), for: firstURL)
    try await cache.insert(Data(repeating: 2, count: 8), for: secondURL)

    #expect(try await cache.currentByteCount() <= 12)
    #expect(try await cache.data(for: secondURL) != nil)

    try await cache.removeAll()
    #expect(try await cache.currentByteCount() == 0)
}

@Test
func `media cache reads do not wait for index maintenance`() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cachedURL = try #require(URL(string: "https://cdn.example/cached"))
    let insertedURL = try #require(URL(string: "https://cdn.example/inserted"))
    let expected = Data("cached-media".utf8)
    let seed = try MediaCache(maximumBytes: 1_024, directory: root)
    try await seed.insert(expected, for: cachedURL)

    let indexLoad = SuspendedMediaCacheIndexLoad()
    let cache = try MediaCache(
        maximumBytes: 1_024,
        directory: root,
        beforeIndexLoad: indexLoad.pause
    )
    let insert = Task {
        try await cache.insert(Data("new-media".utf8), for: insertedURL)
    }
    #expect(await indexLoad.waitUntilPaused())

    let read = Task {
        try await cache.data(for: cachedURL)
    }
    let readFinishedFirst = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            (try? await read.value) == expected
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(250))
            return false
        }
        let result = await group.next() ?? false
        indexLoad.resume()
        group.cancelAll()
        return result
    }

    #expect(readFinishedFirst)
    try await insert.value
}

@Test
func `media cache clear cannot be undone by an older suspended insert`() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let insertedURL = try #require(URL(string: "https://cdn.example/inserted"))
    let indexLoad = SuspendedMediaCacheIndexLoad()
    let cache = try MediaCache(
        maximumBytes: 1_024,
        directory: root,
        beforeIndexLoad: indexLoad.pause
    )
    let insert = Task {
        try await cache.insert(Data("old-media".utf8), for: insertedURL)
    }
    #expect(await indexLoad.waitUntilPaused())

    let clear = Task { try await cache.removeAll() }
    for _ in 0 ..< 20 { await Task.yield() }
    indexLoad.resume()
    try await insert.value
    try await clear.value

    #expect(try await cache.currentByteCount() == 0)
    #expect(try await cache.data(for: insertedURL) == nil)
}

@Test
func `concurrent media cache clears coalesce`() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try MediaCache(maximumBytes: 1_024, directory: root)
    let url = try #require(URL(string: "https://cdn.example/cached"))
    try await cache.insert(Data("cached-media".utf8), for: url)

    async let firstClear: Void = cache.removeAll()
    async let secondClear: Void = cache.removeAll()
    _ = try await (firstClear, secondClear)

    #expect(try await cache.currentByteCount() == 0)
    #expect(try await cache.data(for: url) == nil)
}

@Test
func `media cache tracks failed evictions and retries them`() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let removal = FailFirstMediaCacheRemoval()
    let cache = try MediaCache(
        maximumBytes: 8,
        directory: root,
        beforeIndexLoad: {},
        removeCachedFile: removal.remove
    )
    let firstURL = try #require(URL(string: "https://cdn.example/first"))
    let secondURL = try #require(URL(string: "https://cdn.example/second"))
    let thirdURL = try #require(URL(string: "https://cdn.example/third"))

    try await cache.insert(Data(repeating: 1, count: 8), for: firstURL)
    try await cache.insert(Data(repeating: 2, count: 8), for: secondURL)

    #expect(try await cache.currentByteCount() == 16)
    #expect(removal.attemptCount == 1)

    try await cache.insert(Data(repeating: 3, count: 8), for: thirdURL)

    #expect(try await cache.currentByteCount() == 8)
    #expect(removal.attemptCount == 3)
}

private final class SuspendedMediaCacheIndexLoad: @unchecked Sendable {
    private let paused = DispatchSemaphore(value: 0)
    private let resumeSignal = DispatchSemaphore(value: 0)

    func pause() {
        paused.signal()
        resumeSignal.wait()
    }

    func waitUntilPaused() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(
                    returning: paused.wait(timeout: .now() + 2) == .success
                )
            }
        }
    }

    func resume() {
        resumeSignal.signal()
    }
}

private final class FailFirstMediaCacheRemoval: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func remove(_ url: URL) throws {
        let shouldFail = lock.withLock {
            attempts += 1
            return attempts == 1
        }
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.removeItem(at: url)
    }
}
