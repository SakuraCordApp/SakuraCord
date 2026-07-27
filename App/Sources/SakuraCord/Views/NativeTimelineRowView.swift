import AppKit
import CoreText
import MessageRendering
import SakuraCordModels

nonisolated enum NativeTimelineMarkdownChromeMetrics {
    static let codeBlockInset: CGFloat = 8
    static let codeBlockParagraphBottomSpacing: CGFloat = 4
    // The painter gives CoreText one point of extra layout headroom and its
    // selection-derived block rect has fractional vertical bounds. Preserve
    // the established three-point message-highlight inset after that painted
    // geometry instead of merely making the block fit the row.
    static let codeBlockTerminalPaintAndHighlightInset: CGFloat = 5.5

    static func trailingVisualOverflow(
        in value: NSAttributedString
    ) -> CGFloat {
        guard value.length > 0 else { return 0 }
        let source = value.string as NSString
        var index = value.length - 1
        while index >= 0 {
            let scalar = source.character(at: index)
            if let unicodeScalar = UnicodeScalar(scalar),
               CharacterSet.whitespacesAndNewlines
                .contains(unicodeScalar)
            {
                index -= 1
                continue
            }
            break
        }
        guard index >= 0,
              value.attribute(
                  .discordMarkdownBlock,
                  at: index,
                  effectiveRange: nil
              ) as? String == "code"
        else { return 0 }
        return max(
            0,
            codeBlockInset
                - codeBlockParagraphBottomSpacing
                + codeBlockTerminalPaintAndHighlightInset
        )
    }
}

enum NativeTimelineTimestamp {
    static func text(for date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}

extension NSAttributedString.Key {
    nonisolated static let nativeTimelineMention = NSAttributedString.Key(
        "dev.sakuracord.native-timeline-mention"
    )
}

final class NativeTimelineMentionBox: NSObject {
    let presentation: MentionPresentation

    init(_ presentation: MentionPresentation) {
        self.presentation = presentation
    }
}

nonisolated private final class NativeTimelineRunMetrics: @unchecked Sendable {
    let ascent: CGFloat
    let descent: CGFloat
    let width: CGFloat

    init(ascent: CGFloat, descent: CGFloat, width: CGFloat) {
        self.ascent = ascent
        self.descent = descent
        self.width = width
    }
}

nonisolated private enum NativeTimelineRunDelegate {
    static func make(
        width: CGFloat,
        height: CGFloat,
        baselineOffset: CGFloat
    ) -> CTRunDelegate {
        let descent = max(0, -baselineOffset)
        let metrics = NativeTimelineRunMetrics(
            ascent: max(0, height - descent),
            descent: descent,
            width: width
        )
        let retained = Unmanaged.passRetained(metrics)
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                Unmanaged<NativeTimelineRunMetrics>
                    .fromOpaque(pointer)
                    .release()
            },
            getAscent: { pointer in
                return Unmanaged<NativeTimelineRunMetrics>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                    .ascent
            },
            getDescent: { pointer in
                return Unmanaged<NativeTimelineRunMetrics>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                    .descent
            },
            getWidth: { pointer in
                return Unmanaged<NativeTimelineRunMetrics>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                    .width
            }
        )
        guard let delegate = CTRunDelegateCreate(
            &callbacks,
            retained.toOpaque()
        ) else {
            retained.release()
            preconditionFailure("Unable to create CoreText inline run delegate")
        }
        return delegate
    }
}

struct NativeTimelineRowActions {
    var loadEarlier: () -> Void
    var openReply: (MessageID) -> Void
    var reply: ((Message) -> Void)?
    var retry: (Message) -> Void
    var edit: (Message, String) -> Void
    var markUnread: (Message) -> Void
    var delete: (Message) -> Void
    var react: (String, Message) -> Void
    var openThread: (MessageThreadSummary) -> Void
    var submitComponent: (
        Message,
        String,
        ComponentInteractionKind,
        [String]
    ) -> Void
}

struct NativeTimelineBeginningLayout {
    let iconFrame: CGRect
    let titleFrame: CGRect
    let descriptionFrame: CGRect
    let dateSeparatorFrame: CGRect?
    let height: CGFloat

