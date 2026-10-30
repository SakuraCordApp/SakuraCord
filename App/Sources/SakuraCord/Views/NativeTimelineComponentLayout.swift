import AppKit
import CoreText
import SakuraCordModels

enum NativeTimelineComponentButtonMetrics {
    static var height: CGFloat { InterfaceScale.metric(32) }
    static var minimumWidth: CGFloat { InterfaceScale.metric(60) }
    static var cornerRadius: CGFloat { InterfaceScale.metric(8) }
    /// Shared by measurement, painting and the animated-emoji overlay.
    static var horizontalPadding: CGFloat { InterfaceScale.metric(12) }
    static var leadingGlyphAdvance: CGFloat { DiscordComponentEmojiMetrics.buttonSize + InterfaceScale.metric(4) }
    /// The launch icon and its 8-point gap after a link button's label.
    static var linkIconSize: CGFloat { InterfaceScale.metric(16) }
    static var linkIconAdvance: CGFloat { InterfaceScale.metric(8) + linkIconSize }

    /// Discord's 14-pixel medium label, on the scale that draws its 16-pixel
    /// message text at `messageTextSize`.
    static var font: NSFont { .interfaceSystemFont(ofSize: 13, weight: .medium) }
}

enum NativeTimelineComponentSelectPolicy {
    nonisolated static func isEnabled(
        kind: ComponentSelectKind,
        hasStaticOptions: Bool,
        supportsComponents: Bool,
        supportsRemoteChoices: Bool,
        interactionUnavailable: Bool
    ) -> Bool {
        guard supportsComponents, !interactionUnavailable else {
            return false
        }
        switch kind {
        case .string:
            return hasStaticOptions
        case .user, .role, .mentionable, .channel:
            return supportsRemoteChoices
        }
    }
}

struct NativeTimelineComponentLayout {
    struct ContainerRegion {
        enum Chrome: Equatable {
            case bubbleSection
            case card
        }

        let frame: CGRect
        let chromeFrame: CGRect
        let componentID: String
        let accentColor: UInt32?
        let isSpoiler: Bool
        let chrome: Chrome
        let cornerRadius: CGFloat
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
        var isLoading = false
        /// The emoji, label and link icon, centred when the button is wider.
        let contentWidth: CGFloat

        /// Discord dims a disabled button to half opacity, but not the one
        /// showing this message's pending action.
        var opacity: CGFloat { isDisabled && !isLoading ? 0.5 : 1 }

        var contentMinX: CGFloat {
            frame.minX + max(NativeTimelineComponentButtonMetrics.horizontalPadding, (frame.width - contentWidth) / 2)
        }
    }

    struct SelectRegion {
        let frame: CGRect
        let componentID: String
        let kind: ComponentSelectKind
        let customID: String
        let placeholder: String
        let minimumSelectionCount: Int
        let maximumSelectionCount: Int
        let options: [ComponentSelectOption]
        let channelTypes: [Int]
        let selectedOptions: [ComponentSelectOption]
        let isDisabled: Bool
        var isLoading = false
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
        let placeholder: NativeTimelineMediaPlaceholder?
    }

    struct MediaRegion {
        let frame: CGRect
        let componentID: String
        let displayURL: URL
        /// The still image drawn in the tile: the media itself for images, or
        /// the media proxy's poster frame for videos.
        let previewURL: URL?
        let openURL: URL
        let description: String
        let isSpoiler: Bool
        let isVideo: Bool
        let placeholder: NativeTimelineMediaPlaceholder?
    }

    struct FileRegion {
        var frame: CGRect
        let componentID: String
        let openURL: URL
        let title: String
        let description: String?
        let isSpoiler: Bool
        /// The file the card names and downloads.
        let attachment: Attachment
        let isInBubble: Bool

        var card: NativeTimelineFileCard { .init(frame: frame, attachment: attachment, isInBubble: isInBubble) }
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
    let drawsTopSeparator: Bool

