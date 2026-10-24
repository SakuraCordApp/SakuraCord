import AppKit
import QuartzCore
import SakuraCordModels

/// A row as it stood before a timeline update moved the NEW divider, read from
/// what was on screen so a motion can start from that picture.
struct NativeTimelineUnreadDividerSource {
    let identifier: NativeMessageTimelineItem.Identifier
    /// Where the divider sat in the row, when the row had one.
    let frameInRow: CGRect?
    /// The top of the divider's space, relative to the viewport.
    let topInViewport: CGFloat
    /// The row's laid-out height, which the divider's space is part of.
    let height: CGFloat
    /// How much of the divider's space was open on screen, when a motion
    /// was already moving it.
    let startGap: CGFloat?
    /// The top of the row as it was on screen, taken when the divider is about
    /// to go and the row might take an author header with it.
    let topSnapshot: NativeTimelineUnreadDividerSnapshot?
}

/// The top of a row as painted, in pixels.
struct NativeTimelineUnreadDividerSnapshot {
    let image: CGImage
    let scale: CGFloat
    /// How far the row's author avatar reaches, in points from the row's top
    /// and left. The avatar sits beside the message body, so it extends below
    /// the divider and header that go with it.
    var avatarExtent: CGSize?

    var height: CGFloat { CGFloat(image.height) / scale }

    /// The top `points` of the picture, or nil if it is not that tall.
    func top(_ points: CGFloat) -> Self? {
        let pixels = pixelRows(for: points)
        guard pixels > 0, pixels <= image.height,
              let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: pixels))
        else { return nil }
        return Self(image: cropped, scale: scale, avatarExtent: nil)
    }

    /// The avatar below the top `points`, which the row that remains has no
    /// avatar to paint.
    func avatarTail(below points: CGFloat) -> Self? {
        guard let avatarExtent else { return nil }
        let firstRow = pixelRows(for: points)
        let lastRow = min(image.height, pixelRows(for: avatarExtent.height))
        let width = min(image.width, pixelRows(for: avatarExtent.width))
        guard lastRow > firstRow, width > 0,
              let cropped = image.cropping(
                  to: CGRect(x: 0, y: firstRow, width: width, height: lastRow - firstRow)
              )
        else { return nil }
        return Self(image: cropped, scale: scale, avatarExtent: nil)
    }

    private func pixelRows(for points: CGFloat) -> Int {
        Int(ceil(points * scale))
    }
}

/// The NEW divider moving between rows in one timeline update.
struct NativeTimelineUnreadDividerChange {
    let removed: NativeTimelineUnreadDividerSource?
    let added: NativeTimelineUnreadDividerSource?
    let addedMessageID: MessageID?
}

enum NativeTimelineUnreadDividerMotion {
    /// Matches the row disclosure so the fade and the gap land together.
    static let fadeInDuration: CFTimeInterval = NativeTimelineRowDisclosure.duration
    static let fadeOutDuration: CFTimeInterval = 0.2
    /// Reduce Motion keeps a plain, quick fade and nothing else.
    static let reducedMotionDuration: CFTimeInterval = 0.12
    static let opacityKey = "sakuraCordUnreadDividerFade"

    /// Whether the divider may move in an update. It animates only for a
    /// change made under a reader who is already looking at the conversation
    /// settled: a message arriving, or the divider being acknowledged. A
    /// conversation that is still opening (a channel or thread switch, an
    /// account switch, a restored or cached channel, the first load) and a
    /// jump to the unread boundary show the divider and its gap in place.
    static func animates(
        conversationChanged: Bool,
        hadInitialPosition: Bool,
        hadMessages: Bool,
        isJumpingToUnreadBoundary: Bool
    ) -> Bool {
        !conversationChanged && hadInitialPosition && hadMessages && !isJumpingToUnreadBoundary
    }

    static func duration(appearing: Bool, reducesMotion: Bool) -> CFTimeInterval {
        if reducesMotion { return reducedMotionDuration }
        return appearing ? fadeInDuration : fadeOutDuration
    }
}

