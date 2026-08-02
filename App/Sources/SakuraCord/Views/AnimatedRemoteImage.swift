import AppKit
import ImageIO
import OSLog
import QuartzCore
import SwiftUI
import WebKit

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

    struct RequestIdentity: Equatable {
        let url: URL
        let maximumPixelDimension: Int
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
                maximumPixelDimension: max(1, maximumPixelDimension)
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

        func load(
            _ request: RequestIdentity,
            into view: StaticRemoteImageView
        ) {
            guard self.request != request else { return }
            self.request = request
            task?.cancel()
            view.clear()
            task = Task { @MainActor [weak self, weak view] in
                let image = await SharedDecodedImageLoader.shared.image(
                    for: request.url,
                    maximumPixelDimension:
                        request.maximumPixelDimension,
                    // NSViewRepresentable creates this coordinator only for a
                    // mounted view. Treat that work as visible so the bounded
                    // prefetch backlog cannot reject it permanently.
                    priority: StaticRemoteImage.loadPriority
                )
                guard !Task.isCancelled,
                      self?.request == request,
                      let view
                else { return }
                if image == nil {
                    // Permit a later SwiftUI update to retry a transient load
                    // or decode failure for the same identity.
                    self?.request = nil
                }
                view.display(image)
            }
        }

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
    var fallbackSystemImage: String?
    var fallbackInset: CGFloat = 2
    var maximumPixelDimension: Int?
    var contentMode: ContentMode = .fit

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reduceAnimatedMedia") private var reduceAnimatedMedia = false
    @State private var decodedImage: DecodedAnimatedImage?
    @State private var displayedLoadID: AnimatedRemoteImageRequestIdentity?
    @State private var didFail = false

    init(
        url: URL,
        animates: Bool = true,
        isLooping: Bool = true,
        fallbackSystemImage: String? = nil,
        fallbackInset: CGFloat = 2,
        maximumPixelDimension: Int? = nil,
        contentMode: ContentMode = .fit
    ) {
        self.url = url
        self.animates = animates
        self.isLooping = isLooping
        self.fallbackSystemImage = fallbackSystemImage
        self.fallbackInset = fallbackInset
        self.maximumPixelDimension = maximumPixelDimension
        self.contentMode = contentMode

        let loadID = AnimatedRemoteImageRequestIdentity(
            url: url,
            maximumPixelDimension: maximumPixelDimension
        )
        let cached = AnimatedRemoteImageDisplayCache.shared.image(
            for: url,
            maximumPixelDimension: maximumPixelDimension
        )
        _decodedImage = State(initialValue: cached)
        _displayedLoadID = State(initialValue: cached == nil ? nil : loadID)
    }

    var body: some View {
        Group {
            if let decodedImage {
                AnimatedImageRepresentable(
                    decodedImage: decodedImage,
                    animates: animates && !reduceMotion && !reduceAnimatedMedia,
                    isLooping: isLooping,
                    contentMode: contentMode
                )
            } else if didFail, let fallbackSystemImage {
                Image(systemName: fallbackSystemImage)
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
                displayedLoadID = loadID
            } catch {
                decodedImage = nil
                displayedLoadID = nil
                didFail = true
            }
        }
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
        let key = key(
            url: url,
            maximumPixelDimension: maximumPixelDimension
        )
        let entry = Entry(
            image: image,
            cost: max(1, image.estimatedByteCount)
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
            $0.contains("chat-performance")
        }

    let frames: [CGImage]
    let frameDurations: [TimeInterval]
    let estimatedByteCount: Int

    nonisolated init(data: Data, maximumPixelDimension: Int?) throws {
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
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw CocoaError(.fileReadCorruptFile) }

        var sourceDurations: [TimeInterval] = []
        sourceDurations.reserveCapacity(frameCount)
        for index in 0 ..< frameCount {
            try Task.checkCancellation()
            sourceDurations.append(
                AnimatedImageFrameTiming.duration(
                    source: source,
                    index: index
                )
            )
        }
        let selections = AnimatedImageFrameSelection.selections(
            for: sourceDurations
        )
        var frames: [CGImage] = []
        var frameDurations: [TimeInterval] = []
        var estimatedByteCount = 0
        frames.reserveCapacity(selections.count)
        frameDurations.reserveCapacity(selections.count)
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
        for selection in selections {
            // ImageIO frame expansion is synchronous. Checking between frames
            // lets a viewport change abandon a large GIF/APNG instead of
            // finishing obsolete work after the media has scrolled away.
            try Task.checkCancellation()
            let image = thumbnailOptions.flatMap {
                CGImageSourceCreateThumbnailAtIndex(
                    source,
                    selection.index,
                    $0
                )
            } ?? CGImageSourceCreateImageAtIndex(
                source,
                selection.index,
                imageOptions
            )
            guard let image else { continue }
            // ImageIO has already been asked to decode every selected frame
            // immediately. A second CGContext redraw of every frame doubled
            // memory bandwidth for no visual gain. Prepare only the first
            // compositor frame so mounting the overlay cannot defer work onto
            // the main thread.
            let prepared = frames.isEmpty
                ? AnimatedImageFramePreparation.prepare(image)
                : image
            frames.append(prepared)
            frameDurations.append(selection.duration)
            estimatedByteCount += prepared.bytesPerRow * prepared.height
        }
        guard !frames.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        self.frames = frames
        self.frameDurations = frameDurations
        self.estimatedByteCount = estimatedByteCount
        if Self.reportsPerformance {
            let milliseconds =
                (ProcessInfo.processInfo.systemUptime - decodeStart) * 1_000
            Self.performanceLogger.notice(
                """
                Animated decode: \(milliseconds, format: .fixed(precision: 2), privacy: .public) ms;
                pixel max \(maximumPixelDimension ?? 0, privacy: .public);
                source \(data.count, privacy: .public) bytes;
                frames \(frameCount, privacy: .public) -> \(frames.count, privacy: .public);
                decoded \(estimatedByteCount, privacy: .public) bytes
                """
            )
        }
    }
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
                return try await SharedAnimatedImageDecodeScheduler.shared
                    .decode(
                        data: data,
                        maximumPixelDimension: key.maximumPixelDimension
                    )
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
                cost: image.estimatedByteCount
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
    static let taskPriority = TaskPriority.utility
}

