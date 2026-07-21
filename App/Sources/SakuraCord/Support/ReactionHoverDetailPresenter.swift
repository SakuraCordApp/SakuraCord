import AppKit
import SwiftUI

nonisolated enum ReactionHoverDetailPolicy {
    static let preferredEdge: NSRectEdge = .minY
    static let behavior: NSPopover.Behavior = .applicationDefined
    static let animates = true
    static let ignoresMouseEvents = true
    static let usesNativePopover = true
    static let permitsIndependentPresentations = true
    static let tracksExactPillBounds = true
    static let maximumContentSize = CGSize(width: 400, height: 600)
}

nonisolated struct ReactionHoverAnchorSnapshot: Equatable, Sendable {
    let mouseLocationInScreen: CGPoint
    let mouseLocationInPill: CGPoint

    func pillFrameInScreen(pillSize: CGSize) -> CGRect? {
        stableSnapshot.sourceFrameInScreen(sourceSize: pillSize)
    }

    var stableSnapshot: StablePopoverAnchorSnapshot {
        StablePopoverAnchorSnapshot(
            mouseLocationInScreen: mouseLocationInScreen,
            mouseLocationInSource: mouseLocationInPill
        )
    }
}

@MainActor
@discardableResult
func sizeReactionHoverPopover<Content: View>(
    _ popover: NSPopover,
    hostingController: NSHostingController<Content>
) -> CGSize {
    sizeStablePopover(
        popover,
        hostingController: hostingController,
        maximumContentSize: ReactionHoverDetailPolicy.maximumContentSize
    )
}

extension View {
    func reactionHoverDetail<Content: View>(
        isPresented: Binding<Bool>,
        anchorSnapshot: ReactionHoverAnchorSnapshot? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        overlay {
            StableAnchoredPopoverPresenter(
                isPresented: isPresented.wrappedValue,
                anchorSnapshot: anchorSnapshot?.stableSnapshot,
                configuration: .hover,
                onDismiss: { isPresented.wrappedValue = false },
                content: content
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
