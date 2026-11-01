import Foundation
import SakuraCordModels

/// Discord's media proxy renders a video's first frame when a still format is
/// requested. Only that proxy can do so; the origin URL would deliver the whole
/// video, so other hosts get no poster.
nonisolated enum DiscordVideoPosterURL {
    static let maximumRequestedPixelDimension = 1_024

    static func url(
        proxyURL: URL?,
        width: Int?,
        height: Int?,
        maximumPixelDimension: Int
    ) -> URL? {
        guard let proxyURL,
              proxyURL.scheme == "https",
              proxyURL.host() == "media.discordapp.net",
              var components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false)
        else { return nil }
        var query = (components.queryItems ?? []).filter {
            !["format", "width", "height"].contains($0.name)
        }
        query.append(URLQueryItem(name: "format", value: "webp"))
        if let width, let height, width > 0, height > 0 {
            let bound = min(max(1, maximumPixelDimension), maximumRequestedPixelDimension)
            let scale = min(1, Double(bound) / Double(max(width, height)))
            func scaled(_ dimension: Int) -> String {
                String(max(1, Int((Double(dimension) * scale).rounded())))
            }
            query.append(URLQueryItem(name: "width", value: scaled(width)))
            query.append(URLQueryItem(name: "height", value: scaled(height)))
        }
        components.queryItems = query
        return components.url
    }
}

extension Attachment {
    nonisolated func videoPosterURL(maximumPixelDimension: Int) -> URL? {
        guard mediaKind == .video else { return nil }
        return DiscordVideoPosterURL.url(
            proxyURL: proxyURL,
            width: width,
            height: height,
            maximumPixelDimension: maximumPixelDimension
        )
    }
}
