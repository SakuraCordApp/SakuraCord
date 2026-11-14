import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

@MainActor
enum SystemSymbolImageCache {
    private struct ConfiguredKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: CGFloat
        let appearanceName: String
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private struct RasterizedKey: Hashable {
        let configured: ConfiguredKey
        let scaleQuarter: Int
    }

    private static let configuredImageLimit = 256
    private static let rasterizedImageLimit = 1_024
    private static var images: [String: NSImage] = [:]
    private static var configuredImages: [ConfiguredKey: NSImage] = [:]
    private static var rasterizedImages: [RasterizedKey: NSImage] = [:]
    private static var rasterizedImageOrder: [RasterizedKey] = []
    private static var postFirstFramePrewarmTask: Task<Void, Never>?
    private static var postFirstFramePrewarmGeneration: UInt64 = 0
    private static var didPrewarmPostFirstFrameSymbols = false

    static func image(named name: String) -> NSImage? {
        if let image = images[name] { return image }
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "TimelineSystemSymbolCacheMiss"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "TimelineSystemSymbolCacheMiss",
                interval
            )
        }
        guard let image = SakuraCordSystemSymbol.image(named: name) else { return nil }
        images[name] = image
        return image
    }

    static func configuredImage(
        named name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSImage? {
        let appearance = NSAppearance.currentDrawing()
        let resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        let key = configuredKey(
            name: name,
            pointSize: pointSize,
            weight: weight,
            appearance: appearance,
            resolvedColor: resolvedColor
        )
        return configuredImage(
            for: key,
            weight: weight,
            resolvedColor: resolvedColor
        )
    }

    static func rasterizedConfiguredImage(
        named name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        scale: CGFloat
    ) -> NSImage? {
        let appearance = NSAppearance.currentDrawing()
        let resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        let configuredKey = configuredKey(
            name: name,
            pointSize: pointSize,
            weight: weight,
            appearance: appearance,
            resolvedColor: resolvedColor
        )
        let boundedScale = min(4, max(1, scale))
        let scaleQuarter = Int((boundedScale * 4).rounded())
        let rasterizedKey = RasterizedKey(
            configured: configuredKey,
            scaleQuarter: scaleQuarter
        )
        if let image = rasterizedImages[rasterizedKey] { return image }
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "TimelineSystemSymbolRasterCacheMiss"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "TimelineSystemSymbolRasterCacheMiss",
                interval
            )
        }
        guard let configuredImage = configuredImage(
            for: configuredKey,
            weight: weight,
            resolvedColor: resolvedColor
        ), let rasterized = rasterizedImage(
            from: configuredImage,
            scale: CGFloat(scaleQuarter) / 4,
            appearance: appearance
        ) else { return nil }
        if rasterizedImages.count >= rasterizedImageLimit,
           let oldest = rasterizedImageOrder.first
        {
            rasterizedImageOrder.removeFirst()
            rasterizedImages[oldest] = nil
        }
        rasterizedImageOrder.append(rasterizedKey)
        rasterizedImages[rasterizedKey] = rasterized
        return rasterized
    }

    private static func configuredKey(
        name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        appearance: NSAppearance,
        resolvedColor: NSColor
    ) -> ConfiguredKey {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolvedColor.getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        )
        return ConfiguredKey(
            name: name,
            pointSize: pointSize,
            weight: weight.rawValue,
            appearanceName: appearance.name.rawValue,
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    private static func configuredImage(
        for key: ConfiguredKey,
        weight: NSFont.Weight,
        resolvedColor: NSColor
    ) -> NSImage? {
        if let image = configuredImages[key] { return image }
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "TimelineSystemSymbolConfiguredCacheMiss"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "TimelineSystemSymbolConfiguredCacheMiss",
                interval
            )
        }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: key.pointSize,
            weight: weight
        ).applying(
            NSImage.SymbolConfiguration(paletteColors: [resolvedColor])
        )
        guard let image = image(named: key.name)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        if configuredImages.count >= configuredImageLimit {
            configuredImages.remove(at: configuredImages.startIndex)
        }
        configuredImages[key] = image
        return image
    }

    private static func rasterizedImage(
        from image: NSImage,
        scale: CGFloat,
        appearance: NSAppearance
    ) -> NSImage? {
        let size = image.size
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else { return nil }
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard let representation = NSBitmapImageRep(
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
        ) else { return nil }
        representation.size = size
        guard let graphics = NSGraphicsContext(bitmapImageRep: representation)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        appearance.performAsCurrentDrawingAppearance {
            image.draw(
                in: CGRect(origin: .zero, size: size),
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            graphics.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        let rasterized = NSImage(size: size)
        rasterized.addRepresentation(representation)
        rasterized.alignmentRect = image.alignmentRect
        rasterized.isTemplate = false
        return rasterized
    }

    static func schedulePostFirstFramePrewarm(
        appearance: NSAppearance
    ) {
        guard !didPrewarmPostFirstFrameSymbols else { return }
        postFirstFramePrewarmGeneration &+= 1
        let generation = postFirstFramePrewarmGeneration
        postFirstFramePrewarmTask?.cancel()
        postFirstFramePrewarmTask = Task { @MainActor in
            defer {
                if postFirstFramePrewarmGeneration == generation {
                    postFirstFramePrewarmTask = nil
                }
            }
            // Keep one-shot SF Symbol resolution away from both the first
            // conversation frame and active input. Resolve one symbol per
            // display budget so this warm-up cannot become its own hitch.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled,
                  postFirstFramePrewarmGeneration == generation,
                  !AppScrollActivity.isActive,
                  !AppPerformanceSignposts.isConversationPresentationWorkActive
            else { return }
            let preparations: [() -> Void] = [
                {
                    prewarmConfiguredImage(
                        named: "play.circle.fill",
                        pointSize: 36,
                        weight: .regular,
                        color: .white,
                        appearance: appearance
                    )
                },
                {
                    prewarmConfiguredImage(
                        named: "play.fill",
                        pointSize: 15,
                        weight: .regular,
                        color: NSColor.black.withAlphaComponent(0.75),
                        appearance: appearance
                    )
                },
                {
                    prewarmConfiguredImage(
                        named: SakuraCordSystemSymbol.emojiFaceGrinning,
                        pointSize: 10,
                        weight: .medium,
                        color: .secondaryLabelColor,
                        appearance: appearance
                    )
                },
                {
                    prewarmConfiguredImage(
                        named: SakuraCordSystemSymbol.emojiFaceGrinning,
                        pointSize: 16,
                        weight: .medium,
                        color: .labelColor,
                        appearance: appearance
                    )
                },
            ]
            for preparation in preparations {
                guard !Task.isCancelled,
                      postFirstFramePrewarmGeneration == generation,
                      !AppScrollActivity.isActive,
                      !AppPerformanceSignposts.isConversationPresentationWorkActive
                else {
                    return
                }
                preparation()
                try? await Task.sleep(for: .milliseconds(16))
            }
            didPrewarmPostFirstFrameSymbols = true
        }
    }

    private static func prewarmConfiguredImage(
        named name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        appearance: NSAppearance
    ) {
        AppPerformanceSignposts.measureSync(
            "TimelineSystemSymbolConfiguredPrewarm"
        ) {
            appearance.performAsCurrentDrawingAppearance {
                guard let image = configuredImage(
                    named: name,
                    pointSize: pointSize,
                    weight: weight,
                    color: color
                ) else { return }
                let width = max(1, Int(ceil(image.size.width * 2)))
                let height = max(1, Int(ceil(image.size.height * 2)))
                guard let representation = NSBitmapImageRep(
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
                ) else { return }
                representation.size = image.size
                guard let graphics = NSGraphicsContext(
                    bitmapImageRep: representation
                ) else { return }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                image.draw(in: CGRect(origin: .zero, size: image.size))
                graphics.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
