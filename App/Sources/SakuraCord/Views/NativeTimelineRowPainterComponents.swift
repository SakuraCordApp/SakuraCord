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
enum NativeTimelineSystemSymbolCache {
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

struct NativeTimelineComponentsDrawInput {
    let layout: NativeTimelineComponentLayout
    let bubbleRegion: NativeTimelineBubbleRegion?
    let model: AppModel?
    let messageID: MessageID
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let layoutIndex: Int
    let textSelection: NativeTimelineTextSelection?
    let hoveredMention: NativeTimelineMentionHover?
    let hoveredTextLink: NativeTimelineTextLinkHover?
    let hoveredTextSpoiler: NativeTimelineTextSpoilerHover?
    let revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState
    let spoilerRevealStore: NativeTimelineSpoilerRevealStore?
    let hoveredComponentButton: NativeTimelineComponentButtonTarget?
    let activeComponentChoiceTarget: NativeTimelineComponentSelectTarget?
    let pressedComponentButton: NativeTimelineComponentButtonTarget?
    let componentButtonPressProgress: CGFloat
}

extension NativeTimelineRowPainter {
    private struct BubbleIntegratedSectionGeometry {
        let frame: CGRect
        let cornerRadius: CGFloat
        let ownsTopEdge: Bool
        let ownsBottomEdge: Bool

        var path: NSBezierPath {
            NSBezierPath(
                concentricRoundedRect: frame,
                cornerRadius: cornerRadius
            )
        }
    }

    static func schedulePostFirstFrameSymbolPrewarm(
        appearance: NSAppearance
    ) {
        NativeTimelineSystemSymbolCache.schedulePostFirstFramePrewarm(
            appearance: appearance
        )
    }

    static func drawComponents(_ input: NativeTimelineComponentsDrawInput) {
        let hiddenContainerFrames =
            input.spoilerRevealStore.map {
                NativeTimelineSpoilerConcealmentPolicy
                    .hiddenContainerFrames(
                        in: input.layout,
                        messageID: input.messageID,
                        store: $0
                    )
            } ?? []
        drawComponentChrome(input, hiddenContainerFrames: hiddenContainerFrames)
        drawComponentText(input, hiddenContainerFrames: hiddenContainerFrames)
        drawComponentImages(input, hiddenContainerFrames: hiddenContainerFrames)
        drawComponentMedia(input, hiddenContainerFrames: hiddenContainerFrames)
        drawComponentFiles(input, hiddenContainerFrames: hiddenContainerFrames)
        drawComponentControls(input, hiddenContainerFrames: hiddenContainerFrames)
        drawUnsupportedComponents(input, hiddenContainerFrames: hiddenContainerFrames)

    }

    private static func isInsideHiddenComponentContainer(
        _ frame: CGRect,
        hiddenContainerFrames: [CGRect]
    ) -> Bool {
        NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
            frame,
            hiddenContainerFrames: hiddenContainerFrames
        )
    }

