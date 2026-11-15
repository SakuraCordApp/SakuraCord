@testable import SakuraCord
import Foundation
import ImageIO
import QuartzCore
import SakuraCordModels
import Testing

@Test func `small animated frames are prepared before display`() {
    #expect(AnimatedImageFramePreparation.shouldEagerlyDecode(width: 96, height: 96))
    #expect(AnimatedImageFramePreparation.shouldEagerlyDecode(width: 512, height: 512))
    #expect(!AnimatedImageFramePreparation.shouldEagerlyDecode(width: 513, height: 512))
    #expect(!AnimatedImageFramePreparation.shouldEagerlyDecode(width: 0, height: 96))
    #expect(!AnimatedImageFramePreparation.shouldEagerlyDecode(width: .max, height: .max))
}

@Test func `animation expansion drops only frames above thirty fps`() {
    let sixtyFPS = AnimatedImageFrameSelection.selections(
        for: Array(repeating: 1 / 60, count: 6)
    )
    let tenFPS = AnimatedImageFrameSelection.selections(
        for: Array(repeating: 0.1, count: 4)
    )

    #expect(sixtyFPS.map(\.index) == [0, 2, 4])
    #expect(sixtyFPS.allSatisfy {
        abs($0.duration - (1 / 30)) < 0.000_001
    })
    #expect(abs(sixtyFPS.map(\.duration).reduce(0, +) - 0.1) < 0.000_001)
    #expect(tenFPS.map(\.index) == [0, 1, 2, 3])
    #expect(abs(tenFPS.map(\.duration).reduce(0, +) - 0.4) < 0.000_001)
}

@Test func `sub frame duration loops retain visible motion`() {
    let selections = AnimatedImageFrameSelection.selections(
        for: Array(repeating: 0.005, count: 4)
    )

    #expect(selections.map(\.index) == [0, 2])
    #expect(abs(selections.map(\.duration).reduce(0, +) - 0.02) < 0.000_001)
}

@Test func `full animated expansion is serialized at background priority`() {
    #expect(
        AnimatedImageDecodePolicy
            .maximumConcurrentDecodes == 1
    )
    #expect(
        AnimatedImageDecodePolicy.taskPriority == .background
    )
}

@Test func `animated expansion cooperatively interrupts for scrolling`() {
    #expect(throws: AnimatedImageDecodeInterruption.self) {
        _ = try DecodedAnimatedImage(
            data: Data(),
            maximumPixelDimension: 68,
            shouldInterrupt: { true }
        )
    }
}

@Test func `new animated expansion waits until interactive scrolling ends`() async {
    let scheduler = SharedAnimatedImageDecodeScheduler()
    await scheduler.setInteractiveScrolling(
        true,
        source: .timeline,
        revision: 2
    )
    // A stale end callback must not reopen the lane after a newer scroll-start
    // callback has already arrived.
    await scheduler.setInteractiveScrolling(
        false,
        source: .timeline,
        revision: 1
    )
    let decode = Task {
        try? await scheduler.decode(
            data: Data(),
            maximumPixelDimension: 68
        )
    }

    #expect(await eventually { await scheduler.stateForTesting.waitingCount == 1 })
    var state = await scheduler.stateForTesting
    #expect(state.activeCount == 0)
    #expect(state.waitingCount == 1)
    #expect(state.isDeferred)

    let memberListSource = AnimatedImageInteractiveScrollSource.memberList(UUID())
    await scheduler.setInteractiveScrolling(
        true,
        source: memberListSource,
        revision: 1
    )
    await scheduler.setInteractiveScrolling(
        false,
        source: .timeline,
        revision: 3
    )
    state = await scheduler.stateForTesting
    #expect(state.isDeferred)

    await scheduler.setInteractiveScrolling(
        false,
        source: memberListSource,
        revision: 2
    )
    _ = await decode.value
    state = await scheduler.stateForTesting
    #expect(state.activeCount == 0)
    #expect(state.waitingCount == 0)
    #expect(!state.isDeferred)
}

