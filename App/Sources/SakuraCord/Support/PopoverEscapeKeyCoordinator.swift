import AppKit
import SwiftUI

@MainActor
final class PopoverEscapeKeyRegistration {
    fileprivate weak var popoverWindow: NSWindow?
    fileprivate weak var presentingWindow: NSWindow?
    fileprivate var dismiss: () -> Void

    fileprivate init(
        popoverWindow: NSWindow,
        presentingWindow: NSWindow?,
        dismiss: @escaping () -> Void
    ) {
        self.popoverWindow = popoverWindow
        self.presentingWindow = presentingWindow
        self.dismiss = dismiss
    }

    func update(
        popoverWindow: NSWindow,
        presentingWindow: NSWindow?,
        dismiss: @escaping () -> Void
    ) {
        self.popoverWindow = popoverWindow
        self.presentingWindow = presentingWindow
        self.dismiss = dismiss
    }

    fileprivate func matches(_ window: NSWindow, registrations: [PopoverEscapeKeyRegistration]) -> Bool {
        if window === popoverWindow { return true }
        // Escape can remain addressed to the workspace/settings window even
        // when several nested popovers are open above it.
        // A same-window overlay inherits its containing popover's presenter.
        // Its registration must not hide that relationship from nested controls.
        var ancestor = presentingWindow ?? registrations.last {
            $0.popoverWindow === popoverWindow && $0.presentingWindow != nil
        }?.presentingWindow
        var visited: Set<ObjectIdentifier> = []
        while let current = ancestor, visited.insert(ObjectIdentifier(current)).inserted {
            if current === window { return true }
            ancestor = registrations.last {
                $0.popoverWindow === current && $0.presentingWindow != nil
            }?.presentingWindow
        }
        return false
    }
}

@MainActor
final class PopoverEscapeKeyCoordinator {
    static let shared = PopoverEscapeKeyCoordinator()

    private final class WeakRegistration {
        weak var value: PopoverEscapeKeyRegistration?

        init(_ value: PopoverEscapeKeyRegistration) {
            self.value = value
        }
    }

    private var registrations: [WeakRegistration] = []
    private var eventMonitor: Any?
    private let installsEventMonitor: Bool

    init(installsEventMonitor: Bool = true) {
        self.installsEventMonitor = installsEventMonitor
    }

    func register(
        popoverWindow: NSWindow,
        presentingWindow: NSWindow?,
        dismiss: @escaping () -> Void
    ) -> PopoverEscapeKeyRegistration {
        if installsEventMonitor {
            prioritizeEventMonitor()
        }
        let registration = PopoverEscapeKeyRegistration(
            popoverWindow: popoverWindow,
            presentingWindow: presentingWindow,
            dismiss: dismiss
        )
        registrations.append(WeakRegistration(registration))
        return registration
    }

    private func prioritizeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard KeyboardShortcutPolicy.isPlainEscape(keyCode: event.keyCode, modifierFlags: event.modifierFlags),
              let eventWindow = event.window ?? NSApp.keyWindow
        else { return event }

        return dismissTopmostPopover(in: eventWindow) ? nil : event
    }

    @discardableResult
    func dismissTopmostPopover(in eventWindow: NSWindow) -> Bool {
        // Let AppKit cancel the alert first, including events addressed to its
        // parent window. Dismissing the host here can orphan the modal session.
        guard eventWindow.sheetParent == nil,
              !PopoverSheetLifecycle.hasSheet(in: eventWindow)
        else { return false }
        registrations.removeAll { $0.value == nil }
        let activeRegistrations = registrations.compactMap(\.value)
        guard let registration = activeRegistrations.reversed().first(where: {
            $0.matches(eventWindow, registrations: activeRegistrations)
        }) else { return false }

        guard !PopoverSheetLifecycle.hasSheet(in: registration.popoverWindow),
              !PopoverSheetLifecycle.hasSheet(in: registration.presentingWindow)
        else { return false }

        registration.dismiss()
        return true
    }
}

