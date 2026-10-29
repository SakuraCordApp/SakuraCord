import CoreGraphics
import Foundation
@testable import SakuraCord
import Testing

/// A 20×20 animation whose only layer is a red solid covering the top half.
private let topHalfRedLottie = Data("""
{"v":"5.6.2","fr":30,"ip":0,"op":2,"w":20,"h":20,"layers":[{"ty":1,"ind":1,"sc":"#ff0000",\
"sw":20,"sh":10,"ip":0,"op":2,"st":0,"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},\
"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}}}]}
""".utf8)

@Test func `lottie sticker frames render upright and unshifted`() throws {
    let renderer = try #require(
        LottieStickerFrameRenderer(data: topHalfRedLottie, maximumPixelDimension: nil)
    )
    #expect(renderer.frameCount == 2)
    #expect(LottieStickerFrameRenderer(data: Data("\n ".utf8) + topHalfRedLottie, maximumPixelDimension: nil) != nil)
    let frame = try #require(renderer.frame(at: 0))
    #expect(frame.width == 20 && frame.height == 20)

    var pixels = [UInt8](repeating: 0, count: 20 * 20 * 4)
    let context = try #require(CGContext(
        data: &pixels,
        width: 20,
        height: 20,
        bitsPerComponent: 8,
        bytesPerRow: 20 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(frame, in: CGRect(x: 0, y: 0, width: 20, height: 20))
    // The buffer's first row is the top of the image.
    func pixel(x: Int, y: Int) -> (red: UInt8, alpha: UInt8) {
        let offset = (y * 20 + x) * 4
        return (pixels[offset], pixels[offset + 3])
    }
    for (x, y) in [(1, 1), (18, 1), (1, 8), (18, 8)] {
        #expect(pixel(x: x, y: y).red > 200 && pixel(x: x, y: y).alpha > 200, "top (\(x), \(y))")
    }
    for (x, y) in [(1, 12), (18, 12), (1, 18), (18, 18)] {
        #expect(pixel(x: x, y: y).alpha < 50, "bottom (\(x), \(y))")
    }
}

@Test func `non lottie data is left to ImageIO`() {
    #expect(LottieStickerFrameRenderer(data: Data([0x89, 0x50, 0x4E, 0x47]), maximumPixelDimension: 384) == nil)
    #expect(LottieStickerFrameRenderer(data: Data("{}".utf8), maximumPixelDimension: 384) == nil)
}
