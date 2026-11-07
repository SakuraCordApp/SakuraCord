import SwiftUI

/// Motion shared by every sidebar mention badge: it pops in, rolls its
/// digits as the count changes and shrinks away when cleared.
enum MentionBadgeMotion {
    static let animation = Animation.spring(duration: 0.35, bounce: 0.3)
    static let transition = AnyTransition.scale(scale: 0.4).combined(with: .opacity)
}

extension View {
    /// Animates the mention badges within this view when `count` changes.
    func mentionBadgeMotion(_ count: Int) -> some View {
        modifier(MentionBadgeAnimation(count: count))
    }
}

private struct MentionBadgeAnimation: ViewModifier {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.reducesSidebarMotion) private var reducesSidebarMotion

    func body(content: Content) -> some View {
        content.animation(systemReducesMotion || reducesSidebarMotion ? nil : MentionBadgeMotion.animation, value: count)
    }
}

/// A channel, thread or conversation row's mention count.
struct SidebarMentionBadge: View {
    let count: Int

    var body: some View {
        Text(count, format: .number)
            .font(.interface(.caption2).bold())
            .foregroundStyle(.white)
            .contentTransition(.numericText(value: Double(count)))
            .padding(.horizontal, InterfaceScale.metric(6))
            .padding(.vertical, InterfaceScale.metric(2))
            .background(Color(hex: MentionRed.hex), in: Capsule())
            .transition(MentionBadgeMotion.transition)
    }
}
