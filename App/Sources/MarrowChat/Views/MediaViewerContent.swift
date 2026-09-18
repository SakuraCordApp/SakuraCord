import AppKit
import AVKit
import SwiftUI

struct MediaViewerStage: View {
    let item: RichMediaItem
    let previewImage: NSImage?
    let isVisible: Bool
    let transitionSource: MediaViewerTransitionSource?
    let transitionSourceFrame: CGRect?
    let transitionSourceVisibleFrame: CGRect?
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let interaction: MediaViewerInteractionModel
    let finishPinchDismissal: (CGFloat) -> Bool
    let open: () -> Void
    let imageContextMenuActions: MediaImageContextMenuActions?

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
                    transitionSourceFrame: transitionSourceFrame,
                    transitionSourceVisibleFrame:
                        transitionSourceVisibleFrame,
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
            case .audio:
                MediaViewerAudio(title: item.title, url: item.url)
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)
            case .file:
                MediaViewerFile(title: item.title, open: open)
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
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
    let transitionSourceFrame: CGRect?
    let transitionSourceVisibleFrame: CGRect?
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

                if let transitionSource,
                   let transitionSourceFrame,
                   let transitionSourceVisibleFrame
                {
                    MediaViewerTransitionImage(
                        url: url,
                        isAnimated: isAnimated,
                        source: transitionSource,
                        sourceFrame: transitionSourceFrame,
                        sourceVisibleFrame: transitionSourceVisibleFrame,
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
    let sourceFrame: CGRect
    let sourceVisibleFrame: CGRect
    let destinationFrame: CGRect
    let presentationProgress: CGFloat
    let isPresented: Bool
    @State private var presentsRemoteImage: Bool

    init(
        url: URL,
        isAnimated: Bool,
        source: MediaViewerTransitionSource,
        sourceFrame: CGRect,
        sourceVisibleFrame: CGRect,
        destinationFrame: CGRect,
        presentationProgress: CGFloat,
        isPresented: Bool
    ) {
        self.url = url
        self.isAnimated = isAnimated
        self.source = source
        self.sourceFrame = sourceFrame
        self.sourceVisibleFrame = sourceVisibleFrame
        self.destinationFrame = destinationFrame
        self.presentationProgress = presentationProgress
        self.isPresented = isPresented
        _presentsRemoteImage = State(initialValue: isPresented)
    }

    var body: some View {
        let progress = min(1, max(0, presentationProgress))
        let sourceProgress = 1 - progress
        let remoteImageOpacity = remoteImageOpacity(for: progress)
        let clipFrame = interpolatedFrame(
            from: sourceVisibleFrame,
            to: destinationFrame,
            progress: progress
        )
        let sourceImageFrame = MediaViewerLayoutPolicy.imageFrame(
            imageSize: source.image.size,
            in: sourceFrame,
            fillsFrame: source.fillsFrame
        )
        let destinationImageFrame = MediaViewerLayoutPolicy.imageFrame(
            imageSize: source.image.size,
            in: destinationFrame,
            fillsFrame: false
        )
        let imageFrame = interpolatedFrame(
            from: sourceImageFrame,
            to: destinationImageFrame,
            progress: progress
        )
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
                    .aspectRatio(contentMode: .fit)

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
        abs(sourceFrame[keyPath: edge] - sourceVisibleFrame[keyPath: edge])
            < 0.5
    }

    private func interpolatedFrame(
        from source: CGRect,
        to destination: CGRect,
        progress: CGFloat
    ) -> CGRect {
        CGRect(
            x: interpolatedValue(
                from: source.minX,
                to: destination.minX,
                progress: progress
            ),
            y: interpolatedValue(
                from: source.minY,
                to: destination.minY,
                progress: progress
            ),
            width: interpolatedValue(
                from: source.width,
                to: destination.width,
                progress: progress
            ),
            height: interpolatedValue(
                from: source.height,
                to: destination.height,
                progress: progress
            )
        )
    }

    private func interpolatedValue(
        from source: CGFloat,
        to destination: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        source + (destination - source) * progress
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
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled,
                  let view,
                  let observedWindow,
                  event.window === observedWindow,
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

private struct MediaViewerAudio: View {
    let title: String
    let url: URL

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(1)
            ViewerAVPlayer(url: url)
                .frame(height: 74)
        }
        .padding(24)
        .frame(width: 560)
        .glassEffect(
            .regular,
            in: ConcentricRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct MediaViewerFile: View {
    let title: String
    let open: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Button("Open File", systemImage: "arrow.up.forward.app", action: open)
                .buttonStyle(.glassProminent)
        }
        .padding(30)
        .frame(width: 420)
        .glassEffect(
            .regular,
            in: ConcentricRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

struct ViewerAVPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.player?.pause()
        let player = AVPlayer(url: url)
        context.coordinator.url = url
        context.coordinator.player = player
        view.player = player
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
