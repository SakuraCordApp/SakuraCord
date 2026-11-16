import AppKit
import QuartzCore
import SakuraCordModels
import SwiftUI

/// The Messages-style typing bubble: a capsule with a two-circle thought tail
/// whose three dots darken in a left-to-right wave.
///
/// Core Animation runs the loop in the render server, so a visible indicator
/// never redraws the footer or wakes the main thread.
@MainActor
final class TypingBubble {
    /// Proportions follow Messages' typing bubble, scaled so the body is
    /// exactly as tall as a one-line message bubble.
    private enum Metrics {
        private static var unit: CGFloat { NativeTimelineBubbleLayout.oneLineHeight / 36 }
        static var bodySize: CGSize { CGSize(width: 60 * unit, height: 36 * unit) }
        /// How far the tail's small circle reaches past the body's leading edge.
        static var leadingOverhang: CGFloat { 7.5 * unit }
        static var bottomOverhang: CGFloat { 4 * unit }
        static var dotDiameter: CGFloat { 9 * unit }
        static var dotSpacing: CGFloat { 13 * unit }
        static var cornerCircleDiameter: CGFloat { 11 * unit }
        static var cornerCircleInset: CGFloat { 3.5 * unit }
        static var tinyCircleDiameter: CGFloat { 6 * unit }
        static var tinyCircleOffset: CGPoint { CGPoint(x: -4.5 * unit, y: 0.7 * unit) }
    }

    static var size: CGSize {
        CGSize(
            width: Metrics.leadingOverhang + Metrics.bodySize.width,
            height: Metrics.bodySize.height + Metrics.bottomOverhang
        )
    }

    /// The body's leading edge, which lines up with incoming message bubbles.
    static var bodyLeadingInset: CGFloat { Metrics.leadingOverhang }
    static var bodyHeight: CGFloat { Metrics.bodySize.height }
    /// The body's width with nothing beside the dots.
    static var minimumBodyWidth: CGFloat { Metrics.bodySize.width }
    /// Where the dots end inside the body. They keep their place however
    /// wide the body grows, so content beside them starts here.
    static var dotsTrailingEdge: CGFloat {
        minimumBodyWidth / 2 + Metrics.dotSpacing + Metrics.dotDiameter / 2
    }

    // Each dot darkens for just under half a cycle, trailing the previous one
    // by a quarter, so the wave crosses the bubble and briefly rests.
    private static let cycle: CFTimeInterval = 1.32
    private static let dotStagger: CFTimeInterval = 0.33
    private static let dimDotOpacity: Float = 0.5
    /// The loops are slow eases, so they need not redraw at ProMotion rates
    /// for as long as someone types.
    private static let loopFrameRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

