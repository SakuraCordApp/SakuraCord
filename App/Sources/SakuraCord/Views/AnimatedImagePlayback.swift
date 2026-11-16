import AppKit
import ImageIO
import OSLog
import QuartzCore
import SwiftUI

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
    private let frameTicker = DisplayLinkTicker()

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
            let frames = AnimatedImageKeyframeSchedule.contentsAnimation(for: image)
            frames.repeatCount = isLooping ? .infinity : 1
            frames.isRemovedOnCompletion = !isLooping
            frames.fillMode = .forwards
            frames.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            animation = frames
        }
        layer.add(animation, forKey: "remoteAnimatedImage")
    }

}
