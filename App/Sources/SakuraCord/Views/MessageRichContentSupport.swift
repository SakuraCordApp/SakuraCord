import AppKit
import MessageRendering
import SakuraCordModels

enum DiscordRichMessageMetrics {
    static let maximumWidth: CGFloat = 520
    static let cardCornerRadius: CGFloat = 8
    static let cardPadding: CGFloat = 12
}

nonisolated enum DiscordFittingWidthPlan {
    static func width(ideal: CGFloat, available: CGFloat?, maximum: CGFloat) -> CGFloat {
        min(max(0, ideal), max(0, available ?? maximum), maximum)
    }
}

nonisolated enum MessageEmbedPresentationKind: Equatable {
    case hidden, bareMedia, card
}

nonisolated enum MessageEmbedPresentation {
    static func visibleEmbeds(
        for message: Message,
        showsAutomaticLinkPreviews: Bool = true
    ) -> [MessageEmbed] {
        guard !message.flags.contains(.suppressEmbeds) else { return [] }
        let linkedEmojiURLs =
            LinkedImagePresentation(content: message.content)
                .matchedEmojiURLs
        let sakuraCordDeepLinkActions = Set(
            SakuraCordDeepLinkPresentation.all(in: message.content)
                .map(\.action)
        )
        return message.embeds.filter { embed in
            if let url = embed.url,
               let action = SakuraCordDeepLinkPresentation.action(for: url),
               sakuraCordDeepLinkActions.contains(action)
            {
                return false
            }
            if !showsAutomaticLinkPreviews,
               isAutomaticLinkPreview(embed, messageContent: message.content)
            {
                return false
            }
            return !(kind(for: embed) == .bareMedia
                && embed.url.map(linkedEmojiURLs.contains) == true)
        }
    }

    static func visibleMessageContent(
        for message: Message,
        showsAutomaticLinkPreviews: Bool = true
    ) -> String {
        visibleMessageContent(
            message.content,
            embeds: visibleEmbeds(
                for: message,
                showsAutomaticLinkPreviews: showsAutomaticLinkPreviews
            )
        )
    }

    static func isAutomaticLinkPreview(
        _ embed: MessageEmbed,
        messageContent: String
    ) -> Bool {
        guard let url = embed.url?.absoluteString else { return false }
        return messageContent.contains(url)
            || messageContent.contains("<\(url)>")
    }

    static func kind(for embed: MessageEmbed) -> MessageEmbedPresentationKind {
        let type = embed.type?.lowercased()
        if type == "gifv" || type == "image" {
            return embed.image != nil || embed.video != nil ? .bareMedia : .hidden
        }
        let hasMedia = embed.image != nil || embed.video != nil
        let hasCardContent = embed.author != nil || embed.title != nil || embed.description != nil
            || !embed.fields.isEmpty || embed.footer != nil || embed.thumbnail != nil
        if !hasMedia, !hasCardContent {
            return .hidden
        }
        if hasMedia, !hasCardContent, embed.provider == nil {
            return .bareMedia
        }
        return .card
    }

    static func visibleMessageContent(_ content: String, embeds: [MessageEmbed]) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let rawURL = trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
            ? String(trimmed.dropFirst().dropLast()) : trimmed
        guard let contentURL = URL(string: rawURL), contentURL.scheme != nil else { return content }
        let replacesLink = embeds.contains { embed in
            kind(for: embed) == .bareMedia && embed.url == contentURL
        }
        return replacesLink ? "" : content
    }
}

