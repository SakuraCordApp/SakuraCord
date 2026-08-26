import SwiftUI

struct MentionAutocompleteList: View {
    let heading: String
    let suggestions: [MentionAutocompleteSuggestion]
    let selectedIndex: Int
    let highlight: (Int) -> Void
    let select: (MentionAutocompleteSuggestion) -> Void

    var body: some View {
        ComposerAutocompletePanel(heading: heading, count: suggestions.count) {
            LazyVStack(spacing: 2) {
                ForEach(suggestions.enumerated(), id: \.element.id) { index, suggestion in
                    if index > 0,
                       case .role = suggestion.target,
                       case .user = suggestions[index - 1].target
                    {
                        Divider()
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                    }
                    MentionAutocompleteRow(
                        suggestion: suggestion,
                        isSelected: index == selectedIndex,
                        select: { select(suggestion) },
                        highlight: { highlight(index) }
                    )
                }
            }
        }
    }
}
