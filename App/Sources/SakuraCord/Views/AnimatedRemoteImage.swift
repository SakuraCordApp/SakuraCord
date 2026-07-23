import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import WebKit

/// Displays remote GIF/APNG/WebP assets without flattening them to their first frame.
struct AnimatedRemoteImage: View {
    private struct LoadID: Hashable {
        let url: URL
        let maximumPixelDimension: Int?
    }

    let url: URL
    var animates = true
    var isLooping = true
    var fallbackSystemImage: String?
    var fallbackInset: CGFloat = 2
    var maximumPixelDimension: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reduceAnimatedMedia") private var reduceAnimatedMedia = false
    @State private var decodedImage: DecodedAnimatedImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let decodedImage {
                AnimatedImageRepresentable(
                    decodedImage: decodedImage,
                    animates: animates && !reduceMotion && !reduceAnimatedMedia,
                    isLooping: isLooping
                )
            } else if didFail, let fallbackSystemImage {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .padding(fallbackInset)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
            }
        }
        .task(id: LoadID(url: url, maximumPixelDimension: maximumPixelDimension)) {
            decodedImage = nil
            didFail = false
            do {
                let image = try await SharedAnimatedImageLoader.shared.image(
                    for: url,
                    maximumPixelDimension: maximumPixelDimension
                )
                guard !Task.isCancelled else { return }
                decodedImage = image
            } catch {
                decodedImage = nil
                didFail = true
            }
        }
    }
}

nonisolated final class DecodedAnimatedImage: @unchecked Sendable {
    let frames: [CGImage]
    let frameDurations: [TimeInterval]
    let estimatedByteCount: Int

    nonisolated init(data: Data, maximumPixelDimension: Int?) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw CocoaError(.fileReadCorruptFile) }

        var frames: [CGImage] = []
        var frameDurations: [TimeInterval] = []
        var estimatedByteCount = 0
        frames.reserveCapacity(frameCount)
        frameDurations.reserveCapacity(frameCount)
        let thumbnailOptions: CFDictionary? = maximumPixelDimension.map { maximumPixelDimension in
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelDimension),
            ] as CFDictionary
        }
        for index in 0 ..< frameCount {
            let image = thumbnailOptions.flatMap {
                CGImageSourceCreateThumbnailAtIndex(source, index, $0)
            } ?? CGImageSourceCreateImageAtIndex(source, index, nil)
            guard let image else { continue }
            let prepared = AnimatedImageFramePreparation.prepare(image)
            frames.append(prepared)
            frameDurations.append(AnimatedImageFrameTiming.duration(source: source, index: index))
            estimatedByteCount += prepared.bytesPerRow * prepared.height
        }
        guard !frames.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        self.frames = frames
        self.frameDurations = frameDurations
        self.estimatedByteCount = estimatedByteCount
    }
}

enum AnimatedImageFramePreparation {
    nonisolated static let maximumEagerPixelCount = 512 * 512

    nonisolated static func shouldEagerlyDecode(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixelCount <= maximumEagerPixelCount
    }

    nonisolated static func prepare(_ image: CGImage) -> CGImage {
        guard shouldEagerlyDecode(width: image.width, height: image.height),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return context.makeImage() ?? image
    }
}

