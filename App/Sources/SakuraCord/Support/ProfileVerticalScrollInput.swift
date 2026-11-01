import AppKit
import SwiftUI

/// SwiftUI's vertical scroll views can still apply horizontal trackpad momentum.
/// Remove that axis before AppKit handles it, retaining vertical deltas and phases.
struct ProfileVerticalScrollInput: NSViewRepresentable {
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {}

    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stopMonitoring() }

    final class InputView: NSView {
        private var monitor: Any?

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
                return Self.verticalEvent(event)
            }
        }

        private static func verticalEvent(_ event: NSEvent) -> NSEvent {
            guard let copy = event.cgEvent?.copy() else { return event }
            for field: CGEventField in [
                .scrollWheelEventDeltaAxis2,
                .scrollWheelEventFixedPtDeltaAxis2,
                .scrollWheelEventPointDeltaAxis2,
                .scrollWheelEventAcceleratedDeltaAxis2,
                .scrollWheelEventRawDeltaAxis2,
            ] {
                copy.setDoubleValueField(field, value: 0)
            }
            return NSEvent(cgEvent: copy) ?? event
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
