import AppKit
import MediaPipeline
import SakuraCordModels

/// Media that may carry a Discord `placeholder` hash.
protocol NativeTimelineMediaPlaceholderSource {
    var placeholder: String? { get }
    var placeholderVersion: Int? { get }
}

extension Attachment: NativeTimelineMediaPlaceholderSource {}
extension MessageEmbedMedia: NativeTimelineMediaPlaceholderSource {}
extension ComponentMedia: NativeTimelineMediaPlaceholderSource {}

/// A Discord `placeholder` hash the timeline can preview while the real media loads.
struct NativeTimelineMediaPlaceholder: Hashable {
    let hash: String

    init?(_ media: (some NativeTimelineMediaPlaceholderSource)?) {
        guard media?.placeholderVersion == ThumbHash.supportedVersion,
              let hash = media?.placeholder, !hash.isEmpty
        else { return nil }
        self.hash = hash
    }

    /// Rows draw on every redraw, so each hash is decoded once. A hash that
    /// fails to decode caches an empty image to avoid retrying every frame.
    @MainActor private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()

    /// The decoded preview, or nil when the hash is malformed.
    @MainActor var image: NSImage? {
        let key = hash as NSString
        if let cached = Self.images.object(forKey: key) {
            return cached.size.width > 0 ? cached : nil
        }
        let decoded = ThumbHash.image(base64: hash).map {
            NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height))
        }
        Self.images.setObject(decoded ?? NSImage(), forKey: key)
        return decoded
    }
}
