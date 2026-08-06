import Foundation
import SakuraCordModels

nonisolated enum DiscordGIFFavoriteMediaPolicy {
    /// Discord persists only the selected source for a GIF favourite. Older
    /// official-client entries can therefore contain a Tenor WebM or MP4 URL
    /// without the `gif_src` returned by search. Tenor exposes the same asset
    /// at the sibling `.gif` path, allowing these entries to stay on the
    /// picker's bounded native animation pipeline.
    static func previewURL(for source: URL) -> URL {
        guard let host = source.host()?.lowercased(),
              host == "media.tenor.com" || host == "media.tenor.co",
              ["webm", "mp4"].contains(source.pathExtension.lowercased()),
              var components = URLComponents(
                  url: source,
                  resolvingAgainstBaseURL: false
              )
        else { return source }

        let path = components.percentEncodedPath as NSString
        guard let gifPath = (path.deletingPathExtension as NSString)
            .appendingPathExtension("gif")
        else { return source }
        components.percentEncodedPath = gifPath
        return components.url ?? source
    }

    static func persistedFormat(
        for source: URL,
        declaredKind: GIFMediaKind?
    ) -> UInt64 {
        if declaredKind == .video
            || ["webm", "mp4"].contains(source.pathExtension.lowercased())
        {
            return 2
        }
        return 1
    }
}
