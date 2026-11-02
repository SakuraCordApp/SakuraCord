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
