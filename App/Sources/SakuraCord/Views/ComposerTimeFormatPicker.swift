import MessageRendering
import SwiftUI

/// The `@time` menu: every reading of the typed time in Discord's formats,
/// the first format of each reading labelled with what sets it apart.
struct ComposerTimeFormatPicker: View {
    struct Row: Identifiable {
        let id: String
        let token: DiscordTimestampToken
        let reading: DiscordTimeSuggestion.Reading?
        let startsGroup: Bool
    }

    static func rows(_ suggestions: [DiscordTimeSuggestion]) -> [Row] {
        suggestions.enumerated().flatMap { index, suggestion in
            suggestion.styles.enumerated().map { styleIndex, style in
                Row(
                    id: "\(index)-\(style.rawValue)",
                    token: suggestion.token(style),
                    reading: styleIndex == 0 ? suggestion.reading : nil,
                    startsGroup: index > 0 && styleIndex == 0
                )
            }
        }
    }

    @State private var clock = RelativeTimestampDisplayClock()

    let query: String
    let rows: [Row]
    /// Return was pressed while nothing matched, which Discord refuses to send.
    let needsPick: Bool
    let selectedIndex: Int
    let cornerRadius: CGFloat
    let keyboardSelectionRevision: Int
    let select: (Row) -> Void
    let highlight: (Int) -> Void

    var body: some View {
        ComposerOptionPanel(
            title: title,
            rows: rows,
            selectedIndex: selectedIndex,
            status: needsPick ? .message("Pick a time to continue.", isError: true) : .ready,
            cornerRadius: cornerRadius,
            keyboardSelectionRevision: keyboardSelectionRevision,
            select: select,
            highlight: highlight,
            accessibilityLabel: { [$0.token.formatted(relativeTo: clock.date), $0.reading.map(Self.label)].compactMap { $0 }.joined(separator: ", ") },
            startsGroup: \.startsGroup,
            label: { row in
                Text(row.token.formatted(relativeTo: clock.date)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: InterfaceScale.metric(12))
                if let reading = row.reading { ComposerOptionDetail(Self.label(reading)) }
            }
        )
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
    }

    private var title: String {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? "Time formats" : "Time formats for \(query)"
    }

    private static func label(_ reading: DiscordTimeSuggestion.Reading) -> String {
        switch reading {
        case .timeOnly: "Time only"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .thisWeek: "This week"
        case .nextWeek: "Next week"
        case .lastWeek: "Last week"
        case .thisYear: "This year"
        case .nextYear: "Next year"
        }
    }
}
