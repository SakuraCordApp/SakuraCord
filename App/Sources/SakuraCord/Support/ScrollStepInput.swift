import AppKit
import SwiftUI

/// Turns scrolling over a view into whole steps, up or right being later: a
/// trackpad every few points, momentum included, and a mouse wheel per notch.
struct ScrollStepInput: NSViewRepresentable {
    /// Returns whether the step was taken; a refused step drops the remainder.
    let step: (Int) -> Bool

    func makeNSView(context: Context) -> InputView { InputView(step: step) }
    func updateNSView(_ view: InputView, context: Context) { view.step = step }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stopMonitoring() }

    final class InputView: NSView {
        /// Trackpad points per step.
        private static let stepDistance: CGFloat = 18
        var step: (Int) -> Bool
        private var monitor: Any?
        private var pending: CGFloat = 0

        init(step: @escaping (Int) -> Bool) {
            self.step = step
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      WindowModalCoordinator.allowsInput(for: self)
                else { return event }
                self.handle(event)
                return nil
            }
        }

        private func handle(_ event: NSEvent) {
            let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            let delta = direction * (event.scrollingDeltaX - event.scrollingDeltaY)
            guard event.hasPreciseScrollingDeltas else {
                if delta != 0 { _ = step(delta > 0 ? 1 : -1) }
                return
            }
            if event.phase.contains(.began) { pending = 0 }
            pending += delta
            while abs(pending) >= Self.stepDistance {
                let sign: CGFloat = pending > 0 ? 1 : -1
                guard step(Int(sign)) else {
                    pending = 0
                    return
                }
                pending -= sign * Self.stepDistance
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
