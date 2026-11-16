import AppKit
import QuartzCore
import SakuraCordModels

/// The interactive part of a media spoiler cover. The row draws the cover
/// itself, so the cover is never missing while this view comes and goes;
/// this view adds hover, keyboard focus and activation.
@MainActor
final class NativeTimelineSpoilerOverlayHost: NSView {
    let cornerRadius: CGFloat
    /// Reveals the spoiler; false when the timeline refused the press, so the cover stays usable.
    let revealAction: () -> Bool
    /// Tints the cover while the pointer is over it, as a text spoiler's
    /// fill tints.
    let tintView = NSView()
    /// Darkens the row's pill while the pointer is over the cover.
    let pillView = NSView()
    let pillLabel = NSTextField(labelWithString: "SPOILER")
    var trackingArea: NSTrackingArea?
    var isHovered = false {
        didSet { updateHover(animated: true) }
    }
    var isPressed = false
    var didActivate = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        frame: CGRect,
        cornerRadius: CGFloat,
        reveal: @escaping () -> Bool
    ) {
        self.cornerRadius = cornerRadius
        revealAction = reveal
        super.init(frame: frame)
        wantsLayer = true
        tintView.wantsLayer = true
        tintView.layer?.cornerRadius = cornerRadius
        tintView.layer?.cornerCurve = .continuous
        tintView.alphaValue = 0
        tintView.setAccessibilityElement(false)
        addSubview(tintView)
        pillView.wantsLayer = true
        pillView.layer?.masksToBounds = true
        pillView.layer?.backgroundColor =
            SpoilerAppearance.hoveredPillOverlayColor.cgColor
        pillView.setAccessibilityElement(false)
        addSubview(pillView)
        pillLabel.alignment = .center
        pillLabel.lineBreakMode = .byClipping
        pillLabel.setAccessibilityElement(false)
        pillView.addSubview(pillLabel)
        pillView.alphaValue = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Reveal spoiler")
        setAccessibilityHelp("Reveals the spoiler without opening it")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        tintView.frame = bounds
        updateHover(animated: false)
        // The same pill the row draws under this view.
        guard let pill = NativeTimelineSpoilerCover.pill(in: bounds, isHovered: true) else { return }
        pillLabel.attributedStringValue = pill.label
        pillView.frame = pill.frame
        pillView.layer?.cornerRadius = pill.frame.height / 2
        pillLabel.frame = SpoilerAppearance.labelFrame(
            in: pillView.bounds,
            measuredLabelHeight: pill.label.size().height
        )
    }

    /// Eases the hover in or out on the timeline's hover curve.
    private func updateHover(animated: Bool) {
        // A cover too small for the row to draw a pill on has none to darken.
        let hasPill = SpoilerAppearance.pillScale(forTileWidth: bounds.width) != nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && AppMotionPolicy.animatesUncategorized
                ? NativeTimelineComponentButtonVisualState.hoverAnimationDuration : 0
            context.timingFunction = NativeTimelineComponentButtonVisualState.hoverTimingFunction
            tintView.animator().alphaValue = isHovered ? 1 : 0
            pillView.animator().alphaValue = isHovered && hasPill ? 1 : 0
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTintColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTintColor()
    }

    private func updateTintColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tintView.layer?.backgroundColor = SpoilerAppearance.mediaHoverTintColor.cgColor
        }
    }

    override func resetCursorRects() {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates.
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        window?.makeFirstResponder(self)
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        let activates =
            isPressed
            && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if activates {
            activate()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func otherMouseDown(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        if SpoilerAppearance.isActivationKey(event) {
            activate()
        } else {
            super.keyDown(with: event)
        }
    }

    nonisolated override func accessibilityActionNames()
        -> [NSAccessibility.Action]
    {
        [.press]
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            activate()
            return didActivate
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.sakuraCordAccentColor.setStroke()
            let focus = NSBezierPath(
                concentricRoundedRect: bounds.insetBy(dx: InterfaceScale.metric(2), dy: InterfaceScale.metric(2)),
                cornerRadius: max(1, cornerRadius - 2)
            )
            focus.lineWidth = 2
            focus.stroke()
        }
    }

#if DEBUG
    var hasPersistentPillForTesting: Bool {
        pillView.superview === self
            && pillLabel.superview === pillView
    }
#endif

    func activate() {
        guard !didActivate else { return }
        didActivate = revealAction()
    }
}

