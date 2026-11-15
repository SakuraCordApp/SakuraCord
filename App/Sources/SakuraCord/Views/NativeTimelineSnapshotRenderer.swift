import AppKit

/// Renders transition snapshots in the timeline's flipped coordinates.
@MainActor
enum NativeTimelineSnapshotRenderer {
    static func render(size: CGSize, scale: CGFloat, draw: () -> Void) -> NSImage? {
        let scale = max(1, scale)
        guard size.width > 0, size.height > 0,
              let representation = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: max(1, Int(ceil(size.width * scale))),
                  pixelsHigh: max(1, Int(ceil(size.height * scale))),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let graphics = NSGraphicsContext(bitmapImageRep: representation)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }
}