/// The divider painted once. It never redraws while it fades or while its
/// container resizes.
final class NativeTimelineUnreadDividerArtwork: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NativeTimelineRowPainter.newMessagesSeparator(frame: bounds)
    }
}

/// Clips the divider to the space it may occupy. While the divider's gap opens
/// or closes this container is exactly the gap, so the line can never draw
/// over a message. Fading is a compositor opacity animation on this layer.
final class NativeTimelineUnreadDividerOverlay: NSView {
    let artwork = NativeTimelineUnreadDividerArtwork(frame: .zero)
    /// A closing divider that took its author header with it is shown as the
    /// picture it was, riding the bottom of the open gap.
    private let snapshotView = NSView(frame: .zero)
    private let tailView = NSView(frame: .zero)
    private var snapshotHeight: CGFloat = 0
    private var tailSize: CGSize = .zero

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(artwork)
        for view in [snapshotView, tailView] {
            view.wantsLayer = true
            view.isHidden = true
            addSubview(view)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setArtworkSize(_ size: CGSize) {
        guard artwork.frame.size != size else { return }
        artwork.frame = CGRect(origin: .zero, size: size)
    }

    /// `tail` is the part of the closing author avatar that hangs below the
    /// snapshot, next to the message body that stays.
    func setSnapshot(
        _ snapshot: NativeTimelineUnreadDividerSnapshot?,
        tail: NativeTimelineUnreadDividerSnapshot? = nil
    ) {
        snapshotView.isHidden = snapshot == nil
        artwork.isHidden = snapshot != nil
        snapshotView.layer?.contents = snapshot?.image
        snapshotView.layer?.contentsScale = snapshot?.scale ?? 1
        snapshotHeight = snapshot?.height ?? 0
        let tail = snapshot == nil ? nil : tail
        tailView.isHidden = tail == nil
        tailView.layer?.contents = tail?.image
        tailView.layer?.contentsScale = tail?.scale ?? 1
        tailSize = tail.map { CGSize(width: CGFloat($0.image.width) / $0.scale, height: $0.height) } ?? .zero
        positionSnapshot()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionSnapshot()
    }

    private func positionSnapshot() {
        guard !snapshotView.isHidden else { return }
        let snapshotBottom = bounds.height - tailSize.height
        snapshotView.frame = CGRect(x: 0, y: snapshotBottom - snapshotHeight, width: bounds.width, height: snapshotHeight)
        tailView.frame = CGRect(origin: CGPoint(x: 0, y: snapshotBottom), size: tailSize)
    }
}

/// A divider that is fading in or out above its row.
struct NativeTimelineUnreadDividerFade {
    let overlay: NativeTimelineUnreadDividerOverlay
    /// Where the row was last seen, so finding it again is usually free.
    var rowIndex: Int
    var frameInRow: CGRect
    var isAppearing: Bool
    var finishTask: Task<Void, Never>?
}

extension NativeTimelineCanvasView {
    var unreadDividerReducesMotion: Bool {
        !AppMotionPolicy.animatesUncategorized
    }

    /// The divider's row as laid out now, whether or not it has one.
    func unreadDividerSource(
        forMessageID messageID: MessageID?,
        capturingTop: Bool = false
    ) -> NativeTimelineUnreadDividerSource? {
        guard let messageID,
              let index = items.firstIndex(where: { $0.messageID == messageID }),
              layouts.indices.contains(index)
        else { return nil }
        let identifier = items[index].identifier
        let frame = layouts[index].unreadSeparatorFrame
        let activeGap = unreadDividerGap?.identifier == identifier ? unreadDividerGap : nil
        let top = activeGap == nil ? displayedRowOrigin(at: index) : unreadDividerGapTop
        return NativeTimelineUnreadDividerSource(
            identifier: identifier,
            frameInRow: frame,
            topInViewport: top - viewportMinY,
            height: layouts[index].height,
            startGap: activeGap?.frame.gap,
            topSnapshot: capturingTop && frame != nil && activeGap == nil && unreadDividerFades.isEmpty
                ? unreadDividerTopSnapshot(at: index)
                : nil
        )
    }

