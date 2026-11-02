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

struct StaticRemoteImage: NSViewRepresentable {
    nonisolated static let loadPriority = MediaLoadPriority.visible

    let url: URL
    let maximumPixelDimension: Int
    var contentMode: ContentMode = .fit
    var retriesFailedLoads = false

    struct RequestIdentity: Equatable {
        let url: URL
        let maximumPixelDimension: Int
        var retriesFailedLoads = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> StaticRemoteImageView {
        StaticRemoteImageView()
    }

    func updateNSView(
        _ view: StaticRemoteImageView,
        context: Context
    ) {
        view.contentMode = contentMode
        context.coordinator.load(
            RequestIdentity(
                url: url,
                maximumPixelDimension: max(1, maximumPixelDimension),
                retriesFailedLoads: retriesFailedLoads
            ),
            into: view
        )
    }

    static func dismantleNSView(
        _ view: StaticRemoteImageView,
        coordinator: Coordinator
    ) {
        coordinator.cancel()
        view.clear()
    }

    @MainActor
    final class Coordinator {
        private var request: RequestIdentity?
        private var task: Task<Void, Never>?
        private let loadImage: @MainActor (RequestIdentity) async -> CGImage?
        private let wait: @MainActor (Duration) async throws -> Void
        private let retryDelays: [Duration]

        init(
            retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)],
            loadImage: @escaping @MainActor (RequestIdentity) async -> CGImage? = { request in
                await SharedDecodedImageLoader.shared.image(
                    for: request.url,
                    maximumPixelDimension: request.maximumPixelDimension,
                    priority: StaticRemoteImage.loadPriority
                )
            },
            wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        ) {
            self.retryDelays = retryDelays
            self.loadImage = loadImage
            self.wait = wait
        }

        func load(
            _ request: RequestIdentity,
            into view: StaticRemoteImageView
        ) {
            guard self.request != request else { return }
            self.request = request
            task?.cancel()
            if let cached = SharedDecodedImageLoader.shared.cachedImage(
                for: request.url, maximumPixelDimension: request.maximumPixelDimension
            ) {
                view.display(cached)
                return
            }
            view.clear()
            let delays = request.retriesFailedLoads ? retryDelays : []
            let loadImage = loadImage
            let wait = wait
            task = Task { @MainActor [weak self, weak view] in
                for attempt in 0 ... delays.count {
                    guard !Task.isCancelled, self?.request == request, view != nil else { return }
                    let image = await loadImage(request)
                    guard !Task.isCancelled,
                          self?.request == request,
                          let view
                    else { return }
                    if let image {
                        view.display(image)
                        return
                    }
                    guard attempt < delays.count else { break }
                    do {
                        try await wait(delays[attempt])
                    } catch {
                        return
                    }
                }
                // A mounted server icon owns a bounded retry sequence. SwiftUI
                // redraws must not restart that sequence indefinitely. Leaving
                // the viewport dismantles it, so re-entry can try again.
                if !request.retriesFailedLoads {
                    self?.request = nil
                }
            }
        }

#if DEBUG
        var loadTaskForTesting: Task<Void, Never>? { task }

        func waitForLoadForTesting() async {
            await task?.value
        }
#endif

        func cancel() {
            task?.cancel()
            task = nil
            request = nil
        }
    }
}

