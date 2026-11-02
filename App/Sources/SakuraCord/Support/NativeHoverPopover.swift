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

extension View {
    func nativeHoverHelp(_ title: String) -> some View {
        modifier(NativeHoverHelp(title: title))
    }
}

private struct NativeHoverHelp: ViewModifier {
    let title: String
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onModalHover { isPresented = $0 }
            .nativeHoverPopover(isPresented: $isPresented) { NativeHoverHelpLabel(title: title) }
    }
}

/// A hover label's text, shared by SwiftUI controls and the timeline canvas.
struct NativeHoverHelpLabel: View {
    let title: String

    var body: some View {
        Text(title).font(.interface(.subheadline).weight(.medium))
            .fixedSize().padding(.horizontal, InterfaceScale.metric(12)).padding(.vertical, InterfaceScale.metric(10))
    }
}
