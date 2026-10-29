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

    static func image(forFilename filename: String, pixels: Int) -> NSImage? {
        let pathExtension = (filename as NSString).pathExtension.lowercased()
        let key = Key(pathExtension: pathExtension, pixels: pixels)
        if let image = images[key] { return image }
        // An unknown extension has a dynamic type, whose icon is the generic
        // document; no extension at all is plain data.
        let type = UTType(filenameExtension: pathExtension) ?? .data
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSWorkspace.shared.icon(for: type).draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let bitmap = context.makeImage() else { return nil }
        if images.count >= 64 { images.removeAll(keepingCapacity: true) }
        let image = NSImage(cgImage: bitmap, size: CGSize(width: pixels, height: pixels))
        images[key] = image
        return image
    }
}
