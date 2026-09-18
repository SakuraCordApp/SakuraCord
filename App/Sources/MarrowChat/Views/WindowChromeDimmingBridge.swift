import AppKit
import SwiftUI

/// Extends SwiftUI-owned dimming into the AppKit title-bar region that sits
/// outside the root view's bounds.
struct WindowChromeDimmingBridge: NSViewRepresentable {
    let isDimmed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.update(window: view.window, isDimmed: isDimmed)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.update(window: view.window, isDimmed: isDimmed)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private weak var frameView: NSView?
        private var resizeObserver: NSObjectProtocol?
        private var overlay: WindowChromeDimmingView?

        func update(window: NSWindow?, isDimmed: Bool) {
            if self.window !== window {
                attach(to: window)
            }
            updateOverlayFrame()
            overlay?.isHidden = !isDimmed
        }

        func detach() {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            resizeObserver = nil
            overlay?.removeFromSuperview()
            overlay = nil
            frameView = nil
            window = nil
        }

        private func attach(to window: NSWindow?) {
            detach()
            self.window = window
            guard let window, let frameView = window.contentView?.superview else { return }
            self.frameView = frameView

            let overlay = WindowChromeDimmingView(frame: .zero)
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            overlay.isHidden = true
            frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.overlay = overlay

            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateOverlayFrame()
                }
            }
        }

        private func updateOverlayFrame() {
            guard let window, let frameView, let overlay else { return }
            let chromeHeight = max(
                0,
                frameView.bounds.height - window.contentLayoutRect.height
            )
            overlay.frame = CGRect(
                x: 0,
                y: frameView.bounds.maxY - chromeHeight,
                width: frameView.bounds.width,
                height: chromeHeight
            )
        }
    }
}

private final class WindowChromeDimmingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