@Test func `mounted static images use visible scheduling`() {
    #expect(StaticRemoteImage.loadPriority == .visible)
}

@Test func `timeline media declares every byte limited memory cache`() {
    #expect(
        MediaMemoryPolicy.decodedImageCacheBytes
            == 176 * 1_024 * 1_024
    )
    let sharedMediaBytes = SharedMediaDataMemoryPolicy.remoteBytes + SharedMediaDataMemoryPolicy.localBytes
    #expect(sharedMediaBytes == 56 * 1_024 * 1_024)
    #expect(MediaMemoryPolicy.decodedImageCacheBytes + sharedMediaBytes == 232 * 1_024 * 1_024)
}

@MainActor @Test
func `timeline animated expansion stops when its final viewport owner leaves`() async throws {
    let store = MediaImageStore()
    let key = MediaImageKey.media(try #require(URL(
        string: "https://cdn.example/obsolete-animation.gif"
    )))
    let firstOwner = UUID()
    let secondOwner = UUID()
    let firstSubscriber = MediaImageStore.SubscriberID(
        owner: firstOwner,
        subscriber: NativeMessageTimelineItem.Identifier.message(.server(
            channelID: ChannelID(rawValue: 1),
            messageID: MessageID(rawValue: 1)
        ))
    )
    let secondSubscriber = MediaImageStore.SubscriberID(
        owner: secondOwner,
        subscriber: NativeMessageTimelineItem.Identifier.message(.server(
            channelID: ChannelID(rawValue: 1),
            messageID: MessageID(rawValue: 2)
        ))
    )
    let task = Task<Void, Never> {
        try? await Task.sleep(for: .seconds(30))
    }
    store.animatedSubscribers[key] = [
        firstSubscriber: {},
        secondSubscriber: {},
    ]
    store.animatedLoading.insert(key)
    store.animatedLoadingTaskIDs[key] = UUID()
    store.animatedLoadingTasks[key] = task

    store.cancelAnimatedRequests(owner: firstOwner)

    #expect(store.animatedSubscribers[key]?.count == 1)
    #expect(store.animatedLoading.contains(key))
    #expect(store.animatedLoadingTasks[key] != nil)
    #expect(!task.isCancelled)

    store.cancelAnimatedRequests(owner: secondOwner)
    await task.value

    #expect(store.animatedSubscribers[key] == nil)
    #expect(!store.animatedLoading.contains(key))
    #expect(store.animatedLoadingTaskIDs[key] == nil)
    #expect(store.animatedLoadingTasks[key] == nil)
    #expect(task.isCancelled)
}

@Test func `peripheral thumbnail decoding leaves capacity for message media`() {
    #expect(NativeTimelineMediaDecodeScheduler.maximumConcurrentDecodes == 2)
    #expect(
        NativeTimelineMediaDecodeScheduler
            .maximumConcurrentPrefetchDecodes == 1
    )
}

@Test func `cancelled queued static decode releases its retained work immediately`() async {
    let scheduler = NativeTimelineMediaDecodeScheduler()
    #expect(await scheduler.acquirePermitForTesting(priority: .visible))
    #expect(await scheduler.acquirePermitForTesting(priority: .visible))
    let queued = Task {
        await scheduler.decode(
            Data(repeating: 0, count: 4 * 1_024 * 1_024),
            maximumPixelDimension: 1_024,
            priority: .visible
        )
    }
    #expect(await eventually { await scheduler.snapshot().visibleWaiterCount == 1 })

    queued.cancel()
    _ = await queued.value

    #expect(await scheduler.snapshot().visibleWaiterCount == 0)
    #expect(await scheduler.snapshot().activeCount == 2)
    await scheduler.releasePermitForTesting(priority: .visible)
    await scheduler.releasePermitForTesting(priority: .visible)
}

