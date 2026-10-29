import CoreGraphics
import Foundation
import Lottie
import QuartzCore

/// Rasterizes a Lottie sticker frame by frame off the main thread, so it plays
/// through the same frame pipeline as APNG and GIF stickers. Discord's client
/// likewise renders each frame once in a worker instead of keeping a live
/// vector animation, which here cost a main-thread rebuild of every sticker
/// whenever playback paused or resumed.
nonisolated final class LottieStickerFrameRenderer {
    let frameCount: Int
    let frameDuration: TimeInterval
    private let startFrame: AnimationFrameTime
    private let layer: LottieAnimationLayer
    private let context: CGContext
    private let scale: CGFloat

    /// Returns nil for anything that is not a Lottie document, leaving it to
    /// ImageIO.
    init?(data: Data, maximumPixelDimension: Int?) {
        guard data.first(where: { !" \t\r\n".utf8.contains($0) }) == UInt8(ascii: "{"),
              let animation = try? LottieAnimation.from(data: data),
              animation.size.width > 0,
              animation.size.height > 0,
              animation.framerate > 0,
              animation.endFrame > animation.startFrame
        else { return nil }
        let longestSide = max(animation.size.width, animation.size.height)
        scale = maximumPixelDimension.map { min(1, CGFloat($0) / longestSide) } ?? 1
        guard let context = CGContext(
            data: nil,
            width: max(1, Int((animation.size.width * scale).rounded())),
            height: max(1, Int((animation.size.height * scale).rounded())),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            // A profiled space lets the frames enter the on-disk frame cache.
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        self.context = context
        startFrame = animation.startFrame
        // Looping playback never shows the end frame itself.
        frameCount = Int((animation.endFrame - animation.startFrame).rounded(.down))
        frameDuration = 1 / animation.framerate
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The CPU renderer draws through ordinary layers, which render off the
        // main thread when forced directly; its own display pass refuses to.
        layer = LottieAnimationLayer(
            animation: animation,
            configuration: LottieConfiguration(renderingEngine: .mainThread)
        )
        layer.frame = CGRect(origin: .zero, size: animation.size)
        layer.layoutIfNeeded()
        CATransaction.commit()
        // Setting up the animation queues a redraw of it on the main queue.
        // Let that finish so it cannot race the drawing below.
        if !Thread.isMainThread {
            DispatchQueue.main.sync {}
        }
    }

    func frame(at index: Int) -> CGImage? {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Lottie's own frame setter finishes on the main queue, racing this
        // thread; set the inner layer's frame and redraw synchronously instead.
        layer.animationLayer?.setValue(startFrame + AnimationFrameTime(index), forKey: "currentFrame")
        layer.forceDisplayUpdate()
        context.clear(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.saveGState()
        // Lottie lays out top-down; the bitmap context counts from the bottom.
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        // The inner layer is drawn in its own bounds; without a view to
        // position it, the outer one would offset it by half its size.
        layer.animationLayer?.render(in: context)
        context.restoreGState()
        return context.makeImage()
    }
}
