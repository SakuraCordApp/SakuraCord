import AppKit
import SwiftUI

enum DiscordLoginField: Hashable {
    case identifier
    case password
    case mfa
}

extension View {
    func sakuracordLoginField(
        isEditorActive: Bool,
        onActivate: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        textFieldStyle(.plain)
            .font(.interface(.body))
            .foregroundStyle(.primary)
            .padding(.horizontal, InterfaceScale.metric(18))
            .frame(height: InterfaceScale.metric(44))
            .background(.background.opacity(0.72), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(isEditorActive ? SakuraCordAccentColor.color.opacity(0.6) : .primary.opacity(0.12), lineWidth: 1)
            }
            .background {
                LoginTextEditorBridge(isActive: isEditorActive, onDismiss: onDismiss)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .simultaneousGesture(TapGesture().onEnded(onActivate))
            .pointerStyle(.horizontalText)
            .tint(SakuraCordAccentColor.color)
    }
}

/// SwiftUI's SecureField does not consistently forward `tint` to the
/// shared AppKit field editor. This bridge styles that editor and dismisses it
/// on outside mouse-down, before the clicked control handles the same event.
/// SwiftUI remains the text and focus owner.
struct LoginTextEditorBridge: NSViewRepresentable {
    let isActive: Bool
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(view: nsView, isActive: isActive, onDismiss: onDismiss)
        guard isActive else { return }
        Task { @MainActor [weak nsView] in
            await Task.yield()
            guard let editor = nsView?.window?.firstResponder as? NSTextView else { return }
            editor.insertionPointColor = .sakuraCordAccentColor
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor.sakuraCordTextSelectionBackgroundColor,
                .foregroundColor: NSColor.selectedTextColor,
            ]
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        private weak var view: NSView?
        private var mouseMonitor: Any?
        private var onDismiss: () -> Void = {}

        func update(view: NSView, isActive: Bool, onDismiss: @escaping () -> Void) {
            self.view = view
            self.onDismiss = onDismiss
            guard isActive else {
                stopMonitoring()
                return
            }
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.dismissIfOutside(event)
                return event
            }
        }

        func stopMonitoring() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
        }

        private func dismissIfOutside(_ event: NSEvent) {
            guard let view, let window = view.window, event.window === window,
                  !view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            else { return }
            if let contentView = window.contentView {
                var target = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
                while let candidate = target {
                    if candidate is NSTextField || candidate is NSTextView { return }
                    target = candidate.superview
                }
            }
            window.makeFirstResponder(nil)
            onDismiss()
            stopMonitoring()
        }
    }
}
