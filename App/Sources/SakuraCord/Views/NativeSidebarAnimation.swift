import AppKit
import SwiftUI

/// Changes only the native sidebar's collapse animation. AppKit continues to
/// own its layout, materials, divider, toolbar, and interactive resizing.
struct NativeSidebarAnimation: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the sidebar snaps in the reader's settings, as under Reduce
    /// Motion.
    let snaps: Bool

    func makeNSView(context: Context) -> AnimationView { AnimationView() }

    func updateNSView(_ view: AnimationView, context: Context) {
        view.reduceMotion = reduceMotion || snaps
        view.scheduleUpdate()
    }

    static func dismantleNSView(_ view: AnimationView, coordinator: ()) {
        view.detach()
    }

    final class AnimationView: NSView {
        var reduceMotion = false
        private weak var sidebarItem: NSSplitViewItem?
        private var previousAnimation: Any?
        private var appliedReduceMotion: Bool?
        private var updateTask: Task<Void, Never>?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { scheduleUpdate() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleUpdate()
        }

        func scheduleUpdate() {
            updateTask?.cancel()
            updateTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self, window != nil else { return }
                configureSidebar()
            }
        }

        private func configureSidebar() {
            var ancestor = superview
            while let view = ancestor {
                if let splitView = view as? NSSplitView,
                   let controller = splitView.delegate as? NSSplitViewController,
                   let item = controller.splitViewItems.first(where: {
                       $0.behavior == .sidebar && isDescendant(of: $0.viewController.view)
                   })
                {
                    if sidebarItem !== item {
                        restoreAnimation()
                        sidebarItem = item
                        previousAnimation = item.animations["collapsed"]
                    }
                    guard appliedReduceMotion != reduceMotion else { return }
                    let spring = ChatChromeMetrics.sidebarSpring
                    let animation = CASpringAnimation(
                        perceptualDuration: spring.duration,
                        bounce: spring.bounce
                    )
                    animation.duration = reduceMotion ? 0 : spring.settlingDuration
                    item.animations["collapsed"] = animation
                    appliedReduceMotion = reduceMotion
                    return
                }
                ancestor = view.superview
            }
        }

        func detach() {
            updateTask?.cancel()
            updateTask = nil
            restoreAnimation()
        }

        private func restoreAnimation() {
            sidebarItem?.animations["collapsed"] = previousAnimation
            sidebarItem = nil
            previousAnimation = nil
            appliedReduceMotion = nil
        }
    }
}
