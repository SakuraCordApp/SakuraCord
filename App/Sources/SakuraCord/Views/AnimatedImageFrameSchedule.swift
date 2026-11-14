import Foundation
import QuartzCore

/// The same source-frame and effect-layer timing used by compositor animations,
/// expressed as a frame index for animations whose raster set exceeds the budget.
nonisolated struct AnimatedImageFrameSchedule {
    private let frameEnds: [TimeInterval]
    private let sourceDuration: TimeInterval

    init(durations: [TimeInterval]) {
        var end: TimeInterval = 0
        frameEnds = durations.map { duration in
            end += duration
            return end
        }
        sourceDuration = AnimatedImageKeyframeSchedule.duration(for: durations)
    }

    func frameIndex(
        elapsed: TimeInterval,
        playCount: Int?,
        isLooping: Bool,
        activeDuration: TimeInterval?,
        loopDelay: TimeInterval
    ) -> Int? {
        guard !frameEnds.isEmpty, elapsed >= 0 else { return nil }
        let position: TimeInterval
        if let activeDuration {
            let sourceLimit = playCount.flatMap { $0 > 0 ? sourceDuration * Double($0) : nil }
            if isLooping, loopDelay <= 0 {
                if let sourceLimit, elapsed >= sourceLimit { return frameEnds.count - 1 }
                position = elapsed.truncatingRemainder(dividingBy: sourceDuration)
            } else {
                let active = activeDuration > 0 ? activeDuration : sourceDuration
                let cyclePosition = isLooping
                    ? elapsed.truncatingRemainder(dividingBy: active + max(0, loopDelay))
                    : elapsed
                guard cyclePosition < active else { return nil }
                if let sourceLimit, cyclePosition >= sourceLimit { return frameEnds.count - 1 }
                position = cyclePosition.truncatingRemainder(dividingBy: sourceDuration)
            }
        } else {
            // Ordinary one-shot canvases return to their model-layer poster
            // when the existing remove-on-completion animation ends.
            if !isLooping, elapsed >= sourceDuration { return 0 }
            position = elapsed.truncatingRemainder(dividingBy: sourceDuration)
        }
        // Source durations are positive. Find the first end strictly after
        // this position, preserving the existing boundary and loop semantics.
        var lower = 0
        var upper = frameEnds.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if position < frameEnds[middle] {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return min(lower, frameEnds.count - 1)
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
