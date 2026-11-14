import AppKit
import ImageIO
import OSLog
import QuartzCore
import SwiftUI

nonisolated struct AnimatedRemoteImageRequestIdentity: Hashable {
    let url: URL
    let maximumPixelDimension: Int?
}

nonisolated enum AnimatedRemoteImageReloadPolicy {
    static func shouldReplaceDisplayedImage(
        displayed: AnimatedRemoteImageRequestIdentity?,
        requested: AnimatedRemoteImageRequestIdentity
    ) -> Bool {
        displayed != requested
    }
}

/// Displays remote GIF/APNG/WebP assets without flattening them to their first frame.
struct AnimatedRemoteImage: View {
    let url: URL
    var animates = true
    var isLooping = true
    var playback: AnimatedImagePlayback?
    var previewImage: NSImage?
    var fallbackSystemImage: String?
    var fallbackInset: CGFloat = InterfaceScale.metric(2)
    var maximumPixelDimension: Int?
    var contentMode: ContentMode = .fit
    var onFailure: (() -> Void)?
    var usesSwiftUIRendering = false
    var resetsWhenStopped = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playsAnimatedImages
    @State private var decodedImage: DecodedAnimatedImage?
    @State private var cachedPoster: CGImage?
    @State private var displayedLoadID: AnimatedRemoteImageRequestIdentity?
    @State private var didFail = false

    init(
        url: URL,
        animates: Bool = true,
        isLooping: Bool = true,
        playback: AnimatedImagePlayback? = nil,
        loadedImage: DecodedAnimatedImage? = nil,
        previewImage: NSImage? = nil,
        fallbackSystemImage: String? = nil,
        fallbackInset: CGFloat = 2,
        maximumPixelDimension: Int? = nil,
        contentMode: ContentMode = .fit,
        usesSwiftUIRendering: Bool = false,
        resetsWhenStopped: Bool = false,
        onFailure: (() -> Void)? = nil
    ) {
        self.url = url
        self.animates = animates
        self.isLooping = isLooping
        self.playback = playback
        self.previewImage = previewImage
        self.fallbackSystemImage = fallbackSystemImage
        self.fallbackInset = fallbackInset
        self.maximumPixelDimension = maximumPixelDimension
        self.contentMode = contentMode
        self.usesSwiftUIRendering = usesSwiftUIRendering
        self.resetsWhenStopped = resetsWhenStopped
        self.onFailure = onFailure

        let loadID = AnimatedRemoteImageRequestIdentity(
            url: url,
            maximumPixelDimension: maximumPixelDimension
        )
        let (cached, poster) = Self.cachedDisplay(
            url: url, maximumPixelDimension: maximumPixelDimension, loadedImage: loadedImage
        )
        _decodedImage = State(initialValue: cached)
        _cachedPoster = State(initialValue: poster)
        _displayedLoadID = State(initialValue: cached == nil ? nil : loadID)
    }

    /// What can show at once: the decoded image a cache holds, and its first
    /// frame or a cached poster.
    private static func cachedDisplay(
        url: URL,
        maximumPixelDimension: Int?,
        loadedImage: DecodedAnimatedImage? = nil
    ) -> (image: DecodedAnimatedImage?, poster: CGImage?) {
        let image = loadedImage ?? AnimatedRemoteImageDisplayCache.shared.image(
            for: url,
            maximumPixelDimension: maximumPixelDimension
        )
        return (image, image?.frames.first ?? AnimatedImagePosterCache.shared.image(
            for: url, maximumPixelDimension: maximumPixelDimension
        ))
    }