    static func make(
        beginning: NativeTimelineBeginning,
        width: CGFloat
    ) -> Self {
        let horizontalInset: CGFloat = 16
        let contentWidth = max(
            1,
            width - horizontalInset * 2
        )
        let iconFrame = CGRect(x: horizontalInset, y: 28, width: 68, height: 68)
        let titleFont = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize,
            weight: .bold
        )
        let descriptionFont = NSFont.preferredFont(forTextStyle: .body)
        let titleHeight = legacyLargeTitleHeight(
            beginning.title,
            font: titleFont,
            width: contentWidth
        )
        let titleFrame = CGRect(
            x: horizontalInset,
            y: iconFrame.maxY + 9,
            width: contentWidth,
            height: titleHeight
        )
        let descriptionHeight = textHeight(
            beginning.description,
            font: descriptionFont,
            width: contentWidth
        )
        let descriptionFrame = CGRect(
            x: horizontalInset,
            y: titleFrame.maxY + 9,
            width: contentWidth,
            height: descriptionHeight
        )
        let contentHeight = descriptionFrame.maxY + 18
        let dateSeparatorFrame = beginning.startedAt.map { _ in
            CGRect(x: 0, y: contentHeight, width: width, height: 37)
        }
        return Self(
            iconFrame: iconFrame,
            titleFrame: titleFrame,
            descriptionFrame: descriptionFrame,
            dateSeparatorFrame: dateSeparatorFrame,
            height: dateSeparatorFrame?.maxY ?? contentHeight
        )
    }

    private static func textHeight(
        _ value: String,
        font: NSFont,
        width: CGFloat
    ) -> CGFloat {
        let bounds = (value as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(
            ceil(font.ascender - font.descender + font.leading),
            ceil(bounds.height)
        )
    }

    private static func legacyLargeTitleHeight(
        _ value: String,
        font: NSFont,
        width: CGFloat
    ) -> CGFloat {
        let bounds = (value as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let intrinsicLineHeight = ceil(
            font.ascender - font.descender + font.leading
        )
        let measuredLineHeight = max(
            1,
            font.ascender - font.descender + font.leading
        )
        let lineCount = max(
            1,
            Int(ceil(bounds.height / measuredLineHeight))
        )

        // SwiftUI's large-title Text uses the intrinsic height for its first
        // line and one additional point of leading for each following line.
        // Core Text's bounding rect omits that inter-line leading.
        return intrinsicLineHeight
            + CGFloat(lineCount - 1) * (intrinsicLineHeight + 1)
    }
}

struct NativeTimelineLoaderLayout {
    let height: CGFloat
    let controlFrame: CGRect
    let labelFrame: CGRect
    let spinnerFrame: CGRect?

    static func make(
        isLoading: Bool,
        kind: NativeTimelineLoaderKind,
        width: CGFloat
    ) -> Self {
        guard isLoading else {
            return Self(
                height: 0,
                controlFrame: .zero,
                labelFrame: .zero,
                spinnerFrame: nil
            )
        }
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let label = kind.loadingLabel
        let measured = (label as NSString).size(
            withAttributes: [.font: font]
        )
        let labelSize = CGSize(
            width: ceil(measured.width),
            height: ceil(measured.height)
        )
        let spinnerSize: CGFloat = 16
        let spacing: CGFloat = 8
        let controlSize = CGSize(
            width: spinnerSize + spacing + labelSize.width,
            height: max(spinnerSize, labelSize.height)
        )
        let controlFrame = CGRect(
            x: (width - controlSize.width) / 2,
            y: 10,
            width: controlSize.width,
            height: controlSize.height
        )
        let labelFrame = CGRect(
            x: controlFrame.minX + spinnerSize + spacing,
            y: controlFrame.minY
                + (controlFrame.height - labelSize.height) / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        let spinnerFrame = CGRect(
            x: controlFrame.minX,
            y: controlFrame.minY,
            width: spinnerSize,
            height: spinnerSize
        )
        return Self(
            height: controlFrame.maxY + 10,
            controlFrame: controlFrame,
            labelFrame: labelFrame,
            spinnerFrame: spinnerFrame
        )
    }
}

struct NativeTimelineRowLayout {
    struct CommandInvocationRegion {
        let frame: CGRect
        let connectorFrame: CGRect
        let avatarFrame: CGRect?
        let fallbackAvatarFrame: CGRect?
        let profileFrame: CGRect
        let userFrame: CGRect
        let usedFrame: CGRect
        let pillFrame: CGRect
        let commandSymbolFrame: CGRect
        let commandFrame: CGRect
    }

    struct EphemeralRegion {
        let frame: CGRect
        let eyeFrame: CGRect
        let visibilityFrame: CGRect
        let bulletFrame: CGRect
        let dismissFrame: CGRect
    }

    struct AttachmentRegion {
        let frame: CGRect
        let attachment: Attachment
    }

    struct ReactionRegion {
        struct AvatarRegion {
            let frame: CGRect
            let reactor: ReactionReactor
        }

        let frame: CGRect
        let reaction: Reaction
        let emojiFrame: CGRect
        let countFrame: CGRect?
        let avatarRegions: [AvatarRegion]
        let overflowFrame: CGRect?
    }

    struct LinkedImageRegion {
        let frame: CGRect
        let reference: LinkedImageReference
    }

    struct EmbedRegion {
        enum Kind: Equatable {
            case bareMedia
            case card
        }

        struct TextRegion {
            let frame: CGRect
            let text: NativeTimelineAttributedTextBox
            let isSelectable: Bool
        }

        struct ImageRegion {
            let frame: CGRect
            let url: URL
            let cornerRadius: CGFloat
            let fallbackSystemImage: String
            let maximumPixelDimension: Int
        }

        let embedID: String
        let kind: Kind
        let frame: CGRect
        let textRegions: [TextRegion]
        let imageRegions: [ImageRegion]
        let mediaFrame: CGRect?
        let mediaURL: URL?
        let mediaIsVideo: Bool
        let mediaAutoplaysInline: Bool
        let accentColor: UInt32?
    }

    let height: CGFloat
    let loaderLayout: NativeTimelineLoaderLayout?
    let beginningLayout: NativeTimelineBeginningLayout?
    let highlightFrame: CGRect?
    let daySeparatorFrame: CGRect?
    let unreadSeparatorFrame: CGRect?
    let avatarFrame: CGRect?
    let compactTimestampFrame: CGRect?
    let authorFrame: CGRect?
    let botBadgeFrame: CGRect?
    let timestampFrame: CGRect?
    let editedFrame: CGRect?
    let loadingIndicatorFrame: CGRect?
    let replyFrame: CGRect?
    let commandInvocationRegion: CommandInvocationRegion?
    let systemIconFrame: CGRect?
    let contentFrame: CGRect?
    let attributedContent: NSAttributedString?
    let contentFramesetter: CTFramesetter?
    let linkedImageRegions: [LinkedImageRegion]
    let attachmentRegions: [AttachmentRegion]
    let embedFrames: [CGRect]
    let embedRegions: [EmbedRegion]
    let componentFrames: [CGRect]
    let componentLayouts: [NativeTimelineComponentLayout]
    let stickerFrames: [CGRect]
    let threadFrame: CGRect?
    let reactionRegions: [ReactionRegion]
    let addReactionFrame: CGRect?
    let ephemeralRegion: EphemeralRegion?
    let failedFrame: CGRect?

    static func make(
        item: NativeMessageTimelineItem,
        width proposedWidth: CGFloat,
        model: AppModel? = nil
    ) -> Self {
        let width = max(220, proposedWidth)
        switch item {
        case let .loader(isLoading, kind):
            let loaderLayout = NativeTimelineLoaderLayout.make(
                isLoading: isLoading,
                kind: kind,
                width: width
            )
            return empty(
                height: loaderLayout.height,
                loaderLayout: loaderLayout,
                loadingIndicatorFrame: loaderLayout.spinnerFrame
            )
        case let .beginning(beginning):
            let beginningLayout = NativeTimelineBeginningLayout.make(
                beginning: beginning,
                width: width
            )
            return empty(
                height: beginningLayout.height,
                beginningLayout: beginningLayout
            )
        case let .message(row, isUnreadBoundary, _):
            return message(
                row,
                isUnreadBoundary: isUnreadBoundary,
                width: width,
                model: model
            )
        }
    }

    private static func empty(
        height: CGFloat,
        loaderLayout: NativeTimelineLoaderLayout? = nil,
        beginningLayout: NativeTimelineBeginningLayout? = nil,
        loadingIndicatorFrame: CGRect? = nil
    ) -> Self {
        Self(
            height: height,
            loaderLayout: loaderLayout,
            beginningLayout: beginningLayout,
            highlightFrame: nil,
            daySeparatorFrame: nil,
            unreadSeparatorFrame: nil,
            avatarFrame: nil,
            compactTimestampFrame: nil,
            authorFrame: nil,
            botBadgeFrame: nil,
            timestampFrame: nil,
            editedFrame: nil,
            loadingIndicatorFrame: loadingIndicatorFrame,
            replyFrame: nil,
            commandInvocationRegion: nil,
            systemIconFrame: nil,
            contentFrame: nil,
            attributedContent: nil,
            contentFramesetter: nil,
            linkedImageRegions: [],
            attachmentRegions: [],
            embedFrames: [],
            embedRegions: [],
            componentFrames: [],
            componentLayouts: [],
            stickerFrames: [],
            threadFrame: nil,
            reactionRegions: [],
            addReactionFrame: nil,
            ephemeralRegion: nil,
            failedFrame: nil
        )
    }

    private static func message(
        _ row: MessageRowPresentation,
        isUnreadBoundary: Bool,
        width: CGFloat,
        model: AppModel?
    ) -> Self {
        let message = row.message
        let horizontalInset: CGFloat = 14
        let avatarWidth: CGFloat = 38
        let columnGap: CGFloat = 12
        let ordinaryContentX = horizontalInset + avatarWidth + columnGap
        let ordinaryContentWidth = max(
            80,
            width - ordinaryContentX - horizontalInset
        )
        let isGenerated = message.type.hasGeneratedContent
        let contentX: CGFloat = isGenerated ? horizontalInset + 58 : ordinaryContentX
        let contentWidth = max(80, width - contentX - horizontalInset)
        var prefixHeight: CGFloat = 0

        var daySeparatorFrame: CGRect?
        if row.startsDay {
            daySeparatorFrame = CGRect(
                x: horizontalInset,
                y: prefixHeight,
                width: width - 28,
                height: NativeTimelineDateSeparatorMetrics.rowHeight
            )
            prefixHeight += NativeTimelineDateSeparatorMetrics.rowHeight
        }

        var unreadSeparatorFrame: CGRect?
        if isUnreadBoundary {
            unreadSeparatorFrame = CGRect(
                x: horizontalInset,
                y: prefixHeight,
                width: width - 24,
                height: NativeTimelineUnreadSeparatorMetrics.rowHeight
            )
            prefixHeight += NativeTimelineUnreadSeparatorMetrics.rowHeight
        }

        let highlightInsets = MessageRowLayoutMetrics.highlightInsets(
            hasReplyPreview: row.replyPreview != nil,
            isEditing: false
        )
        let externalTopSeparation = MessageRowLayoutMetrics.separation(
            startsGroup: row.startsGroup,
            followsTimelineSeparator: row.startsDay || isUnreadBoundary,
            highlightTopInset: highlightInsets.top
        )
        let highlightMinY = prefixHeight + externalTopSeparation
        var y = highlightMinY + highlightInsets.top

        var replyFrame: CGRect?
        if row.replyPreview != nil {
            replyFrame = CGRect(
                x: horizontalInset,
                y: y,
                width: width - horizontalInset * 2,
                height: 20
            )
            y += 20
        }

        var commandInvocationRegion: CommandInvocationRegion?
        if message.type == .chatInputCommand {
            commandInvocationRegion = commandInvocation(
                message,
                origin: CGPoint(x: horizontalInset, y: y),
                maximumWidth: width - horizontalInset * 2
            )
            y += MessageRowLayoutMetrics.commandInvocationHeight
        }

        var avatarFrame: CGRect?
        var compactTimestampFrame: CGRect?
        var authorFrame: CGRect?
        var botBadgeFrame: CGRect?
        var timestampFrame: CGRect?
        var editedFrame: CGRect?
        var loadingIndicatorFrame: CGRect?
        if row.startsGroup, !isGenerated {
            let author = model.map {
                $0.authorPresentation(for: message).user
            } ?? message.author
            let authorFont = NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
                weight: .semibold
            )
            let authorWidth = min(
                ordinaryContentWidth,
                measuredTextWidth(author.displayName, font: authorFont)
            )
            avatarFrame = CGRect(
                x: horizontalInset,
                y: y,
                width: avatarWidth,
                height: avatarWidth
            )
            authorFrame = CGRect(
                x: contentX,
                y: y,
                width: authorWidth,
                height: MessageRowLayoutMetrics.authorLineHeight
            )
            var headerX = contentX + authorWidth
            if author.isBot {
                headerX += 7
                let badgeFont = NSFont.systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
                    weight: .bold
                )
                let badgeWidth = measuredTextWidth(
                    "APP",
                    font: badgeFont
                ) + 8
                botBadgeFrame = CGRect(
                    x: headerX,
                    // Discord gives the application badge enough vertical
                    // weight to read as a badge, while keeping it centered
                    // inside the fixed author line.
                    y: y + 1,
                    width: badgeWidth,
                    height: 14
                )
                headerX += badgeWidth
            }
            headerX += 7
            let timestampFont = NSFont.preferredFont(forTextStyle: .caption1)
            let timestamp = NativeTimelineTimestamp.text(for: message.timestamp)
            let timestampWidth = measuredTextWidth(
                timestamp,
                font: timestampFont
            )
            timestampFrame = CGRect(
                x: headerX,
                y: y + 3,
                width: min(timestampWidth, max(0, contentX + contentWidth - headerX)),
                height: 13
            )
            headerX = timestampFrame?.maxX ?? headerX
            if message.editedTimestamp != nil {
                headerX += 7
                let editedFont = NSFont.preferredFont(forTextStyle: .caption2)
                editedFrame = CGRect(
                    x: headerX,
                    y: y + 4,
                    width: min(
                        measuredTextWidth("(edited)", font: editedFont),
                        max(0, contentX + contentWidth - headerX)
                    ),
                    height: 11
                )
                headerX = editedFrame?.maxX ?? headerX
            }
            if message.flags.contains(.loading) {
                headerX += 7
                loadingIndicatorFrame = CGRect(
                    x: headerX,
                    y: y + 2,
                    width: min(
                        12,
                        max(
                            0,
                            contentX + contentWidth - headerX
                        )
                    ),
                    height: 12
                )
            }
            y += MessageRowLayoutMetrics.authorLineHeight
                + MessageRowLayoutMetrics.authorToContentSpacing(
                    isCommandResponse: message.type == .chatInputCommand
                )
        } else if !isGenerated {
            compactTimestampFrame = CGRect(
                x: horizontalInset,
                y: y,
                width: avatarWidth,
                height: MessageRowLayoutMetrics.compactContentHeight
            )
        }

        var systemIconFrame: CGRect?
        if isGenerated {
            systemIconFrame = CGRect(
                x: horizontalInset + 36,
                y: y,
                width: 16,
                height: MessageRowLayoutMetrics.compactContentHeight
            )
        }

        var contentFrame: CGRect?
        var hasRichContent = false
        let usesComponentsV2 = message.flags.contains(.isComponentsV2)
        let contentPresentation =
            usesComponentsV2
                ? NativeTimelineTextPresentation.empty
                : NativeTimelineTextPresentation.make(
                    message: message,
                    plan: row.textPlan,
                    model: model
                )
        if let attributedContent = contentPresentation.attributedContent {
            let textHeight = measuredTextHeight(
                contentPresentation.framesetter,
                value: attributedContent,
                length: attributedContent.length,
                width: contentWidth
            )
            contentFrame = CGRect(x: contentX, y: y, width: contentWidth, height: textHeight)
            y += textHeight
            hasRichContent = true
        }

        var linkedImageRegions: [LinkedImageRegion] = []
        if !contentPresentation.linkedImages.isEmpty {
            if hasRichContent {
                y += 6
            }
            let plan = InlineWrappingLayoutPlan.frames(
                sizes: contentPresentation.linkedImages.map { $0.displaySize },
                maximumWidth: contentWidth,
                horizontalSpacing: 4,
                verticalSpacing: 4
            )
            linkedImageRegions = zip(
                contentPresentation.linkedImages,
                plan.frames
            ).map { reference, frame in
                LinkedImageRegion(
                    frame: frame.offsetBy(dx: contentX, dy: y),
                    reference: reference
                )
            }
            y += plan.size.height
            hasRichContent = true
        }

        var attachmentRegions: [AttachmentRegion] = []
        if !usesComponentsV2, !message.attachments.isEmpty {
            if hasRichContent {
                y += 8
            }
            let galleryWidth = min(500, max(180, contentWidth))
            let galleryFrames = MediaGalleryPlan.frames(
                count: message.attachments.count,
                width: galleryWidth,
                aspectRatios: message.attachments.map {
                    guard let width = $0.width,
                          let height = $0.height,
                          width > 0,
                          height > 0
                    else { return 16 / 9 }
                    return CGFloat(width) / CGFloat(height)
                },
                intrinsicSizes: message.attachments.map {
                    guard let width = $0.width,
                          let height = $0.height,
                          width > 0,
                          height > 0
                    else { return .zero }
                    return CGSize(
                        width: CGFloat(width),
                        height: CGFloat(height)
                    )
                },
                spacing: 4
            )
            attachmentRegions = zip(
                message.attachments,
                galleryFrames
            ).map { attachment, frame in
                AttachmentRegion(
                    frame: frame.offsetBy(dx: contentX, dy: y),
                    attachment: attachment
                )
            }
            y += galleryFrames.map(\.maxY).max() ?? 0
            hasRichContent = true
        }

        var embedRegions: [EmbedRegion] = []
        if !usesComponentsV2 {
            let visibleEmbeds =
                MessageEmbedPresentation.visibleEmbeds(for: message)
            embedRegions.reserveCapacity(visibleEmbeds.count)
            for embed in visibleEmbeds {
                let embedY = y + (hasRichContent ? 8 : 0)
                guard let region = NativeTimelineEmbedLayout.make(
                    embed: embed,
                    message: message,
                    model: model,
                    attachments: message.attachments,
                    origin: CGPoint(x: contentX, y: embedY),
                    maximumWidth: min(contentWidth, 520)
                ) else { continue }
                embedRegions.append(region)
                y = region.frame.maxY
                hasRichContent = true
            }
        }
        let embedFrames = embedRegions.map(\.frame)

        var componentLayouts: [NativeTimelineComponentLayout] = []
        let componentY = y + (hasRichContent ? 8 : 0)
        if let componentLayout = NativeTimelineComponentLayout.make(
            message: message,
            model: model,
            origin: CGPoint(x: contentX, y: componentY),
            maximumWidth: min(contentWidth, 520)
        ) {
            componentLayouts.append(componentLayout)
            y = componentLayout.frame.maxY
            hasRichContent = true
        }
        let componentFrames = componentLayouts.map(\.frame)

        var stickerFrames: [CGRect] = []
        if !message.stickers.isEmpty {
            if hasRichContent {
                y += 8
            }
            let size = min(contentWidth, 112)
            var stickerX = contentX
            var rowHeight: CGFloat = 0
            for _ in message.stickers {
                if stickerX + size > contentX + contentWidth,
                   stickerX > contentX
                {
                    stickerX = contentX
                    y += rowHeight + 8
                    rowHeight = 0
                }
                stickerFrames.append(
                    CGRect(x: stickerX, y: y, width: size, height: size)
                )
                stickerX += size + 8
                rowHeight = max(rowHeight, size)
            }
            y += rowHeight
            hasRichContent = true
        }

        var threadFrame: CGRect?
        if message.thread != nil {
            if hasRichContent {
                y += 8
            }
            threadFrame = CGRect(
                x: contentX,
                y: y,
                width: min(contentWidth, 500),
                height: 48
            )
            y += 48
            hasRichContent = true
        }

        var reactionRegions: [ReactionRegion] = []
        var addReactionFrame: CGRect?
        let presentedReactions = MessageReactionPresentation.items(
            from: message.reactions
        )
        if !presentedReactions.isEmpty {
            if hasRichContent {
                y += 4
            }
            let sizes = presentedReactions.map(reactionSize)
                + [CGSize(
                    width: ReactionActionMenuPresentation.inline.width,
                    height: MessageReactionMetrics.pillHeight
                )]
            let wrapping = InlineWrappingLayoutPlan.frames(
                sizes: sizes,
                maximumWidth: contentWidth,
                horizontalSpacing: MessageReactionMetrics.horizontalSpacing,
                verticalSpacing: MessageReactionMetrics.verticalSpacing
            )
            reactionRegions = zip(
                presentedReactions,
                wrapping.frames.prefix(presentedReactions.count)
            ).map { reaction, frame in
                reactionRegion(
                    reaction,
                    frame: frame.offsetBy(dx: contentX, dy: y)
                )
            }
            if let frame = wrapping.frames.last {
                addReactionFrame = frame.offsetBy(dx: contentX, dy: y)
            }
            y += wrapping.size.height
        }

        var ephemeralRegion: EphemeralRegion?
        if message.flags.contains(.ephemeral) {
            if hasRichContent || !presentedReactions.isEmpty {
                y += 4
            }
            ephemeralRegion = ephemeral(
                origin: CGPoint(x: contentX, y: y),
                maximumWidth: contentWidth
            )
            y += 15
        }

        var failedFrame: CGRect?
        if message.outboxState == .failed {
            if hasRichContent
                || !presentedReactions.isEmpty
                || ephemeralRegion != nil
            {
                y += 4
            }
            failedFrame = CGRect(
                x: contentX,
                y: y,
                width: contentWidth,
                height: 14
            )
            y += 14
        }

        let visibleContentMaxY = max(
            y,
            avatarFrame?.maxY ?? 0,
            authorFrame?.maxY ?? 0
        )
        let rowHeight = ceil(
            max(
                visibleContentMaxY + highlightInsets.bottom,
                highlightMinY
                    + highlightInsets.top
                    + (row.startsGroup && !isGenerated
                        ? MessageRowLayoutMetrics.avatarDiameter
                        : MessageRowLayoutMetrics.compactContentHeight)
                    + highlightInsets.bottom
            )
        )
        let highlightFrame = CGRect(
            x: 0,
            y: highlightMinY,
            width: width,
            height: max(0, rowHeight - highlightMinY)
        )

        return Self(
            height: rowHeight,
            loaderLayout: nil,
            beginningLayout: nil,
            highlightFrame: highlightFrame,
            daySeparatorFrame: daySeparatorFrame,
            unreadSeparatorFrame: unreadSeparatorFrame,
            avatarFrame: avatarFrame,
            compactTimestampFrame: compactTimestampFrame,
            authorFrame: authorFrame,
            botBadgeFrame: botBadgeFrame,
            timestampFrame: timestampFrame,
            editedFrame: editedFrame,
            loadingIndicatorFrame: loadingIndicatorFrame,
            replyFrame: replyFrame,
            commandInvocationRegion: commandInvocationRegion,
            systemIconFrame: systemIconFrame,
            contentFrame: contentFrame,
            attributedContent: contentPresentation.attributedContent,
            contentFramesetter: contentPresentation.framesetter,
            linkedImageRegions: linkedImageRegions,
            attachmentRegions: attachmentRegions,
            embedFrames: embedFrames,
            embedRegions: embedRegions,
            componentFrames: componentFrames,
            componentLayouts: componentLayouts,
            stickerFrames: stickerFrames,
            threadFrame: threadFrame,
            reactionRegions: reactionRegions,
            addReactionFrame: addReactionFrame,
            ephemeralRegion: ephemeralRegion,
            failedFrame: failedFrame
        )
    }

    private static func commandInvocation(
        _ message: Message,
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> CommandInvocationRegion {
        let user = message.interactionMetadata?.user
        let userLabel = user?.displayName ?? "Someone"
        let commandLabel = message.interactionMetadata?.displayName ?? "command"
        let userFont = NSFont.systemFont(
            ofSize: NSFont.preferredFont(
                forTextStyle: .caption2
            ).pointSize,
            weight: .semibold
        )
        let captionFont = NSFont.preferredFont(
            forTextStyle: .caption1
        )
        let commandFont = NSFont.systemFont(
            ofSize: NSFont.preferredFont(
                forTextStyle: .caption1
            ).pointSize,
            weight: .semibold
        )
        let frame = CGRect(
            origin: origin,
            size: CGSize(
                width: maximumWidth,
                height: MessageRowLayoutMetrics.commandInvocationHeight
            )
        )
        let connectorFrame = CGRect(
            x: origin.x,
            y: origin.y,
            width: 30,
            height: MessageRowLayoutMetrics.commandInvocationHeight
        )
        var x = connectorFrame.maxX + 5
        let avatarFrame = user.map { _ in
            CGRect(
                x: x,
                y: origin.y
                    + MessageRowLayoutMetrics.commandInvocationContentInset,
                width: 14,
                height: 14
            )
        }
        let fallbackAvatarFrame = user == nil
            ? CGRect(
                x: x,
                y: origin.y
                    + MessageRowLayoutMetrics.commandInvocationContentInset,
                width: 14,
                height: 14
            )
            : nil
        x += 14 + 5
        let availableMaxX = frame.maxX - 48
        let userWidth = min(
            measuredTextWidth(userLabel, font: userFont),
            max(0, availableMaxX - x)
        )
        let userFrame = CGRect(
            x: x,
            y: origin.y + 3,
            width: userWidth,
            height: 14
        )
        x = userFrame.maxX + 5
        let usedWidth = min(
            measuredTextWidth("used", font: captionFont),
            max(0, availableMaxX - x)
        )
        let usedFrame = CGRect(
            x: x,
            y: origin.y + 2,
            width: usedWidth,
            height: 16
        )
        x = usedFrame.maxX + 5
        let symbolWidth: CGFloat = 10
        let naturalCommandWidth = measuredTextWidth(
            commandLabel,
            font: commandFont
        )
        let pillWidth = min(
            6 + symbolWidth + 3 + naturalCommandWidth + 6,
            max(0, availableMaxX - x)
        )
        let pillFrame = CGRect(
            x: x,
            y: origin.y + 2,
            width: pillWidth,
            height: 16
        )
        let commandSymbolFrame = CGRect(
            x: pillFrame.minX + 6,
            y: pillFrame.minY + 3,
            width: symbolWidth,
            height: 10
        )
        let commandFrame = CGRect(
            x: commandSymbolFrame.maxX + 3,
            y: pillFrame.minY,
            width: max(0, pillFrame.maxX - 6 - commandSymbolFrame.maxX - 3),
            height: 16
        )
        let profileFrame = (
            avatarFrame
                ?? fallbackAvatarFrame
                ?? userFrame
        ).union(userFrame)
        return CommandInvocationRegion(
            frame: frame,
            connectorFrame: connectorFrame,
            avatarFrame: avatarFrame,
            fallbackAvatarFrame: fallbackAvatarFrame,
            profileFrame: profileFrame,
            userFrame: userFrame,
            usedFrame: usedFrame,
            pillFrame: pillFrame,
            commandSymbolFrame: commandSymbolFrame,
            commandFrame: commandFrame
        )
    }

    private static func ephemeral(
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> EphemeralRegion {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let frame = CGRect(
            origin: origin,
            size: CGSize(width: maximumWidth, height: 15)
        )
        var x = origin.x
        let eyeFrame = CGRect(x: x, y: origin.y + 1, width: 13, height: 13)
        x = eyeFrame.maxX + 4
        let visibilityWidth = min(
            measuredTextWidth("Only you can see this", font: font),
            max(0, frame.maxX - x)
        )
        let visibilityFrame = CGRect(
            x: x,
            y: origin.y,
            width: visibilityWidth,
            height: 15
        )
        x = visibilityFrame.maxX + 4
        let bulletWidth = min(
            measuredTextWidth("•", font: font),
            max(0, frame.maxX - x)
        )
        let bulletFrame = CGRect(
            x: x,
            y: origin.y,
            width: bulletWidth,
            height: 15
        )
        x = bulletFrame.maxX + 4
        let dismissFrame = CGRect(
            x: x,
            y: origin.y,
            width: min(
                measuredTextWidth("Dismiss message", font: font),
                max(0, frame.maxX - x)
            ),
            height: 15
        )
        return EphemeralRegion(
            frame: frame,
            eyeFrame: eyeFrame,
            visibilityFrame: visibilityFrame,
            bulletFrame: bulletFrame,
            dismissFrame: dismissFrame
        )
    }

    private static func reactionSize(_ reaction: Reaction) -> CGSize {
        let plan = MessageReactionPresentation.previewPlan(for: reaction)
        var width: CGFloat = 12 + MessageReactionMetrics.emojiSize
        if reaction.count > 0 {
            width += 4 + measuredTextWidth(
                String(reaction.count),
                font: .monospacedDigitSystemFont(
                    ofSize: NSFont.preferredFont(
                        forTextStyle: .caption1
                    ).pointSize,
                    weight: .semibold
                )
            )
        }
        if !plan.isEmpty {
            width += 4 + reactionPreviewWidth(plan)
        }
        return CGSize(
            width: ceil(width),
            height: MessageReactionMetrics.pillHeight
        )
    }

    private static func reactionPreviewWidth(
        _ plan: MessageReactionPreviewPlan
    ) -> CGFloat {
        let avatarsWidth = plan.reactors.isEmpty
            ? 0
            : MessageReactionMetrics.avatarSize
                + CGFloat(plan.reactors.count - 1) * 11
        guard plan.overflowCount > 0 else { return avatarsWidth }
        let overflowWidth = max(
            MessageReactionMetrics.avatarSize,
            measuredTextWidth(
                "+\(plan.overflowCount)",
                font: .monospacedDigitSystemFont(
                    ofSize: 10,
                    weight: .bold
                )
            )
        )
        return avatarsWidth
            + (plan.reactors.isEmpty ? 0 : 2)
            + overflowWidth
    }

    private static func reactionRegion(
        _ reaction: Reaction,
        frame: CGRect
    ) -> ReactionRegion {
        var x = frame.minX + 6
        let emojiFrame = CGRect(
            x: x,
            y: frame.midY - MessageReactionMetrics.emojiSize / 2,
            width: MessageReactionMetrics.emojiSize,
            height: MessageReactionMetrics.emojiSize
        )
        x = emojiFrame.maxX

        var countFrame: CGRect?
        if reaction.count > 0 {
            x += 4
            let countWidth = measuredTextWidth(
                String(reaction.count),
                font: .monospacedDigitSystemFont(
                    ofSize: NSFont.preferredFont(
                        forTextStyle: .caption1
                    ).pointSize,
                    weight: .semibold
                )
            )
            countFrame = CGRect(
                x: x,
                y: frame.minY,
                width: countWidth,
                height: frame.height
            )
            x += countWidth
        }

        let plan = MessageReactionPresentation.previewPlan(for: reaction)
        var avatars: [ReactionRegion.AvatarRegion] = []
        var overflowFrame: CGRect?
        if !plan.isEmpty {
            x += 4
            for (index, reactor) in plan.reactors.enumerated() {
                let avatarFrame = CGRect(
                    x: x + CGFloat(index) * 11,
                    y: frame.midY - MessageReactionMetrics.avatarSize / 2,
                    width: MessageReactionMetrics.avatarSize,
                    height: MessageReactionMetrics.avatarSize
                )
                avatars.append(.init(frame: avatarFrame, reactor: reactor))
            }
            if !plan.reactors.isEmpty {
                x += MessageReactionMetrics.avatarSize
                    + CGFloat(plan.reactors.count - 1) * 11
            }
            if plan.overflowCount > 0 {
                if !plan.reactors.isEmpty {
                    x += 2
                }
                overflowFrame = CGRect(
                    x: x,
                    y: frame.minY,
                    width: max(
                        MessageReactionMetrics.avatarSize,
                        frame.maxX - 6 - x
                    ),
                    height: frame.height
                )
            }
        }
        return ReactionRegion(
            frame: frame,
            reaction: reaction,
            emojiFrame: emojiFrame,
            countFrame: countFrame,
            avatarRegions: avatars,
            overflowFrame: overflowFrame
        )
    }

    fileprivate static func measuredTextHeight(
        _ framesetter: CTFramesetter,
        value: NSAttributedString,
        length: Int,
        width: CGFloat
    ) -> CGFloat {
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: length),
            nil,
            CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            nil
        )
        // SwiftUI's one-line message text fits exactly in the established
        // 18-point compact row. CoreText reports that same line just under
        // 19 points because its suggested bounds include fractional font
        // leading. Multiline suggestions retain one trailing point that the
        // preserved NSTextView usedRect omitted.
        if size.height < 20 {
            return MessageRowLayoutMetrics.compactContentHeight
        }
        return ceil(size.height - 1.01)
            + NativeTimelineMarkdownChromeMetrics
                .trailingVisualOverflow(in: value)
    }

    private static func measuredTextWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

}

