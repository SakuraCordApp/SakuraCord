import AppKit
import Observation
import SwiftUI

/// Installs the viewer above the window frame hierarchy so SwiftUI toolbar
/// items cannot render or receive events over the modal surface.
struct MediaViewerWindowOverlay: NSViewRepresentable {
    let presentation: NativeTimelineMediaViewerPresentation?
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MediaViewerWindowAttachmentView {
        let view = MediaViewerWindowAttachmentView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(
        _ view: MediaViewerWindowAttachmentView,
        context: Context
    ) {
        context.coordinator.update(
            presentation: presentation,
            dismiss: dismiss
        )
    }

    static func dismantleNSView(
        _ view: MediaViewerWindowAttachmentView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
        view.windowChanged = nil
    }

    @MainActor
    final class Coordinator {
        private weak var attachmentView: MediaViewerWindowAttachmentView?
        private weak var presentationWindow: NSWindow?
        private var overlayView: MediaViewerWindowHostingView?
        private var presentation: NativeTimelineMediaViewerPresentation?
        private var dismiss: (() -> Void)?
        private var keyMonitor: Any?

        func attach(to view: MediaViewerWindowAttachmentView) {
            attachmentView = view
            view.windowChanged = { [weak self] window in
                self?.windowDidChange(window)
            }
        }

        func update(
            presentation: NativeTimelineMediaViewerPresentation?,
            dismiss: @escaping () -> Void
        ) {
            self.presentation = presentation
            self.dismiss = dismiss
            reconcileOverlay()
        }

        func detach() {
            presentation = nil
            dismiss = nil
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
                  let window = attachmentView?.window ?? presentationWindow,
                  let container = window.contentView?.superview
                      ?? window.contentView
            else {
                overlayView?.requestDismissal(committingPresentation: false)
                return
            }

            if overlayView?.presentationID == presentation.id,
               overlayView?.superview === container
            {
                installKeyMonitorIfNeeded(for: window)
                return
            }

            removeOverlay()
            presentationWindow = window
            let overlay = MediaViewerWindowHostingView(
                presentationID: presentation.id,
                presentation: presentation,
                dismiss: dismiss,
                didFinishDismissal: { [weak self] in
                    self?.removeOverlay()
                }
            )
            overlay.frame = container.bounds
            overlay.autoresizingMask = [.width, .height]
            overlay.wantsLayer = true
            overlay.layer?.zPosition = 100_000
            container.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlayView = overlay
            installKeyMonitorIfNeeded(for: window)
            window.makeFirstResponder(overlay)
        }

        private func installKeyMonitorIfNeeded(for window: NSWindow) {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self, weak window] event in
                guard event.keyCode == 53,
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
            overlayView?.removeFromSuperview()
            overlayView = nil
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
    }
}

@MainActor
final class MediaViewerWindowAttachmentView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}

@MainActor
final class MediaViewerWindowHostingView: NSHostingView<AnyView> {
    let presentationID: UUID
    private let animationState: MediaViewerWindowAnimationState

    override var acceptsFirstResponder: Bool { true }

    init(
        presentationID: UUID,
        presentation: NativeTimelineMediaViewerPresentation,
        dismiss: @escaping () -> Void,
        didFinishDismissal: @escaping () -> Void
    ) {
        self.presentationID = presentationID
        let animationState = MediaViewerWindowAnimationState(
            dismiss: dismiss,
            didFinishDismissal: didFinishDismissal
        )
        self.animationState = animationState
        super.init(
            rootView: AnyView(
                MediaViewerWindowAnimatedContent(
                    presentation: presentation,
                    animationState: animationState
                )
            )
        )
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
        if event.keyCode == 53 {
            requestDismissal()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
            requestDismissal()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func requestDismissal(committingPresentation: Bool = true) {
        animationState.dismiss(
            committingPresentation: committingPresentation
        )
    }
}

@MainActor
@Observable
private final class MediaViewerWindowAnimationState {
    private(set) var isVisible = false
    private var dismissalTask: Task<Void, Never>?
    private let dismissPresentation: () -> Void
    private let didFinishDismissal: () -> Void

    init(
        dismiss: @escaping () -> Void,
        didFinishDismissal: @escaping () -> Void
    ) {
        dismissPresentation = dismiss
        self.didFinishDismissal = didFinishDismissal
    }

    func present() {
        guard !isVisible, dismissalTask == nil else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            isVisible = true
        }
    }

    func dismiss(committingPresentation: Bool) {
        guard dismissalTask == nil else { return }
        withAnimation(.easeIn(duration: 0.16)) {
            isVisible = false
        }
        dismissalTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled else { return }
            if committingPresentation {
                dismissPresentation()
            }
            didFinishDismissal()
        }
    }
}

private struct MediaViewerWindowAnimatedContent: View {
    let presentation: NativeTimelineMediaViewerPresentation
    let animationState: MediaViewerWindowAnimationState

    var body: some View {
        MediaViewer(
            presentation: presentation,
            isVisible: animationState.isVisible,
            close: { animationState.dismiss(committingPresentation: true) }
        )
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                animationState.present()
            }
        }
    }
}
