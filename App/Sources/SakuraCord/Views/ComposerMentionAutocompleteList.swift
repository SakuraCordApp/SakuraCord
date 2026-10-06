import SwiftUI

struct MentionAutocompleteList: View {
    let heading: String
    let suggestions: [MentionAutocompleteSuggestion]
    let selectedIndex: Int
    let highlight: (Int) -> Void
    let select: (MentionAutocompleteSuggestion) -> Void

    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    var keyboardSelectionRevision = 0

    var body: some View {
        ComposerAutocompletePanel(heading: heading, cornerRadius: cornerRadius) {
            ComposerSuggestionList(
                rows: suggestions,
                selectedID: suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex].id : nil,
                keyboardSelectionRevision: keyboardSelectionRevision,
                rowHeight: { hasDivider(before: $0) ? 50 : 42 },
                highlight: highlightRow,
                activate: select,
                content: { suggestion in
                    VStack(spacing: 0) {
                        if hasDivider(before: suggestion) {
                            Divider().padding(.horizontal, 8).frame(height: 8)
                        }
                        MentionAutocompleteRow(
                            suggestion: suggestion,
                            isSelected: suggestions.indices.contains(selectedIndex) && suggestions[selectedIndex].id == suggestion.id,
                            select: { select(suggestion) },
                            cornerRadius: max(0, cornerRadius - 6)
                        )
                    }
                }
            )
        }
    }

    private func highlightRow(_ suggestion: MentionAutocompleteSuggestion) {
        if let index = suggestions.firstIndex(where: { $0.id == suggestion.id }), index != selectedIndex { highlight(index) }
    }

    private func hasDivider(before suggestion: MentionAutocompleteSuggestion) -> Bool {
        guard let index = suggestions.firstIndex(where: { $0.id == suggestion.id }), index > 0,
              (suggestion.member != nil) != (suggestions[index - 1].member != nil) else { return false }
        return true
    }
}
