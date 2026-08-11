import AppKit
import Observation
import QuartzCore
import SwiftUI

nonisolated enum WindowModalKeyPolicy {
    static func isEscape(keyCode: UInt16, characters: String?) -> Bool {
        keyCode == 53 || characters == "\u{1B}"
    }
}

nonisolated enum WindowModalAnimationTiming {
    static let openingSeconds = 0.22
    static let closingSeconds = 0.16
    static let removalDelayMilliseconds = 170
}

/// Hosts a SwiftUI modal above the complete macOS window frame. This keeps
/// titlebar/toolbar chrome, split-view columns, and their responder chains
/// behind one stable surface without changing the workspace's layout tree.
struct WindowModalOverlay<Presentation: Identifiable, Content: View>: NSViewRepresentable
where Presentation.ID: Hashable {
    let presentation: Presentation?
    let zPosition: CGFloat
    let dismiss: () -> Void
    @ViewBuilder let content: (
        Presentation,
        WindowModalAnimationState
    ) -> Content

    init(
        presentation: Presentation?,
        zPosition: CGFloat = 100_000,
        dismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping (
            Presentation,
            WindowModalAnimationState
        ) -> Content
    ) {
        self.presentation = presentation
        self.zPosition = zPosition
        self.dismiss = dismiss
        self.content = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowModalAttachmentView {
        let view = WindowModalAttachmentView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(
        _ view: WindowModalAttachmentView,
        context: Context
    ) {
        context.coordinator.update(
            presentation: presentation,
            zPosition: zPosition,
            dismiss: dismiss,
            content: content
        )
    }

    static func dismantleNSView(
        _ view: WindowModalAttachmentView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
        view.windowChanged = nil
    }

    @MainActor
    final class Coordinator {
        private weak var attachmentView: WindowModalAttachmentView?
        private weak var presentationWindow: NSWindow?
        private var overlayView: WindowModalHostingView?
        private var presentation: Presentation?
        private var zPosition: CGFloat = 100_000
        private var dismiss: (() -> Void)?
        private var content: ((Presentation, WindowModalAnimationState) -> Content)?
        private var keyMonitor: Any?

        func attach(to view: WindowModalAttachmentView) {
            attachmentView = view
            view.windowChanged = { [weak self] window in
                self?.windowDidChange(window)
            }
        }

        func update(
            presentation: Presentation?,
            zPosition: CGFloat,
            dismiss: @escaping () -> Void,
            content: @escaping (Presentation, WindowModalAnimationState) -> Content
        ) {
            self.presentation = presentation
            self.zPosition = zPosition
            self.dismiss = dismiss
            self.content = content
            reconcileOverlay()
        }

        func detach() {
            presentation = nil
            dismiss = nil
            content = nil
            removeOverlay()
            attachmentView = nil
            presentationWindow = nil
        }

        private func windowDidChange(_ window: NSWindow?) {
            guard presentationWindow !== window else { return }
            removeOverlay()
            presentationWindow = window
            reconcileOverlay()
        }

        private func reconcileOverlay() {
            guard let presentation,
                  let dismiss,
                  let content,
                  let window = attachmentView?.window ?? presentationWindow,
                  let container = window.contentView?.superview ?? window.contentView
            else {
                overlayView?.requestDismissal(committingPresentation: false)
                return
            }

            let presentationID = AnyHashable(presentation.id)
            if let overlayView,
               overlayView.presentationID == presentationID,
               overlayView.superview === container
            {
                // The hosted SwiftUI tree observes its own model dependencies.
                // Replacing rootView here used to recreate every glass surface,
                // focus binding, row, and remote-image coordinator whenever the
                // surrounding workspace updated. Besides being expensive, that
                // made individual controls join/leave the modal animation at
                // visibly different times.
                overlayView.updateDismissCallback(dismiss)
                installKeyMonitorIfNeeded(for: window)
                return
            }

            removeOverlay()
            presentationWindow = window
            let overlay = WindowModalHostingView(
                presentationID: presentationID,
                dismiss: dismiss,
                didFinishDismissal: { [weak self] in
                    self?.removeOverlay(ifPresentationID: presentationID)
                },
                content: { animationState in
                    AnyView(content(presentation, animationState))
                }
            )
            overlay.frame = container.bounds
            overlay.autoresizingMask = [.width, .height]
            overlay.wantsLayer = true
            overlay.layer?.zPosition = zPosition
            container.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlayView = overlay
            installKeyMonitorIfNeeded(for: window)
            window.makeFirstResponder(overlay)
            overlay.present()
        }

        private func installKeyMonitorIfNeeded(for window: NSWindow) {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self, weak window] event in
                guard WindowModalKeyPolicy.isEscape(
                    keyCode: event.keyCode,
                    characters: event.charactersIgnoringModifiers
                ),
                      let self,
                      self.presentation != nil,
                      event.window === window
                          || NSApp.keyWindow === window
                          || NSApp.mainWindow === window
                else { return event }
                self.overlayView?.requestDismissal()
                return nil
            }
        }

        private func removeOverlay() {
            overlayView?.cancelPendingDismissal()
            overlayView?.removeFromSuperview()
            overlayView = nil
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        private func removeOverlay(ifPresentationID presentationID: AnyHashable) {
            guard overlayView?.presentationID == presentationID else { return }
            removeOverlay()
        }
    }
}

@MainActor
final class WindowModalAttachmentView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}

