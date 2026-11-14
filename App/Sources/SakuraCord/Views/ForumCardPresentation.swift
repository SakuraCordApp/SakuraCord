import AppKit
import SakuraCordModels

/// Everything a forum card draws, resolved once from the model. Cards repaint
/// only when their presentation changes; geometry never depends on it beyond
/// `ForumCardGeometryInput`.
struct ForumCardPresentation: Equatable {
    struct Tag: Equatable {
        let id: ForumTagID
        let name: String
        let emoji: ForumTagEmojiPresentation?
    }

    struct Author: Hashable {
        let name: String
        let fontID: Int?
        let color: NSColor?
        let roleDotColor: NSColor?
    }

    enum Excerpt: Equatable {
        /// The starter message has not loaded yet.
        case pending
        /// Discord's muted text in place of a starter without text, after
        /// its author's name. An image or video starter has none: its
        /// media is the card's thumbnail, so the name stands alone.
        case placeholder(String?, author: Author)
        /// Discord answered without the starter: it was deleted. Discord
        /// still names the post's author before its placeholder.
        case deleted(author: Author?)
        case message(Message, author: Author)
    }

    enum Media: Equatable {
        case image(MediaImageKey)
        case video(poster: MediaImageKey?, filename: String)
        case audio(filename: String)
        case file(filename: String)
        /// Drawn under the spoiler cover, like every hidden item.
        indirect case spoiler(Media)
    }

    enum Hero: Equatable {
        case pending
        case media(Media)
        case text(Message)
        case empty
        case deleted
    }

    struct ReactionSummary: Equatable {
        let reaction: Reaction
        let message: Message
        let isDisabled: Bool
    }

    let title: String
    /// Whether the card reserves its status row; the first-paint geometry
    /// decides it, so it can differ from `tags` while tags are unresolved.
    let hasStatusRow: Bool
    let isEmphasized: Bool
    let isNew: Bool
    let isSelected: Bool
    let isPinned: Bool
    let isLocked: Bool
    let tags: [Tag]
    let excerpt: Excerpt
    let thumbnail: Media?
    let hero: Hero
    let galleryAuthor: Author?
    let reaction: ReactionSummary?
    let messageCount: Int
    /// New replies in an opened unread post; `nil` shows no count.
    let unreadCount: Int?
    let createdAt: Date
    let lastActivityAt: Date
    let underlinesLinks: Bool

    /// The relative time a card shows: last activity in the list, creation in the gallery.
    func relativeTimeText(isGallery: Bool) -> String {
        ForumTimestampPresentation.roundedRelativeText(for: isGallery ? createdAt : lastActivityAt, relativeTo: .now)
    }

    /// Whether skeleton bars stand in for the field the layout shows: the
    /// excerpt in the list, the hero in the gallery.
    func isAwaitingContent(isGallery: Bool) -> Bool {
        isGallery ? hero == .pending : excerpt == .pending
    }

    /// The attachment the layout shows: the thumbnail in the list, the hero in the gallery.
    func media(isGallery: Bool) -> Media? {
        guard isGallery else { return thumbnail }
        guard case let .media(media) = hero else { return nil }
        return media
    }

