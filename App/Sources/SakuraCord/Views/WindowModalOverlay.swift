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

nonisolated struct WindowModalBehavior: Sendable {
    var animates: Bool
    var capturesEscape: Bool
    var retainsHostWhenDismissed: Bool = false

    static let standard = WindowModalBehavior(animates: true, capturesEscape: true)
    static let instantKeyboardOwned = WindowModalBehavior(
        animates: false,
        capturesEscape: false,
        retainsHostWhenDismissed: true
    )
}

/// Hosts a SwiftUI modal above the complete macOS window frame. This keeps
/// titlebar/toolbar chrome, split-view columns, and their responder chains
/// behind one stable surface without changing the workspace's layout tree.
struct WindowModalOverlay<Presentation: Identifiable, Content: View>: NSViewRepresentable
where Presentation.ID: Hashable {
    let presentation: Presentation?
    let preloadedPresentation: Presentation?
    let zPosition: CGFloat
    let behavior: (Presentation) -> WindowModalBehavior
    let dismiss: () -> Void
    @ViewBuilder let content: (
        Presentation,
        WindowModalAnimationState
    ) -> Content

    init(
        presentation: Presentation?,
        preloadedPresentation: Presentation? = nil,
        zPosition: CGFloat = 100_000,
        behavior: @escaping (Presentation) -> WindowModalBehavior = { _ in .standard },
        dismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping (
            Presentation,
            WindowModalAnimationState
        ) -> Content
    ) {
        self.presentation = presentation
        self.preloadedPresentation = preloadedPresentation
        self.zPosition = zPosition
        self.behavior = behavior
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
            preloadedPresentation: preloadedPresentation,
            zPosition: zPosition,
            behavior: behavior,
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
        private var preloadedPresentation: Presentation?
        private var zPosition: CGFloat = 100_000
        private var behavior: ((Presentation) -> WindowModalBehavior)?
        private var dismiss: (() -> Void)?
        private var content: ((Presentation, WindowModalAnimationState) -> Content)?
        private var keyMonitor: Any?
        private weak var previousFirstResponder: NSResponder?

        func attach(to view: WindowModalAttachmentView) {
            attachmentView = view
            view.windowChanged = { [weak self] window in
                self?.windowDidChange(window)
            }
        }

        func update(
            presentation: Presentation?,
            preloadedPresentation: Presentation?,
            zPosition: CGFloat,
            behavior: @escaping (Presentation) -> WindowModalBehavior,
            dismiss: @escaping () -> Void,
            content: @escaping (Presentation, WindowModalAnimationState) -> Content
        ) {
            self.presentation = presentation
            self.preloadedPresentation = preloadedPresentation
            self.zPosition = zPosition
            self.behavior = behavior
            self.dismiss = dismiss
            self.content = content
            reconcileOverlay()
        }

        func detach() {
            presentation = nil
            preloadedPresentation = nil
            dismiss = nil
            content = nil
            behavior = nil
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
            guard let resolvedPresentation = presentation ?? preloadedPresentation,
                  let dismiss,
                  let content,
                  let behavior,
                  let window = attachmentView?.window ?? presentationWindow,
                  let container = window.contentView?.superview ?? window.contentView
            else {
                overlayView?.requestDismissal(committingPresentation: false)
                return
            }

            let presentationID = AnyHashable(resolvedPresentation.id)
            let modalBehavior = behavior(resolvedPresentation)
            let isPresented = presentation != nil
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
                if isPresented {
                    if !overlayView.isPresented {
                        previousFirstResponder = window.firstResponder
                        overlayView.present()
                        window.makeFirstResponder(overlayView)
                    }
                    reconcileKeyMonitor(
                        for: window,
                        capturesEscape: modalBehavior.capturesEscape
                    )
                } else {
                    if overlayView.isPresented {
                        overlayView.hideImmediately()
                        restorePreviousFirstResponder(in: window)
                    }
                    reconcileKeyMonitor(for: window, capturesEscape: false)
                }
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
                behavior: modalBehavior,
                content: { animationState in
                    AnyView(content(resolvedPresentation, animationState))
                }
            )
            overlay.frame = container.bounds
            overlay.autoresizingMask = [.width, .height]
            overlay.wantsLayer = true
            overlay.layer?.zPosition = zPosition
            container.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlayView = overlay
            if isPresented {
                previousFirstResponder = window.firstResponder
                reconcileKeyMonitor(
                    for: window,
                    capturesEscape: modalBehavior.capturesEscape
                )
                overlay.present()
                window.makeFirstResponder(overlay)
            } else {
                overlay.hideImmediately()
            }
        }

        private func restorePreviousFirstResponder(in window: NSWindow) {
            if let previousFirstResponder,
               previousFirstResponder !== overlayView
            {
                window.makeFirstResponder(previousFirstResponder)
            } else {
                window.makeFirstResponder(window.contentView)
            }
            self.previousFirstResponder = nil
        }

        private func reconcileKeyMonitor(for window: NSWindow, capturesEscape: Bool) {
            guard capturesEscape else {
                if let keyMonitor {
                    NSEvent.removeMonitor(keyMonitor)
                    self.keyMonitor = nil
                }
                return
            }
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
            previousFirstResponder = nil
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
    private let behavior: WindowModalBehavior
    private var isModalPresented = false
    var isPresented: Bool { isModalPresented }

    override var acceptsFirstResponder: Bool { true }

    init(
        presentationID: AnyHashable,
        dismiss: @escaping () -> Void,
        didFinishDismissal: @escaping () -> Void,
        behavior: WindowModalBehavior,
        content: (WindowModalAnimationState) -> AnyView
    ) {
        self.presentationID = presentationID
        let animationState = WindowModalAnimationState(
            dismiss: dismiss,
            didFinishDismissal: didFinishDismissal,
            animates: behavior.animates
        )
        self.animationState = animationState
        self.behavior = behavior
        super.init(
            rootView: content(animationState)
        )
        animationState.requestDismissal = { [weak self] commitsPresentation in
            self?.requestDismissal(committingPresentation: commitsPresentation)
        }
        alphaValue = behavior.animates
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1
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
        if behavior.capturesEscape {
            requestDismissal()
        } else {
            super.cancelOperation(sender)
        }
    }

    override func keyDown(with event: NSEvent) {
        if behavior.capturesEscape, WindowModalKeyPolicy.isEscape(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers
        ) {
            requestDismissal()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if behavior.capturesEscape,
           event.type == .keyDown,
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
        guard isModalPresented, bounds.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    func updateDismissCallback(_ dismiss: @escaping () -> Void) {
        animationState.updateDismissCallback(dismiss)
    }

    func present() {
        guard !isModalPresented else { return }
        isModalPresented = true
        isHidden = false
        setAccessibilityHidden(false)
        guard behavior.animates,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            animationState.present()
            alphaValue = 1
            return
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            animationState.present()
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = WindowModalAnimationTiming.openingSeconds
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    func hideImmediately() {
        guard behavior.retainsHostWhenDismissed else {
            requestDismissal(committingPresentation: false)
            return
        }
        cancelPendingDismissal()
        alphaValue = 0
        // Keep the retained instant modal in the render tree so reopening it
        // does not synchronously rebuild and lay out the complete SwiftUI
        // subtree. Hit testing is already disabled while it is dismissed, and
        // both the hosting view and its root content are accessibility-hidden.
        isHidden = false
        isModalPresented = false
        setAccessibilityHidden(true)
        animationState.hideImmediately()
        needsLayout = true
        needsDisplay = true
        AppPerformanceSignposts.reportQuickSwitcherClosed()
    }

    func requestDismissal(committingPresentation: Bool = true) {
        guard animationState.canBeginDismissal else { return }
        if !behavior.animates || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
    private let animates: Bool

    init(
        dismiss: @escaping () -> Void,
        didFinishDismissal: @escaping () -> Void,
        animates: Bool = true
    ) {
        dismissPresentation = dismiss
        self.didFinishDismissal = didFinishDismissal
        self.animates = animates
    }

    func updateDismissCallback(_ dismiss: @escaping () -> Void) {
        dismissPresentation = dismiss
    }

    func dismiss(committingPresentation: Bool) {
        requestDismissal?(committingPresentation)
    }

    fileprivate func present() {
        guard !isVisible, dismissalTask == nil else { return }
        if !animates || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            isVisible = true
        } else {
            withAnimation(.easeOut(duration: WindowModalAnimationTiming.openingSeconds)) {
                isVisible = true
            }
        }
    }

    fileprivate func beginDismissal(committingPresentation: Bool) {
        guard dismissalTask == nil else { return }
        let reduceMotion = !animates || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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

    fileprivate func hideImmediately() {
        dismissalTask?.cancel()
        dismissalTask = nil
        isVisible = false
    }

    func cancelPendingDismissal() {
        dismissalTask?.cancel()
        dismissalTask = nil
    }
}
