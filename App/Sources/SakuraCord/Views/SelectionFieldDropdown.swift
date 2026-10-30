import AppKit
import Observation
import SwiftUI

/// A same-window dropdown: it escapes scroll clipping without a popover or a new window.
struct SelectionFieldDropdown<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let height: CGFloat
    let preferredPlacement: SelectionFieldResultPlacement
    let reduceMotion: Bool
    let dismiss: () -> Void
    let cancel: () -> Void
    @ViewBuilder let content: (CGFloat) -> Content

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.dismiss = dismiss
        view.cancel = cancel
        view.reduceMotion = reduceMotion
        view.preferredPlacement = preferredPlacement
        view.requestedHeight = height
        view.makeContent = { AnyView(content($0)) }
        view.setPresented(isPresented)
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.setPresented(false) }

    final class Anchor: NSView {
        var dismiss: () -> Void = {}
        var cancel: () -> Void = {}
        var reduceMotion = false
        var preferredPlacement: SelectionFieldResultPlacement = .below
        var requestedHeight: CGFloat = InterfaceScale.metric(260)
        var makeContent: (CGFloat) -> AnyView = { _ in AnyView(EmptyView()) }
        private var host: NSHostingView<AnyView>?
        private weak var modalCoordinator: WindowModalCoordinator?
        private var presentation = SelectionFieldDropdownPresentation()
        private var mouseMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var removalTask: Task<Void, Never>?
        private var presented = false

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if presented { show() } }
        override func layout() { super.layout(); if presented { show() } }

        func setPresented(_ value: Bool) {
            presented = value
            if value { show() } else { hide() }
        }

        private var container: NSView? {
            guard let window else { return nil }
            return window.contentView?.superview ?? window.contentView
        }

        private func show() {
            guard let container, bounds.width > 0 else { return }
            removalTask?.cancel()
            removalTask = nil
            let isOpening = host == nil
            if isOpening {
                presentation = SelectionFieldDropdownPresentation()
                let host = NSHostingView(rootView: AnyView(EmptyView()))
                host.sizingOptions = []
                host.wantsLayer = true
                host.layer?.zPosition = 90_000
                container.addSubview(host, positioned: .above, relativeTo: nil)
                self.host = host
                if let window {
                    let coordinator = WindowModalCoordinator.coordinator(for: window)
                    coordinator.registerAccessory(host, from: self)
                    modalCoordinator = coordinator
                }
                installObservers()
            }
            position()
            guard isOpening || !presentation.visible else { return }
            // Establish the collapsed surface once; subsequent updates must not force layout.
            if isOpening { host?.layoutSubtreeIfNeeded() }
            let presentation = presentation
            Task { @MainActor [weak self] in
                guard self?.presented == true else { return }
                presentation.visible = true
            }
        }

        private func position() {
            guard let host, let container else { return }
            let anchor = convert(bounds, to: container)
            // Work in top-down coordinates regardless of the containing NSView.
            let top = container.isFlipped ? anchor.minY : container.bounds.height - anchor.maxY
            let bottom = top + anchor.height
            let below = max(0, container.bounds.height - bottom - 12)
            let above = max(0, top - 12)
            let opensBelow = preferredPlacement == .below ? (below >= requestedHeight || below >= above) : !(above >= requestedHeight || above >= below)
            let height = min(requestedHeight, opensBelow ? below : above)
            let topEdge = opensBelow ? bottom + 7 : top - 7 - height
            let originY = container.isFlipped ? topEdge : container.bounds.height - topEdge - height
            presentation.opensBelow = opensBelow
            host.frame = CGRect(x: anchor.minX, y: originY, width: bounds.width, height: height)
            let content = makeContent(height)
            host.rootView = AnyView(SelectionFieldDropdownSurface(presentation: presentation, reduceMotion: reduceMotion) {
                content
            })
        }

        private func hide() {
            guard host != nil, removalTask == nil else { return }
            presentation.visible = false
            if reduceMotion { removeDropdown(); return }
            // Keep the floating view alive through dismissal even if its field is dismantled.
            removalTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
                removeDropdown()
            }
        }

        func removeDropdown() {
            removalTask?.cancel()
            removalTask = nil
            if let host { modalCoordinator?.unregisterAccessory(host) }
            modalCoordinator = nil
            host?.removeFromSuperview()
            host = nil
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        private func installObservers() {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, presented, event.window === window,
                      WindowModalCoordinator.allowsInput(for: self) else { return event }
                if bounds.contains(convert(event.locationInWindow, from: nil)) { return event }
                if let host, host.bounds.contains(host.convert(event.locationInWindow, from: nil)) { return event }
                dismiss()
                return event
            }
            var ancestor = superview
            while let view = ancestor {
                if let clip = view as? NSClipView {
                    clip.postsBoundsChangedNotifications = true
                    observe(NSView.boundsDidChangeNotification, object: clip)
                }
                ancestor = view.superview
            }
            if let window {
                observe(NSWindow.didResizeNotification, object: window)
                observe(WindowModalCoordinator.inputDidChange, object: window)
            }
        }

        private func observe(_ name: Notification.Name, object: AnyObject) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.presented else { return }
                    if self.visibleRect.isEmpty || !WindowModalCoordinator.allowsInput(for: self) {
                        self.cancel()
                    } else {
                        self.position()
                    }
                }
            })
        }
    }
}

@MainActor @Observable
private final class SelectionFieldDropdownPresentation {
    var visible = false
    var opensBelow = true
}

private struct SelectionFieldDropdownSurface<Content: View>: View {
    let presentation: SelectionFieldDropdownPresentation
    let reduceMotion: Bool
    @ViewBuilder let content: () -> Content

    private var edge: UnitPoint { presentation.opensBelow ? .top : .bottom }
    private var reveal: Animation? {
        guard !reduceMotion else { return nil }
        return presentation.visible
            ? .spring(response: 0.22, dampingFraction: 0.86)
            : .smooth(duration: 0.12)
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) { content() }
            .clipShape(.rect(cornerRadius: SelectionFieldLayoutMetrics.cornerRadius))
            .opacity(presentation.visible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: presentation.visible ? 0.09 : 0.08), value: presentation.visible)
            .mask(alignment: presentation.opensBelow ? .top : .bottom) {
                RoundedRectangle(cornerRadius: SelectionFieldLayoutMetrics.cornerRadius)
                    .scaleEffect(x: 1, y: presentation.visible || reduceMotion ? 1 : 0.06, anchor: edge)
                    .animation(reveal, value: presentation.visible)
            }
            .offset(y: presentation.visible || reduceMotion ? 0 : (presentation.opensBelow ? -InterfaceScale.metric(10) : InterfaceScale.metric(10)))
            .animation(reveal, value: presentation.visible)
            .allowsHitTesting(presentation.visible)
            .accessibilityHidden(!presentation.visible)
    }
}
