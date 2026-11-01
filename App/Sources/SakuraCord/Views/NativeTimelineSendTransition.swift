import AppKit
import CoreText
import QuartzCore
import SakuraCordModels

/// Where a sent message was in the composer, in window coordinates.
struct NativeTimelineSendTransitionSource {
    struct Text {
        let image: NSImage
        let frame: CGRect
        /// The leading end of the first line's baseline.
        let baseline: CGPoint
    }

    /// A staged attachment's thumbnail, which flies into its place in the
    /// bubble the way an iMessage photo does.
    struct Attachment {
        let image: NSImage
        let frame: CGRect
        let cornerRadius: CGFloat
        /// Thumbnails fill their frame; file icons keep their shape.
        let fillsFrame: Bool
    }

    let channelID: ChannelID
    /// The trimmed draft, which becomes the optimistic message content, or
    /// `nil` for a send that did not come from the draft.
    let content: String?
    let capturedAt: TimeInterval
    weak var window: NSWindow?
    let fieldFrame: CGRect
    let text: Text?
    /// Index-aligned with the message's attachments.
    let attachments: [Attachment?]
}

/// Hands a composer send to the timeline that later appends its optimistic
/// row. The sent text and attachments are held in place over the clearing
/// composer until then, and released if no timeline claims them in time.
@MainActor
final class NativeTimelineSendTransitionStore {
    struct Pending {
        let source: NativeTimelineSendTransitionSource
        let overlay: NativeTimelineSendTransitionOverlay
    }

    private struct Composer {
        weak var anchor: ComposerSendTransitionAnchor?
    }

    static let lifetime: TimeInterval = 0.5
    /// How long a locally appended message stays recognisable as this
    /// window's send, whether or not it has been confirmed yet.
    static let localSendLifetime: TimeInterval = 1

    private var pending: [ChannelID: Pending] = [:]
    private var composers: [ChannelID: Composer] = [:]
    private var localSends: [String: TimeInterval] = [:]

    func registerComposer(_ anchor: ComposerSendTransitionAnchor) {
        // Text held for a conversation the composer just left must not
        // linger over the next one.
        for (channelID, composer) in composers
        where composer.anchor === anchor && channelID != anchor.channelID {
            discard(channelID)
        }
        composers = composers.filter {
            $0.value.anchor != nil && $0.value.anchor !== anchor
        }
        if let channelID = anchor.channelID {
            composers[channelID] = Composer(anchor: anchor)
        }
    }

    func hasComposer(for channelID: ChannelID) -> Bool {
        composers[channelID]?.anchor != nil
    }

    /// Records a message this client appended before sending it.
    func noteLocalSend(
        nonce: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        localSends = localSends.filter { now - $0.value <= Self.localSendLifetime }
        localSends[nonce] = now
    }

    func isRecentLocalSend(
        nonce: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        localSends[nonce].map { now - $0 <= Self.localSendLifetime } ?? false
    }

    func register(_ source: NativeTimelineSendTransitionSource) {
        discard(source.channelID)
        guard let overlay = NativeTimelineSendTransitionOverlay.holding(source)
        else { return }
        pending[source.channelID] = Pending(source: source, overlay: overlay)
        Task { @MainActor [weak self, weak overlay] in
            try? await Task.sleep(for: .seconds(Self.lifetime))
            guard let self, let overlay,
                  self.pending[source.channelID]?.overlay === overlay
            else { return }
            self.discard(source.channelID)
        }
    }

    func hasPendingSource(
        for channelID: ChannelID,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard let entry = pending[channelID] else { return false }
        guard now - entry.source.capturedAt <= Self.lifetime else {
            discard(channelID)
            return false
        }
        return true
    }

    /// Claims the pending send whose draft became `message`. The caller owns
    /// the returned overlay and must run or dismiss it.
    func consume(
        for message: Message,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Pending? {
        guard hasPendingSource(for: message.channelID, now: now),
              pending[message.channelID]?.source.content == message.content
        else { return nil }
        return pending.removeValue(forKey: message.channelID)
    }

    /// A send this window made without a captured draft, such as a GIF,
    /// sticker, poll or dropped file, leaves from the composer's field.
    func fieldPending(for channelID: ChannelID, in window: NSWindow?) -> Pending? {
        guard let anchor = composers[channelID]?.anchor,
              let source = anchor.fieldSource(channelID: channelID),
              source.window === window,
              let overlay = NativeTimelineSendTransitionOverlay.holding(source)
        else { return nil }
        return Pending(source: source, overlay: overlay)
    }

    func discard(_ channelID: ChannelID, animated: Bool = true) {
        guard let overlay = pending.removeValue(forKey: channelID)?.overlay else { return }
        if animated {
            overlay.dismiss()
        } else {
            overlay.removeFromSuperview()
        }
    }
}

/// Telegram's open-source iOS client reproduces the iMessage send transition
/// by animating each axis on its own curve: the bubble settles into its width
/// and column almost immediately while it travels up more gradually, and the
/// transcript moves on the same vertical curve.
enum NativeTimelineSendTransitionTiming {
    static let duration: CFTimeInterval = 0.36
    static let fillFadeDuration: CFTimeInterval = 0.08
    static let sourceTextFadeDuration: CFTimeInterval = 0.1
    static let plainTextCrossFadeDuration: CFTimeInterval = 0.2
    static let contentFadeDuration: CFTimeInterval = 0.08
    static let contentRefreshDuration: CFTimeInterval = 0.12
    static let tailFadeDelay: CFTimeInterval = 0.06
    static let tailFadeDuration: CFTimeInterval = 0.12
    static let dismissalDuration: CFTimeInterval = 0.12
    /// The composer stacks attachments above the text while a message puts
    /// its text first, so their paths cross. The text leaves first and
    /// passes over the media, which follows a beat behind and lands below.
    static let mediaStagger: CFTimeInterval = 0.06
    /// How long a landed bubble may wait for its row's media to decode, so
    /// the hand-off never shows a loading placeholder.
    static let mediaWaitLimit: TimeInterval = 0.6

