import AppKit
import Observation
import SwiftUI

/// Media transitions stay feature-owned; window input and lifetime use the shared host.
struct MediaViewerWindowOverlay: View {
    @Environment(\.profileCosmeticPolicy) private var cosmeticPolicy
    @Environment(VoiceMessagePlaybackStore.self) private var playback
    let presentation: NativeTimelineMediaViewerPresentation?
    /// Read live by the hosted viewer, whose tree outlives this view's updates.
    let animatesOverlays: () -> Bool
    let dismiss: () -> Void
    var selectionChanged: (String) -> Void = { _ in }

    var body: some View {
        WindowModalOverlay(presentation: presentation, behavior: { _ in .contentAnimated }, dismiss: dismiss, content: { [animatesOverlays, selectionChanged] presentation, context in
            MediaViewerWindowAnimatedContent(
                presentation: presentation, context: context,
                animatesOverlays: animatesOverlays, selectionChanged: selectionChanged
            )
                .environment(\.profileCosmeticPolicy, cosmeticPolicy)
                .environment(playback)
        })
    }
}

@MainActor
@Observable
private final class MediaViewerWindowAnimationState {
    private(set) var isVisible = false
    private(set) var transitionSources: [String: MediaViewerTransitionSource] = [:]
    /// Follows the setting while the viewer is up, so its curves, its zoom
    /// and the card it covers always agree.
    var reducesMotion: Bool
    private let sourceItemIDs: Set<String>
    /// Files zoom from a slim card into a large page, which reads only over
    /// a longer, even curve than a photo's snappy one.
    private let fileItemIDs: Set<String>
    private var selectedItemID: String

    init(presentation: NativeTimelineMediaViewerPresentation, reducesMotion: Bool) {
        self.reducesMotion = reducesMotion
        sourceItemIDs = Set(presentation.transitionLink.sources.keys)
        fileItemIDs = Set(presentation.items.filter {
            switch $0.kind {
            case .audio, .text, .file: true
            default: false
            }
        }.map(\.id))
        selectedItemID = presentation.items[presentation.selection].id
    }

    private var hasTransitionSource: Bool {
        sourceItemIDs.contains(selectedItemID)
    }

    private var zoomsFile: Bool {
        hasTransitionSource && fileItemIDs.contains(selectedItemID)
    }

    /// The card the zoom stands in for, which the timeline leaves out.
    var coveredItemID: String? {
        hasTransitionSource && !reducesMotion ? selectedItemID : nil
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
                    || previous.image !== source.image
            })
        else { return }
        transitionSources = sources
    }

    func present() {
        guard !isVisible else { return }
        withAnimation(
            reducesMotion
                ? .easeOut(duration: 0.12)
                : zoomsFile
                    ? .smooth(duration: 0.34)
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
        // A pinch follows the fingers, so only a file closed outright eases.
        let easesFile = zoomsFile && !interactively
        let duration = if reducesMotion {
            0.12
        } else if easesFile {
            0.3
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
                : easesFile
                    ? .smooth(duration: duration)
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
    let selectionChanged: (String) -> Void
    @State private var animationState: MediaViewerWindowAnimationState
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    let animatesOverlays: () -> Bool

    private var reducesMotion: Bool { systemReducesMotion || !animatesOverlays() }
    private var link: MediaViewerTransitionLink { presentation.transitionLink }

    init(
        presentation: NativeTimelineMediaViewerPresentation,
        context: WindowModalContext,
        animatesOverlays: @escaping () -> Bool,
        selectionChanged: @escaping (String) -> Void
    ) {
        self.presentation = presentation
        self.context = context
        self.animatesOverlays = animatesOverlays
        self.selectionChanged = selectionChanged
        _animationState = State(initialValue: MediaViewerWindowAnimationState(
            presentation: presentation, reducesMotion: !animatesOverlays()
        ))
    }

    var body: some View {
        MediaViewer(
            presentation: presentation,
            isVisible: animationState.isVisible,
            transitionSources: animationState.reducesMotion ? [:] : animationState.transitionSources,
            close: { context.dismiss() },
            closeInteractively: { context.dismiss(interactively: true) },
            selectionChanged: {
                animationState.select(itemID: $0)
                selectionChanged($0)
                link.cover(animationState.coveredItemID)
            }
        )
        .background {
            MediaViewerTransitionFrameReader(link: link, animationState: animationState)
        }
        .onAppear {
            context.dismissalTransition = { [animationState] interactively in
                animationState.dismiss(interactively: interactively)
            }
            context.willRemove = { [link] in link.release() }
            animationState.reducesMotion = reducesMotion
            Task { @MainActor in
                await Task.yield()
                guard context.isVisible else { return }
                animationState.present()
                // The zoom now draws over its card, so the card can leave.
                link.cover(animationState.coveredItemID)
            }
        }
        .onChange(of: reducesMotion) { _, reducesMotion in
            animationState.reducesMotion = reducesMotion
            link.cover(animationState.coveredItemID)
        }
        .onDisappear {
            context.dismissalTransition = nil
            context.willRemove = nil
        }
    }
}

/// Reads the timeline's live sources here, so a refresh that moves nothing
/// doesn't re-render the viewer.
private struct MediaViewerTransitionFrameReader: View {
    let link: MediaViewerTransitionLink
    let animationState: MediaViewerWindowAnimationState

    var body: some View {
        MediaViewerTransitionFrameConverter(sources: link.sources, animationState: animationState)
    }
}

/// Convert the thumbnail source into the same full-window coordinate space used before.
private struct MediaViewerTransitionFrameConverter: NSViewRepresentable {
    let sources: [String: MediaViewerTransitionSource]
    let animationState: MediaViewerWindowAnimationState

    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) {
        view.sources = sources
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
                            fillsFrame: source.fillsFrame,
                            coversSource: source.coversSource
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
