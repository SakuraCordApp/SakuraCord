import SwiftUI

struct MentionAutocompleteRow: View {
    let suggestion: MentionAutocompleteSuggestion
    let isSelected: Bool
    let select: () -> Void
    let highlight: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                leadingVisual
                if suggestion.detail.isEmpty {
                    Text(suggestion.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Text(suggestion.title)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 8)
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
            .padding(.horizontal, 9)
            .frame(height: 40)
            .background(
                isSelected ? Color.primary.opacity(0.10) : .clear,
                in: ConcentricRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlight() } }
    }

    @ViewBuilder
    private var leadingVisual: some View {
        switch suggestion.target {
        case .unresolved:
            EmptyView()
        case .user:
            AvatarView(name: suggestion.title, url: suggestion.avatarURL, size: 28)
        case .role:
            RoleColorIndicator(colorHex: suggestion.colorHex, size: 16)
                .frame(width: 28, height: 28)
        case .channel:
            Image(systemName: suggestion.systemImage ?? "questionmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        case .linkedChannel:
            Image(systemName: ChannelIconPresentation.forumPostSystemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        case .message:
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }
}
