import AppKit
import Lottie

@MainActor
final class NativeTimelineLottieStickerOverlay: NSView {
    let animationView = LottieAnimationView()
    let progressIndicator = NSProgressIndicator()
    var loadingTask: Task<Void, Never>?
    var url: URL?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .loop
        animationView.isHidden = true
        addSubview(animationView)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.startAnimation(nil)
        addSubview(progressIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        animationView.frame = bounds
        animationView.needsLayout = true
        animationView.layoutSubtreeIfNeeded()
        let spinnerSize = progressIndicator.fittingSize
        progressIndicator.frame = CGRect(
            x: (bounds.width - spinnerSize.width) / 2,
            y: (bounds.height - spinnerSize.height) / 2,
            width: spinnerSize.width,
            height: spinnerSize.height
        )
    }

    func display(_ url: URL, reduceMotion: Bool) {
        if self.url != url {
            stop()
            self.url = url
            animationView.isHidden = true
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            loadingTask = Task { @MainActor [weak self] in
                let animation = await SharedTimelineLottieAnimationLoader
                    .shared.animation(for: url)
                guard !Task.isCancelled,
                      let self,
                      self.url == url
                else { return }
                self.loadingTask = nil
                self.animationView.animation = animation
                self.animationView.isHidden = animation == nil
                self.progressIndicator.isHidden = animation != nil
                self.updatePlayback(reduceMotion: reduceMotion)
            }
        } else {
            updatePlayback(reduceMotion: reduceMotion)
        }
    }

    func updatePlayback(reduceMotion: Bool) {
        animationView.loopMode = .loop
        guard animationView.animation != nil else { return }
        if reduceMotion {
            animationView.pause()
            animationView.currentProgress = 0
        } else if !animationView.isAnimationPlaying {
            animationView.play()
        }
    }

    func stop() {
        loadingTask?.cancel()
        loadingTask = nil
        animationView.stop()
        animationView.animation = nil
        url = nil
    }

    deinit {
        loadingTask?.cancel()
    }
}

nonisolated enum TimelineLottieLoadingPolicy {
    static let maximumCachedAnimations = 12
    static let maximumConcurrentParses = 1
}

actor SharedTimelineLottieAnimationLoader {
    static let shared = SharedTimelineLottieAnimationLoader()

    typealias DataLoader = @Sendable (URL) async throws -> Data

    private let cache: DefaultAnimationCache = {
        let cache = DefaultAnimationCache()
        cache.cacheSize = TimelineLottieLoadingPolicy.maximumCachedAnimations
        return cache
    }()
    private var inFlight: [URL: Task<LottieAnimation?, Never>] = [:]
    private var isParsing = false
    private struct ParseWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var parseWaiters: [ParseWaiter] = []
    private let loadData: DataLoader

    init(
        loadData: @escaping DataLoader = { url in
            try await SharedMediaDataLoader.shared.data(
                for: url,
                priority: .visible
            )
        }
    ) {
        self.loadData = loadData
    }

    func animation(for url: URL) async -> LottieAnimation? {
        if let cached = cache.animation(forKey: url.absoluteString) {
            return cached
        }
        if let task = inFlight[url] {
            return await task.value
        }
        let task = Task<LottieAnimation?, Never> { [weak self] in
            guard let self else { return nil }
            let data = try? await self.loadData(url)
            guard let data, !Task.isCancelled,
                  await self.acquireParseLane()
            else { return nil }
            guard !Task.isCancelled else {
                await self.releaseParseLane()
                return nil
            }
            let animation = try? LottieAnimation.from(data: data)
            if let animation {
                self.cache.setAnimation(
                    animation,
                    forKey: url.absoluteString
                )
            }
            await self.releaseParseLane()
            return animation
        }
        inFlight[url] = task
        let animation = await task.value
        inFlight[url] = nil
        return animation
    }

    private func acquireParseLane() async -> Bool {
        if Task.isCancelled {
            return false
        }
        if !isParsing {
            isParsing = true
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                parseWaiters.append(
                    ParseWaiter(
                        id: waiterID,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancelParseWaiter(waiterID)
            }
        }
    }

    private func cancelParseWaiter(_ id: UUID) {
        guard let index = parseWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        parseWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func releaseParseLane() {
        if !parseWaiters.isEmpty {
            parseWaiters.removeFirst().continuation.resume(returning: true)
        } else {
            isParsing = false
        }
    }
}