@MainActor
final class StaticRemoteImageView: NSView {
    var contentMode: ContentMode = .fit {
        didSet { updateContentsGravity() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        updateContentsGravity()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    func display(_ image: CGImage?) {
        layer?.contents = image
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    func clear() {
        layer?.contents = nil
    }

    private func updateContentsGravity() {
        layer?.contentsGravity =
            contentMode == .fill ? .resizeAspectFill : .resizeAspect
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
        let cached = loadedImage ?? AnimatedRemoteImageDisplayCache.shared.image(
            for: url,
            maximumPixelDimension: maximumPixelDimension
        )
        _decodedImage = State(initialValue: cached)
        _cachedPoster = State(initialValue: cached?.frames.first ?? AnimatedImagePosterCache.shared.image(
            for: url, maximumPixelDimension: maximumPixelDimension
        ))
        _displayedLoadID = State(initialValue: cached == nil ? nil : loadID)
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
                decodedImage = AnimatedRemoteImageDisplayCache.shared.image(
                    for: url,
                    maximumPixelDimension: maximumPixelDimension
                )
                cachedPoster = decodedImage?.frames.first ?? AnimatedImagePosterCache.shared.image(
                    for: url, maximumPixelDimension: maximumPixelDimension
                )
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
        NativeTimelineMediaMemoryPolicy.displayedAnimatedImageBytes
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
    private static let performanceSignposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PointsOfInterest"
    )
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
        let decodeSignpost = Self.performanceSignposter.beginInterval(
            "AnimatedImageDecode"
        )
        defer {
            Self.performanceSignposter.endInterval(
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
            NativeTimelineMediaMemoryPolicy.sharedAnimatedImageBytes
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

nonisolated enum MediaLoadPriority: Int, Sendable {
    case prefetch
    case visible
}

nonisolated enum SharedMediaRequestSchedulingPolicy {
    static let maximumConcurrentRemoteLoads = 8
    static let maximumConcurrentPrefetchLoads = 2
    static let maximumPendingRemoteLoads = 64
    static let maximumPendingPrefetchLoads = 24

    static func acceptsRemoteLoad(pendingRemoteCount: Int) -> Bool {
        pendingRemoteCount < maximumPendingRemoteLoads
    }

    static func acceptsPrefetch(pendingPrefetchCount: Int) -> Bool {
        pendingPrefetchCount < maximumPendingPrefetchLoads
    }

    static func nextURL(
        in order: [URL],
        priorities: [URL: MediaLoadPriority],
        activeCount: Int,
        activePrefetchCount: Int
    ) -> URL? {
        guard activeCount < maximumConcurrentRemoteLoads else { return nil }
        if let visible = order.first(where: {
            priorities[$0] == .visible
        }) {
            return visible
        }
        guard activePrefetchCount < maximumConcurrentPrefetchLoads else {
            return nil
        }
        return order.first(where: {
            priorities[$0] == .prefetch
        })
    }
}

struct AnimatedImageRepresentable: NSViewRepresentable {
    let decodedImage: DecodedAnimatedImage
    let animates: Bool
    let isLooping: Bool
    let contentMode: ContentMode
    var playback: AnimatedImagePlayback?
    var resetsWhenStopped = false

    func makeNSView(context: Context) -> AnimatedImageCanvas {
        Self.configuredCanvas(
            decodedImage: decodedImage,
            animates: animates,
            isLooping: isLooping,
            contentMode: contentMode,
            playback: playback,
            resetsWhenStopped: resetsWhenStopped
        )
    }

    func updateNSView(_ view: AnimatedImageCanvas, context: Context) {
        view.display(
            decodedImage,
            animates: animates,
            isLooping: isLooping,
            contentMode: contentMode,
            playback: playback,
            resetsWhenStopped: resetsWhenStopped
        )
    }

    static func configuredCanvas(
        decodedImage: DecodedAnimatedImage,
        animates: Bool,
        isLooping: Bool,
        contentMode: ContentMode,
        playback: AnimatedImagePlayback? = nil,
        resetsWhenStopped: Bool = false
    ) -> AnimatedImageCanvas {
        let view = AnimatedImageCanvas()
        view.display(
            decodedImage,
            animates: animates,
            isLooping: isLooping,
            contentMode: contentMode,
            playback: playback,
            resetsWhenStopped: resetsWhenStopped
        )
        return view
    }
}

final class AnimatedImageCanvas: NSView {
    private(set) var displayedImage: DecodedAnimatedImage?
    private struct AnimationPreference: Equatable {
        let animates: Bool
        let isLooping: Bool
        let resetsWhenStopped: Bool
    }

    private var displayedAnimationPreference: AnimationPreference?
    private var displayedContentMode: ContentMode?
    private var displayedPlayback: AnimatedImagePlayback?
    private var displayedPlaybackEnabled: Bool?
    private var isPlaybackSuppressed = false
    private var playbackClock = AnimatedImagePlaybackClock()
    private var hasBeenAttachedToWindow = false
    private var usesBoundedPlayback = false
    private var boundedStartTime: CFTimeInterval = 0
    private var boundedFrameIndex: Int?
    private let frameTicker = NativeTimelineDisplayLinkTicker()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
        layer?.actions = ["contents": NSNull()]
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(playbackVisibilityDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        frameTicker.stop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hasBeenAttachedToWindow = hasBeenAttachedToWindow || window != nil
        applyPlaybackState(force: true)
    }

    override func viewDidHide() {
        super.viewDidHide()
        applyPlaybackState(force: true)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        applyPlaybackState(force: true)
    }

    func display(
        _ image: DecodedAnimatedImage,
        animates: Bool,
        isLooping: Bool,
        contentMode: ContentMode = .fit,
        playback: AnimatedImagePlayback? = nil,
        resetsWhenStopped: Bool = false
    ) {
        let preference = AnimationPreference(animates: animates, isLooping: isLooping, resetsWhenStopped: resetsWhenStopped)
        guard
            displayedImage !== image
            || displayedAnimationPreference != preference
            || displayedContentMode != contentMode
            || displayedPlayback != playback
        else { return }
        let replacesAnimation = displayedImage !== image
            || displayedPlayback != playback
            || displayedAnimationPreference?.isLooping != isLooping
            || displayedAnimationPreference?.resetsWhenStopped != resetsWhenStopped
            || (resetsWhenStopped && displayedAnimationPreference?.animates != animates)
        displayedImage = image
        displayedAnimationPreference = preference
        displayedContentMode = contentMode
        displayedPlayback = playback
        layer?.contentsGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
        if replacesAnimation {
            installAnimation(for: image, isLooping: isLooping)
            if resetsWhenStopped, !animates {
                layer?.removeAnimation(forKey: "remoteAnimatedImage")
                layer?.contents = image.frames.first
            }
        }
        applyPlaybackState(force: true)
    }

    /// Freezes compositor-driven animated media without discarding the
    /// decoded frames or recreating the canvas. Timeline scrolling uses this
    /// to avoid advancing every visible GIF/emoji while Core Animation is
    /// simultaneously moving the backing surface.
    func setPlaybackSuppressed(_ isSuppressed: Bool) {
        guard isPlaybackSuppressed != isSuppressed else { return }
        isPlaybackSuppressed = isSuppressed
        applyPlaybackState(force: true)
    }

    func displayStatic(_ image: CGImage?) {
        guard displayedImage == nil else { return }
        layer?.contents = image
    }

    func clear() {
        frameTicker.stop()
        usesBoundedPlayback = false
        boundedFrameIndex = nil
        displayedImage = nil
        displayedAnimationPreference = nil
        displayedContentMode = nil
        displayedPlayback = nil
        displayedPlaybackEnabled = nil
        isPlaybackSuppressed = false
        playbackClock = AnimatedImagePlaybackClock()
        if let layer { playbackClock.apply(to: layer) }
        layer?.removeAnimation(forKey: "remoteAnimatedImage")
        layer?.contents = nil
    }

    @objc
    private func playbackVisibilityDidChange(_ notification: Notification) {
        if let changedWindow = notification.object as? NSWindow,
           changedWindow !== window
        {
            return
        }
        applyPlaybackState(force: false)
    }

    private func applyPlaybackState(force: Bool) {
        guard displayedImage != nil,
              let preference = displayedAnimationPreference,
              let layer
        else { return }
        let playbackEnabled = AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: !isHiddenOrHasHiddenAncestor,
            isWindowVisible: window?.occlusionState.contains(.visible)
                ?? !hasBeenAttachedToWindow,
            reduceMotion: !preference.animates
        ) && !isPlaybackSuppressed
        guard force || displayedPlaybackEnabled != playbackEnabled else { return }
        displayedPlaybackEnabled = playbackEnabled
        let clock = displayedPlayback?.clock ?? playbackClock
        // A late effect layer inherits the shared pause; a detached preparation
        // canvas must not resume or pause the other layers before it is mounted.
        if displayedPlayback?.clock == nil || window != nil {
            clock.setPaused(!playbackEnabled, at: CACurrentMediaTime())
        }
        clock.apply(to: layer)
        if usesBoundedPlayback {
            updateBoundedFrame()
            if playbackEnabled, window != nil {
                if frameTicker.displayLink == nil {
                    frameTicker.start(on: self) { [weak self] in self?.updateBoundedFrame() }
                }
            } else {
                frameTicker.stop()
            }
        }
    }

    private func updateBoundedFrame() {
        guard let image = displayedImage, let preference = displayedAnimationPreference, let layer else { return }
        let clock = displayedPlayback?.clock ?? playbackClock
        let elapsed = (clock.pausedAt ?? CACurrentMediaTime()) - clock.pausedDuration - boundedStartTime
        let index = preference.resetsWhenStopped && !preference.animates ? 0 : image.frameSchedule.frameIndex(
            elapsed: elapsed,
            playCount: image.playCount,
            isLooping: preference.isLooping,
            activeDuration: displayedPlayback?.duration,
            loopDelay: displayedPlayback?.loopDelay ?? 0
        )
        guard index != boundedFrameIndex else { return }
        boundedFrameIndex = index
        // Keep discrete frame changes in AppKit's shared transaction instead
        // of committing image uploads separately inside each display callback.
        layer.contents = index.map { CompressedAnimatedFrame.transientImage(image.frames[$0]) }
    }

    private func installAnimation(for image: DecodedAnimatedImage, isLooping: Bool) {
        guard let layer else { return }
        frameTicker.stop()
        layer.removeAnimation(forKey: "remoteAnimatedImage")
        playbackClock = AnimatedImagePlaybackClock()
        playbackClock.apply(to: layer)
        // Small animations keep compositor-only playback. For larger raster
        // sets, submit only the current frame, releasing previous uploads while
        // preserving the compressed source and the shared presentation clock.
        usesBoundedPlayback = image.frames.count > 1 && image.estimatedByteCount > 2 * 1_024 * 1_024
            && image.frames.allSatisfy(CompressedAnimatedFrame.canReconstruct)
        boundedFrameIndex = nil
        if usesBoundedPlayback {
            boundedStartTime = displayedPlayback?.startTime ?? CACurrentMediaTime()
            layer.contents = nil
            updateBoundedFrame()
            return
        }
        let animation: CAAnimation
        if let playback = displayedPlayback {
            layer.contents = nil
            animation = playback.animation(for: image, isLooping: isLooping)
            animation.beginTime = layer.convertTime(playback.startTime, from: nil)
        } else {
            layer.contents = image.frames.first
            guard image.frames.count > 1 else { return }
            let frames = CAKeyframeAnimation(keyPath: "contents")
            frames.values = image.frames
            frames.keyTimes = AnimatedImageKeyframeSchedule.keyTimes(
                for: image.frameDurations
            ) + [1]
            frames.duration = AnimatedImageKeyframeSchedule.duration(for: image.frameDurations)
            frames.calculationMode = .discrete
            frames.repeatCount = isLooping ? .infinity : 1
            frames.isRemovedOnCompletion = !isLooping
            frames.fillMode = .forwards
            frames.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            animation = frames
        }
        layer.add(animation, forKey: "remoteAnimatedImage")
    }

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
