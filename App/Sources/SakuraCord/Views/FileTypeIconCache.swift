import AppKit
import UniformTypeIdentifiers

/// Finder's document icons for file cards, rasterized once per file type
/// and pixel size. The type comes from the filename's extension alone, so
/// no file is read, and cards draw a cached bitmap while scrolling.
@MainActor
enum FileTypeIconCache {
    private struct Key: Hashable {
        let type: String
        let pixels: Int
    }

    private static var images: [Key: CGImage] = [:]

    static func image(forFilename filename: String, pixels: Int) -> CGImage? {
        // An unknown extension gets a dynamic type, whose icon is the
        // generic document.
        let type = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        let key = Key(type: type.identifier, pixels: pixels)
        if let image = images[key] { return image }
        let icon = NSWorkspace.shared.icon(for: type)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        if images.count >= 64 { images.removeAll(keepingCapacity: true) }
        images[key] = image
        return image
    }
}
