import Foundation
import MediaPipeline
import Observation
import SakuraCordModels

/// Shared derived colours for the profile card, editor background and palette.
/// The result never changes saved metadata or creates an explicit override.
@Observable
@MainActor
final class ProfileThemeState {
    private var loadedURL: URL?
    private var palette: [UInt32] = []

    func source(for profile: UserProfile?, scale: CGFloat, allowsTheme: Bool? = nil) -> URL? {
        guard let profile, allowsTheme ?? (profile.user.premiumType == 2),
              profile.themeHexes.count < 2, let url = profile.avatarURL ?? profile.defaultAvatarURL else { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host == "cdn.discordapp.com", parts.path.contains("/avatars/") else { return url }
        // Discord's theme extraction requests a static avatar at 80 points,
        // omitting the animation query even when the displayed avatar animates.
        var query = parts.queryItems ?? []
        query.removeAll { $0.name == "size" || $0.name == "animated" }
        query.insert(URLQueryItem(name: "size", value: String(Int((80 * scale).rounded()))), at: 0)
        parts.queryItems = query
        return parts.url
    }

    func colors(for profile: UserProfile?, scale: CGFloat, allowsTheme: Bool? = nil) -> [UInt32] {
        guard let profile, allowsTheme ?? (profile.user.premiumType == 2) else { return [] }
        if profile.themeHexes.count >= 2 { return Array(profile.themeHexes.prefix(2)) }
        let url = source(for: profile, scale: scale, allowsTheme: allowsTheme)
        let values = url == loadedURL ? palette : url.flatMap { ProfileAvatarPaletteLoader.shared.cached($0) } ?? []
        guard let primary = values.first else { return [0x41434A, 0x41434A] }
        return [primary, values.count > 1 ? values[1] : primary]
    }

    func load(_ url: URL?) async {
        guard let url else { return }
        do {
            let colors = try await ProfileAvatarPaletteLoader.shared.colors(url)
            try Task.checkCancellation()
            loadedURL = url
            palette = colors
        } catch {
            // Keep the reference client's neutral colour when artwork fails.
        }
    }
}

@MainActor
final class ProfileAvatarPaletteLoader {
    static let shared = ProfileAvatarPaletteLoader()
    private let cache = NSCache<NSURL, Palette>()

    init() { cache.countLimit = 128 }

    func cached(_ url: URL) -> [UInt32]? { cache.object(forKey: url as NSURL)?.colors }

    func colors(_ url: URL) async throws -> [UInt32] {
        if let colors = cached(url) { return colors }
        let data = try await SharedMediaDataLoader.shared.data(for: url)
        try Task.checkCancellation()
        if let colors = cached(url) { return colors }
        let colors = try await Task.detached { try ProfileImagePalette.colors(in: data) }.value
        try Task.checkCancellation()
        cache.setObject(Palette(colors), forKey: url as NSURL)
        return colors
    }

    private final class Palette: NSObject {
        let colors: [UInt32]
        init(_ colors: [UInt32]) { self.colors = colors }
    }
}
