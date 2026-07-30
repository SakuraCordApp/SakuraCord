import AppKit
import AVKit
import SwiftUI

struct MediaViewer: View {
    let items: [RichMediaItem]
    @State var selection: Int
    let close: () -> Void
    @State private var imageScale: CGFloat = 1

    init(
        items: [RichMediaItem],
        selection: Int,
        close: @escaping () -> Void
    ) {
        self.items = items
        _selection = State(initialValue: selection)
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(items[selection].title).font(.headline).lineLimit(1)
                Spacer()
                Text("\(selection + 1) of \(items.count)")
                    .foregroundStyle(.secondary)
                ShareLink(item: items[selection].url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share or copy link")
                Link(destination: items[selection].url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open media")
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .buttonStyle(.borderless)
            .padding()
            Divider()
            ZStack {
                Color.black.opacity(0.92)
                viewerContent
                HStack {
                    Button {
                        move(-1)
                    } label: {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.largeTitle)
                    }
                    .disabled(selection == 0)
                    Spacer()
                    Button {
                        move(1)
                    } label: {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.largeTitle)
                    }
                    .disabled(selection == items.count - 1)
                }
                .buttonStyle(.plain)
                .padding()
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onKeyPress(.leftArrow) {
            move(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            move(1)
            return .handled
        }
        .accessibilityLabel(
            """
            \(items[selection].description ?? items[selection].title), \
            item \(selection + 1) of \(items.count)
            """
        )
    }

    @ViewBuilder
    private var viewerContent: some View {
        let item = items[selection]
        switch item.kind {
        case let .image(animated):
            AnimatedRemoteImage(
                url: item.url,
                isLooping: animated
            )
            .scaleEffect(imageScale)
            .gesture(
                MagnifyGesture().onChanged {
                    imageScale = max(
                        0.5,
                        min(6, $0.magnification)
                    )
                }
            )
            .padding(50)
        case .video, .audio:
            ViewerAVPlayer(url: item.url)
                .padding(50)
        case .file:
            Link(destination: item.url) {
                Label("Open \(item.title)", systemImage: "doc")
            }
            .font(.title2)
        }
    }

    private func move(_ delta: Int) {
        selection = min(
            items.count - 1,
            max(0, selection + delta)
        )
        imageScale = 1
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement:
                    "Item \(selection + 1) of \(items.count)"
            ]
        )
    }
}

private struct ViewerAVPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(
        _ view: AVPlayerView,
        context: Context
    ) {
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