@MainActor
private enum NativeTimelineTextPresentation {
    struct Value {
        let attributedContent: NSAttributedString?
        let framesetter: CTFramesetter
        let linkedImages: [LinkedImageReference]
    }

    static var empty: Value {
        Value(
            attributedContent: nil,
            framesetter: CTFramesetterCreateWithAttributedString(
                NSAttributedString()
            ),
            linkedImages: []
        )
    }

    static func make(
        message: Message,
        plan: NativeTimelineTextPlan,
        model: AppModel?
    ) -> Value {
        guard let prepared = plan.preparedText else {
            return Value(
                attributedContent: nil,
                framesetter: CTFramesetterCreateWithAttributedString(
                    NSAttributedString()
                ),
                linkedImages: plan.linkedImages
            )
        }

        if let preparedBox = plan.attributedText {
            return Value(
                attributedContent: preparedBox.value,
                framesetter: preparedBox.framesetter,
                linkedImages: plan.linkedImages
            )
        }

        let resolver = model.map { MessageMentionResolver(model: $0, message: message) }
        let mentions = prepared.tokens.reduce(into: [String: MentionPresentation]()) {
            values,
            token in
            guard case let .mention(mention) = token else { return }
            values[mention.rawToken] =
                resolver?.presentation(mention)
                ?? MentionPresentation.fallback(for: mention)
        }
        let emojiSize: CGFloat = prepared.isEmojiOnly ? 48 : 22
        let cacheKey = NativeTimelineResolvedTextCache.Key(
            messageID: message.id,
            scope: "message",
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: plan.baseFontSize,
            mentions: mentions.values.sorted {
                $0.rawToken < $1.rawToken
            }
        )
        let box = NativeTimelineResolvedTextCache.shared.box(
            for: cacheKey
        ) {
            NativeTimelineAttributedTextBox(
                NativeTimelineCoreText.make(
                    prepared: prepared,
                    emojiSize: emojiSize,
                    baseFontSize: plan.baseFontSize,
                    mentionPresentations: mentions
                )
            )
        }
        return Value(
            attributedContent: box.value,
            framesetter: box.framesetter,
            linkedImages: plan.linkedImages
        )
    }
}

