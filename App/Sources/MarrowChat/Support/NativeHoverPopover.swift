import AppKit
import SwiftUI

nonisolated enum NativeHoverPopoverPolicy {
    static let preferredEdge: NSRectEdge = .minY
    static let ignoresMouseEvents = true
    static let usesIntrinsicContentSize = true
}

extension View {
    /// Tracks the exact hovered control, chooses a fitting screen edge before
    /// presentation, and keeps the non-interactive popover out of pointer hit testing.
    func nativeHoverPopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) -> some View {
        overlay {
            StableAnchoredPopoverPresenter(
                isPresented: isPresented.wrappedValue,
                configuration: .intrinsicHoverLabel,
                onDismiss: { isPresented.wrappedValue = false },
                content: content
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
