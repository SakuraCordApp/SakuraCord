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
    let model: AppModel?
    let messageID: MessageID
    let layoutIndex: Int
    let textSelection: NativeTimelineTextSelection?
    let hoveredMention: NativeTimelineMentionHover?
    let hoveredTextLink: NativeTimelineTextLinkHover?
    let hoveredTextSpoiler: NativeTimelineTextSpoilerHover?
    let revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState
    let spoilerRevealStore: NativeTimelineSpoilerRevealStore?
    let hoveredComponentButton: NativeTimelineComponentButtonTarget?
    let pressedComponentButton: NativeTimelineComponentButtonTarget?
    let componentButtonPressProgress: CGFloat
}

extension NativeTimelineRowPainter {
    static var componentsDrawOperation:
        @MainActor (NativeTimelineComponentsDrawInput) -> Void
    {
        { input in
            let layout = input.layout
            let model = input.model
            let messageID = input.messageID
            let layoutIndex = input.layoutIndex
            let textSelection = input.textSelection
            let hoveredMention = input.hoveredMention
            let hoveredTextLink = input.hoveredTextLink
            let hoveredTextSpoiler = input.hoveredTextSpoiler
            let revealedTextSpoilerState = input.revealedTextSpoilerState
            let spoilerRevealStore = input.spoilerRevealStore
            let hoveredComponentButton = input.hoveredComponentButton
            let pressedComponentButton = input.pressedComponentButton
            let componentButtonPressProgress = input.componentButtonPressProgress
        let hiddenContainerFrames =
            spoilerRevealStore.map {
                NativeTimelineSpoilerConcealmentPolicy
                    .hiddenContainerFrames(
                        in: layout,
                        messageID: messageID,
                        store: $0
                    )
            } ?? []
        @MainActor
        func isInsideHiddenContainer(_ frame: CGRect) -> Bool {
            NativeTimelineSpoilerConcealmentPolicy
                .isInsideHiddenContainer(
                    frame,
                    hiddenContainerFrames: hiddenContainerFrames
                )
        }
        @MainActor
        func isConcealed(
            contentID: String,
            isSpoiler: Bool
        ) -> Bool {
            spoilerRevealStore.map {
                NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                    messageID: messageID,
                    contentID: contentID,
                    isSpoiler: isSpoiler,
                    store: $0
                )
            } ?? false
        }

        for container in layout.containers {
            let isHidden = hiddenContainerFrames.contains(container.frame)
            if !isHidden, isInsideHiddenContainer(container.frame) {
                continue
            }
            componentContainer(
                container.frame,
                accentColor: container.accentColor
            )
            if isHidden {
                spoilerConcealedBase(
                    in: container.frame,
                    cornerRadius:
                        DiscordRichMessageMetrics.cardCornerRadius
                )
            }
        }
        for separator in layout.separators
        where separator.drawsDivider
            && !isInsideHiddenContainer(separator.frame) {
            NSColor.separatorColor.setFill()
            CGRect(
                x: separator.frame.minX,
                y: separator.frame.midY - 0.5,
                width: separator.frame.width,
                height: 1
            ).fill()
        }
        for (textIndex, region) in layout.textRegions.enumerated()
        where !isInsideHiddenContainer(region.frame) {
            attributedText(
                region.text,
                in: region.frame,
                model: model,
                selectionRange:
                    textSelection?.itemIdentifier == .message(messageID)
                        && textSelection?.region == .component(
                            layoutIndex: layoutIndex,
                            textIndex: textIndex
                        )
                    ? textSelection?.range
                    : nil,
                hoveredMentionCharacterIndex:
                    hoveredMention?.itemIdentifier == .message(messageID)
                        && hoveredMention?.region == .component(
                            layoutIndex: layoutIndex,
                            textIndex: textIndex
                        )
                    ? hoveredMention?.characterIndex
                    : nil,
                hoveredLinkCharacterIndex:
                    hoveredTextLink?.itemIdentifier == .message(messageID)
                        && hoveredTextLink?.region == .component(
                            layoutIndex: layoutIndex,
                            textIndex: textIndex
                        )
                    ? hoveredTextLink?.characterIndex
                    : nil,
                hoveredSpoilerRangeLocation:
                    hoveredTextSpoiler?.itemIdentifier
                        == .message(messageID)
                        && hoveredTextSpoiler?.region == .component(
                            layoutIndex: layoutIndex,
                            textIndex: textIndex
                        )
                    ? hoveredTextSpoiler?.rangeLocation
                    : nil,
                revealedSpoilerLocations:
                    revealedTextSpoilerState.locations(
                        in: .component(
                            layoutIndex: layoutIndex,
                            textIndex: textIndex
                        )
                    )
            )
        }
        for region in layout.images
        where !isInsideHiddenContainer(region.frame) {
            if isConcealed(
                contentID: region.componentID,
                isSpoiler: region.isSpoiler
            ) {
                spoilerConcealedBase(
                    in: region.frame,
                    cornerRadius: region.cornerRadius
                )
                continue
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(
                concentricRoundedRect: region.frame,
                cornerRadius: region.cornerRadius
            ).fill()
            if let image = mediaImage(
                for: .media(
                    region.displayURL,
                    maximumPixelDimension: region.maximumPixelDimension
                )
            ) {
                drawImage(
                    image,
                    in: region.frame,
                    cornerRadius: region.cornerRadius,
                    fillsFrame: false
                )
            } else {
                systemSymbol(
                    "photo",
                    in: region.frame,
                    color: .secondaryLabelColor,
                    inset: 22
                )
            }
        }
        for region in layout.media
        where !isInsideHiddenContainer(region.frame) {
            if isConcealed(
                contentID: region.componentID,
                isSpoiler: region.isSpoiler
            ) {
                spoilerConcealedBase(
                    in: region.frame,
                    cornerRadius: 8
                )
                continue
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(
                concentricRoundedRect: region.frame,
                cornerRadius: 8
            ).fill()
            if let image = mediaImage(
                for: .media(region.displayURL)
            ) {
                drawImage(
                    image,
                    in: region.frame,
                    cornerRadius: 8,
                    fillsFrame: true
                )
            } else if region.isVideo {
                systemSymbol(
                    "film",
                    in: region.frame,
                    color: .secondaryLabelColor,
                    inset: 30
                )
            }
            if region.isVideo {
                mediaPlayGlyph(in: region.frame)
            }
        }
        for region in layout.files
        where !isInsideHiddenContainer(region.frame) {
            if isConcealed(
                contentID: region.componentID,
                isSpoiler: region.isSpoiler
            ) {
                spoilerConcealedBase(
                    in: region.frame,
                    cornerRadius:
                        DiscordRichMessageMetrics.cardCornerRadius
                )
                continue
            }
            componentFile(region)
        }
        for region in layout.buttons
        where !isInsideHiddenContainer(region.frame) {
            let target = NativeTimelineComponentButtonTarget(
                messageID: messageID,
                componentID: region.componentID
            )
            componentButton(
                region,
                isHovered: hoveredComponentButton == target,
                pressProgress:
                    pressedComponentButton == target
                        ? componentButtonPressProgress
                        : 0
            )
        }
        for region in layout.selects
        where !isInsideHiddenContainer(region.frame) {
            componentSelect(region)
        }
        for region in layout.unsupported
        where !isInsideHiddenContainer(region.frame) {
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
    }

    static func drawComponents(_ input: NativeTimelineComponentsDrawInput) {
        componentsDrawOperation(input)
    }

    static func componentContainer(
        _ frame: CGRect,
        accentColor: UInt32?
    ) {
        let shape = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: DiscordRichMessageMetrics.cardCornerRadius
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
            cornerRadius: DiscordRichMessageMetrics.cardCornerRadius - 0.5
        )
        border.lineWidth = 1
        border.stroke()
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

    static func threadSummary(
        _ thread: MessageThreadSummary,
        in frame: CGRect
    ) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: 8
        ).fill()
        systemSymbol(
            "bubble.left.and.bubble.right",
            in: CGRect(
                x: frame.minX + 9,
                y: frame.midY - 9,
                width: 18,
                height: 18
            ),
            color: .labelColor,
            inset: 1
        )
        text(
            thread.name,
            in: CGRect(
                x: frame.minX + 35,
                y: frame.minY + 6,
                width: max(1, frame.width - 70),
                height: 18
            ),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor
        )
        text(
            "\(thread.messageCount) replies · \(thread.memberCount) participants",
            in: CGRect(
                x: frame.minX + 35,
                y: frame.minY + 23,
                width: max(1, frame.width - 70),
                height: 16
            ),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )
        systemSymbol(
            "chevron.right",
            in: CGRect(
                x: frame.maxX - 25,
                y: frame.midY - 7,
                width: 14,
                height: 14
            ),
            color: .secondaryLabelColor,
            inset: 2
        )
    }

    static var reactionDrawOperation:
        @MainActor (
            NativeTimelineRowLayout.ReactionRegion,
            AppModel?,
            Bool,
            NativeTimelineReactionCountTransition?
        ) -> Void
    {
        { region, model, isHovered, countTransition in
        let selected = region.reaction.didCurrentUserReact
        let shape = NSBezierPath(
            roundedRect: region.frame,
            xRadius: 9,
            yRadius: 9
        )
        (
            selected
                ? NSColor.controlAccentColor.withAlphaComponent(
                    isHovered ? 0.22 : 0.16
                )
                : NSColor.labelColor.withAlphaComponent(
                    isHovered ? 0.14 : 0.09
                )
        ).setFill()
        shape.fill()
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }

        let reference = region.reaction.emojiReference
        if let id = reference.id {
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(
                concentricRoundedRect: region.emojiFrame,
                cornerRadius: 5
            ).fill()
            systemSymbol(
                "face.smiling",
                in: region.emojiFrame,
                color: .secondaryLabelColor,
                inset: 4,
                weight: .medium
            )
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
        if let countFrame = region.countFrame, countTransition == nil {
            reactionCount(
                region.reaction.count,
                in: countFrame,
                color: selected ? .controlAccentColor : .labelColor
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
                font: .monospacedDigitSystemFont(
                    ofSize: 10,
                    weight: .bold
                ),
                color: .secondaryLabelColor,
                alignment: .center
            )
        }

        }
    }

    static func reaction(
        _ region: NativeTimelineRowLayout.ReactionRegion,
        model: AppModel?,
        isHovered: Bool,
        countTransition: NativeTimelineReactionCountTransition?
    ) {
        reactionDrawOperation(region, model, isHovered, countTransition)
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
            "face.smiling.inverse",
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
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .semibold
        )
        text(
            String(count),
            in: frame,
            font: font,
            color: color,
            alignment: .center
        )
    }

