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
        case image(NativeTimelineMediaKey)
        case video(poster: NativeTimelineMediaKey?, filename: String)
        case audio(filename: String)
        case file(filename: String)
        case spoiler
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
        if let id = tag.emojiID {
            let url = customEmojiURLsByID[id]
                ?? EmojiReference(id: id, name: tag.emojiName ?? "emoji").imageURL(size: 64)
            guard let url else { return nil }
            self = .custom(url)
        } else if let name = tag.emojiName, !name.isEmpty {
            self = .unicode(name)
        } else {
            return nil
        }
    }

    var mediaKey: NativeTimelineMediaKey? {
        guard case let .custom(url) = self else { return nil }
        return .media(url, maximumPixelDimension: 64)
    }
}

extension ForumCardPresentation.Excerpt {
    /// What Discord's forum card shows for a starter without text.
    static func placeholderText(for starter: Message) -> String? {
        if let poll = starter.poll { return poll.question }
        if starter.flags.contains(.isComponentsV2) { return "Click to see message" }
        if !starter.stickers.isEmpty { return "Click to see sticker" }
        switch starter.attachments.first?.mediaKind {
        case .image, .animatedImage, .video: return nil
        default: return "Click to see attachment"
        }
    }
}

extension ForumCardPresentation.Media {
    init(attachment: Attachment) {
        if attachment.isSpoiler {
            self = .spoiler
            return
        }
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

    var mediaKey: NativeTimelineMediaKey? {
        switch self {
        case let .image(key): key
        case let .video(poster, _): poster
        case .audio, .file, .spoiler: nil
        }
    }
}
