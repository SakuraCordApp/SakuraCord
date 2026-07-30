import AppKit
import SakuraCordModels

enum DiscordComponentButtonAppearance {
    static func backgroundHex(for style: ComponentButtonStyle?) -> UInt32 {
        switch style ?? .secondary {
        case .primary: 0x5865F2
        case .secondary, .link, .premium: 0x4E5058
        case .success: 0x248046
        case .destructive: 0xDA373C
        }
    }
}

nonisolated enum DiscordComponentEmojiMetrics {
    static let buttonSize: CGFloat = 16
    static let selectSize: CGFloat = 16

    static func opticalSize(for boxSize: CGFloat) -> CGFloat {
        max(0, boxSize - 2)
    }
}

@MainActor
enum ComponentUnicodeEmojiRenderer {
    private static var cache: [String: NSImage] = [:]
    private static let sourceFontSize: CGFloat = 64
    private static let canvasPadding = 16

    static func image(for value: String) -> NSImage {
        if let cached = cache[value] {
            return cached
        }

        let font = NSFont(name: "Apple Color Emoji", size: sourceFontSize)
            ?? NSFont.systemFont(ofSize: sourceFontSize)
        let attributed = NSAttributedString(string: value, attributes: [.font: font])
        let measured = attributed.size()
        let width = max(1, Int(ceil(measured.width)) + canvasPadding * 2)
        let height = max(1, Int(ceil(measured.height)) + canvasPadding * 2)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        bitmap.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            attributed.draw(at: NSPoint(x: canvasPadding, y: canvasPadding))
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let crop = opaqueBounds(in: bitmap),
              let cgImage = bitmap.cgImage?.cropping(to: crop)
        else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: crop.width, height: crop.height)
        )
        cache[value] = image
        return image
    }

    private static func opaqueBounds(in bitmap: NSBitmapImageRep) -> CGRect? {
        guard let data = bitmap.bitmapData else { return nil }
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bytesPerPixel - 1
        let alphaThreshold: UInt8 = 5
        var minimumX = bitmap.pixelsWide
        var minimumY = bitmap.pixelsHigh
        var maximumX = -1
        var maximumY = -1

        for y in 0 ..< bitmap.pixelsHigh {
            let row = data.advanced(by: y * bitmap.bytesPerRow)
            for x in 0 ..< bitmap.pixelsWide
            where row[x * bytesPerPixel + alphaOffset] > alphaThreshold {
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }
}
