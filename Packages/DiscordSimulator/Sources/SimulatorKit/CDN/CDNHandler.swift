import Foundation
import Synchronization

/// Serves `cdn.discordapp.com` and `media.discordapp.net` paths: stored
/// attachments and uploads, and images generated from asset hashes.
public final class CDNHandler: Sendable {
    let world: World
    let log: SimulatorLog
    let host: String
    private let cache = Mutex<[String: (Data, String)]>([:])

    public init(world: World, log: SimulatorLog, host: String) {
        self.world = world
        self.log = log
        self.host = host
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else { return .empty(405) }
        let path = request.path.removingPercentEncoding ?? request.path
        if let stored = await world.mediaData(path) {
            return response(request, stored.data, contentType: stored.contentType)
        }
        let size = min(1024, max(16, Int(request.query["size"]?.first ?? request.query["width"]?.first ?? "128") ?? 128))
        let cacheKey = "\(path)@\(size)" + (request.query["passthrough"]?.first.map { "?passthrough=\($0)" } ?? "")
        if let cached = cache.withLock({ $0[cacheKey] }) { return response(request, cached.0, contentType: cached.1) }
        guard let generated = await generate(path: path, size: size, request: request) else {
            log.error("cdn", "UNKNOWN ASSET \(host)\(request.target)")
            return .bytes(404, Data("404: Not Found".utf8), contentType: "text/plain")
        }
        cache.withLock { $0[cacheKey] = generated }
        return response(request, generated.0, contentType: generated.1)
    }

    private func response(_ request: HTTPRequest, _ data: Data, contentType: String) -> HTTPResponse {
        var response = HTTPResponse.bytes(200, request.method == "HEAD" ? Data() : data, contentType: contentType)
        response.headers.append(("Cache-Control", "public, max-age=31536000"))
        return response
    }

    /// Assets are keyed by their hash, so the hash seeds the generator and the
    /// same URL always yields the same image.
    private func generate(path: String, size: Int, request: HTTPRequest) async -> (Data, String)? {
        let segments = path.split(separator: "/").map(String.init)
        guard let kind = segments.first else { return nil }
        let file = segments.last ?? ""
        let stem = (file as NSString).deletingPathExtension
        let animated = stem.hasPrefix("a_") && (file.hasSuffix(".gif") || request.query["animated"]?.first == "true")
        let seed = Self.seed(stem)
        let palette = await world.palettes[stem]
        let art = await world.arts[stem]
        // Generated images exist only for assets the world created; anything else is a bad URL.
        let key: String = switch kind {
        case "assets": segments.dropLast().last ?? stem
        case "media": segments.count > 3 ? segments[3] : stem
        default: stem
        }
        let known = await world.isKnownAsset(key)
        guard kind == "embed" || known else { return nil }
        switch kind {
        case "avatars", "guilds" where segments.contains("avatars"):
            if animated { return (MediaGenerator.animatedGIF(seed: seed, size: size, art: art), "image/gif") }
            return (MediaGenerator.avatarPNG(seed: seed, size: size, art: art), "image/png")
        case "embed" where segments.count >= 3 && segments[1] == "avatars":
            return (MediaGenerator.defaultAvatarPNG(index: Int(stem) ?? 0, size: size), "image/png")
        case "icons", "splashes", "discovery-splashes", "role-icons", "guild-tag-badges", "badge-icons", "app-icons", "channel-icons":
            return (MediaGenerator.guildIconPNG(seed: seed, size: size, art: art, palette: palette), "image/png")
        case "banners", "guilds" where segments.contains("banners"):
            let width = max(size, 600)
            return (MediaGenerator.bannerPNG(width: width, height: width * 2 / 5, seed: seed, palette: palette), "image/png")
        case "avatar-decoration-presets":
            // `passthrough=false` asks for the still frame, as the client does when animation is off.
            let still = request.query["passthrough"]?.first == "false" || !stem.hasPrefix("a_")
            return (MediaGenerator.avatarDecorationPNG(seed: seed, size: min(size, 240), animated: !still), "image/png")
        case "assets" where segments.contains("collectibles"), "media" where segments.contains("collectibles-shop"):
            return (MediaGenerator.bannerPNG(width: 480, height: 96, seed: Self.seed(segments.dropLast().last ?? stem)), "image/png")
        default:
            return nil
        }
    }

    /// Hex asset hashes and numeric IDs both map to a stable seed.
    static func seed(_ text: String) -> UInt64 {
        let trimmed = text.hasPrefix("a_") ? String(text.dropFirst(2)) : text
        if let value = UInt64(trimmed.prefix(16), radix: 16) { return value }
        return trimmed.hashValueStable
    }
}

/// The attachment upload host: `PUT /discord-attachments-uploads-prd/<uuid>/<filename>`.
public struct UploadHandler: Sendable {
    let world: World
    let log: SimulatorLog

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let prefix = "/discord-attachments-uploads-prd/"
        let path = request.path.removingPercentEncoding ?? request.path
        guard request.method == "PUT", path.hasPrefix(prefix) else {
            log.error("upload", "UNKNOWN UPLOAD REQUEST \(request.method) \(request.target)")
            return .bytes(404, Data("Not Found".utf8), contentType: "text/plain")
        }
        let name = String(path.dropFirst(prefix.count))
        guard await world.completeUpload(name, data: request.body) else {
            log.error("upload", "upload to an unreserved slot \(name)")
            return .bytes(403, Data("<?xml version='1.0' encoding='UTF-8'?><Error><Code>AccessDenied</Code></Error>".utf8),
                          contentType: "application/xml; charset=UTF-8")
        }
        return .empty(200)
    }
}
