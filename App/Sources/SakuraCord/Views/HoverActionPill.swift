import SwiftUI

nonisolated enum HoverActionPillMetrics {
    static var controlDiameter: CGFloat { InterfaceScale.metric(28) }
    static var spacing: CGFloat { InterfaceScale.metric(1) }
    static var padding: CGFloat { InterfaceScale.metric(4) }

    static var dividerWidth: CGFloat { 1 + InterfaceScale.metric(3) * 2 }

    static func size(controlCount: Int, dividerCount: Int = 0) -> CGSize {
        let count = max(1, controlCount)
        let diameter = controlDiameter
        return CGSize(
            width:
                padding * 2
                + diameter * CGFloat(count)
                + spacing * CGFloat(count - 1)
                + (dividerWidth + spacing) * CGFloat(dividerCount),
            height: padding * 2 + diameter
        )
    }
}

struct HoverActionPillDivider: View {
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.16))
            .frame(width: 1, height: HoverActionPillMetrics.controlDiameter * 0.6)
            .frame(width: HoverActionPillMetrics.dividerWidth)
            .accessibilityHidden(true)
    }
}

struct HoverActionPill<Content: View>: View {
    var glass: Glass = .regular
    var spacing: CGFloat = HoverActionPillMetrics.spacing
    var padding: CGFloat = HoverActionPillMetrics.padding
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

struct HoverCloseButton: View {
    let help: LocalizedStringResource
    let accessibilityIdentifier: String
    var diameter: CGFloat = InterfaceScale.metric(36)
    var iconSize: CGFloat = 15
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.interfaceSystem(size: iconSize, weight: .medium))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .background {
                    Circle()
                        .fill(.primary.opacity(isHovered ? 0.09 : 0.001))
                }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onModalHover { isHovered = $0 }
        .help(help)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct HoverActionButton: View {
    let systemImage: String
    let help: String
    var role: ButtonRole?
    var isSelected: Bool?
    var diameter: CGFloat?
    var iconFont: Font = .interface(.callout).weight(.medium)
    var onHoverChanged: ((Bool) -> Void)?
    let action: () -> Void

    var body: some View {
        let button = Button(role: role, action: action) {
            HoverActionControlLabel(
                role: role,
                isSelected: isSelected,
                diameter: diameter ?? HoverActionPillMetrics.controlDiameter,
                onHoverChanged: onHoverChanged
            ) {
                SakuraCordSystemSymbol.swiftUIImage(named: systemImage)
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
    var diameter: CGFloat = InterfaceScale.metric(28)
    var onHoverChanged: ((Bool) -> Void)?
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        content()
            .foregroundStyle(iconColor)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .background(backgroundColor, in: Circle())
            .contentShape(Circle())
            .onModalHover {
                isHovering = $0
                onHoverChanged?($0)
            }
    }

    private var iconColor: Color {
        if role == .destructive, isHovering { return .red }
        if isSelected == true { return SakuraCordAccentColor.color }
        return .primary
    }

    private var backgroundColor: Color {
        if isHovering {
            return role == .destructive ? .red.opacity(0.18) : .primary.opacity(0.14)
        }
        return isSelected == true
            ? SakuraCordAccentColor.color.opacity(0.16)
            : .clear
    }
}
