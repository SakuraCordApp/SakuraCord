import SwiftUI

/// Composer lists share the command picker's exact native scroll geometry.
/// Only keyboard navigation reveals a selection; pointer highlights never scroll.
/// Clicks activate rows through the list, not the hosted row views.
struct ComposerSuggestionList<Row: Identifiable, Content: View>: View where Row.ID == String {
    let rows: [Row]
    let selectedID: String?
    let keyboardSelectionRevision: Int
    var maximumHeight: CGFloat = InterfaceScale.metric(340)
    let rowHeight: (Row) -> CGFloat
    let highlight: (Row) -> Void
    let activate: (Row) -> Void
    @ViewBuilder let content: (Row) -> Content
    @Environment(\.composerSuggestionListHeightLimit) private var heightLimit

    var body: some View {
        let ids = rows.map(\.id)
        let heights = rows.map(rowHeight)
        NativePickerScrollReader { proxy in
            NativePickerDocument(
                rows: rows,
                revision: geometryRevision(ids: ids, heights: heights),
                position: proxy,
                capturesOverlayPointer: true,
                rowHeight: { row, _ in rowHeight(row) },
                pointerRowChanged: highlight,
                rowActivated: activate,
                content: content
            )
            .onChange(of: keyboardSelectionRevision) { _, _ in
                if let selectedID { proxy.scrollTo(selectedID) }
            }
            .onChange(of: ids, initial: true) { _, _ in
                if let id = selectedID ?? ids.first { proxy.scrollTo(id) }
            }
        }
        .frame(height: min(maximumHeight, heightLimit, heights.reduce(0, +)))
        .padding(.horizontal, InterfaceScale.metric(6))
    }

    private func geometryRevision(ids: [String], heights: [CGFloat]) -> Int {
        var hasher = Hasher()
        hasher.combine(ids)
        hasher.combine(heights)
        return hasher.finalize()
    }
}

extension EnvironmentValues {
    /// Caps a suggestion list below its own maximum where it opens in a
    /// short space, such as a forum post's body.
    @Entry var composerSuggestionListHeightLimit: CGFloat = .infinity
}
