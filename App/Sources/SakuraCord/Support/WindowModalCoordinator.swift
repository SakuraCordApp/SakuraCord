import AppKit
import SwiftUI

/// Native surfaces clear transient state when their window's input owner changes.
@MainActor
protocol WindowModalInputParticipant: AnyObject {
    func modalInputDidChange()
}

/// Presentation order, focus and event ownership belong to a window, not AppModel.
@MainActor
final class WindowModalCoordinator {
    static let inputDidChange = Notification.Name("WindowModalInputDidChange")
    private static let coordinators = NSMapTable<NSWindow, WindowModalCoordinator>.weakToStrongObjects()

    private final class Entry {
        weak var host: WindowModalHostingView?
        weak var previousResponder: NSResponder?
        let accessories = NSHashTable<NSView>.weakObjects()

        init(host: WindowModalHostingView, previousResponder: NSResponder?) {
            self.host = host
            self.previousResponder = previousResponder
        }

        func contains(_ view: NSView) -> Bool {
            if let host, view === host || view.isDescendant(of: host) { return true }
            return accessories.allObjects.contains { view === $0 || view.isDescendant(of: $0) }
        }
    }

    private weak var window: NSWindow?
    private var entries: [Entry] = []
    private var monitor: Any?
    private weak var scrollOwner: WindowModalHostingView?

    init(window: NSWindow) { self.window = window }

    static func coordinator(for window: NSWindow) -> WindowModalCoordinator {
        if let existing = coordinators.object(forKey: window) { return existing }
        let coordinator = WindowModalCoordinator(window: window)
        coordinators.setObject(coordinator, forKey: window)
        return coordinator
    }

    static func allowsInput(for view: NSView) -> Bool {
        // Retained, invisible hosts must never participate, even with no open modal.
        var ancestor: NSView? = view
        while let current = ancestor {
            if let host = current as? WindowModalHostingView, !host.isPresented { return false }
            ancestor = current.superview
        }
        guard let window = view.window,
              let coordinator = coordinators.object(forKey: window)
        else { return true }
        return coordinator.allowsInput(to: view)
    }

    var topmost: WindowModalHostingView? { entries.reversed().compactMap(\.host).first }

    func allowsInput(to view: NSView) -> Bool {
        guard let topmost else { return true }
        return entries.last { $0.host === topmost }?.contains(view) == true
    }

    /// Floating controls must be siblings of the modal's SwiftUI host to render
    /// outside its glass composition, but still belong to that modal for input.
    func registerAccessory(_ view: NSView, from source: NSView) {
        guard let entry = entries.last(where: { $0.contains(source) }) else { return }
        entry.accessories.add(view)
        reorderHosts()
    }

    func unregisterAccessory(_ view: NSView) {
        for entry in entries { entry.accessories.remove(view) }
    }

    func present(_ host: WindowModalHostingView) {
        guard !entries.contains(where: { $0.host === host }), let window else { return }
        entries.append(Entry(host: host, previousResponder: window.firstResponder))
        reorderHosts()
        installMonitor()
        updateInputOwnership()
        window.makeFirstResponder(host)
    }

