import AppKit
import SakuraCordModels

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
        let excerpt: ForumCardPresentation.Excerpt
        if let starter {
            excerpt = starter.content.isEmpty ? .empty : .message(starter, author: forumCardAuthor(for: starter))
        } else {
            excerpt = .pending
        }
        let thumbnail = starter?.attachments.first.map(ForumCardPresentation.Media.init(attachment:))
        let hero: ForumCardPresentation.Hero =
            if let thumbnail {
                .media(thumbnail)
            } else if let preview = post.mostRecentMessage ?? starter, !preview.content.isEmpty {
                .text(preview)
            } else if starter == nil {
                .pending
            } else {
                .empty
            }
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
        let reaction = ForumPostReactionPresentation.displayedReaction(
            reactions: starter?.reactions ?? [],
            defaultReaction: channel.defaultReaction
        ).flatMap { reaction in
            starter.map {
                ForumCardPresentation.ReactionSummary(
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
            isNew: isForumPostNew(post),
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
        let roleColor = NativeTimelineRowPainter.roleColor(presentation.roleColorHex)
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