final class NativeTimelineResolvedTextCache {
    struct Key: Hashable {
        let messageID: MessageID
        let scope: String
        let prepared: RichMessageAttributedText.Prepared
        let emojiSize: CGFloat
        let baseFontSize: CGFloat
        let mentions: [MentionPresentation]
    }

    static let shared = NativeTimelineResolvedTextCache()

    private let entryLimit = 2_000
    private var entries: [Key: NativeTimelineAttributedTextBox] = [:]
    private var insertionOrder: [Key] = []
    private var evictionIndex = 0

    private init() {
        entries.reserveCapacity(entryLimit)
        insertionOrder.reserveCapacity(entryLimit + 512)
    }

    func box(
        for key: Key,
        make: () -> NativeTimelineAttributedTextBox
    ) -> NativeTimelineAttributedTextBox {
        if let cached = entries[key] {
            return cached
        }
        let box = make()
        entries[key] = box
        insertionOrder.append(key)
        while entries.count > entryLimit,
              evictionIndex < insertionOrder.count
        {
            let oldest = insertionOrder[evictionIndex]
            evictionIndex += 1
            entries.removeValue(forKey: oldest)
        }
        if evictionIndex > 1_024,
           evictionIndex * 2 > insertionOrder.count
        {
            insertionOrder.removeFirst(evictionIndex)
            evictionIndex = 0
        }
        return box
    }
}