nonisolated enum SystemMessagePresentation {
    enum Action: Equatable, Sendable {
        case profile(UserID)
        case message(guildID: GuildID?, channelID: ChannelID, messageID: MessageID)
        case pins(ChannelID)

        var url: URL {
            switch self {
            case .profile(let userID):
                URL(string: "sakuracord-action://profile/\(userID)")!
            case let .message(guildID, channelID, messageID):
                URL(string: "sakuracord-action://message/\(guildID?.description ?? "@me")/\(channelID)/\(messageID)")!
            case .pins(let channelID):
                URL(string: "sakuracord-action://pins/\(channelID)")!
            }
        }
    }

    struct TextRun: Equatable, Sendable {
        let text: String
        let isEmphasized: Bool
        let action: Action?

        static func emphasized(_ text: String, action: Action? = nil) -> Self {
            Self(text: text, isEmphasized: true, action: action)
        }

        static func secondary(_ text: String) -> Self {
            Self(text: text, isEmphasized: false, action: nil)
        }
    }

    static func label(
        for message: Message,
        currentUserID: UserID? = nil
    ) -> String {
        textRuns(for: message, currentUserID: currentUserID)
            .map(\.text)
            .joined()
    }

    static func attributedLabel(
        for message: Message,
        currentUserID: UserID? = nil,
        baseFontSize: CGFloat,
        actorColor: NSColor? = nil
    ) -> NSAttributedString {
        let value = NSMutableAttributedString()
        for run in textRuns(for: message, currentUserID: currentUserID) {
            var attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(
                            ofSize: baseFontSize,
                            weight: run.isEmphasized ? .semibold : .regular
                        ),
                        .foregroundColor: run.action == .profile(message.author.id)
                            ? actorColor ?? NSColor.labelColor
                            : run.isEmphasized
                                ? NSColor.labelColor
                                : NSColor.secondaryLabelColor,
            ]
            if let action = run.action {
                attributes[.link] = action.url
            }
            value.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return value
    }

    static func textRuns(
        for message: Message,
        currentUserID: UserID? = nil
    ) -> [TextRun] {
        let author = message.author.displayName
        return switch message.type {
        case .recipientAdd, .recipientRemove, .channelNameChange, .channelIconChange,
             .channelPinnedMessage, .userJoin:
            conversationTextRuns(for: message, author: author)
        case .call:
            callTextRuns(for: message, author: author, currentUserID: currentUserID)
        case .guildBoost, .guildBoostTier1, .guildBoostTier2, .guildBoostTier3:
            boostTextRuns(for: message, author: author)
        case .channelFollowAdd, .threadCreated, .guildInviteReminder, .stageStart,
             .stageEnd, .stageSpeaker, .stageTopic:
            eventTextRuns(for: message, author: author)
        default:
            [
                .secondary(
                    message.content.isEmpty
                        ? "Discord system message"
                        : message.content
                )
            ]
        }
    }

    private static func conversationTextRuns(
        for message: Message,
        author: String
    ) -> [TextRun] {
        switch message.type {
        case .recipientAdd:
            let recipientUser = message.mentionedUsers.first
            let recipient = recipientUser?.displayName ?? "someone"
            return [
                actorRun(message),
                .secondary(" added "),
                .emphasized(recipient, action: recipientUser.map { .profile($0.id) }),
                .secondary(" to the group."),
            ]
        case .recipientRemove:
            let recipientUser = message.mentionedUsers.first
            let recipient = recipientUser?.displayName ?? "someone"
            return [
                actorRun(message),
                .secondary(" removed "),
                .emphasized(recipient, action: recipientUser.map { .profile($0.id) }),
                .secondary(" from the group."),
            ]
        case .channelNameChange:
            if message.content.isEmpty {
                return [
                    actorRun(message),
                    .secondary(" changed the group name."),
                ]
            }
            return [
                actorRun(message),
                .secondary(" changed the group name to "),
                .emphasized(message.content),
                .secondary("."),
            ]
        case .channelIconChange:
            return [
                actorRun(message),
                .secondary(" changed the group icon."),
            ]
        case .channelPinnedMessage:
            let target = message.messageReference?.messageID.map {
                Action.message(
                    guildID: message.messageReference?.guildID ?? message.guildID,
                    channelID: message.messageReference?.channelID ?? message.channelID,
                    messageID: $0
                )
            }
            return [
                actorRun(message),
                .secondary(" pinned "),
                .emphasized("a message", action: target),
                .secondary(" to this channel. "),
                .emphasized("See all pinned messages", action: .pins(message.channelID)),
                .secondary("."),
            ]
        case .userJoin:
            return [
                .secondary("Yay you made it, "),
                actorRun(message),
                .secondary("!"),
            ]
        default:
            return []
        }
    }

    private static func callTextRuns(
        for message: Message,
        author: String,
        currentUserID: UserID?
    ) -> [TextRun] {
        guard let endedAt = message.call?.endedAt else {
            return [
                actorRun(message),
                .secondary(" started a call."),
            ]
        }
        let duration = callDuration(from: message.timestamp, to: endedAt)
        if isMissedCall(message, currentUserID: currentUserID) {
            return [
                .secondary("You missed a call from "),
                actorRun(message),
                .secondary(" that lasted \(duration)."),
            ]
        }
        return [
            actorRun(message),
            .secondary(" started a call that lasted \(duration)."),
        ]
    }

    private static func boostTextRuns(
        for message: Message,
        author: String
    ) -> [TextRun] {
        switch message.type {
        case .guildBoost:
            return [actorRun(message), .secondary(" boosted the server!")]
        case .guildBoostTier1:
            return [
                actorRun(message),
                .secondary(" boosted the server to "),
                .emphasized("Level 1"),
                .secondary("!"),
            ]
        case .guildBoostTier2:
            return [
                actorRun(message),
                .secondary(" boosted the server to "),
                .emphasized("Level 2"),
                .secondary("!"),
            ]
        case .guildBoostTier3:
            return [
                actorRun(message),
                .secondary(" boosted the server to "),
                .emphasized("Level 3"),
                .secondary("!"),
            ]
        default:
            return []
        }
    }

    private static func eventTextRuns(
        for message: Message,
        author: String
    ) -> [TextRun] {
        switch message.type {
        case .channelFollowAdd:
            return [
                actorRun(message),
                .secondary(" added a followed channel."),
            ]
        case .threadCreated:
            return [
                actorRun(message),
                .secondary(" started a thread: "),
                .emphasized(message.content.isEmpty ? "Thread" : message.content),
            ]
        case .guildInviteReminder:
            return [
                .secondary(
                    "Wondering who to invite? Start by inviting anyone who can help this server grow."
                )
            ]
        case .stageStart:
            return [actorRun(message), .secondary(" started a Stage.")]
        case .stageEnd:
            return [actorRun(message), .secondary(" ended the Stage.")]
        case .stageSpeaker:
            return [actorRun(message), .secondary(" is now a speaker.")]
        case .stageTopic:
            if message.content.isEmpty {
                return [.secondary("The Stage topic changed.")]
            }
            return [
                .secondary("Stage topic: "),
                .emphasized(message.content),
            ]
        default:
            return []
        }
    }

    private static func actorRun(_ message: Message) -> TextRun {
        .emphasized(
            message.author.displayName,
            action: .profile(message.author.id)
        )
    }

    static func systemImage(
        for message: Message,
        currentUserID: UserID? = nil
    ) -> String {
        switch message.type {
        case .recipientAdd: "arrow.right"
        case .recipientRemove: "arrow.left"
        case .channelNameChange: "pencil"
        case .channelIconChange: "photo.fill"
        case .userJoin: "arrow.right"
        case .guildBoost, .guildBoostTier1, .guildBoostTier2, .guildBoostTier3:
            "sparkles"
        case .channelPinnedMessage: "pin.fill"
        case .call:
            isMissedCall(message, currentUserID: currentUserID)
                ? "phone.down.fill" : "phone.fill"
        default: "info.circle.fill"
        }
    }

    static func usesSuccessColor(
        for message: Message,
        currentUserID: UserID? = nil
    ) -> Bool {
        message.type == .recipientAdd
            || message.type == .userJoin
            || (message.type == .call
                && !isMissedCall(message, currentUserID: currentUserID))
    }

    static func isMissedCall(
        _ message: Message,
        currentUserID: UserID?
    ) -> Bool {
        guard message.type == .call,
              let currentUserID,
              let call = message.call,
              call.endedAt != nil,
              !call.participantIDs.isEmpty
        else { return false }
        return !call.participantIDs.contains(currentUserID)
    }

    private static func callDuration(from start: Date, to end: Date) -> String {
        let totalSeconds = max(0, Int(end.timeIntervalSince(start)))
        if totalSeconds < 60 {
            return "a few seconds"
        }
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            return totalMinutes == 1 ? "1 minute" : "\(totalMinutes) minutes"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        guard minutes > 0 else { return hourText }
        return "\(hourText) \(minutes == 1 ? "1 minute" : "\(minutes) minutes")"
    }
}