    var body: some View {
        Group {
            if let decodedImage {
                if usesSwiftUIRendering || decodedImage.frames.count == 1 {
                    SwiftUIAnimatedImage(image: decodedImage, animates: animates && !accessibilityReducesAnimation,
                                         isLooping: isLooping, contentMode: contentMode, resetsWhenStopped: resetsWhenStopped)
                        .id(ObjectIdentifier(decodedImage))
                } else {
                    AnimatedImageRepresentable(
                        decodedImage: decodedImage,
                        animates: animates && !accessibilityReducesAnimation,
                        isLooping: isLooping,
                        contentMode: contentMode,
                        playback: accessibilityReducesAnimation ? nil : playback,
                        resetsWhenStopped: resetsWhenStopped
                    )
                }
            } else if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let cachedPoster {
                Image(decorative: cachedPoster, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if didFail,
                      let fallbackSystemImage,
                      let fallbackImage = SakuraCordSystemSymbol.image(
                          named: fallbackSystemImage
                      )
            {
                Image(nsImage: fallbackImage)
                    .resizable()
                    .scaledToFit()
                    .padding(fallbackInset)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
            }
        }
        .task(id: AnimatedRemoteImageRequestIdentity(
            url: url,
            maximumPixelDimension: maximumPixelDimension
        )) {
            let loadID = AnimatedRemoteImageRequestIdentity(
                url: url,
                maximumPixelDimension: maximumPixelDimension
            )
            if AnimatedRemoteImageReloadPolicy.shouldReplaceDisplayedImage(
                displayed: displayedLoadID,
                requested: loadID
            ) {
                (decodedImage, cachedPoster) = Self.cachedDisplay(url: url, maximumPixelDimension: maximumPixelDimension)
                displayedLoadID = decodedImage == nil ? nil : loadID
            }
            guard decodedImage == nil else {
                didFail = false
                return
            }
            didFail = false
            do {
                let image = try await SharedAnimatedImageLoader.shared.image(
                    for: url,
                    maximumPixelDimension: maximumPixelDimension
                )
                guard !Task.isCancelled else { return }
                AnimatedRemoteImageDisplayCache.shared.insert(
                    image,
                    for: url,
                    maximumPixelDimension: maximumPixelDimension
                )
                decodedImage = image
                cachedPoster = image.frames.first
                displayedLoadID = loadID
            } catch {
                guard !Task.isCancelled else { return }
                decodedImage = nil
                displayedLoadID = nil
                didFail = true
                onFailure?()
            }
        }
    }

    private var accessibilityReducesAnimation: Bool {
        reduceMotion || !playsAnimatedImages
    }
}

final class AnimatedRemoteImageDisplayCache: @unchecked Sendable {
    static let shared = AnimatedRemoteImageDisplayCache()

    private struct Entry {
        let image: DecodedAnimatedImage
        let cost: Int
    }

    private let maximumCount = 128
    private let maximumCost =
        MediaMemoryPolicy.displayedAnimatedImageBytes
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    private var totalCost = 0

    func image(
        for url: URL,
        maximumPixelDimension: Int?
    ) -> DecodedAnimatedImage? {
        let key = key(
            url: url,
            maximumPixelDimension: maximumPixelDimension
        )
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.image
    }

    func insert(
        _ image: DecodedAnimatedImage,
        for url: URL,
        maximumPixelDimension: Int?
    ) {
        if let frame = image.frames.first {
            AnimatedImagePosterCache.shared.insert(frame, for: url, maximumPixelDimension: maximumPixelDimension)
        }
        let key = key(
            url: url,
            maximumPixelDimension: maximumPixelDimension
        )
        let entry = Entry(
            image: image,
            cost: max(1, image.storedByteCount)
        )
        lock.lock()
        defer { lock.unlock() }
        if let previous = entries[key] {
            totalCost -= previous.cost
            entries[key] = nil
            recency.removeAll { $0 == key }
        }
        guard entry.cost <= maximumCost else {
            return
        }
        entries[key] = entry
        totalCost += entry.cost
        recency.append(key)
        evictIfNeeded()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
        totalCost = 0
        lock.unlock()
    }

#if DEBUG
    var entryCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var maximumCountForTesting: Int {
        maximumCount
    }
#endif

    private func key(
        url: URL,
        maximumPixelDimension: Int?
    ) -> String {
        "\(url.absoluteString)#display-pixel-max=\(maximumPixelDimension ?? 0)"
    }

    private func evictIfNeeded() {
        while entries.count > maximumCount
            || totalCost > maximumCost
        {
            guard let key = recency.first,
                  let removed = entries.removeValue(forKey: key)
            else { return }
            recency.removeAll { $0 == key }
            totalCost -= removed.cost
        }
    }
}

nonisolated final class DecodedAnimatedImage: @unchecked Sendable {
    private static let performanceLogger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "AnimatedMediaPerformance"
    )
    private static let reportsPerformance =
        ProcessInfo.processInfo.arguments.contains {
            $0.contains("chat-performance") || $0 == "--debug-authenticated-gesture-scroll-performance"
        }

    let frames: [CGImage]
    let frameDurations: [TimeInterval]
    let frameSchedule: AnimatedImageFrameSchedule
    let playCount: Int?
    let estimatedByteCount: Int
    /// The memory the animation keeps: frames stay compressed between draws,
    /// so this, not the expanded size, is what caches should charge.
    let storedByteCount: Int
    let compressedFrameData: [Data?]

    init(frames: [CGImage], frameDurations: [TimeInterval], playCount: Int?, compressedFrameData: [Data?]) {
        self.frames = frames
        self.frameDurations = frameDurations
        frameSchedule = AnimatedImageFrameSchedule(durations: frameDurations)
        self.playCount = playCount
        self.compressedFrameData = compressedFrameData
        estimatedByteCount = frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        storedByteCount = zip(frames, compressedFrameData).reduce(0) {
            $0 + ($1.1?.count ?? $1.0.bytesPerRow * $1.0.height)
        }
    }

    nonisolated init(
        data: Data,
        maximumPixelDimension: Int?,
        shouldInterrupt: @escaping @Sendable () -> Bool = { false }
    ) throws {
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let decodeSignpost = AppPerformanceSignposts.signposter.beginInterval(
            "AnimatedImageDecode"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "AnimatedImageDecode",
                decodeSignpost
            )
        }
        try Self.checkInterruption(shouldInterrupt)
        let source = try Self.frameSource(
            data: data,
            maximumPixelDimension: maximumPixelDimension,
            shouldInterrupt: shouldInterrupt
        )
        let frameCount = source.durations.count
        playCount = source.playCount
        let selections = AnimatedImageFrameSelection.selections(
            for: source.durations
        )
        var frames: [CGImage] = []
        var frameDurations: [TimeInterval] = []
        var estimatedByteCount = 0
        var storedByteCount = 0
        var compressedFrameData: [Data?] = []
        frames.reserveCapacity(selections.count)
        frameDurations.reserveCapacity(selections.count)
        for selection in selections {
            // Frame expansion is synchronous. Checking between frames lets a
            // viewport change abandon a large animation instead of finishing
            // obsolete work after the media has scrolled away.
            try Self.checkInterruption(shouldInterrupt)
            guard let image = source.makeFrame(selection.index) else { continue }
            // ImageIO has already been asked to decode every selected frame
            // immediately. A second CGContext redraw of every frame doubled
            // memory bandwidth for no visual gain. Prepare only the first
            // compositor frame so mounting the overlay cannot defer work onto
            // the main thread.
            let prepared = frames.isEmpty
                ? AnimatedImageFramePreparation.prepare(image)
                : image
            let storage = frames.isEmpty
                ? CompressedAnimatedFrame.Result(image: prepared, storedByteCount: prepared.bytesPerRow * prepared.height)
                : CompressedAnimatedFrame.store(prepared)
            frames.append(storage.image)
            frameDurations.append(selection.duration)
            estimatedByteCount += prepared.bytesPerRow * prepared.height
            storedByteCount += storage.storedByteCount
            compressedFrameData.append(storage.compressedData)
            if storage.image !== prepared {
                source.discardFrame(selection.index)
            }
        }
        guard !frames.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        self.frames = frames
        self.frameDurations = frameDurations
        frameSchedule = AnimatedImageFrameSchedule(durations: frameDurations)
        self.estimatedByteCount = estimatedByteCount
        self.storedByteCount = storedByteCount
        self.compressedFrameData = compressedFrameData
        reportPerformance(
            startedAt: decodeStart, sourceBytes: data.count,
            sourceFrameCount: frameCount, maximumPixelDimension: maximumPixelDimension
        )
    }

