import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

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
    let textSpoilerHover: [NativeTimelineTextSpoilerHover: CGFloat]
    let revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState
    var spoilerRevealStore: NativeTimelineSpoilerRevealStore?
    let hoveredComponentButton: NativeTimelineComponentButtonTarget?
    let activeComponentChoiceTarget: NativeTimelineComponentSelectTarget?
    let pressedComponentButton: NativeTimelineComponentButtonTarget?
    let componentButtonPressProgress: CGFloat
    let fileCardHoverProgress: [NativeTimelineComponentButtonTarget: CGFloat]
    let fileCardFinishProgress: [NativeTimelineComponentButtonTarget: CGFloat]
    let animatedOverlayRoles: Set<NativeTimelineCanvasView.AnimatedMediaOverlayRole>
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
        SystemSymbolImageCache.schedulePostFirstFramePrewarm(
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
                discordCard(
                    container.frame,
                    cornerRadius: container.cornerRadius,
                    accent: roleColor(container.accentColor)
                )
            }
            if isHidden {
                NativeTimelineSpoilerCover.draw(covering: true, in: container.frame, cornerRadius: container.cornerRadius) {
                    var revealed = input
                    revealed.spoilerRevealStore = nil
                    drawComponents(revealed)
                }
            }
        }
        for separator in input.layout.separators
        where separator.drawsDivider
            && !isInsideHiddenComponentContainer(
                separator.frame,
                hiddenContainerFrames: hiddenContainerFrames
            ) {
            // Discord draws dividers in its subtle border colour, like the
            // container's own edge.
            NativeTimelineSemanticColor.opacity(.labelColor, 0.10).setFill()
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
                bubble: input.bubbleRegion,
                selectionRange: input.textSelection.scoped(to: input.itemIdentifier, region: textRegion)?.range,
                hoveredMentionCharacterIndex:
                    input.hoveredMention.scoped(to: input.itemIdentifier, region: textRegion)?.characterIndex,
                hoveredLinkCharacterIndex:
                    input.hoveredTextLink.scoped(to: input.itemIdentifier, region: textRegion)?.characterIndex,
                spoilerHoverProgress: input.textSpoilerHover.progress(in: input.itemIdentifier, region: textRegion),
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
            NativeTimelineSpoilerCover.draw(
                covering: isConcealedComponentContent(contentID: region.componentID, isSpoiler: region.isSpoiler, input: input),
                in: region.frame,
                cornerRadius: region.cornerRadius
            ) {
                drawComponentImage(region)
            }
        }
    }

    private static func drawComponentImage(_ region: NativeTimelineComponentLayout.ImageRegion) {
        // Discord crops a thumbnail to fill its square.
        drawMediaSurface(
            in: region.frame,
            cornerRadius: region.cornerRadius,
            backdrop: NSColor.secondaryLabelColor.withAlphaComponent(0.08),
            image: mediaImage(for: region.mediaKey),
            fillsFrame: true,
            placeholder: region.placeholder,
            fallbackSymbol: ("photo", InterfaceScale.metric(22))
        )
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
            NativeTimelineSpoilerCover.draw(
                covering: isConcealedComponentContent(contentID: region.componentID, isSpoiler: region.isSpoiler, input: input),
                in: region.frame,
                cornerRadius: DiscordRichMessageMetrics.px(8)
            ) {
                drawComponentMediaItem(region)
            }
        }
    }

    private static func drawComponentMediaItem(_ region: NativeTimelineComponentLayout.MediaRegion) {
        drawMediaSurface(
            in: region.frame,
            cornerRadius: DiscordRichMessageMetrics.px(8),
            backdrop: NSColor.secondaryLabelColor.withAlphaComponent(0.10),
            image: region.previewURL.flatMap { mediaImage(for: .media($0)) },
            fillsFrame: true,
            placeholder: region.placeholder,
            fallbackSymbol: region.isVideo ? ("film", InterfaceScale.metric(30)) : nil,
            isVideo: region.isVideo
        )
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
            NativeTimelineSpoilerCover.draw(
                covering: isConcealedComponentContent(contentID: region.componentID, isSpoiler: region.isSpoiler, input: input),
                in: region.frame,
                cornerRadius: region.card.cornerRadius
            ) {
                fileCard(
                    region.card,
                    messageID: input.messageID,
                    bubbleRegion: input.bubbleRegion,
                    state: input.model?.attachmentDownloads.states[region.attachment.id],
                    finishProgress: input.fileCardFinishProgress,
                    pointer: .init(
                        hovered: input.hoveredComponentButton, hoverProgress: input.fileCardHoverProgress,
                        pressed: input.pressedComponentButton, pressProgress: input.componentButtonPressProgress
                    )
                )
            }
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
                hasAnimatedEmojiOverlay: input.animatedOverlayRoles.contains(
                    .componentButton(input.layoutIndex, region.componentID)
                ),
                cornerRadius: bubbleConcentricCornerRadius(
                    for: region.frame,
                    in: input.bubbleRegion,
                    fallback: NativeTimelineComponentButtonMetrics.cornerRadius
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
                cornerRadius: bubbleConcentricCornerRadius(
                    for: region.frame, in: input.bubbleRegion, fallback: SelectionFieldLayoutMetrics.cornerRadius
                )
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
                    width: InterfaceScale.metric(16),
                    height: region.frame.height
                ),
                color: .secondaryLabelColor,
                inset: 1
            )
            text(
                region.label,
                in: CGRect(
                    x: region.frame.minX + InterfaceScale.metric(22),
                    y: region.frame.minY,
                    width: max(1, region.frame.width - InterfaceScale.metric(22)),
                    height: region.frame.height
                ),
                font: .messageSystemFont(ofSize: 11),
                color: .secondaryLabelColor
            )
        }
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
                width: InterfaceScale.metric(4),
                height: geometry.frame.height
            ).fill()
            NSGraphicsContext.restoreGraphicsState()
            // The rail runs along the leading edge, so it only reaches an
            // incoming bubble's tail.
            if geometry.ownsBottomEdge,
               bubbleRegion.showsTail,
               !bubbleRegion.isOutgoing,
               let accentColor = roleColor(accentColor)
            {
                accentColor.setFill()
                NativeTimelineBubbleDrawing.fillTailProtrusion(of: bubbleRegion)
            }
        }

        if drawsTopSeparator {
            NSGraphicsContext.saveGraphicsState()
            NativeTimelineBubbleDrawing.bodyPath(for: bubbleRegion).addClip()
            NSBezierPath(rect: CGRect(
                x: geometry.frame.minX - 1,
                y: geometry.frame.minY - 1,
                width: geometry.frame.width + InterfaceScale.metric(2),
                height: geometry.cornerRadius + InterfaceScale.metric(2)
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
            // A section along the bottom edge continues into the tail.
            if geometry.ownsBottomEdge {
                NativeTimelineBubbleDrawing.fillTailProtrusion(of: bubbleRegion)
            }
        }
    }

    static let bubbleIntegratedSectionTintColor = NSColor(
        name: nil
    ) { appearance in
        appearance.isDark
            ? NSColor.black.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.055)
    }

    private static func bubbleIntegratedSectionGeometry(
        _ frame: CGRect,
        bubbleRegion: NativeTimelineBubbleRegion
    ) -> BubbleIntegratedSectionGeometry {
        let bubbleFrame = bubbleRegion.frame
        // Content within the bubble's own padding of an edge reaches it.
        let edgeSlack = NativeTimelineBubbleLayout.verticalPadding + 0.5
        let ownsTopEdge = frame.minY - bubbleFrame.minY <= edgeSlack
        let ownsBottomEdge = bubbleFrame.maxY - frame.maxY <= edgeSlack
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

    static func reaction(
        _ region: NativeTimelineRowLayout.ReactionRegion,
        model: AppModel?,
        isHovered: Bool,
        hasAnimatedEmojiOverlay: Bool
    ) {
        let selected = region.reaction.didCurrentUserReact
        drawReactionBackground(region.frame, selected: selected, isHovered: isHovered)
        if !hasAnimatedEmojiOverlay { drawReactionEmoji(region, model: model) }
        if let countFrame = region.countFrame {
            reactionCount(
                region.reaction.count,
                in: countFrame,
                color: selected ? .sakuraCordAccentColor : .labelColor
            )
        }
        drawReactionAvatars(region)
    }

    static func drawReactionBackground(
        _ frame: CGRect,
        selected: Bool,
        isHovered: Bool
    ) {
        let shape = NSBezierPath(
            roundedRect: frame,
            xRadius: InterfaceScale.metric(9),
            yRadius: InterfaceScale.metric(9)
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
            shape.lineWidth = 1
            shape.stroke()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
    }

    static func drawReactionEmoji(
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
                    cornerRadius: InterfaceScale.metric(5)
                ).fill()
                systemSymbol(
                    SakuraCordSystemSymbol.emojiFaceGrinning,
                    in: region.emojiFrame,
                    color: .secondaryLabelColor,
                    inset: InterfaceScale.metric(4),
                    weight: .medium
                )
            }
        } else {
            let image = ComponentUnicodeEmojiRenderer.image(
                for: reference.name
            )
            drawImage(
                image,
                in: region.emojiFrame,
                cornerRadius: 0,
                fillsFrame: false
            )
        }
    }

    static func drawReactionAvatars(_ region: NativeTimelineRowLayout.ReactionRegion) {
        let avatars = region.avatarRegions.map {
            (frame: $0.frame, name: $0.reactor.displayName, url: $0.reactor.avatarURL, isPlaceholder: false)
        } + region.placeholderAvatarFrames.map {
            (frame: $0, name: "", url: nil as URL?, isPlaceholder: true)
        }
        for avatar in avatars {
            let isLoadingImage = avatar.url.map { mediaImage(for: .avatar($0)) == nil } ?? false
            if avatar.isPlaceholder || isLoadingImage {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(ovalIn: avatar.frame).fill()
            } else {
                self.avatar(name: avatar.name, url: avatar.url, in: avatar.frame)
            }
            NSColor.labelColor.withAlphaComponent(0.24).setStroke()
            let border = NSBezierPath(ovalIn: avatar.frame.insetBy(
                dx: 0.5,
                dy: 0.5
            ))
            border.lineWidth = 1
            border.stroke()
        }
    }

    static func reactionAddControl(
        in frame: CGRect,
        isHovered: Bool
    ) {
        let shape = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: InterfaceScale.metric(9)
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
            color: NSColor.labelColor.withAlphaComponent(0.8),
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
        hasAnimatedEmojiOverlay: Bool,
        cornerRadius: CGFloat = NativeTimelineComponentButtonMetrics.cornerRadius
    ) {
        // Discord darkens a button on hover and further while pressed, and
        // dims a disabled one to half opacity without either.
        let isDimmed = region.opacity < 1
        let pressProgress = isDimmed ? 0 : min(max(pressProgress, 0), 1)
        let hover: CGFloat = !isDimmed && isHovered ? 1 : 0
        let isDark = NSAppearance.currentDrawing().isDark
        let fill: NSColor
        let border: NSColor
        let foreground: NSColor
        if let fills = DiscordComponentButtonAppearance.solidFillHexes(for: region.style)?.compactMap(roleColor) {
            let settled = fills[0].blended(withFraction: hover, of: fills[1]) ?? fills[0]
            fill = settled.blended(withFraction: pressProgress, of: fills[2]) ?? settled
            border = NSColor.white.withAlphaComponent(0.08)
            foreground = .white
        } else {
            let alphas = DiscordComponentButtonAppearance.secondaryFillAlphas(isDark: isDark)
            let settled = alphas[0] + (alphas[1] - alphas[0]) * hover
            fill = DiscordEmbedPalette.grey.withAlphaComponent(settled + (alphas[2] - settled) * pressProgress)
            border = SakuraCordThemeStore.shared.committedTheme.discordTinted(
                DiscordEmbedPalette.grey.withAlphaComponent(DiscordComponentButtonAppearance.secondaryBorderAlpha(isDark: isDark)),
                isDark: isDark
            )
            foreground = .labelColor
        }

        NSGraphicsContext.saveGraphicsState()
        // A press also dips the button about its centre.
        concatScale(
            NativeTimelineComponentButtonVisualState.scale(pressProgress: pressProgress),
            aboutCenterOf: region.frame
        )
        let context = NSGraphicsContext.current?.cgContext
        if isDimmed {
            context?.setAlpha(region.opacity)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        fill.setFill()
        NSBezierPath(concentricRoundedRect: region.frame, cornerRadius: cornerRadius).fill()
        border.setStroke()
        NSBezierPath.strokeHairline(region.frame, cornerRadius: cornerRadius)
        drawComponentButtonContent(region, color: foreground, drawsEmoji: !hasAnimatedEmojiOverlay)
        if isDimmed { context?.endTransparencyLayer() }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawComponentButtonContent(
        _ region: NativeTimelineComponentLayout.ButtonRegion,
        color: NSColor,
        drawsEmoji: Bool
    ) {
        // The row's loading-dots overlay replaces the label.
        guard !region.isLoading else { return }
        var horizontalPosition = region.contentMinX
        let glyphSize = DiscordComponentEmojiMetrics.buttonSize
        let glyphFrame = CGRect(
            x: horizontalPosition, y: region.frame.midY - glyphSize / 2, width: glyphSize, height: glyphSize
        )
        if let emoji = region.emoji {
            // An animated emoji plays in its own overlay, at the button's
            // opacity, so the painter leaves its slot empty.
            if drawsEmoji { componentEmoji(emoji, in: glyphFrame) }
            horizontalPosition += NativeTimelineComponentButtonMetrics.leadingGlyphAdvance
        } else if region.style == .premium {
            systemSymbol("sparkles", in: glyphFrame, color: color, inset: 1)
            horizontalPosition += NativeTimelineComponentButtonMetrics.leadingGlyphAdvance
        }
        let linkAdvance = region.url == nil ? 0 : NativeTimelineComponentButtonMetrics.linkIconAdvance
        let labelMaxX = min(
            region.frame.maxX - NativeTimelineComponentButtonMetrics.horizontalPadding,
            region.contentMinX + region.contentWidth
        ) - linkAdvance
        text(
            region.label,
            in: CGRect(
                x: horizontalPosition,
                y: region.frame.minY,
                width: max(1, labelMaxX - horizontalPosition),
                height: region.frame.height
            ),
            font: NativeTimelineComponentButtonMetrics.font,
            color: color
        )
        if region.url != nil {
            let iconSize = NativeTimelineComponentButtonMetrics.linkIconSize
            DiscordLaunchIcon.draw(
                in: CGRect(
                    x: labelMaxX + linkAdvance - iconSize,
                    y: region.frame.midY - iconSize / 2,
                    width: iconSize,
                    height: iconSize
                ),
                color: color
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
        cornerRadius: CGFloat
    ) {
        let opacity: CGFloat = region.isDisabled ? 0.65 : 1
        NSColor.labelColor.withAlphaComponent(0.075 * opacity).setFill()
        NSBezierPath(
            concentricRoundedRect: region.frame,
            cornerRadius: cornerRadius
        ).fill()
        // The open field's resting border.
        NSColor.labelColor.withAlphaComponent(0.16 * opacity).setStroke()
        NSBezierPath.strokeHairline(region.frame, cornerRadius: cornerRadius)

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
                color: .secondaryLabelColor,
                opacity: opacity
            )
        } else {
            componentSelectTokens(
                options,
                in: region.frame,
                opacity: opacity
            )
        }
        if !region.isLoading {
            SelectionFieldRenderer.drawChevron(
                in: region.frame,
                opacity: opacity
            )
        }
    }

    static func componentSelectTokens(
        _ options: [SelectionFieldOption<String>],
        in frame: CGRect,
        opacity: CGFloat
    ) {
        let metrics = SelectionFieldLayoutMetrics.self
        let available = metrics.tokenAvailableWidth(in: frame.width)
        let leadingX = frame.minX + metrics.leadingInset
        var origin = CGPoint(x: leadingX, y: 0)
        var placements: [(option: SelectionFieldOption<String>, frame: CGRect)] = []
        for option in options {
            let tokenWidth = metrics.tokenWidth(option, availableWidth: available)
            if origin.x > leadingX, origin.x + tokenWidth > leadingX + available {
                origin.x = leadingX
                origin.y += metrics.tokenHeight + metrics.tokenSpacing
            }
            placements.append((option, CGRect(origin: origin, size: CGSize(width: tokenWidth, height: metrics.tokenHeight))))
            origin.x += tokenWidth + metrics.tokenSpacing
        }
        // Like the open field, centre the token rows within its minimum height.
        let top = frame.minY + ((frame.height - (origin.y + metrics.tokenHeight)) / 2).rounded()
        for placement in placements {
            let image = SelectionFieldRenderer.tokenImage(
                option: placement.option, font: SelectionFieldLayoutMetrics.font,
                leadingImage: componentSelectLeadingImage(placement.option.leading), maximumWidth: placement.frame.width
            )
            image.draw(
                in: CGRect(origin: CGPoint(x: placement.frame.minX, y: top + placement.frame.minY), size: image.size),
                from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: nil
            )
        }
    }

    static func componentSelectLeadingImage(
        _ leading: SelectionFieldLeading
    ) -> NSImage? {
        guard let url = leading.imageURL else { return nil }
        if url.isFileURL { return fileImage(at: url) }
        return mediaImage(for: .media(url, maximumPixelDimension: 64))
    }

    /// Loaded once per file: rows draw their selects on every redraw, and
    /// reading the file each time held up the motions that redraw them.
    private static let fileImages = NSCache<NSURL, NSImage>()

    private static func fileImage(at url: URL) -> NSImage? {
        if let image = fileImages.object(forKey: url as NSURL) { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        fileImages.setObject(image, forKey: url as NSURL)
        return image
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
                cornerRadius: InterfaceScale.metric(3),
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
        guard let image = SystemSymbolImageCache
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
        for key: MediaImageKey
    ) -> NSImage? {
        MediaImageStore.shared.firstAnimatedFrame(for: key)
            ?? MediaImageStore.shared.image(for: key)
    }

    /// A media tile: an optional tinted backdrop, then the loaded image, its
    /// ThumbHash placeholder or a fallback symbol, and a play glyph on video.
    static func drawMediaSurface(
        in frame: CGRect,
        cornerRadius: CGFloat,
        backdrop: NSColor?,
        image: NSImage?,
        fillsFrame: Bool,
        placeholder: @autoclosure () -> NativeTimelineMediaPlaceholder?,
        placeholderFillsFrame: Bool = true,
        fallbackSymbol: (name: String, inset: CGFloat)?,
        isVideo: Bool = false
    ) {
        if let backdrop {
            backdrop.setFill()
            NSBezierPath(concentricRoundedRect: frame, cornerRadius: cornerRadius).fill()
        }
        if let image {
            drawImage(image, in: frame, cornerRadius: cornerRadius, fillsFrame: fillsFrame)
        } else if let placeholder = placeholder()?.image {
            drawImage(placeholder, in: frame, cornerRadius: cornerRadius, fillsFrame: placeholderFillsFrame)
        } else if let fallbackSymbol {
            systemSymbol(fallbackSymbol.name, in: frame, color: .secondaryLabelColor, inset: fallbackSymbol.inset)
        }
        if isVideo { mediaPlayGlyph(in: frame) }
    }

    /// Where an image of `size` lands when it fills or fits `frame`, centred.
    static func drawImage(
        _ image: NSImage,
        in frame: CGRect,
        cornerRadius: CGFloat,
        fillsFrame: Bool
    ) {
        guard frame.width > 0, frame.height > 0,
              image.size.width > 0, image.size.height > 0
        else { return }
        let destination = aspectRect(for: image.size, in: frame, fillsFrame: fillsFrame)
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

}
