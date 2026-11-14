import Foundation

/// Image URLs on Discord's CDN. An `a_` hash names an animated image.
public enum DiscordCDN {
    /// An application's icon or cover image.
    public static func applicationImage(_ id: ApplicationID, image: String, size: Int) -> URL? {
        URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\(image).png?size=\(size)")
    }

    public static func guildIcon(_ guildID: GuildID, hash: String) -> URL? {
        URL(string: "https://cdn.discordapp.com/icons/\(guildID)/\(hash).webp?size=128&animated=\(isAnimated(hash))")
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

    private static func isAnimated(_ hash: String) -> String {
        hash.hasPrefix("a_") ? "true" : "false"
    }
}