private actor SharedAnimatedImageLoader {
    static let shared = SharedAnimatedImageLoader()

    private struct RequestKey: Hashable, Sendable {
        let url: URL
        let maximumPixelDimension: Int?

        var cacheKey: NSString {
            "\(url.absoluteString)#pixel-max=\(maximumPixelDimension ?? 0)" as NSString
        }
    }

    private let cache = NSCache<NSString, DecodedAnimatedImage>()
    private var inFlight: [RequestKey: Task<DecodedAnimatedImage, any Error>] = [:]

    init() {
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 256
    }

    func image(for url: URL, maximumPixelDimension: Int?) async throws -> DecodedAnimatedImage {
        let key = RequestKey(
            url: url,
            maximumPixelDimension: maximumPixelDimension.map { max(1, $0) }
        )
        if let cached = cache.object(forKey: key.cacheKey) { return cached }
        if let task = inFlight[key] { return try await task.value }

        let data = try await SharedMediaDataLoader.shared.data(for: url)
        let task = Task.detached(priority: .userInitiated) {
            try DecodedAnimatedImage(
                data: data,
                maximumPixelDimension: key.maximumPixelDimension
            )
        }
        inFlight[key] = task
        do {
            let image = try await task.value
            inFlight[key] = nil
            cache.setObject(image, forKey: key.cacheKey, cost: image.estimatedByteCount)
            return image
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
}

actor SharedMediaDataLoader {
    static let shared = SharedMediaDataLoader()
    private let localFileCache = NSCache<NSURL, NSData>()
    private var inFlight: [URL: Task<Data, any Error>] = [:]

    init() {
        localFileCache.totalCostLimit = 32 * 1024 * 1024
        localFileCache.countLimit = 256
    }

    func data(for url: URL) async throws -> Data {
        if url.isFileURL, let value = localFileCache.object(forKey: url as NSURL) {
            return value as Data
        }
        if let task = inFlight[url] {
            return try await task.value
        }
        let task = Task<Data, any Error> {
            if url.isFileURL {
                return try Data(contentsOf: url)
            }
            let request = URLRequest(
                url: url,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 30
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            if let response = response as? HTTPURLResponse, !(200 ..< 300).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        }
        inFlight[url] = task
        do {
            let value = try await task.value
            inFlight[url] = nil
            if url.isFileURL {
                localFileCache.setObject(
                    value as NSData,
                    forKey: url as NSURL,
                    cost: value.count
                )
            }
            return value
        } catch {
            inFlight[url] = nil
            throw error
        }
    }

}

private struct AnimatedImageRepresentable: NSViewRepresentable {
    let decodedImage: DecodedAnimatedImage
    let animates: Bool
    let isLooping: Bool

    func makeNSView(context: Context) -> AnimatedImageCanvas {
        AnimatedImageCanvas()
    }

    func updateNSView(_ view: AnimatedImageCanvas, context: Context) {
        view.display(decodedImage, animates: animates, isLooping: isLooping)
    }
}

private final class AnimatedImageCanvas: NSView {
    private var displayedImage: DecodedAnimatedImage?
    private var displayedAnimationPreference: (animates: Bool, isLooping: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ image: DecodedAnimatedImage, animates: Bool, isLooping: Bool) {
        let preference = (animates: animates, isLooping: isLooping)
        guard
            displayedImage !== image
            || displayedAnimationPreference?.animates != preference.animates
            || displayedAnimationPreference?.isLooping != preference.isLooping
        else { return }
        displayedImage = image
        displayedAnimationPreference = preference
        layer?.removeAnimation(forKey: "remoteAnimatedImage")

        let frames = image.frames
        let frameDurations = image.frameDurations
        guard let firstFrame = frames.first else { return }
        layer?.contents = firstFrame

        guard animates, frames.count > 1 else { return }
        let totalDuration = max(frameDurations.reduce(0, +), 0.05)
        var elapsed: TimeInterval = 0
        let keyTimes = frameDurations.map { duration -> NSNumber in
            defer { elapsed += duration }
            return NSNumber(value: elapsed / totalDuration)
        }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = keyTimes
        animation.duration = totalDuration
        animation.calculationMode = .discrete
        animation.repeatCount = isLooping ? .infinity : 1
        animation.isRemovedOnCompletion = !isLooping
        animation.fillMode = .forwards
        layer?.add(animation, forKey: "remoteAnimatedImage")
    }

}

enum AnimatedImageFrameTiming {
    nonisolated static func duration(source: CGImageSource, index: Int) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        else {
            return 0.1
        }
        return duration(properties: properties)
    }

    nonisolated static func duration(properties: [CFString: Any]) -> TimeInterval {
        if let webP = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            if let value = webP[kCGImagePropertyWebPUnclampedDelayTime] as? NSNumber {
                return normalizedWebP(value.doubleValue)
            }
            if let value = webP[kCGImagePropertyWebPDelayTime] as? NSNumber {
                return normalizedWebP(value.doubleValue)
            }
        }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let value = png[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber {
                return normalized(value.doubleValue)
            }
            if let value = png[kCGImagePropertyAPNGDelayTime] as? NSNumber {
                return normalized(value.doubleValue)
            }
        }
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let value = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber {
                return normalized(value.doubleValue)
            }
            if let value = gif[kCGImagePropertyGIFDelayTime] as? NSNumber {
                return normalized(value.doubleValue)
            }
        }
        return 0.1
    }

    nonisolated private static func normalized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 0.1 }
        return max(0.01, value)
    }

    nonisolated private static func normalizedWebP(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0.01 else { return 0.1 }
        return value
    }
}