enum NativeTimelineCoreText {
    private static let runDelegateKey = NSAttributedString.Key(
        rawValue: kCTRunDelegateAttributeName as String
    )

    static func make(
        prepared: RichMessageAttributedText.Prepared,
        emojiSize: CGFloat,
        baseFontSize: CGFloat? = nil,
        mentionPresentations: [String: MentionPresentation]
    ) -> NSAttributedString {
        let resolvedBaseFontSize =
            prepared.isEmojiOnly
                ? emojiSize
                : baseFontSize ?? 15
        let baseFont = NSFont.systemFont(ofSize: resolvedBaseFontSize)
        let output = NSMutableAttributedString(
            attributedString: DiscordMarkdown.appKitAttributed(
                prepared.markdownPlan,
                baseFontSize: resolvedBaseFontSize
            )
        )
        let fullRange = NSRange(location: 0, length: output.length)
        let placeholderRanges = ranges(of: "\u{FFFC}", in: output.string)
        for (range, token) in zip(
            placeholderRanges.reversed(),
            prepared.tokens.reversed()
        ) {
            var inlineAttributes = output.attributes(
                at: range.location,
                effectiveRange: nil
            )
            let replacement: NSAttributedString
            switch token {
            case let .customEmoji(emoji):
                inlineAttributes[.discordEmojiToken] = emoji.rawToken
                replacement = inlineRun(
                    width: emojiSize,
                    height: emojiSize,
                    baselineOffset: ComposerEmojiAttributedText
                        .attachmentOriginY(font: baseFont, size: emojiSize),
                    attributes: inlineAttributes
                )
            case let .mention(mention):
                let presentation =
                    mentionPresentations[mention.rawToken]
                    ?? MentionPresentation.fallback(for: mention)
                let metrics = mentionMetrics(
                    presentation: presentation,
                    font: baseFont
                )
                inlineAttributes[.discordMentionToken] =
                    presentation.rawToken
                inlineAttributes[.nativeTimelineMention] =
                    NativeTimelineMentionBox(presentation)
                replacement = inlineRun(
                    width: metrics.width,
                    height: metrics.height,
                    baselineOffset: ComposerEmojiAttributedText
                        .attachmentOriginY(
                            font: baseFont,
                            size: metrics.height
                        ),
                    attributes: inlineAttributes
                )
            }
            output.replaceCharacters(in: range, with: replacement)
        }
        output.enumerateAttribute(.link, in: fullRange) {
            value, range, _ in
            guard value != nil else { return }
            output.addAttributes(
                [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: 0,
                ],
                range: range
            )
        }
        normalizeParagraphMetrics(in: output)
        return output
    }

