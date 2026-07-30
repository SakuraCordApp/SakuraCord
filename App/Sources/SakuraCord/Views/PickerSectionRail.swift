import SwiftUI

enum PickerSectionRailLayout {
    static let width: CGFloat = 46
    static let bookmarkSize: CGFloat = 30
    static let iconSize: CGFloat = 28
}

struct PickerSectionBookmark<Section: Hashable & Identifiable, Content: View>: View
where Section.ID == String {
    let section: Section
    let visibleSection: Section
    let help: String
    let jump: (Section) -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        Button {
            jump(section)
        } label: {
            content()
                .frame(
                    width: PickerSectionRailLayout.iconSize,
                    height: PickerSectionRailLayout.iconSize,
                    alignment: .center
                )
                .contentShape(ConcentricRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .frame(
            width: PickerSectionRailLayout.bookmarkSize,
            height: PickerSectionRailLayout.bookmarkSize,
            alignment: .center
        )
        .background {
            if visibleSection == section {
                ConcentricRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.13))
            } else if isHovering {
                ConcentricRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .id(section.id)
    }
}
