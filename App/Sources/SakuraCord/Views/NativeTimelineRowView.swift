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
    static func text(
        for date: Date,
        settings: InterfaceSettingsSnapshot = .defaults,
        includesSeconds: Bool? = nil
    ) -> String {
        InterfaceTimestampFormatter.text(
            for: date,
            format: settings.timestampFormat,
            includesSeconds: includesSeconds
                ?? settings.includesTimestampSeconds
        )
    }
}

extension NSAttributedString.Key {
    nonisolated static let nativeTimelineMention = NSAttributedString.Key(
        "dev.sakuracord.native-timeline-mention"
    )
}

nonisolated final class NativeTimelineMentionBox: NSObject {
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

nonisolated enum NativeTimelineRunDelegate {
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
    var openMessage: ((Message) -> Void)?
    var openReply: (MessageID) -> Void
    var reply: ((Message) -> Void)?
    var forward: ((Message) -> Void)?
    var retry: (Message) -> Void
    var edit: (Message, String) -> Void
    var markUnread: (Message) -> Void
    var delete: (Message) -> Void
    var togglePin: (Message) -> Void
    var discardFailed: (Message) -> Void
    var react: (String, Message) -> Void
    var openThread: (MessageThreadSummary) -> Void
    var submitComponent: (
        Message,
        String,
        ComponentInteractionKind,
        [String]
    ) -> Void
    var checkForUpdates: () -> Void
    var applyTheme: (SakuraCordSharedTheme) -> Void

    init(
        loadEarlier: @escaping () -> Void,
        openMessage: ((Message) -> Void)? = nil,
        openReply: @escaping (MessageID) -> Void,
        reply: ((Message) -> Void)?,
        forward: ((Message) -> Void)? = nil,
        retry: @escaping (Message) -> Void,
        edit: @escaping (Message, String) -> Void,
        markUnread: @escaping (Message) -> Void,
        delete: @escaping (Message) -> Void,
        togglePin: @escaping (Message) -> Void = { _ in },
        react: @escaping (String, Message) -> Void,
        openThread: @escaping (MessageThreadSummary) -> Void,
        submitComponent: @escaping (
            Message,
            String,
            ComponentInteractionKind,
            [String]
        ) -> Void,
        discardFailed: @escaping (Message) -> Void = { _ in },
        checkForUpdates: @escaping () -> Void = {},
        applyTheme: @escaping (SakuraCordSharedTheme) -> Void = { _ in }
    ) {
        self.loadEarlier = loadEarlier
        self.openMessage = openMessage
        self.openReply = openReply
        self.reply = reply
        self.forward = forward
        self.retry = retry
        self.edit = edit
        self.markUnread = markUnread
        self.delete = delete
        self.togglePin = togglePin
        self.discardFailed = discardFailed
        self.react = react
        self.openThread = openThread
        self.submitComponent = submitComponent
        self.checkForUpdates = checkForUpdates
        self.applyTheme = applyTheme
    }
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

@MainActor
enum NativeTimelineReactionFonts {
    private static var cachedCount: (pointSize: CGFloat, font: NSFont)?

    static var count: NSFont {
        let pointSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        if let cachedCount, cachedCount.pointSize == pointSize {
            return cachedCount.font
        }
        let font = AppPerformanceSignposts.measureSync(
            "TimelineReactionCountFontCacheMiss"
        ) {
            NSFont.monospacedDigitSystemFont(
                ofSize: pointSize,
                weight: .semibold
            )
        }
        cachedCount = (pointSize, font)
        return font
    }

    static let overflow = AppPerformanceSignposts.measureSync(
        "TimelineReactionOverflowFontCacheMiss"
    ) {
        NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
    }
}

struct NativeTimelineRowLayout {
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

    struct SakuraCordDeepLinkRegion {
        let action: SakuraCordDeepLinkAction
        let componentID: String
        let frame: CGRect
        let cardFrame: CGRect
        let symbolBackgroundFrame: CGRect
        let symbolFrame: CGRect
        let titleFrame: CGRect
        let paletteFrames: [CGRect]
        let buttonFrame: CGRect
    }

    let height: CGFloat
    let loaderLayout: NativeTimelineLoaderLayout?
    let beginningLayout: NativeTimelineBeginningLayout?
    let searchSectionRegion: SearchSectionRegion?
    let searchCardFrame: CGRect?
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
    let replyContentFrame: CGRect?
    let commandInvocationRegion: CommandInvocationRegion?
    let systemIconFrame: CGRect?
    let contentFrame: CGRect?
    let attributedContent: NSAttributedString?
    let contentFramesetter: CTFramesetter?
    let forwardedHeaderFrame: CGRect?
    let forwardedBarFrame: CGRect?
    let forwardedSourceRegion: ForwardedSourceRegion?
    let linkedImageRegions: [LinkedImageRegion]
    let attachmentRegions: [AttachmentRegion]
    let embedFrames: [CGRect]
    let embedRegions: [EmbedRegion]
    let sakuraCordDeepLinkRegions: [SakuraCordDeepLinkRegion]
    let componentFrames: [CGRect]
    let componentLayouts: [NativeTimelineComponentLayout]
    let stickerFrames: [CGRect]
    let threadFrame: CGRect?
    let reactionRegions: [ReactionRegion]
    let addReactionFrame: CGRect?
    let ephemeralRegion: EphemeralRegion?
    let failedFrame: CGRect?
    let pinnedAtFrame: CGRect?

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
            searchSectionRegion: nil,
            searchCardFrame: nil,
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
            replyContentFrame: nil,
            commandInvocationRegion: nil,
            systemIconFrame: nil,
            contentFrame: nil,
            attributedContent: nil,
            contentFramesetter: nil,
            forwardedHeaderFrame: nil,
            forwardedBarFrame: nil,
            forwardedSourceRegion: nil,
            linkedImageRegions: [],
            attachmentRegions: [],
            embedFrames: [],
            embedRegions: [],
            sakuraCordDeepLinkRegions: [],
            componentFrames: [],
            componentLayouts: [],
            stickerFrames: [],
            threadFrame: nil,
            reactionRegions: [],
            addReactionFrame: nil,
            ephemeralRegion: nil,
            failedFrame: nil,
            pinnedAtFrame: nil
        )
    }

    private struct MessageBuilder {
        let row: MessageRowPresentation
        let isUnreadBoundary: Bool
        let width: CGFloat
        let model: AppModel?

        var layout: NativeTimelineRowLayout {
        let message = row.message
        let searchContext = row.searchContext
        let interfaceSettings = model?.interfaceSettings ?? .defaults
        let density = interfaceSettings.messageDensity
        let horizontalInset: CGFloat = searchContext == nil
            ? density.horizontalInset
            : 22
        let avatarWidth = density.avatarDiameter
        let columnGap = density.columnGap
        let ordinaryContentX = horizontalInset + avatarWidth + columnGap
        let ordinaryContentWidth = max(
            80,
            width - ordinaryContentX - horizontalInset
        )
        let isGenerated = message.type.hasGeneratedContent
        let contentX: CGFloat = isGenerated
            ? horizontalInset + avatarWidth + 20
            : ordinaryContentX
        let contentWidth = max(80, width - contentX - horizontalInset)
        var prefixHeight: CGFloat = 0

        var searchSectionRegion: SearchSectionRegion?
        if let searchContext, searchContext.showsSectionHeader {
            let sectionFrame = CGRect(
                x: 14,
                y: 8,
                width: max(1, width - 28),
                height: searchContext.sectionSubtitle == nil ? 24 : 34
            )
            let iconFrame = CGRect(
                x: sectionFrame.minX,
                y: sectionFrame.minY + 2,
                width: 20,
                height: 20
            )
            let titleFrame = CGRect(
                x: iconFrame.maxX + 7,
                y: sectionFrame.minY,
                width: max(1, sectionFrame.maxX - iconFrame.maxX - 7),
                height: 18
            )
            let subtitleFrame = searchContext.sectionSubtitle.map { _ in
                CGRect(
                    x: titleFrame.minX,
                    y: titleFrame.maxY,
                    width: titleFrame.width,
                    height: 14
                )
            }
            searchSectionRegion = SearchSectionRegion(
                frame: sectionFrame,
                iconFrame: iconFrame,
                titleFrame: titleFrame,
                subtitleFrame: subtitleFrame
            )
            prefixHeight = sectionFrame.maxY + 4
        }

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
            hasReplyPreview: row.replyMessageID != nil,
            isEditing: false,
            density: density
        )
        let externalTopSeparation = MessageRowLayoutMetrics.separation(
            startsGroup: row.startsGroup,
            followsTimelineSeparator: row.startsDay || isUnreadBoundary,
            highlightTopInset: highlightInsets.top,
            density: density
        )
        let highlightMinY = prefixHeight
            + (searchContext == nil ? externalTopSeparation : 4)
        var verticalOffset = highlightMinY + highlightInsets.top

        var replyFrame: CGRect?
        var replyContentFrame: CGRect?
        if row.replyMessageID != nil {
            let frame = CGRect(
                x: horizontalInset,
                y: verticalOffset,
                width: width - horizontalInset * 2,
                height: 20
            )
            replyFrame = frame
            replyContentFrame = CGRect(
                x: contentX,
                y: frame.minY,
                width: max(0, frame.maxX - contentX),
                height: frame.height
            )
            verticalOffset += 20
        }

        var commandInvocationRegion: CommandInvocationRegion?
        if message.type == .chatInputCommand {
            commandInvocationRegion = NativeTimelineRowLayout.commandInvocation(
                message,
                origin: CGPoint(x: horizontalInset, y: verticalOffset),
                maximumWidth: width - horizontalInset * 2
            )
            verticalOffset += MessageRowLayoutMetrics.commandInvocationHeight
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
                NativeTimelineRowLayout.measuredTextWidth(author.displayName, font: authorFont)
            )
            avatarFrame = CGRect(
                x: horizontalInset,
                y: verticalOffset,
                width: avatarWidth,
                height: avatarWidth
            )
            authorFrame = CGRect(
                x: contentX,
                y: verticalOffset,
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
                let badgeWidth = NativeTimelineRowLayout.measuredTextWidth(
                    "APP",
                    font: badgeFont
                ) + 8
                botBadgeFrame = CGRect(
                    x: headerX,
                    // Discord gives the application badge enough vertical
                    // weight to read as a badge, while keeping it centered
                    // inside the fixed author line.
                    y: verticalOffset + 1,
                    width: badgeWidth,
                    height: 14
                )
                headerX += badgeWidth
            }
            headerX += 7
            let timestampFont = NSFont.preferredFont(forTextStyle: .caption1)
            let timestamp = NativeTimelineTimestamp.text(
                for: message.timestamp,
                settings: model?.interfaceSettings ?? .defaults
            )
            let timestampWidth = NativeTimelineRowLayout.measuredTextWidth(
                timestamp,
                font: timestampFont
            )
            timestampFrame = CGRect(
                x: headerX,
                y: verticalOffset + 3,
                width: min(timestampWidth, max(0, contentX + contentWidth - headerX)),
                height: 13
            )
            headerX = timestampFrame?.maxX ?? headerX
            if message.editedTimestamp != nil,
               model?.chatSettings.showsEditedMarkers != false
            {
                headerX += 7
                let editedFont = NSFont.preferredFont(forTextStyle: .caption2)
                editedFrame = CGRect(
                    x: headerX,
                    y: verticalOffset + 4,
                    width: min(
                        NativeTimelineRowLayout.measuredTextWidth("(edited)", font: editedFont),
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
                    y: verticalOffset + 2,
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
            verticalOffset += MessageRowLayoutMetrics.authorLineHeight
                + MessageRowLayoutMetrics.authorToContentSpacing(
                    isCommandResponse: message.type == .chatInputCommand,
                    density: density
                )
        } else if !isGenerated {
            compactTimestampFrame = CGRect(
                x: horizontalInset,
                y: verticalOffset,
                width: avatarWidth,
                height: density.compactContentHeight
            )
        }

        var systemIconFrame: CGRect?
        if isGenerated {
            systemIconFrame = CGRect(
                x: horizontalInset + 36,
                y: verticalOffset,
                width: 16,
                height: density.compactContentHeight
            )
        }

        var forwardedHeaderFrame: CGRect?
        let forwardedBarStartY: CGFloat?
        if message.forwardedSnapshot != nil {
            forwardedHeaderFrame = CGRect(
                x: contentX,
                y: verticalOffset,
                width: contentWidth,
                height: 18
            )
            forwardedBarStartY = verticalOffset
            verticalOffset += 22
        } else {
            forwardedBarStartY = nil
        }

        var contentFrame: CGRect?
        var hasRichContent = false
        let usesComponentsV2 = message.flags.contains(.isComponentsV2)
        let chatSettings = model?.chatSettings ?? .defaults
        let inlineMediaMaximumWidth = min(
            contentWidth,
            chatSettings.inlineMediaSize.maximumWidth
        )
        let systemActorColor = model?.authorPresentation(for: message).roleColorHex
            .flatMap { value -> NSColor? in
                guard value != 0 else { return nil }
                return NSColor(
                    red: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1
                )
            }
        let textPlan =
            if message.type.hasGeneratedContent {
                NativeTimelineTextPlan.make(
                    for: message,
                    currentUserID: model?.snapshot?.currentUser.id,
                    systemActorColor: systemActorColor
                )
            } else if !chatSettings.showsAutomaticLinkPreviews
                || !chatSettings.expandsEmbedsByDefault
            {
                NativeTimelineTextPlan.make(
                    for: message,
                    showsAutomaticLinkPreviews: false
                )
            } else {
                row.textPlan
            }
        let contentPresentation =
            usesComponentsV2
                ? NativeTimelineTextPresentation.empty
                : NativeTimelineTextPresentation.make(
                    message: message,
                    plan: textPlan,
                    model: model
                )
        if let attributedContent = contentPresentation.attributedContent {
            let textHeight = NativeTimelineRowLayout.measuredTextHeight(
                contentPresentation.framesetter,
                value: attributedContent,
                length: attributedContent.length,
                width: contentWidth
            )
            contentFrame = CGRect(x: contentX, y: verticalOffset, width: contentWidth, height: textHeight)
            verticalOffset += textHeight
            hasRichContent = true
        }

        var linkedImageRegions: [LinkedImageRegion] = []
        if !contentPresentation.linkedImages.isEmpty {
            if hasRichContent {
                verticalOffset += 6
            }
            let plan = InlineWrappingLayoutPlan.frames(
                sizes: contentPresentation.linkedImages.map { $0.displaySize },
                maximumWidth: inlineMediaMaximumWidth,
                horizontalSpacing: 4,
                verticalSpacing: 4
            )
            linkedImageRegions = zip(
                contentPresentation.linkedImages,
                plan.frames
            ).map { reference, frame in
                LinkedImageRegion(
                    frame: frame.offsetBy(dx: contentX, dy: verticalOffset),
                    reference: reference
                )
            }
            verticalOffset += plan.size.height
            hasRichContent = true
        }

        var attachmentRegions: [AttachmentRegion] = []
        if !usesComponentsV2, !message.attachments.isEmpty {
            if hasRichContent {
                verticalOffset += 8
            }
            let galleryWidth = min(500, max(180, inlineMediaMaximumWidth))
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
                    frame: frame.offsetBy(dx: contentX, dy: verticalOffset),
                    attachment: attachment
                )
            }
            verticalOffset += galleryFrames.map(\.maxY).max() ?? 0
            hasRichContent = true
        }

        var embedRegions: [EmbedRegion] = []
        var sakuraCordDeepLinkRegions: [SakuraCordDeepLinkRegion] = []
        if !usesComponentsV2, chatSettings.expandsEmbedsByDefault,
           chatSettings.showsAutomaticLinkPreviews {
            for (index, deepLink) in row.sakuraCordDeepLinks.enumerated() {
                let deepLinkY = verticalOffset + (hasRichContent ? 8 : 0)
                let region = NativeTimelineSakuraCordDeepLinkLayout.make(
                    deepLink,
                    componentIndex: index,
                    origin: CGPoint(x: contentX, y: deepLinkY),
                    maximumWidth: inlineMediaMaximumWidth
                )
                sakuraCordDeepLinkRegions.append(region)
                verticalOffset = region.frame.maxY
                hasRichContent = true
            }
        }
        if !usesComponentsV2, chatSettings.expandsEmbedsByDefault {
            let visibleEmbeds =
                MessageEmbedPresentation.visibleEmbeds(
                    for: message,
                    showsAutomaticLinkPreviews:
                        chatSettings.showsAutomaticLinkPreviews
                )
            embedRegions.reserveCapacity(visibleEmbeds.count)
            for embed in visibleEmbeds {
                let embedY = verticalOffset + (hasRichContent ? 8 : 0)
                guard let region = NativeTimelineEmbedLayout.make(
                    embed: embed,
                    message: message,
                    model: model,
                    attachments: message.attachments,
                    origin: CGPoint(x: contentX, y: embedY),
                    maximumWidth: inlineMediaMaximumWidth
                ) else { continue }
                embedRegions.append(region)
                verticalOffset = region.frame.maxY
                hasRichContent = true
            }
        }
        let embedFrames = embedRegions.map(\.frame)

        var componentLayouts: [NativeTimelineComponentLayout] = []
        let componentY = verticalOffset + (hasRichContent ? 8 : 0)
        if let componentLayout = NativeTimelineComponentLayout.make(
            message: message,
            model: model,
            origin: CGPoint(x: contentX, y: componentY),
            maximumWidth: inlineMediaMaximumWidth
        ) {
            componentLayouts.append(componentLayout)
            verticalOffset = componentLayout.frame.maxY
            hasRichContent = true
        }
        let componentFrames = componentLayouts.map(\.frame)

        var stickerFrames: [CGRect] = []
        if !message.stickers.isEmpty {
            if hasRichContent {
                verticalOffset += 8
            }
            let size = min(contentWidth, 112)
            var stickerX = contentX
            var rowHeight: CGFloat = 0
            for _ in message.stickers {
                if stickerX + size > contentX + contentWidth,
                   stickerX > contentX
                {
                    stickerX = contentX
                    verticalOffset += rowHeight + 8
                    rowHeight = 0
                }
                stickerFrames.append(
                    CGRect(x: stickerX, y: verticalOffset, width: size, height: size)
                )
                stickerX += size + 8
                rowHeight = max(rowHeight, size)
            }
            verticalOffset += rowHeight
            hasRichContent = true
        }

        var forwardedSourceRegion: ForwardedSourceRegion?
        var forwardedBarFrame: CGRect?
        if let snapshot = message.forwardedSnapshot,
           let reference = message.messageReference,
           let sourceChannelID = reference.channelID,
           let sourceChannel = model?.snapshot?.channels.first(where: {
               $0.id == sourceChannelID
           })
        {
            if hasRichContent { verticalOffset += 7 }
            let sourceGuild = reference.guildID.flatMap { sourceGuildID in
                model?.snapshot?.guilds.first(where: { $0.id == sourceGuildID })
            }
            let sameGuild = message.guildID == reference.guildID
            let sourceLabel = sameGuild
                ? "#\(sourceChannel.name)"
                : (sourceGuild?.name ?? sourceChannel.name)
            let dateText = snapshot.timestamp.formatted(
                date: .abbreviated,
                time: .shortened
            )
            let sourceText = "\(sourceLabel)  •  \(dateText)  ›"
            let sourceFont = NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: .medium
            )
            let iconWidth: CGFloat = sameGuild ? 0 : 24
            let sourceWidth = min(
                contentWidth,
                ceil((sourceText as NSString).size(withAttributes: [
                    .font: sourceFont
                ]).width) + iconWidth + 12
            )
            forwardedSourceRegion = ForwardedSourceRegion(
                frame: CGRect(
                    x: contentX,
                    y: verticalOffset,
                    width: sourceWidth,
                    height: 22
                ),
                label: sourceLabel,
                iconURL: sameGuild ? nil : sourceGuild?.iconURL,
                channelID: sourceChannelID,
                guildID: reference.guildID,
                messageID: reference.messageID,
                timestamp: snapshot.timestamp
            )
            verticalOffset += 22
            hasRichContent = true
        }
        if let forwardedBarStartY {
            forwardedBarFrame = CGRect(
                x: contentX - 11,
                y: forwardedBarStartY,
                width: 3,
                height: max(18, verticalOffset - forwardedBarStartY)
            )
        }

        var threadFrame: CGRect?
        if message.thread != nil {
            if hasRichContent {
                verticalOffset += 8
            }
            threadFrame = CGRect(
                x: contentX,
                y: verticalOffset,
                width: min(contentWidth, 500),
                height: 48
            )
            verticalOffset += 48
            hasRichContent = true
        }

        var reactionRegions: [ReactionRegion] = []
        var addReactionFrame: CGRect?
        let presentedReactions = MessageReactionPresentation.items(
            from: message.reactions
        )
        if !presentedReactions.isEmpty {
            if hasRichContent {
                verticalOffset += 4
            }
            let sizes = presentedReactions.map(reactionSize)
                + [CGSize(
                    width: ReactionActionMenuPresentation.inline.width(
                        enlarged: false
                    ),
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
                NativeTimelineRowLayout.reactionRegion(
                    reaction,
                    frame: frame.offsetBy(dx: contentX, dy: verticalOffset)
                )
            }
            if let frame = wrapping.frames.last {
                addReactionFrame = frame.offsetBy(dx: contentX, dy: verticalOffset)
            }
            verticalOffset += wrapping.size.height
        }

        var ephemeralRegion: EphemeralRegion?
        if message.flags.contains(.ephemeral) {
            if hasRichContent || !presentedReactions.isEmpty {
                verticalOffset += 4
            }
            ephemeralRegion = NativeTimelineRowLayout.ephemeral(
                origin: CGPoint(x: contentX, y: verticalOffset),
                maximumWidth: contentWidth
            )
            verticalOffset += 15
        }

        var failedFrame: CGRect?
        if message.outboxState == .failed {
            if hasRichContent
                || !presentedReactions.isEmpty
                || ephemeralRegion != nil
            {
                verticalOffset += 4
            }
            failedFrame = CGRect(
                x: contentX,
                y: verticalOffset,
                width: contentWidth,
                height: 14
            )
            verticalOffset += 14
        }

        var pinnedAtFrame: CGRect?
        if row.pinnedAt != nil {
            if hasRichContent || !presentedReactions.isEmpty || ephemeralRegion != nil {
                verticalOffset += 6
            }
            pinnedAtFrame = CGRect(
                x: contentX,
                y: verticalOffset,
                width: contentWidth,
                height: 16
            )
            verticalOffset += 16
        }

        let visibleContentMaxY = max(
            verticalOffset,
            avatarFrame?.maxY ?? 0,
            authorFrame?.maxY ?? 0
        )
        let searchBottomInset: CGFloat = searchContext == nil ? 0 : 8
        let rowHeight = ceil(
            max(
                visibleContentMaxY + highlightInsets.bottom,
                highlightMinY
                    + highlightInsets.top
                    + (row.startsGroup && !isGenerated
                        ? density.avatarDiameter
                        : density.compactContentHeight)
                    + highlightInsets.bottom
            ) + searchBottomInset
        )
        let searchCardFrame = searchContext.map { _ in
            CGRect(
                x: 0,
                y: highlightMinY,
                width: width,
                height: max(0, rowHeight - highlightMinY - searchBottomInset)
            )
        }
        let highlightFrame = CGRect(
            x: searchCardFrame?.minX ?? 0,
            y: highlightMinY,
            width: searchCardFrame?.width ?? width,
            height: searchCardFrame?.height ?? max(0, rowHeight - highlightMinY)
        )

        return NativeTimelineRowLayout(
            height: rowHeight,
            loaderLayout: nil,
            beginningLayout: nil,
            searchSectionRegion: searchSectionRegion,
            searchCardFrame: searchCardFrame,
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
            replyContentFrame: replyContentFrame,
            commandInvocationRegion: commandInvocationRegion,
            systemIconFrame: systemIconFrame,
            contentFrame: contentFrame,
            attributedContent: contentPresentation.attributedContent,
            contentFramesetter: contentPresentation.framesetter,
            forwardedHeaderFrame: forwardedHeaderFrame,
            forwardedBarFrame: forwardedBarFrame,
            forwardedSourceRegion: forwardedSourceRegion,
            linkedImageRegions: linkedImageRegions,
            attachmentRegions: attachmentRegions,
            embedFrames: embedFrames,
            embedRegions: embedRegions,
            sakuraCordDeepLinkRegions: sakuraCordDeepLinkRegions,
            componentFrames: componentFrames,
            componentLayouts: componentLayouts,
            stickerFrames: stickerFrames,
            threadFrame: threadFrame,
            reactionRegions: reactionRegions,
            addReactionFrame: addReactionFrame,
            ephemeralRegion: ephemeralRegion,
            failedFrame: failedFrame,
            pinnedAtFrame: pinnedAtFrame
        )
        }
    }

    private static func message(
        _ row: MessageRowPresentation,
        isUnreadBoundary: Bool,
        width: CGFloat,
        model: AppModel?
    ) -> Self {
        MessageBuilder(
            row: row,
            isUnreadBoundary: isUnreadBoundary,
            width: width,
            model: model
        ).layout
    }

    private struct CommandInvocationBuilder {
        let message: Message
        let origin: CGPoint
        let maximumWidth: CGFloat

        var region: CommandInvocationRegion {
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
        var horizontalOffset = connectorFrame.maxX + 5
        let avatarFrame = user.map { _ in
            CGRect(
                x: horizontalOffset,
                y: origin.y
                    + MessageRowLayoutMetrics.commandInvocationContentInset,
                width: 14,
                height: 14
            )
        }
        let fallbackAvatarFrame = user == nil
            ? CGRect(
                x: horizontalOffset,
                y: origin.y
                    + MessageRowLayoutMetrics.commandInvocationContentInset,
                width: 14,
                height: 14
            )
            : nil
        horizontalOffset += 14 + 5
        let availableMaxX = frame.maxX - 48
        let userWidth = min(
            NativeTimelineRowLayout.measuredTextWidth(userLabel, font: userFont),
            max(0, availableMaxX - horizontalOffset)
        )
        let userFrame = CGRect(
            x: horizontalOffset,
            y: origin.y + 3,
            width: userWidth,
            height: 14
        )
        horizontalOffset = userFrame.maxX + 5
        let usedWidth = min(
            NativeTimelineRowLayout.measuredTextWidth("used", font: captionFont),
            max(0, availableMaxX - horizontalOffset)
        )
        let usedFrame = CGRect(
            x: horizontalOffset,
            y: origin.y + 2,
            width: usedWidth,
            height: 16
        )
        horizontalOffset = usedFrame.maxX + 5
        let symbolWidth: CGFloat = 10
        let naturalCommandWidth = NativeTimelineRowLayout.measuredTextWidth(
            commandLabel,
            font: commandFont
        )
        let pillWidth = min(
            6 + symbolWidth + 3 + naturalCommandWidth + 6,
            max(0, availableMaxX - horizontalOffset)
        )
        let pillFrame = CGRect(
            x: horizontalOffset,
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
    }

    private static func commandInvocation(
        _ message: Message,
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> CommandInvocationRegion {
        CommandInvocationBuilder(
            message: message,
            origin: origin,
            maximumWidth: maximumWidth
        ).region
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
        var horizontalOffset = origin.x
        let eyeFrame = CGRect(x: horizontalOffset, y: origin.y + 1, width: 13, height: 13)
        horizontalOffset = eyeFrame.maxX + 4
        let visibilityWidth = min(
            measuredTextWidth("Only you can see this", font: font),
            max(0, frame.maxX - horizontalOffset)
        )
        let visibilityFrame = CGRect(
            x: horizontalOffset,
            y: origin.y,
            width: visibilityWidth,
            height: 15
        )
        horizontalOffset = visibilityFrame.maxX + 4
        let bulletWidth = min(
            measuredTextWidth("•", font: font),
            max(0, frame.maxX - horizontalOffset)
        )
        let bulletFrame = CGRect(
            x: horizontalOffset,
            y: origin.y,
            width: bulletWidth,
            height: 15
        )
        horizontalOffset = bulletFrame.maxX + 4
        let dismissFrame = CGRect(
            x: horizontalOffset,
            y: origin.y,
            width: min(
                measuredTextWidth("Dismiss message", font: font),
                max(0, frame.maxX - horizontalOffset)
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
                font: NativeTimelineReactionFonts.count
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
                font: NativeTimelineReactionFonts.overflow
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
        var horizontalOffset = frame.minX + 6
        let emojiFrame = CGRect(
            x: horizontalOffset,
            y: frame.midY - MessageReactionMetrics.emojiSize / 2,
            width: MessageReactionMetrics.emojiSize,
            height: MessageReactionMetrics.emojiSize
        )
        horizontalOffset = emojiFrame.maxX

        var countFrame: CGRect?
        if reaction.count > 0 {
            horizontalOffset += 4
            let countWidth = measuredTextWidth(
                String(reaction.count),
                font: NativeTimelineReactionFonts.count
            )
            countFrame = CGRect(
                x: horizontalOffset,
                y: frame.minY,
                width: countWidth,
                height: frame.height
            )
            horizontalOffset += countWidth
        }

        let plan = MessageReactionPresentation.previewPlan(for: reaction)
        var avatars: [ReactionRegion.AvatarRegion] = []
        var overflowFrame: CGRect?
        if !plan.isEmpty {
            horizontalOffset += 4
            for (index, reactor) in plan.reactors.enumerated() {
                let avatarFrame = CGRect(
                    x: horizontalOffset + CGFloat(index) * 11,
                    y: frame.midY - MessageReactionMetrics.avatarSize / 2,
                    width: MessageReactionMetrics.avatarSize,
                    height: MessageReactionMetrics.avatarSize
                )
                avatars.append(.init(frame: avatarFrame, reactor: reactor))
            }
            if !plan.reactors.isEmpty {
                horizontalOffset += MessageReactionMetrics.avatarSize
                    + CGFloat(plan.reactors.count - 1) * 11
            }
            if plan.overflowCount > 0 {
                if !plan.reactors.isEmpty {
                    horizontalOffset += 2
                }
                overflowFrame = CGRect(
                    x: horizontalOffset,
                    y: frame.minY,
                    width: max(
                        MessageReactionMetrics.avatarSize,
                        frame.maxX - 6 - horizontalOffset
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

extension NativeTimelineRowLayout {
    struct SearchSectionRegion {
        let frame: CGRect
        let iconFrame: CGRect
        let titleFrame: CGRect
        let subtitleFrame: CGRect?
    }

    struct ForwardedSourceRegion {
        let frame: CGRect
        let label: String
        let iconURL: URL?
        let channelID: ChannelID
        let guildID: GuildID?
        let messageID: MessageID?
        let timestamp: Date
    }

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
}
