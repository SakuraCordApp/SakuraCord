import SwiftUI

/// A rounded, hover- and focus-aware surface for plain text fields in modals.
struct ModalInputSurface: ViewModifier {
    let isFocused: Bool
    let focus: () -> Void
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                ConcentricRectangle(cornerRadius: ChatChromeMetrics.modalFieldCornerRadius)
                    .fill(.background.opacity(0.72))
                    .contentShape(ConcentricRectangle(cornerRadius: ChatChromeMetrics.modalFieldCornerRadius))
                    .onTapGesture(perform: focus)
            }
            .overlay {
                ConcentricRectangle(cornerRadius: ChatChromeMetrics.modalFieldCornerRadius)
                    .stroke(.primary.opacity(isFocused ? 0.3 : isHovered ? 0.2 : 0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onModalHover { isHovered = $0 }
    }
}
