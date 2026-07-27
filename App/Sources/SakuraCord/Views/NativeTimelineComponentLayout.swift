import AppKit
import CoreText
import SakuraCordModels

enum NativeTimelineComponentButtonMetrics {
    static let height: CGFloat = 32

    static var font: NSFont {
        .systemFont(
            ofSize: NSFont.preferredFont(
                forTextStyle: .callout
            ).pointSize,
            weight: .semibold
        )
    }
}

struct NativeTimelineComponentLayout {
    struct ContainerRegion {
        let frame: CGRect
        let componentID: String
        let accentColor: UInt32?
        let isSpoiler: Bool
    }

    struct TextRegion {
        let frame: CGRect
        let text: NativeTimelineAttributedTextBox
        let isSelectable: Bool
        let contentID: String?
    }

    struct ButtonRegion {
        let frame: CGRect
        let componentID: String
        let style: ComponentButtonStyle?
        let label: String
        let emoji: EmojiReference?
        let customID: String?
        let url: URL?
        let isDisabled: Bool
    }

    struct SelectRegion {
        let frame: CGRect
        let componentID: String
        let kind: ComponentSelectKind
        let customID: String
        let placeholder: String
        let options: [ComponentSelectOption]
        let isDisabled: Bool
    }

    struct ImageRegion {
        let frame: CGRect
        let componentID: String
        let displayURL: URL
        let openURL: URL
        let description: String
        let isSpoiler: Bool
        let cornerRadius: CGFloat
        let maximumPixelDimension: Int
    }

    struct MediaRegion {
        let frame: CGRect
        let componentID: String
        let displayURL: URL
        let openURL: URL
        let description: String
        let isSpoiler: Bool
        let isVideo: Bool
    }

    struct FileRegion {
        let frame: CGRect
        let componentID: String
        let openURL: URL
        let title: String
        let description: String?
        let isSpoiler: Bool
    }

    struct SeparatorRegion {
        let frame: CGRect
        let drawsDivider: Bool
    }

    struct UnsupportedRegion {
        let frame: CGRect
        let label: String
    }

    let frame: CGRect
    let containers: [ContainerRegion]
    let textRegions: [TextRegion]
    let buttons: [ButtonRegion]
    let selects: [SelectRegion]
    let images: [ImageRegion]
    let media: [MediaRegion]
    let files: [FileRegion]
    let separators: [SeparatorRegion]
    let unsupported: [UnsupportedRegion]

