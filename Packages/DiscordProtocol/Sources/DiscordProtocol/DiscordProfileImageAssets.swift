import Foundation
import SakuraCordModels

public enum DiscordProfileImageAssets {
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