    /// The top of a row on screen, tall enough for its divider and the author
    /// header that goes with it, so a row that loses both can close them.
    private func unreadDividerTopSnapshot(at index: Int) -> NativeTimelineUnreadDividerSnapshot? {
        let layout = layouts[index]
        let row = rowFrame(at: index)
        guard let dividerHeight = layout.unreadSeparatorFrame?.height,
              row.intersects(visibleRect)
        else { return nil }
        let item = items[index]
        let tileIndex = layout.height > 256 ? 0 : -1
        let image = cachedBitmap(for: item, width: row.width, tileIndex: tileIndex)
            ?? bitmap(
                for: item, at: index, layout: layout, width: row.width,
                preparedMediaKeys: mediaKeys(for: item, at: index), tileIndex: tileIndex
            )
        var proposed = CGRect(origin: .zero, size: image.size)
        guard image.size.height > 0,
              let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { return nil }
        var snapshot = NativeTimelineUnreadDividerSnapshot(
            image: cgImage, scale: CGFloat(cgImage.height) / image.size.height
        )
        let avatar = layout.avatarFrame
        snapshot.avatarExtent = avatar.map { CGSize(width: $0.maxX, height: $0.maxY) }
        let maximumSpace = NativeTimelineUnreadDividerGapGeometry.maximumSpace(dividerHeight: dividerHeight)
        guard let cropped = snapshot.top(min(snapshot.height, max(maximumSpace, avatar?.maxY ?? 0))) else {
            return nil
        }
        var result = cropped
        result.avatarExtent = snapshot.avatarExtent
        return result
    }

    /// The divider's placement in the row that now has it.
    func unreadDividerPlacement(
        forMessageID messageID: MessageID?
    ) -> (identifier: NativeMessageTimelineItem.Identifier, frameInRow: CGRect)? {
        guard let source = unreadDividerSource(forMessageID: messageID),
              let frame = source.frameInRow
        else { return nil }
        return (source.identifier, frame)
    }

    /// The row with this identifier. `hint` is where it last was.
    func rowIndex(forIdentifier identifier: NativeMessageTimelineItem.Identifier, hint: Int? = nil) -> Int? {
        if let hint, items.indices.contains(hint), items[hint].identifier == identifier { return hint }
        return items.lastIndex { $0.identifier == identifier }
    }

    /// Opens or closes the divider's gap and fades the line inside it. Where
    /// the gap cannot move rows, an arriving divider simply fades in; a
    /// removed one is dropped, since the next message already fills its slot.
    func transitionUnreadDivider(_ change: NativeTimelineUnreadDividerChange) {
        let added = unreadDividerPlacement(forMessageID: change.addedMessageID)
        let removed = change.removed.flatMap { $0.frameInRow == nil ? nil : $0 }
        var opensGap = false
        if let removed, added == nil {
            opensGap = beginUnreadDividerGap(from: removed, appearing: false)
        } else if removed == nil, added != nil, let source = change.added {
            opensGap = beginUnreadDividerGap(from: source, appearing: true)
        }
        if let removed, !opensGap {
            finishUnreadDividerFade(removed.identifier)
        }
        if let added {
            beginUnreadDividerFade(
                identifier: added.identifier,
                frameInRow: added.frameInRow,
                appearing: true,
                usesGap: opensGap
            )
        } else if opensGap, let removed, let frame = removed.frameInRow {
            beginUnreadDividerFade(
                identifier: removed.identifier,
                frameInRow: frame,
                appearing: false,
                usesGap: true
            )
        }
    }

    /// Where the divider's overlay sits: the gap it fills while one is moving,
    /// otherwise its slot in the row.
    private func unreadDividerOverlayFrame(
        identifier: NativeMessageTimelineItem.Identifier,
        index: Int,
        frameInRow: CGRect
    ) -> CGRect {
        if let gap = unreadDividerGap, gap.identifier == identifier {
            let showsSnapshot = gap.snapshot != nil
            // A snapshot is the whole row width, which a header spans.
            let row = rowFrame(at: index)
            return CGRect(
                x: showsSnapshot ? row.minX : frameInRow.minX,
                y: unreadDividerGapTop,
                width: showsSnapshot ? row.width : frameInRow.width,
                height: NativeTimelineUnreadDividerGapGeometry.overlayHeight(
                    gap: gap.frame.gap, spaceHeight: gap.spaceHeight, dividerHeight: gap.dividerHeight,
                    showsSpaceSnapshot: showsSnapshot,
                    snapshotTailHeight: gap.snapshotTail?.height ?? 0
                )
            )
        }
        return frameInRow.offsetBy(dx: 0, dy: displayedRowOrigin(at: index))
    }

