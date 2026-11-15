import CoreGraphics

nonisolated extension CGColorSpace {
    /// The colour space offscreen bitmaps draw in when no window supplies one.
    static let bitmapDefault = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

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
