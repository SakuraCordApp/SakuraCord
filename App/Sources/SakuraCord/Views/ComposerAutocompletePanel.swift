import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

/// The emoji matching a `:` query, in the composer's option menu.
struct EmojiAutocompleteList: View {
    let suggestions: [ColonAutocompleteSuggestion]
    let selectedIndex: Int
    let highlight: (Int) -> Void
    let select: (ColonAutocompleteSuggestion) -> Void

    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    var keyboardSelectionRevision = 0

    var body: some View {
        ComposerOptionPanel(
            title: "Emojis",
            rows: suggestions,
            selectedIndex: selectedIndex,
            cornerRadius: cornerRadius,
            keyboardSelectionRevision: keyboardSelectionRevision,
            select: select,
            highlight: highlight,
            accessibilityLabel: { [$0.detail, $0.source].compactMap { $0 }.joined(separator: ", ") },
            label: { suggestion in
                Group {
                    if let url = suggestion.imageURL {
                        AnimatedRemoteImage(url: url)
                    } else {
                        Text(suggestion.value).font(.interfaceSystem(size: 17))
                    }
                }
                .frame(width: InterfaceScale.metric(22), height: InterfaceScale.metric(22))
                Text(suggestion.detail)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: InterfaceScale.metric(12))
                if let source = suggestion.source {
                    ComposerOptionDetail(source)
                }
            }
        )
    }
}

struct ComposerAutocompletePanel<Content: View>: View {
    let heading: String
    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(.interface(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, InterfaceScale.metric(14))
                .padding(.top, InterfaceScale.metric(10))
                .padding(.bottom, InterfaceScale.metric(5))
            content()
        }
        .frame(maxWidth: .infinity)
        .commandPanelSurface(cornerRadius: cornerRadius)
    }
}
