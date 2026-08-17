import AppKit
import SakuraCordModels

enum DiscordComponentButtonAppearance {
    static func backgroundHex(for style: ComponentButtonStyle?) -> UInt32 {
        switch style ?? .secondary {
        case .primary: 0x5865F2
        case .secondary, .link, .premium: 0x4E5058
        case .success: 0x248046
        case .destructive: 0xDA373C
        }
    }
}

nonisolated enum DiscordComponentEmojiMetrics {
    static let buttonSize: CGFloat = 16
    static let selectSize: CGFloat = 16

    static func opticalSize(for boxSize: CGFloat) -> CGFloat {
        max(0, boxSize - 2)
    }
}

nonisolated struct PreparedComponentUnicodeEmojiBatch: @unchecked Sendable {
    struct Image: @unchecked Sendable {
        let value: String
        let image: CGImage
        let size: CGSize
    }

    let images: [Image]
}

nonisolated enum ComponentUnicodeEmojiBatchGenerator {
    private struct Entry {
        let value: String
        let attributed: NSAttributedString
        let originX: Int
        let width: Int
        let height: Int
    }

    private static let sourceFontSize: CGFloat = 64
    private static let canvasPadding = 16

    static func render(_ values: [String])
        -> PreparedComponentUnicodeEmojiBatch
    {
        guard !values.isEmpty else {
            return PreparedComponentUnicodeEmojiBatch(images: [])
        }
        return AppPerformanceSignposts.measureSync(
            "ComponentUnicodeEmojiBatchRender"
        ) {
            let font = NSFont(
                name: "Apple Color Emoji",
                size: sourceFontSize
            ) ?? NSFont.systemFont(ofSize: sourceFontSize)
            var entries: [Entry] = []
            entries.reserveCapacity(values.count)
            var atlasWidth = 0
            var atlasHeight = 1
            for value in values {
                let attributed = NSAttributedString(
                    string: value,
                    attributes: [.font: font]
                )
                let measured = attributed.size()
                let width = max(
                    1,
                    Int(ceil(measured.width)) + canvasPadding * 2
                )
                let height = max(
                    1,
                    Int(ceil(measured.height)) + canvasPadding * 2
                )
                entries.append(Entry(
                    value: value,
                    attributed: attributed,
                    originX: atlasWidth,
                    width: width,
                    height: height
                ))
                atlasWidth += width
                atlasHeight = max(atlasHeight, height)
            }
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: atlasWidth,
                pixelsHigh: atlasHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                return PreparedComponentUnicodeEmojiBatch(images: [])
            }
            bitmap.size = NSSize(width: atlasWidth, height: atlasHeight)

            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.current = context
                NSColor.clear.setFill()
                NSRect(
                    x: 0,
                    y: 0,
                    width: atlasWidth,
                    height: atlasHeight
                ).fill()
                for entry in entries {
                    entry.attributed.draw(at: NSPoint(
                        x: entry.originX + canvasPadding,
                        y: canvasPadding
                    ))
                }
                context.flushGraphics()
            }
            NSGraphicsContext.restoreGraphicsState()

            guard let atlasImage = bitmap.cgImage else {
                return PreparedComponentUnicodeEmojiBatch(images: [])
            }
            let images = entries.compactMap { entry
                -> PreparedComponentUnicodeEmojiBatch.Image? in
                let cell = CGRect(
                    x: entry.originX,
                    y: 0,
                    width: entry.width,
                    height: entry.height
                )
                guard let crop = opaqueBounds(in: bitmap, within: cell),
                      let image = atlasImage.cropping(to: crop)
                else { return nil }
                return PreparedComponentUnicodeEmojiBatch.Image(
                    value: entry.value,
                    image: image,
                    size: crop.size
                )
            }
            return PreparedComponentUnicodeEmojiBatch(images: images)
        }
    }

    private static func opaqueBounds(
        in bitmap: NSBitmapImageRep,
        within bounds: CGRect
    ) -> CGRect? {
        guard let data = bitmap.bitmapData else { return nil }
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst)
            ? 0
            : bytesPerPixel - 1
        let alphaThreshold: UInt8 = 5
        let lowerX = max(0, Int(bounds.minX.rounded(.down)))
        let lowerY = max(0, Int(bounds.minY.rounded(.down)))
        let upperX = min(bitmap.pixelsWide, Int(bounds.maxX.rounded(.up)))
        let upperY = min(bitmap.pixelsHigh, Int(bounds.maxY.rounded(.up)))
        guard lowerX < upperX, lowerY < upperY else { return nil }
        var minimumX = upperX
        var minimumY = upperY
        var maximumX = -1
        var maximumY = -1

        for rowIndex in lowerY ..< upperY {
            let row = data.advanced(by: rowIndex * bitmap.bytesPerRow)
            var firstOpaqueColumn = lowerX
            while firstOpaqueColumn < upperX,
                  row[firstOpaqueColumn * bytesPerPixel + alphaOffset]
                    <= alphaThreshold
            {
                firstOpaqueColumn += 1
            }
            guard firstOpaqueColumn < upperX else { continue }
            var lastOpaqueColumn = upperX - 1
            while lastOpaqueColumn > firstOpaqueColumn,
                  row[lastOpaqueColumn * bytesPerPixel + alphaOffset]
                    <= alphaThreshold
            {
                lastOpaqueColumn -= 1
            }
            minimumX = min(minimumX, firstOpaqueColumn)
            minimumY = min(minimumY, rowIndex)
            maximumX = max(maximumX, lastOpaqueColumn)
            maximumY = rowIndex
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }
}