    static var horizontal: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    }

    static let verticalCurve = NativeTimelineGlideCurve(
        x1: 0.2, y1: 0.01, x2: 0.28, y2: 0.91, duration: duration
    )

    static var vertical: CAMediaTimingFunction { verticalCurve.timingFunction }
}

/// A cubic Bézier curve the transcript can glide on, readable at any moment
/// so a glide that is interrupted continues from where its rows are drawn.
struct NativeTimelineGlideCurve {
    let x1: Float
    let y1: Float
    let x2: Float
    let y2: Float
    let duration: CFTimeInterval

    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: x1, y1, x2, y2)
    }

    /// The curve's progress after `fraction` of the duration.
    func progress(at fraction: Double) -> Double {
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return 1 }
        func bezier(_ parameter: Double, _ first: Float, _ second: Float) -> Double {
            let inverse = 1 - parameter
            return 3 * inverse * inverse * parameter * Double(first)
                + 3 * inverse * parameter * parameter * Double(second)
                + parameter * parameter * parameter
        }
        var lower = 0.0
        var upper = 1.0
        for _ in 0 ..< 24 {
            let middle = (lower + upper) / 2
            if bezier(middle, x1, x2) < fraction {
                lower = middle
            } else {
                upper = middle
            }
        }
        return bezier((lower + upper) / 2, y1, y2)
    }
}

/// Renders transition snapshots in the timeline's flipped coordinates.
@MainActor
enum NativeTimelineSendTransitionSnapshot {
    static func render(size: CGSize, scale: CGFloat, draw: () -> Void) -> NSImage? {
        let scale = max(1, scale)
        guard size.width > 0, size.height > 0,
              let representation = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: max(1, Int(ceil(size.width * scale))),
                  pixelsHigh: max(1, Int(ceil(size.height * scale))),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let graphics = NSGraphicsContext(bitmapImageRep: representation)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }
}

/// The flying bubble. It sits above the composer and timeline while the
/// canvas leaves the destination bubble transparent.
@MainActor
final class NativeTimelineSendTransitionOverlay: NSView {
    /// An attachment thumbnail that flies from the composer to its frame.
    struct Piece {
        let index: Int
        let frame: CGRect
        let cornerRadius: CGFloat
        let opacity: Float
        /// Whether the timeline draws something else in this frame, such as
        /// a video that has no poster yet.
        let fadesOut: Bool
    }

    /// The bubble the field becomes. Messages shown without bubbles have
    /// none; their content leaves the field on its own.
    struct Bubble {
        let frame: CGRect
        let cornerRadius: CGFloat
        /// Relative to the bubble's bottom trailing corner.
        let tailPath: CGPath?
        let fillColor: CGColor
    }

    /// Destination geometry in this view's (unflipped) coordinates.
    struct Geometry {
        let fieldFrame: CGRect
        let bubble: Bubble?
        let contentImage: NSImage
        let contentFrame: CGRect
        /// The content point that leaves from `sourceAnchor`.
        let contentAnchor: CGPoint
        let sourceAnchor: CGPoint
        let pieces: [Piece]
    }

    private let bubbleLayer = CALayer()
    private let tailLayer = CAShapeLayer()
    /// Clips the content to the bubble while the bubble grows.
    private let clipLayer = CALayer()
    private let contentLayer = CALayer()
    private let finalContentLayer = CALayer()
    private let sourceTextLayer = CALayer()
    private var heldTextFrame: CGRect?
    private var pieceLayers: [Int: CALayer] = [:]
    private var pieceSourceFrames: [Int: CGRect] = [:]
    private var pieceSourceCornerRadii: [Int: CGFloat] = [:]

