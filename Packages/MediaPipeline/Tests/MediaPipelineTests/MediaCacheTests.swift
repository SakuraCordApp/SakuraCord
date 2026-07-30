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
