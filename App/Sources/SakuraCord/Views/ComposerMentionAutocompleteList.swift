import SwiftUI

/// People, roles and channels matching an `@` or `#` query, in the composer's
/// option menu, in the order the suggestions arrive.
struct MentionAutocompleteList: View {
    let heading: String
    let suggestions: [MentionAutocompleteSuggestion]
    let selectedIndex: Int
    let highlight: (Int) -> Void
    let select: (MentionAutocompleteSuggestion) -> Void

    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    var keyboardSelectionRevision = 0

    var body: some View {
        ComposerOptionPanel(
            title: heading,
            rows: suggestions,
            selectedIndex: selectedIndex,
            cornerRadius: cornerRadius,
            keyboardSelectionRevision: keyboardSelectionRevision,
            select: select,
            highlight: highlight,
            accessibilityLabel: { [$0.title, $0.detail].filter { !$0.isEmpty }.joined(separator: ", ") },
            startsGroup: startsRoles,
            label: { suggestion in
                if suggestion.target != .unresolved {
                    MentionAutocompleteIcon(suggestion: suggestion)
                        .frame(width: InterfaceScale.metric(22), height: InterfaceScale.metric(22))
                }
                Text(suggestion.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: InterfaceScale.metric(12))
                if !suggestion.detail.isEmpty {
                    ComposerOptionDetail(suggestion.detail)
                }
            }
        )
    }

    /// Roles follow the people they're listed with, below a divider.
    private func startsRoles(_ suggestion: MentionAutocompleteSuggestion) -> Bool {
        guard let index = suggestions.firstIndex(where: { $0.id == suggestion.id }), index > 0,
              case .role = suggestion.target, case .user = suggestions[index - 1].target else { return false }
        return true
    }
}
