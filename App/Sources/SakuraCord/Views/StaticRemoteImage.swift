import AppKit
import ImageIO
import OSLog
import QuartzCore
import SwiftUI

struct StaticRemoteImage: NSViewRepresentable {
    nonisolated static let loadPriority = MediaLoadPriority.visible

    let url: URL
    let maximumPixelDimension: Int
    var contentMode: ContentMode = .fit
    var retriesFailedLoads = false

    struct RequestIdentity: Equatable {
        let url: URL
        let maximumPixelDimension: Int
        var retriesFailedLoads = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> StaticRemoteImageView {
        StaticRemoteImageView()
    }

    func updateNSView(
        _ view: StaticRemoteImageView,
        context: Context
    ) {
        view.contentMode = contentMode
        context.coordinator.load(
            RequestIdentity(
                url: url,
                maximumPixelDimension: max(1, maximumPixelDimension),
                retriesFailedLoads: retriesFailedLoads
            ),
            into: view
        )
    }

    static func dismantleNSView(
        _ view: StaticRemoteImageView,
        coordinator: Coordinator
    ) {
        coordinator.cancel()
        view.clear()
    }

    @MainActor
    final class Coordinator {
        private var request: RequestIdentity?
        private var task: Task<Void, Never>?
        private let loadImage: @MainActor (RequestIdentity) async -> CGImage?
        private let wait: @MainActor (Duration) async throws -> Void
        private let retryDelays: [Duration]

        init(
            retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)],
            loadImage: @escaping @MainActor (RequestIdentity) async -> CGImage? = { request in
                await SharedDecodedImageLoader.shared.image(
                    for: request.url,
                    maximumPixelDimension: request.maximumPixelDimension,
                    priority: StaticRemoteImage.loadPriority
                )
            },
            wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        ) {
            self.retryDelays = retryDelays
            self.loadImage = loadImage
            self.wait = wait
        }

        func load(
            _ request: RequestIdentity,
            into view: StaticRemoteImageView
        ) {
            guard self.request != request else { return }
            self.request = request
            task?.cancel()
            if let cached = SharedDecodedImageLoader.shared.cachedImage(
                for: request.url, maximumPixelDimension: request.maximumPixelDimension
            ) {
                view.display(cached)
                return
            }
            view.clear()
            let delays = request.retriesFailedLoads ? retryDelays : []
            let loadImage = loadImage
            let wait = wait
            task = Task { @MainActor [weak self, weak view] in
                for attempt in 0 ... delays.count {
                    guard !Task.isCancelled, self?.request == request, view != nil else { return }
                    let image = await loadImage(request)
                    guard !Task.isCancelled,
                          self?.request == request,
                          let view
                    else { return }
                    if let image {
                        view.display(image)
                        return
                    }
                    guard attempt < delays.count else { break }
                    do {
                        try await wait(delays[attempt])
                    } catch {
                        return
                    }
                }
                // A mounted server icon owns a bounded retry sequence. SwiftUI
                // redraws must not restart that sequence indefinitely. Leaving
                // the viewport dismantles it, so re-entry can try again.
                if !request.retriesFailedLoads {
                    self?.request = nil
                }
            }
        }

#if DEBUG
        var loadTaskForTesting: Task<Void, Never>? { task }

        func waitForLoadForTesting() async {
            await task?.value
        }
#endif

        func cancel() {
            task?.cancel()
            task = nil
            request = nil
        }
    }
}

@MainActor
final class StaticRemoteImageView: NSView {
    var contentMode: ContentMode = .fit {
        didSet { updateContentsGravity() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        updateContentsGravity()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    func display(_ image: CGImage?) {
        layer?.contents = image
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    func clear() {
        layer?.contents = nil
    }

    private func updateContentsGravity() {
        layer?.contentsGravity =
            contentMode == .fill ? .resizeAspectFill : .resizeAspect
    }
}