    private static func normalizeParagraphMetrics(
        in output: NSMutableAttributedString
    ) {
        guard output.length > 0 else { return }
        let source = output.string as NSString
        var location = 0
        while location < output.length {
            let paragraphRange = source.paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            var lineHeight: CGFloat = 0
            var containsInlineRun = false
            output.enumerateAttributes(
                in: paragraphRange,
                options: []
            ) { attributes, _, _ in
                if attributes[runDelegateKey] != nil {
                    containsInlineRun = true
                }
                guard let font = attributes[.font] as? NSFont else {
                    return
                }
                lineHeight = max(
                    lineHeight,
                    ceil(font.ascender - font.descender + font.leading)
                )
            }
            let existing = output.attribute(
                .paragraphStyle,
                at: paragraphRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            let style = (existing?.mutableCopy()
                as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            // NSTextView's usedRect follows the typographic line bounds and
            // does not count the shared markdown style's trailing point.
            // CoreText otherwise rounds up the font bounding box and counts
            // that point once per line.
            style.lineSpacing = 0
            if !containsInlineRun, lineHeight > 0 {
                style.minimumLineHeight = lineHeight
                style.maximumLineHeight = lineHeight
            }
            output.addAttribute(
                .paragraphStyle,
                value: style,
                range: paragraphRange
            )
            location = NSMaxRange(paragraphRange)
        }
    }

    private static func inlineRun(
        width: CGFloat,
        height: CGFloat,
        baselineOffset: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var attributes = attributes
        attributes[runDelegateKey] = NativeTimelineRunDelegate.make(
            width: width,
            height: height,
            baselineOffset: baselineOffset
        )
        return NSAttributedString(
            string: "\u{FFFC}",
            attributes: attributes
        )
    }

    private static func mentionMetrics(
        presentation: MentionPresentation,
        font: NSFont
    ) -> (width: CGFloat, height: CGFloat) {
        let labelFont = NSFont.systemFont(
            ofSize: font.pointSize,
            weight: .semibold
        )
        let labelWidth = ceil(
            (presentation.label as NSString).size(
                withAttributes: [.font: labelFont]
            ).width
        )
        let height = max(21, ceil(font.pointSize + 6))
        let showsAvatar = if case .user = presentation.target { true } else { false }
        let showsLeadingIcon = presentation.systemImage != nil
        let avatarSize = height - 6
        let iconSize = height - 7
        let width = ceil(
            12 + labelWidth
                + (showsAvatar ? avatarSize + 4 : 0)
                + (showsLeadingIcon ? iconSize + 4 : 0)
        )
        return (width, height)
    }

    private static func ranges(
        of value: String,
        in source: String
    ) -> [NSRange] {
        let source = source as NSString
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let range = source.range(
                of: value,
                options: [],
                range: searchRange
            )
            guard range.location != NSNotFound else { break }
            result.append(range)
            let nextLocation = NSMaxRange(range)
            searchRange = NSRange(
                location: nextLocation,
                length: source.length - nextLocation
            )
        }
        return result
    }
}

private enum NativeTimelineEmbedLayout {
    private struct PreparedField {
        let field: MessageEmbedField
        let name: NativeTimelineAttributedTextBox
        let value: NativeTimelineAttributedTextBox
    }

