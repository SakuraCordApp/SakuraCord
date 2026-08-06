import Foundation
import SakuraCordModels

private struct DiscordGIFDTO: Decodable {
    var id: String
    var title: String
    var url: String
    var src: String
    var gifSrc: String?
    var width: Int?
    var height: Int?
    var preview: String?

    enum CodingKeys: String, CodingKey {
        case id, title, url, src, width, height, preview
        case gifSrc = "gif_src"
    }

    var domain: GIFSearchResult? {
        guard let canonicalURL = Self.url(from: url),
              let mediaURL = Self.url(from: src)
        else { return nil }
        return GIFSearchResult(
            id: id,
            title: title.isEmpty ? "GIF" : title,
            url: canonicalURL,
            previewURL: gifSrc.flatMap(Self.url(from:)) ?? mediaURL,
            width: width,
            height: height,
            thumbnailURL: preview.flatMap(Self.url(from:)),
            mediaURL: mediaURL
        )
    }

    private static func url(from value: String) -> URL? {
        URL(string: value.hasPrefix("//") ? "https:\(value)" : value)
    }
}

private struct DiscordGIFCategoryDTO: Decodable {
    var name: String
    var type: String?
    var src: String?
    var gifSrc: String?

    enum CodingKeys: String, CodingKey {
        case name, type, src
        case gifSrc = "gif_src"
    }

    var domain: GIFPickerCategory {
        GIFPickerCategory(
            id: type.map { "\($0):\(name)" } ?? name,
            name: name,
            query: name,
            previewURL: (gifSrc ?? src).flatMap {
                URL(string: $0.hasPrefix("//") ? "https:\($0)" : $0)
            }
        )
    }
}

private struct DiscordGIFPickerLandingDTO: Decodable {
    var categories: [DiscordGIFCategoryDTO]
    var gifs: [DiscordGIFDTO]
}

public extension DiscordRESTProvider {
    func searchGIFs(query: String) async throws -> [GIFSearchResult] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return try await trendingGIFs() }
        let response: [DiscordGIFDTO] = try await request(
            "/gifs/search",
            query: [
                URLQueryItem(name: "q", value: normalized),
                URLQueryItem(name: "media_format", value: "webm"),
                URLQueryItem(name: "locale", value: Self.gifLocale),
            ]
        )
        return response.compactMap(\.domain)
    }

    func trendingGIFs() async throws -> [GIFSearchResult] {
        let response: [DiscordGIFDTO] = try await request(
            "/gifs/trending-gifs",
            query: [
                URLQueryItem(name: "media_format", value: "webm"),
                URLQueryItem(name: "locale", value: Self.gifLocale),
            ]
        )
        return response.compactMap(\.domain)
    }

    func gifPickerLanding() async throws -> GIFPickerLanding {
        if let cachedGIFPickerLanding { return cachedGIFPickerLanding }
        let response: DiscordGIFPickerLandingDTO = try await request(
            "/gifs/trending",
            query: [
                URLQueryItem(name: "locale", value: Self.gifLocale),
                URLQueryItem(name: "media_format", value: "webm"),
            ]
        )
        let landing = GIFPickerLanding(
            categories: response.categories.map(\.domain),
            trendingPreviewURL: response.gifs.first?.domain?.previewURL
        )
        cachedGIFPickerLanding = landing
        return landing
    }

    func favoriteGIFs() async throws -> [GIFSearchResult] {
        if let cachedGIFFavorites { return cachedGIFFavorites }
        let data = try await frecencySettingsProto()
        let favorites = DiscordSettingsProto.gifFavorites(from: data)
        cachedGIFFavorites = favorites
        return favorites
    }

    func setGIFFavorite(_ gif: GIFSearchResult, isFavorite: Bool) async throws
        -> [GIFSearchResult]
    {
        guard !isMutatingGIFFavorite else {
            throw ChatProviderError.invalidRequest("A GIF favorite update is already in progress.")
        }
        isMutatingGIFFavorite = true
        defer { isMutatingGIFFavorite = false }

        let current = try await frecencySettingsProto()
        let update = try DiscordSettingsProto.updatingGIFFavorite(
            in: current,
            gif: gif,
            isFavorite: isFavorite
        )
        try await requestEmpty(
            "/users/@me/settings-proto/2",
            method: "PATCH",
            body: ["settings": .string(update.data.base64EncodedString())]
        )
        cachedFrecencySettingsProto = update.data
        cachedGIFFavorites = update.favorites
        return update.favorites
    }

    internal func frecencySettingsProto() async throws -> Data {
        if let cachedFrecencySettingsProto { return cachedFrecencySettingsProto }
        if let frecencySettingsTask { return try await frecencySettingsTask.value }
        let task = Task { [self] in
            let response: UserSettingsProtoDTO = try await request(
                "/users/@me/settings-proto/2"
            )
            guard let data = Data(base64Encoded: response.settings) else {
                throw ChatProviderError.invalidRequest(
                    "Discord returned malformed GIF and emoji settings."
                )
            }
            return data
        }
        frecencySettingsTask = task
        do {
            let data = try await task.value
            frecencySettingsTask = nil
            cachedFrecencySettingsProto = data
            return data
        } catch {
            frecencySettingsTask = nil
            throw error
        }
    }

    private static var gifLocale: String {
        Locale.preferredLanguages.first ?? "en-US"
    }
}