    /// Covers the composer's text and attachments with identical copies so
    /// clearing the composer cannot blink before the timeline takes the
    /// message over.
    static func holding(
        _ source: NativeTimelineSendTransitionSource
    ) -> NativeTimelineSendTransitionOverlay? {
        guard let window = source.window,
              let container = window.contentView?.superview ?? window.contentView
        else { return nil }
        let overlay = NativeTimelineSendTransitionOverlay(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.clipLayer.frame = overlay.bounds
        if let text = source.text {
            let frame = overlay.convert(text.frame, from: nil)
            overlay.heldTextFrame = frame
            overlay.sourceTextLayer.contents = text.image
            overlay.sourceTextLayer.contentsScale = window.backingScaleFactor
            overlay.sourceTextLayer.frame = frame
        }
        for (index, attachment) in source.attachments.enumerated() {
            guard let attachment else { continue }
            let frame = overlay.convert(attachment.frame, from: nil)
            let layer = CALayer()
            layer.contents = attachment.image
            layer.contentsGravity = attachment.fillsFrame ? .resizeAspectFill : .resizeAspect
            layer.contentsScale = window.backingScaleFactor
            layer.masksToBounds = true
            layer.cornerCurve = .continuous
            layer.cornerRadius = attachment.cornerRadius
            layer.frame = frame
            overlay.layer?.addSublayer(layer)
            overlay.pieceLayers[index] = layer
            overlay.pieceSourceFrames[index] = frame
            overlay.pieceSourceCornerRadii[index] = attachment.cornerRadius
        }
        CATransaction.commit()
        return overlay
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = false
        layer = root
        wantsLayer = true
        for sublayer in [bubbleLayer, tailLayer, clipLayer] {
            // The message body flies over the attachment copies it crosses.
            sublayer.zPosition = 1
            root.addSublayer(sublayer)
        }
        bubbleLayer.opacity = 0
        tailLayer.opacity = 0
        contentLayer.bounds = .zero
        contentLayer.anchorPoint = .zero
        clipLayer.addSublayer(contentLayer)
        contentLayer.addSublayer(finalContentLayer)
        contentLayer.addSublayer(sourceTextLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func run(_ geometry: Geometry, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let field = geometry.fieldFrame
        typealias Timing = NativeTimelineSendTransitionTiming

        // The clip carries the content along the bubble's path. Without a
        // bubble it stays put and the content travels on its own.
        let clipOrigin: (source: CGPoint, target: CGPoint)
        if let bubble = geometry.bubble {
            let target = bubble.frame
            let fieldCornerRadius = min(bubble.cornerRadius, field.height / 2)
            bubbleLayer.backgroundColor = bubble.fillColor
            morph(
                bubbleLayer, from: field, to: target,
                cornerRadius: (fieldCornerRadius, bubble.cornerRadius)
            )
            fadeIn(bubbleLayer, duration: Timing.fillFadeDuration)

            if let tailPath = bubble.tailPath {
                tailLayer.bounds = .zero
                tailLayer.anchorPoint = .zero
                tailLayer.position = CGPoint(x: target.maxX, y: target.minY)
                tailLayer.path = tailPath
                tailLayer.fillColor = bubble.fillColor
                animateAxes(
                    tailLayer,
                    offset: CGPoint(x: field.maxX - target.maxX, y: field.minY - target.minY)
                )
                fadeIn(tailLayer, duration: Timing.tailFadeDuration, delay: Timing.tailFadeDelay)
            }

            clipLayer.masksToBounds = true
            morph(
                clipLayer, from: field, to: target,
                cornerRadius: (fieldCornerRadius, bubble.cornerRadius)
            )
            clipOrigin = (field.origin, target.origin)
        } else {
            clipLayer.masksToBounds = false
            clipLayer.frame = bounds
            clipOrigin = (.zero, .zero)
        }
        contentLayer.position = CGPoint(
            x: geometry.contentAnchor.x - clipOrigin.target.x,
            y: geometry.contentAnchor.y - clipOrigin.target.y
        )
        animateAxes(
            contentLayer,
            offset: CGPoint(
                x: geometry.sourceAnchor.x - clipOrigin.source.x - contentLayer.position.x,
                y: geometry.sourceAnchor.y - clipOrigin.source.y - contentLayer.position.y
            )
        )
        finalContentLayer.contents = geometry.contentImage
        finalContentLayer.contentsScale = scale
        finalContentLayer.frame = geometry.contentFrame.offsetBy(
            dx: -geometry.contentAnchor.x,
            dy: -geometry.contentAnchor.y
        )
        // Composer text and message text look alike, so without a bubble to
        // hide the swap the two cross-fade over a little longer.
        let crossFade = geometry.bubble == nil ? Timing.plainTextCrossFadeDuration : nil
        fadeIn(finalContentLayer, duration: crossFade ?? Timing.contentFadeDuration)
        if let heldTextFrame {
            sourceTextLayer.frame = heldTextFrame.offsetBy(
                dx: -geometry.sourceAnchor.x,
                dy: -geometry.sourceAnchor.y
            )
            sourceTextLayer.opacity = 0
            add(
                sourceTextLayer, "opacity", from: 1, to: 0,
                duration: crossFade ?? Timing.sourceTextFadeDuration
            )
        }

        var landingIndexes = Set<Int>()
        let delay = mediaDelay
        for piece in geometry.pieces {
            guard let layer = pieceLayers[piece.index],
                  let source = pieceSourceFrames[piece.index]
            else { continue }
            landingIndexes.insert(piece.index)
            morph(
                layer, from: source, to: piece.frame,
                cornerRadius: (pieceSourceCornerRadii[piece.index] ?? piece.cornerRadius, piece.cornerRadius),
                delay: delay
            )
            let opacity: Float = piece.fadesOut ? 0 : piece.opacity
            layer.opacity = opacity
            add(layer, "opacity", from: 1, to: CGFloat(opacity), timing: Timing.vertical, delay: delay)
        }
        // Anything the destination has no frame for leaves with the field.
        for (index, layer) in pieceLayers where !landingIndexes.contains(index) {
            layer.opacity = 0
            add(layer, "opacity", from: 1, to: 0, duration: Timing.dismissalDuration)
        }
    }

    /// How long attachments wait for the text to lead them out.
    var mediaDelay: CFTimeInterval {
        heldTextFrame != nil && !pieceLayers.isEmpty
            ? NativeTimelineSendTransitionTiming.mediaStagger : 0
    }

    /// Replaces the bubble's content after its media finishes loading.
    func updateContent(_ image: NSImage) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = NativeTimelineSendTransitionTiming.contentRefreshDuration
        finalContentLayer.add(transition, forKey: "contents")
        finalContentLayer.contents = image
    }

    /// Moves the in-flight bubble when its destination row moves, for example
    /// when a multiline composer collapses after sending.
    func retarget(by delta: CGPoint, duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for layer in [bubbleLayer, tailLayer, clipLayer] + Array(pieceLayers.values) {
            layer.position.x += delta.x
            layer.position.y += delta.y
            animateAxes(layer, offset: CGPoint(x: -delta.x, y: -delta.y), duration: duration)
        }
    }

    /// Releases held content that no timeline animated.
    func dismiss() {
        guard let layer else {
            removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.removeFromSuperview()
        }
        layer.opacity = 0
        add(
            layer, "opacity", from: 1, to: 0,
            duration: NativeTimelineSendTransitionTiming.dismissalDuration
        )
        CATransaction.commit()
    }

    /// Moves and resizes a layer between two frames, each axis on its curve.
    private func morph(
        _ layer: CALayer,
        from source: CGRect,
        to target: CGRect,
        cornerRadius: (from: CGFloat, to: CGFloat),
        delay: CFTimeInterval = 0
    ) {
        typealias Timing = NativeTimelineSendTransitionTiming
        layer.frame = target
        layer.cornerCurve = .continuous
        layer.cornerRadius = cornerRadius.to
        animateAxes(
            layer,
            offset: CGPoint(x: source.midX - target.midX, y: source.midY - target.midY),
            delay: delay
        )
        add(layer, "bounds.size.width", from: source.width, to: target.width, timing: Timing.horizontal, delay: delay)
        add(layer, "bounds.size.height", from: source.height, to: target.height, timing: Timing.vertical, delay: delay)
        add(layer, "cornerRadius", from: cornerRadius.from, to: cornerRadius.to, timing: Timing.vertical, delay: delay)
    }

    private func animateAxes(
        _ layer: CALayer,
        offset: CGPoint,
        duration: CFTimeInterval = NativeTimelineSendTransitionTiming.duration,
        delay: CFTimeInterval = 0
    ) {
        if abs(offset.x) >= 0.5 {
            add(
                layer, "position.x", from: offset.x, to: 0,
                timing: NativeTimelineSendTransitionTiming.horizontal,
                duration: duration, delay: delay, isAdditive: true
            )
        }
        if abs(offset.y) >= 0.5 {
            add(
                layer, "position.y", from: offset.y, to: 0,
                timing: NativeTimelineSendTransitionTiming.vertical,
                duration: duration, delay: delay, isAdditive: true
            )
        }
    }

    private func fadeIn(_ layer: CALayer, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        layer.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.beginTime = delay > 0 ? layer.convertTime(CACurrentMediaTime(), from: nil) + delay : 0
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: nil)
    }

    private func add(
        _ layer: CALayer,
        _ keyPath: String,
        from: CGFloat,
        to: CGFloat,
        timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut),
        duration: CFTimeInterval = NativeTimelineSendTransitionTiming.duration,
        delay: CFTimeInterval = 0,
        isAdditive: Bool = false
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        animation.isAdditive = isAdditive
        if delay > 0 {
            // Holds its starting value until the delayed start.
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: nil)
    }
}