struct RichMediaItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case image(animated: Bool)
        case video, audio, file
    }

    var id: String
    var url: URL
    var previewURL: URL?
    var title: String
    var description: String?
    var width: Int?
    var height: Int?
    var size: Int
    var kind: Kind
    var isSpoiler: Bool
    var autoplaysInline: Bool

    init(_ attachment: Attachment) {
        id = attachment.id
        url = attachment.url
        previewURL = attachment.proxyURL
        title = attachment.title ?? attachment.filename
        description = attachment.description
        width = attachment.width
        height = attachment.height
        size = attachment.size
        isSpoiler = attachment.isSpoiler
        autoplaysInline = false
        kind =
            switch attachment.mediaKind {
            case .image: .image(animated: false)
            case .animatedImage: .image(animated: true)
            case .video: .video
            case .audio: .audio
            case .file: .file
            }
    }

    init(
        id: String, media: MessageEmbedMedia, fallbackTitle: String,
        autoplaysInline: Bool = false
    ) {
        self.id = id
        url = media.url ?? URL(string: "about:blank")!
        previewURL = media.proxyURL
        title = fallbackTitle
        description = media.description
        width = media.width
        height = media.height
        size = 0
        let pathExtension = media.url?.pathExtension.lowercased()
        if media.contentType?.hasPrefix("video/") == true {
            kind = .video
        } else {
            kind = .image(
                animated: media.flags & 1 != 0 || pathExtension == "gif" || pathExtension == "apng"
            )
        }
        isSpoiler = false
        self.autoplaysInline = autoplaysInline
    }

    init?(embed: MessageEmbed, attachments: [Attachment]) {
        guard var media = embed.image ?? embed.video else { return nil }
        if let raw = media.url?.absoluteString,
           raw.hasPrefix("attachment://"),
           let attachment = attachments.first(where: {
               $0.filename == String(raw.dropFirst("attachment://".count))
           })
        {
            self.init(attachment)
            return
        }
        guard media.url != nil else { return nil }
        if embed.video != nil {
            media.contentType = "video/unknown"
            if media.width == nil {
                media.width = embed.thumbnail?.width ?? embed.image?.width
            }
            if media.height == nil {
                media.height = embed.thumbnail?.height ?? embed.image?.height
            }
        }
        self.init(
            id: "\(embed.id)-media",
            media: media,
            fallbackTitle: embed.title ?? "Embed media",
            autoplaysInline: embed.type?.lowercased() == "gifv"
        )
    }

    init(id: String, media: ComponentMedia, fallbackTitle: String) {
        self.init(
            id: id,
            media: MessageEmbedMedia(
                url: media.url, proxyURL: media.proxyURL, width: media.width, height: media.height,
                description: media.description, contentType: media.contentType,
                placeholder: media.placeholder, placeholderVersion: media.placeholderVersion,
                flags: media.flags ?? 0
            ),
            fallbackTitle: fallbackTitle
        )
        isSpoiler = media.isSpoiler
    }

    init(
        imageID: String,
        url: URL,
        previewURL: URL? = nil,
        title: String,
        description: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        id = imageID
        self.url = url
        self.previewURL = previewURL
        self.title = title
        self.description = description
        self.width = width
        self.height = height
        size = 0
        let pathExtension = url.pathExtension.lowercased()
        kind = .image(
            animated: pathExtension == "gif" || pathExtension == "apng"
        )
        isSpoiler = false
        autoplaysInline = false
    }

    init(
        componentID: String,
        url: URL,
        previewURL: URL? = nil,
        title: String,
        description: String? = nil,
        isVideo: Bool
    ) {
        id = componentID
        self.url = url
        self.previewURL = previewURL
        self.title = title
        self.description = description
        width = nil
        height = nil
        size = 0
        kind = isVideo
            ? .video
            : .image(animated: Self.isAnimatedImageURL(url))
        isSpoiler = false
        autoplaysInline = false
    }

    static func isSupportedImageURL(_ url: URL) -> Bool {
        let extensions = Set([
            "apng", "avif", "gif", "heic", "heif", "jpeg", "jpg",
            "png", "tiff", "webp",
        ])
        return extensions.contains(url.pathExtension.lowercased())
    }

    private static func isAnimatedImageURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return pathExtension == "gif" || pathExtension == "apng"
    }

    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }

    var intrinsicSize: CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

