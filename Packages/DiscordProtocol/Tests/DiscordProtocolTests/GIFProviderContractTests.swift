import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Suite(.serialized)
struct GIFProviderContractTests {
    @Test func `GIF picker uses exact current Discord landing search and trending routes`() async throws {
        GIFURLProtocol.reset()
        let provider = makeProvider()

        let landing = try await provider.gifPickerLanding()
        let searched = try await provider.searchGIFs(query: "hello")
        let trending = try await provider.trendingGIFs()

        #expect(landing.categories.map(\.name) == [
            "hello", "lol", "love", "happy birthday", "thank you", "excited",
        ])
        #expect(landing.categories.allSatisfy { $0.previewURL?.host() == "static.klipy.com" })
        #expect(searched.map(\.id) == ["one", "two"])
        #expect(searched[0].thumbnailURL?.absoluteString == "https://static.klipy.com/one.webm")
        #expect(searched[0].previewURL?.absoluteString == "https://static.klipy.com/one.webp")
        #expect(searched[1].previewURL?.host() == "static.klipy.com")
        #expect(trending.map(\.id) == ["one", "two"])
        #expect(GIFURLProtocol.requests.map(\.path) == [
            "/api/v9/gifs/trending",
            "/api/v9/gifs/search",
            "/api/v9/gifs/trending-gifs",
        ])
        let locale = Locale.preferredLanguages.first ?? "en-US"
        #expect(GIFURLProtocol.requests[0].query == [
            GIFQuery(name: "locale", value: locale),
            GIFQuery(name: "media_format", value: "webm"),
        ])
        #expect(GIFURLProtocol.requests[1].query == [
            GIFQuery(name: "q", value: "hello"),
            GIFQuery(name: "media_format", value: "webm"),
            GIFQuery(name: "locale", value: locale),
        ])
        #expect(GIFURLProtocol.requests[2].query == [
            GIFQuery(name: "media_format", value: "webm"),
            GIFQuery(name: "locale", value: locale),
        ])
    }

    @Test func `GIF favourites share one settings read and use one full proto patch per action`() async throws {
        GIFURLProtocol.reset()
        let provider = makeProvider()
        let gif = GIFSearchResult(
            id: "one",
            title: "Hello",
            url: URL(string: "https://tenor.com/view/one")!,
            previewURL: URL(string: "https://cdn.example/one.gif"),
            width: 640,
            height: 640
        )

        async let favorites = provider.favoriteGIFs()
        async let emojiSettings = provider.emojiUserSettings()
        let (initial, _) = try await (favorites, emojiSettings)
        let added = try await provider.setGIFFavorite(gif, isFavorite: true)
        let removed = try await provider.setGIFFavorite(gif, isFavorite: false)

        #expect(initial.isEmpty)
        #expect(added.map(\.url) == [gif.url])
        #expect(removed.isEmpty)
        #expect(GIFURLProtocol.requests.filter {
            $0.path == "/api/v9/users/@me/settings-proto/2" && $0.method == "GET"
        }.count == 1)
        let patches = GIFURLProtocol.requests.filter { $0.method == "PATCH" }
        #expect(patches.count == 2)
        #expect(patches.allSatisfy {
            $0.path == "/api/v9/users/@me/settings-proto/2"
                && $0.body?.keys.sorted() == ["settings"]
        })
        let addedBase64 = try #require(patches.first?.body?["settings"] as? String)
        let addedProto = try #require(Data(base64Encoded: addedBase64))
        #expect(DiscordSettingsProto.gifFavorites(from: addedProto).map(\.url) == [gif.url])
    }

    @Test func `persisted Tenor video favourites use native GIF previews`() throws {
        let webM = try #require(URL(
            string: "https://media.tenor.com/a%20b/AAAPs/favorite.WEBM?size=2"
        ))
        let mp4 = try #require(URL(
            string: "https://media1.tenor.co/asset/AAAPo/favorite.mp4"
        ))
        let unrelated = try #require(URL(
            string: "https://cdn.example/favorite.webm"
        ))

        #expect(
            DiscordGIFFavoriteMediaPolicy.previewURL(for: webM).absoluteString
                == "https://media.tenor.com/a%20b/AAAAM/favorite.gif?size=2"
        )
        #expect(
            DiscordGIFFavoriteMediaPolicy.previewURL(for: mp4).absoluteString
                == "https://media1.tenor.co/asset/AAAAM/favorite.gif"
        )
        #expect(
            DiscordGIFFavoriteMediaPolicy.previewURL(for: unrelated)
                == unrelated
        )
    }

    @Test func `persisted favorite format preserves extensionless video media`() throws {
        let canonical = try #require(URL(string: "https://example.com/gif/one"))
        let media = try #require(URL(string: "https://cdn.example/media/one"))
        let gif = GIFSearchResult(
            id: "one",
            title: "One",
            url: canonical,
            mediaURL: media,
            mediaKind: .video
        )

        let update = try DiscordSettingsProto.updatingGIFFavorite(
            in: Data(),
            gif: gif,
            isFavorite: true
        )
        let favorite = try #require(update.favorites.first)

        #expect(favorite.mediaURL == media)
        #expect(favorite.mediaKind == .video)
    }

    private func makeProvider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GIFURLProtocol.self]
        return DiscordRESTProvider(
            credentials: GIFCredentialStore(),
            handle: CredentialHandle(accountID: "gif-contract"),
            session: URLSession(configuration: configuration)
        )
    }
}