/// The transcript's remaining offset while it glides into place.
struct NativeTimelineTranscriptGlide {
    let offset: CGFloat
    let beganAt: CFTimeInterval
    /// How long the rows stay put before gliding.
    let hold: CFTimeInterval
    let curve: NativeTimelineGlideCurve

    var endsAt: CFTimeInterval {
        beganAt + hold + curve.duration
    }

    func remaining(at time: CFTimeInterval) -> CGFloat {
        let fraction = (time - beganAt - hold) / curve.duration
        return offset * CGFloat(1 - curve.progress(at: fraction))
    }
}

/// An in-flight send transition owned by the timeline canvas.
@MainActor
final class NativeTimelineSendTransition {
    let identifier: NativeMessageTimelineItem.Identifier
    let overlay: NativeTimelineSendTransitionOverlay
    /// Attachments drawn by flying thumbnails instead of the bubble content.
    let omittedAttachments: Set<Int>
    var bubbleFrameInWindow: CGRect
    var endUptime: TimeInterval
    var finishTask: Task<Void, Never>?

    init(
        identifier: NativeMessageTimelineItem.Identifier,
        overlay: NativeTimelineSendTransitionOverlay,
        omittedAttachments: Set<Int>,
        bubbleFrameInWindow: CGRect,
        endUptime: TimeInterval
    ) {
        self.identifier = identifier
        self.overlay = overlay
        self.omittedAttachments = omittedAttachments
        self.bubbleFrameInWindow = bubbleFrameInWindow
        self.endUptime = endUptime
    }
}

extension NativeTimelineCanvasView {
    private static let transcriptGlideKey = "sakuraCordSendTransitionGlide"

