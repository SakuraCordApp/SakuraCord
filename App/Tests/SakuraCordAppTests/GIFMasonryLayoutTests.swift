import Foundation
import SakuraCordModels
@testable import SakuraCord
import Testing

@Test func `GIF picker keeps supported animation media on the native path`() throws {
    let tenorWebM = try #require(URL(
        string: "https://media.tenor.com/abcAAAPs/favorite.WEBM?size=2"
    ))
    let otherWebM = try #require(URL(
        string: "https://cdn.example/favorite.webm?size=2"
    ))
    let gif = try #require(URL(string: "https://media.tenor.com/native/search.gif"))
    let tenor = GIFSearchResult(
        id: "tenor",
        title: "Tenor",
        url: tenorWebM,
        previewURL: tenorWebM,
        mediaURL: tenorWebM,
        mediaKind: .video
    )
    let unsupported = GIFSearchResult(
        id: "other",
        title: "Other",
        url: otherWebM,
        previewURL: otherWebM,
        mediaURL: otherWebM,
        mediaKind: .video
    )
    let native = GIFSearchResult(
        id: "gif",
        title: "GIF",
        url: gif,
        previewURL: gif,
        mediaURL: gif,
        mediaKind: .image
    )

    #expect(
        GIFPickerMediaPolicy.nativeAnimationURL(for: tenor)?.absoluteString
            == "https://media.tenor.com/abcAAAAM/favorite.gif?size=2"
    )
    #expect(
        GIFPickerMediaPolicy.nativeVideoURL(for: tenor)?.absoluteString
            == "https://media.tenor.com/abcAAAPo/favorite.mp4?size=2"
    )
    #expect(GIFPickerMediaPolicy.nativeVideoURL(for: unsupported) == nil)
    #expect(GIFPickerMediaPolicy.nativeAnimationURL(for: unsupported) == nil)
    #expect(GIFPickerMediaPolicy.nativeAnimationURL(for: native) == gif)
    let poster = try #require(URL(string: "https://media.tenor.com/abc/poster.png"))
    let animation = try #require(URL(string: "https://media.tenor.com/abc/favorite.gif"))
    let complete = GIFSearchResult(
        id: "complete",
        title: "Complete",
        url: tenorWebM,
        previewURL: animation,
        thumbnailURL: poster,
        mediaURL: tenorWebM,
        mediaKind: .video
    )
    #expect(GIFPickerMediaPolicy.requestURLs(for: complete).count == 3)
    #expect(GIFPickerMediaPolicy.maximumRequestCount == 3)
}

@Test func `GIF media policy accepts Discord returned HTTPS origins safely`() throws {
    let rejected = [
        "http://media.tenor.com/a.gif",
        "https://media.tenor.com:8443/a.gif",
        "https://user:secret@media.tenor.com/a.gif",
        "file:///tmp/a.gif",
    ]
    for value in rejected {
        #expect(GIFMediaURLPolicy.approved(URL(string: value)) == nil)
    }
    for value in [
        "https://media.tenor.com/a.gif",
        "https://media12.tenor.co/a.mp4",
        "https://c.tenor.com/a.webp",
        "https://static.klipy.com/a.webp",
        "https://media.giphy.com/a.gif",
        "https://i.giphy.com/a.gif",
        "https://future-provider.example/a.gif",
    ] {
        #expect(GIFMediaURLPolicy.approved(URL(string: value)) != nil)
    }
}

@Test func `Klipy results use returned WebP without speculative MP4 rewriting`() throws {
    let canonical = try #require(URL(string: "https://klipy.com/view/one"))
    let webM = try #require(URL(string: "https://static.klipy.com/one.webm"))
    let webP = try #require(URL(string: "https://static.klipy.com/one.webp"))
    let result = GIFSearchResult(
        id: "one",
        title: "One",
        url: canonical,
        previewURL: webP,
        thumbnailURL: webM,
        mediaURL: webM,
        mediaKind: .video
    )

    #expect(GIFPickerMediaPolicy.nativeVideoURL(for: result) == nil)
    #expect(GIFPickerMediaPolicy.staticFallbackURL(for: result) == webP)
    #expect(GIFPickerMediaPolicy.nativeAnimationURL(for: result) == webP)
    #expect(GIFPickerMediaPolicy.requestURLs(for: result) == [webP])
}

@Test func `GIF video staging uses one shared streamed request`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sakuracord-gif-video-test-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let downloaded = directory.appendingPathComponent("download.mp4")
    let bytes = Data("video-bytes".utf8)
    try bytes.write(to: downloaded)
    let probe = GIFVideoDownloadProbe(fileURL: downloaded)
    let loader = SharedMediaDataLoader(
        remoteFetch: { _ in throw URLError(.unsupportedURL) },
        remoteDownload: { url in await probe.download(url) }
    )
    let source = try #require(URL(string: "https://media.tenor.com/asset/video.mp4"))

    let staged = try await GIFPickerVideoTransport.stage(source, dataLoader: loader)
    defer { staged.discard() }

    #expect(try Data(contentsOf: staged.fileURL) == bytes)
    #expect(await probe.urls == [source])

    let unsafe = try #require(URL(string: "http://unsafe.example/video.mp4"))
    await #expect(throws: URLError.self) {
        try await GIFPickerVideoTransport.stage(unsafe, dataLoader: loader)
    }
    #expect(await probe.urls == [source])
}

@Test func `GIF picker preserves Tenor video size when deriving native MP4`() throws {
    let tinyWebM = try #require(URL(
        string: "https://media1.tenor.co/m/abcAAAP3/favorite.webm"
    ))
    let nanoWebM = try #require(URL(
        string: "https://c.tenor.com/abcAAAP4/favorite.webm"
    ))
    let tiny = GIFSearchResult(
        id: "tiny",
        title: "Tiny",
        url: tinyWebM,
        mediaURL: tinyWebM,
        mediaKind: .video
    )
    let nano = GIFSearchResult(
        id: "nano",
        title: "Nano",
        url: nanoWebM,
        mediaURL: nanoWebM,
        mediaKind: .video
    )

    #expect(
        GIFPickerMediaPolicy.nativeVideoURL(for: tiny)?.absoluteString
            == "https://media1.tenor.co/m/abcAAAP1/favorite.mp4"
    )
    #expect(
        GIFPickerMediaPolicy.nativeVideoURL(for: nano)?.absoluteString
            == "https://c.tenor.com/abcAAAP2/favorite.mp4"
    )
}

private actor GIFVideoDownloadProbe {
    let fileURL: URL
    private(set) var urls: [URL] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func download(_ url: URL) -> SharedMediaDownloadedFile {
        urls.append(url)
        return SharedMediaDownloadedFile(url: fileURL, cleanupDirectory: nil)
    }
}

@Test func `GIF video failures remain on bounded native image fallback`() throws {
    let first = try #require(URL(string: "https://example.com/first.mp4"))
    let second = try #require(URL(string: "https://example.com/second.mp4"))
    let third = try #require(URL(string: "https://example.com/third.mp4"))
    var memory = GIFPickerVideoFallbackMemory(maximumCount: 2)

    memory.insert(first)
    memory.insert(second)
    memory.insert(second)
    #expect(memory.contains(first))
    #expect(memory.contains(second))

    memory.insert(third)
    #expect(!memory.contains(first))
    #expect(memory.contains(second))
    #expect(memory.contains(third))
}
