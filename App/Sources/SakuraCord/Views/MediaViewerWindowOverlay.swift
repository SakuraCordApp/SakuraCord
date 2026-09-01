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
                    self?.removeOverlay(ifPresentationID: presentation.id)
                }
            )
            overlay.frame = container.bounds
            overlay.autoresizingMask = [.width, .height]
            overlay.wantsLayer = true
            overlay.layer?.zPosition = 100_000
            container.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlayView = overlay
            overlay.resolveTransitionSourceFrame()
            MediaViewerPresentationPerformanceProbe.shared
                .reportOverlayAttached(to: overlay)
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

        private func removeOverlay(ifPresentationID presentationID: UUID) {
            guard overlayView?.presentationID == presentationID else { return }
            removeOverlay()
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
    private let transitionSourceFrameInWindow: CGRect?
    private let transitionSourceVisibleFrameInWindow: CGRect?

    override var acceptsFirstResponder: Bool { true }

    init(
        presentationID: UUID,
        presentation: NativeTimelineMediaViewerPresentation,
        dismiss: @escaping () -> Void,
        didFinishDismissal: @escaping () -> Void
    ) {
        self.presentationID = presentationID
        transitionSourceFrameInWindow =
            presentation.transitionSource?.frameInWindow
        transitionSourceVisibleFrameInWindow =
            presentation.transitionSource?.visibleFrameInWindow
        let animationState = MediaViewerWindowAnimationState(
            hasTransitionSource: presentation.transitionSource != nil,
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

    override func layout() {
        super.layout()
        resolveTransitionSourceFrame()
    }

    func resolveTransitionSourceFrame() {
        animationState.setTransitionSourceFrames(
            frame: transitionSourceFrameInWindow.map {
                convert($0, from: nil)
            },
            visibleFrame: transitionSourceVisibleFrameInWindow.map {
                convert($0, from: nil)
            }
        )
    }

    func requestDismissal(
        committingPresentation: Bool = true,
        interactively: Bool = false
    ) {
        animationState.dismiss(
            committingPresentation: committingPresentation,
            interactively: interactively
        )
    }

}

@MainActor
@Observable
private final class MediaViewerWindowAnimationState {
    private(set) var isVisible = false
    private(set) var transitionSourceFrame: CGRect?
    private(set) var transitionSourceVisibleFrame: CGRect?
    private var dismissalTask: Task<Void, Never>?
    private var reducesMotion = false
    private let hasTransitionSource: Bool
    private let dismissPresentation: () -> Void
    private let didFinishDismissal: () -> Void

    init(
        hasTransitionSource: Bool,
        dismiss: @escaping () -> Void,
        didFinishDismissal: @escaping () -> Void
    ) {
        self.hasTransitionSource = hasTransitionSource
        dismissPresentation = dismiss
        self.didFinishDismissal = didFinishDismissal
    }

    func setTransitionSourceFrames(
        frame: CGRect?,
        visibleFrame: CGRect?
    ) {
        guard transitionSourceFrame != frame
                || transitionSourceVisibleFrame != visibleFrame
        else { return }
        transitionSourceFrame = frame
        transitionSourceVisibleFrame = visibleFrame
    }

    func present(reducesMotion: Bool) {
        guard !isVisible, dismissalTask == nil else { return }
        self.reducesMotion = reducesMotion
        withAnimation(
            reducesMotion
                ? .easeOut(duration: 0.12)
                : hasTransitionSource
                    ? .snappy(
                        duration:
                            MediaViewerTransitionTiming.presentationDuration,
                        extraBounce: 0.02
                    )
                    : .easeOut(
                        duration:
                            MediaViewerTransitionTiming.presentationDuration
                    )
        ) {
            isVisible = true
        }
        MediaViewerPresentationPerformanceProbe.shared
            .reportAnimationTransactionStarted()
    }

    func dismiss(
        committingPresentation: Bool,
        interactively: Bool = false
    ) {
        guard dismissalTask == nil else { return }
        let duration = if reducesMotion {
            0.12
        } else if hasTransitionSource {
            interactively
                ? MediaViewerTransitionTiming.interactiveDismissalDuration
                : 0.18
        } else {
            interactively
                ? MediaViewerTransitionTiming.interactiveDismissalDuration
                : 0.16
        }
        withAnimation(
            reducesMotion
                ? .easeIn(duration: duration)
                : hasTransitionSource
                    ? interactively
                        ? .snappy(duration: duration, extraBounce: 0.01)
                        : .snappy(duration: duration)
                    : interactively
                        ? .easeInOut(duration: duration)
                        : .easeIn(duration: duration)
        ) {
            isVisible = false
        }
        dismissalTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.01))
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
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        MediaViewer(
            presentation: presentation,
            isVisible: animationState.isVisible,
            transitionSourceFrame: reducesMotion
                ? nil
                : animationState.transitionSourceFrame,
            transitionSourceVisibleFrame: reducesMotion
                ? nil
                : animationState.transitionSourceVisibleFrame,
            close: {
                animationState.dismiss(committingPresentation: true)
            },
            closeInteractively: {
                animationState.dismiss(
                    committingPresentation: true,
                    interactively: true
                )
            }
        )
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                animationState.present(reducesMotion: reducesMotion)
            }
        }
    }
}