    /// Starts the held content leaving the composer for its row as a bubble.
    /// `transcriptShift` is how far the earlier rows just moved in window
    /// coordinates, so they can glide there with the bubble instead of
    /// jumping.
    func beginSendTransition(
        from pending: NativeTimelineSendTransitionStore.Pending,
        rowIndex index: Int,
        transcriptShift: CGFloat
    ) {
        guard model?.animatesMessageSending == true else {
            pending.overlay.removeFromSuperview()
            cancelTranscriptGlide()
            return
        }
        guard let window,
              let (geometry, bubbleInWindow) = sendTransitionGeometry(
                  from: pending, rowIndex: index, in: window
              )
        else {
            pending.overlay.dismiss()
            glideTranscript(by: transcriptShift)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transition = NativeTimelineSendTransition(
            identifier: items[index].identifier,
            overlay: pending.overlay,
            omittedAttachments: Set(geometry.pieces.filter { !$0.fadesOut }.map(\.index)),
            bubbleFrameInWindow: bubbleInWindow,
            endUptime: CACurrentMediaTime() + NativeTimelineSendTransitionTiming.duration
                + pending.overlay.mediaDelay
        )
        // Earlier sends keep flying; each hides only its own row.
        sendTransitions.append(transition)
        suppressSendTransitionInteractions()
        // The canvas update already installed media at the destination.
        // Remove those overlays now that their row is held back for flight.
        reconcileAnimatedMedia()
        startVisibleInlineVideosImmediately()
        reconcileSpoilerOverlays()
        reconcileActivityIndicators()
        setNeedsDisplay(rowFrame(at: index))
        glideTranscript(by: transcriptShift)
        displayIfNeeded()
        pending.overlay.run(geometry, scale: window.backingScaleFactor)
        CATransaction.commit()
        scheduleSendTransitionFinish(transition)
    }

    private func sendTransitionGeometry(
        from pending: NativeTimelineSendTransitionStore.Pending,
        rowIndex index: Int,
        in window: NSWindow
    ) -> (NativeTimelineSendTransitionOverlay.Geometry, CGRect)? {
        let source = pending.source
        let overlay = pending.overlay
        guard model?.animatesMessageSending == true,
              source.window === window,
              overlay.window === window,
              items.indices.contains(index),
              layouts.indices.contains(index),
              case let .message(row, _, _) = items[index]
        else { return nil }
        let layout = layouts[index]
        let rowFrame = rowFrame(at: index)
        guard let target = layout.sendTransitionFrame(rowWidth: rowFrame.width) else { return nil }
        let toWindow = { (rect: CGRect) in
            self.convert(rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY), to: nil)
        }
        let targetInWindow = toWindow(target)
        guard convert(visibleRect, to: nil).intersects(targetInWindow) else { return nil }
        let flyingAttachments = Set(source.attachments.indices.filter {
            source.attachments[$0] != nil && layout.attachmentRegions.indices.contains($0)
        })
        // A preview that fades out, such as a file icon, reveals what the
        // bubble draws there instead.
        let fadingAttachments = flyingAttachments.filter {
            layout.attachmentRegions[$0].previewKey == nil
        }
        guard let content = sendTransitionContent(
            item: items[index],
            layout: layout,
            rowFrame: rowFrame,
            omittingAttachments: flyingAttachments.subtracting(fadingAttachments)
        ) else { return nil }
        let toOverlay = { (rect: CGRect) in overlay.convert(rect, from: nil) }
        let targetFrame = toOverlay(targetInWindow)
        let fieldFrame = toOverlay(source.fieldFrame)
        // Text leaves from its own baseline; anything else leaves from the
        // field's top leading corner.
        let anchors: (source: CGPoint, content: CGPoint)
        if let text = source.text, let baseline = content.baselineInWindow {
            anchors = (overlay.convert(text.baseline, from: nil), overlay.convert(baseline, from: nil))
        } else {
            anchors = (
                CGPoint(x: fieldFrame.minX, y: fieldFrame.maxY),
                CGPoint(x: targetFrame.minX, y: targetFrame.maxY)
            )
        }
        let mediaOpacity = Float(MessageOutboxPresentation.mediaOpacity(for: row.message.outboxState))
        let pieces = flyingAttachments.sorted().map { attachmentIndex in
            let attachmentRegion = layout.attachmentRegions[attachmentIndex]
            return NativeTimelineSendTransitionOverlay.Piece(
                index: attachmentIndex,
                frame: toOverlay(toWindow(attachmentRegion.frame)),
                cornerRadius: NativeTimelineRowPainter.attachmentCornerRadius,
                opacity: mediaOpacity,
                fadesOut: fadingAttachments.contains(attachmentIndex)
            )
        }
        let bubble = layout.bubbleRegion.map { region in
            var fillColor = NSColor.clear.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                fillColor = NativeTimelineBubbleDrawing.fillColor(for: region).cgColor
            }
            return NativeTimelineSendTransitionOverlay.Bubble(
                frame: targetFrame,
                cornerRadius: min(
                    NativeTimelineBubbleDrawing.cornerRadius,
                    targetFrame.height / 2,
                    targetFrame.width / 2
                ),
                tailPath: region.showsTail ? Self.sendTransitionTailPath() : nil,
                fillColor: fillColor
            )
        }
        let geometry = NativeTimelineSendTransitionOverlay.Geometry(
            fieldFrame: fieldFrame,
            bubble: bubble,
            contentImage: content.image,
            contentFrame: toOverlay(content.frameInWindow),
            contentAnchor: anchors.content,
            sourceAnchor: anchors.source,
            pieces: pieces
        )
        return (geometry, targetInWindow)
    }

    /// Keeps in-flight bubbles aimed at their rows after a later timeline
    /// update moves them, and ends a transition whose row changed shape.
    func reconcileSendTransitions() {
        guard model?.animatesMessageSending == true else {
            let store = model?.timelineSendTransitionStore
            let hasPending = presentedConversationID.map { store?.hasPendingSource(for: $0) == true } ?? false
            if hasPending || !sendTransitions.isEmpty {
                cancelTranscriptGlide()
            }
            if let presentedConversationID {
                store?.discard(presentedConversationID, animated: false)
            }
            finishSendTransitions(reconcilesHeldMedia: true)
            restoreSendTransitionInteractions()
            return
        }
        for transition in sendTransitions {
            reconcileSendTransition(transition)
        }
    }

    private func reconcileSendTransition(_ transition: NativeTimelineSendTransition) {
        guard let index = items.lastIndex(where: { $0.identifier == transition.identifier }),
              layouts.indices.contains(index),
              let target = layouts[index].sendTransitionFrame(rowWidth: rowFrame(at: index).width)
        else {
            finishSendTransition(transition)
            return
        }
        let rowFrame = rowFrame(at: index)
        let bubbleInWindow = convert(target.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY), to: nil)
        let previous = transition.bubbleFrameInWindow
        guard abs(bubbleInWindow.width - previous.width) < 0.5,
              abs(bubbleInWindow.height - previous.height) < 0.5
        else {
            // The copy no longer matches its row, so let it dissolve there.
            finishSendTransition(transition, dissolving: true)
            return
        }
        let delta = CGPoint(x: bubbleInWindow.minX - previous.minX, y: bubbleInWindow.minY - previous.minY)
        guard abs(delta.x) >= 0.5 || abs(delta.y) >= 0.5 else { return }
        transition.bubbleFrameInWindow = bubbleInWindow
        // Rows moved by the same update glide for a full duration from now;
        // the copy follows on that timing so both settle together.
        let duration = NativeTimelineSendTransitionTiming.duration
        transition.endUptime = max(transition.endUptime, CACurrentMediaTime() + duration)
        transition.overlay.retarget(by: delta, duration: duration)
        scheduleSendTransitionFinish(transition)
    }

    /// Re-renders the bubble content once media the flight started without
    /// has loaded.
    func refreshSendTransitionContent(
        for identifiers: Set<NativeMessageTimelineItem.Identifier>
    ) {
        for transition in sendTransitions where identifiers.contains(transition.identifier) {
            guard let index = items.lastIndex(where: { $0.identifier == transition.identifier }),
                  layouts.indices.contains(index),
                  let content = sendTransitionContent(
                      item: items[index],
                      layout: layouts[index],
                      rowFrame: rowFrame(at: index),
                      omittingAttachments: transition.omittedAttachments
                  )
            else { continue }
            transition.overlay.updateContent(content.image)
        }
    }

    /// Whether a message's row is hidden while its copy is in flight.
    func hidesRowForSendTransition(_ identifier: NativeMessageTimelineItem.Identifier) -> Bool {
        !sendTransitions.isEmpty && sendTransitions.contains { $0.identifier == identifier }
    }

    /// Ends every transition early. Scrolling and conversation changes
    /// reconcile media themselves; appearance changes must restore it here.
    func finishSendTransitions(reconcilesHeldMedia: Bool = false) {
        for transition in sendTransitions {
            finishSendTransition(transition, reconcilesHeldMedia: reconcilesHeldMedia)
        }
    }

    func finishSendTransition(
        _ transition: NativeTimelineSendTransition,
        dissolving: Bool = false,
        reconcilesHeldMedia: Bool = true
    ) {
        guard let position = sendTransitions.firstIndex(where: { $0 === transition }) else { return }
        sendTransitions.remove(at: position)
        transition.finishTask?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let index = items.lastIndex(where: { $0.identifier == transition.identifier }) {
            setNeedsDisplay(rowFrame(at: index))
            displayIfNeeded()
        }
        if dissolving {
            transition.overlay.dismiss()
        } else {
            transition.overlay.removeFromSuperview()
        }
        CATransaction.commit()
        guard reconcilesHeldMedia else { return }
        // The landed row's animated media, videos and spoiler covers were
        // held back while its copy was in flight.
        reconcileAnimatedMedia()
        startVisibleInlineVideosImmediately()
        reconcileSpoilerOverlays()
        reconcileActivityIndicators()
        restoreSendTransitionInteractions()
    }

    func cancelTranscriptGlide() {
        transcriptGlideFinishTask?.cancel()
        transcriptGlideFinishTask = nil
        transcriptGlide = nil
        layer?.removeAnimation(forKey: Self.transcriptGlideKey)
    }

    private func restoreSendTransitionInteractions() {
        guard !sendTransitionBlocksInteractions else { return }
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        synchronizeHoverWithCurrentPointer()
    }

    private func suppressSendTransitionInteractions() {
        // A press begun before the rows moved must not activate on release.
        clearPointerTargets()
        pressedPollTarget = nil
        hoveredPollTarget = nil
        textSelectionGesture = nil
        updateCodeCopyControl()
        reactionHoverCoordinator.close()
        removeActionCapsule()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        setNeedsDisplay(visibleRect)
    }

    var sendTransitionBlocksInteractions: Bool {
        !sendTransitions.isEmpty || isTranscriptGliding
    }

    var isTranscriptGliding: Bool {
        transcriptGlide.map { CACurrentMediaTime() < $0.endsAt } ?? false
    }

    /// The destination bubble, or a plain row's body, stays transparent while
    /// its copy is in flight. A plain row's author header remains, so it
    /// arrives with the transcript.
    func clearSendTransitionBubble(
        for item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout,
        rowFrame: CGRect
    ) {
        guard hidesRowForSendTransition(item.identifier),
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        if let region = layout.bubbleRegion {
            context.addPath(NativeTimelineBubbleDrawing.path(for: NativeTimelineBubbleRegion(
                frame: region.frame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY).insetBy(dx: -1, dy: -1),
                isOutgoing: region.isOutgoing,
                showsTail: region.showsTail
            )).cgPath)
        } else if let body = layout.sendTransitionFrame(rowWidth: rowFrame.width) {
            context.addRect(body.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY).insetBy(dx: -1, dy: 0))
        }
        context.fillPath()
        context.restoreGState()
    }

    /// Plays the earlier rows' jump back as a glide on the bubble's vertical
    /// curve. Pointer actions wait until this presentation-only animation
    /// reaches the final positions used by hit testing.
    func glideTranscript(
        by shift: CGFloat,
        holdingFor hold: CFTimeInterval = 0,
        on curve: NativeTimelineGlideCurve = NativeTimelineSendTransitionTiming.verticalCurve
    ) {
        guard abs(shift) >= 0.5, let layer else { return }
        // A send can move the rows twice in quick succession, once as the
        // composer collapses and again as the message arrives. Continue
        // from where the rows are drawn now so they travel only the net
        // distance.
        let now = CACurrentMediaTime()
        // Layer geometry follows the superview's coordinate space.
        let isFlippedSuperlayer = superview?.isFlipped == true
        var translation = (transcriptGlide?.remaining(at: now) ?? 0)
            + (isFlippedSuperlayer ? shift : -shift)
        // Only rows inside the bounded canvas backing can be drawn, so never
        // glide further than the backing extends past the viewport, unless
        // that edge is the document's own, which is empty beyond it.
        let visible = visibleRect
        let documentHeight = max(displayedContentHeight, minimumHeight)
        // Positive moves the drawn rows down, exposing rows above the viewport.
        let displacement = isFlippedSuperlayer ? translation : -translation
        let coverage = if displacement > 0 {
            bounds.minY <= 0.5 ? CGFloat.greatestFiniteMagnitude : visible.minY - bounds.minY
        } else {
            bounds.maxY >= documentHeight - 0.5 ? CGFloat.greatestFiniteMagnitude : bounds.maxY - visible.maxY
        }
        if abs(displacement) > coverage {
            translation = (translation < 0 ? -1 : 1) * max(0, coverage)
        }
        guard abs(translation) >= 0.5 else {
            cancelTranscriptGlide()
            restoreSendTransitionInteractions()
            return
        }
        transcriptGlide = NativeTimelineTranscriptGlide(
            offset: translation, beganAt: now, hold: hold, curve: curve
        )
        suppressSendTransitionInteractions()
        // Rows outside the viewport become visible during the glide.
        setNeedsDisplay(visible.insetBy(dx: 0, dy: -abs(translation)))
        let animation: CAAnimation
        if hold > 0 {
            let held = CAKeyframeAnimation(keyPath: "transform.translation.y")
            held.values = [translation, translation, 0]
            held.keyTimes = [0, NSNumber(value: hold / (hold + curve.duration)), 1]
            held.timingFunctions = [CAMediaTimingFunction(name: .linear), curve.timingFunction]
            held.isAdditive = true
            animation = held
        } else {
            let glide = CABasicAnimation(keyPath: "transform.translation.y")
            glide.fromValue = translation
            glide.toValue = 0
            glide.timingFunction = curve.timingFunction
            glide.isAdditive = true
            animation = glide
        }
        animation.duration = hold + curve.duration
        layer.add(animation, forKey: Self.transcriptGlideKey)
        transcriptGlideFinishTask?.cancel()
        transcriptGlideFinishTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(hold + curve.duration))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.transcriptGlideFinishTask = nil
            self.transcriptGlide = nil
            self.restoreSendTransitionInteractions()
        }
    }

    private func scheduleSendTransitionFinish(_ transition: NativeTimelineSendTransition) {
        transition.finishTask?.cancel()
        transition.finishTask = Task { @MainActor [weak self, weak transition] in
            // Hand off only once the transcript has also settled, so the
            // landed row cannot appear offset by a glide still in progress.
            while let transition, let self {
                let settles = max(transition.endUptime, self.transcriptGlide?.endsAt ?? 0)
                let remaining = settles - CACurrentMediaTime()
                guard remaining > 0 else { break }
                do {
                    try await Task.sleep(for: .milliseconds(Int(ceil(remaining * 1_000))))
                } catch {
                    return
                }
            }
            let mediaDeadline = CACurrentMediaTime()
                + NativeTimelineSendTransitionTiming.mediaWaitLimit
            while let self, let transition,
                  self.sendTransitions.contains(where: { $0 === transition }),
                  self.sendTransitionAwaitsMedia(transition),
                  CACurrentMediaTime() < mediaDeadline
            {
                do {
                    try await Task.sleep(for: .milliseconds(30))
                } catch {
                    return
                }
            }
            guard let self, let transition else { return }
            self.finishSendTransition(transition)
        }
    }

    private func sendTransitionAwaitsMedia(_ transition: NativeTimelineSendTransition) -> Bool {
        guard let index = items.lastIndex(where: { $0.identifier == transition.identifier })
        else { return false }
        return mediaKeys(for: items[index], at: index).contains {
            NativeTimelineRowPainter.mediaImage(for: $0) == nil
        }
    }

    private struct SendTransitionContent {
        let image: NSImage
        let frameInWindow: CGRect
        let baselineInWindow: CGPoint?
    }

    /// Renders what the destination bubble or plain body contains, without a
    /// bubble's fill, so the flying copy can morph its own background
    /// independently. Attachments that arrive as flying thumbnails are left
    /// out.
    private func sendTransitionContent(
        item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout,
        rowFrame: CGRect,
        omittingAttachments omitted: Set<Int>
    ) -> SendTransitionContent? {
        let bubblePath: NSBezierPath
        if let region = layout.bubbleRegion {
            bubblePath = NativeTimelineBubbleDrawing.path(for: region)
        } else if let body = layout.sendTransitionFrame(rowWidth: rowFrame.width) {
            bubblePath = NSBezierPath(rect: body)
        } else {
            return nil
        }
        let drawRect = bubblePath.bounds.insetBy(dx: -1, dy: -1).integral
        guard let image = NativeTimelineSendTransitionSnapshot.render(
            size: drawRect.size,
            scale: window?.backingScaleFactor ?? 2,
            draw: {
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                context.translateBy(x: -drawRect.minX, y: -drawRect.minY)
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    bubblePath.addClip()
                    NativeTimelineRowPainter.draw(
                        item: item,
                        layout: layout,
                        in: CGRect(x: 0, y: 0, width: rowFrame.width, height: layout.height),
                        model: model,
                        isHovered: false,
                        drawsBubbleBackground: false,
                        spoilerRevealStore: spoilerRevealStore
                    )
                }
                let omittedFrames = omitted.compactMap {
                    layout.attachmentRegions.indices.contains($0)
                        ? layout.attachmentRegions[$0].frame : nil
                }
                guard !omittedFrames.isEmpty else { return }
                context.setBlendMode(.clear)
                for frame in omittedFrames {
                    context.addPath(NSBezierPath(
                        concentricRoundedRect: frame,
                        cornerRadius: NativeTimelineRowPainter.attachmentCornerRadius
                    ).cgPath)
                }
                context.fillPath()
            }
        ) else { return nil }
        return SendTransitionContent(
            image: image,
            frameInWindow: convert(drawRect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY), to: nil),
            baselineInWindow: Self.firstBaseline(of: layout).map {
                convert(CGPoint(x: rowFrame.minX + $0.x, y: rowFrame.minY + $0.y), to: nil)
            }
        )
    }

    /// The leading end of the message text's first baseline in row
    /// coordinates, matching the painter's CoreText frame.
    private static func firstBaseline(of layout: NativeTimelineRowLayout) -> CGPoint? {
        guard let contentFrame = layout.contentFrame,
              let attributedContent = layout.attributedContent,
              attributedContent.length > 0,
              let framesetter = layout.contentFramesetter
        else { return nil }
        let drawingFrame = NativeTimelineTextGeometry.messageContentDrawingFrame(contentFrame)
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributedContent.length),
            CGPath(rect: CGRect(origin: .zero, size: drawingFrame.size), transform: nil),
            nil
        )
        guard CFArrayGetCount(CTFrameGetLines(textFrame)) > 0 else { return nil }
        var lineOrigin = CGPoint.zero
        CTFrameGetLineOrigins(textFrame, CFRange(location: 0, length: 1), &lineOrigin)
        return CGPoint(
            x: drawingFrame.minX + lineOrigin.x,
            y: drawingFrame.maxY - lineOrigin.y
        )
    }

    /// The bubble tail relative to its bottom trailing corner, in the
    /// overlay's unflipped coordinates.
    private static func sendTransitionTailPath() -> CGPath {
        let size: CGFloat = 64
        let path = NativeTimelineBubbleDrawing.tailPath(for: NativeTimelineBubbleRegion(
            frame: CGRect(x: -size, y: -size, width: size, height: size),
            isOutgoing: true,
            showsTail: true
        ))
        path.transform(using: AffineTransform(scaleByX: 1, byY: -1))
        return path.cgPath
    }
}

