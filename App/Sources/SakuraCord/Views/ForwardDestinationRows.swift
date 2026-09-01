import SakuraCordModels
import SwiftUI

struct ForwardSelectionControl: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : .clear)
            Circle()
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary,
                    lineWidth: 1.8
                )
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(
            width: ForwardPickerLayoutMetrics.selectionDiameter,
            height: ForwardPickerLayoutMetrics.selectionDiameter
        )
        .accessibilityHidden(true)
    }
}

struct ForwardDestinationRow: View {
    let destination: ForwardDestination
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ForwardDestinationAvatar(destination: destination)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    let detail = destination.unavailableReason ?? destination.detail
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(destination.unavailableReason == nil
                                ? Color.secondary : Color.red)
                            .lineLimit(1)
                    }
                }
                Spacer()
                ForwardSelectionControl(isSelected: isSelected)
            }
            .padding(.horizontal, 16)
            .frame(height: ForwardPickerLayoutMetrics.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowBackground)
            }
        }
        .buttonStyle(.plain)
        .disabled(destination.unavailableReason != nil)
        .opacity(destination.unavailableReason == nil ? 1 : 0.62)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(destination.id.accessibilityIdentifier)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var rowBackground: Color {
        .primary.opacity(isSelected || isHovered ? 0.075 : 0.001)
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
            guildIcon(channelKind: channel.kind)
        case .thread:
            guildIcon(channelKind: .text)
        case .channel, .user:
            AvatarView(
                name: destination.title,
                url: destination.avatarURL,
                size: 28
            )
        }
    }

    private func guildIcon(channelKind: ChannelKindValue) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if destination.guild?.iconURL != nil {
                GuildIconView(
                    name: destination.guild?.name ?? destination.title,
                    iconURL: destination.guild?.iconURL,
                    size: 28,
                    cornerRadius: 9,
                    animates: false
                )
            } else {
                ConcentricRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Text(guildInitials)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
            }
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: channelKind == .voice ? "speaker.wave.2.fill" : "number")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .overlay {
                    Circle().stroke(.black.opacity(0.12), lineWidth: 0.5)
                }
                .offset(x: 4, y: 4)
        }
        .frame(width: 34, height: 34)
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