@MainActor
final class WindowModalHostingView: NSHostingView<AnyView> {
    let presentationID: AnyHashable
    let animationState: WindowModalAnimationState

    override var acceptsFirstResponder: Bool { true }

    init(
        presentationID: AnyHashable,
        dismiss: @escaping () -> Void,
        didFinishDismissal: @escaping () -> Void,
        content: (WindowModalAnimationState) -> AnyView
    ) {
        self.presentationID = presentationID
        let animationState = WindowModalAnimationState(
            dismiss: dismiss,
            didFinishDismissal: didFinishDismissal
        )
        self.animationState = animationState
        super.init(
            rootView: content(animationState)
        )
        animationState.requestDismissal = { [weak self] commitsPresentation in
            self?.requestDismissal(committingPresentation: commitsPresentation)
        }
        alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityModal(true)
    }

    @available(*, unavailable)
    required init(rootView: AnyView) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cancelOperation(_ sender: Any?) {
        requestDismissal()
    }

    override func keyDown(with event: NSEvent) {
        if WindowModalKeyPolicy.isEscape(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers
        ) {
            requestDismissal()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           WindowModalKeyPolicy.isEscape(
               keyCode: event.keyCode,
               characters: event.charactersIgnoringModifiers
           )
        {
            requestDismissal()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    func updateDismissCallback(_ dismiss: @escaping () -> Void) {
        animationState.updateDismissCallback(dismiss)
    }

    func present() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            animationState.present()
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                alphaValue = 1
                return
            }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = WindowModalAnimationTiming.openingSeconds
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    func requestDismissal(committingPresentation: Bool = true) {
        guard animationState.canBeginDismissal else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 0
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WindowModalAnimationTiming.closingSeconds
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
            }
        }
        animationState.beginDismissal(committingPresentation: committingPresentation)
    }

    func cancelPendingDismissal() {
        animationState.cancelPendingDismissal()
    }
}

@MainActor
@Observable
final class WindowModalAnimationState {
    fileprivate var requestDismissal: ((Bool) -> Void)?
    private(set) var isVisible = false
    private var dismissalTask: Task<Void, Never>?
    private var dismissPresentation: () -> Void
    private let didFinishDismissal: () -> Void

    init(
        dismiss: @escaping () -> Void,
        didFinishDismissal: @escaping () -> Void
    ) {
        dismissPresentation = dismiss
        self.didFinishDismissal = didFinishDismissal
    }

    func updateDismissCallback(_ dismiss: @escaping () -> Void) {
        dismissPresentation = dismiss
    }

    func dismiss(committingPresentation: Bool) {
        requestDismissal?(committingPresentation)
    }

    fileprivate func present() {
        guard !isVisible, dismissalTask == nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            isVisible = true
        } else {
            withAnimation(.easeOut(duration: WindowModalAnimationTiming.openingSeconds)) {
                isVisible = true
            }
        }
    }

    fileprivate func beginDismissal(committingPresentation: Bool) {
        guard dismissalTask == nil else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            isVisible = false
        } else {
            withAnimation(.easeIn(duration: WindowModalAnimationTiming.closingSeconds)) {
                isVisible = false
            }
        }
        dismissalTask = Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(
                    for: .milliseconds(WindowModalAnimationTiming.removalDelayMilliseconds)
                )
            }
            guard !Task.isCancelled else { return }
            if committingPresentation {
                dismissPresentation()
            }
            didFinishDismissal()
        }
    }

    fileprivate var canBeginDismissal: Bool {
        dismissalTask == nil
    }

    func cancelPendingDismissal() {
        dismissalTask?.cancel()
        dismissalTask = nil
    }
}
