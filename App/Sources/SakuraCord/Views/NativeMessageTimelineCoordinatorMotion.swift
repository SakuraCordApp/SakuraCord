import AppKit

/// How the timeline follows workspace motions. During a motion the canvas
/// re-wraps its visible rows on every frame, at the width the columns' path
/// gives it, and lays everything out once the width settles.
extension NativeMessageTimelineCoordinator {
        func workspaceMotionObservations(_ center: NotificationCenter) -> [NSObjectProtocol] {
            [
                center.addObserver(forName: WorkspaceLayoutMotion.didBegin, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.canvas?.dismissHoverPresentationForScroll()
                    }
                },
                // A column that covers the conversation rather than resizing
                // it changes no frame here; the timeline follows its path.
                center.addObserver(forName: WorkspaceConversationWidthPath.didAdvance, object: nil, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let scrollView = self.scrollView, self.motionWidth(of: scrollView) != nil
                            || abs(scrollView.contentView.bounds.width - self.lastViewportSize.width) >= 0.5
                        else { return }
                        _ = self.reconcileViewportGeometryIfNeeded()
                    }
                },
                center.addObserver(forName: WorkspaceLayoutMotion.didSettle, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.scrollIdleTask == nil else { return }
                        self.canvas?.allowHoverPresentationAfterScroll()
                    }
                },
            ]
        }

        /// While the workspace's columns move, the width they give the
        /// timeline, if it differs from its own: a column that slides over
        /// the conversation leaves its frame alone.
        func motionWidth(of scrollView: NSScrollView) -> CGFloat? {
            let path = WorkspaceConversationWidthPath.shared
            guard path.isMoving, let width = path.width(of: scrollView),
                  abs(width - scrollView.contentView.bounds.width) >= 0.5
            else { return nil }
            return width
        }
}