@Test func `cancelled admitted static decode cancels its detached worker`() async {
    let probe = StaticDecodeCancellationProbe()
    let scheduler = NativeTimelineMediaDecodeScheduler { _, _ in
        probe.decodeUntilCancelled()
    }
    let decode = Task {
        await scheduler.decode(
            Data(repeating: 0, count: 1_024),
            maximumPixelDimension: 96,
            priority: .visible
        )
    }
    #expect(await probe.waitUntilStarted())

    decode.cancel()
    #expect(await decode.value == nil)

    #expect(probe.observedCancellation)
    #expect(await scheduler.snapshot().activeCount == 0)
}

private final class StaticDecodeCancellationProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var cancelled = false

    var observedCancellation: Bool {
        condition.withLock { cancelled }
    }

    func decodeUntilCancelled() -> CGImage? {
        condition.withLock {
            started = true
            condition.broadcast()
        }
        for _ in 0 ..< 1_000 where !Task.isCancelled {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let observedCancellation = Task.isCancelled
        condition.withLock {
            cancelled = observedCancellation
        }
        return nil
    }

    func waitUntilStarted() async -> Bool {
        await eventually { condition.withLock { started } }
    }
}

@Test func `timeline lottie parsing and retention stay bounded`() {
    #expect(TimelineLottieLoadingPolicy.maximumConcurrentParses == 1)
    #expect(TimelineLottieLoadingPolicy.maximumCachedAnimations == 12)
}

@Test func `slow lottie download does not block a fast visible download`() async throws {
    let slowURL = try #require(URL(string: "https://cdn.example/slow.json"))
    let fastURL = try #require(URL(string: "https://cdn.example/fast.json"))
    let gate = ControlledLottieDataLoader(slowURL: slowURL)
    let loader = SharedTimelineLottieAnimationLoader { url in
        await gate.data(for: url)
    }
    let slow = Task {
        await loader.animation(for: slowURL)
    }
    await gate.waitUntilSlowStarted()
    let fast = Task {
        _ = await loader.animation(for: fastURL)
        return true
    }

    let fastCompletedFirst = await withTaskGroup(of: Bool.self) { group in
        group.addTask { await fast.value }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(200))
            await gate.releaseSlow()
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }

    #expect(fastCompletedFirst)
    await gate.releaseSlow()
    _ = await slow.value
}

