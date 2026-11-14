import Foundation
import CoreGraphics

/// Retain one frame independently of the much larger animation working set.
/// Remounted views can paint synchronously even after their animation is evicted.
nonisolated final class AnimatedImagePosterCache: @unchecked Sendable {
    static let shared = AnimatedImagePosterCache()

    private let maximumCost: Int
    private let maximumCount: Int
    private let lock = NSLock()
    private var images: [AnimatedRemoteImageRequestIdentity: CGImage] = [:]
    private var recency: [AnimatedRemoteImageRequestIdentity] = []
    private var totalCost = 0

    init(maximumCost: Int = MediaMemoryPolicy.animatedImagePosterBytes, maximumCount: Int = 256) {
        self.maximumCost = maximumCost
        self.maximumCount = maximumCount
    }

    func image(for url: URL, maximumPixelDimension: Int?) -> CGImage? {
        let key = AnimatedRemoteImageRequestIdentity(url: url, maximumPixelDimension: maximumPixelDimension)
        lock.lock()
        defer { lock.unlock() }
        guard let image = images[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return image
    }

    func insert(_ image: CGImage, for url: URL, maximumPixelDimension: Int?) {
        let key = AnimatedRemoteImageRequestIdentity(url: url, maximumPixelDimension: maximumPixelDimension)
        let cost = image.bytesPerRow * image.height
        lock.lock()
        defer { lock.unlock() }
        if let previous = images.removeValue(forKey: key) {
            totalCost -= previous.bytesPerRow * previous.height
            recency.removeAll { $0 == key }
        }
        guard cost <= maximumCost else { return }
        images[key] = image
        totalCost += cost
        recency.append(key)
        while totalCost > maximumCost || images.count > maximumCount {
            guard let oldest = recency.first, let removed = images.removeValue(forKey: oldest) else { break }
            recency.removeFirst()
            totalCost -= removed.bytesPerRow * removed.height
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        images.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
        totalCost = 0
    }
}
