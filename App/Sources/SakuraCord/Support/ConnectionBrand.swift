import AppKit
import SwiftUI

enum ConnectionBrand {
    struct IconAsset: Sendable {
        let light: String
        let dark: String
    }

    // Discord web build 580156, observed 2026-07-18. These are Discord's own
    // profile-connection SVG assets, bundled locally to keep profile rendering
    // crisp and to avoid leaking profile views to a third-party favicon service.
    static let officialIconAssets: [String: IconAsset] = [
        "amazon-music": .init(light: "e3c4aacc1a54395d", dark: "e3c4aacc1a54395d"),
        "battlenet": .init(light: "163c8cb9220efc74", dark: "163c8cb9220efc74"),
        "bluesky": .init(light: "2709f058378a099d", dark: "2709f058378a099d"),
        "bungie": .init(light: "5b0c8422db0e5507", dark: "099cd81cf3b4cc98"),
        "crunchyroll": .init(light: "94ef3e8b7fa85a2e", dark: "94ef3e8b7fa85a2e"),
        "domain": .init(light: "10d4972595802406", dark: "b4376756bcbbf1ef"),
        "ebay": .init(light: "b28a7a265581b6e3", dark: "b28a7a265581b6e3"),
        "epicgames": .init(light: "4fb7893066c0ef83", dark: "199eceff4fca1a0c"),
        "facebook": .init(light: "17be29f77bee4405", dark: "17be29f77bee4405"),
        "github": .init(light: "4db64e0649c64e7e", dark: "a35ff3e86ffa1eb2"),
        "instagram": .init(light: "c05dded52023ed43", dark: "c05dded52023ed43"),
        "leagueoflegends": .init(light: "302a27a2e5cc3fb6", dark: "302a27a2e5cc3fb6"),
        "mastodon": .init(light: "0e6385723fe5cd49", dark: "0e6385723fe5cd49"),
        "paypal": .init(light: "dcb64a4ff8f61b2c", dark: "dcb64a4ff8f61b2c"),
        "playstation": .init(light: "792da49081c21457", dark: "eed203a7ec517e23"),
        "reddit": .init(light: "adfd927dcc2049a5", dark: "adfd927dcc2049a5"),
        "roblox": .init(light: "e04a073ed006173a", dark: "a4d8e9b0404a2d00"),
        "riotgames": .init(light: "772307b7d902b47b", dark: "772307b7d902b47b"),
        "spotify": .init(light: "d5719388ffc613da", dark: "d5719388ffc613da"),
        "steam": .init(light: "dbfa31449965dbd5", dark: "1f7ec18f3695d4cf"),
        "tiktok": .init(light: "53641d0496c85aec", dark: "a303feb844769624"),
        "twitch": .init(light: "4fda00c96319c8ae", dark: "4fda00c96319c8ae"),
        "twitter": .init(light: "5cf814b9693aac47", dark: "a61999ae9bfb9658"),
        "xbox": .init(light: "0133fed7d4dc775c", dark: "c4f09fda61827e19"),
        "youtube": .init(light: "0fa530ba9c04ac32", dark: "0fa530ba9c04ac32")
    ]

    private static var imageCache: [String: NSImage] = [:]

    static func displayName(for type: String) -> String {
        switch normalized(type) {
        case "amazon-music": "Amazon Music"
        case "battlenet": "Battle.net"
        case "bluesky": "Bluesky"
        case "bungie": "Bungie.net"
        case "crunchyroll": "Crunchyroll"
        case "domain": "Domain"
        case "ebay": "eBay"
        case "epicgames": "Epic Games"
        case "facebook": "Facebook"
        case "github": "GitHub"
        case "instagram": "Instagram"
        case "leagueoflegends": "League of Legends"
        case "mastodon": "Mastodon"
        case "paypal": "PayPal"
        case "playstation": "PlayStation Network"
        case "reddit": "Reddit"
        case "roblox": "Roblox"
        case "riotgames": "Riot Games"
        case "soundcloud": "SoundCloud"
        case "spotify": "Spotify"
        case "steam": "Steam"
        case "tiktok": "TikTok"
        case "twitch": "Twitch"
        case "twitter": "X"
        case "xbox": "Xbox"
        case "youtube": "YouTube"
        default: type.localizedCapitalized
        }
    }

    static func image(for type: String, colorScheme: ColorScheme) -> NSImage? {
        guard let asset = iconAsset(for: type) else { return nil }
        let resourceName = colorScheme == .dark ? asset.dark : asset.light
        let cacheKey = "\(resourceName)-\(colorScheme == .dark ? "dark" : "light")"
        if let cached = imageCache[cacheKey] { return cached }

        let resourceURL = Bundle.module.url(
            forResource: resourceName,
            withExtension: "svg",
            subdirectory: "ConnectionIcons"
        ) ?? Bundle.module.url(forResource: resourceName, withExtension: "svg")
        guard let resourceURL, let image = NSImage(contentsOf: resourceURL) else { return nil }
        imageCache[cacheKey] = image
        return image
    }

    static func iconAsset(for type: String) -> IconAsset? {
        officialIconAssets[normalized(type)]
    }

    private static func normalized(_ type: String) -> String {
        switch type.lowercased() {
        case "playstation-stg": "playstation"
        case "twitter_legacy", "x": "twitter"
        default: type.lowercased()
        }
    }
}