    private struct FrameSource {
        let durations: [TimeInterval]
        let playCount: Int?
        let makeFrame: (Int) -> CGImage?
        var discardFrame: (Int) -> Void = { _ in }
    }

    /// Lottie stickers are rendered frame by frame; everything else is
    /// expanded by ImageIO.
    private nonisolated static func frameSource(
        data: Data,
        maximumPixelDimension: Int?,
        shouldInterrupt: @Sendable () -> Bool
    ) throws -> FrameSource {
        if let lottie = LottieStickerFrameRenderer(
            data: data,
            maximumPixelDimension: maximumPixelDimension
        ) {
            return FrameSource(
                durations: Array(repeating: lottie.frameDuration, count: lottie.frameCount),
                playCount: nil,
                makeFrame: lottie.frame(at:)
            )
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let webP = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]

        var durations: [TimeInterval] = []
        durations.reserveCapacity(frameCount)
        for index in 0 ..< frameCount {
            try checkInterruption(shouldInterrupt)
            durations.append(
                AnimatedImageFrameTiming.duration(
                    source: source,
                    index: index
                )
            )
        }
        let thumbnailOptions: CFDictionary? = maximumPixelDimension.map { maximumPixelDimension in
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelDimension),
            ] as CFDictionary
        }
        let imageOptions = [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return FrameSource(
            durations: durations,
            playCount: (png?[kCGImagePropertyAPNGLoopCount] as? NSNumber)?.intValue
                ?? (webP?[kCGImagePropertyWebPLoopCount] as? NSNumber)?.intValue,
            makeFrame: { index in
                thumbnailOptions.flatMap {
                    CGImageSourceCreateThumbnailAtIndex(source, index, $0)
                } ?? CGImageSourceCreateImageAtIndex(source, index, imageOptions)
            },
            discardFrame: { CGImageSourceRemoveCacheAtIndex(source, $0) }
        )
    }

    private func reportPerformance(
        startedAt: TimeInterval, sourceBytes: Int,
        sourceFrameCount: Int, maximumPixelDimension: Int?
    ) {
        guard Self.reportsPerformance else { return }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        Self.performanceLogger.notice(
            """
            Animated decode: \(milliseconds, format: .fixed(precision: 2), privacy: .public) ms;
            pixel max \(maximumPixelDimension ?? 0, privacy: .public);
            source \(sourceBytes, privacy: .public) bytes;
            frames \(sourceFrameCount, privacy: .public) -> \(self.frames.count, privacy: .public);
            decoded \(self.estimatedByteCount, privacy: .public) bytes;
            stored \(self.storedByteCount, privacy: .public) bytes
            """
        )
    }

    private nonisolated static func checkInterruption(
        _ shouldInterrupt: @Sendable () -> Bool
    ) throws {
        try Task.checkCancellation()
        if shouldInterrupt() {
            throw AnimatedImageDecodeInterruption.scrollActivity
        }
    }
}