nonisolated enum MediaGalleryPlan {
    static func rowCounts(for count: Int) -> [Int] {
        switch count {
        case ...0: []
        case 1: [1]
        case 2: [2]
        case 3: [1, 2]
        case 4: [2, 2]
        case 5: [2, 3]
        case 6: [3, 3]
        case 7: [1, 3, 3]
        case 8: [2, 3, 3]
        case 9: [3, 3, 3]
        case 10: [1, 3, 3, 3]
        default: stride(from: 0, to: count, by: 3).map { min(3, count - $0) }
        }
    }

    static func frames(
        count: Int, width: CGFloat, aspectRatios: [CGFloat], intrinsicSizes: [CGSize] = [],
        spacing: CGFloat
    ) -> [CGRect]
    {
        guard count > 0 else { return [] }
        if count == 1 {
            if let intrinsicSize = intrinsicSizes.first,
               intrinsicSize.width > 0, intrinsicSize.height > 0
            {
                let scale = min(1, width / intrinsicSize.width, 350 / intrinsicSize.height)
                return [
                    CGRect(
                        x: 0, y: 0, width: intrinsicSize.width * scale,
                        height: intrinsicSize.height * scale
                    )
                ]
            }
            let ratio = max(0.2, min(12, aspectRatios.first ?? 16 / 9))
            let fittedWidth = min(width, 350 * ratio)
            let fittedHeight = min(350, fittedWidth / ratio)
            return [CGRect(x: 0, y: 0, width: fittedWidth, height: max(80, fittedHeight))]
        }
        if count == 3 {
            let height = min(300, max(190, width * 0.62))
            let heroWidth = (width - spacing) * 0.64
            let stackWidth = width - spacing - heroWidth
            return [
                CGRect(x: 0, y: 0, width: heroWidth, height: height),
                CGRect(x: heroWidth + spacing, y: 0, width: stackWidth, height: (height - spacing) / 2),
                CGRect(
                    x: heroWidth + spacing, y: (height + spacing) / 2, width: stackWidth,
                    height: (height - spacing) / 2
                )
            ]
        }
        var result: [CGRect] = []
        var verticalOffset: CGFloat = 0
        for (rowIndex, columns) in rowCounts(for: count).enumerated() {
            let tileWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let hero = columns == 1 && (count == 7 || count == 10) && rowIndex == 0
            let height = hero ? min(240, max(150, width * 0.44)) : min(175, max(92, tileWidth * 0.72))
            for column in 0 ..< columns {
                result.append(
                    CGRect(
                        x: CGFloat(column) * (tileWidth + spacing),
                        y: verticalOffset,
                        width: tileWidth,
                        height: height
                    )
                )
            }
            verticalOffset += height + spacing
        }
        return result
    }
}

nonisolated enum MediaGalleryImagePresentation {
    static func fillsFrame(itemCount: Int) -> Bool {
        itemCount > 1
    }
}

nonisolated enum DiscordComponentContainerLayoutPlan {
    static func width(
        idealContent: CGFloat,
        available: CGFloat?,
        maximum: CGFloat,
        padding: CGFloat,
        hasAccent: Bool
    ) -> CGFloat {
        let fixedWidth = padding * 2 + (hasAccent ? 4 : 0)
        return DiscordFittingWidthPlan.width(
            ideal: idealContent + fixedWidth,
            available: available,
            maximum: maximum
        )
    }
}
