@testable import SakuraCord
import Foundation
import ImageIO
import QuartzCore
import Testing

@Test func `small animated frames are prepared before display`() {
    #expect(AnimatedImageFramePreparation.shouldEagerlyDecode(width: 96, height: 96))
    #expect(AnimatedImageFramePreparation.shouldEagerlyDecode(width: 512, height: 512))
    #expect(!AnimatedImageFramePreparation.shouldEagerlyDecode(width: 513, height: 512))
    #expect(!AnimatedImageFramePreparation.shouldEagerlyDecode(width: 0, height: 96))
    #expect(!AnimatedImageFramePreparation.shouldEagerlyDecode(width: .max, height: .max))
}

@Test func `remote image task restarts retain the decoded image for the same request`() throws {
    let firstURL = try #require(URL(string: "https://cdn.example/avatar.webp"))
    let secondURL = try #require(URL(string: "https://cdn.example/banner.webp"))
    let displayed = AnimatedRemoteImageRequestIdentity(
        url: firstURL,
        maximumPixelDimension: 96
    )

    #expect(
        !AnimatedRemoteImageReloadPolicy.shouldReplaceDisplayedImage(
            displayed: displayed,
            requested: displayed
        )
    )
    #expect(
        AnimatedRemoteImageReloadPolicy.shouldReplaceDisplayedImage(
            displayed: displayed,
            requested: AnimatedRemoteImageRequestIdentity(
                url: firstURL,
                maximumPixelDimension: 192
            )
        )
    )
    #expect(
        AnimatedRemoteImageReloadPolicy.shouldReplaceDisplayedImage(
            displayed: displayed,
            requested: AnimatedRemoteImageRequestIdentity(
                url: secondURL,
                maximumPixelDimension: 96
            )
        )
    )
}

@Test func `visible media is scheduled ahead of queued prefetch work`() throws {
    let prefetch = try #require(URL(string: "https://cdn.example/prefetch.png"))
    let visible = try #require(URL(string: "https://cdn.example/visible.png"))
    let order = [prefetch, visible]
    let priorities: [URL: MediaLoadPriority] = [
        prefetch: .prefetch,
        visible: .visible,
    ]

    #expect(
        SharedMediaRequestSchedulingPolicy.nextURL(
            in: order,
            priorities: priorities,
            activeCount: 2,
            activePrefetchCount: 2
        ) == visible
    )
}

@Test func `prefetch media cannot consume visible request capacity`() throws {
    let prefetch = try #require(URL(string: "https://cdn.example/prefetch.png"))
    #expect(
        SharedMediaRequestSchedulingPolicy.nextURL(
            in: [prefetch],
            priorities: [prefetch: .prefetch],
            activeCount: 2,
            activePrefetchCount:
                SharedMediaRequestSchedulingPolicy.maximumConcurrentPrefetchLoads
        ) == nil
    )
}

@Test func `pending prefetch backlog is bounded`() {
    #expect(SharedMediaRequestSchedulingPolicy.acceptsPrefetch(
        pendingPrefetchCount:
            SharedMediaRequestSchedulingPolicy.maximumPendingPrefetchLoads - 1
    ))
    #expect(!SharedMediaRequestSchedulingPolicy.acceptsPrefetch(
        pendingPrefetchCount:
            SharedMediaRequestSchedulingPolicy.maximumPendingPrefetchLoads
    ))
}

@MainActor @Test
func `cached avatar frame is installed before the representable is attached`() throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let decoded = try DecodedAnimatedImage(
        data: data as Data,
        maximumPixelDimension: 68
    )
    let url = try #require(URL(string: "https://cdn.example/avatar.webp"))
    let cache = AnimatedRemoteImageDisplayCache.shared
    cache.removeAll()
    cache.insert(decoded, for: url, maximumPixelDimension: 68)

    #expect(cache.image(for: url, maximumPixelDimension: 68) === decoded)
    let canvas = AnimatedImageRepresentable.configuredCanvas(
        decodedImage: decoded,
        animates: true,
        isLooping: true,
        contentMode: .fit
    )
    #expect(canvas.layer?.contents != nil)
}