    private func beginUnreadDividerFade(
        identifier: NativeMessageTimelineItem.Identifier,
        frameInRow: CGRect,
        appearing: Bool,
        usesGap: Bool
    ) {
        let existing = unreadDividerFades[identifier]
        guard window != nil,
              let index = rowIndex(forIdentifier: identifier, hint: existing?.rowIndex)
        else { return }
        let frame = unreadDividerOverlayFrame(identifier: identifier, index: index, frameInRow: frameInRow)
        // Only a divider the reader can see is worth animating. A stale fade
        // for the same row is settled so the row simply shows its new state.
        guard usesGap || frame.intersects(visibleRect) else {
            if existing != nil { finishUnreadDividerFade(identifier) }
            return
        }
        existing?.finishTask?.cancel()
        let overlay = existing?.overlay ?? {
            let overlay = NativeTimelineUnreadDividerOverlay(frame: frame)
            addSubview(overlay, positioned: .below, relativeTo: mediaViewerHost)
            return overlay
        }()
        overlay.setArtworkSize(frameInRow.size)
        if let gap = unreadDividerGap, gap.identifier == identifier, !appearing {
            overlay.setSnapshot(gap.snapshot, tail: gap.snapshotTail)
        } else {
            overlay.setSnapshot(nil)
        }
        // A rapid reversal continues from the opacity on screen rather than
        // snapping to either end.
        let startOpacity: Float = if existing != nil {
            overlay.layer?.presentation()?.opacity ?? Float(overlay.alphaValue)
        } else {
            appearing ? 0 : 1
        }
        let targetOpacity: Float = appearing ? 1 : 0
        let fullDuration = NativeTimelineUnreadDividerMotion.duration(
            appearing: appearing,
            reducesMotion: unreadDividerReducesMotion
        )
        let duration = max(0.05, fullDuration * Double(abs(targetOpacity - startOpacity)))
        unreadDividerFades[identifier] = NativeTimelineUnreadDividerFade(
            overlay: overlay,
            rowIndex: index,
            frameInRow: frameInRow,
            isAppearing: appearing,
            // A divider moving with a gap stays on its overlay until the gap
            // settles, so the row never repaints it at another height.
            finishTask: usesGap ? nil : Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(duration + 0.03))
                } catch {
                    return
                }
                self?.finishUnreadDividerFade(identifier)
            }
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = frame
        overlay.alphaValue = CGFloat(targetOpacity)
        if let layer = overlay.layer {
            layer.removeAnimation(forKey: NativeTimelineUnreadDividerMotion.opacityKey)
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = startOpacity
            animation.toValue = targetOpacity
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: appearing ? .easeOut : .easeIn)
            layer.add(animation, forKey: NativeTimelineUnreadDividerMotion.opacityKey)
        }
        // While it fades in, the row's own bitmap withholds the divider.
        if appearing {
            setNeedsDisplay(rowFrame(at: index))
        }
        CATransaction.commit()
    }

    /// Ends one fade and hands the divider back to the row's own painting.
    func finishUnreadDividerFade(_ identifier: NativeMessageTimelineItem.Identifier) {
        guard let fade = unreadDividerFades.removeValue(forKey: identifier) else { return }
        fade.finishTask?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.overlay.removeFromSuperview()
        if fade.isAppearing, let index = rowIndex(forIdentifier: identifier, hint: fade.rowIndex) {
            setNeedsDisplay(rowFrame(at: index))
            displayIfNeeded()
        }
        CATransaction.commit()
    }

    func finishUnreadDividerFades() {
        finishUnreadDividerGap()
        for identifier in Array(unreadDividerFades.keys) {
            finishUnreadDividerFade(identifier)
        }
    }

    /// Keeps a running fade attached to its row through scrolling, relayout
    /// and row changes.
    func positionUnreadDividerFades() {
        for (identifier, fade) in unreadDividerFades {
            guard let index = rowIndex(forIdentifier: identifier, hint: fade.rowIndex),
                  layouts.indices.contains(index)
            else {
                finishUnreadDividerFade(identifier)
                continue
            }
            unreadDividerFades[identifier]?.rowIndex = index
            let frameInRow = layouts[index].unreadSeparatorFrame ?? fade.frameInRow
            let frame = unreadDividerOverlayFrame(identifier: identifier, index: index, frameInRow: frameInRow)
            fade.overlay.setArtworkSize(frameInRow.size)
            if fade.overlay.frame != frame {
                fade.overlay.frame = frame
            }
        }
    }

    /// Erases the divider the row just painted while its overlay fades in.
    func clearHeldUnreadDivider(
        for item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout,
        rowFrame: CGRect
    ) {
        guard unreadDividerFades[item.identifier]?.isAppearing == true,
              let frame = layout.unreadSeparatorFrame,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.fill(frame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY))
        context.restoreGState()
    }
}

