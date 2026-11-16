import SwiftUI

/// The composer's option menu: a section title, then rows with an inset
/// highlight concentric with the panel, navigated by the keyboard with room
/// to spare at the edges. Command arguments and emoji share it.
struct ComposerOptionPanel<Row: Identifiable, Label: View>: View where Row.ID == String {
    let title: String
    let rows: [Row]
    let selectedIndex: Int?
    var status: ApplicationCommandSuggestionContent.Status = .ready
    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    var keyboardSelectionRevision = 0
    let select: (Row) -> Void
    let highlight: (Int) -> Void
    let accessibilityLabel: (Row) -> String
    /// Rows that start a new group get a divider above them.
    var startsGroup: (Row) -> Bool = { _ in false }
    @ViewBuilder let label: (Row) -> Label

    private static var rowHeight: CGFloat { InterfaceScale.metric(34) }
    private static var dividerHeight: CGFloat { InterfaceScale.metric(8) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.interface(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, InterfaceScale.metric(14))
                .padding(.top, InterfaceScale.metric(10))
                .padding(.bottom, InterfaceScale.metric(5))
            if !rows.isEmpty {
                ComposerSuggestionList(
                    rows: rows,
                    selectedID: selectedIndex.flatMap { rows.indices.contains($0) ? rows[$0].id : nil },
                    keyboardSelectionRevision: keyboardSelectionRevision,
                    maximumHeight: 320,
                    rowHeight: { Self.rowHeight + (startsGroup($0) ? Self.dividerHeight : 0) },
                    highlight: { row in
                        if let index = rows.firstIndex(where: { $0.id == row.id }), index != selectedIndex { highlight(index) }
                    },
                    activate: select,
                    content: { row in
                        let isSelected = rows.firstIndex(where: { $0.id == row.id }) == selectedIndex
                        VStack(spacing: 0) {
                        if startsGroup(row) {
                            Divider().padding(.horizontal, InterfaceScale.metric(8)).frame(height: Self.dividerHeight)
                        }
                        Button { select(row) } label: {
                            // Every row spans the panel, whether or not its
                            // label ends in a spacer.
                            HStack(spacing: InterfaceScale.metric(8)) { label(row) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, InterfaceScale.metric(8))
                                .frame(height: Self.rowHeight)
                                .background(
                                    isSelected ? Color.primary.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: max(0, cornerRadius - 6), style: .continuous)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .accessibilityLabel(accessibilityLabel(row))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                )
                .padding(.bottom, InterfaceScale.metric(6))
            }
            statusView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .commandPanelSurface(cornerRadius: cornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .ready:
            EmptyView()
        case .loading:
            HStack(spacing: InterfaceScale.metric(8)) {
                InteractionLoadingDotsView()
                Text("Loading options…")
            }
            .font(.interface(.callout))
            .foregroundStyle(.secondary)
            .padding(.horizontal, InterfaceScale.metric(14))
            .padding(.bottom, InterfaceScale.metric(12))
        case let .message(text, isError):
            Text(text)
                .font(.interface(.callout))
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .padding(.horizontal, InterfaceScale.metric(14))
                .padding(.bottom, InterfaceScale.metric(12))
        }
    }
}

/// A row's trailing, secondary text.
struct ComposerOptionDetail: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.interface(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: InterfaceScale.metric(320), alignment: .trailing)
    }
}
