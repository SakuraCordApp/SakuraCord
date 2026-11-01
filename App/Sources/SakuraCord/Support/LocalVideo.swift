import AVFoundation
import Synchronization
import UniformTypeIdentifiers

/// A video file on this Mac, such as one being sent: its first frame, and
/// its size as it plays, with its rotation applied.
nonisolated enum LocalVideo {
    private static let sizes = Mutex<[URL: CGSize]>([:])

    static func isVideo(_ url: URL) -> Bool {
        url.isFileURL && UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    /// The size `prepare` read, so a message being sent lays out in the
    /// video's shape before Discord reports it.
    static func preparedSize(of url: URL) -> CGSize? {
        sizes.withLock { $0[url.standardizedFileURL] }
    }

    /// Reads each video's size for the message that will carry it. A
    /// message is built at once when sent, so this runs as files are staged.
    static func prepare(_ urls: [URL]) async {
        await withTaskGroup { group in
            for url in urls where isVideo(url) && preparedSize(of: url) == nil {
                group.addTask {
                    guard let size = await size(of: url) else { return }
                    sizes.withLock { $0[url.standardizedFileURL] = size }
                }
            }
        }
    }

    private static func size(of url: URL) async -> CGSize? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let shown = CGRect(origin: .zero, size: size).applying(transform).size
        guard shown.width != 0, shown.height != 0 else { return nil }
        return CGSize(width: abs(shown.width).rounded(), height: abs(shown.height).rounded())
    }

    /// The first frame, as it plays, at most `maximumPixelDimension` on its
    /// longer side.
    static func frame(at url: URL, maximumPixelDimension: Int) async -> CGImage? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelDimension, height: maximumPixelDimension)
        return try? await generator.image(at: .zero).image
    }
}
