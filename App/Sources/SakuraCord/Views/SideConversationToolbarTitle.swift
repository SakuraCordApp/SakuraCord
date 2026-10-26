import SwiftUI

/// A side chat's title in the window toolbar. Its capsule fills a fixed width
/// from the pane's leading inset to the pane's actions, truncating the title
/// within it, so title changes never move it.
struct SideConversationToolbarTitle: View {
    let label: SideConversationLabel
    /// Nil until the toolbar has laid the item out once.
    let width: CGFloat?

    var body: some View {
        ConversationToolbarLabel(
            title: label.title,
            systemImage: label.systemImage,
            subtitle: nil,
            textSize: InterfaceTypographyMetrics.interfaceTextSize
        )
        // The capsule fills its width whatever the title's length, so its
        // gap to the pane's actions stays constant.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
        .glassEffect(.regular, in: Capsule())
        // Flexible below its ideal width, so a stale width compresses the
        // title instead of overflowing the pane's actions while it updates.
        .frame(idealWidth: width, maxWidth: width)
        .opacity(width == nil ? 0 : 1)
    }
}