    static func make(
        embed: MessageEmbed,
        message: Message,
        model: AppModel?,
        attachments: [Attachment],
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> NativeTimelineRowLayout.EmbedRegion? {
        switch MessageEmbedPresentation.kind(for: embed) {
        case .hidden:
            return nil
        case .bareMedia:
            guard let media = embed.image ?? embed.video,
                  let url = resolvedURL(media, attachments: attachments)
            else { return nil }
            let size = mediaSize(
                media,
                maximumWidth: min(maximumWidth, 500),
                maximumHeight: 350
            )
            let frame = CGRect(origin: origin, size: size)
            return .init(
                embedID: embed.id,
                kind: .bareMedia,
                frame: frame,
                textRegions: [],
                imageRegions: [],
                mediaFrame: frame,
                mediaURL: url,
                mediaIsVideo: embed.video != nil,
                mediaAutoplaysInline: embed.type?.lowercased() == "gifv",
                accentColor: nil
            )
        case .card:
            let cardPadding: CGFloat = 12
            let stripeWidth: CGFloat = 4
            let innerChrome = stripeWidth + cardPadding * 2
            let maximumContentWidth = max(80, maximumWidth - innerChrome)

            let author = embed.author.map {
                plainTextBox(
                    $0.name,
                    font: .systemFont(ofSize: 11, weight: .semibold),
                    color: $0.url == nil ? .labelColor : .linkColor,
                    link: $0.url
                )
            }
            let title = embed.title.map {
                plainTextBox(
                    $0,
                    font: .systemFont(ofSize: 13, weight: .semibold),
                    color: embed.url == nil ? .labelColor : .linkColor,
                    link: embed.url
                )
            }
            let description = embed.description.map {
                resolvedTextBox(
                    prepared: RichMessageAttributedText.prepare(source: $0),
                    scope: "description",
                    emojiSize: 18,
                    embed: embed,
                    message: message,
                    model: model
                )
            }
            let fields = embed.fields.enumerated().map { index, field in
                PreparedField(
                    field: field,
                    name: plainTextBox(
                        field.name,
                        font: .systemFont(ofSize: 11, weight: .bold),
                        color: .labelColor
                    ),
                    value: resolvedTextBox(
                        prepared: RichMessageAttributedText.prepare(
                            source: field.value
                        ),
                        scope: "field:\(index)",
                        emojiSize: 16,
                        embed: embed,
                        message: message,
                        model: model
                    )
                )
            }
            let provider = embed.provider?.name.map {
                plainTextBox(
                    $0,
                    font: .systemFont(ofSize: 11),
                    color: .secondaryLabelColor
                )
            }
            let footerText = footerText(
                footer: embed.footer,
                timestamp: embed.timestamp
            )
            let footer = footerText.map {
                plainTextBox(
                    $0,
                    font: .systemFont(ofSize: 11),
                    color: .secondaryLabelColor
                )
            }

            let thumbnailURL = embed.thumbnail.flatMap {
                resolvedURL($0, attachments: attachments)
            }
            let thumbnailSize: CGFloat = thumbnailURL == nil ? 0 : 80
            // The legacy HStack contains text, a zero-minimum Spacer, and the
            // thumbnail. SwiftUI applies its 12-point spacing on both sides
            // of that spacer even when the spacer collapses to zero.
            let thumbnailAllowance: CGFloat =
                thumbnailSize > 0 ? thumbnailSize + 24 : 0

            let naturalTextWidth = textColumnIdealWidth(
                author: author,
                authorHasIcon:
                    (embed.author?.proxyIconURL ?? embed.author?.iconURL) != nil,
                title: title,
                description: description,
                fields: fields,
                provider: provider
            )
            let naturalTopWidth = naturalTextWidth + thumbnailAllowance
            let mainMedia = embed.image ?? embed.video
            let naturalMediaSize = mainMedia.map {
                mediaSize(
                    $0,
                    maximumWidth: maximumContentWidth,
                    maximumHeight: 350
                )
            }
            let naturalFooterWidth = footer.map {
                idealWidth($0)
                    + ((embed.footer?.proxyIconURL ?? embed.footer?.iconURL) == nil
                        ? 0 : 23)
            } ?? 0
            let naturalContentWidth = max(
                naturalTopWidth,
                naturalMediaSize?.width ?? 0,
                naturalFooterWidth,
                92
            )
            let width = min(
                maximumWidth,
                max(120, ceil(naturalContentWidth + innerChrome))
            )
            let contentX = origin.x + stripeWidth + cardPadding
            let contentWidth = max(80, width - innerChrome)
            let textWidth = max(40, contentWidth - thumbnailAllowance)
            var textRegions: [NativeTimelineRowLayout.EmbedRegion.TextRegion] = []
            var imageRegions: [NativeTimelineRowLayout.EmbedRegion.ImageRegion] = []

            var textY = origin.y + cardPadding
            var hasTextSection = false
            func appendText(
                _ box: NativeTimelineAttributedTextBox?,
                x: CGFloat = contentX,
                width: CGFloat = textWidth,
                spacing: CGFloat = 7,
                isSelectable: Bool = false
            ) {
                guard let box else { return }
                if hasTextSection {
                    textY += spacing
                }
                let height = measuredHeight(box, width: width)
                textRegions.append(
                    .init(
                        frame: CGRect(
                            x: x,
                            y: textY,
                            width: width,
                            height: height
                        ),
                        text: box,
                        isSelectable: isSelectable
                    )
                )
                textY += height
                hasTextSection = true
            }

            if let author {
                if let iconURL = embed.author?.proxyIconURL
                    ?? embed.author?.iconURL
                {
                    if hasTextSection {
                        textY += 7
                    }
                    let lineHeight = max(20, measuredHeight(
                        author,
                        width: max(20, textWidth - 26)
                    ))
                    imageRegions.append(
                        .init(
                            frame: CGRect(
                                x: contentX,
                                y: textY + (lineHeight - 20) / 2,
                                width: 20,
                                height: 20
                            ),
                            url: iconURL,
                            cornerRadius: 10,
                            fallbackSystemImage: "person.crop.circle",
                            maximumPixelDimension: 64
                        )
                    )
                    let authorHeight = measuredHeight(
                        author,
                        width: max(20, textWidth - 26)
                    )
                    textRegions.append(
                        .init(
                            frame: CGRect(
                                x: contentX + 26,
                                y: textY + (lineHeight - authorHeight) / 2,
                                width: max(20, textWidth - 26),
                                height: authorHeight
                            ),
                            text: author,
                            isSelectable: false
                        )
                    )
                    textY += lineHeight
                    hasTextSection = true
                } else {
                    appendText(author)
                }
            }
            appendText(title)
            appendText(description, isSelectable: true)

            if !fields.isEmpty {
                if hasTextSection {
                    textY += 7
                }
                layoutFields(
                    fields,
                    x: contentX,
                    y: &textY,
                    width: textWidth,
                    into: &textRegions
                )
                hasTextSection = true
            }
            appendText(provider)

            let textHeight = hasTextSection
                ? textY - (origin.y + cardPadding)
                : 0
            let topHeight = max(textHeight, thumbnailSize)

            if let thumbnailURL {
                imageRegions.append(
                    .init(
                        frame: CGRect(
                            x: origin.x + width - cardPadding - thumbnailSize,
                            y: origin.y + cardPadding,
                            width: thumbnailSize,
                            height: thumbnailSize
                        ),
                        url: thumbnailURL,
                        cornerRadius: 6,
                        fallbackSystemImage: "photo",
                        maximumPixelDimension: 256
                    )
                )
            }

            let mediaURL = mainMedia.flatMap {
                resolvedURL($0, attachments: attachments)
            }
            let mediaSize = mainMedia.flatMap { media -> CGSize? in
                guard mediaURL != nil else { return nil }
                return self.mediaSize(
                    media,
                    maximumWidth: min(contentWidth, 500),
                    maximumHeight: 350
                )
            }
            let mediaGap: CGFloat =
                mediaSize == nil ? 0 : (topHeight > 0 ? 9 : 0)
            let mediaFrame = mediaSize.map {
                CGRect(
                    x: contentX,
                    y: origin.y + cardPadding + topHeight + mediaGap,
                    width: $0.width,
                    height: $0.height
                )
            }

            var bottomY =
                origin.y + cardPadding + topHeight + mediaGap
                + (mediaSize?.height ?? 0)
            if let footer {
                if topHeight > 0 || mediaSize != nil {
                    bottomY += 9
                }
                let footerIconURL =
                    embed.footer?.proxyIconURL ?? embed.footer?.iconURL
                let footerTextX = contentX + (footerIconURL == nil ? 0 : 23)
                let footerTextWidth = max(
                    30,
                    contentWidth - (footerIconURL == nil ? 0 : 23)
                )
                let footerTextHeight = measuredHeight(
                    footer,
                    width: footerTextWidth
                )
                let footerHeight = max(
                    footerTextHeight,
                    footerIconURL == nil ? 0 : 18
                )
                if let footerIconURL {
                    imageRegions.append(
                        .init(
                            frame: CGRect(
                                x: contentX,
                                y: bottomY + (footerHeight - 18) / 2,
                                width: 18,
                                height: 18
                            ),
                            url: footerIconURL,
                            cornerRadius: 9,
                            fallbackSystemImage: "photo.circle",
                            maximumPixelDimension: 64
                        )
                    )
                }
                textRegions.append(
                    .init(
                        frame: CGRect(
                            x: footerTextX,
                            y: bottomY + (footerHeight - footerTextHeight) / 2,
                            width: footerTextWidth,
                            height: footerTextHeight
                        ),
                        text: footer,
                        isSelectable: false
                    )
                )
                bottomY += footerHeight
            }
            let cardHeight = bottomY - origin.y + cardPadding
            let frame = CGRect(
                x: origin.x,
                y: origin.y,
                width: width,
                height: max(58, cardHeight)
            )
            return .init(
                embedID: embed.id,
                kind: .card,
                frame: frame,
                textRegions: textRegions,
                imageRegions: imageRegions,
                mediaFrame: mediaFrame,
                mediaURL: mediaURL,
                mediaIsVideo: embed.video != nil,
                mediaAutoplaysInline: false,
                accentColor: embed.color
            )
        }
    }

    private static func resolvedTextBox(
        prepared: RichMessageAttributedText.Prepared,
        scope: String,
        emojiSize: CGFloat,
        embed: MessageEmbed,
        message: Message,
        model: AppModel?
    ) -> NativeTimelineAttributedTextBox {
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
            scope: "embed:\(embed.id):\(scope)",
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

    private static func plainTextBox(
        _ value: String,
        font: NSFont,
        color: NSColor,
        link: URL? = nil
    ) -> NativeTimelineAttributedTextBox {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let output = NSMutableAttributedString(
            string: value,
            attributes: attributes
        )
        if let link {
            output.addAttribute(
                .link,
                value: link,
                range: NSRange(location: 0, length: output.length)
            )
        }
        return NativeTimelineAttributedTextBox(output)
    }

    private static func textColumnIdealWidth(
        author: NativeTimelineAttributedTextBox?,
        authorHasIcon: Bool,
        title: NativeTimelineAttributedTextBox?,
        description: NativeTimelineAttributedTextBox?,
        fields: [PreparedField],
        provider: NativeTimelineAttributedTextBox?
    ) -> CGFloat {
        var width = max(
            author.map(idealWidth) ?? 0,
            title.map(idealWidth) ?? 0,
            description.map(idealWidth) ?? 0,
            provider.map(idealWidth) ?? 0
        )
        if author != nil, authorHasIcon {
            width = max(width, (author.map(idealWidth) ?? 0) + 26)
        }
        for row in fieldRows(fields) {
            if row.count == 1, row[0].field.isInline == false {
                width = max(
                    width,
                    max(idealWidth(row[0].name), idealWidth(row[0].value))
                )
            } else {
                let fieldsWidth = row.reduce(CGFloat.zero) {
                    $0 + max(idealWidth($1.name), idealWidth($1.value))
                }
                width = max(
                    width,
                    fieldsWidth + CGFloat(max(0, row.count - 1)) * 14
                )
            }
        }
        return width
    }

    private static func layoutFields(
        _ fields: [PreparedField],
        x: CGFloat,
        y: inout CGFloat,
        width: CGFloat,
        into regions: inout [
            NativeTimelineRowLayout.EmbedRegion.TextRegion
        ]
    ) {
        let columnGap: CGFloat = 14
        let rowGap: CGFloat = 8
        let rows = fieldRows(fields)
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 {
                y += rowGap
            }
            let inlineColumnCount = max(1, min(3, row.count))
            let columnWidth = max(
                20,
                (
                    width
                        - columnGap * CGFloat(inlineColumnCount - 1)
                ) / CGFloat(inlineColumnCount)
            )
            var rowHeight: CGFloat = 0
            for (columnIndex, field) in row.enumerated() {
                let spansAllColumns =
                    row.count == 1 && field.field.isInline == false
                let fieldWidth = spansAllColumns ? width : columnWidth
                let fieldX = spansAllColumns
                    ? x
                    : x + CGFloat(columnIndex) * (columnWidth + columnGap)
                let nameHeight = measuredHeight(
                    field.name,
                    width: fieldWidth
                )
                let valueHeight = measuredHeight(
                    field.value,
                    width: fieldWidth
                )
                regions.append(
                    .init(
                        frame: CGRect(
                            x: fieldX,
                            y: y,
                            width: fieldWidth,
                            height: nameHeight
                        ),
                        text: field.name,
                        isSelectable: false
                    )
                )
                regions.append(
                    .init(
                        frame: CGRect(
                            x: fieldX,
                            y: y + nameHeight + 2,
                            width: fieldWidth,
                            height: valueHeight
                        ),
                        text: field.value,
                        isSelectable: true
                    )
                )
                rowHeight = max(rowHeight, nameHeight + 2 + valueHeight)
            }
            y += rowHeight
        }
    }

    private static func fieldRows(
        _ fields: [PreparedField]
    ) -> [[PreparedField]] {
        var rows: [[PreparedField]] = []
        var inline: [PreparedField] = []
        func flushInline() {
            while !inline.isEmpty {
                let count = min(3, inline.count)
                rows.append(Array(inline.prefix(count)))
                inline.removeFirst(count)
            }
        }
        for field in fields {
            if field.field.isInline {
                inline.append(field)
                if inline.count == 3 {
                    flushInline()
                }
            } else {
                flushInline()
                rows.append([field])
            }
        }
        flushInline()
        return rows
    }

    private static func footerText(
        footer: MessageEmbedFooter?,
        timestamp: Date?
    ) -> String? {
        var values: [String] = []
        if let footer {
            values.append(footer.text)
        }
        if let timestamp {
            values.append(
                timestamp.formatted(date: .omitted, time: .shortened)
            )
        }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " • ")
    }