    static func make(
        message: Message,
        model: AppModel?,
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> Self? {
        guard !message.components.isEmpty else { return nil }
        var nodes = message.components.map {
            NodeBuilder.node(
                for: $0,
                message: message,
                model: model,
                maximumWidth: maximumWidth
            )
        }
        if let error = model?.componentError(for: message.id) {
            let errorBox = NodeBuilder.plainText(
                "⚠ \(error)",
                font: .systemFont(ofSize: 11),
                color: .systemRed
            )
            nodes.append(
                Node(
                    size: CGSize(
                        width: min(
                            maximumWidth,
                            NodeBuilder.idealWidth(errorBox)
                        ),
                        height: NodeBuilder.measuredHeight(
                            errorBox,
                            width: maximumWidth
                        )
                    ),
                    textRegions: [
                        .init(
                            frame: CGRect(
                                origin: .zero,
                                size: CGSize(
                                    width: maximumWidth,
                                    height: NodeBuilder.measuredHeight(
                                        errorBox,
                                        width: maximumWidth
                                    )
                                )
                            ),
                            text: errorBox,
                            isSelectable: false,
                            contentID: nil
                        )
                    ]
                )
            )
        }

        let root = NodeBuilder.vertical(nodes, spacing: 8)
            .offsetBy(dx: origin.x, dy: origin.y)
        return Self(
            frame: CGRect(origin: origin, size: root.size),
            containers: root.containers,
            textRegions: root.textRegions,
            buttons: root.buttons,
            selects: root.selects,
            images: root.images,
            media: root.media,
            files: root.files,
            separators: root.separators,
            unsupported: root.unsupported
        )
    }
}

private struct Node {
    var size = CGSize.zero
    var containers: [NativeTimelineComponentLayout.ContainerRegion] = []
    var textRegions: [NativeTimelineComponentLayout.TextRegion] = []
    var buttons: [NativeTimelineComponentLayout.ButtonRegion] = []
    var selects: [NativeTimelineComponentLayout.SelectRegion] = []
    var images: [NativeTimelineComponentLayout.ImageRegion] = []
    var media: [NativeTimelineComponentLayout.MediaRegion] = []
    var files: [NativeTimelineComponentLayout.FileRegion] = []
    var separators: [NativeTimelineComponentLayout.SeparatorRegion] = []
    var unsupported: [NativeTimelineComponentLayout.UnsupportedRegion] = []

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
        var result = self
        result.containers = containers.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                componentID: $0.componentID,
                accentColor: $0.accentColor,
                isSpoiler: $0.isSpoiler
            )
        }
        result.textRegions = textRegions.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                text: $0.text,
                isSelectable: $0.isSelectable,
                contentID: $0.contentID
            )
        }
        result.buttons = buttons.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                componentID: $0.componentID,
                style: $0.style,
                label: $0.label,
                emoji: $0.emoji,
                customID: $0.customID,
                url: $0.url,
                isDisabled: $0.isDisabled
            )
        }
        result.selects = selects.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                componentID: $0.componentID,
                kind: $0.kind,
                customID: $0.customID,
                placeholder: $0.placeholder,
                options: $0.options,
                isDisabled: $0.isDisabled
            )
        }
        result.images = images.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                componentID: $0.componentID,
                displayURL: $0.displayURL,
                openURL: $0.openURL,
                description: $0.description,
                isSpoiler: $0.isSpoiler,
                cornerRadius: $0.cornerRadius,
                maximumPixelDimension: $0.maximumPixelDimension
            )
        }
        result.media = media.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                componentID: $0.componentID,
                displayURL: $0.displayURL,
                openURL: $0.openURL,
                description: $0.description,
                isSpoiler: $0.isSpoiler,
                isVideo: $0.isVideo
            )
        }
        result.files = files.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                componentID: $0.componentID,
                openURL: $0.openURL,
                title: $0.title,
                description: $0.description,
                isSpoiler: $0.isSpoiler
            )
        }
        result.separators = separators.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                drawsDivider: $0.drawsDivider
            )
        }
        result.unsupported = unsupported.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                label: $0.label
            )
        }
        return result
    }

    mutating func merge(_ child: Node, at origin: CGPoint) {
        let child = child.offsetBy(dx: origin.x, dy: origin.y)
        containers.append(contentsOf: child.containers)
        textRegions.append(contentsOf: child.textRegions)
        buttons.append(contentsOf: child.buttons)
        selects.append(contentsOf: child.selects)
        images.append(contentsOf: child.images)
        media.append(contentsOf: child.media)
        files.append(contentsOf: child.files)
        separators.append(contentsOf: child.separators)
        unsupported.append(contentsOf: child.unsupported)
    }
}

private enum NodeBuilder {
    private struct ResolvedMedia {
        let displayURL: URL
        let openURL: URL
        let title: String
        let description: String?
        let width: Int?
        let height: Int?
        let isSpoiler: Bool
        let isVideo: Bool
    }

