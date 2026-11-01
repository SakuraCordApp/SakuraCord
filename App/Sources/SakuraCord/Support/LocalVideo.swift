import AVFoundation
import Synchronization
import UniformTypeIdentifiers

/// A video file on this Mac, such as one being sent: its first frame, and
/// its size as it plays, with its rotation applied.
nonisolated enum LocalVideo {
    /// By file and its modification date, so a file replaced in place is read again.
    private static let sizes = Mutex<[String: CGSize]>([:])

    static func isVideo(_ url: URL) -> Bool {
        url.isFileURL && UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    /// The size `prepare` read, so a message being sent lays out in the
    /// video's shape before Discord reports it.
    static func preparedSize(of url: URL) -> CGSize? {
        let key = sizeKey(url)
        return sizes.withLock { $0[key] }
    }

    private static func sizeKey(_ url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.standardizedFileURL.path)#\(modified?.timeIntervalSinceReferenceDate ?? 0)"
    }

    /// Reads each video's size, and draws its poster for the timeline, for
    /// the message that will carry it. A message is built at once when sent,
    /// so this runs as files are staged.
    static func prepare(_ urls: [URL]) async {
        await withTaskGroup { group in
            for url in urls where isVideo(url) && preparedSize(of: url) == nil {
                group.addTask {
                    guard let size = await size(of: url) else { return }
                    let key = sizeKey(url)
                    sizes.withLock { $0[key] = size }
                }
                group.addTask {
                    _ = await SharedDecodedImageLoader.shared.image(
                        for: url,
                        maximumPixelDimension: NativeTimelineMediaKey.videoPosterPixelDimension,
                        priority: .prefetch,
                        preparesForTimeline: true
                    )
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