    static var componentButtonDrawOperation:
        @MainActor (NativeTimelineComponentLayout.ButtonRegion, Bool, CGFloat) -> Void
    {
        { region, isHovered, pressProgress in
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
            cornerRadius: 6
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
            cornerRadius: 5.5
        )
        border.lineWidth = 1
        border.stroke()

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
        NSGraphicsContext.restoreGraphicsState()

        }
    }

    static func componentButton(
        _ region: NativeTimelineComponentLayout.ButtonRegion,
        isHovered: Bool,
        pressProgress: CGFloat
    ) {
        componentButtonDrawOperation(region, isHovered, pressProgress)
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
        _ region: NativeTimelineComponentLayout.SelectRegion
    ) {
        let opacity: CGFloat = region.isDisabled ? 0.65 : 1
        NSColor.labelColor.withAlphaComponent(0.075 * opacity).setFill()
        NSBezierPath(
            concentricRoundedRect: region.frame,
            cornerRadius: 7
        ).fill()
        NSColor.labelColor.withAlphaComponent(0.16 * opacity).setStroke()
        let border = NSBezierPath(
            concentricRoundedRect: region.frame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: 6.5
        )
        border.lineWidth = 1
        border.stroke()
        text(
            region.placeholder,
            in: CGRect(
                x: region.frame.minX + 12,
                y: region.frame.minY,
                width: max(1, region.frame.width - 54),
                height: region.frame.height
            ),
            font: .systemFont(ofSize: 13),
            color: NSColor.labelColor.withAlphaComponent(opacity)
        )
        systemSymbol(
            "chevron.down",
            in: CGRect(
                x: region.frame.maxX - 26,
                y: region.frame.midY - 7,
                width: 14,
                height: 14
            ),
            color: NSColor.secondaryLabelColor.withAlphaComponent(opacity),
            inset: 1
        )
    }

    static func componentFile(
        _ region: NativeTimelineComponentLayout.FileRegion
    ) {
        componentContainer(region.frame, accentColor: nil)
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
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: weight
        ).applying(
            NSImage.SymbolConfiguration(paletteColors: [color])
        )
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
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
        let color = selected ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor
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