extension NativeMessageTimelineCoordinator {
    struct SendTransitionTranscriptAnchor {
        /// The newest existing message row and where it was.
        let identifier: NativeMessageTimelineItem.Identifier?
        let frameInWindow: CGRect?
        /// Rows that existed before the update, so new ones can be told apart.
        let recentIdentifiers: Set<NativeMessageTimelineItem.Identifier>
        /// Whether a send was already under way before the update.
        let isSending: Bool
    }

    /// Records the transcript's tail before an update in a conversation whose
    /// composer can send into it, so a send's arrival can be recognised and
    /// the rows' jump measured afterwards.
    func sendTransitionTranscriptAnchor(
        for parent: NativeMessageTimelineView
    ) -> SendTransitionTranscriptAnchor? {
        guard parent.conversation == self.parent.conversation,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let channelID = parent.conversation.sendTransitionChannelID,
              let canvas
        else { return nil }
        let store = parent.model.timelineSendTransitionStore
        let isSending = !canvas.sendTransitions.isEmpty || store.hasPendingSource(for: channelID)
        guard isSending || store.hasComposer(for: channelID) else { return nil }
        let index = items.lastIndex(where: { $0.messageID != nil })
        return SendTransitionTranscriptAnchor(
            identifier: index.map { items[$0].identifier },
            frameInWindow: index.map { canvas.convert(canvas.rowFrame(at: $0), to: nil) },
            recentIdentifiers: Set(items.suffix(4).map(\.identifier)),
            isSending: isSending
        )
    }

