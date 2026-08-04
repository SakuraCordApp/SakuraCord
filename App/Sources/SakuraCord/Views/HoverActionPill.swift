import SwiftUI

struct HoverActionPill<Content: View>: View {
    var glass: Glass = .regular
    var spacing: CGFloat = 1
    var padding: CGFloat = 4
    @ViewBuilder let content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: spacing) {
                content()
            }
            .padding(padding)
            .glassEffect(glass, in: Capsule())
        }
    }
}

struct HoverActionButton: View {
    let systemImage: String
    let help: String
    var role: ButtonRole?
    var isSelected: Bool?
    var diameter: CGFloat = 28
    var iconFont: Font = .callout.weight(.medium)
    let action: () -> Void

    var body: some View {
        let button = Button(role: role, action: action) {
            HoverActionControlLabel(
                role: role,
                isSelected: isSelected,
                diameter: diameter
            ) {
                Image(systemName: systemImage)
                    .symbolVariant(.none)
                    .font(iconFont)
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        if let isSelected {
            button.accessibilityValue(isSelected ? "On" : "Off")
        } else {
            button
        }
    }
}

struct HoverActionControlLabel<Content: View>: View {
    var role: ButtonRole?
    var isSelected: Bool?
    var diameter: CGFloat = 28
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        content()
            .foregroundStyle(iconColor)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .background(backgroundColor, in: Circle())
            .contentShape(Circle())
            .onHover { isHovering = $0 }
    }

    private var iconColor: Color {
        if role == .destructive, isHovering { return .red }
        if isSelected == true { return .accentColor }
        return .primary
    }

    private var backgroundColor: Color {
        if isHovering {
            return role == .destructive ? .red.opacity(0.18) : .primary.opacity(0.14)
        }
        return isSelected == true ? .accentColor.opacity(0.16) : .clear
    }
}