extension NativeMessageTimelineCoordinator {
    /// A jump to the unread boundary is on its way: the model's request, which
    /// the view clears once it has turned it into a scroll request, or that
    /// scroll request until the timeline has applied it.
    private func isJumpingToUnreadBoundary(in newParent: NativeMessageTimelineView) -> Bool {
        let navigation = newParent.model.messageNavigationRequest
        if navigation?.isUnreadBoundary == true, navigation?.channelID == newParent.conversation.id {
            return true
        }
        guard let request = newParent.scrollRequest,
              request.id != lastScrollRequestID,
              case let .message(_, anchor) = request.target
        else { return false }
        return anchor == TimelineInitialPositionPolicy.unreadViewportAnchor
    }

    /// Reads the divider an update is about to move while rows still show it,
    /// so the motion starts from that picture. A running gap is settled first
    /// when the update could reflow rows under it. Nil when the divider does
    /// not change or may not animate, in which case the rows simply show it.
    func unreadDividerChange(
        to newParent: NativeMessageTimelineView,
        canvas: NativeTimelineCanvasView
    ) -> NativeTimelineUnreadDividerChange? {
        let conversationChanged = newParent.conversation != parent.conversation
        // With all animations off the divider changes in place; Reduce
        // Motion alone keeps its short fade.
        guard !AppMotionPolicy.settings.disablesAllAnimations, NativeTimelineUnreadDividerMotion.animates(
            conversationChanged: conversationChanged,
            // Read before this update can establish the position or bring in
            // the first rows, so a divider that arrives with either stays
            // still. An empty timeline can hold a position, for instance
            // after a failed first load that is then retried.
            hadInitialPosition: initialPositionConversation == parent.conversation,
            hadMessages: items.contains { $0.messageID != nil },
            isJumpingToUnreadBoundary: isJumpingToUnreadBoundary(in: newParent)
        ) else {
            // Includes a motion already running when the reader jumps.
            canvas.finishUnreadDividerFades()
            return nil
        }
        let previous = parent.unreadMessageID
        let changes = previous != newParent.unreadMessageID
        let reflowsRows = newParent.rowsRevision != rowsRevision
            || newParent.presentationRevision != presentationRevision
            || conversationChanged
        guard changes else {
            if reflowsRows { canvas.finishUnreadDividerGap() }
            return nil
        }
        let change = NativeTimelineUnreadDividerChange(
            removed: canvas.unreadDividerSource(forMessageID: previous, capturingTop: true),
            added: canvas.unreadDividerSource(forMessageID: newParent.unreadMessageID),
            addedMessageID: newParent.unreadMessageID
        )
        // A divider reversing on its own row keeps its overlay and carries on
        // from the opacity on screen; the transition drops it if no gap follows.
        let reversingRow = change.removed?.frameInRow == nil ? change.added : change.removed
        canvas.finishUnreadDividerGap(preservingFadeFor: reversingRow?.identifier)
        return change
    }
}
