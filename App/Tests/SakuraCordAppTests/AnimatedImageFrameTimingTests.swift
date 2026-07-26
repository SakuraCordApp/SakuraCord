@testable import SakuraCord
import Foundation
import ImageIO
import Testing

@Test func `small animated frames are prepared before display`() {
    #expect(AnimatedImageFramePreparation.shouldEagerlyDecode(width: 96, height: 96))
    #expect(AnimatedImageFramePreparation.shouldEagerlyDecode(width: 512, height: 512))
    #expect(!AnimatedImageFramePreparation.shouldEagerlyDecode(width: 513, height: 512))
    #expect(!AnimatedImageFramePreparation.shouldEagerlyDecode(width: 0, height: 96))
    #expect(!AnimatedImageFramePreparation.shouldEagerlyDecode(width: .max, height: .max))
}

@Test func `animated image decoding respects the requested display pixel budget`() throws {
    let width = 1_200
    let height = 800
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))

    let decoded = try DecodedAnimatedImage(data: data as Data, maximumPixelDimension: 184)
    let frame = try #require(decoded.frames.first)
    #expect(max(frame.width, frame.height) <= 184)
    #expect(decoded.estimatedByteCount <= frame.bytesPerRow * frame.height)
}

@Test func `animated image decoding preserves transparent pixels`() throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil,
            width: 2,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.clear(CGRect(x: 0, y: 0, width: 2, height: 1))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))

    let source = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, source, nil)
    #expect(CGImageDestinationFinalize(destination))

    let decoded = try DecodedAnimatedImage(data: data as Data, maximumPixelDimension: 2)
    let frame = try #require(decoded.frames.first)
    let provider = try #require(frame.dataProvider)
    let bytes = try #require(CFDataGetBytePtr(provider.data))

    #expect(frame.alphaInfo == .premultipliedLast)
    #expect(bytes[3] == 0)
    #expect(bytes[7] == 255)
}

@MainActor @Test func `animated webp uses its real frame delay`() {
    let properties: [CFString: Any] = [
        kCGImagePropertyWebPDictionary: [
            kCGImagePropertyWebPUnclampedDelayTime: NSNumber(value: 0.04)
        ] as [CFString: Any]
    ]

    #expect(AnimatedImageFrameTiming.duration(properties: properties) == 0.04)
}

@MainActor @Test func `invalid animated image delay uses bounded fallback`() {
    let properties: [CFString: Any] = [
        kCGImagePropertyWebPDictionary: [
            kCGImagePropertyWebPDelayTime: NSNumber(value: 0)
        ] as [CFString: Any]
    ]

    #expect(AnimatedImageFrameTiming.duration(properties: properties) == 0.1)
}

@MainActor @Test func `ten millisecond webp frames use browser compatible timing`() {
    let properties: [CFString: Any] = [
        kCGImagePropertyWebPDictionary: [
            kCGImagePropertyWebPUnclampedDelayTime: NSNumber(value: 0.01)
        ] as [CFString: Any]
    ]

    #expect(AnimatedImageFrameTiming.duration(properties: properties) == 0.1)
}

@Test func `animated media only plays while visible and motion is enabled`() {
    #expect(
        AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: true,
            reduceMotion: false,
            reduceAnimatedMedia: false
        )
    )
    #expect(
        !AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: false,
            reduceMotion: false,
            reduceAnimatedMedia: false
        )
    )
    #expect(
        !AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: true,
            reduceMotion: true,
            reduceAnimatedMedia: false
        )
    )
    #expect(
        !AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: true,
            reduceMotion: false,
            reduceAnimatedMedia: true
        )
    )
}