nonisolated enum AnimatedImageDecodeInterruption: Error {
    case scrollActivity
}

nonisolated enum AnimatedImageFrameSelection {
    struct Selection: Equatable, Sendable {
        let index: Int
        let duration: TimeInterval
    }

    /// Core Animation can present these frames at display refresh without
    /// decoding them again. Frames above 30 fps are visually redundant in a
    /// scrolling chat surface but expensive for ImageIO to expand and retain.
    static let minimumFrameDuration: TimeInterval = 1 / 30

    static func selections(
        for durations: [TimeInterval]
    ) -> [Selection] {
        guard !durations.isEmpty else { return [] }
        guard durations.count > 1 else {
            return [Selection(index: 0, duration: durations[0])]
        }

        var selections: [Selection] = []
        var groupStart = 0
        var groupDuration: TimeInterval = 0
        for (index, duration) in durations.enumerated() {
            groupDuration += duration
            if groupDuration >= minimumFrameDuration
                || index == durations.index(before: durations.endIndex)
            {
                selections.append(Selection(
                    index: groupStart,
                    duration: groupDuration
                ))
                groupStart = index + 1
                groupDuration = 0
            }
        }

        // Very short reaction animations can complete one loop inside a
        // single 30 Hz interval. Preserve motion rather than flattening them
        // to one frame; ordinary animations still use the bounded path above.
        if selections.count == 1 {
            let split = max(1, durations.count / 2)
            return [
                Selection(
                    index: 0,
                    duration: durations[..<split].reduce(0, +)
                ),
                Selection(
                    index: split,
                    duration: durations[split...].reduce(0, +)
                ),
            ]
        }
        return selections
    }
}

