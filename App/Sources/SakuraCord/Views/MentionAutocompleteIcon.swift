import SwiftUI

/// A mention suggestion's avatar, role colour or channel icon, framed by its row.
struct MentionAutocompleteIcon: View {
    let suggestion: MentionAutocompleteSuggestion

    var body: some View {
        switch suggestion.target {
        case .unresolved:
            EmptyView()
        case .user:
            AvatarView(name: suggestion.title, url: suggestion.avatarURL, size: InterfaceScale.metric(22))
        case .role:
            RoleColorIndicator(colorHex: suggestion.colorHex, size: InterfaceScale.metric(12))
        case .channel, .guildNavigation, .game, .command:
            Image(systemName: suggestion.systemImage ?? "questionmark")
                .font(.interfaceSystem(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        case .linkedChannel:
            Image(systemName: ChannelIconPresentation.forumPostSystemImage)
                .font(.interfaceSystem(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        case .message:
            Image(systemName: "bubble.left.fill")
                .font(.interfaceSystem(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
