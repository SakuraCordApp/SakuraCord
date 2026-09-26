import MessageRendering
import SwiftUI

struct ComposerTimeFormatPicker: View {
    static let styles: [DiscordTimestampToken.Style] = [
        .shortDateMediumTime, .longDateShortTime, .fullDateShortTime, .relative,
    ]

    let seconds: Int64
    let selectedIndex: Int
    let select: (DiscordTimestampToken.Style) -> Void
    let highlight: (Int) -> Void

    var body: some View {
        ComposerAutocompletePanel(heading: "TIME FORMATS", count: Self.styles.count) {
            LazyVStack(spacing: 2) {
                ForEach(Self.styles.indices, id: \.self) { index in
                    let style = Self.styles[index]
                    Button { select(style) } label: {
                        Text(DiscordTimestampToken(seconds: seconds, style: style).formatted())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .frame(height: 40)
                            .background(
                                index == selectedIndex ? Color.primary.opacity(0.10) : .clear,
                                in: ConcentricRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onModalHover { if $0 { highlight(index) } }
                }
            }
        }
    }
}