@MainActor
enum ComponentUnicodeEmojiRenderer {
    private static var cache: [String: NSImage] = [:]
    private static var cacheInsertionOrder: [String] = []
    private static var cacheEvictionIndex = 0
    private static let sourceFontSize: CGFloat = 64
    private static let canvasPadding = 16
    private static let maximumBatchCount = 16
    private static let maximumCacheCount = 256

    static func prepareImages<S: Sequence>(for values: S)
    where S.Element == String {
        for batch in missingBatches(for: values) {
            renderBatch(batch)
        }
    }

    private static func missingBatches<S: Sequence>(for values: S)
        -> [[String]] where S.Element == String
    {
        var seen: Set<String> = []
        let missing = values.filter {
            cache[$0] == nil && seen.insert($0).inserted
        }
        guard !missing.isEmpty else { return [] }
        var batches: [[String]] = []
        batches.reserveCapacity(
            (missing.count + maximumBatchCount - 1) / maximumBatchCount
        )
        var offset = 0
        while offset < missing.count {
            let end = min(offset + maximumBatchCount, missing.count)
            batches.append(Array(missing[offset ..< end]))
            offset = end
        }
        return batches
    }

    private static func renderBatch(_ values: [String]) {
        guard !values.isEmpty else { return }
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "ComponentUnicodeEmojiBatchCacheMiss"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "ComponentUnicodeEmojiBatchCacheMiss",
                interval
            )
        }

        install(ComponentUnicodeEmojiBatchGenerator.render(values))
    }

    private static func install(
        _ prepared: PreparedComponentUnicodeEmojiBatch
    ) {
        for preparedImage in prepared.images where cache[preparedImage.value] == nil {
            insert(
                NSImage(
                    cgImage: preparedImage.image,
                    size: preparedImage.size
                ),
                for: preparedImage.value
            )
        }
    }

    private static func insert(_ image: NSImage, for value: String) {
        while cache.count >= maximumCacheCount,
              cacheEvictionIndex < cacheInsertionOrder.count
        {
            cache.removeValue(
                forKey: cacheInsertionOrder[cacheEvictionIndex]
            )
            cacheEvictionIndex += 1
        }
        cache[value] = image
        cacheInsertionOrder.append(value)
        if cacheEvictionIndex > 512,
           cacheEvictionIndex * 2 > cacheInsertionOrder.count
        {
            cacheInsertionOrder.removeFirst(cacheEvictionIndex)
            cacheEvictionIndex = 0
        }
    }

    static func image(for value: String) -> NSImage {
        if let cached = cache[value] {
            return cached
        }
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "ComponentUnicodeEmojiCacheMiss"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "ComponentUnicodeEmojiCacheMiss",
                interval
            )
        }

        let font = NSFont(name: "Apple Color Emoji", size: sourceFontSize)
            ?? NSFont.systemFont(ofSize: sourceFontSize)
        let attributed = NSAttributedString(string: value, attributes: [.font: font])
        let measured = attributed.size()
        let width = max(1, Int(ceil(measured.width)) + canvasPadding * 2)
        let height = max(1, Int(ceil(measured.height)) + canvasPadding * 2)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        bitmap.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            attributed.draw(at: NSPoint(x: canvasPadding, y: canvasPadding))
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let crop = opaqueBounds(
            in: bitmap,
            within: CGRect(
                x: 0,
                y: 0,
                width: bitmap.pixelsWide,
                height: bitmap.pixelsHigh
            )
        ),
              let cgImage = bitmap.cgImage?.cropping(to: crop)
        else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: crop.width, height: crop.height)
        )
        insert(image, for: value)
        return image
    }

    private static func opaqueBounds(
        in bitmap: NSBitmapImageRep,
        within bounds: CGRect
    ) -> CGRect? {
        guard let data = bitmap.bitmapData else { return nil }
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bytesPerPixel - 1
        let alphaThreshold: UInt8 = 5
        let lowerX = max(0, Int(bounds.minX.rounded(.down)))
        let lowerY = max(0, Int(bounds.minY.rounded(.down)))
        let upperX = min(bitmap.pixelsWide, Int(bounds.maxX.rounded(.up)))
        let upperY = min(bitmap.pixelsHigh, Int(bounds.maxY.rounded(.up)))
        guard lowerX < upperX, lowerY < upperY else { return nil }
        var minimumX = upperX
        var minimumY = upperY
        var maximumX = -1
        var maximumY = -1

        for rowIndex in lowerY ..< upperY {
            let row = data.advanced(by: rowIndex * bitmap.bytesPerRow)
            var firstOpaqueColumn = lowerX
            while firstOpaqueColumn < upperX,
                  row[firstOpaqueColumn * bytesPerPixel + alphaOffset]
                    <= alphaThreshold
            {
                firstOpaqueColumn += 1
            }
            guard firstOpaqueColumn < upperX else { continue }
            var lastOpaqueColumn = upperX - 1
            while lastOpaqueColumn > firstOpaqueColumn,
                  row[lastOpaqueColumn * bytesPerPixel + alphaOffset]
                    <= alphaThreshold
            {
                lastOpaqueColumn -= 1
            }
            minimumX = min(minimumX, firstOpaqueColumn)
            minimumY = min(minimumY, rowIndex)
            maximumX = max(maximumX, lastOpaqueColumn)
            maximumY = rowIndex
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }

#if DEBUG
    static func clearCacheForTesting() {
        cache.removeAll(keepingCapacity: false)
        cacheInsertionOrder.removeAll(keepingCapacity: false)
        cacheEvictionIndex = 0
    }
#endif
}
