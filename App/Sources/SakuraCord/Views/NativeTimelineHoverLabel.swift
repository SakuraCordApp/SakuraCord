import AppKit
import MessageRendering
import SakuraCordModels

/// What the native hover label describes: a timestamp's full date, or the
/// @silent badge.
enum NativeTimelineHoverLabelTarget: Equatable {
    case timestamp(NativeTimelineMentionHover)
    case silentBadge(MessageID)
}

extension NativeTimelineCanvasView {
    /// A hovered timestamp shows its full date and time, and a hovered
    /// @silent badge Discord's tooltip, in the native hover label, unless a
    /// spoiler hides the timestamp or a press is under way.
    func presentHoverLabel() {
        let target = hoverLabelTarget
        if target != dismissedHoverLabel { dismissedHoverLabel = nil }
        guard dismissedHoverLabel == nil, NSEvent.pressedMouseButtons == 0,
              let target, let title = hoverLabelTitle(for: target), hoverLabelFrame(for: target) != nil
        else {
            hoverLabelCoordinator.close()
            return
        }
        let anchor = StablePopoverAnchor(sourceView: self) { [weak self] in
            self?.hoverLabelFrame(for: target)
        }
        hoverLabelCoordinator.update(
            anchor: anchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: .intrinsicHoverLabel,
            onDismiss: {},
            content: NativeHoverHelpLabel(title: title)
        )
    }

    /// Any press dismisses the label, as with a native tooltip, until the
    /// pointer hovers another target.
    func dismissHoverLabel() {
        dismissedHoverLabel = hoverLabelTarget
        hoverLabelCoordinator.close()
    }

    override func otherMouseDown(with event: NSEvent) {
        dismissHoverLabel()
        super.otherMouseDown(with: event)
    }

    /// Clearing hover targets directly bypasses their setters, so their
    /// hover popovers close here.
    func closeHoverTooltips() {
        reactionHoverCoordinator.close()
        hoverLabelCoordinator.close()
    }

    /// Layout can move a hovered target without changing it, as when a
    /// relative timestamp's label changes width, so its popover re-anchors.
    func reconcileHoverTooltips() {
        reconcileReactionHover()
        presentHoverLabel()
    }

    func setHoveredSilentBadgeMessageID(_ value: MessageID?) {
        guard hoveredSilentBadgeMessageID != value else { return }
        hoveredSilentBadgeMessageID = value
        presentHoverLabel()
    }

    func silentBadgePointerHit(at point: CGPoint) -> MessageID? {
        guard let index = rowIndex(at: point.y), layouts.indices.contains(index),
              let frame = layouts[index].silentBadgeFrame,
              frame.contains(CGPoint(x: point.x, y: point.y - displayedRowOrigin(at: index)))
        else { return nil }
        return items[index].messageID
    }

    private var hoverLabelTarget: NativeTimelineHoverLabelTarget? {
        if let messageID = hoveredSilentBadgeMessageID { return .silentBadge(messageID) }
        return hoveredMention.map(NativeTimelineHoverLabelTarget.timestamp)
    }

    private func hoverLabelTitle(for target: NativeTimelineHoverLabelTarget) -> String? {
        switch target {
        case let .timestamp(hover):
            DiscordTimestampToken(rawToken: hover.rawToken)?.date.formatted(date: .complete, time: .shortened)
        case .silentBadge:
            NativeTimelineSilentBadge.help
        }
    }

    private func hoverLabelFrame(for target: NativeTimelineHoverLabelTarget) -> CGRect? {
        switch target {
        case let .timestamp(hover):
            visibleTimestampFrame(for: hover)
        case let .silentBadge(messageID):
            visibleMessageRowIndex(for: messageID).flatMap { index in
                layouts[index].silentBadgeFrame?.offsetBy(dx: 0, dy: displayedRowOrigin(at: index))
            }
        }
    }

    /// The hovered timestamp's frame, unless a spoiler conceals it.
    private func visibleTimestampFrame(for hover: NativeTimelineMentionHover) -> CGRect? {
        guard let index = items.firstIndex(where: { $0.identifier == hover.itemIdentifier }),
              let frame = mentionPointerRegions(at: index).first(where: {
                  $0.region == hover.region && $0.characterIndex == hover.characterIndex
              })?.frame,
              textSpoilerPointerHit(at: CGPoint(x: frame.midX, y: frame.midY)) == nil
        else { return nil }
        // A channel topic has no components to hide it.
        guard let messageID = items[index].messageID else { return frame }
        let hiddenContainers = layouts[index].componentLayouts.flatMap {
            NativeTimelineSpoilerConcealmentPolicy.hiddenContainerFrames(in: $0, messageID: messageID, store: spoilerRevealStore)
        }
        let isConcealed = NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
            frame.offsetBy(dx: 0, dy: -displayedRowOrigin(at: index)), hiddenContainerFrames: hiddenContainers
        )
        return isConcealed ? nil : frame
    }
}