actor SharedAnimatedImageDecodeScheduler {
    static let shared = SharedAnimatedImageDecodeScheduler()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeCount = 0
    private var waiters: [Waiter] = []
    private var defersForInteractiveScrolling = false
    private var interactiveScrollingRevision: UInt64 = 0

    /// Full frame expansion is optional background work. Keep already decoded
    /// animations playing, but do not start another memory-bandwidth-heavy
    /// expansion while a timeline gesture is live. Static first-frame and
    /// ordinary thumbnail loading use separate schedulers and remain
    /// available for immediate visual feedback.
    func setInteractiveScrolling(
        _ isScrolling: Bool,
        revision: UInt64
    ) {
        guard revision >= interactiveScrollingRevision else { return }
        interactiveScrollingRevision = revision
        defersForInteractiveScrolling = isScrolling
        resumeNextIfPossible()
    }

    func decode(
        data: Data,
        maximumPixelDimension: Int?
    ) async throws -> DecodedAnimatedImage {
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
        defer { release() }
        let task = Task.detached(
            priority: AnimatedImageDecodePolicy.taskPriority
        ) {
            try DecodedAnimatedImage(
                data: data,
                maximumPixelDimension: maximumPixelDimension
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
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

    func makeNSView(context: Context) -> AnimatedImageCanvas {
        Self.configuredCanvas(
            decodedImage: decodedImage,
            animates: animates,
            isLooping: isLooping,
            contentMode: contentMode
        )
    }

    func updateNSView(_ view: AnimatedImageCanvas, context: Context) {
        view.display(
            decodedImage,
            animates: animates,
            isLooping: isLooping,
            contentMode: contentMode
        )
    }

    static func configuredCanvas(
        decodedImage: DecodedAnimatedImage,
        animates: Bool,
        isLooping: Bool,
        contentMode: ContentMode
    ) -> AnimatedImageCanvas {
        let view = AnimatedImageCanvas()
        view.display(
            decodedImage,
            animates: animates,
            isLooping: isLooping,
            contentMode: contentMode
        )
        return view
    }
}

final class AnimatedImageCanvas: NSView {
    private var displayedImage: DecodedAnimatedImage?
    private var displayedAnimationPreference: (animates: Bool, isLooping: Bool)?
    private var displayedContentMode: ContentMode?
    private var displayedPlaybackEnabled: Bool?
    private var isPlaybackSuppressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(playbackVisibilityDidChange(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(playbackVisibilityDidChange(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPlaybackState(force: true)
    }

    func display(
        _ image: DecodedAnimatedImage,
        animates: Bool,
        isLooping: Bool,
        contentMode: ContentMode = .fit
    ) {
        let preference = (animates: animates, isLooping: isLooping)
        guard
            displayedImage !== image
            || displayedAnimationPreference?.animates != preference.animates
            || displayedAnimationPreference?.isLooping != preference.isLooping
            || displayedContentMode != contentMode
        else { return }
        displayedImage = image
        displayedAnimationPreference = preference
        displayedContentMode = contentMode
        layer?.contentsGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
        applyPlaybackState(force: true)
    }

    /// Freezes compositor-driven animated media without discarding the
    /// decoded frames or recreating the canvas. Timeline scrolling uses this
    /// to avoid advancing every visible GIF/emoji while Core Animation is
    /// simultaneously moving the backing surface.
    func setPlaybackSuppressed(_ isSuppressed: Bool) {
        guard isPlaybackSuppressed != isSuppressed else { return }
        let frozenContents = isSuppressed
            ? (layer?.presentation()?.contents ?? layer?.contents)
            : nil
        isPlaybackSuppressed = isSuppressed
        applyPlaybackState(force: true)
        if isSuppressed, let frozenContents {
            layer?.contents = frozenContents
        }
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
        guard let image = displayedImage,
              let preference = displayedAnimationPreference
        else { return }
        // A detached test/preparation canvas has no compositor surface and
        // therefore no energy cost. Keep its layer animation inspectable;
        // only a canvas attached to a real window needs visibility gating.
        let isAttachedToWindow = window != nil
        let playbackEnabled = AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: true,
            isApplicationActive: !isAttachedToWindow || NSApp.isActive,
            isWindowVisible: !isAttachedToWindow
                || window?.occlusionState.contains(.visible) == true,
            reduceMotion: !preference.animates,
            reduceAnimatedMedia: false
        ) && !isPlaybackSuppressed
        guard force || displayedPlaybackEnabled != playbackEnabled else {
            return
        }
        displayedPlaybackEnabled = playbackEnabled
        layer?.removeAnimation(forKey: "remoteAnimatedImage")

        let frames = image.frames
        let frameDurations = image.frameDurations
        guard let firstFrame = frames.first else { return }
        layer?.contents = firstFrame

        guard playbackEnabled, frames.count > 1 else { return }
        let totalDuration = AnimatedImageKeyframeSchedule.duration(
            for: frameDurations
        )
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = AnimatedImageKeyframeSchedule.keyTimes(
            for: frameDurations
        )
        animation.duration = totalDuration
        animation.calculationMode = .discrete
        animation.repeatCount = preference.isLooping ? .infinity : 1
        animation.isRemovedOnCompletion = !preference.isLooping
        animation.fillMode = .forwards
        layer?.add(animation, forKey: "remoteAnimatedImage")
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

struct LoopingRemoteWebMedia: NSViewRepresentable {
    let url: URL
    let backgroundURL: URL?
    let backgroundCSS: String
    let isPlaying: Bool

    private static let mediaDataStore = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PassthroughWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.websiteDataStore = Self.mediaDataStore
        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 9
        webView.layer?.cornerCurve = .continuous
        webView.layer?.masksToBounds = true
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.isPlaying = isPlaying
        load(url: url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: PassthroughWebView, context: Context) {
        load(url: url, in: webView, coordinator: context.coordinator)
        context.coordinator.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ webView: PassthroughWebView, coordinator: Coordinator) {
        coordinator.setPlaying(false)
        webView.stopLoading()
        webView.navigationDelegate = nil
        coordinator.webView = nil
        coordinator.currentKey = nil
    }

    private func load(url: URL, in webView: WKWebView, coordinator: Coordinator) {
        let key = "\(url.absoluteString)|\(backgroundURL?.absoluteString ?? "")|\(backgroundCSS)"
        guard coordinator.currentKey != key else { return }
        coordinator.currentKey = key
        coordinator.isReady = false
        webView.loadHTMLString(
            html(
                source: escaped(url),
                backgroundSource: backgroundURL.map(escaped),
                backgroundCSS: backgroundCSS,
                initiallyPlaying: coordinator.isPlaying
            ),
            baseURL: nil
        )
    }

    private func html(
        source: String,
        backgroundSource: String?,
        backgroundCSS: String,
        initiallyPlaying: Bool
    ) -> String {
        let background =
            backgroundSource.map {
            #"<img id="background" src="\#($0)" alt="">"#
        } ?? ""
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}
        body{position:relative}
        #plate{position:absolute;inset:0;background:\(backgroundCSS);\
        mask-image:linear-gradient(to right,transparent 0%,transparent 42%,rgba(0,0,0,.18) 52%,rgba(0,0,0,.72) 66%,#000 76%);\
        -webkit-mask-image:linear-gradient(to right,transparent 0%,transparent 42%,rgba(0,0,0,.18) 52%,rgba(0,0,0,.72) 66%,#000 76%);\
        mask-size:100% 100%;-webkit-mask-size:100% 100%;mask-repeat:no-repeat;-webkit-mask-repeat:no-repeat}
        #plate img,#plate video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
        video{mix-blend-mode:screen;pointer-events:none;background:transparent}
        </style>
        </head><body><div id="plate">\(background)<video id="animation" src="\(source)" autoplay loop muted playsinline preload="auto"></video></div>
        <script>
        const animation = document.getElementById('animation');
        let playbackEnabled = \(initiallyPlaying ? "true" : "false");
        const syncPlayback = () => {
          if (playbackEnabled && document.visibilityState === 'visible') {
            animation.play().catch(() => {});
          } else {
            animation.pause();
          }
        };
        window.setPlaybackEnabled = enabled => { playbackEnabled = enabled; syncPlayback(); };
        animation.addEventListener('canplay', syncPlayback);
        document.addEventListener('visibilitychange', syncPlayback);
        syncPlayback();
        </script></body></html>
        """
    }

    private func escaped(_ url: URL) -> String {
        url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var currentKey: String?
        weak var webView: WKWebView?
        var isPlaying = true
        var isReady = false

        func setPlaying(_ value: Bool) {
            guard isPlaying != value else { return }
            isPlaying = value
            applyPlaybackState()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isReady = true
            applyPlaybackState()
        }

        private func applyPlaybackState() {
            guard isReady else { return }
            webView?.evaluateJavaScript(
                "window.setPlaybackEnabled(\(isPlaying ? "true" : "false"))"
            )
        }
    }
}

final class PassthroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

nonisolated enum AnimatedMediaPlaybackPolicy {
    static func shouldPlay(
        isVisible: Bool,
        isApplicationActive: Bool = true,
        isWindowVisible: Bool = true,
        reduceMotion: Bool,
        reduceAnimatedMedia: Bool
    ) -> Bool {
        isVisible
            && isApplicationActive
            && isWindowVisible
            && !reduceMotion
            && !reduceAnimatedMedia
    }
}