    static func node(
        for component: MessageComponent,
        message: Message,
        model: AppModel?,
        maximumWidth: CGFloat
    ) -> Node {
        let maximumWidth = max(1, maximumWidth)
        switch component {
        case let .actionRow(_, children):
            var result = Node()
            var x: CGFloat = 0
            var maximumHeight: CGFloat = 0
            for child in children {
                if x > 0 {
                    x += 8
                }
                let remaining = max(1, maximumWidth - x)
                let childNode = node(
                    for: child,
                    message: message,
                    model: model,
                    maximumWidth: remaining
                )
                result.merge(childNode, at: CGPoint(x: x, y: 0))
                x += childNode.size.width
                maximumHeight = max(maximumHeight, childNode.size.height)
            }
            result.size = CGSize(
                width: min(maximumWidth, x),
                height: maximumHeight
            )
            return result

        case let .button(
            id,
            style,
            rawLabel,
            emoji,
            customID,
            url,
            _,
            disabled
        ):
            let label = rawLabel ?? "Button"
            let labelWidth = ceil(
                (label as NSString).size(
                    withAttributes: [
                        .font: NativeTimelineComponentButtonMetrics.font
                    ]
                ).width
            )
            let showsLeadingGlyph = emoji != nil || style == .premium
            let showsExternalLink = url != nil
            let width = min(
                maximumWidth,
                ceil(
                    24 + labelWidth
                        + (showsLeadingGlyph ? 22 : 0)
                        + (showsExternalLink ? 18 : 0)
                )
            )
            let isDisabled =
                disabled
                || style == .premium
                || (url == nil && (
                    customID == nil
                        || model?.supportsCapability(.components) != true
                        || customID.map {
                            model?.isComponentPending(
                                messageID: message.id,
                                customID: $0
                            ) == true
                        } == true
                ))
            return Node(
                size: CGSize(
                    width: max(32, width),
                    height: NativeTimelineComponentButtonMetrics.height
                ),
                buttons: [
                    .init(
                        frame: CGRect(
                            x: 0,
                            y: 0,
                            width: max(32, width),
                            height:
                                NativeTimelineComponentButtonMetrics
                                    .height
                        ),
                        componentID: id,
                        style: style,
                        label: label,
                        emoji: emoji,
                        customID: customID,
                        url: url,
                        isDisabled: isDisabled
                    )
                ]
            )

        case let .select(
            id,
            kind,
            customID,
            rawPlaceholder,
            _,
            _,
            disabled,
            options,
            _
        ):
            let placeholder = rawPlaceholder ?? "Select an option…"
            let font = NSFont.systemFont(ofSize: 13)
            let labelWidth = ceil(
                (placeholder as NSString).size(
                    withAttributes: [.font: font]
                ).width
            )
            let width = min(
                maximumWidth,
                max(210, min(380, labelWidth + 76))
            )
            let isDisabled =
                disabled
                || options.isEmpty
                || model?.supportsCapability(.components) != true
                || model?.isComponentPending(
                    messageID: message.id,
                    customID: customID
                ) == true
            return Node(
                size: CGSize(width: width, height: 38),
                selects: [
                    .init(
                        frame: CGRect(
                            x: 0,
                            y: 0,
                            width: width,
                            height: 38
                        ),
                        componentID: id,
                        kind: kind,
                        customID: customID,
                        placeholder: placeholder,
                        options: options,
                        isDisabled: isDisabled
                    )
                ]
            )

        case let .section(_, children, accessory):
            guard let accessory else {
                return vertical(
                    children.map {
                        node(
                            for: $0,
                            message: message,
                            model: model,
                            maximumWidth: maximumWidth
                        )
                    },
                    spacing: 8
                )
            }
            let accessoryNode = node(
                for: accessory,
                message: message,
                model: model,
                maximumWidth: min(180, maximumWidth)
            )
            let leftWidth = max(
                1,
                maximumWidth - accessoryNode.size.width - 8
            )
            let left = vertical(
                children.map {
                    node(
                        for: $0,
                        message: message,
                        model: model,
                        maximumWidth: leftWidth
                    )
                },
                spacing: 8
            )
            var result = Node(
                size: CGSize(
                    width: min(
                        maximumWidth,
                        left.size.width + 8 + accessoryNode.size.width
                    ),
                    height: max(left.size.height, accessoryNode.size.height)
                )
            )
            result.merge(left, at: .zero)
            result.merge(
                accessoryNode,
                at: CGPoint(x: left.size.width + 8, y: 0)
            )
            return result

        case let .textDisplay(id, content):
            let box = richText(
                content,
                componentID: id,
                message: message,
                model: model,
                emojiSize: 18
            )
            let width = min(maximumWidth, max(1, idealWidth(box)))
            let height = measuredHeight(box, width: width)
            return Node(
                size: CGSize(width: width, height: height),
                textRegions: [
                    .init(
                        frame: CGRect(
                            x: 0,
                            y: 0,
                            width: width,
                            height: height
                        ),
                        text: box,
                        isSelectable: true,
                        contentID: id
                    )
                ]
            )

        case let .thumbnail(id, media):
            guard let item = resolve(
                media,
                componentID: id,
                attachments: message.attachments
            ) else {
                return unsupportedNode(
                    "Media unavailable",
                    maximumWidth: maximumWidth
                )
            }
            let size = min(80, maximumWidth)
            return Node(
                size: CGSize(width: size, height: size),
                images: [
                    .init(
                        frame: CGRect(
                            x: 0,
                            y: 0,
                            width: size,
                            height: size
                        ),
                        componentID: id,
                        displayURL: item.displayURL,
                        openURL: item.openURL,
                        description:
                            item.description ?? item.title,
                        isSpoiler: item.isSpoiler,
                        cornerRadius: 8,
                        maximumPixelDimension: 256
                    )
                ]
            )

        case let .mediaGallery(_, items):
            let resolved = items.compactMap { item -> (
                ComponentGalleryItem,
                ResolvedMedia
            )? in
                resolve(
                    item.media,
                    componentID: item.id,
                    attachments: message.attachments
                ).map { (item, $0) }
            }
            guard !resolved.isEmpty else {
                return unsupportedNode(
                    "Media unavailable",
                    maximumWidth: maximumWidth
                )
            }
            let galleryWidth = min(500, max(180, maximumWidth))
            let frames = MediaGalleryPlan.frames(
                count: resolved.count,
                width: galleryWidth,
                aspectRatios: resolved.map {
                    aspectRatio(width: $0.1.width, height: $0.1.height)
                },
                intrinsicSizes: resolved.map {
                    intrinsicSize(width: $0.1.width, height: $0.1.height)
                },
                spacing: 4
            )
            let height = frames.map(\.maxY).max() ?? 0
            return Node(
                size: CGSize(width: galleryWidth, height: height),
                media: zip(resolved, frames).map { pair, frame in
                    let (item, media) = pair
                    return .init(
                        frame: frame,
                        componentID: item.id,
                        displayURL: media.displayURL,
                        openURL: media.openURL,
                        description:
                            media.description ?? media.title,
                        isSpoiler: media.isSpoiler,
                        isVideo: media.isVideo
                    )
                }
            )

        case let .file(id, media):
            guard let item = resolve(
                media,
                componentID: id,
                attachments: message.attachments
            ) else {
                return unsupportedNode(
                    "Media unavailable",
                    maximumWidth: maximumWidth
                )
            }
            let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let naturalWidth = ceil(
                (item.title as NSString).size(
                    withAttributes: [.font: titleFont]
                ).width
            ) + 96
            let width = min(maximumWidth, max(220, naturalWidth))
            let height: CGFloat =
                item.description?.isEmpty == false ? 62 : 48
            return Node(
                size: CGSize(width: width, height: height),
                files: [
                    .init(
                        frame: CGRect(
                            x: 0,
                            y: 0,
                            width: width,
                            height: height
                        ),
                        componentID: id,
                        openURL: item.openURL,
                        title: item.title,
                        description: item.description,
                        isSpoiler: item.isSpoiler
                    )
                ]
            )

        case let .separator(_, divider, spacing):
            let height: CGFloat = divider
                ? (spacing == 2 ? 13 : 3)
                : (spacing == 2 ? 12 : 6)
            return Node(
                // SwiftUI Divider has no intrinsic horizontal width. It
                // stretches only after the container has chosen its fitting
                // width, so it must not force every component card to 520pt.
                size: CGSize(width: 0, height: height),
                separators: [
                    .init(
                        frame: CGRect(
                            x: 0,
                            y: 0,
                            width: maximumWidth,
                            height: height
                        ),
                        drawsDivider: divider
                    )
                ]
            )

        case let .container(id, accent, spoiler, children):
            let fixedWidth: CGFloat = 24 + (accent == nil ? 0 : 4)
            let maximumContentWidth = max(1, maximumWidth - fixedWidth)
            let firstPass = vertical(
                children.map {
                    node(
                        for: $0,
                        message: message,
                        model: model,
                        maximumWidth: maximumContentWidth
                    )
                },
                spacing: 7
            )
            let width = DiscordComponentContainerLayoutPlan.width(
                idealContent: firstPass.size.width,
                available: maximumWidth,
                maximum: DiscordRichMessageMetrics.maximumWidth,
                padding: DiscordRichMessageMetrics.cardPadding,
                hasAccent: accent != nil
            )
            let contentWidth = max(1, width - fixedWidth)
            let content = vertical(
                children.map {
                    node(
                        for: $0,
                        message: message,
                        model: model,
                        maximumWidth: contentWidth
                    )
                },
                spacing: 7
            )
            let height = content.size.height + 24
            var result = Node(
                size: CGSize(width: width, height: height),
                containers: [
                    .init(
                        frame: CGRect(
                            x: 0,
                            y: 0,
                            width: width,
                            height: height
                        ),
                        componentID: id,
                        accentColor: accent,
                        isSpoiler: spoiler
                    )
                ]
            )
            result.merge(
                content,
                at: CGPoint(
                    x: 12 + (accent == nil ? 0 : 4),
                    y: 12
                )
            )
            return result

        case let .unsupported(_, type, rawLabel):
            return unsupportedNode(
                rawLabel ?? "Unsupported component \(type)",
                maximumWidth: maximumWidth
            )
        }
    }