    func updateSendTransition(
        parent: NativeMessageTimelineView,
        preparation: TimelineUpdatePreparation,
        transcriptAnchor anchor: SendTransitionTranscriptAnchor?
    ) {
        guard let canvas else { return }
        canvas.reconcileSendTransitions()
        guard let anchor,
              !preparation.conversationChanged,
              let channelID = parent.conversation.sendTransitionChannelID
        else { return }
        let shift: () -> CGFloat = { [items] in
            guard let identifier = anchor.identifier,
                  let previous = anchor.frameInWindow,
                  let index = items.lastIndex(where: { $0.identifier == identifier })
            else { return 0 }
            return canvas.convert(canvas.rowFrame(at: index), to: nil).minY - previous.minY
        }
        if didMutateItems,
           let (index, pending) = sendTransitionCandidate(
               parent: parent, channelID: channelID, anchor: anchor
           )
        {
            canvas.beginSendTransition(from: pending, rowIndex: index, transcriptShift: shift())
        } else if anchor.isSending, parent.model.animatesMessageSending {
            // The composer resizing as it clears moves the transcript too.
            // Until the message arrives, hold the rows where they were so
            // they move once, together with the bubble.
            let holdsForMessage = canvas.sendTransitions.isEmpty
                && preparation.bottomInsetChanged
            canvas.glideTranscript(
                by: shift(),
                holdingFor: holdsForMessage ? NativeTimelineSendTransitionStore.lifetime : 0
            )
        } else if preparation.bottomInsetChanged,
                  let destination = parent.conversation.composerDestination,
                  parent.model.composer.isAnimatingResize(of: destination)
        {
            // The composer is growing or shrinking on its resize curve; the
            // rows the inset just moved follow its edge on the same curve.
            canvas.glideTranscript(by: shift(), on: ComposerResizeMotion.glideCurve)
        } else if preparation.bottomInsetChanged, preparation.wasNearBottom {
            // Footer chrome such as the typing bubble resized under the
            // newest rows. Glide them with it rather than jumping.
            canvas.glideTranscript(by: shift())
        }
    }

