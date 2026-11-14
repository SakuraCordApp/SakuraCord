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
        #expect(DiscordProfileImageAssets.editableGIFURL(searched[0].previewURL)?.absoluteString == "https://discord.com/klipy/one.webp")
        #expect(DiscordProfileImageAssets.editableGIFURL(URL(string: "https://static.klipy.com/unexpected.svg")) == nil)
        #expect(DiscordProfileImageAssets.editableGIFURL(URL(string: "https://media.tenor.com/id/name.gif?discard=this"))?.absoluteString == "https://discord.com/tenor/id/name.gif")
        #expect(DiscordProfileImageAssets.editableGIFURL(URL(string: "https://media.giphy.com/media/id/name.gif"))?.absoluteString == "https://discord.com/giphy/media/id/name.gif")
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

    @Test func `GIF favourites share one settings read and use one changed-field proto patch per action`() async throws {
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

    @Test func `emoji favourites patch only field 5 and consume the stored response`() async throws {
        GIFURLProtocol.reset()
        let provider = makeProvider()

        let initial = try await provider.emojiUserSettings()
        let added = try await provider.setEmojiFavorite("wave", isFavorite: true)
        let removed = try await provider.setEmojiFavorite("wave", isFavorite: false)

        #expect(initial.favoriteKeys.isEmpty)
        #expect(added.favoriteKeys == ["wave"])
        #expect(removed.favoriteKeys.isEmpty)
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
        #expect(DiscordSettingsProto.emojiSettings(from: addedProto).favoriteKeys == ["wave"])
    }

    @Test func `emoji usage saves both histories with a favorite in one partial patch`() async throws {
        GIFURLProtocol.reset()
        let provider = makeProvider()
        let message = DiscordFrecencyHistory(entries: [.init(key: "turtle", totalUses: 3, recentUses: [1, 2, 3], frecency: 300, score: 300)])
        let reaction = DiscordFrecencyHistory(entries: [.init(key: "snake", totalUses: 1, recentUses: [4], frecency: 80, score: 100)])
        let stored = try await provider.saveEmojiFrecency(message, reactions: reaction, favoriteKey: "turtle", isFavorite: true)
        #expect(stored.messageHistory == message)
        #expect(stored.reactionHistory == reaction)
        #expect(stored.favoriteKeys == ["turtle"])
        #expect(GIFURLProtocol.requests.map(\.method) == ["GET", "PATCH"])
        let encoded = try #require(GIFURLProtocol.requests.last?.body?["settings"] as? String)
        var reader = ProtoReader(data: try #require(Data(base64Encoded: encoded)))
        var fields: [Int] = []
        while let field = reader.readRawField() { fields.append(field.field) }
        #expect(fields == [6, 13, 5])
    }

    @Test func `other type two saves include and acknowledge pending emoji usage in the same request`() async throws {
        GIFURLProtocol.reset()
        let provider = makeProvider()
        let history = DiscordFrecencyHistory(entries: [.init(key: "turtle", totalUses: 2, recentUses: [1, 2])])
        let acknowledgement = EmojiSaveAcknowledgement()
        let sessionProvider: any ChatProvider = provider
        await sessionProvider.configureEmojiFrecencyPersistence {
            EmojiFrecencySaveContribution(messages: history, reactions: .init()) { settings in
                await acknowledgement.record(settings)
            }
        }
        let gif = GIFSearchResult(id: "one", title: "Hello", url: URL(string: "https://tenor.com/view/one")!)
        let favorites = try await provider.setGIFFavorite(gif, isFavorite: true)
        #expect(favorites.map(\.url) == [gif.url])
        #expect(GIFURLProtocol.requests.map(\.method) == ["GET", "PATCH"])
        #expect(await acknowledgement.settings?.messageHistory == history)
        let encoded = try #require(GIFURLProtocol.requests.last?.body?["settings"] as? String)
        var reader = ProtoReader(data: try #require(Data(base64Encoded: encoded)))
        var fields: [Int] = []
        while let field = reader.readRawField() { fields.append(field.field) }
        #expect(fields == [2, 6, 13])
    }

    @Test func `soundboard defaults native send and favorites use exact contracts`() async throws {
        GIFURLProtocol.reset()
        let provider = makeProvider()
        let defaults = try await provider.defaultSoundboardSounds()
        let custom = SoundboardSound(
            id: "9002",
            name: "Custom",
            volume: 0.8,
            emojiID: "7001",
            guildID: GuildID(rawValue: 123)
        )

        try await provider.sendSoundboardSound(custom, in: ChannelID(rawValue: 456))
        let added = try await provider.setSoundboardFavorite("9002", isFavorite: true)

        #expect(defaults.map(\.name) == ["quack", "airhorn"])
        let send = try #require(GIFURLProtocol.requests.first {
            $0.path == "/api/v9/channels/456/send-soundboard-sound"
        })
        #expect(send.method == "POST")
        #expect(send.body?["sound_id"] as? String == "9002")
        #expect(send.body?["emoji_id"] as? String == "7001")
        #expect(send.body?["emoji_name"] is NSNull)
        #expect(send.body?["source_guild_id"] as? String == "123")
        #expect(added.favoriteSoundIDs == ["9002"])
        let patch = try #require(GIFURLProtocol.requests.last { $0.method == "PATCH" })
        let settings = try #require(patch.body?["settings"] as? String)
        let proto = try #require(Data(base64Encoded: settings))
        #expect(DiscordSettingsProto.soundboardSettings(from: proto).favoriteSoundIDs == ["9002"])
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
            credentials: TestCredentialStore(token: "gif-contract-session", handles: []),
            handle: CredentialHandle(accountID: "gif-contract"),
            session: URLSession(configuration: configuration)
        )
    }
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
        case "/api/v9/soundboard-default-sounds":
            body = #"[{"sound_id":"1","name":"quack","emoji_name":"🦆"},{"sound_id":"2","name":"airhorn","emoji_name":"🔊"}]"#
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
            let settings = Self.requests.last?.body?["settings"] as? String ?? ""
            body = "{\"settings\":\"\(settings)\"}"
        default:
            body = "{}"
        }
        respond(status: 200, body: Data(body.utf8), headers: nil)
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> Data? {
        request.bodyData
    }
}

private actor EmojiSaveAcknowledgement {
    private(set) var settings: EmojiUserSettings?
    func record(_ settings: EmojiUserSettings?) { self.settings = settings }
}
