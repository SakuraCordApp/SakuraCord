import AppKit
import SwiftUI

@MainActor
final class NativeTimelineActionCapsuleHost: NSHostingView<AnyView> {
    /// The visible pill in the superview's coordinates. Points outside it
    /// fall through to the timeline.
    var interactiveFrame: CGRect?

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let interactiveFrame, !interactiveFrame.contains(point) { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class NativeTimelineEditingHost: NSHostingView<AnyView> {
    var fittingHeightDidChange: ((CGFloat) -> Void)?

    var lastReportedFittingHeight: CGFloat = 0
    var isMeasuringFittingHeight = false

    override func layout() {
        super.layout()
        guard !isMeasuringFittingHeight else { return }
        isMeasuringFittingHeight = true
        let height = max(1, ceil(fittingSize.height))
        isMeasuringFittingHeight = false
        guard abs(height - lastReportedFittingHeight) > 0.5 else {
            return
        }
        lastReportedFittingHeight = height
        DispatchQueue.main.async { [weak self] in
            self?.fittingHeightDidChange?(height)
        }
    }
}
