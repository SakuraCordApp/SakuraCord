import SwiftUI

struct MentionAutocompleteRow: View {
    let suggestion: MentionAutocompleteSuggestion
    let isSelected: Bool
    let select: () -> Void
    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius - 6

    var body: some View {
        Button(action: select) {
            HStack(spacing: InterfaceScale.metric(9)) {
                leadingVisual
                if suggestion.detail.isEmpty {
                    Text(suggestion.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: InterfaceScale.metric(12)) {
                            Text(suggestion.title)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: InterfaceScale.metric(8))
                            Text(suggestion.detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Text(suggestion.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, InterfaceScale.metric(9))
            .frame(height: InterfaceScale.metric(40))
            .background(
                isSelected ? Color.primary.opacity(0.10) : .clear,
                in: ConcentricRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var leadingVisual: some View {
        switch suggestion.target {
        case .unresolved, .game, .command:
            EmptyView()
        case .user:
            AvatarView(name: suggestion.title, url: suggestion.avatarURL, size: InterfaceScale.metric(28))
        case .role:
            RoleColorIndicator(colorHex: suggestion.colorHex, size: InterfaceScale.metric(16))
                .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
        case .channel, .guildNavigation:
            Image(systemName: suggestion.systemImage ?? "questionmark")
                .font(.interfaceSystem(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
        case .linkedChannel:
            Image(systemName: ChannelIconPresentation.forumPostSystemImage)
                .font(.interfaceSystem(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
        case .message:
            Image(systemName: "bubble.left.fill")
                .font(.interfaceSystem(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
        }
    }
}