    static func vertical(_ children: [Node], spacing: CGFloat) -> Node {
        var result = Node()
        var y: CGFloat = 0
        var width: CGFloat = 0
        for child in children where child.size.height > 0 {
            if y > 0 {
                y += spacing
            }
            result.merge(child, at: CGPoint(x: 0, y: y))
            y += child.size.height
            width = max(width, child.size.width)
        }
        result.size = CGSize(width: width, height: y)
        return result
    }

    static func plainText(
        _ value: String,
        font: NSFont,
        color: NSColor
    ) -> NativeTimelineAttributedTextBox {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NativeTimelineAttributedTextBox(
            NSAttributedString(
                string: value,
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            )
        )
    }

    static func idealWidth(
        _ box: NativeTimelineAttributedTextBox
    ) -> CGFloat {
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            box.framesetter,
            CFRange(location: 0, length: box.value.length),
            nil,
            CGSize(width: 10_000, height: 10_000),
            nil
        )
        return max(1, ceil(size.width))
    }

    static func measuredHeight(
        _ box: NativeTimelineAttributedTextBox,
        width: CGFloat
    ) -> CGFloat {
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            box.framesetter,
            CFRange(location: 0, length: box.value.length),
            nil,
            CGSize(width: max(1, width), height: 10_000),
            nil
        )
        return max(
            1,
            ceil(size.height) - box.layoutHeightAdjustment
        )
    }

    private static func richText(
        _ source: String,
        componentID: String,
        message: Message,
        model: AppModel?,
        emojiSize: CGFloat
    ) -> NativeTimelineAttributedTextBox {
        let prepared = RichMessageAttributedText.prepare(source: source)
        let resolver = model.map {
            MessageMentionResolver(model: $0, message: message)
        }
        let mentions = prepared.tokens.reduce(
            into: [String: MentionPresentation]()
        ) { result, token in
            guard case let .mention(mention) = token else { return }
            result[mention.rawToken] =
                resolver?.presentation(mention)
                ?? MentionPresentation.fallback(for: mention)
        }
        let key = NativeTimelineResolvedTextCache.Key(
            messageID: message.id,
            scope: "component:\(componentID)",
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: 15,
            mentions: mentions.values.sorted {
                $0.rawToken < $1.rawToken
            }
        )
        return NativeTimelineResolvedTextCache.shared.box(for: key) {
            NativeTimelineAttributedTextBox(
                NativeTimelineCoreText.make(
                    prepared: prepared,
                    emojiSize: emojiSize,
                    mentionPresentations: mentions
                ),
                layoutHeightAdjustment: 1
            )
        }
    }

    private static func unsupportedNode(
        _ label: String,
        maximumWidth: CGFloat
    ) -> Node {
        let font = NSFont.systemFont(ofSize: 11)
        let width = min(
            maximumWidth,
            ceil(
                (label as NSString).size(
                    withAttributes: [.font: font]
                ).width
            ) + 22
        )
        return Node(
            size: CGSize(width: max(40, width), height: 18),
            unsupported: [
                .init(
                    frame: CGRect(
                        x: 0,
                        y: 0,
                        width: max(40, width),
                        height: 18
                    ),
                    label: label
                )
            ]
        )
    }

    private static func resolve(
        _ media: ComponentMedia,
        componentID: String,
        attachments: [Attachment]
    ) -> ResolvedMedia? {
        if let name = media.attachmentName,
           let attachment = attachments.first(where: {
               $0.filename == name || $0.id == name
           })
        {
            return ResolvedMedia(
                displayURL: attachment.proxyURL ?? attachment.url,
                openURL: attachment.url,
                title: attachment.filename,
                description: media.description ?? attachment.description,
                width: media.width ?? attachment.width,
                height: media.height ?? attachment.height,
                isSpoiler: media.isSpoiler || attachment.isSpoiler,
                isVideo: attachment.mediaKind == .video
            )
        }
        guard let openURL = media.url else { return nil }
        return ResolvedMedia(
            displayURL: media.proxyURL ?? openURL,
            openURL: openURL,
            title: media.description ?? "Component media",
            description: media.description,
            width: media.width,
            height: media.height,
            isSpoiler: media.isSpoiler,
            isVideo: media.contentType?.hasPrefix("video/") == true
        )
    }

    private static func aspectRatio(
        width: Int?,
        height: Int?
    ) -> CGFloat {
        guard let width, let height, width > 0, height > 0 else {
            return 16 / 9
        }
        return CGFloat(width) / CGFloat(height)
    }

    private static func intrinsicSize(
        width: Int?,
        height: Int?
    ) -> CGSize {
        guard let width, let height, width > 0, height > 0 else {
            return .zero
        }
        return CGSize(width: width, height: height)
    }
}
