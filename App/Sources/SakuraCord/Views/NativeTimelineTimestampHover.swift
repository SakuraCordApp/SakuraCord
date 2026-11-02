import AppKit
import MessageRendering

extension NativeTimelineCanvasView {
    /// A hovered timestamp shows its full date and time in the native hover
    /// label, as Discord's does, unless a spoiler hides it or a press is
    /// under way.
    func presentTimestampHover(for hover: NativeTimelineMentionHover?) {
        if hover != dismissedTimestampHover { dismissedTimestampHover = nil }
        guard dismissedTimestampHover == nil, NSEvent.pressedMouseButtons == 0,
              let hover, let token = DiscordTimestampToken(rawToken: hover.rawToken),
              visibleTimestampFrame(for: hover) != nil
        else {
            timestampHoverCoordinator.close()
            return
        }
        let anchor = StablePopoverAnchor(sourceView: self) { [weak self] in
            self?.visibleTimestampFrame(for: hover)
        }
        timestampHoverCoordinator.update(
            anchor: anchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: .intrinsicHoverLabel,
            onDismiss: {},
            content: NativeHoverHelpLabel(title: token.date.formatted(date: .complete, time: .shortened))
        )
    }

    /// Any press dismisses the label, as with a native tooltip, until the
    /// pointer hovers another target.
    func dismissTimestampHover() {
        dismissedTimestampHover = hoveredMention
        timestampHoverCoordinator.close()
    }

    override func otherMouseDown(with event: NSEvent) {
        dismissTimestampHover()
        super.otherMouseDown(with: event)
    }

    /// Clearing hover targets directly bypasses their setters, so their
    /// hover popovers close here.
    func closeHoverTooltips() {
        reactionHoverCoordinator.close()
        timestampHoverCoordinator.close()
    }

    /// Layout can move a hovered target without changing it, as when a
    /// relative timestamp's label changes width, so its popover re-anchors.
    func reconcileHoverTooltips() {
        reconcileReactionHover()
        presentTimestampHover(for: hoveredMention)
    }

    /// The hovered timestamp's frame, unless a spoiler conceals it.
    private func visibleTimestampFrame(for hover: NativeTimelineMentionHover) -> CGRect? {
        guard let index = items.firstIndex(where: { $0.identifier == hover.itemIdentifier }),
              let messageID = items[index].messageID,
              let frame = mentionPointerRegions(at: index).first(where: {
                  $0.region == hover.region && $0.characterIndex == hover.characterIndex
              })?.frame,
              textSpoilerPointerHit(at: CGPoint(x: frame.midX, y: frame.midY)) == nil
        else { return nil }
        let hiddenContainers = layouts[index].componentLayouts.flatMap {
            NativeTimelineSpoilerConcealmentPolicy.hiddenContainerFrames(in: $0, messageID: messageID, store: spoilerRevealStore)
        }
        let isConcealed = NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
            frame.offsetBy(dx: 0, dy: -displayedRowOrigin(at: index)), hiddenContainerFrames: hiddenContainers
        )
        return isConcealed ? nil : frame
    }
}