struct LoopingRemoteWebMedia: NSViewRepresentable {
    let url: URL
    let backgroundURL: URL?
    let backgroundCSS: String
    let isPlaying: Bool

    private static let mediaDataStore = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PassthroughWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.websiteDataStore = Self.mediaDataStore
        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 9
        webView.layer?.cornerCurve = .continuous
        webView.layer?.masksToBounds = true
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.isPlaying = isPlaying
        load(url: url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: PassthroughWebView, context: Context) {
        load(url: url, in: webView, coordinator: context.coordinator)
        context.coordinator.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ webView: PassthroughWebView, coordinator: Coordinator) {
        coordinator.setPlaying(false)
        webView.stopLoading()
        webView.navigationDelegate = nil
        coordinator.webView = nil
        coordinator.currentKey = nil
    }

    private func load(url: URL, in webView: WKWebView, coordinator: Coordinator) {
        let key = "\(url.absoluteString)|\(backgroundURL?.absoluteString ?? "")|\(backgroundCSS)"
        guard coordinator.currentKey != key else { return }
        coordinator.currentKey = key
        coordinator.isReady = false
        webView.loadHTMLString(
            html(
                source: escaped(url),
                backgroundSource: backgroundURL.map(escaped),
                backgroundCSS: backgroundCSS,
                initiallyPlaying: coordinator.isPlaying
            ),
            baseURL: nil
        )
    }

    private func html(
        source: String,
        backgroundSource: String?,
        backgroundCSS: String,
        initiallyPlaying: Bool
    ) -> String {
        let background =
            backgroundSource.map {
            #"<img id="background" src="\#($0)" alt="">"#
        } ?? ""
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}
        body{position:relative}
        #plate{position:absolute;inset:0;background:\(backgroundCSS);mask-image:linear-gradient(to right,transparent 0%,transparent 42%,rgba(0,0,0,.18) 52%,rgba(0,0,0,.72) 66%,#000 76%);-webkit-mask-image:linear-gradient(to right,transparent 0%,transparent 42%,rgba(0,0,0,.18) 52%,rgba(0,0,0,.72) 66%,#000 76%);mask-size:100% 100%;-webkit-mask-size:100% 100%;mask-repeat:no-repeat;-webkit-mask-repeat:no-repeat}
        #plate img,#plate video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
        video{mix-blend-mode:screen;pointer-events:none;background:transparent}
        </style>
        </head><body><div id="plate">\(background)<video id="animation" src="\(source)" autoplay loop muted playsinline preload="auto"></video></div>
        <script>
        const animation = document.getElementById('animation');
        let playbackEnabled = \(initiallyPlaying ? "true" : "false");
        const syncPlayback = () => {
          if (playbackEnabled && document.visibilityState === 'visible') {
            animation.play().catch(() => {});
          } else {
            animation.pause();
          }
        };
        window.setPlaybackEnabled = enabled => { playbackEnabled = enabled; syncPlayback(); };
        animation.addEventListener('canplay', syncPlayback);
        document.addEventListener('visibilitychange', syncPlayback);
        syncPlayback();
        </script></body></html>
        """
    }

    private func escaped(_ url: URL) -> String {
        url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var currentKey: String?
        weak var webView: WKWebView?
        var isPlaying = true
        var isReady = false

        func setPlaying(_ value: Bool) {
            guard isPlaying != value else { return }
            isPlaying = value
            applyPlaybackState()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isReady = true
            applyPlaybackState()
        }

        private func applyPlaybackState() {
            guard isReady else { return }
            webView?.evaluateJavaScript(
                "window.setPlaybackEnabled(\(isPlaying ? "true" : "false"))"
            )
        }
    }
}

final class PassthroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

nonisolated enum AnimatedMediaPlaybackPolicy {
    static func shouldPlay(
        isVisible: Bool,
        reduceMotion: Bool,
        reduceAnimatedMedia: Bool
    ) -> Bool {
        isVisible && !reduceMotion && !reduceAnimatedMedia
    }
}