    func remove(_ host: WindowModalHostingView) {
        guard let index = entries.firstIndex(where: { $0.host === host }) else { return }
        let wasTopmost = topmost === host
        let previous = entries[index].previousResponder
        // A covered modal can disappear before its child. Repair the focus chain.
        for entry in entries.dropFirst(index + 1) {
            if let view = entry.previousResponder as? NSView,
               entries[index].contains(view) {
                entry.previousResponder = previous
            }
        }
        for accessory in entries[index].accessories.allObjects { accessory.removeFromSuperview() }
        entries.remove(at: index)
        host.animationState.isInputActive = false
        // The rest keep their order; reordering would raise them over a
        // modal still animating away.
        updateInputOwnership()
        if wasTopmost, let window {
            if let view = previous as? NSView, view.window === window,
               allowsInput(to: view), !view.isHiddenOrHasHiddenAncestor {
                window.makeFirstResponder(view)
            } else {
                window.makeFirstResponder(topmost ?? window.contentView)
            }
        }
        if entries.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func reorderHosts() {
        for (index, entry) in entries.enumerated() {
            guard let host = entry.host, let container = host.superview else { continue }
            host.layer?.zPosition = CGFloat(100_000 + index)
            container.addSubview(host, positioned: .above, relativeTo: nil)
            for accessory in entry.accessories.allObjects {
                accessory.layer?.zPosition = CGFloat(100_000 + index) + 0.5
                container.addSubview(accessory, positioned: .above, relativeTo: host)
            }
        }
    }

    private func updateInputOwnership() {
        scrollOwner = nil
        for entry in entries {
            entry.host?.animationState.isInputActive = entry.host === topmost
        }
        guard let window else { return }
        func visit(_ view: NSView) {
            (view as? WindowModalInputParticipant)?.modalInputDidChange()
            window.invalidateCursorRects(for: view)
            for child in view.subviews { visit(child) }
        }
        if let container = window.contentView?.superview ?? window.contentView { visit(container) }
        NotificationCenter.default.post(name: Self.inputDidChange, object: window)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .scrollWheel, .mouseEntered, .mouseExited, .cursorUpdate]
        ) { [weak self] event in
            guard let self else { return event }
            return filter(event)
        }
    }

    // Internal for focused event-routing regression tests. Returning nil consumes input.
    func filter(_ event: NSEvent) -> NSEvent? {
        guard let window, let topmost,
              event.window === window || event.window == nil && NSApp.keyWindow === window
        else { return event }
        if event.type == .keyDown {
            guard KeyboardShortcutPolicy.isPlainEscape(keyCode: event.keyCode, modifierFlags: event.modifierFlags, characters: event.charactersIgnoringModifiers) else { return event }
            if window.attachedSheet != nil { return event }
            if PopoverEscapeKeyCoordinator.shared.dismissTopmostPopover(in: window) { return nil }
            guard topmost.capturesEscape else { return event }
            topmost.animationState.handleEscape()
            return nil
        }
        if event.type == .scrollWheel {
            return allowsScroll(phase: event.phase, momentumPhase: event.momentumPhase) ? event : nil
        }
        if let owner = event.trackingArea?.owner as? NSView, !allowsInput(to: owner) {
            return nil
        }
        return event
    }

    func allowsScroll(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> Bool {
        guard let topmost else { return true }
        if phase.contains(.began) { scrollOwner = topmost }
        // Momentum belongs to the gesture's original surface, including across
        // presentation and dismissal of a nested modal.
        return momentumPhase.isEmpty || scrollOwner === topmost
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

extension EnvironmentValues {
    @Entry var windowModalInputAllowed = true
}

extension View {
    /// Apply to each independent SwiftUI window root. Hosted modals install their own scope.
    func windowModalInputScope() -> some View { modifier(WindowModalInputScope()) }

    func onModalHover(perform action: @escaping (Bool) -> Void) -> some View {
        modifier(ModalHoverModifier(action: action))
    }
}

private struct ModalHoverModifier: ViewModifier {
    @Environment(\.windowModalInputAllowed) private var inputAllowed
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onHover { action(inputAllowed && $0) }
            .onChange(of: inputAllowed) { _, allowed in
                if !allowed { action(false) }
            }
    }
}

private struct WindowModalInputScope: ViewModifier {
    @State private var inputAllowed = true

    func body(content: Content) -> some View {
        // The full-window native host blocks pointer input. Disabling hit testing
        // on NavigationSplitView also changes its sidebar toolbar insets on macOS 27.
        content
            .environment(\.windowModalInputAllowed, inputAllowed)
            .accessibilityHidden(!inputAllowed)
            .background {
                WindowModalInputReader { inputAllowed = $0 }.frame(width: 0, height: 0)
            }
    }
}

private struct WindowModalInputReader: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> Reader { Reader(changed: changed) }
    func updateNSView(_ view: Reader, context: Context) { view.changed = changed }

    final class Reader: NSView, WindowModalInputParticipant {
        var changed: (Bool) -> Void
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); modalInputDidChange() }
        func modalInputDidChange() {
            let allowed = WindowModalCoordinator.allowsInput(for: self)
            Task { @MainActor [weak self] in
                guard let self, allowed == WindowModalCoordinator.allowsInput(for: self) else { return }
                changed(allowed)
            }
        }
    }
}
