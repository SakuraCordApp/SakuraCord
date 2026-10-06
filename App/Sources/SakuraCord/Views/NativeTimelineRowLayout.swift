import AppKit
import CoreText
import MessageRendering
import SakuraCordModels

/// Geometry shared by rendering, hit testing, selection and accessibility.
struct NativeTimelineRowLayout {
    var fontRevision = ProfileNameFontCache.revision

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
        /// The still image drawn in the region: the image itself, or a
        /// video's poster frame.
        let previewKey: NativeTimelineMediaKey?
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
            case bubbleIntegratedCard
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
        let drawsTopSeparator: Bool
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

    /// An animated progress mark hosted as a layer-backed canvas overlay, so
    /// its animation never repaints the row.
    struct ActivityIndicator: Equatable {
        enum Style: Equatable {
            case spinner
            case dots(InteractionLoadingDots.Tone)
        }

        let frame: CGRect
        let style: Style
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

    var height: CGFloat = 0
    var loaderLayout: NativeTimelineLoaderLayout?
    var beginningLayout: NativeTimelineBeginningLayout?
    var searchSectionRegion: SearchSectionRegion?
    var searchCardFrame: CGRect?
    var bubbleRegion: NativeTimelineBubbleRegion?
    var highlightFrame: CGRect?
    var daySeparatorFrame: CGRect?
    var unreadSeparatorFrame: CGRect?
    var avatarFrame: CGRect?
    var compactTimestampFrame: CGRect?
    var authorFrame: CGRect?
    var botBadgeFrame: CGRect?
    var timestampFrame: CGRect?
    var editedFrame: CGRect?
    var activityIndicators: [ActivityIndicator] = []
    var replyFrame: CGRect?
    var replyContentFrame: CGRect?
    var commandInvocationRegion: CommandInvocationRegion?
    var systemIconFrame: CGRect?
    var contentFrame: CGRect?
    var attributedContent: NSAttributedString?
    var contentFramesetter: CTFramesetter?
    var forwardedHeaderFrame: CGRect?
    var forwardedBarFrame: CGRect?
    var forwardedSourceRegion: ForwardedSourceRegion?
    var linkedImageRegions: [LinkedImageRegion] = []
    var attachmentRegions: [AttachmentRegion] = []
    var embedFrames: [CGRect] = []
    var embedRegions: [EmbedRegion] = []
    var sakuraCordDeepLinkRegions: [SakuraCordDeepLinkRegion] = []
    var componentFrames: [CGRect] = []
    var componentLayouts: [NativeTimelineComponentLayout] = []
    var stickerFrames: [CGRect] = []
    var threadFrame: CGRect?
    var reactionRegions: [ReactionRegion] = []
    var addReactionFrame: CGRect?
    var ephemeralRegion: EphemeralRegion?
    var failedFrame: CGRect?
    var pinnedAtFrame: CGRect?
    var pollLayout: NativeTimelinePollLayout?
    var pollResultFrame: CGRect?
    var inviteRegions: [NativeTimelineInviteLayout] = []

    static func make(
        item: NativeMessageTimelineItem,
        width proposedWidth: CGFloat,
        model: AppModel? = nil,
        metrics: Metrics? = nil,
        relativeTo date: Date = .now
    ) -> Self {
        let width = max(220, proposedWidth)
        switch item {
        case .inboxGroup:
            return Self(height: 58)
        case .inboxEvent:
            return Self(height: 104)
        case .inboxForumPost:
            return Self(height: 88)
        case let .loader(isLoading, kind):
            let loaderLayout = NativeTimelineLoaderLayout.make(
                isLoading: isLoading,
                kind: kind,
                width: width
            )
            return Self(
                height: loaderLayout.height,
                loaderLayout: loaderLayout,
                activityIndicators: loaderLayout.spinnerFrame.map { [.init(frame: $0, style: .spinner)] } ?? []
            )
        case let .beginning(beginning):
            let beginningLayout = NativeTimelineBeginningLayout.make(
                beginning: beginning,
                width: width
            )
            return Self(
                height: beginningLayout.height,
                beginningLayout: beginningLayout
            )
        case let .message(row, isUnreadBoundary, _):
            var builder = MessageBuilder(
                row: row,
                isUnreadBoundary: isUnreadBoundary,
                width: width,
                model: model,
                metrics: metrics ?? Metrics(settings: model?.interfaceSettings ?? .defaults),
                relativeTo: date
            )
            return builder.make()
        }
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

struct NativeTimelineSearchPrefixLayout {
    let region: NativeTimelineRowLayout.SearchSectionRegion?
    let height: CGFloat

    static func make(
        context: MessageSearchRowContext?,
        width: CGFloat
    ) -> Self {
        guard let context, context.showsSectionHeader else {
            return Self(region: nil, height: 0)
        }
        let sectionFrame = CGRect(
            x: 14,
            y: 8,
            width: max(1, width - 28),
            height: context.sectionSubtitle == nil ? 24 : 34
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
        let subtitleFrame = context.sectionSubtitle.map { _ in
            CGRect(
                x: titleFrame.minX,
                y: titleFrame.maxY,
                width: titleFrame.width,
                height: 14
            )
        }
        return Self(
            region: NativeTimelineRowLayout.SearchSectionRegion(
                frame: sectionFrame,
                iconFrame: iconFrame,
                titleFrame: titleFrame,
                subtitleFrame: subtitleFrame
            ),
            height: sectionFrame.maxY + 4
        )
    }
}