    var accessibilityLabel: String {
        var parts = [title]
        if isPinned { parts.append("Pinned") }
        if isLocked { parts.append("Locked") }
        if isNew { parts.append("New post") }
        if !tags.isEmpty { parts.append("Tags: " + tags.map(\.name).joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }

    /// Discord caps the footer's new-reply count at 25+.
    var unreadCountText: String? {
        unreadCount.map { $0 >= 25 ? "25+" : $0.formatted() }
    }

    var messageCountAccessibilityText: String {
        let messages = messageCount == 1 ? "message" : "messages"
        guard let unreadCount, let unreadCountText else { return "\(messageCount) \(messages)" }
        let newMessages = unreadCount == 1 ? "new message" : "new messages"
        return "\(messageCount) \(messages), \(unreadCountText) \(newMessages)"
    }
}

enum ForumTagEmojiPresentation: Equatable {
    case unicode(String)
    case custom(URL)

    init?(tag: ForumTag, customEmojiURLsByID: CustomEmojiImageURLs) {
        if tag.emojiID != nil {
            guard let url = Self.customEmojiURL(for: tag, customEmojiURLsByID: customEmojiURLsByID) else { return nil }
            self = .custom(url)
        } else if let name = tag.emojiName, !name.isEmpty {
            self = .unicode(name)
        } else {
            return nil
        }
    }

    var mediaKey: MediaImageKey? {
        guard case let .custom(url) = self else { return nil }
        return .media(url, maximumPixelDimension: 64)
    }

    static func customEmojiURL(for tag: ForumTag, customEmojiURLsByID: CustomEmojiImageURLs) -> URL? {
        tag.emojiID.flatMap { EmojiReference(id: $0, name: tag.emojiName ?? "emoji").imageURL(in: customEmojiURLsByID) }
    }
}

extension ForumCardPresentation.Excerpt {
    /// What Discord's forum card shows for a starter without text.
    static func placeholderText(for starter: Message) -> String? {
        if let poll = starter.poll { return poll.question }
        // A forwarded starter carries its components in the snapshot.
        if (starter.forwardedSnapshot?.flags ?? starter.flags).contains(.isComponentsV2) { return "Click to see message" }
        if !starter.stickers.isEmpty { return "Click to see sticker" }
        return ForumCardPresentation.thumbnailAttachment(of: starter) == nil ? "Click to see attachment" : nil
    }
}

extension ForumCardPresentation {
    /// Discord gives a list card a thumbnail only for a starter that opens
    /// with an image or a video; audio and other files get none.
    static func thumbnailAttachment(of starter: Message) -> Attachment? {
        guard let attachment = starter.attachments.first else { return nil }
        switch attachment.mediaKind {
        case .image, .animatedImage, .video: return attachment
        default: return nil
        }
    }
}

extension ForumCardPresentation.Media {
    init(attachment: Attachment) {
        switch attachment.mediaKind {
        case .image, .animatedImage:
            let url = attachment.proxyURL ?? attachment.url
            self = .image(.media(url, fallbackURL: url == attachment.url ? nil : attachment.url, maximumPixelDimension: 640))
        case .video:
            self = .video(
                poster: attachment.videoPosterURL(maximumPixelDimension: 640).map { .media($0, maximumPixelDimension: 640) },
                filename: attachment.filename
            )
        case .audio:
            self = .audio(filename: attachment.filename)
        case .file:
            self = .file(filename: attachment.filename)
        }
        if attachment.isSpoiler { self = .spoiler(self) }
    }

    var accessibilityDescription: String {
        switch self {
        case .image: "Image attachment"
        case let .video(_, filename): "Video attachment, \(filename)"
        case let .audio(filename): "Audio attachment, \(filename)"
        case let .file(filename): "File attachment, \(filename)"
        case .spoiler: "Spoiler attachment hidden"
        }
    }

    var mediaKey: MediaImageKey? {
        switch self {
        case let .image(key): key
        case let .video(poster, _): poster
        case let .spoiler(media): media.mediaKey
        case .audio, .file: nil
        }
    }
}

nonisolated enum ForumTimestampPresentation {
    static func roundedRelativeText(for date: Date, relativeTo now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60:
            return "now"
        case ..<3_600:
            return "\(max(1, seconds / 60))m ago"
        case ..<86_400:
            return "\(seconds / 3_600)h ago"
        case ..<604_800:
            return "\(seconds / 86_400)d ago"
        case ..<2_629_800:
            return "\(seconds / 604_800)w ago"
        case ..<31_557_600:
            return "\(seconds / 2_629_800)mo ago"
        default:
            return "\(seconds / 31_557_600)y ago"
        }
    }
}

nonisolated enum ForumPostReactionPresentation {
    static func displayedReaction(
        reactions: [Reaction],
        defaultReaction: ForumDefaultReaction?
    ) -> Reaction? {
        // `max(by:)` keeps the first of equally counted reactions.
        if let highestCountReaction = MessageReactionPresentation.items(from: reactions)
            .max(by: { $0.count < $1.count })
        {
            return highestCountReaction
        }
        guard let token = defaultReactionToken(defaultReaction) else { return nil }
        return Reaction(emoji: token, count: 0)
    }

    static func defaultReactionToken(_ value: ForumDefaultReaction?) -> String? {
        guard let value else { return nil }
        if let id = value.emojiID {
            return EmojiReference(id: id, name: value.emojiName ?? "emoji").rawToken
        }
        return value.emojiName
    }
}

extension AppModel {
    /// `tagsByID` is the channel's tags keyed by ID, built once by the caller
    /// rather than per post.
    func forumCardPresentation(
        for post: ForumPost,
        in channel: Channel,
        tagsByID: [ForumTagID: ForumTag]
    ) -> ForumCardPresentation {
        let tags = post.thread.appliedTagIDs.compactMap { tagsByID[$0] }.map {
            ForumCardPresentation.Tag(
                id: $0.id,
                name: $0.name,
                emoji: ForumTagEmojiPresentation(tag: $0, customEmojiURLsByID: customEmojiURLsByID)
            )
        }
        let starter = post.firstMessage
        let galleryAuthor: ForumCardPresentation.Author? =
            if let starter {
                forumCardAuthor(for: starter)
            } else if let owner = post.owner {
                ForumCardPresentation.Author(
                    name: owner.displayName,
                    fontID: owner.displayNameStyle?.fontID,
                    color: owner.isBot ? .sakuraCordAccentColor : nil,
                    roleDotColor: nil
                )
            } else {
                nil
            }
        let excerpt: ForumCardPresentation.Excerpt
        if let starter {
            let author = forumCardAuthor(for: starter)
            excerpt = starter.content.isEmpty
                ? .placeholder(ForumCardPresentation.Excerpt.placeholderText(for: starter), author: author)
                : .message(starter, author: author)
        } else {
            excerpt = post.isFirstMessageLoaded ? .deleted(author: galleryAuthor) : .pending
        }
        let thumbnail = starter
            .flatMap(ForumCardPresentation.thumbnailAttachment(of:))
            .map(ForumCardPresentation.Media.init(attachment:))
        let hero: ForumCardPresentation.Hero =
            if let media = starter?.attachments.first.map(ForumCardPresentation.Media.init(attachment:)) {
                .media(media)
            } else if starter == nil, post.isFirstMessageLoaded {
                .deleted
            } else if let preview = post.mostRecentMessage ?? starter, !preview.content.isEmpty {
                .text(preview)
            } else if starter == nil {
                .pending
            } else {
                .empty
            }
        let reaction = ForumPostReactionPresentation.displayedReaction(
            reactions: starter?.reactions ?? [],
            defaultReaction: channel.defaultReaction
        ).flatMap { reaction in
            starter.map {
                // Cards show only the emoji and count, so reactor identities
                // stay out of what the card compares, draws and announces.
                var reaction = reaction
                reaction.reactors = []
                return ForumCardPresentation.ReactionSummary(
                    reaction: reaction,
                    message: $0,
                    isDisabled: guildTimeoutUntil(in: post.id, guildID: post.thread.guildID) != nil
                )
            }
        }
        return ForumCardPresentation(
            title: post.thread.name,
            hasStatusRow: ForumCardGeometryInput(post: post).hasStatusRow,
            isEmphasized: shouldEmphasizeForumPost(post),
            isNew: readState.isNewForumPost(post),
            isSelected: openThread?.id == post.id,
            isPinned: post.thread.isPinned,
            isLocked: post.thread.isLocked,
            tags: tags,
            excerpt: excerpt,
            thumbnail: thumbnail,
            hero: hero,
            galleryAuthor: galleryAuthor,
            reaction: reaction,
            messageCount: max(0, post.thread.messageCount),
            unreadCount: forumUnreadMessageCount(post),
            createdAt: post.createdAt,
            lastActivityAt: post.lastActivityAt,
            underlinesLinks: accessibilitySettings.underlinesLinks
        )
    }

    private func forumCardAuthor(for message: Message) -> ForumCardPresentation.Author {
        let presentation = authorPresentation(for: message)
        let roleColor = NSColor(discordColor: presentation.roleColorHex)
        let display = accessibilitySettings.roleColorDisplay
        let color: NSColor? =
            if presentation.user.isBot {
                .sakuraCordAccentColor
            } else if display == .inNames {
                roleColor
            } else {
                nil
            }
        return ForumCardPresentation.Author(
            name: presentation.user.displayName,
            fontID: presentation.user.displayNameStyle?.fontID,
            color: color,
            roleDotColor: display == .nextToNames ? roleColor : nil
        )
    }
}