private actor ControlledLottieDataLoader {
    private let slowURL: URL
    private var didStartSlow = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(slowURL: URL) {
        self.slowURL = slowURL
    }

    func data(for url: URL) async -> Data {
        if url == slowURL {
            didStartSlow = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !isReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        return Data("{}".utf8)
    }

    func waitUntilSlowStarted() async {
        guard !didStartSlow else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseSlow() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
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
    #expect(SharedMediaRequestSchedulingPolicy.acceptsRemoteLoad(
        pendingRemoteCount:
            SharedMediaRequestSchedulingPolicy.maximumPendingRemoteLoads - 1
    ))
    #expect(!SharedMediaRequestSchedulingPolicy.acceptsRemoteLoad(
        pendingRemoteCount:
            SharedMediaRequestSchedulingPolicy.maximumPendingRemoteLoads
    ))
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
    let url = try #require(URL(
        string:
            "https://cdn.example/recreated-avatar.webp?animated=true"
    ))
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
    // Evicting complete animations must not blank a remounted image view.
    #expect(AnimatedImagePosterCache.shared.image(for: oldest, maximumPixelDimension: 1) === decoded.frames.first)
    #expect(
        cache.image(for: newest, maximumPixelDimension: 1) === decoded
    )
    cache.removeAll()

    // The independent poster budget still evicts by cost and recent use.
    let frame = try #require(decoded.frames.first)
    let posters = AnimatedImagePosterCache(maximumCost: frame.bytesPerRow * frame.height * 2)
    let third = try #require(URL(string: "https://cdn.example/third.png"))
    posters.insert(frame, for: oldest, maximumPixelDimension: 1)
    posters.insert(frame, for: newest, maximumPixelDimension: 1)
    #expect(posters.image(for: oldest, maximumPixelDimension: 1) === frame)
    posters.insert(frame, for: third, maximumPixelDimension: 1)
    #expect(posters.image(for: newest, maximumPixelDimension: 1) == nil)
    #expect(posters.image(for: oldest, maximumPixelDimension: 1) === frame)
    #expect(posters.image(for: third, maximumPixelDimension: 1) === frame)
    #expect(posters.image(for: third, maximumPixelDimension: 2) == nil)
    posters.removeAll()
    #expect(posters.image(for: third, maximumPixelDimension: 1) == nil)
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
func `animated image canvas pauses or resets without discarding frames`()
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

    canvas.setPlaybackSuppressed(true)
    #expect(canvas.layer?.speed == 0)
    #expect(
        canvas.layer?.animation(forKey: "remoteAnimatedImage") != nil
    )
    #expect(canvas.layer?.contents != nil)

    let layer = try #require(canvas.layer)
    let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
    #expect(layer.convertTime(CACurrentMediaTime() + 60, from: nil) == pausedTime)
    canvas.setPlaybackSuppressed(false)
    #expect(layer.speed == 1)
    #expect(
        canvas.layer?.animation(forKey: "remoteAnimatedImage") != nil
    )

    canvas.display(decoded, animates: false, isLooping: true)
    #expect(canvas.layer?.speed == 0)
    #expect(
        canvas.layer?.animation(forKey: "remoteAnimatedImage") != nil
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

    canvas.display(decoded, animates: true, isLooping: true, resetsWhenStopped: true)
    let hoverAnimation = try #require(layer.animation(forKey: "remoteAnimatedImage"))
    canvas.display(decoded, animates: false, isLooping: true, resetsWhenStopped: true)
    #expect(layer.animation(forKey: "remoteAnimatedImage") == nil)
    #expect((layer.contents as AnyObject?) === decoded.frames.first)
    #expect(layer.speed == 0)
    #expect(canvas.displayedImage === decoded)

    canvas.display(decoded, animates: true, isLooping: true, resetsWhenStopped: true)
    let restartedAnimation = try #require(layer.animation(forKey: "remoteAnimatedImage"))
    #expect(restartedAnimation.beginTime >= hoverAnimation.beginTime)
    #expect(layer.speed == 1)
    #expect(canvas.displayedImage === decoded)
}

@Test func `bounded frames preserve source loops effect gaps and completion`() {
    let schedule = AnimatedImageFrameSchedule(durations: [0.25, 0.5, 0.25])
    func frame(_ elapsed: Double, loops: Bool = true, active: Double? = nil, delay: Double = 0, count: Int? = nil) -> Int? {
        schedule.frameIndex(
            elapsed: elapsed,
            playCount: count, isLooping: loops, activeDuration: active, loopDelay: delay
        )
    }
    #expect(frame(-0.1) == nil)
    #expect(frame(0) == 0)
    #expect(frame(0.25) == 1)
    #expect(frame(0.75) == 2)
    #expect(frame(1) == 0)
    #expect(frame(1, loops: false) == 0)
    #expect(frame(1.25, active: 4, count: 1) == 2)
    #expect(frame(1.25, active: 4, count: 2) == 1)
    #expect(frame(2.25, active: 4, count: 2) == 2)
    #expect(frame(1.25, active: 2, delay: 1) == 1)
    #expect(frame(2, active: 2, delay: 1) == nil)
    #expect(frame(2.75, active: 2, delay: 1) == nil)
    #expect(frame(3, active: 2, delay: 1) == 0)
    #expect(frame(3.25, active: 2, delay: 1, count: 1) == 1)
    #expect(frame(1.25, loops: false, active: 2, count: 1) == 2)
    #expect(frame(2, loops: false, active: 2, count: 1) == nil)
    #expect(frame(1, loops: false, active: 0) == nil)
}

@Test func `animated media only plays while visible and motion is enabled`() {
    #expect(
        AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: true,
            reduceMotion: false
        )
    )
    #expect(
        !AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: false,
            reduceMotion: false
        )
    )
    #expect(
        !AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: true,
            isWindowVisible: false,
            reduceMotion: false
        )
    )
    #expect(
        !AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: true,
            reduceMotion: true
        )
    )
}