enum AnimatedImageFramePreparation {
    nonisolated static let maximumEagerPixelCount = 512 * 512

    nonisolated static func shouldEagerlyDecode(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixelCount <= maximumEagerPixelCount
    }

    nonisolated static func prepare(_ image: CGImage) -> CGImage {
        guard shouldEagerlyDecode(width: image.width, height: image.height),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return context.makeImage() ?? image
    }
}

actor SharedAnimatedImageLoader {
    static let shared = SharedAnimatedImageLoader()
    private static let cacheLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "AnimatedMediaPerformance")

    private struct InFlightRequest {
        let id: UUID
        let task: Task<DecodedAnimatedImage, any Error>
        var waiterIDs: Set<UUID>
    }

    private struct RequestKey: Hashable, Sendable {
        let url: URL
        let maximumPixelDimension: Int?

        var cacheKey: NSString {
            "\(url.absoluteString)#pixel-max=\(maximumPixelDimension ?? 0)" as NSString
        }
    }

    private let cache = NSCache<NSString, DecodedAnimatedImage>()
    private var inFlight: [RequestKey: InFlightRequest] = [:]

    init() {
        cache.totalCostLimit =
            MediaMemoryPolicy.sharedAnimatedImageBytes
        cache.countLimit = 96
    }

    func image(for url: URL, maximumPixelDimension: Int?) async throws -> DecodedAnimatedImage {
        let key = RequestKey(
            url: url,
            maximumPixelDimension: maximumPixelDimension.map { max(1, $0) }
        )
        if let cached = cache.object(forKey: key.cacheKey) { return cached }
        let waiterID = UUID()
        let requestID: UUID
        let task: Task<DecodedAnimatedImage, any Error>
        if var request = inFlight[key] {
            request.waiterIDs.insert(waiterID)
            inFlight[key] = request
            requestID = request.id
            task = request.task
        } else {
            requestID = UUID()
            task = Task {
                let data = try await SharedMediaDataLoader.shared.data(
                    for: url,
                    priority: .visible
                )
                try Task.checkCancellation()
                let preparedKey = url.isFileURL ? nil : PreparedAnimatedImage.key(
                    source: data, maximumPixelDimension: key.maximumPixelDimension
                )
                if let preparedKey,
                   let prepared = await SharedMediaDataLoader.shared.cachedPreparedMedia(for: preparedKey),
                   let image = await PreparedAnimatedImage.restore(prepared)
                {
                    try Task.checkCancellation()
                    if ProcessInfo.processInfo.arguments.contains("--debug-authenticated-gesture-scroll-performance") {
                        Self.cacheLogger.notice("Prepared animation cache hit: \(prepared.count, privacy: .public) bytes; \(image.frames.count, privacy: .public) frames")
                    }
                    return image
                }
                let image = try await SharedAnimatedImageDecodeScheduler.shared
                    .decode(
                        data: data,
                        maximumPixelDimension: key.maximumPixelDimension
                    )
                if let preparedKey,
                   let prepared = await PreparedAnimatedImage.archive(image),
                   !Task.isCancelled,
                   let mapped = await SharedMediaDataLoader.shared.storePreparedMedia(prepared, for: preparedKey),
                   let restored = await PreparedAnimatedImage.restore(mapped)
                {
                    try Task.checkCancellation()
                    return restored
                }
                try Task.checkCancellation()
                return image
            }
            inFlight[key] = InFlightRequest(
                id: requestID,
                task: task,
                waiterIDs: [waiterID]
            )
        }

        let result: Result<DecodedAnimatedImage, any Error>
        do {
            let image = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task {
                    await self.cancelWaiter(
                        waiterID,
                        requestID: requestID,
                        for: key
                    )
                }
            }
            result = .success(image)
        } catch {
            result = .failure(error)
        }
        if Task.isCancelled {
            cancelWaiter(
                waiterID,
                requestID: requestID,
                for: key
            )
            throw CancellationError()
        }
        return try finishWaiter(
            waiterID,
            requestID: requestID,
            for: key,
            result: result
        ).get()
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        requestID: UUID,
        for key: RequestKey
    ) {
        guard var request = inFlight[key],
              request.id == requestID,
              request.waiterIDs.remove(waiterID) != nil
        else { return }
        if request.waiterIDs.isEmpty {
            inFlight[key] = nil
            request.task.cancel()
        } else {
            inFlight[key] = request
        }
    }

    private func finishWaiter(
        _ waiterID: UUID,
        requestID: UUID,
        for key: RequestKey,
        result: Result<DecodedAnimatedImage, any Error>
    ) -> Result<DecodedAnimatedImage, any Error> {
        guard var request = inFlight[key],
              request.id == requestID,
              request.waiterIDs.remove(waiterID) != nil
        else { return .failure(CancellationError()) }
        if request.waiterIDs.isEmpty {
            inFlight[key] = nil
        } else {
            inFlight[key] = request
        }
        if case let .success(image) = result {
            cache.setObject(
                image,
                forKey: key.cacheKey,
                cost: image.storedByteCount
            )
        }
        return result
    }
}