    private static let dotColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.68, green: 0.68, blue: 0.70, alpha: 1)
            : NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
    }

    /// The tail, body, and dots, laid out from the origin.
    let layer = CALayer()
    /// Holds the dots, and anything shown beside them, in coordinates from
    /// its leading edge.
    let body = CALayer()
    private let cornerCircle = CALayer()
    private let tinyCircle = CALayer()
    private let dots = (0 ..< 3).map { _ in CALayer() }
    private var bodyWidth: CGFloat?

    init() {
        for sublayer in [tinyCircle, cornerCircle, body] {
            layer.addSublayer(sublayer)
        }
        dots.forEach(body.addSublayer)
        layOut()
    }

    /// Grows or shrinks the body from its leading edge, which stays put.
    /// The caller disables implicit actions.
    func setBodyWidth(_ width: CGFloat, animated: Bool) {
        let from = body.bounds.width
        bodyWidth = width
        layOut()
        guard animated, from != width else { return }
        // Width and centre ride the same spring, so the leading edge holds
        // exactly; additive springs keep their velocity when retargeted.
        for (keyPath, offset) in [("bounds.size.width", from - width), ("position.x", (from - width) / 2)] {
            let spring = TypingIndicator.spring(keyPath)
            spring.isAdditive = true
            spring.fromValue = offset
            spring.toValue = 0
            body.add(spring, forKey: nil)
        }
    }

    func layOut() {
        let bodyFrame = CGRect(
            origin: CGPoint(x: Metrics.leadingOverhang, y: 0),
            size: CGSize(width: bodyWidth ?? Metrics.bodySize.width, height: Metrics.bodySize.height)
        )
        layer.frame = CGRect(
            x: 0, y: 0,
            width: bodyFrame.maxX,
            height: Self.size.height
        )
        place(body, frame: bodyFrame)
        let corner = Metrics.cornerCircleDiameter
        place(cornerCircle, frame: CGRect(
            x: bodyFrame.minX + Metrics.cornerCircleInset - corner / 2,
            y: bodyFrame.maxY - corner,
            width: corner,
            height: corner
        ))
        let tiny = Metrics.tinyCircleDiameter
        place(tinyCircle, frame: CGRect(
            x: bodyFrame.minX + Metrics.tinyCircleOffset.x - tiny / 2,
            y: bodyFrame.maxY + Metrics.tinyCircleOffset.y - tiny / 2,
            width: tiny,
            height: tiny
        ))
        let dot = Metrics.dotDiameter
        for (index, layer) in dots.enumerated() {
            let centerX = Self.minimumBodyWidth / 2 + CGFloat(index - 1) * Metrics.dotSpacing
            place(layer, frame: CGRect(
                x: centerX - dot / 2,
                y: (bodyFrame.height - dot) / 2,
                width: dot,
                height: dot
            ))
        }
    }

    func stopAnimating() {
        ([body, cornerCircle, tinyCircle] + dots).forEach { $0.removeAllAnimations() }
    }

    private func place(_ layer: CALayer, frame: CGRect) {
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.cornerRadius = min(frame.width, frame.height) / 2
    }

    func updateColors(for appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            let fill = NativeTimelineBubbleDrawing.incomingFillColor.cgColor
            [body, cornerCircle, tinyCircle].forEach { $0.backgroundColor = fill }
            let dot = Self.dotColor.cgColor
            dots.forEach { $0.backgroundColor = dot }
        }
    }

    func startAnimating() {
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = Self.cycle * (reducesMotion ? 2 : 1)
        for (index, dot) in dots.enumerated() {
            let wave = CAKeyframeAnimation(keyPath: "opacity")
            wave.values = [Self.dimDotOpacity, 1, Self.dimDotOpacity, Self.dimDotOpacity]
            wave.keyTimes = [0, 0.22, 0.44, 1]
            wave.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            wave.preferredFrameRateRange = Self.loopFrameRate
            let lag = Self.dotStagger / Self.cycle * duration * CFTimeInterval(index)
            wave.repeatOnMediaClock(cycle: duration, lead: -lag)
            dot.opacity = Self.dimDotOpacity
            dot.add(wave, forKey: "wave")
        }
    }
}

/// Bubble mode's typing indicator. It sits where the next incoming bubble
/// would, and in group conversations a stack of the typists' avatars follows.
///
/// The footer only reserves the indicator's height. Its arrival, departure,
/// and avatar changes all run in Core Animation alongside the transcript
/// glide, so they stay smooth however busy the main thread is.
struct TypingBubbleIndicatorView: View {
    let model: AppModel
    let channel: Channel

    var body: some View {
        let showsAvatars = NativeTimelineBubbleLayout.showsAvatar(in: channel)
        let presentation = model.typingState.presentation(in: channel.id)
        // Typing events already carry each typist's guild profile.
        let typists = showsAvatars
            ? model.typingState.usersNewestFirst(in: channel.id).map {
                TypingIndicator.Typist(id: $0.id, avatarURL: $0.avatarURL)
            }
            : []
        let leadingInset = NativeTimelineBubbleLayout.incomingBubbleMinX(
            showsAvatar: showsAvatars,
            settings: model.interfaceSettings
        )
        TypingIndicatorRepresentable(
            state: TypingIndicator.State(channelID: channel.id, typists: typists, presentation: presentation)
        )
        .frame(width: TypingIndicator.width, height: presentation == nil ? 0 : TypingIndicator.height)
        .padding(.leading, leadingInset - TypingBubble.bodyLeadingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }
}

private struct TypingIndicatorRepresentable: NSViewRepresentable {
    let state: TypingIndicator.State

