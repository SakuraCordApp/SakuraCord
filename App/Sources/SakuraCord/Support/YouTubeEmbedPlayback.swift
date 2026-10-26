import Foundation

/// A validated YouTube player destination, kept separate from downloadable media.
nonisolated struct YouTubeEmbedPlayback: Hashable {
    let videoID: String
    let startSeconds: Int?

    init?(url: URL) {
        guard url.scheme?.lowercased() == "https",
              ["youtube.com", "www.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(url.host()?.lowercased()),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443
        else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == 2, path[0] == "embed",
              path[1].utf8.count == 11,
              path[1].utf8.allSatisfy({
                  (65 ... 90).contains($0) || (97 ... 122).contains($0)
                      || (48 ... 57).contains($0) || $0 == 45 || $0 == 95
              })
        else { return nil }
        videoID = path[1]
        startSeconds = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "start" }?.value.flatMap(Int.init)
            .flatMap { $0 >= 0 ? $0 : nil }
    }

    var watchURL: URL {
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        if let startSeconds {
            components.queryItems?.append(URLQueryItem(name: "t", value: String(startSeconds)))
        }
        return components.url!
    }

    func playerRequest(appIdentifier: String, resumeAt seconds: Double? = nil) -> URLRequest {
        let origin = "https://\(appIdentifier.lowercased())"
        var components = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")!
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "origin", value: origin)
        ]
        if let seconds, seconds.isFinite, seconds >= 0 {
            components.queryItems?.append(URLQueryItem(name: "start", value: String(format: "%.0f", seconds.rounded(.down))))
        } else if let startSeconds {
            components.queryItems?.append(URLQueryItem(name: "start", value: String(startSeconds)))
        }
        var request = URLRequest(url: components.url!)
        // The wrapper uses this origin as its base URL so the iframe receives this Referer.
        request.setValue(origin, forHTTPHeaderField: "Referer")
        return request
    }
}

/// Resume points live only in this process; no preferences, account data or disk cache.
final class YouTubePlaybackSession {
    static let shared = YouTubePlaybackSession()

    private var positions: [String: Double] = [:]

    func position(for playback: YouTubeEmbedPlayback) -> Double {
        positions[playback.videoID] ?? Double(playback.startSeconds ?? 0)
    }

    func record(_ seconds: Double, duration: Double, ended: Bool, for playback: YouTubeEmbedPlayback) {
        guard seconds.isFinite, duration.isFinite,
              duration > 0, seconds >= 0, seconds <= duration else { return }
        if ended {
            positions.removeValue(forKey: playback.videoID)
        } else {
            positions[playback.videoID] = seconds
        }
    }
}
