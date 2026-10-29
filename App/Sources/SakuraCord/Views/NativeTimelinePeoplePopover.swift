import AppKit
import SwiftUI

extension NativeTimelineCanvasView {
    /// Poll voters and reaction users share the system popover and dismissal path.
    func presentMessagePeoplePopover<Content: View>(
        relativeTo anchor: CGRect,
        followsTimelineScroll: Bool = false,
        @ViewBuilder content: (NSPopover) -> Content
    ) -> NSPopover? {
        guard let window, !anchor.isNull, !anchor.isEmpty else { return nil }
        // Freeze the anchor independently of later reaction layout changes.
        // Reaction popovers keep that snapshot inside the scrolling document.
        let source = StableReactionPickerSourceView(frame: anchor)
        source.followsScrolling = followsTimelineScroll
        addSubview(source)
        let snapshotAnchor = source.installSnapshotAnchor(in: window)
        if followsTimelineScroll { reactionDetailsPopoverAnchor = snapshotAnchor }
        source.removeFromSuperview()
        let popover = OverlayMotionPopover()
        popover.behavior = .transient
        popover.animates = AppMotionPolicy.animates(.overlays)
        let controller = StablePopoverHostingController(
            rootView: content(popover).onDisappear { snapshotAnchor.removeFromSuperview() },
            dismiss: { [weak popover] in popover?.close() }
        )
        popover.contentViewController = controller
        popover.contentSize = MessagePeoplePopoverLayout.size
        let sourceFrame = window.convertToScreen(snapshotAnchor.convert(snapshotAnchor.bounds, to: nil))
        let placement = StablePopoverPlacementPolicy.placement(
            sourceFrame: sourceFrame,
            visibleFrame: window.screen?.visibleFrame ?? sourceFrame,
            contentSize: popover.contentSize,
            preferredEdge: .maxX
        )
        popover.show(relativeTo: snapshotAnchor.bounds, of: snapshotAnchor, preferredEdge: placement.edge)
        if !popover.isShown { snapshotAnchor.removeFromSuperview() }
        controller.monitorEscapeKey(in: controller.view.window, presentingWindow: window)
        Task { @MainActor [weak self, weak popover, weak controller] in
            await Task.yield()
            guard popover?.isShown == true, let controller else { return }
            controller.monitorEscapeKey(in: controller.view.window, presentingWindow: self?.window)
        }
        return popover
    }
}

/// The voters and reaction users popover, whose open and close animation
/// follows the reader's overlay motion setting at the time it plays.
private final class OverlayMotionPopover: NSPopover {
    override func close() {
        animates = animates && AppMotionPolicy.animates(.overlays)
        super.close()
    }

    override func performClose(_ sender: Any?) {
        animates = animates && AppMotionPolicy.animates(.overlays)
        super.performClose(sender)
    }
}
