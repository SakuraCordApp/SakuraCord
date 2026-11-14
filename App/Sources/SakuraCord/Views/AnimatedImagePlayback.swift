import AppKit

/// A presentation-owned clock for media with an explicit active interval.
nonisolated struct AnimatedImagePlayback: Equatable {
    let startTime: CFTimeInterval
    var clock: AnimatedImagePlaybackClock?
    let duration: TimeInterval
    let loopDelay: TimeInterval

    func animation(for image: DecodedAnimatedImage, isLooping: Bool) -> CAAnimation {
        let frames = AnimatedImageKeyframeSchedule.contentsAnimation(for: image)
        // A looping layer can contain a one-shot APNG intro. Browsers honor
        // the file's play count and retain its final frame independently of
        // the profile effect's layer visibility schedule.
        let sourceDuration = image.playCount.flatMap { count in
            count > 0 ? frames.duration * Double(count) : nil
        }

        if isLooping, loopDelay <= 0 {
            if let sourceDuration {
                frames.repeatDuration = sourceDuration
                frames.fillMode = .forwards
                frames.isRemovedOnCompletion = false
            } else {
                frames.repeatCount = .infinity
            }
            return frames
        }

        // The source can contain a shorter animation than the layer's active
        // interval. Repeat its frames only within that interval, then clear it.
        let activeDuration = duration > 0 ? duration : frames.duration
        frames.repeatDuration = min(sourceDuration ?? activeDuration, activeDuration)
        frames.fillMode = .forwards
        let active = CAAnimationGroup()
        active.animations = [frames]
        active.duration = activeDuration
        guard isLooping else { return active }

        let cycle = CAAnimationGroup()
        cycle.duration = activeDuration + max(0, loopDelay)
        // A child contents animation can retain its final frame through the
        // enclosing group's idle interval. Hide the layer explicitly until
        // the next cycle, without fading or restarting the shared clock.
        let visibility = CAKeyframeAnimation(keyPath: "opacity")
        visibility.values = [1, 0]
        visibility.keyTimes = [0, NSNumber(value: activeDuration / cycle.duration), 1]
        visibility.duration = cycle.duration
        visibility.calculationMode = .discrete
        cycle.animations = [active, visibility]
        cycle.repeatCount = .infinity
        return cycle
    }
}

/// Shared by all layers of one effect, including layers decoded while hidden.
/// Stopping layer time suspends compositor work and preserves frame/gap position.
@MainActor
final class AnimatedImagePlaybackClock: Equatable {
    private(set) var pausedAt: CFTimeInterval?
    private(set) var pausedDuration: CFTimeInterval = 0

    nonisolated static func == (lhs: AnimatedImagePlaybackClock, rhs: AnimatedImagePlaybackClock) -> Bool {
        lhs === rhs
    }

    func setPaused(_ paused: Bool, at time: CFTimeInterval) {
        if paused {
            if pausedAt == nil { pausedAt = time }
        } else if let pausedAt {
            pausedDuration += max(0, time - pausedAt)
            self.pausedAt = nil
        }
    }

    func apply(to layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        if let pausedAt {
            let offset = layer.convertTime(pausedAt, from: nil) - pausedDuration
            layer.speed = 0
            layer.timeOffset = offset
        } else {
            layer.beginTime = pausedDuration
        }
        CATransaction.commit()
    }
}
