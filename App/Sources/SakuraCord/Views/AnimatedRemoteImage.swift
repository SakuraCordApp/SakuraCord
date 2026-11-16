import AppKit
import QuartzCore
import SwiftUI

nonisolated struct AnimatedRemoteImageRequestIdentity: Hashable {
    let url: URL
    let maximumPixelDimension: Int?
}

/// Displays remote GIF/APNG/WebP assets without flattening them to their first frame.
struct AnimatedRemoteImage: View {
    let url: URL
    var animates: Bool
    var isLooping: Bool
    var playback: AnimatedImagePlayback?
    var previewImage: NSImage?
    var fallbackSystemImage: String?
    var fallbackInset: CGFloat
    var maximumPixelDimension: Int?
    var contentMode: ContentMode
    var onFailure: (() -> Void)?
    var usesSwiftUIRendering: Bool
    var resetsWhenStopped: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playsAnimatedImages
    @State private var decodedImage: DecodedAnimatedImage?
    @State private var cachedPoster: CGImage?
    @State private var displayedLoadID: AnimatedRemoteImageRequestIdentity?
    @State private var didFail = false

    init(
        url: URL,
        animates: Bool = true,
        isLooping: Bool = true,
        playback: AnimatedImagePlayback? = nil,
        loadedImage: DecodedAnimatedImage? = nil,
        previewImage: NSImage? = nil,
        fallbackSystemImage: String? = nil,
        fallbackInset: CGFloat = 2,
        maximumPixelDimension: Int? = nil,
        contentMode: ContentMode = .fit,
        usesSwiftUIRendering: Bool = false,
        resetsWhenStopped: Bool = false,
        onFailure: (() -> Void)? = nil
    ) {
        self.url = url
        self.animates = animates
        self.isLooping = isLooping
        self.playback = playback
        self.previewImage = previewImage
        self.fallbackSystemImage = fallbackSystemImage
        self.fallbackInset = fallbackInset
        self.maximumPixelDimension = maximumPixelDimension
        self.contentMode = contentMode
        self.usesSwiftUIRendering = usesSwiftUIRendering
        self.resetsWhenStopped = resetsWhenStopped
        self.onFailure = onFailure

        let loadID = AnimatedRemoteImageRequestIdentity(
            url: url,
            maximumPixelDimension: maximumPixelDimension
        )
        let (cached, poster) = Self.cachedDisplay(
            url: url, maximumPixelDimension: maximumPixelDimension, loadedImage: loadedImage
        )
        _decodedImage = State(initialValue: cached)
        _cachedPoster = State(initialValue: poster)
        _displayedLoadID = State(initialValue: cached == nil ? nil : loadID)
    }

    /// What can show at once: the decoded image a cache holds, and its first
    /// frame or a cached poster.
    private static func cachedDisplay(
        url: URL,
        maximumPixelDimension: Int?,
        loadedImage: DecodedAnimatedImage? = nil
    ) -> (image: DecodedAnimatedImage?, poster: CGImage?) {
        let image = loadedImage ?? AnimatedRemoteImageDisplayCache.shared.image(
            for: url,
            maximumPixelDimension: maximumPixelDimension
        )
        return (image, image?.frames.first ?? AnimatedImagePosterCache.shared.image(
            for: url, maximumPixelDimension: maximumPixelDimension
        ))
    }

