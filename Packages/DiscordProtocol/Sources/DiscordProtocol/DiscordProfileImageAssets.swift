import Foundation
import SakuraCordModels

public enum DiscordProfileImageAssets {
    /// The clean client's standard avatar assets, ordered by its user-ID or
    /// legacy discriminator index. These are bundled artwork, not inventory.
    /// Every decoded user without an avatar resolves through this one source.
    public static func defaultAvatarURL(userID: String, discriminator: String?) -> URL? {
        let assets = ["18e336a74a159cfd.png", "788f05731f8aa02e.png", "9855d7e3b9780976.png",
                      "2ccd8ae8b2379360.png", "411d8a698dd15ddf.png", "320d5a40d309f942.png"]
        // Only the migrated "0" discriminator indexes by ID; any legacy value,
        // including a webhook's "0000", indexes by discriminator.
        let index = if let discriminator, discriminator != "0", let legacy = UInt64(discriminator) {
            legacy % 5
        } else {
            (UserID(userID)?.discordEpochMilliseconds ?? 0) % UInt64(assets.count)
        }
        return URL(string: "https://discord.com/assets/\(assets[Int(index)])")
    }

    /// Artwork used by the official image chooser, in reading order.
    public static let gifPickerArtwork: [URL] = [
        "1071e0c5ceaf6ef7.png", "6d14801ca95f25f1.png",
        "4637e85fff87537c.png", "ca693e3ef16951f4.png"
    ].compactMap { URL(string: "https://discord.com/assets/\($0)") }

    /// Profile cropping uses the first-party asset proxy. Picker thumbnails
    /// continue to use the response-provided media origin.
    public static func editableGIFURL(_ candidate: URL?) -> URL? {
        guard let url = GIFMediaURLPolicy.approved(candidate),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        let path = components.percentEncodedPath
        let prefix: String
        let pattern: String
        switch host {
        case "media.tenor.com", "media.tenor.co", "c.tenor.com":
            prefix = "/tenor"
            pattern = #"^/([a-zA-Z0-9-_]+/[a-z0-9-%]+\.gif)$"#
        case _ where host == "giphy.com" || host.hasSuffix(".giphy.com"):
            prefix = "/giphy"
            pattern = #"^/(media/(?:v1\.[a-zA-Z0-9=&_-]+/)?[a-zA-Z0-9]+/[a-zA-Z0-9_-]+\.(gif|webp|mp4))$"#
        case "static.klipy.com":
            prefix = "/klipy"
            pattern = #"^/([a-zA-Z0-9/_-]+\.(gif|webp|webm|mp4|png))$"#
        default:
            return url
        }
        guard path.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://discord.com\(prefix)\(path)")
    }
}
