import AppKit
import AVKit
import SakuraCordModels
import SwiftUI

struct MediaViewerStage: View {
    let item: RichMediaItem
    /// The message the item belongs to, if any, which an audio file plays as.
    let messageID: MessageID?
    let previewImage: NSImage?
    let isVisible: Bool
    let transitionSource: MediaViewerTransitionSource?
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let interaction: MediaViewerInteractionModel
    let finishPinchDismissal: (CGFloat) -> Bool
    let download: () -> Void
    let imageContextMenuActions: MediaImageContextMenuActions?

    /// The corner radius of a file's preview, player, or page.
    static var contentCornerRadius: CGFloat { InterfaceScale.metric(24) }
    private nonisolated static let space = "MediaViewerStage"
    /// Where a file's content lays out, which its card zooms into.
    @State private var contentFrame: CGRect?

    var body: some View {
        ZStack {
            switch item.kind {
            case let .image(animated):
                MediaViewerZoomableImage(
                    url: item.url,
                    isAnimated: animated,
                    previewImage: previewImage,
                    mediaWidth: item.width,
                    mediaHeight: item.height,
                    isVisible: isVisible,
                    transitionSource: transitionSource,
                    horizontalInset: horizontalInset,
                    topInset: topInset,
                    bottomInset: bottomInset,
                    interaction: interaction,
                    finishPinchDismissal: finishPinchDismissal,
                    contextMenuActions: imageContextMenuActions
                )
            case .video:
                MediaViewerVideo(
                    url: item.url,
                    mediaWidth: item.width,
                    mediaHeight: item.height
                )
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            case let .youtube(playback):
                GeometryReader { proxy in
                    let fittedSize = MediaViewerLayoutPolicy.fittedSize(
                        mediaWidth: item.width ?? 16, mediaHeight: item.height ?? 9,
                        availableSize: proxy.size
                    )
                    if isVisible {
                        YouTubePlayerView(playback: playback, openInBrowser: MediaViewerActionService.openInBrowser)
                            .id(playback)
                            .frame(width: fittedSize.width, height: fittedSize.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            case .audio, .text, .file:
                // Its own container keeps the content's glass under the
                // zoom's fade and clip; the viewer's would draw it regardless.
                GlassEffectContainer { fileContent }
                    .modifier(MediaViewerContainerZoom(
                        progress: isVisible ? 1 - interaction.pinchDismissalProgress : 0,
                        source: transitionSource,
                        destination: contentFrame
                    ))
                    .background {
                        Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                            contentFrame = $0
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(Self.space))
        .clipped()
    }

    @ViewBuilder private var fileContent: some View {
        switch item.kind {
        case .audio:
            let playbackID: VoiceMessagePlaybackID = messageID.map { .attachment($0, attachmentID: item.id) } ?? .file(item.url)
            // Each file is its own player, which another file replaces.
            MediaViewerAudio(item: item, playbackID: playbackID, download: download)
                .id(playbackID)
        case let .text(language):
            MediaViewerText(url: item.url, language: language)
        default:
            MediaViewerFile(item: item, download: download)
        }
    }
}

/// Grows a file's card into the viewer's content and shrinks it back: the
/// card's box moves and resizes into the content's frame, rounding to the
/// content's corners, while the card's snapshot fades into the content.
/// It reads the progress on every frame, which a plain opacity would not.
private struct MediaViewerContainerZoom: ViewModifier, Animatable {
    var progress: CGFloat
    let source: MediaViewerTransitionSource?
    let destination: CGRect?

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let isZooming = source != nil && destination != nil
        let progress = isZooming ? min(max(progress, 0), 1) : 1
        let end = destination ?? .zero
        let box = (source?.frameInWindow ?? end).interpolated(to: end, progress: progress)
        // A card partly scrolled out starts cut to the viewport, in the
        // stage's space, which offsetting the content doesn't move.
        let viewport = progress < 1
            ? (source?.visibleFrameInWindow ?? end).interpolated(to: end, progress: progress)
                .offsetBy(dx: -end.minX, dy: -end.minY)
            : .infinite
        // The box in the content's own space, centred on it as it moves.
        let clip = progress < 1
            ? CGRect(x: (end.width - box.width) / 2, y: (end.height - box.height) / 2, width: box.width, height: box.height)
            : .infinite
        let radius = (source?.cornerRadius ?? 0) * (1 - progress) + MediaViewerStage.contentCornerRadius * progress
        content
            .opacity(Self.smoothstep(progress, from: 0.1, to: 0.6))
            .overlay {
                if let source, progress < 1 {
                    let size = source.frameInWindow.size
                    let scale = min(box.width / max(size.width, 1), box.height / max(size.height, 1))
                    Image(nsImage: source.image)
                        .resizable()
                        .frame(width: size.width * scale, height: size.height * scale)
                        .position(x: clip.midX, y: clip.midY)
                        .opacity(1 - Self.smoothstep(progress, from: 0, to: 0.45))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(MediaViewerZoomClip(rect: clip, cornerRadius: radius))
            .offset(x: box.midX - end.midX, y: box.midY - end.midY)
            .clipShape(MediaViewerZoomClip(rect: viewport, cornerRadius: 0))
    }

    private static func smoothstep(_ value: CGFloat, from lower: CGFloat, to upper: CGFloat) -> CGFloat {
        let fraction = min(max((value - lower) / (upper - lower), 0), 1)
        return fraction * fraction * (3 - 2 * fraction)
    }
}

private nonisolated struct MediaViewerZoomClip: Shape {
    let rect: CGRect
    let cornerRadius: CGFloat

    func path(in bounds: CGRect) -> Path {
        rect.isInfinite ? Path(bounds.insetBy(dx: -10_000, dy: -10_000)) : Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
    }
}
private struct MediaViewerZoomableImage: View {
    let url: URL
    let isAnimated: Bool
    let previewImage: NSImage?
    let mediaWidth: Int?
    let mediaHeight: Int?
    let isVisible: Bool
    let transitionSource: MediaViewerTransitionSource?
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let interaction: MediaViewerInteractionModel
    let finishPinchDismissal: (CGFloat) -> Bool
    let contextMenuActions: MediaImageContextMenuActions?
    @GestureState private var liveMagnification: CGFloat = 1
    @GestureState private var liveTranslation = CGSize.zero

    var body: some View {
        let scale = interaction.scale
        let offset = interaction.offset
        let presentationProgress = isVisible
            ? 1 - interaction.pinchDismissalProgress
            : 0

        GeometryReader { proxy in
            let availableSize = proxy.size
            let restingFrame = MediaViewerLayoutPolicy.restingFrame(
                availableSize: availableSize,
                horizontalInset: horizontalInset,
                topInset: topInset,
                bottomInset: bottomInset
            )
            let fittedSize = MediaViewerLayoutPolicy.fittedSize(
                mediaWidth: mediaWidth,
                mediaHeight: mediaHeight,
                availableSize: restingFrame.size
            )
            let effectiveScale = min(
                MediaViewerInteractionModel.maximumScale,
                max(
                    MediaViewerInteractionModel.minimumScale,
                    scale * liveMagnification
                )
            )
            let proposedOffset = CGSize(
                width: offset.width + liveTranslation.width,
                height: offset.height + liveTranslation.height
            )
            let effectiveOffset = MediaViewerLayoutPolicy.clampedOffset(
                proposedOffset,
                scale: effectiveScale,
                fittedSize: fittedSize,
                availableSize: availableSize
            )
            let transformedFrame = MediaViewerLayoutPolicy.transformedImageFrame(
                restingFrame: restingFrame,
                fittedSize: fittedSize,
                scale: effectiveScale,
                offset: effectiveOffset
            )

            ZStack {
                AnimatedRemoteImage(
                    url: url,
                    isLooping: isAnimated,
                    previewImage: previewImage
                )
                .id(url)
                .frame(width: fittedSize.width, height: fittedSize.height)
                .scaleEffect(effectiveScale)
                .offset(
                    x: restingFrame.midX - availableSize.width / 2
                        + effectiveOffset.width,
                    y: restingFrame.midY - availableSize.height / 2
                        + effectiveOffset.height
                )
                .opacity(transitionSource == nil ? 1 : 0)
                .allowsHitTesting(false)

                if let transitionSource {
                    MediaViewerTransitionImage(
                        url: url,
                        isAnimated: isAnimated,
                        source: transitionSource,
                        destinationFrame: transformedFrame,
                        presentationProgress: presentationProgress,
                        isPresented: isVisible
                    )
                }

                Color.clear
                    .frame(
                        width: transformedFrame.width,
                        height: transformedFrame.height
                    )
                    .contentShape(Rectangle())
                    .position(
                        x: transformedFrame.midX,
                        y: transformedFrame.midY
                    )
                    .gesture(
                        MagnifyGesture()
                            .updating($liveMagnification) { value, state, _ in
                                state = value.magnification
                            }
                            .onChanged { value in
                                guard MediaViewerInteractionModel
                                    .isAtMinimumScale(scale),
                                    value.magnification < 1
                                else {
                                    updatePinchDismissal(magnification: 1)
                                    return
                                }
                                updatePinchDismissal(
                                    magnification: value.magnification
                                )
                            }
                            .onEnded { value in
                                if MediaViewerInteractionModel
                                    .isAtMinimumScale(scale),
                                    value.magnification < 1
                                {
                                    let committed = finishPinchDismissal(
                                        value.magnification
                                    )
                                    if committed {
                                        return
                                    }
                                }
                                interaction.commitScale(
                                    scale * value.magnification
                                )
                                interaction.commitOffset(
                                    MediaViewerLayoutPolicy.clampedOffset(
                                        effectiveOffset,
                                        scale: scale * value.magnification,
                                        fittedSize: fittedSize,
                                        availableSize: availableSize
                                    )
                                )
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 1)
                            .updating($liveTranslation) { value, state, _ in
                                if effectiveScale > 1 {
                                    state = value.translation
                                }
                            }
                            .onEnded { value in
                                let proposed = CGSize(
                                    width: offset.width + value.translation.width,
                                    height: offset.height + value.translation.height
                                )
                                interaction.commitOffset(
                                    MediaViewerLayoutPolicy.clampedOffset(
                                        proposed,
                                        scale: scale,
                                        fittedSize: fittedSize,
                                        availableSize: availableSize
                                    )
                                )
                            }
                    )
                    .onTapGesture(
                        count: 2,
                        perform: interaction.toggleZoom
                    )
                    .accessibilityLabel("Media image")
                    .accessibilityValue(
                        "Zoom \(scale, format: .number.precision(.fractionLength(1))) times"
                    )

                if let contextMenuActions {
                    MediaImageContextMenuBridge(actions: contextMenuActions)
                        .frame(
                            width: transformedFrame.width,
                            height: transformedFrame.height
                        )
                        .position(
                            x: transformedFrame.midX,
                            y: transformedFrame.midY
                        )
                }

                MediaViewerTrackpadPanBridge(
                    isEnabled: effectiveScale
                        > MediaViewerInteractionModel.minimumScale
                ) { scrollingDelta in
                    interaction.commitOffset(
                        MediaViewerLayoutPolicy.offsetByScrolling(
                            offset,
                            scrollingDelta: scrollingDelta,
                            scale: scale,
                            fittedSize: fittedSize,
                            availableSize: availableSize
                        )
                    )
                }
                .allowsHitTesting(false)
            }
            .frame(width: availableSize.width, height: availableSize.height)
        }
    }

    private func updatePinchDismissal(magnification: CGFloat) {
        guard let thresholdChange = interaction.updatePinchDismissal(
            magnification: magnification
        ) else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern =
            switch thresholdChange {
            case .willCommit:
                .alignment
            case .willCancel:
                .levelChange
            }
        NSHapticFeedbackManager.defaultPerformer.perform(
            pattern,
            performanceTime: .drawCompleted
        )
    }
}

private struct MediaViewerTransitionImage: View {
    private static let remoteImageHandoffStartProgress: CGFloat = 0.86
    private static let remoteImageHandoffEndProgress: CGFloat = 0.58

    let url: URL
    let isAnimated: Bool
    let source: MediaViewerTransitionSource
    let destinationFrame: CGRect
    let presentationProgress: CGFloat
    let isPresented: Bool
    @State private var presentsRemoteImage: Bool

    init(
        url: URL,
        isAnimated: Bool,
        source: MediaViewerTransitionSource,
        destinationFrame: CGRect,
        presentationProgress: CGFloat,
        isPresented: Bool
    ) {
        self.url = url
        self.isAnimated = isAnimated
        self.source = source
        self.destinationFrame = destinationFrame
        self.presentationProgress = presentationProgress
        self.isPresented = isPresented
        _presentsRemoteImage = State(initialValue: isPresented)
    }

    var body: some View {
        let progress = min(1, max(0, presentationProgress))
        let sourceProgress = 1 - progress
        let remoteImageOpacity = remoteImageOpacity(for: progress)
        let clipFrame = source.visibleFrameInWindow.interpolated(to: destinationFrame, progress: progress)
        let sourceImageFrame = MediaViewerLayoutPolicy.imageFrame(
            imageSize: source.image.size,
            in: source.frameInWindow,
            fillsFrame: source.fillsFrame
        )
        let destinationImageFrame = MediaViewerLayoutPolicy.imageFrame(
            imageSize: source.image.size,
            in: destinationFrame,
            fillsFrame: false
        )
        let imageFrame = sourceImageFrame.interpolated(to: destinationImageFrame, progress: progress)
        let cornerRadii = RectangleCornerRadii(
            topLeading: sharesEdge(\.minX) && sharesEdge(\.minY)
                ? source.cornerRadius * sourceProgress
                : 0,
            bottomLeading: sharesEdge(\.minX) && sharesEdge(\.maxY)
                ? source.cornerRadius * sourceProgress
                : 0,
            bottomTrailing: sharesEdge(\.maxX) && sharesEdge(\.maxY)
                ? source.cornerRadius * sourceProgress
                : 0,
            topTrailing: sharesEdge(\.maxX) && sharesEdge(\.minY)
                ? source.cornerRadius * sourceProgress
                : 0
        )

        ZStack {
            ZStack {
                Image(nsImage: source.image)
                    .resizable()
                    .scaledToFit()

                if presentsRemoteImage {
                    AnimatedRemoteImage(
                        url: url,
                        isLooping: isAnimated,
                        contentMode: .fit
                    )
                    .opacity(remoteImageOpacity)
                    .transition(.opacity)
                }
            }
            .frame(width: imageFrame.width, height: imageFrame.height)
            .position(
                x: imageFrame.midX - clipFrame.minX,
                y: imageFrame.midY - clipFrame.minY
            )
        }
        .frame(width: clipFrame.width, height: clipFrame.height)
        .clipShape(UnevenRoundedRectangle(cornerRadii: cornerRadii))
        .position(x: clipFrame.midX, y: clipFrame.midY)
        .allowsHitTesting(false)
        .task(id: isPresented) {
            guard isPresented, !presentsRemoteImage else { return }
            try? await Task.sleep(
                for: .seconds(
                    MediaViewerTransitionTiming.presentationDuration
                )
            )
            guard !Task.isCancelled else { return }
            withAnimation(
                .easeOut(
                    duration:
                        MediaViewerTransitionTiming.remoteImageFadeDuration
                )
            ) {
                presentsRemoteImage = true
            }
        }
    }

    private func sharesEdge(
        _ edge: KeyPath<CGRect, CGFloat>
    ) -> Bool {
        abs(
            source.frameInWindow[keyPath: edge]
                - source.visibleFrameInWindow[keyPath: edge]
        ) < 0.5
    }

    private func remoteImageOpacity(for progress: CGFloat) -> CGFloat {
        let normalizedProgress = min(
            1,
            max(
                0,
                (progress - Self.remoteImageHandoffEndProgress)
                    / (
                        Self.remoteImageHandoffStartProgress
                            - Self.remoteImageHandoffEndProgress
                    )
            )
        )
        return normalizedProgress * normalizedProgress
            * (3 - 2 * normalizedProgress)
    }
}

private struct MediaViewerTrackpadPanBridge: NSViewRepresentable {
    let isEnabled: Bool
    let pan: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, pan: pan)
    }

    func makeNSView(context: Context) -> TrackpadPanView {
        let view = TrackpadPanView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: TrackpadPanView, context: Context) {
        context.coordinator.update(isEnabled: isEnabled, pan: pan)
    }

    static func dismantleNSView(
        _ view: TrackpadPanView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
        view.windowChanged = nil
    }

    @MainActor
    final class Coordinator {
        private weak var view: TrackpadPanView?
        private weak var observedWindow: NSWindow?
        private var eventMonitor: Any?
        private var isEnabled: Bool
        private var pan: (CGSize) -> Void

        init(isEnabled: Bool, pan: @escaping (CGSize) -> Void) {
            self.isEnabled = isEnabled
            self.pan = pan
        }

        func attach(to view: TrackpadPanView) {
            self.view = view
            view.windowChanged = { [weak self] window in
                self?.windowDidChange(window)
            }
        }

        func update(isEnabled: Bool, pan: @escaping (CGSize) -> Void) {
            self.isEnabled = isEnabled
            self.pan = pan
        }

        func detach() {
            removeEventMonitor()
            view = nil
            observedWindow = nil
        }

        private func windowDidChange(_ window: NSWindow?) {
            guard observedWindow !== window else { return }
            removeEventMonitor()
            observedWindow = window
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .scrollWheel
            ) { [weak self] event in
                guard let self else { return event }
                return handle(event)
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled,
                  let view,
                  WindowModalCoordinator.allowsInput(for: view),
                  let observedWindow,
                  event.window === observedWindow,
                  WindowModalCoordinator.coordinator(for: observedWindow).allowsScroll(phase: event.phase, momentumPhase: event.momentumPhase),
                  view.bounds.contains(
                      view.convert(event.locationInWindow, from: nil)
                  )
            else { return event }
            let delta = CGSize(
                width: event.scrollingDeltaX,
                height: event.scrollingDeltaY
            )
            guard delta != .zero else { return event }
            pan(delta)
            return nil
        }

        private func removeEventMonitor() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }
    }
}

@MainActor
private final class TrackpadPanView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}

private struct MediaViewerVideo: View {
    let url: URL
    let mediaWidth: Int?
    let mediaHeight: Int?

    var body: some View {
        GeometryReader { proxy in
            let fittedSize = MediaViewerLayoutPolicy.fittedSize(
                mediaWidth: mediaWidth ?? 16,
                mediaHeight: mediaHeight ?? 9,
                availableSize: proxy.size
            )
            ViewerAVPlayer(url: url)
                .frame(width: fittedSize.width, height: fittedSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ViewerAVPlayer: NSViewRepresentable {
    let url: URL
    var autoplays = false
    var mutesOnStart = false
    var showsFullScreenToggleButton = false

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = showsFullScreenToggleButton
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.showsFullScreenToggleButton = showsFullScreenToggleButton
        guard context.coordinator.url != url else { return }
        context.coordinator.player?.pause()
        let player = AVPlayer(url: url)
        player.isMuted = mutesOnStart
        context.coordinator.url = url
        context.coordinator.player = player
        view.player = player
        if autoplays { player.play() }
    }

    static func dismantleNSView(
        _ view: AVPlayerView,
        coordinator: Coordinator
    ) {
        coordinator.player?.pause()
        view.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var url: URL?
        var player: AVPlayer?
    }
}

private extension CGRect {
    /// This frame moved and resized `progress` of the way to `target`.
    func interpolated(to target: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: minX + (target.minX - minX) * progress,
            y: minY + (target.minY - minY) * progress,
            width: width + (target.width - width) * progress,
            height: height + (target.height - height) * progress
        )
    }
}
