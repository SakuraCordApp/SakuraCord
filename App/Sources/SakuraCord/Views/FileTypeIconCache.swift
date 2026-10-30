import AppKit
import UniformTypeIdentifiers

/// Finder's document icons for file cards, rasterized once per file type
/// and pixel size. The type comes from the filename's extension alone, so
/// no file is read, and cards draw a cached bitmap while scrolling.
@MainActor
enum FileTypeIconCache {
    private struct Key: Hashable {
        let pathExtension: String
        let pixels: Int
    }

    private static var images: [Key: NSImage] = [:]

    /// Extensions common enough to have their icons ready before a
    /// conversation first shows them.
    private nonisolated static let commonExtensions = [
        "", "pdf", "zip", "txt", "md", "log", "json", "swift", "js", "py", "html", "csv",
        "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "rtf",
        "png", "jpg", "gif", "mp4", "mov", "mp3", "m4a", "ogg", "wav", "dmg", "bin",
    ]

    /// Rasterizes the common icons off the main thread, so opening a
    /// conversation of files never waits on Launch Services.
    static func prewarm() {
        let pixels = Int(ceil(NativeTimelineFileCard.iconSide * (NSScreen.main?.backingScaleFactor ?? 2)))
        Task.detached(priority: .utility) {
            let rendered = commonExtensions.compactMap { pathExtension in
                render(pathExtension, pixels: pixels).map { (pathExtension, $0) }
            }
            await MainActor.run {
                for (pathExtension, bitmap) in rendered {
                    images[Key(pathExtension: pathExtension, pixels: pixels)] = image(bitmap, pixels: pixels)
                }
            }
        }
    }

    static func image(forFilename filename: String, pixels: Int) -> NSImage? {
        let pathExtension = (filename as NSString).pathExtension.lowercased()
        let key = Key(pathExtension: pathExtension, pixels: pixels)
        if let image = images[key] { return image }
        guard let bitmap = render(pathExtension, pixels: pixels) else { return nil }
        if images.count >= 64 { images.removeAll(keepingCapacity: true) }
        let image = image(bitmap, pixels: pixels)
        images[key] = image
        return image
    }

    private static func image(_ bitmap: CGImage, pixels: Int) -> NSImage {
        NSImage(cgImage: bitmap, size: CGSize(width: pixels, height: pixels))
    }

    /// An unknown extension has a dynamic type, whose icon is the generic
    /// document; no extension at all is plain data.
    private nonisolated static func render(_ pathExtension: String, pixels: Int) -> CGImage? {
        let type = UTType(filenameExtension: pathExtension) ?? .data
        guard let context = ForumCardRasterizer.makeContext(
            width: pixels, height: pixels, colorSpace: ForumCardRasterizer.defaultColorSpace
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSWorkspace.shared.icon(for: type).draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
