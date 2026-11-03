import SakuraCordModels
import SwiftUI

/// Rows sit 8 points inside the 32-point panel. Their 24-point corners stay
/// concentric with it, as the 32-point avatar and check do 8 points inside them.
struct ForwardDestinationRow: View {
    let destination: ForwardDestination
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(10)) {
                ForwardDestinationAvatar(destination: destination)
                VStack(alignment: .leading, spacing: InterfaceScale.metric(1)) {
                    Text(destination.title)
                        .font(.interface(.body).weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    let detail = destination.unavailableReason ?? destination.detail
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.interface(.caption))
                            .foregroundStyle(destination.unavailableReason == nil
                                ? Color.secondary : Color.red)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.interfaceSystem(size: 20))
                    .foregroundStyle(isSelected ? SakuraCordAccentColor.color : Color.secondary.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: ForwardPickerLayoutMetrics.iconSize, height: ForwardPickerLayoutMetrics.iconSize)
                    .accessibilityHidden(true)
            }
            .padding(InterfaceScale.metric(8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PopoverRowButtonStyle(isSelected: isSelected, cornerRadius: InterfaceScale.metric(24)))
        .disabled(destination.unavailableReason != nil)
        .opacity(destination.unavailableReason == nil ? 1 : 0.62)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(destination.id.accessibilityIdentifier)
    }

    private var accessibilityLabel: String {
        let detail = destination.unavailableReason ?? destination.detail
        return detail.isEmpty ? destination.title : "\(destination.title), \(detail)"
    }
}

private struct ForwardDestinationAvatar: View {
    let destination: ForwardDestination

    var body: some View {
        switch destination.kind {
        case .channel(let channel) where channel.guildID != nil:
            guildIcon(symbol: channel.kind == .voice ? "speaker.wave.2.fill" : "number")
        case .thread(_, let parent):
            guildIcon(symbol: parent?.kind == .forum ? "number" : SakuraCordSystemSymbol.thread)
        case .channel, .user:
            AvatarView(
                name: destination.title,
                url: destination.avatarURL,
                size: ForwardPickerLayoutMetrics.iconSize
            )
        }
    }

    private func guildIcon(symbol: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if destination.guild?.iconURL != nil {
                GuildIconView(
                    name: destination.guild?.name ?? destination.title,
                    iconURL: destination.guild?.iconURL,
                    size: ForwardPickerLayoutMetrics.iconSize,
                    cornerRadius: ForwardPickerLayoutMetrics.iconSize / 2,
                    animates: false
                )
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: ForwardPickerLayoutMetrics.iconSize, height: ForwardPickerLayoutMetrics.iconSize)
                    .overlay {
                        Text(guildInitials)
                            .font(.interfaceSystem(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
            }
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: InterfaceScale.metric(18), height: InterfaceScale.metric(18))
                .overlay {
                    SakuraCordSystemSymbol.swiftUIImage(named: symbol)
                        .font(.interfaceSystem(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .overlay {
                    Circle().stroke(.black.opacity(0.12), lineWidth: 0.5)
                }
                .offset(x: InterfaceScale.metric(3), y: InterfaceScale.metric(3))
        }
        .frame(width: ForwardPickerLayoutMetrics.iconSize, height: ForwardPickerLayoutMetrics.iconSize)
        .accessibilityHidden(true)
    }

    private var guildInitials: String {
        let name = destination.guild?.name ?? destination.title
        let initials = name.split(whereSeparator: { $0.isWhitespace }).compactMap(\.first)
        if initials.count > 1 {
            return String(initials.prefix(3)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}
