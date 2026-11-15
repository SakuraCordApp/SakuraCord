import AppKit
import ImageIO
import OSLog

nonisolated final class DecodedAnimatedImage: @unchecked Sendable {
    private static let performanceLogger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "AnimatedMediaPerformance"
    )
    private static let reportsPerformance = AppLaunchConfiguration.current.reportsAnimatedMediaPerformance

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
