import SwiftUI

/// Nudges a view side to side each time `trigger` changes, when an action it
/// holds is refused.
struct RejectionShake<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            LinearKeyframe(-5, duration: 0.04)
            LinearKeyframe(5, duration: 0.06)
            LinearKeyframe(-3, duration: 0.06)
            LinearKeyframe(3, duration: 0.06)
            LinearKeyframe(0, duration: 0.04)
        }
    }
}