    func makeNSView(context _: Context) -> TypingIndicator {
        TypingIndicator()
    }

    func updateNSView(_ view: TypingIndicator, context _: Context) {
        view.update(state)
    }
}

/// Draws the typing bubble bottom-aligned to its bounds, with the typists'
/// avatars stacked inside it after the dots. When the footer collapses it to
/// zero height, the content keeps drawing above it while it shrinks away.
final class TypingIndicator: NSView {
    struct Typist: Equatable {
        let id: UserID
        let avatarURL: URL
    }

    struct State: Equatable {
        let channelID: ChannelID
        /// Newest first: each new typist joins beside the dots and pushes
        /// the others along, and anyone past the visible few folds into the
        /// count. Empty where avatars do not show.
        let typists: [Typist]
        /// Who is typing, or nil when nobody is.
        let presentation: String?

        var isTyping: Bool { presentation != nil }
    }

    private enum Metrics {
        static let maximumVisibleAvatars = 4
        static var bottomPadding: CGFloat { InterfaceScale.metric(6) }
        static var avatarDiameter: CGFloat { InterfaceScale.metric(24) }
        static var avatarOverlap: CGFloat { InterfaceScale.metric(8) }
        static var ringWidth: CGFloat { InterfaceScale.metric(2) }
        /// Concentric with the body's rounded end.
        static var avatarInset: CGFloat { (TypingBubble.bodyHeight - avatarDiameter) / 2 }
        static var dotsGap: CGFloat { InterfaceScale.metric(8) }
        static var countGap: CGFloat { InterfaceScale.metric(4) }
        static var countTrailingPadding: CGFloat { InterfaceScale.metric(8) }
        /// Room reserved for a two-digit count.
        static var countAllowance: CGFloat { InterfaceScale.metric(20) }
        static var countFontSize: CGFloat { InterfaceScale.fontSize(10) }
        /// How long a new avatar waits for its picture before it shows its
        /// placeholder instead.
        static let pictureWait: Duration = .milliseconds(350)
    }

    static var height: CGFloat { TypingBubble.size.height + Metrics.bottomPadding }
    /// Room for the bubble holding a full stack and a two-digit count.
    static var width: CGFloat {
        TypingBubble.bodyLeadingInset
            + bodyWidth(avatars: Metrics.maximumVisibleAvatars, countWidth: Metrics.countAllowance)
    }

    private static var stackX: CGFloat { TypingBubble.dotsTrailingEdge + Metrics.dotsGap }
    private static var avatarStep: CGFloat { Metrics.avatarDiameter - Metrics.avatarOverlap }

    private static func stackWidth(_ avatars: Int) -> CGFloat {
        avatars > 0 ? Metrics.avatarDiameter + CGFloat(avatars - 1) * avatarStep : 0
    }

    private static func bodyWidth(avatars: Int, countWidth: CGFloat?) -> CGFloat {
        guard avatars > 0 else { return TypingBubble.minimumBodyWidth }
        let end = countWidth.map { Metrics.countGap + $0 + Metrics.countTrailingPadding } ?? Metrics.avatarInset
        return stackX + stackWidth(avatars) + end
    }

    /// An avatar is three layers deep so each part of its motion has one
    /// owner: `layer` slides along the stack, each clip cuts the ring of one
    /// avatar in front, and `picture` grows in and out.
    private final class AvatarSlot {
        let layer = CALayer()
        /// Nested, so their masks intersect: an avatar can sit behind two
        /// others while one slides into the place of another that leaves.
        let clips = [CALayer(), CALayer()]
        let picture = CALayer()
        var typist: Typist?
        /// A new avatar stays hidden while its picture loads.
        var isWaitingForPicture = false
        var load: Task<Void, Never>?
        var wait: Task<Void, Never>?

