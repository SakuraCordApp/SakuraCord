import CoreGraphics

nonisolated extension CGContext {
    /// An 8-bit, premultiplied-first, little-endian bitmap context.
    static func premultipliedBitmap(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}
