import Foundation

/// Image URLs on Discord's CDN. An `a_` hash names an animated image.
public enum DiscordCDN {
    /// An application's icon or cover image.
    public static func applicationImage(_ id: ApplicationID, image: String, size: Int) -> URL? {
        URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\(image).png?size=\(size)")
    }

    /// An application's asset, such as an Activity cover or, under `store/`,
    /// a store trailer.
    public static func applicationAsset(
        _ applicationID: String, assetID: String, fileExtension: String, size: Int, animated: Bool = false
    ) -> URL? {
        URL(
            string: "https://cdn.discordapp.com/app-assets/\(applicationID)/\(assetID).\(fileExtension)?size=\(size)"
                + (animated ? "&animated=true" : "")
        )
    }

    /// An application's icon at 64 points, by the ID as Discord sent it.
    public static func applicationIcon(_ applicationID: String, hash: String) -> URL? {
        URL(string: "https://cdn.discordapp.com/app-icons/\(applicationID)/\(hash).webp?size=64")
    }

    /// A server's icon; invite and join-request previews leave out the
    /// animated flag.
    public static func guildIcon(_ guildID: GuildID, hash: String, marksAnimation: Bool = true) -> URL? {
        URL(
            string: "https://cdn.discordapp.com/icons/\(guildID)/\(hash).webp?size=128"
                + (marksAnimation ? "&animated=\(isAnimated(hash))" : "")
        )
    }

    public static func userAvatar(_ userID: UserID, hash: String, size: Int) -> URL? {
        URL(string: "https://cdn.discordapp.com/avatars/\(userID)/\(hash).webp?size=\(size)&animated=\(isAnimated(hash))")
    }

    public static func userBanner(_ userID: UserID, hash: String) -> URL? {
        URL(string: "https://cdn.discordapp.com/banners/\(userID)/\(hash).webp?size=600&animated=\(isAnimated(hash))")
    }

    /// A member's banner for one server.
    public static func guildMemberBanner(_ guildID: GuildID, userID: UserID, hash: String) -> URL? {
        URL(
            string:
            "https://cdn.discordapp.com/guilds/\(guildID)/users/\(userID)/banners/\(hash).webp?size=600&animated=\(isAnimated(hash))"
        )
    }

    public static func avatarDecorationPreset(_ asset: String) -> URL? {
        URL(string: "https://cdn.discordapp.com/avatar-decoration-presets/\(asset).png?size=160")
    }

    /// The folder holding a collectibles-shop item's assets.
    public static func collectiblesShopBase(_ skuID: String) -> String {
        "https://cdn.discordapp.com/media/v1/collectibles-shop/\(skuID)"
    }

    /// A member's avatar for one server.
    public static func guildMemberAvatar(_ guildID: GuildID, userID: UserID, hash: String, size: Int = 128) -> URL? {
        URL(
            string:
            "https://cdn.discordapp.com/guilds/\(guildID)/users/\(userID)/avatars/\(hash).webp?size=\(size)&animated=\(isAnimated(hash))"
        )
    }

    /// A custom emoji's image in `fileExtension`, with the query each
    /// surface asks for.
    public static func emoji(_ id: String, fileExtension: String, query: String? = nil) -> URL? {
        URL(string: "https://cdn.discordapp.com/emojis/\(id).\(fileExtension)" + (query.map { "?\($0)" } ?? ""))
    }

    /// A server's home header image.
    public static func guildHomeHeader(_ guildID: GuildID, hash: String) -> URL? {
        URL(string: "https://cdn.discordapp.com/home-headers/\(guildID)/\(hash).png?size=2048")
    }

    /// The smallest image size the CDN serves that covers `size`, chosen as the
    /// official client's module776231 does.
    public static func supportedSize(atLeast size: Double) -> Int {
        supportedSizes.first { Double($0) >= size } ?? 4096
    }

    private static let supportedSizes = [
        16, 20, 22, 24, 28, 32, 40, 44, 48, 56, 60, 64, 80, 96, 100, 128,
        160, 240, 256, 300, 320, 480, 512, 600, 640, 1024, 1280, 1536, 2048, 3072, 4096,
    ]

    /// `url` with the query items named in `names` dropped and `items`
    /// appended, as the CDN and media proxy take size and format requests.
    /// An empty query is dropped.
    public static func editingQuery(of url: URL, removing names: Set<String>, adding items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = (components.queryItems ?? []).filter { !names.contains($0.name) } + items
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    private static func isAnimated(_ hash: String) -> String {
        hash.hasPrefix("a_") ? "true" : "false"
    }
}
