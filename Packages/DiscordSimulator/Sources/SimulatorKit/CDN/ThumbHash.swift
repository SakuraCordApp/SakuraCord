import CoreGraphics
import Foundation
import ImageIO

/// Discord's attachment `placeholder` is a ThumbHash (version 1) of the image.
/// This is the published ThumbHash encoder, applied to a ≤100 px thumbnail.
enum ThumbHash {
    static func placeholder(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 100,
              ] as CFDictionary)
        else { return nil }
        let width = thumbnail.width, height = thumbnail.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Data(encode(width: width, height: height, rgba: rgba)).base64EncodedString()
    }

    private struct ChannelCode {
        let dc: Double
        let ac: [Double]
        let scale: Double
    }

    static func encode(width: Int, height: Int, rgba: [UInt8]) -> [UInt8] {
        var averageR = 0.0, averageG = 0.0, averageB = 0.0, averageA = 0.0
        for index in 0 ..< width * height {
            let alpha = Double(rgba[index * 4 + 3]) / 255
            averageR += alpha / 255 * Double(rgba[index * 4])
            averageG += alpha / 255 * Double(rgba[index * 4 + 1])
            averageB += alpha / 255 * Double(rgba[index * 4 + 2])
            averageA += alpha
        }
        if averageA > 0 { averageR /= averageA; averageG /= averageA; averageB /= averageA }
        let hasAlpha = averageA < Double(width * height)
        let luminanceLimit = hasAlpha ? 5.0 : 7.0
        let longest = Double(max(width, height))
        let lx = max(1, Int((luminanceLimit * Double(width) / longest).rounded()))
        let ly = max(1, Int((luminanceLimit * Double(height) / longest).rounded()))
        var lumaSamples = [Double](repeating: 0, count: width * height), pSamples = lumaSamples, qSamples = lumaSamples, alphaSamples = lumaSamples
        for index in 0 ..< width * height {
            let alpha = Double(rgba[index * 4 + 3]) / 255
            let red = averageR * (1 - alpha) + alpha / 255 * Double(rgba[index * 4])
            let green = averageG * (1 - alpha) + alpha / 255 * Double(rgba[index * 4 + 1])
            let blue = averageB * (1 - alpha) + alpha / 255 * Double(rgba[index * 4 + 2])
            lumaSamples[index] = (red + green + blue) / 3
            pSamples[index] = (red + green) / 2 - blue
            qSamples[index] = red - green
            alphaSamples[index] = alpha
        }

        func encodeChannel(_ channel: [Double], _ nx: Int, _ ny: Int) -> ChannelCode {
            var dc = 0.0, ac: [Double] = [], scale = 0.0
            var fx = [Double](repeating: 0, count: width)
            for cy in 0 ..< ny {
                var cx = 0
                while cx * ny < nx * (ny - cy) {
                    var coefficient = 0.0
                    for column in 0 ..< width { fx[column] = cos(.pi / Double(width) * Double(cx) * (Double(column) + 0.5)) }
                    for row in 0 ..< height {
                        let fy = cos(.pi / Double(height) * Double(cy) * (Double(row) + 0.5))
                        for column in 0 ..< width { coefficient += channel[column + row * width] * fx[column] * fy }
                    }
                    coefficient /= Double(width * height)
                    if cx > 0 || cy > 0 {
                        ac.append(coefficient)
                        scale = max(scale, abs(coefficient))
                    } else {
                        dc = coefficient
                    }
                    cx += 1
                }
            }
            if scale > 0 { ac = ac.map { 0.5 + 0.5 / scale * $0 } }
            return ChannelCode(dc: dc, ac: ac, scale: scale)
        }

        let lum = encodeChannel(lumaSamples, max(3, lx), max(3, ly))
        let pChannel = encodeChannel(pSamples, 3, 3)
        let qChannel = encodeChannel(qSamples, 3, 3)
        let aChannel = hasAlpha ? encodeChannel(alphaSamples, 5, 5) : nil
        let isLandscape = width > height
        func round(_ value: Double) -> Int { Int(value.rounded()) }
        let header24 = round(63 * lum.dc) | (round(31.5 + 31.5 * pChannel.dc) << 6) | (round(31.5 + 31.5 * qChannel.dc) << 12)
            | (round(31 * lum.scale) << 18) | ((hasAlpha ? 1 : 0) << 23)
        let header16 = (isLandscape ? ly : lx) | (round(63 * pChannel.scale) << 3) | (round(63 * qChannel.scale) << 9)
            | ((isLandscape ? 1 : 0) << 15)
        var hash: [UInt8] = [UInt8(header24 & 255), UInt8((header24 >> 8) & 255), UInt8(header24 >> 16),
                             UInt8(header16 & 255), UInt8(header16 >> 8)]
        if let aChannel { hash.append(UInt8(round(15 * aChannel.dc) | (round(15 * aChannel.scale) << 4))) }
        let start = hash.count
        var index = 0
        for ac in [lum.ac, pChannel.ac, qChannel.ac] + (aChannel.map { [$0.ac] } ?? []) {
            for factor in ac {
                let slot = start + (index >> 1)
                if slot >= hash.count { hash.append(0) }
                hash[slot] |= UInt8(round(15 * factor) << ((index & 1) << 2))
                index += 1
            }
        }
        return hash
    }
}