    private static func idealWidth(
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

    private static func measuredHeight(
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
        // TextKit reports the used fragment height before SwiftUI rounds the
        // composed stack. Rounding every CoreText leaf upward makes a rich
        // embed progressively taller than the previous renderer, especially
        // across its title, description, field grid, and footer.
        return max(
            1,
            floor(size.height) - box.layoutHeightAdjustment
                + NativeTimelineMarkdownChromeMetrics
                    .trailingVisualOverflow(in: box.value)
        )
    }

    private static func mediaSize(
        _ media: MessageEmbedMedia,
        maximumWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> CGSize {
        let width = min(500, max(180, maximumWidth))
        if let rawWidth = media.width,
           let rawHeight = media.height,
           rawWidth > 0,
           rawHeight > 0
        {
            let source = CGSize(
                width: CGFloat(rawWidth),
                height: CGFloat(rawHeight)
            )
            let scale = min(
                1,
                width / source.width,
                maximumHeight / source.height
            )
            return CGSize(
                width: source.width * scale,
                height: source.height * scale
            )
        }
        let ratio = max(
            0.2,
            min(
                12,
                CGFloat(media.width ?? 16) / CGFloat(media.height ?? 9)
            )
        )
        let fittedWidth = min(width, maximumHeight * ratio)
        let fittedHeight = min(maximumHeight, fittedWidth / ratio)
        return CGSize(
            width: fittedWidth,
            height: max(80, fittedHeight)
        )
    }

    private static func resolvedURL(
        _ media: MessageEmbedMedia,
        attachments: [Attachment]
    ) -> URL? {
        let candidate = media.proxyURL ?? media.url
        guard let candidate else { return nil }
        guard candidate.scheme?.lowercased() == "attachment" else {
            return candidate
        }
        let filename = candidate.host ?? candidate.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return attachments.first { $0.filename == filename }
            .map { $0.proxyURL ?? $0.url }
    }

}
