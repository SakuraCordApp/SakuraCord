import AppKit
import Observation
import SwiftUI

/// Media transitions stay feature-owned; window input and lifetime use the shared host.
struct MediaViewerWindowOverlay: View {
    @Environment(\.profileCosmeticPolicy) private var cosmeticPolicy
    let presentation: NativeTimelineMediaViewerPresentation?
    let dismiss: () -> Void

    var body: some View {
        WindowModalOverlay(presentation: presentation, behavior: { _ in .contentAnimated }, dismiss: dismiss, content: { presentation, context in
            MediaViewerWindowAnimatedContent(presentation: presentation, context: context)
                .environment(\.profileCosmeticPolicy, cosmeticPolicy)
        })
    }
}

@MainActor
@Observable
private final class MediaViewerWindowAnimationState {
    private(set) var isVisible = false
    private(set) var transitionSources: [String: MediaViewerTransitionSource] = [:]
    private var reducesMotion = false
    private let sourceItemIDs: Set<String>
    private var selectedItemID: String

    init(presentation: NativeTimelineMediaViewerPresentation) {
        sourceItemIDs = Set(presentation.transitionSources.keys)
        selectedItemID = presentation.items[presentation.selection].id
    }

    private var hasTransitionSource: Bool {
        sourceItemIDs.contains(selectedItemID)
    }

    func select(itemID: String) {
        selectedItemID = itemID
    }

    func setTransitionSources(
        _ sources: [String: MediaViewerTransitionSource]
    ) {
        guard transitionSources.count != sources.count
            || sources.contains(where: { itemID, source in
                guard let previous = transitionSources[itemID] else {
                    return true
                }
                return previous.frameInWindow != source.frameInWindow
                    || previous.visibleFrameInWindow
                        != source.visibleFrameInWindow
            })
        else { return }
        transitionSources = sources
    }

    func present(reducesMotion: Bool) {
        guard !isVisible else { return }
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

    func dismiss(interactively: Bool) -> TimeInterval {
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
        return duration + 0.01
    }
}

private struct MediaViewerWindowAnimatedContent: View {
    let presentation: NativeTimelineMediaViewerPresentation
    let context: WindowModalContext
    @State private var animationState: MediaViewerWindowAnimationState
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    init(presentation: NativeTimelineMediaViewerPresentation, context: WindowModalContext) {
        self.presentation = presentation
        self.context = context
        _animationState = State(initialValue: MediaViewerWindowAnimationState(presentation: presentation))
    }

    var body: some View {
        MediaViewer(
            presentation: presentation,
            isVisible: animationState.isVisible,
            transitionSources: reducesMotion ? [:] : animationState.transitionSources,
            close: { context.dismiss() },
            closeInteractively: { context.dismiss(interactively: true) },
            selectionChanged: { animationState.select(itemID: $0) }
        )
        .background {
            MediaViewerTransitionFrameReader(presentation: presentation, animationState: animationState)
        }
        .onAppear {
            context.dismissalTransition = { [animationState] interactively in
                animationState.dismiss(interactively: interactively)
            }
            Task { @MainActor in
                await Task.yield()
                guard context.isVisible else { return }
                animationState.present(reducesMotion: reducesMotion)
            }
        }
        .onDisappear { context.dismissalTransition = nil }
    }
}

/// Convert the thumbnail source into the same full-window coordinate space used before.
private struct MediaViewerTransitionFrameReader: NSViewRepresentable {
    let presentation: NativeTimelineMediaViewerPresentation
    let animationState: MediaViewerWindowAnimationState

    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) {
        view.sources = presentation.transitionSources
        view.animationState = animationState
        view.resolveFrames()
    }

    final class Reader: NSView {
        var sources: [String: MediaViewerTransitionSource] = [:]
        var animationState: MediaViewerWindowAnimationState?
        private weak var reportedHost: NSView?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolveFrames() }
        override func layout() { super.layout(); resolveFrames() }
        func resolveFrames() {
            var ancestor = superview
            while let view = ancestor {
                if let host = view as? WindowModalHostingView {
                    let resolvedSources = sources.mapValues { source in
                        MediaViewerTransitionSource(
                            itemID: source.itemID,
                            image: source.image,
                            frameInWindow: host.convert(
                                source.frameInWindow,
                                from: nil
                            ),
                            visibleFrameInWindow: host.convert(
                                source.visibleFrameInWindow,
                                from: nil
                            ),
                            cornerRadius: source.cornerRadius,
                            fillsFrame: source.fillsFrame
                        )
                    }
                    animationState?.setTransitionSources(resolvedSources)
                    if reportedHost !== host {
                        reportedHost = host
                        MediaViewerPresentationPerformanceProbe.shared.reportOverlayAttached(to: host)
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