    /// The optimistic row a send from this window just added, with the
    /// composer state it leaves from.
    private func sendTransitionCandidate(
        parent: NativeMessageTimelineView,
        channelID: ChannelID,
        anchor: SendTransitionTranscriptAnchor
    ) -> (Int, NativeTimelineSendTransitionStore.Pending)? {
        guard parent.model.animatesMessageSending else { return nil }
        let store = parent.model.timelineSendTransitionStore
        let currentUserID = parent.model.currentUser?.id
        for index in items.indices.reversed().prefix(3) {
            // A fast confirmation can replace the optimistic row before this
            // update, so recognise this client's send by its nonce.
            guard case let .message(row, _, _) = items[index],
                  !anchor.recentIdentifiers.contains(items[index].identifier),
                  let nonce = row.message.nonce,
                  store.isRecentLocalSend(nonce: nonce),
                  row.message.author.id == currentUserID
            else { continue }
            if let pending = store.consume(for: row.message) {
                return (index, pending)
            }
            // A captured draft waits for its own row; another send arriving
            // first appears without the transition.
            guard !store.hasPendingSource(for: channelID),
                  let pending = store.fieldPending(for: channelID, in: canvas?.window)
            else { continue }
            return (index, pending)
        }
        return nil
    }
}

extension NativeTimelineConversation {
    /// Conversations whose composer can send into this timeline.
    var sendTransitionChannelID: ChannelID? {
        switch self {
        case let .channel(id), let .thread(id):
            id
        case .search, .pins, .inbox, .resource:
            nil
        }
    }

    /// The composer that sits over this timeline.
    var composerDestination: MessageComposerDestination? {
        switch self {
        case .channel: .channel
        case .thread: .thread
        case .search, .pins, .inbox, .resource: nil
        }
    }
}

extension NativeTimelineRowLayout {
    /// The part of a row sent from the composer that leaves the field: its
    /// outgoing bubble, or without bubbles, the message body beside the
    /// avatar column and below the author header, which stays in the
    /// transcript.
    func sendTransitionFrame(rowWidth: CGFloat) -> CGRect? {
        if let bubbleRegion {
            return bubbleRegion.isOutgoing ? bubbleRegion.frame : nil
        }
        let bodyFrames = [
            contentFrame, forwardedHeaderFrame, voiceMessageRegion?.frame, pollLayout?.frame,
        ].compactMap { $0 }
            + attachmentRegions.map(\.frame)
            + uploadRegions.map(\.frame)
            + linkedImageRegions.map(\.frame)
            + stickerFrames
            + embedFrames
            + componentFrames
        guard let first = bodyFrames.first else { return nil }
        let body = bodyFrames.dropFirst().reduce(first) { $0.union($1) }
        return CGRect(
            x: body.minX,
            y: body.minY,
            width: max(body.width, rowWidth - body.minX),
            height: max(body.height, height - body.minY)
        )
    }
}
