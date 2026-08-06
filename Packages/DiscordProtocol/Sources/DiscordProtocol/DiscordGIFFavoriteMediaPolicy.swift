import Foundation
import SakuraCordModels

nonisolated enum DiscordGIFFavoriteMediaPolicy {
    /// Discord persists only the selected source for a GIF favourite. Older
    /// official-client entries can therefore contain a Tenor WebM or MP4 URL
    /// without the `gif_src` returned by search. Tenor exposes the same asset
    /// in a sibling GIF representation, allowing these entries to stay on the
    /// picker's bounded native media pipeline. Newer Tenor URLs also encode
    /// the representation in the media ID (`Ps` for WebM and `AM` for a small
    /// GIF), so changing only the filename extension can still return WebM
    /// bytes and must not be treated as an image.
    static func previewURL(for source: URL) -> URL {
        guard let host = source.host()?.lowercased(),
              isTenorHost(host),
              ["webm", "mp4"].contains(source.pathExtension.lowercased()),
              var components = URLComponents(
                  url: source,
                  resolvingAgainstBaseURL: false
              )
        else { return source }

        var pathComponents = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard !pathComponents.isEmpty else { return source }
        if pathComponents.count >= 2 {
            let mediaIndex = pathComponents.index(before: pathComponents.endIndex - 1)
            let mediaID = pathComponents[mediaIndex]
            if knownVideoSuffixes.contains(where: mediaID.hasSuffix) {
                pathComponents[mediaIndex] = String(mediaID.dropLast(2)) + "AM"
            }
        }
        let filenameIndex = pathComponents.index(before: pathComponents.endIndex)
        let filename = pathComponents[filenameIndex]
        guard let gifFilename = ((filename as NSString)
            .deletingPathExtension as NSString)
            .appendingPathExtension("gif")
        else { return source }
        pathComponents[filenameIndex] = gifFilename
        components.percentEncodedPath = "/" + pathComponents.joined(separator: "/")
        return components.url ?? source
    }

    private static let knownVideoSuffixes = [
        "Ps", "P3", "P4", "Po", "P1", "P2",
    ]

    private static func isTenorHost(_ host: String) -> Bool {
        host == "tenor.com"
            || host.hasSuffix(".tenor.com")
            || host == "tenor.co"
            || host.hasSuffix(".tenor.co")
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