    static func make(
        message: Message,
        components embedComponents: [MessageComponent]? = nil,
        source: AppModel?,
        origin: CGPoint,
        maximumWidth: CGFloat,
        integratesWithBubble: Bool = false,
        drawsTopSeparator: Bool = false
    ) -> Self? {
        let components = embedComponents ?? message.components
        guard !components.isEmpty else { return nil }
        var nodes = components.map { component in
            if integratesWithBubble {
                NodeBuilder.bubbleRootNode(
                    for: component,
                    message: message,
                    source: source,
                    maximumWidth: maximumWidth
                )
            } else {
                NodeBuilder.node(
                    for: component,
                    message: message,
                    source: source,
                    maximumWidth: maximumWidth
                )
            }
        }
        if embedComponents == nil, let error = source?.componentError(for: message.id) {
            let errorBox = NodeBuilder.plainText(
                "⚠ \(error)",
                font: .interfaceSystemFont(ofSize: 13),
                color: .systemRed
            )
            let height = NodeBuilder.measuredHeight(errorBox, width: maximumWidth)
            nodes.append(
                Node(
                    size: CGSize(width: min(maximumWidth, NodeBuilder.idealWidth(errorBox)), height: height),
                    textRegions: [
                        .init(
                            frame: CGRect(x: 0, y: 0, width: maximumWidth, height: height),
                            text: errorBox,
                            isSelectable: false,
                            contentID: nil
                        )
                    ]
                )
            )
        }

        // Like Discord's stack, top-level containers, sections and dividers
        // share the width of the widest component. A bubble draws its
        // containers as full-width sections of itself instead.
        let rootWidth = nodes.map(\.size.width).max() ?? 0
        for (index, component) in components.enumerated() {
            switch component {
            case .container where !integratesWithBubble && nodes[index].size.width < rootWidth:
                nodes[index] = NodeBuilder.containerNode(
                    for: component,
                    message: message,
                    source: source,
                    maximumWidth: maximumWidth,
                    inBubble: false,
                    width: rootWidth
                )
            case .section where rootWidth < maximumWidth, .separator where rootWidth < maximumWidth:
                nodes[index] = NodeBuilder.node(
                    for: component,
                    message: message,
                    source: source,
                    maximumWidth: rootWidth,
                    inBubble: integratesWithBubble
                )
            default:
                break
            }
        }
        let root = NodeBuilder.vertical(nodes, spacing: NodeBuilder.componentSpacing)
            .offsetBy(dx: origin.x, dy: origin.y)
        let expandsSingleBubbleContainer =
            integratesWithBubble
                && !drawsTopSeparator
                && components.count == 1
        let containers = root.containers.map { container in
            guard expandsSingleBubbleContainer,
                  container.chrome == .bubbleSection
            else { return container }
            return .init(
                frame: container.frame.insetBy(dx: -InterfaceScale.metric(12), dy: -InterfaceScale.metric(8)),
                chromeFrame: container.chromeFrame,
                componentID: container.componentID,
                accentColor: container.accentColor,
                isSpoiler: container.isSpoiler,
                chrome: container.chrome,
                cornerRadius: NativeTimelineBubbleDrawing.cornerRadius
            )
        }
        return Self(
            frame: CGRect(origin: origin, size: root.size),
            containers: containers,
            textRegions: root.textRegions,
            buttons: root.buttons,
            selects: root.selects,
            images: root.images,
            media: root.media,
            files: root.files,
            separators: root.separators,
            unsupported: root.unsupported,
            drawsTopSeparator:
                integratesWithBubble && drawsTopSeparator
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
                chromeFrame: $0.chromeFrame.offsetBy(dx: dx, dy: dy),
                componentID: $0.componentID,
                accentColor: $0.accentColor,
                isSpoiler: $0.isSpoiler,
                chrome: $0.chrome,
                cornerRadius: $0.cornerRadius
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
                isDisabled: $0.isDisabled,
                isLoading: $0.isLoading,
                contentWidth: $0.contentWidth
            )
        }
        result.selects = selects.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                componentID: $0.componentID,
                kind: $0.kind,
                customID: $0.customID,
                placeholder: $0.placeholder,
                minimumSelectionCount: $0.minimumSelectionCount,
                maximumSelectionCount: $0.maximumSelectionCount,
                options: $0.options,
                channelTypes: $0.channelTypes,
                selectedOptions: $0.selectedOptions,
                isDisabled: $0.isDisabled,
                isLoading: $0.isLoading
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
                maximumPixelDimension: $0.maximumPixelDimension,
                placeholder: $0.placeholder
            )
        }
        result.media = media.map {
            .init(
                frame: $0.frame.offsetBy(dx: dx, dy: dy),
                componentID: $0.componentID,
                displayURL: $0.displayURL,
                previewURL: $0.previewURL,
                openURL: $0.openURL,
                description: $0.description,
                isSpoiler: $0.isSpoiler,
                isVideo: $0.isVideo,
                placeholder: $0.placeholder
            )
        }
        result.files = files.map {
            var file = $0
            file.frame = file.frame.offsetBy(dx: dx, dy: dy)
            return file
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
        let previewURL: URL?
        let openURL: URL
        let title: String
        let description: String?
        let width: Int?
        let height: Int?
        let isSpoiler: Bool
        let isVideo: Bool
        let placeholder: NativeTimelineMediaPlaceholder?
    }

    static func node(
        for component: MessageComponent,
        message: Message,
        source: AppModel?,
        maximumWidth: CGFloat,
        inBubble: Bool = false,
        inContainer: Bool = false
    ) -> Node {
        let maximumWidth = max(1, maximumWidth)
        switch component {
        case .actionRow:
            return actionRowNode(
                for: component,
                message: message,
                source: source,
                maximumWidth: maximumWidth,
                inBubble: inBubble
            )

        case .button:
            return buttonNode(
                for: component,
                message: message,
                source: source,
                maximumWidth: maximumWidth
            )

        case .select:
            return selectNode(
                for: component,
                message: message,
                source: source,
                maximumWidth: maximumWidth,
                inBubble: inBubble
            )

        case .section:
            return sectionNode(
                for: component,
                message: message,
                source: source,
                maximumWidth: maximumWidth,
                inBubble: inBubble,
                inContainer: inContainer
            )

        case let .textDisplay(id, content):
            return textNode(
                id: id,
                content: content,
                message: message,
                source: source,
                maximumWidth: maximumWidth,
                inContainer: inContainer
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
            let size = min(InterfaceScale.metric(85), maximumWidth)
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
                        cornerRadius: InterfaceScale.metric(8),
                        maximumPixelDimension: 256,
                        placeholder: item.placeholder
                    )
                ]
            )

        case .mediaGallery, .file:
            return mediaNode(
                for: component,
                message: message,
                maximumWidth: maximumWidth,
                inBubble: inBubble
            )

        case .separator, .container:
            return containerNode(
                for: component,
                message: message,
                source: source,
                maximumWidth: maximumWidth,
                inBubble: inBubble
            )

        case let .unsupported(_, type, rawLabel):
            return unsupportedNode(
                rawLabel ?? "Unsupported component \(type)",
                maximumWidth: maximumWidth
            )
        }
    }

    static func bubbleRootNode(
        for component: MessageComponent,
        message: Message,
        source: AppModel?,
        maximumWidth: CGFloat
    ) -> Node {
        guard case let .container(id, accent, spoiler, children) = component
        else {
            return node(
                for: component,
                message: message,
                source: source,
                maximumWidth: maximumWidth,
                inBubble: true
            )
        }
        let content = vertical(
            children.map {
                node(
                    for: $0,
                    message: message,
                    source: source,
                    maximumWidth: maximumWidth,
                    inBubble: true,
                    inContainer: true
                )
            },
            spacing: componentSpacing
        )
        let size = CGSize(
            width: maximumWidth,
            height: max(1, content.size.height)
        )
        var result = Node(
            size: size,
            containers: [
                .init(
                    frame: CGRect(origin: .zero, size: size),
                    chromeFrame: CGRect(origin: .zero, size: size),
                    componentID: id,
                    accentColor: accent,
                    isSpoiler: spoiler,
                    chrome: .bubbleSection,
                    cornerRadius:
                        DiscordRichMessageMetrics.cardCornerRadius
                )
            ]
        )
        result.merge(content, at: .zero)
        return result
    }

    private static func textNode(
        id: String,
        content: String,
        message: Message,
        source: AppModel?,
        maximumWidth: CGFloat,
        inContainer: Bool
    ) -> Node {
        // Discord sets a container's text at 14 pixels against the
        // message's 16.
        let scale: CGFloat = inContainer ? 14 / 16 : 1
        let box = richText(
            content,
            componentID: id,
            message: message,
            source: source,
            emojiSize: 18 * scale,
            fontScale: scale
        )
        let width = min(maximumWidth, max(1, idealWidth(box)))
        let inset = NativeTimelineMarkdownChromeMetrics.leadingVisualInset(in: box.value)
        let height = measuredHeight(box, width: width)
        return Node(
            size: CGSize(width: width, height: inset + height),
            textRegions: [
                .init(
                    frame: CGRect(
                        x: 0,
                        y: inset,
                        width: width,
                        height: height
                    ),
                    text: box,
                    isSelectable: true,
                    contentID: id
                )
            ]
        )
    }

    private static func actionRowNode(
        for component: MessageComponent,
        message: Message,
        source: AppModel?,
        maximumWidth: CGFloat,
        inBubble: Bool
    ) -> Node {
        switch component {
        case let .actionRow(_, children):
            var result = Node()
            var horizontalOffset: CGFloat = 0
            var verticalOffset: CGFloat = 0
            var rowHeight: CGFloat = 0
            var contentWidth: CGFloat = 0
            for child in children {
                // Measure against the whole row so a button moves intact to
                // the next line instead of shrinking into the leftover space.
                let childNode = node(
                    for: child,
                    message: message,
                    source: source,
                    maximumWidth: maximumWidth,
                    inBubble: inBubble
                )
                if horizontalOffset > 0 {
                    if horizontalOffset + componentSpacing + childNode.size.width > maximumWidth {
                        verticalOffset += rowHeight + componentSpacing
                        horizontalOffset = 0
                        rowHeight = 0
                    } else {
                        horizontalOffset += componentSpacing
                    }
                }
                result.merge(childNode, at: CGPoint(x: horizontalOffset, y: verticalOffset))
                horizontalOffset += childNode.size.width
                contentWidth = max(contentWidth, horizontalOffset)
                rowHeight = max(rowHeight, childNode.size.height)
            }
            result.size = CGSize(
                width: min(maximumWidth, contentWidth),
                height: verticalOffset + rowHeight
            )
            return result

        default:
            preconditionFailure("Unexpected action-row component")
        }
    }

    private static func selectNode(
        for component: MessageComponent,
        message: Message,
        source: AppModel?,
        maximumWidth: CGFloat,
        inBubble: Bool
    ) -> Node {
        switch component {
        case let .select(
            id,
            kind,
            customID,
            rawPlaceholder,
            minimumSelectionCount,
            maximumSelectionCount,
            disabled,
            options,
            channelTypes
        ):
            let placeholder = rawPlaceholder ?? "Make a selection"
            // Discord's select is 400 points wide whatever its placeholder.
            let width = inBubble ? maximumWidth : min(maximumWidth, InterfaceScale.metric(400))
            let selectedOptions = source?.componentSelection(
                messageID: message.id,
                customID: customID
            ) ?? (kind == .string
                ? options.filter(\.isDefault)
                : source?.resolvedDefaultComponentChoices(options, kind: kind, guildID: message.guildID) ?? options)
            let height = ComponentChoiceOptionPresentation.fieldHeight(
                options: selectedOptions,
                selectKind: kind,
                fieldWidth: width
            )
            let isDisabled = !NativeTimelineComponentSelectPolicy.isEnabled(
                kind: kind,
                hasStaticOptions: !options.isEmpty,
                supportsComponents:
                    source?.supportsComponents == true,
                supportsRemoteChoices:
                    source?.supportsRemoteComponentChoices == true,
                interactionUnavailable:
                    disabled
                    || source?.isComponentInteractionPending(messageID: message.id) == true
            )
            return Node(
                size: CGSize(width: width, height: height),
                selects: [
                    .init(
                        frame: CGRect(
                            x: 0,
                            y: 0,
                            width: width,
                            height: height
                        ),
                        componentID: id,
                        kind: kind,
                        customID: customID,
                        placeholder: placeholder,
                        minimumSelectionCount: minimumSelectionCount,
                        maximumSelectionCount: maximumSelectionCount,
                        options: options,
                        channelTypes: channelTypes,
                        selectedOptions: selectedOptions,
                        isDisabled: isDisabled,
                        // The committed select shows the dots in place of its chevron.
                        isLoading: source?.isComponentPending(messageID: message.id, customID: customID) == true
                    )
                ]
            )

        default:
            preconditionFailure("Unexpected select component")
        }
    }

    private static func sectionNode(
        for component: MessageComponent,
        message: Message,
        source: AppModel?,
        maximumWidth: CGFloat,
        inBubble: Bool,
        inContainer: Bool
    ) -> Node {
        switch component {
        case let .section(_, children, accessory):
            func text(width: CGFloat) -> Node {
                vertical(
                    children.map {
                        node(
                            for: $0,
                            message: message,
                            source: source,
                            maximumWidth: width,
                            inBubble: inBubble,
                            inContainer: inContainer
                        )
                    },
                    spacing: InterfaceScale.metric(4)
                )
            }
            guard let accessory else { return text(width: maximumWidth) }
            let accessoryNode = node(
                for: accessory,
                message: message,
                source: source,
                maximumWidth: min(InterfaceScale.metric(180), maximumWidth),
                inBubble: inBubble
            )
            let accessoryGap = InterfaceScale.metric(12)
            let left = text(width: max(1, maximumWidth - accessoryNode.size.width - accessoryGap))
            let height = max(left.size.height, accessoryNode.size.height)
            // The accessory sits at the trailing edge of the space offered,
            // while the section reports only the width it needs, so a stack
            // that fits its content and then offers that width lines up.
            var result = Node(size: CGSize(
                width: min(maximumWidth, left.size.width + accessoryGap + accessoryNode.size.width),
                height: height
            ))
            // Discord centres the text beside a button, and tops it beside a
            // thumbnail.
            let isButton = if case .button = accessory { true } else { false }
            result.merge(left, at: CGPoint(x: 0, y: isButton ? ((height - left.size.height) / 2).rounded() : 0))
            result.merge(
                accessoryNode,
                at: CGPoint(
                    x: maximumWidth - accessoryNode.size.width,
                    y: 0
                )
            )
            return result

        default:
            preconditionFailure("Unexpected section component")
        }
    }

    private static func buttonNode(
        for component: MessageComponent,
        message: Message,
        source: AppModel?,
        maximumWidth: CGFloat
    ) -> Node {
        switch component {
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
            // Discord shows an emoji-only button as just its emoji.
            let label = rawLabel ?? (emoji == nil ? "Button" : "")
            let labelWidth = ceil(
                (label as NSString).size(
                    withAttributes: [
                        .font: NativeTimelineComponentButtonMetrics.font
                    ]
                ).width
            )
            let showsLeadingGlyph = emoji != nil || style == .premium
            let leadingGlyphWidth = label.isEmpty
                ? DiscordComponentEmojiMetrics.buttonSize
                : NativeTimelineComponentButtonMetrics.leadingGlyphAdvance
            let contentWidth = labelWidth
                + (showsLeadingGlyph ? leadingGlyphWidth : 0)
                + (url == nil ? 0 : NativeTimelineComponentButtonMetrics.linkIconAdvance)
            let width = min(
                maximumWidth,
                max(
                    NativeTimelineComponentButtonMetrics.minimumWidth,
                    ceil(contentWidth + NativeTimelineComponentButtonMetrics.horizontalPadding * 2)
                )
            )
            // While one action on this message is pending, its siblings are
            // disabled and the activated button shows progress.
            let isLoading = url == nil && customID.map {
                source?.isComponentPending(messageID: message.id, customID: $0) == true
            } == true
            let isDisabled =
                disabled
                || style == .premium
                || (url == nil && (
                    customID == nil
                        || source?.supportsComponents != true
                        || source?.isComponentInteractionPending(messageID: message.id) == true
                ))
            return Node(
                size: CGSize(
                    width: width,
                    height: NativeTimelineComponentButtonMetrics.height
                ),
                buttons: [
                    .init(
                        frame: CGRect(
                            x: 0,
                            y: 0,
                            width: width,
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
                        isDisabled: isDisabled,
                        isLoading: isLoading,
                        contentWidth: contentWidth
                    )
                ]
            )

        default:
            preconditionFailure("Unexpected button component")
        }
    }

    private static func mediaNode(
        for component: MessageComponent,
        message: Message,
        maximumWidth: CGFloat,
        inBubble: Bool
    ) -> Node {
        switch component {
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
            let galleryWidth = min(DiscordRichMessageMetrics.componentsMaximumWidth, maximumWidth)
            let frames = MediaGalleryPlan.frames(
                count: resolved.count,
                width: galleryWidth,
                aspectRatios: resolved.map {
                    aspectRatio(width: $0.1.width, height: $0.1.height)
                },
                intrinsicSizes: resolved.map {
                    intrinsicSize(width: $0.1.width, height: $0.1.height)
                },
                spacing: InterfaceScale.metric(4)
            )
            return Node(
                size: CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0),
                media: zip(resolved, frames).map { pair, frame in
                    let (item, media) = pair
                    return .init(
                        frame: frame,
                        componentID: item.id,
                        displayURL: media.displayURL,
                        previewURL: media.previewURL,
                        openURL: media.openURL,
                        description:
                            media.description ?? media.title,
                        isSpoiler: media.isSpoiler,
                        isVideo: media.isVideo,
                        placeholder: media.placeholder
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
            let attachment = attachment(for: media, in: message.attachments) ?? Attachment(
                id: NativeTimelineFileCard.unresolvedFileID(componentID: id, in: message),
                // A delivered component's attachment name is its ID; the CDN
                // path ends in the filename.
                filename: item.openURL.lastPathComponent,
                url: item.openURL,
                mediaType: media.contentType
            )
            let size = CGSize(
                width: NativeTimelineFileCard.fittedWidth(
                    for: attachment, isInBubble: inBubble, maximumWidth: maximumWidth
                ),
                height: NativeTimelineFileCard.height(isInBubble: inBubble)
            )
            return Node(
                size: size,
                files: [
                    .init(
                        frame: CGRect(origin: .zero, size: size),
                        componentID: id,
                        openURL: item.openURL,
                        title: item.title,
                        description: item.description,
                        isSpoiler: item.isSpoiler,
                        attachment: attachment,
                        isInBubble: inBubble
                    )
                ]
            )

        default:
            preconditionFailure("Unexpected media component")
        }
    }

    static func containerNode(
        for component: MessageComponent,
        message: Message,
        source: AppModel?,
        maximumWidth: CGFloat,
        inBubble: Bool,
        width fixedWidth: CGFloat? = nil
    ) -> Node {
        switch component {
        case let .separator(_, divider, spacing):
            // Discord's separator adds 8 or 24 points between the stack's
            // 8-point gaps, with the 1-point divider centred in it.
            let height = InterfaceScale.metric(
                (spacing == 2 ? 16 : 0) + (divider ? 1 : 0)
            )
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
            let padding = DiscordRichMessageMetrics.cardPadding
            func content(width: CGFloat) -> Node {
                vertical(
                    children.map {
                        node(
                            for: $0,
                            message: message,
                            source: source,
                            maximumWidth: width,
                            inBubble: inBubble,
                            inContainer: true
                        )
                    },
                    spacing: componentSpacing
                )
            }
            let width = fixedWidth ?? DiscordComponentContainerLayoutPlan.width(
                idealContent: content(width: max(1, maximumWidth - padding * 2)).size.width,
                available: maximumWidth,
                maximum: DiscordRichMessageMetrics.componentsMaximumWidth,
                padding: padding
            )
            let content = content(width: max(1, width - padding * 2))
            let frame = CGRect(x: 0, y: 0, width: width, height: content.size.height + padding * 2)
            var result = Node(
                size: frame.size,
                containers: [
                    .init(
                        frame: frame,
                        chromeFrame: frame,
                        componentID: id,
                        accentColor: accent,
                        isSpoiler: spoiler,
                        chrome: .card,
                        cornerRadius:
                            DiscordRichMessageMetrics.cardCornerRadius
                    )
                ]
            )
            result.merge(content, at: CGPoint(x: padding, y: padding))
            return result

        default:
            preconditionFailure("Unexpected container component")
        }
    }

    /// The gap Discord leaves between a stack's components and a row's
    /// controls.
    static var componentSpacing: CGFloat { InterfaceScale.metric(8) }

    static func vertical(_ children: [Node], spacing: CGFloat) -> Node {
        var result = Node()
        var verticalOffset: CGFloat = 0
        var width: CGFloat = 0
        var isFirst = true
        // A spacing-only separator has no height but still adds its gaps.
        for child in children where child.size.height > 0 || !child.separators.isEmpty {
            if !isFirst {
                verticalOffset += spacing
            }
            isFirst = false
            result.merge(child, at: CGPoint(x: 0, y: verticalOffset))
            verticalOffset += child.size.height
            width = max(width, child.size.width)
        }
        result.size = CGSize(width: width, height: verticalOffset)
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
        _ content: String,
        componentID: String,
        message: Message,
        source: AppModel?,
        emojiSize: CGFloat,
        fontScale: CGFloat
    ) -> NativeTimelineAttributedTextBox {
        let prepared = RichMessageAttributedText.prepare(source: content)
        let resolver = source.map {
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
        let baseFontSize = InterfaceScale.fontSize(InterfaceTypographyMetrics.messageTextSize * fontScale)
        let emojiSize = InterfaceScale.metric(emojiSize)
        let key = NativeTimelineResolvedTextCache.Key(
            messageID: message.id,
            scope: "component:\(componentID)",
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: baseFontSize,

            mentions: mentions.values.sorted {
                $0.rawToken < $1.rawToken
            }
        )
        return NativeTimelineResolvedTextCache.shared.box(for: key) {
            NativeTimelineAttributedTextBox(
                NativeTimelineCoreText.make(
                    prepared: prepared,
                    emojiSize: emojiSize,
                    baseFontSize: baseFontSize,

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
        let font = NSFont.interfaceSystemFont(ofSize: 11)
        let width = min(
            maximumWidth,
            ceil(
                (label as NSString).size(
                    withAttributes: [.font: font]
                ).width
            ) + 22
        )
        return Node(
            size: CGSize(width: max(InterfaceScale.metric(40), width), height: InterfaceScale.metric(18)),
            unsupported: [
                .init(
                    frame: CGRect(
                        x: 0,
                        y: 0,
                        width: max(InterfaceScale.metric(40), width),
                        height: InterfaceScale.metric(18)
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
        if let attachment = attachment(for: media, in: attachments) {
            return ResolvedMedia(
                displayURL: attachment.proxyURL ?? attachment.url,
                previewURL: attachment.mediaKind == .video
                    ? attachment.videoPosterURL(maximumPixelDimension: 1_024)
                    : attachment.proxyURL ?? attachment.url,
                openURL: attachment.url,
                title: attachment.filename,
                description: media.description ?? attachment.description,
                width: media.width ?? attachment.width,
                height: media.height ?? attachment.height,
                isSpoiler: media.isSpoiler || attachment.isSpoiler,
                isVideo: attachment.mediaKind == .video,
                placeholder: .init(attachment)
            )
        }
        guard let openURL = media.url else { return nil }
        let isVideo = media.contentType?.hasPrefix("video/") == true
        return ResolvedMedia(
            displayURL: media.proxyURL ?? openURL,
            previewURL: isVideo
                ? DiscordVideoPosterURL.url(
                    proxyURL: media.proxyURL,
                    width: media.width,
                    height: media.height,
                    maximumPixelDimension: 1_024
                )
                : media.proxyURL ?? openURL,
            openURL: openURL,
            title: media.description ?? "Component media",
            description: media.description,
            width: media.width,
            height: media.height,
            isSpoiler: media.isSpoiler,
            isVideo: isVideo,
            placeholder: .init(media)
        )
    }

    private static func attachment(for media: ComponentMedia, in attachments: [Attachment]) -> Attachment? {
        media.attachmentName.flatMap { name in
            attachments.first { $0.filename == name || $0.id == name }
        }
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