nonisolated enum AnimatedImageDecodePolicy {
    /// Full GIF/APNG/WebP frame expansion is memory-bandwidth intensive. A
    /// burst of visible avatars and emoji previously started one detached
    /// user-initiated decode per asset, saturating several cores immediately
    /// after a server switch. Static first frames use the separate two-lane
    /// thumbnail scheduler, so serialize the optional animation expansion at
    /// utility priority without delaying first paint.
    static let maximumConcurrentDecodes = 1
    static let taskPriority = TaskPriority.background
}

actor SharedAnimatedImageDecodeScheduler {
    static let shared = SharedAnimatedImageDecodeScheduler()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeCount = 0
    private var waiters: [Waiter] = []
    private var interactiveScrollingSources: Set<AnimatedImageInteractiveScrollSource> = []
    private var interactiveScrollingRevisions: [AnimatedImageInteractiveScrollSource: UInt64] = [:]

    private var defersForInteractiveScrolling: Bool {
        !interactiveScrollingSources.isEmpty
    }

    /// Full frame expansion is optional background work. Keep already decoded
    /// animations playing, but do not start another memory-bandwidth-heavy
    /// expansion while a timeline gesture is live. Static first-frame and
    /// ordinary thumbnail loading use separate schedulers and remain
    /// available for immediate visual feedback.
    func setInteractiveScrolling(
        _ isScrolling: Bool,
        source: AnimatedImageInteractiveScrollSource,
        revision: UInt64
    ) {
        guard revision >= interactiveScrollingRevisions[source, default: 0]
        else { return }
        interactiveScrollingRevisions[source] = revision
        if isScrolling {
            interactiveScrollingSources.insert(source)
        } else {
            interactiveScrollingSources.remove(source)
        }
        resumeNextIfPossible()
    }

    func decode(
        data: Data,
        maximumPixelDimension: Int?
    ) async throws -> DecodedAnimatedImage {
        while true {
            await AppScrollWorkGate.waitUntilInactive()
            try Task.checkCancellation()
            let waiterID = UUID()
            let acquired = await withTaskCancellationHandler {
                await acquire(waiterID: waiterID)
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            }
            guard acquired, !Task.isCancelled else {
                if acquired {
                    release()
                }
                throw CancellationError()
            }
            let task = Task.detached(
                priority: AnimatedImageDecodePolicy.taskPriority
            ) {
                try DecodedAnimatedImage(
                    data: data,
                    maximumPixelDimension: maximumPixelDimension,
                    shouldInterrupt: { AppScrollWorkGate.isActive }
                )
            }
            do {
                let image = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                release()
                return image
            } catch AnimatedImageDecodeInterruption.scrollActivity {
                release()
                AppPerformanceSignposts.signposter.emitEvent(
                    "AnimatedImageDecodeInterruptedForScroll"
                )
                try Task.checkCancellation()
            } catch {
                release()
                throw error
            }
        }
    }

    private func acquire(waiterID: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if !defersForInteractiveScrolling,
           activeCount
            < AnimatedImageDecodePolicy
                .maximumConcurrentDecodes
        {
            activeCount += 1
            return true
        }
        return await withCheckedContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(returning: false)
                return
            }
            waiters.append(Waiter(
                id: waiterID,
                continuation: continuation
            ))
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        activeCount = max(0, activeCount - 1)
        resumeNextIfPossible()
    }

    private func resumeNextIfPossible() {
        guard !defersForInteractiveScrolling else { return }
        while activeCount
                < AnimatedImageDecodePolicy.maximumConcurrentDecodes,
              !waiters.isEmpty
        {
            activeCount += 1
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

#if DEBUG
    var stateForTesting: AnimatedImageDecodeSchedulerState {
        AnimatedImageDecodeSchedulerState(
            activeCount: activeCount,
            waitingCount: waiters.count,
            isDeferred: defersForInteractiveScrolling
        )
    }
#endif
}

nonisolated enum AnimatedImageInteractiveScrollSource: Hashable, Sendable {
    case timeline
    case memberList(UUID)
}

nonisolated struct AnimatedImageDecodeSchedulerState: Equatable, Sendable {
    let activeCount: Int
    let waitingCount: Int
    let isDeferred: Bool
}

nonisolated enum AnimatedImageKeyframeSchedule {
    static func duration(
        for frameDurations: [TimeInterval]
    ) -> TimeInterval {
        max(frameDurations.reduce(0, +), 0.05)
    }

    static func keyTimes(
        for frameDurations: [TimeInterval]
    ) -> [NSNumber] {
        let totalDuration = duration(for: frameDurations)
        var elapsed: TimeInterval = 0
        return frameDurations.map { duration -> NSNumber in
            defer { elapsed += duration }
            return NSNumber(value: elapsed / totalDuration)
        }
    }

    /// Steps a layer's contents through the image's frames once.
    static func contentsAnimation(for image: DecodedAnimatedImage) -> CAKeyframeAnimation {
        let frames = CAKeyframeAnimation(keyPath: "contents")
        frames.values = image.frames
        frames.keyTimes = keyTimes(for: image.frameDurations) + [1]
        frames.duration = duration(for: image.frameDurations)
        frames.calculationMode = .discrete
        return frames
    }
}

enum AnimatedImageFrameTiming {
    nonisolated static func duration(source: CGImageSource, index: Int) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        else {
            return 0.1
        }
        return duration(properties: properties)
    }

    nonisolated static func duration(properties: [CFString: Any]) -> TimeInterval {
        if let webP = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            if let value = webP[kCGImagePropertyWebPUnclampedDelayTime] as? NSNumber {
                return normalizedWebP(value.doubleValue)
            }
            if let value = webP[kCGImagePropertyWebPDelayTime] as? NSNumber {
                return normalizedWebP(value.doubleValue)
            }
        }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let value = png[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber {
                return normalized(value.doubleValue)
            }
            if let value = png[kCGImagePropertyAPNGDelayTime] as? NSNumber {
                return normalized(value.doubleValue)
            }
        }
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let value = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber {
                return normalized(value.doubleValue)
            }
            if let value = gif[kCGImagePropertyGIFDelayTime] as? NSNumber {
                return normalized(value.doubleValue)
            }
        }
        return 0.1
    }

    nonisolated private static func normalized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 0.1 }
        return max(0.01, value)
    }

    nonisolated private static func normalizedWebP(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0.01 else { return 0.1 }
        return value
    }
}

nonisolated enum AnimatedMediaPlaybackPolicy {
    static func shouldPlay(
        isVisible: Bool,
        isWindowVisible: Bool = true,
        reduceMotion: Bool
    ) -> Bool {
        isVisible
            && isWindowVisible
            && !reduceMotion
    }
}