        init() {
            layer.addSublayer(clips[0])
            clips[0].addSublayer(clips[1])
            clips[1].addSublayer(picture)
            picture.masksToBounds = true
            picture.contentsGravity = .resizeAspectFill
            picture.anchorPoint = CGPoint(x: 0, y: 0.5)
            layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        }

        func size(diameter: CGFloat) {
            let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            layer.bounds = bounds
            clips.forEach { $0.frame = bounds }
            picture.bounds = bounds
            picture.position = CGPoint(x: 0, y: diameter / 2)
            picture.cornerRadius = diameter / 2
        }

        func cancelLoading() {
            load?.cancel()
            wait?.cancel()
        }
    }

    private let content = CALayer()
    private let bubble = TypingBubble()
    private let count = CALayer()
    private let countText = CATextLayer()
    private var slots: [UserID: AvatarSlot] = [:]
    /// The visible typists, newest first.
    private var order: [UserID] = []
    /// Every avatar on screen from front to back, including departing ones
    /// until their exit finishes. A departing avatar keeps its place, so it
    /// stays behind everyone who was in front of it while it leaves.
    private var stack: [AvatarSlot] = []
    private var appliedAvatarDiameter = Metrics.avatarDiameter
    private var themeObserver: NSObjectProtocol?
    private var state: State?
    private var isShown: Bool { state?.isTyping == true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        content.anchorPoint = CGPoint(x: 0, y: 1)
        content.isHidden = true
        layer?.addSublayer(content)
        content.addSublayer(bubble.layer)
        count.anchorPoint = CGPoint(x: 0, y: 0.5)
        count.opacity = 0
        count.addSublayer(countText)
        countText.alignmentMode = .left
        updateCountFont()
        bubble.body.addSublayer(count)
        setAccessibilityElement(false)
        setAccessibilityRole(.staticText)
        themeObserver = NotificationCenter.default.addObserver(
            forName: .sakuraCordThemeDidCommit, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateColors() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShown, let superview, let layer else { return nil }
        let local = content.convert(convert(point, from: superview), from: layer)
        return bubble.layer.frame.contains(local) ? self : nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.bounds = CGRect(x: 0, y: 0, width: Self.width, height: TypingBubble.size.height)
        content.position = CGPoint(x: 0, y: bounds.maxY - Metrics.bottomPadding)
        bubble.layOut()
        if appliedAvatarDiameter != Metrics.avatarDiameter { resizeStack() }
        CATransaction.commit()
    }

    /// Interface Size changed: resize every avatar and the count, then lay
    /// the stack out again.
    private func resizeStack() {
        appliedAvatarDiameter = Metrics.avatarDiameter
        updateCountFont()
        for slot in stack {
            slot.size(diameter: Metrics.avatarDiameter)
        }
        updateStack(state?.typists ?? [], animated: false)
    }

    private func updateCountFont() {
        countText.font = NSFont.systemFont(ofSize: Metrics.countFontSize, weight: .semibold)
        countText.fontSize = Metrics.countFontSize
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        countText.contentsScale = scale
        stack.forEach { $0.picture.contentsScale = scale }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            bubble.stopAnimating()
        } else {
            viewDidChangeBackingProperties()
            updateColors()
            if isShown { bubble.startAnimating() }
        }
    }

    func update(_ newState: State) {
        guard newState != state else { return }
        let previous = state
        state = newState
        setAccessibilityElement(newState.presentation != nil)
        setAccessibilityLabel(newState.presentation)
        toolTip = newState.presentation
        // A different conversation replaces the indicator outright.
        let animates = previous?.channelID == newState.channelID && window != nil
        let wasTyping = previous?.isTyping == true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if newState.isTyping, !wasTyping {
            show(animated: animates)
            updateStack(newState.typists, animated: false)
        } else if !newState.isTyping, wasTyping {
            hide(animated: animates)
        } else if newState.isTyping {
            updateStack(newState.typists, animated: animates)
        }
        CATransaction.commit()
    }

