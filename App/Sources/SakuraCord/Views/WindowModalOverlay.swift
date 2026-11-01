import AppKit
import Observation
import QuartzCore
import SwiftUI

nonisolated enum WindowModalAnimationTiming {
    static let openingSeconds = 0.22
    static let closingSeconds = 0.16
    static let removalDelayMilliseconds = 170
}

nonisolated enum WindowModalVisualStyle {
    static let standardBackdropOpacity = 0.70
    static let mediaViewerBackgroundDimmingOpacity = 0.91
}

nonisolated struct WindowModalBehavior: Sendable {
    var animates: Bool
    var capturesEscape: Bool
    var retainsHostWhenDismissed: Bool = false
    var contentOwnsAnimation: Bool = false

    static let contentAnimated = WindowModalBehavior(animates: false, capturesEscape: true, contentOwnsAnimation: true)

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
    let behavior: (Presentation) -> WindowModalBehavior
    let dismiss: () -> Void
    @ViewBuilder let content: (
        Presentation,
        WindowModalContext
    ) -> Content

    init(
        presentation: Presentation?,
        preloadedPresentation: Presentation? = nil,
        behavior: @escaping (Presentation) -> WindowModalBehavior = { _ in .standard },
        dismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping (
            Presentation,
            WindowModalContext
        ) -> Content
    ) {
        self.presentation = presentation
        self.preloadedPresentation = preloadedPresentation
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
        private var behavior: ((Presentation) -> WindowModalBehavior)?
        private var dismiss: (() -> Void)?
        private var content: ((Presentation, WindowModalContext) -> Content)?

        func attach(to view: WindowModalAttachmentView) {
            attachmentView = view
            view.windowChanged = { [weak self] window in
                self?.windowDidChange(window)
            }
        }

        func update(
            presentation: Presentation?,
            preloadedPresentation: Presentation?,
            behavior: @escaping (Presentation) -> WindowModalBehavior,
            dismiss: @escaping () -> Void,
            content: @escaping (Presentation, WindowModalContext) -> Content
        ) {
            self.presentation = presentation
            self.preloadedPresentation = preloadedPresentation
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
                        overlayView.present()
                    }
                } else {
                    if overlayView.isPresented {
                        overlayView.hideImmediately()
                    }
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
            container.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlayView = overlay
            if isPresented {
                overlay.present()
            } else {
                overlay.hideImmediately()
            }
        }

        private func removeOverlay() {
            overlayView?.cancelPendingDismissal()
            overlayView?.unregisterInput()
            overlayView?.removeFromSuperview()
            overlayView = nil

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
    let animationState: WindowModalContext
    private let behavior: WindowModalBehavior
    private let reducesMotion: Bool
    private var isModalPresented = false
    var isPresented: Bool { isModalPresented }
    var isDismissing: Bool { !animationState.canBeginDismissal }

    var capturesEscape: Bool { behavior.capturesEscape }
    var isTopmostPresentedOverlay: Bool {
        guard isPresented, let window else { return false }
        return WindowModalCoordinator.coordinator(for: window).topmost === self
    }

    func unregisterInput() {
        isModalPresented = false
        guard let window else { return }
        WindowModalCoordinator.coordinator(for: window).remove(self)
    }

    override var acceptsFirstResponder: Bool { true }

    init(
        presentationID: AnyHashable,
        dismiss: @escaping () -> Void,
        didFinishDismissal: @escaping () -> Void,
        behavior: WindowModalBehavior,
        content: (WindowModalContext) -> AnyView
    ) {
        self.presentationID = presentationID
        let reducesMotion = !AppMotionPolicy.animates(.overlays)
        self.reducesMotion = reducesMotion
        let animationState = WindowModalContext(
            dismiss: dismiss,
            didFinishDismissal: didFinishDismissal,
            animates: behavior.animates,
            reducesMotion: reducesMotion
        )
        self.animationState = animationState
        self.behavior = behavior
        super.init(
            rootView: AnyView(WindowModalHostedContent(context: animationState, content: content(animationState)))
        )
        animationState.requestDismissal = { [weak self] commitsPresentation, interactively in
            self?.requestDismissal(committingPresentation: commitsPresentation, interactively: interactively)
        }
        alphaValue = behavior.animates && !reducesMotion ? 0 : 1
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
        if behavior.capturesEscape, isTopmostPresentedOverlay {
            animationState.handleEscape()
        } else {
            super.cancelOperation(sender)
        }
    }

    override func keyDown(with event: NSEvent) {
        if behavior.capturesEscape, isTopmostPresentedOverlay, KeyboardShortcutPolicy.isPlainEscape(
            keyCode: event.keyCode, modifierFlags: event.modifierFlags,
            characters: event.charactersIgnoringModifiers
        ) {
            animationState.handleEscape()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if behavior.capturesEscape,
           isTopmostPresentedOverlay,
           event.type == .keyDown,
           KeyboardShortcutPolicy.isPlainEscape(
               keyCode: event.keyCode, modifierFlags: event.modifierFlags,
               characters: event.charactersIgnoringModifiers
           )
        {
            animationState.handleEscape()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isTopmostPresentedOverlay, bounds.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    // Keep NSHostingView's wheel handling intact, including SwiftUI's elastic
    // scrolling. The full-window hit-test surface and WindowModalCoordinator
    // already isolate the covered workspace and reject inherited momentum.

    func updateDismissCallback(_ dismiss: @escaping () -> Void) {
        animationState.updateDismissCallback(dismiss)
    }

    func present() {
        // A closing modal has let go of input, but it is not reopened.
        guard !isModalPresented, !isDismissing else { return }
        isModalPresented = true
        isHidden = false
        setAccessibilityHidden(false)
        if let window { WindowModalCoordinator.coordinator(for: window).present(self) }
        guard behavior.animates,
              !reducesMotion
        else {
            animationState.present()
            alphaValue = 1
            return
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, isModalPresented, superview != nil, animationState.canBeginDismissal else { return }
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
        unregisterInput()
        setAccessibilityHidden(true)
        animationState.hideImmediately()
        needsLayout = true
        needsDisplay = true
        AppPerformanceSignposts.reportQuickSwitcherClosed()
    }

    func requestDismissal(committingPresentation: Bool = true, interactively: Bool = false) {
        guard animationState.canBeginDismissal, !committingPresentation || !animationState.preventsDismissal else { return }
        if behavior.contentOwnsAnimation {
            // The media viewer supplies its existing transition and completion delay.
        } else if !behavior.animates || reducesMotion {
            alphaValue = 0
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WindowModalAnimationTiming.closingSeconds
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
            }
        }
        animationState.beginDismissal(committingPresentation: committingPresentation, interactively: interactively)
        // A closing modal gives up the window's input at once, so what it
        // covered takes every click, key and gesture as it animates away.
        isModalPresented = false
        if let window { WindowModalCoordinator.coordinator(for: window).remove(self) }
    }

    func cancelPendingDismissal() {
        animationState.cancelPendingDismissal()
    }
}

@MainActor
@Observable
final class WindowModalContext {
    var isInputActive = false
    var preventsDismissal = false
    /// Starts a feature-owned closing transition and returns its removal delay.
    var dismissalTransition: ((Bool) -> TimeInterval)?
    /// Runs as the host leaves the window, in the same transaction, so what
    /// the modal stood in for returns in the frame the modal leaves.
    var willRemove: (() -> Void)?
    var escapeAction: (() -> Void)?
    fileprivate var requestDismissal: ((Bool, Bool) -> Void)?
    private(set) var isVisible = false
    private var dismissalTask: Task<Void, Never>?
    private var dismissPresentation: () -> Void
    private let didFinishDismissal: () -> Void
    private let animates: Bool
    private let reducesMotion: Bool

    init(
        dismiss: @escaping () -> Void,
        didFinishDismissal: @escaping () -> Void,
        animates: Bool = true,
        reducesMotion: Bool = false
    ) {
        dismissPresentation = dismiss
        self.didFinishDismissal = didFinishDismissal
        self.animates = animates
        self.reducesMotion = reducesMotion
    }

    func updateDismissCallback(_ dismiss: @escaping () -> Void) {
        dismissPresentation = dismiss
    }

    func dismiss(committingPresentation: Bool = true, interactively: Bool = false) {
        requestDismissal?(committingPresentation, interactively)
    }

    func callAsFunction(allowsDisabled: Bool = false) {
        if allowsDisabled { preventsDismissal = false }
        dismiss()
    }

    func handleEscape() {
        if let escapeAction { escapeAction() } else { dismiss(committingPresentation: true) }
    }

    fileprivate func present() {
        guard !isVisible, dismissalTask == nil else { return }
        if !animates || reducesMotion {
            isVisible = true
        } else {
            withAnimation(.easeOut(duration: WindowModalAnimationTiming.openingSeconds)) {
                isVisible = true
            }
        }
    }

    fileprivate func beginDismissal(committingPresentation: Bool, interactively: Bool) {
        guard dismissalTask == nil else { return }
        let customDelay = dismissalTransition?(interactively)
        let reduceMotion = !animates || self.reducesMotion
        if reduceMotion {
            isVisible = false
        } else {
            withAnimation(.easeIn(duration: WindowModalAnimationTiming.closingSeconds)) {
                isVisible = false
            }
        }
        dismissalTask = Task { @MainActor in
            let delay = customDelay ?? (reduceMotion ? 0 : Double(WindowModalAnimationTiming.removalDelayMilliseconds) / 1_000)
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            willRemove?()
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

private struct WindowModalHostedContent: View {
    let context: WindowModalContext
    let content: AnyView

    var body: some View {
        content
            .interfaceScaleRoot()
            .environment(\.windowModalInputAllowed, context.isInputActive)
            .allowsHitTesting(context.isInputActive)
            .accessibilityHidden(!context.isInputActive)
    }
}