    var body: some View {
        Group {
            if let decodedImage {
                if usesSwiftUIRendering || decodedImage.frames.count == 1 {
                    SwiftUIAnimatedImage(image: decodedImage, animates: animates && !accessibilityReducesAnimation,
                                         isLooping: isLooping, contentMode: contentMode, resetsWhenStopped: resetsWhenStopped)
                        .id(ObjectIdentifier(decodedImage))
                } else {
                    AnimatedImageRepresentable(
                        decodedImage: decodedImage,
                        animates: animates && !accessibilityReducesAnimation,
                        isLooping: isLooping,
                        contentMode: contentMode,
                        playback: accessibilityReducesAnimation ? nil : playback,
                        resetsWhenStopped: resetsWhenStopped
                    )
                }
            } else if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let cachedPoster {
                Image(decorative: cachedPoster, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if didFail,
                      let fallbackSystemImage,
                      let fallbackImage = SakuraCordSystemSymbol.image(
                          named: fallbackSystemImage
                      )
            {
                Image(nsImage: fallbackImage)
                    .resizable()
                    .scaledToFit()
                    .padding(fallbackInset)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
            }
        }
        .task(id: AnimatedRemoteImageRequestIdentity(
            url: url,
            maximumPixelDimension: maximumPixelDimension
        )) {
            let loadID = AnimatedRemoteImageRequestIdentity(
                url: url,
                maximumPixelDimension: maximumPixelDimension
            )
            if displayedLoadID != loadID {
                (decodedImage, cachedPoster) = Self.cachedDisplay(url: url, maximumPixelDimension: maximumPixelDimension)
                displayedLoadID = decodedImage == nil ? nil : loadID
            }
            guard decodedImage == nil else {
                didFail = false
                return
            }
            didFail = false
            do {
                let image = try await SharedAnimatedImageLoader.shared.image(
                    for: url,
                    maximumPixelDimension: maximumPixelDimension
                )
                guard !Task.isCancelled else { return }
                AnimatedRemoteImageDisplayCache.shared.insert(
                    image,
                    for: url,
                    maximumPixelDimension: maximumPixelDimension
                )
                decodedImage = image
                cachedPoster = image.frames.first
                displayedLoadID = loadID
            } catch {
                guard !Task.isCancelled else { return }
                decodedImage = nil
                displayedLoadID = nil
                didFail = true
                onFailure?()
            }
        }
    }

    private var accessibilityReducesAnimation: Bool {
        reduceMotion || !playsAnimatedImages
    }
}

final class AnimatedRemoteImageDisplayCache: @unchecked Sendable {
    static let shared = AnimatedRemoteImageDisplayCache()

    private struct Entry {
        let image: DecodedAnimatedImage
        let cost: Int
    }

    private let maximumCount = 128
    private let maximumCost =
        MediaMemoryPolicy.displayedAnimatedImageBytes
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    private var totalCost = 0

    func image(
        for url: URL,
        maximumPixelDimension: Int?
    ) -> DecodedAnimatedImage? {
        let key = key(
            url: url,
            maximumPixelDimension: maximumPixelDimension
        )
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.image
    }

    func insert(
        _ image: DecodedAnimatedImage,
        for url: URL,
        maximumPixelDimension: Int?
    ) {
        if let frame = image.frames.first {
            AnimatedImagePosterCache.shared.insert(frame, for: url, maximumPixelDimension: maximumPixelDimension)
        }
        let key = key(
            url: url,
            maximumPixelDimension: maximumPixelDimension
        )
        let entry = Entry(
            image: image,
            cost: max(1, image.storedByteCount)
        )
        lock.lock()
        defer { lock.unlock() }
        if let previous = entries[key] {
            totalCost -= previous.cost
            entries[key] = nil
            recency.removeAll { $0 == key }
        }
        guard entry.cost <= maximumCost else {
            return
        }
        entries[key] = entry
        totalCost += entry.cost
        recency.append(key)
        evictIfNeeded()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
        totalCost = 0
        lock.unlock()
    }

#if DEBUG
    var entryCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var maximumCountForTesting: Int {
        maximumCount
    }
#endif

    private func key(
        url: URL,
        maximumPixelDimension: Int?
    ) -> String {
        "\(url.absoluteString)#display-pixel-max=\(maximumPixelDimension ?? 0)"
    }

    private func evictIfNeeded() {
        while entries.count > maximumCount
            || totalCost > maximumCost
        {
            guard let key = recency.first,
                  let removed = entries.removeValue(forKey: key)
            else { return }
            recency.removeAll { $0 == key }
            totalCost -= removed.cost
        }
    }
}

nonisolated enum AnimatedMediaPlaybackPolicy {
    static func shouldPlay(
        isVisible: Bool,
        isWindowVisible: Bool = true,
        reduceMotion: Bool
    ) -> Bool {
        isVisible
            && isWindowVisible
            && !reduceMotion
    }
}
