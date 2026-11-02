import SwiftUI

/// The capsule Liquid Glass action used in compact window-modal footers. With the
/// footer's 12-point inset, its 40-point capsule stays concentric with a 32-point panel.
struct ModalGlassButton: View {
    let symbol: String
    let label: String
    var primary = false
    /// Tints a primary button red for actions that need extra care.
    var destructive = false
    /// Replaces the label with the interaction dots, keeping the button's size.
    var isLoading = false
    /// Stretches the button across its container, for stacked footers.
    var fillsWidth = false
    /// Unscaled height; compact popovers pair a smaller capsule with less inset.
    var height: CGFloat = 40
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    /// A disabled button loses its tint and dims; a loading one keeps both.
    private var looksEnabled: Bool { isEnabled || isLoading }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.interface(.body).weight(.semibold))
                .lineLimit(1)
                .opacity(isLoading ? 0 : looksEnabled ? 1 : 0.4)
                .overlay { if isLoading { InteractionLoadingDotsView(tone: primary ? .onFill : .content) } }
                .padding(.horizontal, InterfaceScale.metric(16))
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: InterfaceScale.metric(height))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            primary && looksEnabled
                ? .regular.tint(destructive ? .red : SakuraCordAccentColor.color).interactive()
                : .regular.interactive(),
            in: Capsule()
        )
        .help(label)
        .accessibilityLabel(label)
    }
}
