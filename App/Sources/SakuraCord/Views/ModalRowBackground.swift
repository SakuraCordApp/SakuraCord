import SwiftUI

/// A tinted row inside a 32-point window modal. Inset 8 points from the
/// panel, its 24-point corners and 32-point controls stay concentric with it.
struct ModalRowBackground: ViewModifier {
    var isHighlighted = false
    /// Focuses the row's field from a click anywhere in the row, padding
    /// included, rather than only on the field's own text.
    var focus: (() -> Void)?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: InterfaceScale.metric(24), style: .continuous)
        let row = content
            .padding(InterfaceScale.metric(8))
            .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(48), alignment: .leading)
            .background(.quaternary.opacity(isHighlighted ? 0.9 : 0.5), in: shape)
        if let focus {
            row.contentShape(shape).onTapGesture(perform: focus)
        } else {
            row
        }
    }
}