private struct PopoverEscapeKeyReader: NSViewRepresentable {
    let source: PopoverPresentingWindow
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(source: source, dismiss: dismiss)
    }

    func makeNSView(context: Context) -> PopoverEscapeTrackingView {
        let view = PopoverEscapeTrackingView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.update(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: PopoverEscapeTrackingView, context: Context) {
        context.coordinator.dismiss = dismiss
        context.coordinator.update(window: nsView.window)
    }

    static func dismantleNSView(
        _ nsView: PopoverEscapeTrackingView,
        coordinator: Coordinator
    ) {
        nsView.windowDidChange = nil
        coordinator.registration = nil
    }

    @MainActor
    final class Coordinator {
        let source: PopoverPresentingWindow
        var dismiss: () -> Void
        var registration: PopoverEscapeKeyRegistration?

        init(source: PopoverPresentingWindow, dismiss: @escaping () -> Void) {
            self.source = source
            self.dismiss = dismiss
        }

        func update(window: NSWindow?) {
            guard let window else {
                registration = nil
                return
            }
            if let registration {
                registration.update(
                    popoverWindow: window,
                    presentingWindow: source.window ?? window.parent,
                    dismiss: dismiss
                )
            } else {
                registration = PopoverEscapeKeyCoordinator.shared.register(
                    popoverWindow: window,
                    presentingWindow: source.window ?? window.parent,
                    dismiss: dismiss
                )
            }
        }
    }
}

private final class PopoverEscapeTrackingView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    func escapeDismissiblePopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: Edge = .top,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) -> some View {
        PopoverSourceScope { source in
            modifier(WindowModalPopoverGuard(dismiss: { isPresented.wrappedValue = false }))
            .popover(
                isPresented: isPresented,
                attachmentAnchor: attachmentAnchor,
                arrowEdge: arrowEdge
            ) {
                content()
                    .background {
                        PopoverEscapeKeyReader(source: source) {
                            isPresented.wrappedValue = false
                        }
                        .frame(width: 0, height: 0)
                    }
            }
        }
    }

    func escapeDismissiblePopover<Item: Identifiable, PopoverContent: View>(
        item: Binding<Item?>,
        attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: Edge = .top,
        @ViewBuilder content: @escaping (Item) -> PopoverContent
    ) -> some View {
        PopoverSourceScope { source in
            modifier(WindowModalPopoverGuard(dismiss: { item.wrappedValue = nil }))
            .popover(
                item: item,
                attachmentAnchor: attachmentAnchor,
                arrowEdge: arrowEdge
            ) { value in
                content(value)
                    .background {
                        PopoverEscapeKeyReader(source: source) {
                            item.wrappedValue = nil
                        }
                        .frame(width: 0, height: 0)
                    }
            }
        }
    }
}

/// A native popover belongs to the modal (or workspace) containing its anchor.
private struct WindowModalPopoverGuard: ViewModifier {
    @Environment(\.windowModalInputAllowed) private var inputAllowed
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: inputAllowed) { _, allowed in
            if !allowed { dismiss() }
        }
    }
}

@MainActor
private final class PopoverPresentingWindow {
    weak var window: NSWindow?
}

private struct PopoverSourceScope<Content: View>: View {
    @State private var source = PopoverPresentingWindow()
    @ViewBuilder let content: (PopoverPresentingWindow) -> Content

    var body: some View {
        content(source).background {
            PopoverSourceWindowReader(source: source).frame(width: 0, height: 0)
        }
    }
}

private struct PopoverSourceWindowReader: NSViewRepresentable {
    let source: PopoverPresentingWindow
    func makeNSView(context: Context) -> Reader { Reader(source: source) }
    func updateNSView(_ view: Reader, context: Context) { source.window = view.window }

    final class Reader: NSView {
        let source: PopoverPresentingWindow
        init(source: PopoverPresentingWindow) {
            self.source = source
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            source.window = window
        }
    }
}