@MainActor @Test
func `recreated avatar paints its cached frame before animated content mounts`() throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let decoded = try DecodedAnimatedImage(
        data: data as Data,
        maximumPixelDimension: 64
    )
    let url = try #require(URL(string: "https://cdn.example/recreated-avatar.webp"))
    let cache = AnimatedRemoteImageDisplayCache.shared
    cache.removeAll()
    cache.insert(decoded, for: url, maximumPixelDimension: 64)

    let avatar = AvatarView(name: "Maya", url: url, size: 32)
    #expect(avatar.requestedPixelDimension == 64)
    #expect(avatar.cachedFrame === decoded.frames.first)
}

@MainActor @Test
func `remote avatars never paint the fallback beneath transparent pixels`() throws {
    let url = try #require(
        URL(string: "https://cdn.example/transparent-avatar.png")
    )

    #expect(!AvatarView(name: "Transparent", url: url, size: 32).showsFallback)
    #expect(AvatarView(name: "Fallback", url: nil, size: 32).showsFallback)
}

@MainActor @Test
func `recent displayed images use a deterministic bounded cache`() throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        )
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let decoded = try DecodedAnimatedImage(
        data: data as Data,
        maximumPixelDimension: 1
    )
    let cache = AnimatedRemoteImageDisplayCache.shared
    cache.removeAll()

    for index in 0 ... cache.maximumCountForTesting {
        let url = try #require(URL(
            string: "https://cdn.example/recent-\(index).png"
        ))
        cache.insert(decoded, for: url, maximumPixelDimension: 1)
    }

    #expect(cache.entryCountForTesting == cache.maximumCountForTesting)
    let oldest = try #require(URL(
        string: "https://cdn.example/recent-0.png"
    ))
    let newest = try #require(URL(
        string:
            "https://cdn.example/recent-\(cache.maximumCountForTesting).png"
    ))
    #expect(cache.image(for: oldest, maximumPixelDimension: 1) == nil)
    #expect(
        cache.image(for: newest, maximumPixelDimension: 1) === decoded
    )
    cache.removeAll()
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

@MainActor @Test
func `animated image canvas installs discrete compositor frames and resets to its first frame`()
    throws
{
    let encoded =
        "R0lGODlhIAAgAPIHAAAAAFhl8lhl8lhl8lhl8lhl8lhl8v///"
        + "yH/C05FVFNDQVBFMi4wAwEAAAAh+QQJAAAAACwAAAAAIAAgAA"
        + "ADVwi63P4wykmrvTjrzbv/WyAMxiAEH1EYbGsUBEeQrjvE2lr"
        + "XhRbsQBRGANwJMrRia5BR7pDOZYYYNRwxv6oQo1P2NDPlTdZ1"
        + "wT4ikmkLarvf8Lh8Tt8kAAAh+QQJAAAAACwAAAAAIAAgAIIAAA"
        + "DtQkXtQkXtQkXtQkXtQkXtQkX///8DVwi63P4wykmrvTjrzbv"
        + "/4BMIgzEIwUcURusaBcER5fsOssbadqEFvGAKIwjyBJma0TXIL"
        + "HnJJzNTlBqQGKB1iNktfRraEjfzvmKfUenEDbnf8Lh8Tp8nAA"
        + "A7"
    let data = try #require(Data(base64Encoded: encoded))
    let decoded = try DecodedAnimatedImage(
        data: data,
        maximumPixelDimension: 64
    )
    #expect(decoded.frames.count == 2)

    let canvas = AnimatedImageCanvas(
        frame: CGRect(x: 0, y: 0, width: 18, height: 18)
    )
    canvas.display(decoded, animates: true, isLooping: true)
    #expect(canvas.layer?.contentsGravity == .resizeAspect)
    let animation = try #require(
        canvas.layer?.animation(
            forKey: "remoteAnimatedImage"
        ) as? CAKeyframeAnimation
    )
    #expect(animation.values?.count == 2)
    #expect(animation.calculationMode == .discrete)
    #expect(animation.repeatCount == .infinity)
    #expect(animation.duration == 0.2)

    canvas.display(decoded, animates: false, isLooping: true)
    #expect(
        canvas.layer?.animation(forKey: "remoteAnimatedImage") == nil
    )
    #expect(
        (canvas.layer?.contents as AnyObject?)
            === decoded.frames.first
    )

    canvas.display(
        decoded,
        animates: false,
        isLooping: true,
        contentMode: .fill
    )
    #expect(canvas.layer?.contentsGravity == .resizeAspectFill)
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