    private static func isConcealedComponentContent(
        contentID: String,
        isSpoiler: Bool,
        input: NativeTimelineComponentsDrawInput
    ) -> Bool {
        input.spoilerRevealStore.map {
            NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                messageID: input.messageID,
                contentID: contentID,
                isSpoiler: isSpoiler,
                store: $0
            )
        } ?? false
    }

    private static func drawComponentChrome(
        _ input: NativeTimelineComponentsDrawInput,
        hiddenContainerFrames: [CGRect]
    ) {
        for container in input.layout.containers {
            let isHidden = hiddenContainerFrames.contains(container.frame)
            if !isHidden,
               isInsideHiddenComponentContainer(
                   container.frame,
                   hiddenContainerFrames: hiddenContainerFrames
               ) { continue }
            switch container.chrome {
            case .bubbleSection:
                if let bubbleRegion = input.bubbleRegion {
                    bubbleIntegratedSection(
                        container.chromeFrame,
                        bubbleRegion: bubbleRegion,
                        accentColor: container.accentColor,
                        drawsTopSeparator: input.layout.drawsTopSeparator
                            || container.chromeFrame.minY > input.layout.frame.minY + 0.5,
                        drawsNeutralRail: false
                    )
                }
            case .card:
                componentContainer(container.frame, accentColor: container.accentColor)
            }
            if isHidden {
                spoilerConcealedBase(in: container.frame, cornerRadius: container.cornerRadius)
            }
        }
        for separator in input.layout.separators
        where separator.drawsDivider
            && !isInsideHiddenComponentContainer(
                separator.frame,
                hiddenContainerFrames: hiddenContainerFrames
            ) {
            NSColor.separatorColor.setFill()
            CGRect(
                x: separator.frame.minX,
                y: separator.frame.midY - 0.5,
                width: separator.frame.width,
                height: 1
            ).fill()
        }
    }

    private static func drawComponentText(
        _ input: NativeTimelineComponentsDrawInput,
        hiddenContainerFrames: [CGRect]
    ) {
        for (textIndex, region) in input.layout.textRegions.enumerated()
        where !isInsideHiddenComponentContainer(
            region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            let textRegion = NativeTimelineTextRegion.component(
                layoutIndex: input.layoutIndex,
                textIndex: textIndex
            )
            attributedText(
                region.text,
                in: region.frame,
                model: input.model,
                selectionRange:
                    input.textSelection?.itemIdentifier == input.itemIdentifier
                        && input.textSelection?.region == textRegion
                    ? input.textSelection?.range : nil,
                hoveredMentionCharacterIndex:
                    input.hoveredMention?.itemIdentifier == input.itemIdentifier
                        && input.hoveredMention?.region == textRegion
                    ? input.hoveredMention?.characterIndex : nil,
                hoveredLinkCharacterIndex:
                    input.hoveredTextLink?.itemIdentifier == input.itemIdentifier
                        && input.hoveredTextLink?.region == textRegion
                    ? input.hoveredTextLink?.characterIndex : nil,
                hoveredSpoilerRangeLocation:
                    input.hoveredTextSpoiler?.itemIdentifier == input.itemIdentifier
                        && input.hoveredTextSpoiler?.region == textRegion
                    ? input.hoveredTextSpoiler?.rangeLocation : nil,
                revealedSpoilerLocations:
                    input.revealedTextSpoilerState.locations(in: textRegion)
            )
        }
    }

    private static func drawComponentImages(
        _ input: NativeTimelineComponentsDrawInput,
        hiddenContainerFrames: [CGRect]
    ) {
        for region in input.layout.images
        where !isInsideHiddenComponentContainer(
            region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            if isConcealedComponentContent(
                contentID: region.componentID,
                isSpoiler: region.isSpoiler,
                input: input
            ) {
                spoilerConcealedBase(in: region.frame, cornerRadius: region.cornerRadius)
                continue
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(
                concentricRoundedRect: region.frame,
                cornerRadius: region.cornerRadius
            ).fill()
            if let image = mediaImage(for: .media(
                region.displayURL,
                maximumPixelDimension: region.maximumPixelDimension
            )) {
                drawImage(
                    image,
                    in: region.frame,
                    cornerRadius: region.cornerRadius,
                    fillsFrame: false
                )
            } else {
                systemSymbol("photo", in: region.frame, color: .secondaryLabelColor, inset: 22)
            }
        }
    }

    private static func drawComponentMedia(
        _ input: NativeTimelineComponentsDrawInput,
        hiddenContainerFrames: [CGRect]
    ) {
        for region in input.layout.media
        where !isInsideHiddenComponentContainer(
            region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            if isConcealedComponentContent(
                contentID: region.componentID,
                isSpoiler: region.isSpoiler,
                input: input
            ) {
                spoilerConcealedBase(in: region.frame, cornerRadius: 8)
                continue
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(concentricRoundedRect: region.frame, cornerRadius: 8).fill()
            if let previewURL = region.previewURL,
               let image = mediaImage(for: .media(previewURL))
            {
                drawImage(image, in: region.frame, cornerRadius: 8, fillsFrame: true)
            } else if region.isVideo {
                systemSymbol("film", in: region.frame, color: .secondaryLabelColor, inset: 30)
            }
            if region.isVideo { mediaPlayGlyph(in: region.frame) }
        }
    }

    private static func drawComponentFiles(
        _ input: NativeTimelineComponentsDrawInput,
        hiddenContainerFrames: [CGRect]
    ) {
        for region in input.layout.files
        where !isInsideHiddenComponentContainer(
            region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            if isConcealedComponentContent(
                contentID: region.componentID,
                isSpoiler: region.isSpoiler,
                input: input
            ) {
                spoilerConcealedBase(
                    in: region.frame,
                    cornerRadius: DiscordRichMessageMetrics.cardCornerRadius
                )
                continue
            }
            componentFile(
                region,
                cornerRadius: bubbleConcentricCornerRadius(
                    for: region.frame,
                    in: input.bubbleRegion,
                    fallback: DiscordRichMessageMetrics.cardCornerRadius
                )
            )
        }
    }

    private static func drawComponentControls(
        _ input: NativeTimelineComponentsDrawInput,
        hiddenContainerFrames: [CGRect]
    ) {
        for region in input.layout.buttons
        where !isInsideHiddenComponentContainer(
            region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            let target = NativeTimelineComponentButtonTarget(
                messageID: input.messageID,
                componentID: region.componentID
            )
            componentButton(
                region,
                isHovered: input.hoveredComponentButton == target,
                pressProgress: input.pressedComponentButton == target
                    ? input.componentButtonPressProgress : 0,
                cornerRadius: bubbleConcentricCornerRadius(
                    for: region.frame,
                    in: input.bubbleRegion,
                    fallback: 6
                )
            )
        }
        for region in input.layout.selects
        where !isInsideHiddenComponentContainer(
            region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            let target = NativeTimelineComponentSelectTarget(
                messageID: input.messageID,
                componentID: region.componentID
            )
            guard target != input.activeComponentChoiceTarget else { continue }
            componentSelect(
                region,
                cornerRadius: bubbleConcentricCornerRadius(for: region.frame, in: input.bubbleRegion, fallback: 11)
            )
        }
    }

    private static func drawUnsupportedComponents(
        _ input: NativeTimelineComponentsDrawInput,
        hiddenContainerFrames: [CGRect]
    ) {
        for region in input.layout.unsupported
        where !isInsideHiddenComponentContainer(
            region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            systemSymbol(
                "questionmark.square.dashed",
                in: CGRect(
                    x: region.frame.minX,
                    y: region.frame.minY,
                    width: 16,
                    height: region.frame.height
                ),
                color: .secondaryLabelColor,
                inset: 1
            )
            text(
                region.label,
                in: CGRect(
                    x: region.frame.minX + 22,
                    y: region.frame.minY,
                    width: max(1, region.frame.width - 22),
                    height: region.frame.height
                ),
                font: .systemFont(ofSize: 11),
                color: .secondaryLabelColor
            )
        }
    }

    static func componentContainer(
        _ frame: CGRect,
        accentColor: UInt32?,
        cornerRadius: CGFloat = DiscordRichMessageMetrics.cardCornerRadius
    ) {
        let shape = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: cornerRadius
        )
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        frame.fill()
        if let accent = roleColor(accentColor) {
            accent.setFill()
            CGRect(
                x: frame.minX,
                y: frame.minY,
                width: 4,
                height: frame.height
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.labelColor.withAlphaComponent(0.13).setStroke()
        let border = NSBezierPath(
            concentricRoundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: max(0, cornerRadius - 0.5)
        )
        border.lineWidth = 1
        border.stroke()
    }

    static func bubbleIntegratedSection(
        _ frame: CGRect,
        bubbleRegion: NativeTimelineBubbleRegion,
        accentColor: UInt32?,
        drawsTopSeparator: Bool,
        drawsNeutralRail: Bool
    ) {
        let geometry = bubbleIntegratedSectionGeometry(
            frame,
            bubbleRegion: bubbleRegion
        )
        if let railColor = roleColor(accentColor)
            ?? (drawsNeutralRail
                ? NSColor.secondaryLabelColor.withAlphaComponent(0.52)
                : nil)
        {
            NSGraphicsContext.saveGraphicsState()
            NativeTimelineBubbleDrawing.bodyPath(for: bubbleRegion).addClip()
            geometry.path.addClip()
            railColor.setFill()
            CGRect(
                x: geometry.frame.minX,
                y: geometry.frame.minY,
                width: 4,
                height: geometry.frame.height
            ).fill()
            NSGraphicsContext.restoreGraphicsState()
            if geometry.ownsBottomEdge,
               bubbleRegion.showsTail,
               let accentColor = roleColor(accentColor)
            {
                accentColor.setFill()
                NativeTimelineBubbleDrawing.tailPath(for: bubbleRegion).fill()
            }
        }

        if drawsTopSeparator {
            NSGraphicsContext.saveGraphicsState()
            NativeTimelineBubbleDrawing.bodyPath(for: bubbleRegion).addClip()
            NSBezierPath(rect: CGRect(
                x: geometry.frame.minX - 1,
                y: geometry.frame.minY - 1,
                width: geometry.frame.width + 2,
                height: geometry.cornerRadius + 2
            )).addClip()
            NSColor.separatorColor.withAlphaComponent(0.28).setStroke()
            let separator = geometry.path
            separator.lineWidth = 0.75
            separator.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func bubbleIntegratedSectionsTint(
        _ frames: [CGRect],
        bubbleRegion: NativeTimelineBubbleRegion
    ) {
        let frames = frames
            .filter { !$0.isEmpty }
            .sorted { $0.minY < $1.minY }
        guard var currentGroup = frames.first else { return }

        var groups: [CGRect] = []
        for frame in frames.dropFirst() {
            if frame.minY - currentGroup.maxY <= 9 {
                currentGroup = currentGroup.union(frame)
            } else {
                groups.append(currentGroup)
                currentGroup = frame
            }
        }
        groups.append(currentGroup)

        for group in groups {
            let geometry = bubbleIntegratedSectionGeometry(
                group,
                bubbleRegion: bubbleRegion
            )
            bubbleIntegratedSectionTintColor.setFill()
            geometry.path.fill()
        }
    }

    private static let bubbleIntegratedSectionTintColor = NSColor(
        name: nil
    ) { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
            NSColor.black.withAlphaComponent(0.12)
        default:
            NSColor.black.withAlphaComponent(0.055)
        }
    }

    private static func bubbleIntegratedSectionGeometry(
        _ frame: CGRect,
        bubbleRegion: NativeTimelineBubbleRegion
    ) -> BubbleIntegratedSectionGeometry {
        let bubbleFrame = bubbleRegion.frame
        let ownsTopEdge = frame.minY - bubbleFrame.minY <= 8.5
        let ownsBottomEdge = bubbleFrame.maxY - frame.maxY <= 8.5
        let sectionMinY = ownsTopEdge
            ? bubbleFrame.minY
            : max(bubbleFrame.minY, frame.minY - 4.5)
        let sectionMaxY = ownsBottomEdge
            ? bubbleFrame.maxY
            : min(bubbleFrame.maxY, frame.maxY + 4.5)
        let sectionFrame = CGRect(
            x: bubbleFrame.minX,
            y: sectionMinY,
            width: bubbleFrame.width,
            height: max(1, sectionMaxY - sectionMinY)
        )
        return BubbleIntegratedSectionGeometry(
            frame: sectionFrame,
            cornerRadius: min(
                NativeTimelineBubbleDrawing.cornerRadius,
                sectionFrame.height / 2
            ),
            ownsTopEdge: ownsTopEdge,
            ownsBottomEdge: ownsBottomEdge
        )
    }

    static func bubbleConcentricCornerRadius(
        for frame: CGRect,
        in bubbleRegion: NativeTimelineBubbleRegion?,
        fallback: CGFloat
    ) -> CGFloat {
        guard let bubbleRegion else { return fallback }
        let outer = bubbleRegion.frame
        let insets = [
            frame.minX - outer.minX,
            outer.maxX - frame.maxX,
            frame.minY - outer.minY,
            outer.maxY - frame.maxY,
        ].filter { $0 >= 0 }
        guard let nearestInset = insets.min() else { return fallback }
        return min(
            frame.height / 2,
            max(4, NativeTimelineBubbleDrawing.cornerRadius - nearestInset)
        )
    }

    static func spoilerConcealedBase(
        in frame: CGRect,
        cornerRadius: CGFloat
    ) {
        NSColor(
            srgbRed: 0.12,
            green: 0.125,
            blue: 0.14,
            alpha: 1
        ).setFill()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: cornerRadius
        ).fill()
    }

    /// Discord's thread card: the name and message count, then the thread's
    /// latest message or an empty state.
    static func threadSummary(
        _ thread: MessageThreadSummary,
        preview: Message?,
        message: Message,
        model: AppModel?,
        in frame: CGRect
    ) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: 8
        ).fill()
        let inset: CGFloat = 10
        let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let nameWidth = min(
            NativeTimelineReplyMetrics.textWidth(thread.name, font: nameFont),
            frame.width * 0.6
        )
        text(
            thread.name,
            in: CGRect(x: frame.minX + inset, y: frame.minY + 7, width: nameWidth, height: 18),
            font: nameFont,
            color: .labelColor
        )
        text(
            NativeTimelineThreadCard.countText(thread),
            in: CGRect(
                x: frame.minX + inset + nameWidth + 8,
                y: frame.minY + 7,
                width: max(1, frame.width - nameWidth - inset * 2 - 8),
                height: 18
            ),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .sakuraCordAccentColor
        )

        let rowFrame = CGRect(
            x: frame.minX + inset,
            y: frame.minY + 28,
            width: frame.width - inset * 2,
            height: 20
        )
        let activity = NativeTimelineThreadCard.activityText(
            thread.lastMessageID?.createdAt ?? thread.createdAt ?? thread.id.createdAt
        )
        let activityFont = NSFont.systemFont(ofSize: 11)
        let activityWidth = NativeTimelineReplyMetrics.textWidth(activity, font: activityFont)
        text(
            activity,
            in: CGRect(x: rowFrame.maxX - activityWidth, y: rowFrame.minY + 1, width: activityWidth, height: 18),
            font: activityFont,
            color: .tertiaryLabelColor
        )
        let bodyFrame = CGRect(
            x: rowFrame.minX,
            y: rowFrame.minY,
            width: max(0, rowFrame.width - activityWidth - 8),
            height: rowFrame.height
        )
        guard !thread.isArchived, thread.messageCount > 0, let preview else {
            text(
                thread.isArchived || thread.messageCount > 0
                    ? "There are no recent messages in this thread."
                    : "There are no messages in this thread yet.",
                in: bodyFrame,
                font: NativeTimelineReplyMetrics.summaryFont,
                color: .secondaryLabelColor
            )
            return
        }
        replyPreviewLine(
            MessageReplyPreview(message: preview),
            frame: bodyFrame,
            avatarFrame: CGRect(x: bodyFrame.minX, y: bodyFrame.minY + 3, width: 14, height: 14),
            trailingInset: 0,
            message: message,
            model: model
        )
    }

    static func reaction(
        _ region: NativeTimelineRowLayout.ReactionRegion,
        model: AppModel?,
        isHovered: Bool,
        countTransition: NativeTimelineReactionCountTransition?,
        hasAnimatedEmojiOverlay: Bool
    ) {
        let selected = region.reaction.didCurrentUserReact
        drawReactionBackground(region.frame, selected: selected, isHovered: isHovered)
        if !hasAnimatedEmojiOverlay { drawReactionEmoji(region, model: model) }
        drawReactionMetadata(region, selected: selected, countTransition: countTransition)
    }

    private static func drawReactionBackground(
        _ frame: CGRect,
        selected: Bool,
        isHovered: Bool
    ) {
        let shape = NSBezierPath(
            roundedRect: frame,
            xRadius: 9,
            yRadius: 9
        )
        (
            selected
                ? NSColor.sakuraCordAccentColor.withAlphaComponent(
                    isHovered ? 0.22 : 0.16
                )
                : NSColor.labelColor.withAlphaComponent(
                    isHovered ? 0.14 : 0.09
                )
        ).setFill()
        shape.fill()
        if selected {
            NSColor.sakuraCordAccentColor.withAlphaComponent(0.95).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
    }

    private static func drawReactionEmoji(
        _ region: NativeTimelineRowLayout.ReactionRegion,
        model: AppModel?
    ) {
        let reference = region.reaction.emojiReference
        if let id = reference.id {
            if let url = model?.customEmojiURLsByID[id]
                    ?? reference.imageURL(size: 64),
               let image = mediaImage(
                   for: .media(url, maximumPixelDimension: 64)
               )
            {
                drawImage(
                    image,
                    in: region.emojiFrame,
                    cornerRadius: 0,
                    fillsFrame: false
                )
            } else {
                NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(
                    concentricRoundedRect: region.emojiFrame,
                    cornerRadius: 5
                ).fill()
                systemSymbol(
                    SakuraCordSystemSymbol.emojiFaceGrinning,
                    in: region.emojiFrame,
                    color: .secondaryLabelColor,
                    inset: 4,
                    weight: .medium
                )
            }
        } else {
            let image = ComponentUnicodeEmojiRenderer.image(
                for: reference.name
            )
            let optical = region.emojiFrame.insetBy(
                dx: region.emojiFrame.width
                    * (1 - MessageReactionMetrics.nativeEmojiVisualScale) / 2,
                dy: region.emojiFrame.height
                    * (1 - MessageReactionMetrics.nativeEmojiVisualScale) / 2
            )
            drawImage(
                image,
                in: optical,
                cornerRadius: 0,
                fillsFrame: false
            )
        }
    }

    private static func drawReactionMetadata(
        _ region: NativeTimelineRowLayout.ReactionRegion,
        selected: Bool,
        countTransition: NativeTimelineReactionCountTransition?
    ) {
        if let countFrame = region.countFrame, countTransition == nil {
            reactionCount(
                region.reaction.count,
                in: countFrame,
                color: selected ? .sakuraCordAccentColor : .labelColor
            )
        }
        for avatarRegion in region.avatarRegions {
            avatar(
                name: avatarRegion.reactor.displayName,
                url: avatarRegion.reactor.avatarURL,
                in: avatarRegion.frame
            )
            NSColor.labelColor.withAlphaComponent(0.24).setStroke()
            let border = NSBezierPath(ovalIn: avatarRegion.frame.insetBy(
                dx: 0.5,
                dy: 0.5
            ))
            border.lineWidth = 1
            border.stroke()
        }
        if let overflowFrame = region.overflowFrame {
            let overflow = MessageReactionPresentation.previewPlan(
                for: region.reaction
            ).overflowCount
            text(
                "+\(overflow)",
                in: overflowFrame,
                font: NativeTimelineReactionFonts.overflow,
                color: .secondaryLabelColor,
                alignment: .center
            )
        }
    }

    static func reactionAddControl(
        in frame: CGRect,
        isHovered: Bool
    ) {
        let shape = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: 9
        )
        NSColor.labelColor.withAlphaComponent(
            isHovered ? 0.14 : 0.09
        ).setFill()
        shape.fill()
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        systemSymbol(
            SakuraCordSystemSymbol.emojiFaceGrinning,
            in: NativeTimelineReactionAddControlGeometry.iconFrame(in: frame),
            color: .labelColor,
            inset: 0,
            weight: .medium
        )
    }

    static func reactionCount(
        _ count: Int,
        in frame: CGRect,
        color: NSColor
    ) {
        text(
            String(count),
            in: frame,
            font: NativeTimelineReactionFonts.count,
            color: color,
            alignment: .center
        )
    }

    static func componentButton(
        _ region: NativeTimelineComponentLayout.ButtonRegion,
        isHovered: Bool,
        pressProgress: CGFloat,
        cornerRadius: CGFloat = 6
    ) {
        let pressProgress = min(max(pressProgress, 0), 1)
        let scale = NativeTimelineComponentButtonVisualState.scale(
            pressProgress: pressProgress
        )
        let brightness =
            NativeTimelineComponentButtonVisualState.brightness(
                isHovered: isHovered,
                pressProgress: pressProgress
            )
        let opacity: CGFloat = region.isDisabled ? 0.65 : 1
        let background = adjustedBrightness(
            roleColor(
                DiscordComponentButtonAppearance.backgroundHex(
                    for: region.style
                )
            ) ?? .secondaryLabelColor,
            amount: brightness
        )

        NSGraphicsContext.saveGraphicsState()
        if abs(scale - 1) > 0.0001 {
            let transform = NSAffineTransform()
            transform.translateX(
                by: region.frame.midX,
                yBy: region.frame.midY
            )
            transform.scaleX(by: scale, yBy: scale)
            transform.translateX(
                by: -region.frame.midX,
                yBy: -region.frame.midY
            )
            transform.concat()
        }

        background.withAlphaComponent(opacity).setFill()
        NSBezierPath(
            concentricRoundedRect: region.frame,
            cornerRadius: cornerRadius
        ).fill()
        adjustedBrightness(
            .white,
            amount: brightness
        ).withAlphaComponent(
            NativeTimelineComponentButtonVisualState.borderAlpha(
                isHovered: isHovered,
                isEnabled: !region.isDisabled
            ) * opacity
        ).setStroke()
        let border = NSBezierPath(
            concentricRoundedRect: region.frame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: max(0, cornerRadius - 0.5)
        )
        border.lineWidth = 1
        border.stroke()
        drawComponentButtonContent(
            region,
            brightness: brightness,
            opacity: opacity
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawComponentButtonContent(
        _ region: NativeTimelineComponentLayout.ButtonRegion,
        brightness: CGFloat,
        opacity: CGFloat
    ) {
        var horizontalPosition = region.frame.minX + 12
        if let emoji = region.emoji {
            componentEmoji(emoji, in: CGRect(
                x: horizontalPosition,
                y: region.frame.midY - 8,
                width: 16,
                height: 16
            ))
            horizontalPosition += 22
        } else if region.style == .premium {
            systemSymbol(
                "sparkles",
                in: CGRect(
                    x: horizontalPosition,
                    y: region.frame.midY - 8,
                    width: 16,
                    height: 16
                ),
                color: adjustedBrightness(
                    .white,
                    amount: brightness
                ).withAlphaComponent(opacity),
                inset: 1
            )
            horizontalPosition += 22
        }
        let trailingAllowance: CGFloat = region.url == nil ? 12 : 30
        text(
            region.label,
            in: CGRect(
                x: horizontalPosition,
                y: region.frame.minY,
                width: max(
                    1,
                    region.frame.maxX - horizontalPosition - trailingAllowance
                ),
                height: region.frame.height
            ),
            font: NativeTimelineComponentButtonMetrics.font,
            color: adjustedBrightness(
                .white,
                amount: brightness
            ).withAlphaComponent(
                region.isDisabled ? 0.62 : 1
            )
        )
        if region.url != nil {
            systemSymbol(
                "arrow.up.right",
                in: CGRect(
                    x: region.frame.maxX - 22,
                    y: region.frame.midY - 7,
                    width: 14,
                    height: 14
                ),
                color: adjustedBrightness(
                    .white,
                    amount: brightness
                ).withAlphaComponent(opacity),
                inset: 1
            )
        }
    }

    static func adjustedBrightness(
        _ color: NSColor,
        amount: CGFloat
    ) -> NSColor {
        guard abs(amount) > 0.0001,
              let rgb = color.usingColorSpace(.deviceRGB)
        else { return color }
        return NSColor(
            deviceRed: min(max(rgb.redComponent + amount, 0), 1),
            green: min(max(rgb.greenComponent + amount, 0), 1),
            blue: min(max(rgb.blueComponent + amount, 0), 1),
            alpha: rgb.alphaComponent
        )
    }

    static func componentSelect(
        _ region: NativeTimelineComponentLayout.SelectRegion,
        cornerRadius: CGFloat = 11
    ) {
        let opacity: CGFloat = region.isDisabled ? 0.65 : 1
        NSColor.labelColor.withAlphaComponent(0.075 * opacity).setFill()
        NSBezierPath(
            concentricRoundedRect: region.frame,
            cornerRadius: cornerRadius
        ).fill()
        NSColor.labelColor.withAlphaComponent(0.10 * opacity).setStroke()
        let border = NSBezierPath(
            concentricRoundedRect: region.frame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: max(0, cornerRadius - 0.5)
        )
        border.lineWidth = 1
        border.stroke()

        let options = region.selectedOptions.map {
            ComponentChoiceOptionPresentation.fieldOption(
                $0,
                selectKind: region.kind
            )
        }
        if options.isEmpty {
            SelectionFieldRenderer.drawText(
                region.placeholder,
                in: region.frame,
                color: .placeholderTextColor,
                opacity: opacity
            )
        } else {
            componentSelectTokens(
                options,
                in: region.frame,
                opacity: opacity
            )
        }
        SelectionFieldRenderer.drawChevron(
            in: region.frame,
            opacity: opacity
        )
    }

    static func componentSelectTokens(
        _ options: [SelectionFieldOption<String>],
        in frame: CGRect,
        opacity: CGFloat
    ) {
        let available = max(40, frame.width - 50)
        var origin = CGPoint(x: frame.minX + 11, y: frame.minY + 7)
        for option in options {
            let tokenWidth = SelectionFieldLayoutMetrics.tokenWidth(option, availableWidth: available)
            if origin.x > frame.minX + 11, origin.x + tokenWidth > frame.minX + 11 + available {
                origin.x = frame.minX + 11
                origin.y += 34
            }
            let image = SelectionFieldRenderer.tokenImage(
                option: option, font: SelectionFieldLayoutMetrics.font,
                leadingImage: componentSelectLeadingImage(option.leading), maximumWidth: tokenWidth
            )
            image.draw(
                in: CGRect(origin: origin, size: image.size),
                from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: nil
            )
            origin.x += tokenWidth + 6
        }

    }

    static func componentSelectLeadingImage(
        _ leading: SelectionFieldLeading
    ) -> NSImage? {
        let url: URL? = switch leading {
        case .role(_, let iconURL, _): iconURL
        case .remoteImage(let url, _, _): url
        case .none, .systemImage, .text: nil
        }
        guard let url else { return nil }
        if url.isFileURL { return NSImage(contentsOf: url) }
        return mediaImage(for: .media(url, maximumPixelDimension: 64))
    }

    static func componentFile(
        _ region: NativeTimelineComponentLayout.FileRegion,
        cornerRadius: CGFloat = DiscordRichMessageMetrics.cardCornerRadius
    ) {
        componentContainer(
            region.frame,
            accentColor: nil,
            cornerRadius: cornerRadius
        )
        systemSymbol(
            "doc.fill",
            in: CGRect(
                x: region.frame.minX + 10,
                y: region.frame.midY - 12,
                width: 24,
                height: 24
            ),
            color: .secondaryLabelColor,
            inset: 1
        )
        text(
            region.title,
            in: CGRect(
                x: region.frame.minX + 44,
                y: region.frame.minY + 8,
                width: max(1, region.frame.width - 88),
                height: 18
            ),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )
        if let description = region.description, !description.isEmpty {
            text(
                description,
                in: CGRect(
                    x: region.frame.minX + 44,
                    y: region.frame.minY + 27,
                    width: max(1, region.frame.width - 88),
                    height: max(14, region.frame.height - 33)
                ),
                font: .systemFont(ofSize: 11),
                color: .secondaryLabelColor,
                lineBreakMode: .byWordWrapping
            )
        }
        systemSymbol(
            "arrow.down.circle",
            in: CGRect(
                x: region.frame.maxX - 32,
                y: region.frame.midY - 10,
                width: 20,
                height: 20
            ),
            color: .secondaryLabelColor,
            inset: 1
        )
    }

    static func componentEmoji(
        _ emoji: EmojiReference,
        in frame: CGRect
    ) {
        if emoji.id != nil,
           let url = emoji.imageURL(size: 32),
           let image = mediaImage(
               for: .media(url, maximumPixelDimension: 64)
           )
        {
            drawImage(
                image,
                in: frame.insetBy(dx: 1, dy: 1),
                cornerRadius: 3,
                fillsFrame: false
            )
            return
        }
        drawImage(
            ComponentUnicodeEmojiRenderer.image(for: emoji.name),
            in: frame.insetBy(dx: 1, dy: 1),
            cornerRadius: 0,
            fillsFrame: false
        )
    }

    static func systemSymbol(
        _ name: String,
        in frame: CGRect,
        color: NSColor,
        inset: CGFloat,
        weight: NSFont.Weight = .regular
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        let pointSize = max(
            10,
            min(frame.width, frame.height) - max(0, inset) * 2
        )
        let deviceSize = NSGraphicsContext.current?.cgContext
            .convertToDeviceSpace(CGSize(width: 1, height: 1))
        let backingScale = deviceSize.map {
            max(abs($0.width), abs($0.height))
        } ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let image = NativeTimelineSystemSymbolCache
            .rasterizedConfiguredImage(
            named: name,
            pointSize: pointSize,
            weight: weight,
            color: color,
            scale: backingScale
        )
        else { return }
        let target = frame.insetBy(
            dx: min(max(0, inset), frame.width / 2 - 1),
            dy: min(max(0, inset), frame.height / 2 - 1)
        )
        let fittedTarget = NativeTimelineSymbolGeometry.opticallyFitted(
            sourceSize: image.size,
            alignmentRect: image.alignmentRect,
            in: target
        )
        image.draw(
            in: fittedTarget,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    static func pill(_ frame: CGRect, selected: Bool) {
        let color = selected ? NSColor.sakuraCordAccentColor : NSColor.quaternaryLabelColor
        color.withAlphaComponent(selected ? 0.22 : 0.18).setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2)
            .fill()
    }

    static func mediaImage(
        for key: NativeTimelineMediaKey
    ) -> NSImage? {
        NativeTimelineMediaStore.shared.firstAnimatedFrame(for: key)
            ?? NativeTimelineMediaStore.shared.image(for: key)
    }

    static func drawImage(
        _ image: NSImage,
        in frame: CGRect,
        cornerRadius: CGFloat,
        fillsFrame: Bool
    ) {
        guard frame.width > 0, frame.height > 0,
              image.size.width > 0, image.size.height > 0
        else { return }
        let scale = fillsFrame
            ? max(frame.width / image.size.width, frame.height / image.size.height)
            : min(frame.width / image.size.width, frame.height / image.size.height)
        let destination = CGRect(
            x: frame.midX - image.size.width * scale / 2,
            y: frame.midY - image.size.height * scale / 2,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: cornerRadius
        ).addClip()
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    static func attachmentAudio(
        _ attachment: Attachment,
        in frame: CGRect
    ) {
        let title = attachment.title ?? attachment.filename
        let font = NSFont.preferredFont(forTextStyle: .body)
        let symbolSize: CGFloat = 18
        let spacing: CGFloat = 6
        let titleWidth = min(
            measuredTextWidth(title, font: font),
            max(1, frame.width - 24 - symbolSize - spacing)
        )
        let totalWidth = symbolSize + spacing + titleWidth
        let horizontalPosition = frame.midX - totalWidth / 2
        systemSymbol(
            "waveform",
            in: CGRect(
                x: horizontalPosition,
                y: frame.midY - symbolSize / 2,
                width: symbolSize,
                height: symbolSize
            ),
            color: .labelColor,
            inset: 1
        )
        text(
            title,
            in: CGRect(
                x: horizontalPosition + symbolSize + spacing,
                y: frame.midY - 10,
                width: titleWidth,
                height: 20
            ),
            font: font,
            color: .labelColor
        )
    }

}