    // MARK: Arrival and departure

    private func show(animated: Bool) {
        content.removeAnimation(forKey: "presence")
        content.isHidden = false
        content.opacity = 1
        content.transform = CATransform3DIdentity
        if window != nil { bubble.startAnimating() }
        guard animated else { return }
        // Grows out of its tail as the rows above glide up to make room, at
        // the speed and on the curve of a sent message.
        content.add(scaleFade(from: 0, to: 1), forKey: "presence")
    }

    private func hide(animated: Bool) {
        guard animated else {
            finishHiding()
            return
        }
        // Shrinks back into its tail as the rows glide down over it. The
        // layer holds its final state itself, so nothing reappears when the
        // animation ends.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !isShown else { return }
            finishHiding()
        }
        content.opacity = 0
        content.add(scaleFade(from: 1, to: 0), forKey: "presence")
        CATransaction.commit()
    }

    private func finishHiding() {
        // Hiding a layer implicitly cross-fades it, which would flash it back.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.removeAnimation(forKey: "presence")
        content.isHidden = true
        bubble.stopAnimating()
        updateStack([], animated: false)
        CATransaction.commit()
    }

    /// Fades between the opacities while scaling by the same amount, or
    /// toward `minimumScale` when that is larger; Reduce Motion only fades.
    private func scaleFade(
        from: CGFloat,
        to: CGFloat,
        minimumScale: CGFloat = 0.001,
        duration: CFTimeInterval = NativeTimelineSendTransitionTiming.duration,
        timing: CAMediaTimingFunction = NativeTimelineSendTransitionTiming.vertical
    ) -> CAAnimation {
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = from
        opacity.toValue = to
        var animations: [CAAnimation] = [opacity]
        if !reducesMotion {
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = Self.scale(max(from, minimumScale))
            scale.toValue = Self.scale(max(to, minimumScale))
            animations.append(scale)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = timing
        return group
    }

    // MARK: Avatar stack

    private func updateStack(_ typists: [Typist], animated: Bool) {
        let visible = Array(typists.prefix(Metrics.maximumVisibleAvatars))
        let visibleIDs = Set(visible.map(\.id))
        for id in order where !visibleIDs.contains(id) {
            guard let slot = slots.removeValue(forKey: id) else { continue }
            slot.cancelLoading()
            if animated {
                depart(slot)
            } else {
                remove(slot)
            }
        }
        order = visible.map(\.id)
        // A new typist joins at the front, beside the dots. Someone the
        // count held steps out of it at the back instead.
        var joiningFront: [AvatarSlot] = []
        var joiningBack: [AvatarSlot] = []
        for (index, typist) in visible.enumerated() {
            let isNew = slots[typist.id] == nil
            let slot = slots[typist.id] ?? makeSlot(for: typist.id, at: index)
            if isNew {
                if index == 0 { joiningFront.append(slot) } else { joiningBack.append(slot) }
            }
            move(slot.layer, to: avatarPosition(at: index), animated: animated)
            load(typist, into: slot, arrives: isNew && animated)
        }
        if animated {
            stack = joiningFront + stack + joiningBack
        } else {
            // Channel replacement can reorder the same typists. Rebuild the
            // drawing and masking order, discarding any departures in flight.
            for slot in stack where !order.contains(where: { slots[$0] === slot }) {
                remove(slot)
            }
            stack = order.compactMap { slots[$0] }
        }
        restack()
        let countWidth = updateCount(typists.count - visible.count, after: visible.count, animated: animated)
        bubble.setBodyWidth(
            Self.bodyWidth(avatars: visible.count, countWidth: countWidth),
            animated: animated && !reducesMotion
        )
        updateRings()
    }

    private func restack() {
        for (index, slot) in stack.enumerated() {
            slot.layer.zPosition = CGFloat(stack.count - index)
        }
    }

    private func avatarPosition(at index: Int) -> CGPoint {
        CGPoint(x: Self.stackX + CGFloat(index) * Self.avatarStep, y: TypingBubble.bodyHeight / 2)
    }

    private func makeSlot(for id: UserID, at index: Int) -> AvatarSlot {
        let slot = AvatarSlot()
        slot.size(diameter: Metrics.avatarDiameter)
        slot.layer.position = avatarPosition(at: index)
        slot.picture.contentsScale = window?.backingScaleFactor ?? 2
        bubble.body.insertSublayer(slot.layer, below: count)
        slots[id] = slot
        return slot
    }

    private func remove(_ slot: AvatarSlot) {
        slot.layer.removeFromSuperlayer()
        stack.removeAll { $0 === slot }
    }

    /// Masks each avatar's clips with ghosts of the nearest avatars in front
    /// of it: a large shape with a hole the size of that avatar and its ring.
    /// A ghost carries copies of its avatar's in-flight animations, and the
    /// inverse of the masked avatar's own slides, so the hole follows the
    /// avatar in front through every slide, growth, and fade entirely in
    /// the render server.
    private func updateRings() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, slot) in stack.enumerated() {
            let inFront = Array(stack[..<index].reversed())
            for (level, clip) in slot.clips.enumerated() {
                clip.mask = level < inFront.count ? ghost(of: inFront[level], over: slot) : nil
            }
        }
        CATransaction.commit()
    }

    private func ghost(of front: AvatarSlot, over back: AvatarSlot) -> CALayer {
        let diameter = Metrics.avatarDiameter
        let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let ring = bounds.insetBy(dx: -Metrics.ringWidth, dy: -Metrics.ringWidth)
        let ghost = CAShapeLayer()
        ghost.bounds = bounds
        ghost.anchorPoint = front.picture.anchorPoint
        // Large enough to cover the avatar behind even while the ghost is
        // scaled down with an avatar growing in.
        let cover = CGMutablePath()
        cover.addRect(bounds.insetBy(dx: -12 * diameter, dy: -12 * diameter))
        cover.addEllipse(in: ring)
        ghost.path = cover
        ghost.fillRule = .evenOdd
        // Closes the hole as the avatar in front fades.
        let fill = CAShapeLayer()
        fill.frame = bounds
        fill.path = CGPath(ellipseIn: ring, transform: nil)
        ghost.addSublayer(fill)

        let offset = CGPoint(
            x: front.layer.position.x - back.layer.position.x,
            y: front.layer.position.y - back.layer.position.y
        )
        ghost.position = CGPoint(x: offset.x + front.picture.position.x, y: offset.y + front.picture.position.y)
        ghost.transform = front.picture.transform
        fill.opacity = 1 - front.picture.opacity
        for (key, animation) in animations(of: front.layer) where animation.keyPath == "position" {
            ghost.add(animation, forKey: "front-\(key)")
        }
        for (key, animation) in animations(of: back.layer) where animation.keyPath == "position" {
            guard let slide = animation.copy() as? CABasicAnimation,
                  let from = slide.fromValue as? CGPoint
            else { continue }
            slide.fromValue = CGPoint(x: -from.x, y: -from.y)
            ghost.add(slide, forKey: "back-\(key)")
        }
        for (key, animation) in animations(of: front.picture) {
            switch animation.keyPath {
            case "transform":
                ghost.add(animation, forKey: key)
            case "opacity":
                guard let fade = animation.copy() as? CABasicAnimation,
                      let from = fade.fromValue as? CGFloat,
                      let to = fade.toValue as? CGFloat
                else { continue }
                fade.fromValue = 1 - from
                fade.toValue = 1 - to
                fill.add(fade, forKey: key)
            default:
                continue
            }
        }
        return ghost
    }

    private func animations(of layer: CALayer) -> [(String, CABasicAnimation)] {
        (layer.animationKeys() ?? []).compactMap { key in
            (layer.animation(forKey: key) as? CABasicAnimation).map { (key, $0) }
        }
    }

    /// Shows the typist's picture. A new avatar whose picture still has to
    /// load waits for it, briefly, so it grows in with its picture rather
    /// than swapping a placeholder for it mid-animation.
    private func load(_ typist: Typist, into slot: AvatarSlot, arrives: Bool) {
        let previous = slot.typist
        slot.typist = typist
        guard previous?.avatarURL != typist.avatarURL else { return }
        let isNew = previous == nil
        slot.cancelLoading()
        let url = typist.avatarURL
        // Share the timeline's decoded avatars, so anyone with a visible
        // message shows their picture straight away.
        let dimension = MediaImageKey.avatarPixelDimension
        if let cached = SharedDecodedImageLoader.shared.cachedImage(
            for: url, maximumPixelDimension: dimension, preparesForTimeline: true
        ) {
            show(cached, in: slot, arrives: arrives)
            return
        }
        if isNew {
            slot.isWaitingForPicture = true
            slot.picture.opacity = 0
            slot.wait = Task { @MainActor [weak self, weak slot] in
                try? await Task.sleep(for: Metrics.pictureWait)
                guard !Task.isCancelled, let self, let slot else { return }
                show(nil, in: slot, arrives: true)
            }
        } else {
            show(nil, in: slot, arrives: false)
        }
        slot.load = Task { @MainActor [weak self, weak slot] in
            let image = await SharedDecodedImageLoader.shared.image(
                for: url, maximumPixelDimension: dimension, priority: .visible, preparesForTimeline: true
            )
            guard !Task.isCancelled, let self, let slot, slot.typist?.avatarURL == url, let image else { return }
            show(image, in: slot, arrives: slot.isWaitingForPicture)
        }
    }

    /// A nil image shows a neutral circle while the picture loads.
    private func show(_ image: CGImage?, in slot: AvatarSlot, arrives: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slot.picture.contents = image
        slot.picture.backgroundColor = image == nil ? placeholderColor : nil
        let wasWaiting = slot.isWaitingForPicture
        if wasWaiting {
            slot.isWaitingForPicture = false
            slot.wait?.cancel()
            slot.picture.opacity = 1
        }
        if arrives, isShown { arrive(slot) }
        if wasWaiting || arrives { updateRings() }
        CATransaction.commit()
    }

    /// Shows how many typists the stack leaves out, after the last avatar.
    /// Returns its width while it shows.
    private func updateCount(_ hidden: Int, after visibleCount: Int, animated: Bool) -> CGFloat? {
        let wasShowing = count.opacity > 0 && count.animation(forKey: "depart") == nil
        guard hidden > 0 else {
            if wasShowing {
                count.opacity = 0
                if animated { count.add(departure(), forKey: "depart") }
            }
            return nil
        }
        countText.string = "+\(hidden)"
        let textSize = countText.preferredFrameSize()
        let size = CGSize(width: ceil(textSize.width), height: Metrics.avatarDiameter)
        count.bounds = CGRect(origin: .zero, size: size)
        let textHeight = ceil(textSize.height)
        countText.frame = CGRect(x: 0, y: (size.height - textHeight) / 2, width: size.width, height: textHeight)
        let position = CGPoint(
            x: Self.stackX + Self.stackWidth(visibleCount) + Metrics.countGap,
            y: TypingBubble.bodyHeight / 2
        )
        count.removeAnimation(forKey: "depart")
        count.opacity = 1
        if wasShowing {
            move(count, to: position, animated: animated)
        } else {
            count.position = position
            if animated, !reducesMotion { add(arrival(from: -Metrics.avatarDiameter / 4), to: count) }
            if animated { add(fadeIn(), to: count) }
        }
        return size.width
    }

    // MARK: Avatar motion

    private var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static let springDuration: CFTimeInterval = 0.35
    private static let springBounce: CGFloat = 0.25

    static func spring(_ keyPath: String) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: springDuration, bounce: springBounce)
        spring.keyPath = keyPath
        spring.duration = spring.settlingDuration
        return spring
    }

    private var animationSerial = 0

    /// Starts the animation now, under a key of its own so it never replaces
    /// one in flight. An explicit begin time lets ghosts copy it in step.
    private func add(_ animation: CAAnimation, to layer: CALayer) {
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        animationSerial &+= 1
        layer.add(animation, forKey: "\(animation is CASpringAnimation ? "spring" : "basic")-\(animationSerial)")
    }

    /// Slides on an additive spring: a new target adds to the slide in
    /// flight instead of restarting it, so the layer keeps its velocity.
    private func move(_ layer: CALayer, to position: CGPoint, animated: Bool) {
        let from = layer.position
        layer.position = position
        guard animated, from != position, !reducesMotion else { return }
        let slide = Self.spring("position")
        slide.isAdditive = true
        slide.fromValue = CGPoint(x: from.x - position.x, y: from.y - position.y)
        slide.toValue = CGPoint.zero
        add(slide, to: layer)
    }

    /// A new typist grows in beside the dots, and someone leaving the count
    /// grows in from it; under Reduce Motion they fade in.
    private func arrive(_ slot: AvatarSlot) {
        add(fadeIn(), to: slot.picture)
        guard !reducesMotion else { return }
        let index = order.firstIndex { slots[$0] === slot } ?? 0
        let offset = Metrics.avatarDiameter / 2
        add(arrival(from: index == 0 ? -offset : offset), to: slot.picture)
    }

    private func fadeIn() -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = CGFloat(0)
        fade.toValue = CGFloat(1)
        fade.duration = Self.springDuration
        return fade
    }

    private func arrival(from offset: CGFloat) -> CASpringAnimation {
        let grow = Self.spring("transform")
        var start = CATransform3DMakeTranslation(offset, 0, 0)
        start = CATransform3DScale(start, 0.3, 0.3, 1)
        grow.fromValue = start
        grow.toValue = CATransform3DIdentity
        return grow
    }

    /// A flat scale, which stays affine so every renderer honours it.
    static func scale(_ factor: CGFloat) -> CATransform3D {
        CATransform3DMakeScale(factor, factor, 1)
    }

    private func departure() -> CAAnimation {
        scaleFade(from: 1, to: 0, minimumScale: 0.3, duration: 0.2, timing: CAMediaTimingFunction(name: .easeIn))
    }

    /// Shrinks and fades in place. Its fade and shrink run as separate
    /// animations so the ghosts behind it can copy each.
    private func depart(_ slot: AvatarSlot) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            remove(slot)
            restack()
            updateRings()
            CATransaction.commit()
        }
        let timing = CAMediaTimingFunction(name: .easeIn)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = CGFloat(slot.picture.opacity)
        fade.toValue = CGFloat(0)
        fade.duration = 0.2
        fade.timingFunction = timing
        slot.picture.opacity = 0
        add(fade, to: slot.picture)
        if !reducesMotion {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = CATransform3DIdentity
            shrink.toValue = Self.scale(0.3)
            shrink.duration = 0.2
            shrink.timingFunction = timing
            slot.picture.transform = Self.scale(0.3)
            add(shrink, to: slot.picture)
        }
        CATransaction.commit()
    }

    private func updateColors() {
        bubble.updateColors(for: effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            countText.foregroundColor = NSColor.secondaryLabelColor.cgColor
            let placeholder = UserAvatarPresentation.placeholderColor.cgColor
            for slot in stack where slot.picture.contents == nil {
                slot.picture.backgroundColor = placeholder
            }
        }
        CATransaction.commit()
    }

    private var placeholderColor: CGColor? {
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = UserAvatarPresentation.placeholderColor.cgColor }
        return color
    }
}