private actor GIFCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("gif-contract-session".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

private struct GIFQuery: Equatable, Sendable {
    let name: String
    let value: String?
}

private struct CapturedGIFRequest: @unchecked Sendable {
    let method: String
    let path: String
    let query: [GIFQuery]
    let body: [String: Any]?
}

private final class GIFURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [CapturedGIFRequest] = []

    static func reset() { requests = [] }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.map { GIFQuery(name: $0.name, value: $0.value) } ?? []
        Self.requests.append(
            CapturedGIFRequest(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? "",
                query: query,
                body: Self.requestBody(request).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }
            )
        )

        let body: String
        switch request.url?.path {
        case "/api/v9/gifs/trending":
            body = #"""
            {"categories":[
              {"name":"hello","type":"hello","src":"//static.klipy.com/hello.webp"},
              {"name":"lol","type":"lol","src":"//static.klipy.com/lol.webp"},
              {"name":"love","type":"love","src":"//static.klipy.com/love.webp"},
              {"name":"happy birthday","type":"happy-birthday","src":"//static.klipy.com/birthday.webp"},
              {"name":"thank you","type":"thank-you","src":"//static.klipy.com/thanks.webp"},
              {"name":"excited","type":"excited","src":"//static.klipy.com/excited.webp"}
            ],"gifs":[
              {"id":"one","title":"Hello","url":"https://klipy.com/view/one",
               "src":"//static.klipy.com/one.webm","gif_src":"//static.klipy.com/one.webp",
               "preview":"//static.klipy.com/one.webm","width":640,"height":640}
            ]}
            """#
        case "/api/v9/gifs/search", "/api/v9/gifs/trending-gifs":
            body = #"""
            [
              {"id":"one","title":"Hello","url":"https://klipy.com/view/one",
               "src":"//static.klipy.com/one.webm","gif_src":"//static.klipy.com/one.webp",
               "preview":"//static.klipy.com/one.webm","width":640,"height":640},
              {"id":"two","title":"Wave","url":"https://klipy.com/view/two",
               "src":"//static.klipy.com/two.webm","gif_src":"//static.klipy.com/two.webp",
               "preview":"//static.klipy.com/two.webm","width":498,"height":210},
              {"id":"bad","title":"Bad","url":"https://tenor.com/view/bad",
               "src":"http://unsafe.example/bad.webm","width":100,"height":100}
            ]
            """#
        case "/api/v9/users/@me/settings-proto/2":
            body = request.httpMethod == "GET" ? #"{"settings":""}"# : "{}"
        default:
            body = "{}"
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
