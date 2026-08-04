import AppKit
import AVKit
import SwiftUI

struct MediaViewerStage: View {
    let item: RichMediaItem
    let scale: CGFloat
    let offset: CGSize
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let commitScale: (CGFloat) -> Void
    let commitOffset: (CGSize) -> Void
    let toggleZoom: () -> Void
    let open: () -> Void
    let imageContextMenuActions: MediaImageContextMenuActions?

    var body: some View {
        ZStack {
            switch item.kind {
            case let .image(animated):
                MediaViewerZoomableImage(
                    url: item.url,
                    isAnimated: animated,
                    mediaWidth: item.width,
                    mediaHeight: item.height,
                    scale: scale,
                    offset: offset,
                    horizontalInset: horizontalInset,
                    topInset: topInset,
                    bottomInset: bottomInset,
                    commitScale: commitScale,
                    commitOffset: commitOffset,
                    toggleZoom: toggleZoom,
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
    let mediaWidth: Int?
    let mediaHeight: Int?
    let scale: CGFloat
    let offset: CGSize
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let commitScale: (CGFloat) -> Void
    let commitOffset: (CGSize) -> Void
    let toggleZoom: () -> Void
    let contextMenuActions: MediaImageContextMenuActions?
    @GestureState private var liveMagnification: CGFloat = 1
    @GestureState private var liveTranslation = CGSize.zero

    var body: some View {
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
                    fallbackSystemImage: "photo",
                    fallbackInset: 24
                )
                .frame(width: fittedSize.width, height: fittedSize.height)
                .scaleEffect(effectiveScale)
                .offset(
                    x: restingFrame.midX - availableSize.width / 2
                        + effectiveOffset.width,
                    y: restingFrame.midY - availableSize.height / 2
                        + effectiveOffset.height
                )
                .allowsHitTesting(false)

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
                            .onEnded { value in
                                commitScale(scale * value.magnification)
                                commitOffset(
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
                                commitOffset(
                                    MediaViewerLayoutPolicy.clampedOffset(
                                        proposed,
                                        scale: scale,
                                        fittedSize: fittedSize,
                                        availableSize: availableSize
                                    )
                                )
                            }
                    )
                    .onTapGesture(count: 2, perform: toggleZoom)
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
                    commitOffset(
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
