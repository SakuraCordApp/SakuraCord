// Adapted from thumbhash, Copyright (c) 2023 Evan Wallace, MIT license. See docs/THIRD_PARTY_NOTICES.md.

import CoreGraphics
import Foundation

/// Decoder for the `placeholder` hashes Discord sends on attachments and embed media.
public enum ThumbHash {
    /// The `placeholder_version` whose layout this decoder reads.
    public static let supportedVersion = 1

    struct Bitmap {
        let width: Int
        let height: Int
        /// Straight (non-premultiplied) RGBA.
        var pixels: [UInt8]
    }

    /// A preview of at most 32×32 pixels, or nil when the hash is malformed.
    public static func image(base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64),
              let bitmap = bitmap(hash: [UInt8](data)),
              let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData) else { return nil }
        return CGImage(
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bitmap.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func bitmap(hash: [UInt8]) -> Bitmap? {
        guard hash.count >= 5 else { return nil }
        let header24 = Int(hash[0]) | Int(hash[1]) << 8 | Int(hash[2]) << 16
        let header16 = Int(hash[3]) | Int(hash[4]) << 8
        let hasAlpha = header24 >> 23 != 0
        let isLandscape = header16 >> 15 != 0
        let headerLX = isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7
        let headerLY = isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7)
        // A zero dimension has no aspect ratio; encoders never write one.
        guard headerLX > 0, headerLY > 0 else { return nil }
        // Coefficients decode from at least 3×3; the aspect ratio does not.
        let lx = max(3, headerLX)
        let ly = max(3, headerLY)
        let acStart = hasAlpha ? 6 : 5
        let counts = (luma: acCount(lx, ly), chroma: acCount(3, 3), alpha: hasAlpha ? acCount(5, 5) : 0)
        let nibbles = counts.luma + 2 * counts.chroma + counts.alpha
        guard hash.count >= acStart + (nibbles + 1) / 2 else { return nil }

        var nibbleIndex = 0
        func channel(_ count: Int, scale: Double) -> [Double] {
            (0 ..< count).map { _ in
                defer { nibbleIndex += 1 }
                let byte = hash[acStart + nibbleIndex >> 1]
                return (Double(byte >> UInt8((nibbleIndex & 1) << 2) & 15) / 7.5 - 1) * scale
            }
        }
        let lumaDC = Double(header24 & 63) / 63
        let pDC = Double(header24 >> 6 & 63) / 31.5 - 1
        let qDC = Double(header24 >> 12 & 63) / 31.5 - 1
        let alphaDC = hasAlpha ? Double(hash[5] & 15) / 15 : 1
        // Discord's client softens the reference decoder: half-strength luma
        // detail, chroma scaled by 1.1 instead of 1.25, and only the lowest luma
        // frequencies summed below (its worker's `detail: 1, pop: 1.1`).
        let lumaAC = channel(counts.luma, scale: Double(header24 >> 18 & 31) / 31 / 2)
        let pAC = channel(counts.chroma, scale: Double(header16 >> 3 & 63) / 63 * 1.1)
        let qAC = channel(counts.chroma, scale: Double(header16 >> 9 & 63) / 63 * 1.1)
        let alphaAC = hasAlpha ? channel(counts.alpha, scale: Double(hash[5] >> 4) / 15) : []

        let ratio = Double(headerLX) / Double(headerLY)
        let width = Int((ratio > 1 ? 32 : 32 * ratio).rounded())
        let height = Int((ratio > 1 ? 32 / ratio : 32).rounded())
        let columns = cosines(count: width, terms: max(lx, hasAlpha ? 5 : 3))
        let rows = cosines(count: height, terms: max(ly, hasAlpha ? 5 : 3))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width {
                var luma = lumaDC, pValue = pDC, qValue = qDC, alpha = alphaDC
                var index = 0
                for cy in 0 ..< ly {
                    let fy = rows[row][cy] * 2
                    var cx = cy == 0 ? 1 : 0
                    while cx * ly < lx * (ly - cy) {
                        if cx <= 1, cy <= 1 { luma += lumaAC[index] * columns[column][cx] * fy }
                        cx += 1
                        index += 1
                    }
                }
                index = 0
                for cy in 0 ..< 3 {
                    let fy = rows[row][cy] * 2
                    for cx in (cy == 0 ? 1 : 0) ..< 3 - cy {
                        let factor = columns[column][cx] * fy
                        pValue += pAC[index] * factor
                        qValue += qAC[index] * factor
                        index += 1
                    }
                }
                if hasAlpha {
                    index = 0
                    for cy in 0 ..< 5 {
                        let fy = rows[row][cy] * 2
                        for cx in (cy == 0 ? 1 : 0) ..< 5 - cy {
                            alpha += alphaAC[index] * columns[column][cx] * fy
                            index += 1
                        }
                    }
                }
                let blue = luma - 2 / 3 * pValue
                let red = (3 * luma - blue + qValue) / 2
                let green = red - qValue
                let offset = (row * width + column) * 4
                for (channel, value) in [red, green, blue, alpha].enumerated() {
                    pixels[offset + channel] = UInt8(max(0, 255 * min(1, value)))
                }
            }
        }
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    /// The number of AC coefficients in a triangular `nx`×`ny` block, skipping the DC term.
    private static func acCount(_ nx: Int, _ ny: Int) -> Int {
        (0 ..< ny).reduce(0) { total, cy in
            var count = 0
            var cx = cy == 0 ? 1 : 0
            while cx * ny < nx * (ny - cy) {
                count += 1
                cx += 1
            }
            return total + count
        }
    }

    private static func cosines(count: Int, terms: Int) -> [[Double]] {
        (0 ..< count).map { position in
            (0 ..< terms).map { cos(Double.pi / Double(count) * (Double(position) + 0.5) * Double($0)) }
        }
    }
}
