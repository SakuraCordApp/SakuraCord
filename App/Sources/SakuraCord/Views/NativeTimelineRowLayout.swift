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

        var placeholder: NativeTimelineMediaPlaceholder? { .init(attachment) }
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
        let placeholderAvatarFrames: [CGRect]
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
            let placeholder: NativeTimelineMediaPlaceholder?
        }

        let embedID: String
        let kind: Kind
        let frame: CGRect
        let textRegions: [TextRegion]
        let imageRegions: [ImageRegion]
        let mediaFrame: CGRect?
        let mediaURL: URL?
        let mediaPreviewURL: URL?
        let mediaPlaceholder: NativeTimelineMediaPlaceholder?
        let mediaIsVideo: Bool
        let mediaAutoplaysInline: Bool
        let mediaPosterFillsFrame: Bool
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
    /// The day of a date divider that also carries NEW: Discord folds the two
    /// into one divider when they fall on the same row.
    var foldedUnreadDay: Date?
    /// The rule closing a forum post's original message off from its replies.
    var postStarterDividerFrame: CGRect?
    var unreadSeparatorFrame: CGRect?
    /// Where NEW is drawn, on its own or folded into the date divider.
    var unreadDividerFrame: CGRect? {
        unreadSeparatorFrame ?? (foldedUnreadDay == nil ? nil : daySeparatorFrame)
    }
    var avatarFrame: CGRect?
    var compactTimestampFrame: CGRect?
    var authorFrame: CGRect?
    var authorText: NativeIdentityTextPresentation?
    var authorPrimaryGuild: PrimaryGuildIdentity?
    struct ServerTagRegion {
        let frame: CGRect
        let presentation: NativeServerTagPresentation
    }
    var serverTagRegion: ServerTagRegion?
    var timestampText: NativeIdentityTextPresentation?
    var editedText: NativeIdentityTextPresentation?
    var botBadgeFrame: CGRect?
    var botBadgeText: NativeIdentityTextPresentation?
    var timestampFrame: CGRect?
    var editedFrame: CGRect?
    var activityIndicators: [ActivityIndicator] = []
    var replyFrame: CGRect?
    var replyContentFrame: CGRect?
    /// A bubble's reply or command elbow: a stem rising from the bubble's top
    /// edge that turns toward the referenced content at `cornerY`.
    struct ReferenceConnector {
        let stemX: CGFloat
        let fromY: CGFloat
        let cornerY: CGFloat
        let toX: CGFloat
    }
    var bubbleReferenceConnector: ReferenceConnector?
    var commandInvocationRegion: CommandInvocationRegion?
    var systemIconFrame: CGRect?
    var suppressedHeader: NativeTimelineSuppressedHeaderLayout?
    var contentFrame: CGRect?
    var attributedContent: NSAttributedString?
    var contentFramesetter: CTFramesetter?
    var forwardedHeaderFrame: CGRect?
    var forwardedBarFrame: CGRect?
    var forwardedSourceRegion: ForwardedSourceRegion?
    var linkedImageRegions: [LinkedImageRegion] = []
    /// One region per attachment, in message order: a gallery tile or a file card.
    var attachmentRegions: [AttachmentRegion] = []
    var uploadRings: [UploadRing] = []

    var audioFilePlayers: [NativeTimelineVoiceMessageRegion] = []

    /// File and audio cards.
    var fileCards: [NativeTimelineFileCard] { attachmentRegions.compactMap(fileCard) }

    /// A file or audio region's card; a gallery tile has none.
    func fileCard(_ region: AttachmentRegion) -> NativeTimelineFileCard? {
        let attachment = region.attachment
        guard !attachment.mediaKind.isVisual else { return nil }
        return NativeTimelineFileCard(
            frame: region.frame, attachment: attachment, isInBubble: bubbleRegion != nil,
            isAudio: attachment.mediaKind == .audio
        )
    }

    /// A region's outline, which its spoiler cover takes: its file card's,
    /// or a gallery tile's.
    func cornerRadius(of region: AttachmentRegion) -> CGFloat {
        fileCard(region)?.cornerRadius ?? NativeTimelineRowPainter.attachmentCornerRadius
    }

    var mediaGalleryItemCount: Int {
        attachmentRegions.count { $0.attachment.mediaKind.isVisual }
    }
    var voiceMessageRegion: NativeTimelineVoiceMessageRegion?
    /// Every voice message and audio file player in the row.
    var audioPlayers: [NativeTimelineVoiceMessageRegion] {
        (voiceMessageRegion.map { [$0] } ?? []) + audioFilePlayers
    }
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
    var failedRetryFrame: CGRect?
    /// A local send's failed-send Retry. Its files' upload rings act on
    /// their own.
    var deliveryActions: [(frame: CGRect, kind: NativeTimelineFooterActionTarget.Kind)] {
        [failedRetryFrame.map { ($0, .retrySend) }].compactMap(\.self)
    }

    func deliveryAction(at point: CGPoint) -> NativeTimelineFooterActionTarget.Kind? {
        deliveryActions.first { $0.frame.contains(point) }?.kind
    }
    var pinnedAtFrame: CGRect?
    var pollLayout: NativeTimelinePollLayout?
    var pollResultFrame: CGRect?
    var inviteRegions: [NativeTimelineInviteLayout] = []
    var translationRegion: TranslationRegion?

    static func make(
        item: NativeMessageTimelineItem,
        width proposedWidth: CGFloat,
        source: AppModel? = nil,
        metrics: Metrics? = nil
    ) -> Self {
        let width = max(InterfaceScale.metric(220), proposedWidth)
        switch item {
        case let .suppressedMessages(group):
            var result = Self(height: NativeTimelineSuppressedHeaderLayout.contentHeight)
            var offset: CGFloat = 0
            if group.day != nil {
                result.daySeparatorFrame = CGRect(x: InterfaceScale.metric(12), y: offset,
                                                  width: width - InterfaceScale.metric(24), height: NativeTimelineDateSeparatorMetrics.rowHeight)
                offset += NativeTimelineDateSeparatorMetrics.rowHeight
                if group.isUnreadBoundary { result.foldedUnreadDay = group.day }
            } else if group.isUnreadBoundary {
                result.unreadSeparatorFrame = CGRect(x: InterfaceScale.metric(12), y: offset,
                                                     width: width - InterfaceScale.metric(24), height: NativeTimelineUnreadSeparatorMetrics.rowHeight)
                offset += NativeTimelineUnreadSeparatorMetrics.rowHeight
            }
            result.height += offset
            result.suppressedHeader = .make(group: group, width: width, originY: offset)
            return result
        case .inboxGroup:
            return Self(height: InboxRowMetrics.headerHeight)
        case .inboxEvent:
            return Self(height: InboxRowMetrics.scheduledEventHeight)
        case .inboxForumPost:
            return Self(height: InboxRowMetrics.forumPostHeight)
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
                source: source,
                metrics: metrics ?? Metrics(source: source)
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
        let horizontalInset: CGFloat = InterfaceScale.metric(16)
        let contentWidth = max(
            1,
            width - horizontalInset * 2
        )
        let iconFrame = CGRect(x: horizontalInset, y: InterfaceScale.metric(28), width: InterfaceScale.metric(68), height: InterfaceScale.metric(68))
        let titleFont = NSFont.interfaceSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize,
            weight: .bold
        )
        let descriptionFont = NSFont.interfacePreferredFont(forTextStyle: .body)
        let titleHeight = legacyLargeTitleHeight(
            beginning.title,
            font: titleFont,
            width: contentWidth
        )
        let titleFrame = CGRect(
            x: horizontalInset,
            y: iconFrame.maxY + InterfaceScale.metric(9),
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
            y: titleFrame.maxY + InterfaceScale.metric(9),
            width: contentWidth,
            height: descriptionHeight
        )
        let contentHeight = descriptionFrame.maxY + 18
        let dateSeparatorFrame = beginning.startedAt.map { _ in
            CGRect(x: 0, y: contentHeight, width: width, height: InterfaceScale.metric(37))
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
        let font = NSFont.interfacePreferredFont(forTextStyle: .caption1)
        let label = kind.loadingLabel
        let measured = (label as NSString).size(
            withAttributes: [.font: font]
        )
        let labelSize = CGSize(
            width: ceil(measured.width),
            height: ceil(measured.height)
        )
        let spinnerSize: CGFloat = InterfaceScale.metric(16)
        let spacing: CGFloat = InterfaceScale.metric(8)
        let controlSize = CGSize(
            width: spinnerSize + spacing + labelSize.width,
            height: max(spinnerSize, labelSize.height)
        )
        let controlFrame = CGRect(
            x: (width - controlSize.width) / 2,
            y: InterfaceScale.metric(10),
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
            x: InterfaceScale.metric(14),
            y: InterfaceScale.metric(8),
            width: max(1, width - InterfaceScale.metric(28)),
            height: context.sectionSubtitle == nil ? InterfaceScale.metric(24) : InterfaceScale.metric(34)
        )
        let iconFrame = CGRect(
            x: sectionFrame.minX,
            y: sectionFrame.minY + InterfaceScale.metric(2),
            width: InterfaceScale.metric(20),
            height: InterfaceScale.metric(20)
        )
        let titleFrame = CGRect(
            x: iconFrame.maxX + InterfaceScale.metric(7),
            y: sectionFrame.minY,
            width: max(1, sectionFrame.maxX - iconFrame.maxX - InterfaceScale.metric(7)),
            height: InterfaceScale.metric(18)
        )
        let subtitleFrame = context.sectionSubtitle.map { _ in
            CGRect(
                x: titleFrame.minX,
                y: titleFrame.maxY,
                width: titleFrame.width,
                height: InterfaceScale.metric(14)
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

extension NativeTimelineRowLayout {
    func matchesAuthorPrimaryGuild(for item: NativeMessageTimelineItem, source: AppModel) -> Bool {
        guard authorFrame != nil, let row = item.messageRow else { return true }
        return authorPrimaryGuild == source.authorPresentation(for: row.message).user.primaryGuild
    }
}
