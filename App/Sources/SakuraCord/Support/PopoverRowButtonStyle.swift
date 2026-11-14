import SwiftUI

/// Matches the profile surface's uniform concentric corners and minimum radius.
struct PopoverRowButtonStyle: ButtonStyle {
    var isSelected = false
    var cornerRadius: CGFloat = InterfaceScale.metric(16)

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isSelected: isSelected, cornerRadius: cornerRadius)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let cornerRadius: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(.primary.opacity(configuration.isPressed ? 0.18 : isHovered || isSelected ? 0.1 : 0), in: ConcentricRectangle(cornerRadius: cornerRadius))
                .contentShape(ConcentricRectangle(cornerRadius: cornerRadius))
                .onModalHover { isHovered = $0 }
        }
    }
}

/// A popover row that opens another popover: its content, then a trailing chevron.
struct PopoverDisclosureRowLabel<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            content
            Spacer(minLength: InterfaceScale.metric(24))
            Image(systemName: "chevron.right")
                .font(.interface(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, InterfaceScale.metric(8))
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .contentShape(Rectangle())
    }
}