extension NativeTimelineCanvasView {
    struct DesiredSpoilerOverlay {
        let key: NativeTimelineComponentRevealKey
        let frame: CGRect
        let cornerRadius: CGFloat
    }

    func reconcileSpoilerOverlays() {
        let desired = desiredSpoilerOverlays()
        applySpoilerOverlays(desired)
        // Revealing a file card uncovers its upload ring.
        reconcileUploadRings()
    }

    private func desiredSpoilerOverlays() -> [DesiredSpoilerOverlay] {
        var desired: [DesiredSpoilerOverlay] = []
        desired.reserveCapacity(16)
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            removeSpoilerOverlays()
            return []
        }

        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            guard layouts.indices.contains(index),
                  case let .message(row, _, _) = items[index],
                  !hidesRowForSendTransition(items[index].identifier)
            else {
                index += 1
                continue
            }
            let message = row.message
            let rowOrigin = displayedRowOrigin(at: index)
            appendAttachmentSpoilerOverlays(
                for: message,
                layout: layouts[index],
                rowOrigin: rowOrigin,
                into: &desired
            )
            let concealedEmbeds = NativeTimelineSpoilerConcealmentPolicy.concealedEmbeds(
                in: message, store: spoilerRevealStore
            )
            var coveredKeys = Set<NativeTimelineComponentRevealKey>()
            // A multi-image post's card region spans its grid, so its one
            // overlay covers every image.
            for region in layouts[index].embedRegions {
                guard let key = concealedEmbeds[region.embedID], coveredKeys.insert(key).inserted else { continue }
                appendDesiredSpoilerOverlay(
                    key,
                    frame: region.frame,
                    cornerRadius: region.cornerRadius,
                    rowOrigin: rowOrigin,
                    into: &desired
                )
            }
            for component in layouts[index].componentLayouts {
                appendComponentSpoilerOverlays(
                    for: component,
                    messageID: message.id,
                    rowOrigin: rowOrigin,
                    into: &desired
                )
            }
            index += 1
        }
        return desired
    }

    private func appendAttachmentSpoilerOverlays(
        for message: Message,
        layout: NativeTimelineRowLayout,
        rowOrigin: CGFloat,
        into desired: inout [DesiredSpoilerOverlay]
    ) {
        for region in layout.attachmentRegions where region.attachment.isSpoiler {
            appendDesiredSpoilerOverlay(
                .attachment(messageID: message.id, attachmentID: region.attachment.id),
                frame: region.frame,
                cornerRadius: layout.cornerRadius(of: region),
                rowOrigin: rowOrigin,
                into: &desired
            )
        }
    }

    private func appendComponentSpoilerOverlays(
        for component: NativeTimelineComponentLayout,
        messageID: MessageID,
        rowOrigin: CGFloat,
        into desired: inout [DesiredSpoilerOverlay]
    ) {
        let hiddenContainerFrames =
            NativeTimelineSpoilerConcealmentPolicy.hiddenContainerFrames(
                in: component,
                messageID: messageID,
                store: spoilerRevealStore
            )
        appendContainerSpoilerOverlays(
            component,
            messageID: messageID,
            rowOrigin: rowOrigin,
            hiddenContainerFrames: hiddenContainerFrames,
            into: &desired
        )
        appendComponentMediaSpoilerOverlays(
            component,
            messageID: messageID,
            rowOrigin: rowOrigin,
            hiddenContainerFrames: hiddenContainerFrames,
            into: &desired
        )
    }

    private func appendContainerSpoilerOverlays(
        _ component: NativeTimelineComponentLayout,
        messageID: MessageID,
        rowOrigin: CGFloat,
        hiddenContainerFrames: [CGRect],
        into desired: inout [DesiredSpoilerOverlay]
    ) {
        for container in component.containers
        where hiddenContainerFrames.contains(container.frame) {
            appendDesiredSpoilerOverlay(
                NativeTimelineComponentRevealKey(
                    messageID: messageID,
                    componentID: container.componentID
                ),
                frame: container.frame,
                cornerRadius: container.cornerRadius,
                rowOrigin: rowOrigin,
                into: &desired
            )
        }
    }

    private func appendComponentMediaSpoilerOverlays(
        _ component: NativeTimelineComponentLayout,
        messageID: MessageID,
        rowOrigin: CGFloat,
        hiddenContainerFrames: [CGRect],
        into desired: inout [DesiredSpoilerOverlay]
    ) {
        for region in component.mediaRegions where shouldOverlaySpoiler(
            region.isSpoiler,
            frame: region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            let cornerRadius = switch region.kind {
            case let .image(image): image.cornerRadius
            case .media: InterfaceScale.metric(8)
            case let .file(file): file.card(frame: region.frame).cornerRadius
            }
            appendDesiredSpoilerOverlay(
                NativeTimelineComponentRevealKey(
                    messageID: messageID,
                    componentID: region.componentID
                ),
                frame: region.frame,
                cornerRadius: cornerRadius,
                rowOrigin: rowOrigin,
                into: &desired
            )
        }
    }

    private func shouldOverlaySpoiler(
        _ isSpoiler: Bool,
        frame: CGRect,
        hiddenContainerFrames: [CGRect]
    ) -> Bool {
        isSpoiler && !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
            frame,
            hiddenContainerFrames: hiddenContainerFrames
        )
    }

    private func appendDesiredSpoilerOverlay(
        _ key: NativeTimelineComponentRevealKey,
        frame: CGRect,
        cornerRadius: CGFloat,
        rowOrigin: CGFloat,
        into desired: inout [DesiredSpoilerOverlay]
    ) {
        guard !spoilerRevealStore.isMediaRevealed(key) else { return }
        desired.append(DesiredSpoilerOverlay(
            key: key,
            frame: frame.offsetBy(dx: 0, dy: rowOrigin),
            cornerRadius: cornerRadius
        ))
    }

    private func applySpoilerOverlays(_ desired: [DesiredSpoilerOverlay]) {
        let desiredKeys = Set(desired.map(\.key))
        for key in Array(spoilerOverlays.keys)
        where !desiredKeys.contains(key) {
            spoilerOverlays.removeValue(forKey: key)?.removeFromSuperview()
        }
        for item in desired {
            let overlay: NativeTimelineSpoilerOverlayHost
            if let existing = spoilerOverlays[item.key],
               existing.cornerRadius == item.cornerRadius
            {
                overlay = existing
            } else {
                spoilerOverlays.removeValue(forKey: item.key)?
                    .removeFromSuperview()
                overlay = NativeTimelineSpoilerOverlayHost(
                    frame: item.frame,
                    cornerRadius: item.cornerRadius
                ) { [weak self] in
                    guard let self, !glideBlocksPointer else { return false }
                    reveal(item.key)
                    return true
                }
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                spoilerOverlays[item.key] = overlay
            }
            overlay.frame = item.frame
        }
    }

    func positionSpoilerOverlays() {
        guard !spoilerOverlays.isEmpty else { return }
        reconcileSpoilerOverlays()
    }

    func removeSpoilerOverlays() {
        for overlay in spoilerOverlays.values {
            overlay.removeFromSuperview()
        }
        spoilerOverlays.removeAll()
    }
}

#if DEBUG
    extension NativeTimelineCanvasView {
        var spoilerOverlayFramesForTesting:
            [NativeTimelineComponentRevealKey: CGRect]
        {
            spoilerOverlays.mapValues(\.frame)
        }

        var spoilerOverlayPillKeysForTesting:
            Set<NativeTimelineComponentRevealKey>
        {
            Set(
                spoilerOverlays.compactMap { key, overlay in
                    overlay.hasPersistentPillForTesting ? key : nil
                }
            )
        }
    }
#endif
