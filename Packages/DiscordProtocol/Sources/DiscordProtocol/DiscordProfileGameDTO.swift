import Foundation
import SakuraCordModels

struct ProfileGameDTO: Decodable {
    struct Media: Decodable {
        struct Asset: Decodable { let type: String; let value: String }
        let cover: Asset?
        let icon: Asset?
        let artwork: [Asset]?
    }
    struct Company: Decodable { let name: String; let roles: [Int] }
    struct Website: Decodable { let category: Int; let url: String }
    struct SKU: Decodable { let distributor: String; let id: String? }
    struct LinkedApplication: Decodable { let id: String; let type: Int }
    struct Trailer: Decodable {
        let id: String
        let applicationID: String
        let width: Int
        let height: Int
        enum CodingKeys: String, CodingKey { case id, width, height; case applicationID = "application_id" }
    }
    struct Steam: Decodable {
        let rating: Double?
        let ratingCount: Int?
        let recentRating: Double?
        let recentRatingCount: Int?
        let localizedRating: Double?
        let localizedRatingCount: Int?
        enum CodingKeys: String, CodingKey {
            case rating, ratingCount = "rating_count", recentRating = "recent_rating", recentRatingCount = "recent_rating_count"
            case localizedRating = "localized_rating", localizedRatingCount = "localized_rating_count"
        }
    }
    struct Critic: Decodable {
        let topCriticRating: Double?
        let tier: Int?
        let topCriticRatingCount: Int?
        enum CodingKeys: String, CodingKey { case topCriticRating = "top_critic_rating", topCriticRatingCount = "top_critic_rating_count", tier }
    }
    struct Reviews: Decodable {
        let steam: Steam?
        let opencritic: Critic?
    }
    let id: String
    let name: String
    let media: Media?
    let description: String?
    let genres: [Int]?
    let platforms: [Int]?
    let companies: [Company]?
    let websites: [Website]?
    let screenshotURLs: [String]?
    let trailers: [Trailer]?
    let firstReleaseDate: String?
    let reviews: Reviews?
    let opencriticURL: String?
    let thirdPartySKUs: [SKU]?
    let steamReleaseStatus: Int?
    let linkedApplications: [LinkedApplication]?
    let rank: Int?
    let gameFlags: Int?
    let contentClassification: JSONValue?
    enum CodingKeys: String, CodingKey {
        case id, name, media, description, genres, platforms, companies, websites, trailers, reviews
        case screenshotURLs = "screenshot_urls", firstReleaseDate = "first_release_date", opencriticURL = "opencritic_url"
        case thirdPartySKUs = "third_party_skus", steamReleaseStatus = "steam_release_status", linkedApplications = "linked_applications"
        case rank = "l30_rank", gameFlags = "game_flags", contentClassification = "content_classification"
    }

    var domain: ProfileGame {
        var game = ProfileGame(id: id, name: name, iconURL: assetURL(media?.icon, size: 80, format: "png", keepAspectRatio: false),
                               coverURL: assetURL(media?.cover, size: 256, format: "webp", keepAspectRatio: true),
                               isAllowedInDefaultWidgetPicker: !DiscordProfileWidgetGamePolicy.isAdult(contentClassification))
        var details = ProfileGameMetadata()
        details.description = description
        details.genres = genres ?? []
        details.platforms = platforms ?? []
        details.publishers = (companies ?? []).filter { $0.roles.contains(1) }.map(\.name)
        details.developers = (companies ?? []).filter { $0.roles.contains(2) }.map(\.name)
        details.releaseDate = firstReleaseDate.flatMap(DiscordDate.parse)
        details.websites = (websites ?? []).compactMap { site in
            Self.webURL(site.url).map { ProfileGameWebsite(category: site.category, url: $0) }
        }
        details.screenshots = (screenshotURLs ?? []).compactMap(Self.webURL)
        // Artwork fills the game profile banner, so request it at banner resolution, not the 128px default.
        details.artwork = (media?.artwork ?? []).compactMap { assetURL($0, size: 2048, format: "webp", keepAspectRatio: true) }
        details.trailers = (trailers ?? []).filter { UInt64($0.id) != nil && UInt64($0.applicationID) != nil && $0.width > 0 && $0.height > 0 }
            .map { ProfileGameTrailer(id: $0.id, applicationID: $0.applicationID, width: $0.width, height: $0.height) }
        if let steam = reviews?.steam {
            details.steamReviews = ProfileGameSteamReviews(rating: steam.rating, count: steam.ratingCount,
                                                           recentRating: steam.recentRating, recentCount: steam.recentRatingCount,
                                                           localizedRating: steam.localizedRating, localizedCount: steam.localizedRatingCount)
        }
        if let critic = reviews?.opencritic, let rating = critic.topCriticRating, let tier = critic.tier, let url = opencriticURL.flatMap(Self.webURL) {
            details.criticReviews = ProfileGameCriticReviews(rating: rating, tier: tier, url: url, count: critic.topCriticRatingCount)
        }
        let steamWebsite = details.websites.first { $0.category == 13 }?.url
        let steamSKUs = (thirdPartySKUs ?? []).filter { $0.distributor == "steam" }.compactMap(\.id).filter { !$0.isEmpty }
        let steamSKUURL = steamSKUs.first.flatMap { sku -> URL? in
            guard let encoded = sku.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
            return URL(string: "https://store.steampowered.com/app/\(encoded)")
        }
        details.steamURL = steamSKUs.count > 1 && steamWebsite != nil ? steamWebsite : steamSKUURL ?? steamWebsite
        details.isRetiredFromSteam = steamReleaseStatus == 4
        details.isProfileAvailable = (gameFlags ?? 0) & 1 == 0
        details.officialApplicationID = linkedApplications?.first { $0.type == 2 }?.id
        details.rank = rank
        game.metadata = details
        return game
    }

    private func assetURL(_ asset: Media.Asset?, size: Int?, format: String?, keepAspectRatio: Bool) -> URL? {
        guard let asset else { return nil }
        if asset.type == "hash", UInt64(id) != nil, !asset.value.isEmpty, asset.value.allSatisfy(\.isHexDigit) {
            return URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\(asset.value).\(format ?? "png")?size=\(size ?? 128)&keep_aspect_ratio=\(keepAspectRatio)")
        }
        guard asset.type == "url", let url = Self.webURL(asset.value), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query = components.queryItems ?? []
        if url.host?.hasSuffix("discordapp.net") == true {
            let replacing = Set(["keep_aspect_ratio", "format"])
            query.removeAll { replacing.contains($0.name) }
            query.append(URLQueryItem(name: "keep_aspect_ratio", value: String(keepAspectRatio)))
            if let format { query.append(URLQueryItem(name: "format", value: format)) }
        }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    private static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return url
    }
}
