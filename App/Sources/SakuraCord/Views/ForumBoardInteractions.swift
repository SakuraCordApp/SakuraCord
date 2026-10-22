import AppKit
import SakuraCordModels
import SwiftUI

extension ForumBoardView {
    // MARK: Media

    func refreshMedia() {
        var keys = Set<NativeTimelineMediaKey>()
        var keysByPost: [ChannelID: Set<NativeTimelineMediaKey>] = [:]
        let customEmojiURLsByID = model?.customEmojiURLsByID ?? [:]
        for id in cards.keys {
            guard case let .post(postID) = id, let presentation = presentations[postID] else { continue }
            var postKeys = Set<NativeTimelineMediaKey>()
            if let key = presentation.thumbnail?.mediaKey { postKeys.insert(key) }
            for tag in presentation.tags {
                if let key = tag.emoji?.mediaKey { postKeys.insert(key) }
            }
            if let reaction = presentation.reaction?.reaction {
                if let url = MessageReactionPresentation.emojiURL(for: reaction, customEmojiURLsByID: customEmojiURLsByID) {
                    postKeys.insert(.media(url, maximumPixelDimension: 64))
                }
                for reactor in MessageReactionPresentation.previewPlan(for: reaction).reactors {
                    if let url = reactor.avatarURL { postKeys.insert(.avatar(url)) }
                }
            }
            keys.formUnion(postKeys)
            keysByPost[postID] = postKeys
        }
        let store = NativeTimelineMediaStore.shared
        store.retainVisibleImages(for: keys, owner: mediaOwner)
        // Media that leaves view may load next time, as the store retries it.
        failedMediaKeys.formIntersection(keys)
        for (postID, postKeys) in keysByPost {
            for key in postKeys where store.image(for: key) == nil && !failedMediaKeys.contains(key) {
                // The store keys subscribers by timeline item; a forum post is
                // the same post identity the Inbox uses.
                store.request(key, owner: mediaOwner, subscriber: .inboxForumPost(postID)) { [weak self] outcome in
                    guard let self, outcome != .cancelled else { return }
                    if outcome == .failed { failedMediaKeys.insert(key) }
                    cards[.post(postID)]?.render(scale: backingScale, fading: outcome == .ready)
                }
            }
        }
        store.cancelStaticRequestsOutsideVisibleSet(owner: mediaOwner)
    }

    // MARK: Pagination

    func requestNextPageIfNeeded() {
        guard let snapshot, snapshot.hasMore, !snapshot.isLoadingMore, snapshot.paginationError == nil,
              let model
        else { return }
        let visible = visibleRect
        guard visible.maxY > frame.height - visible.height * 1.5 else { return }
        // A page can add no visible posts (filtered or undecodable records)
        // while more remain, so each completed request allows the next.
        guard !isRequestingPage else { return }
        isRequestingPage = true
        Task { [weak self] in
            await model.loadMoreForumPosts()
            self?.isRequestingPage = false
        }
    }

    // MARK: Reaction tooltip

    /// Shows or updates the reactors popover for a post's reaction. Each call
    /// re-resolves its content, so a late emoji catalogue still updates it.
    func presentReactionTooltip(
        postID: ChannelID,
        summary: ForumCardPresentation.ReactionSummary
    ) {
        guard let model, let window else { return }
        let anchor = StablePopoverAnchor(sourceView: self) { [weak self] in
            guard let self, let entry = layoutState?.entry(for: .post(postID)),
                  let frame = cardRegions(for: .post(postID))?.reactionRegionFrame
            else { return nil }
            return frame.offsetBy(dx: entry.frame.minX, dy: entry.frame.minY)
        }
        let screenPoint = NSEvent.mouseLocation
        let pointInView = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        var snapshot: StablePopoverAnchorSnapshot?
        if let source = anchor.sourceRect() {
            snapshot = StablePopoverAnchorSnapshot(
                mouseLocationInScreen: screenPoint,
                mouseLocationInSource: CGPoint(x: pointInView.x - source.minX, y: pointInView.y - source.minY)
            )
        }
        let reaction = summary.reaction
        let emojiURL = MessageReactionPresentation.emojiURL(for: reaction, customEmojiURLsByID: model.customEmojiURLsByID)
        let wasShown = reactionTooltipPostID == postID
        reactionTooltipPostID = postID
        reactionTooltip.update(
            anchor: anchor,
            anchorSnapshot: snapshot,
            isPresented: true,
            configuration: .hover,
            onDismiss: { [weak self] in self?.reactionTooltipPostID = nil },
            presentationIdentity: AnyHashable(postID),
            content: MessageReactionTooltip(reaction: reaction, emojiURL: emojiURL)
        )
        if !wasShown, reaction.count > 0 {
            Task { await model.loadReactionReactors(reaction, on: summary.message) }
        }
    }

    func closeReactionTooltip() {
        guard reactionTooltipPostID != nil else { return }
        reactionTooltipPostID = nil
        reactionTooltip.close()
    }

    // MARK: Tooltips

    func rebuildToolTips() {
        removeAllToolTips()
        for (id, _) in cards {
            guard case .post = id, let entry = layoutState?.entry(for: id),
                  let frame = cardRegions(for: id)?.exactDateFrame
            else { continue }
            addToolTip(frame.offsetBy(dx: entry.frame.minX, dy: entry.frame.minY), owner: self, userData: nil)
        }
    }

    func view(_: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?) -> String {
        guard let hit = hit(at: point), let postID = hit.entry.item.postID, let presentation = presentations[postID] else { return "" }
        return isGallery
            ? "Posted \(presentation.createdAt.formatted(date: .complete, time: .shortened))"
            : "Last activity \(presentation.lastActivityAt.formatted(date: .complete, time: .shortened))"
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, let channel,
              let hit = hit(at: convert(event.locationInWindow, from: nil)),
              let postID = hit.entry.item.postID,
              let post = postsByID[postID]
        else { return nil }
        return contextMenu(for: post, model: model, channel: channel)
    }

    func contextMenu(for post: ForumPost, model: AppModel, channel: Channel) -> NSMenu {
        menuBuilder.makeMenu(
            actionsMenu: ThreadActionsMenu(
                model: model,
                thread: post.thread,
                surface: .forumCard,
                isUnread: model.isForumPostUnread(post),
                offersTags: true
            ),
            tags: channel.availableTags,
            appliedTagIDs: post.thread.appliedTagIDs,
            customEmojiURLsByID: model.customEmojiURLsByID,
            requiresTag: channel.requiresForumTag,
            canManage: model.threadActionPolicy(post.thread).canManage,
            toggleTag: { [weak model] tagID in
                model?.toggleForumTag(tagID, on: post, in: channel)
            }
        )
    }
}
