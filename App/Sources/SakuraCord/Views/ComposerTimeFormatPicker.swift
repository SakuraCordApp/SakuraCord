import MessageRendering
import SwiftUI

/// The `@time` menu: each format, previewing the current time as it counts.
struct ComposerTimeFormatPicker: View {
    static let styles: [DiscordTimestampToken.Style] = [
        .shortDateMediumTime, .longDateShortTime, .fullDateShortTime, .relative,
    ]

    @State private var clock = RelativeTimestampDisplayClock()

    let seconds: Int64
    let selectedIndex: Int
    let cornerRadius: CGFloat
    let keyboardSelectionRevision: Int
    let select: (DiscordTimestampToken.Style) -> Void
    let highlight: (Int) -> Void

    var body: some View {
        ComposerOptionPanel(
            title: "Time formats",
            rows: Self.styles,
            selectedIndex: selectedIndex,
            cornerRadius: cornerRadius,
            keyboardSelectionRevision: keyboardSelectionRevision,
            select: select,
            highlight: highlight,
            accessibilityLabel: preview,
            label: { Text(preview($0)).foregroundStyle(.primary).lineLimit(1) }
        )
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
    }

    private func preview(_ style: DiscordTimestampToken.Style) -> String {
        DiscordTimestampToken(seconds: seconds, style: style).formatted(relativeTo: clock.date)
    }
}
