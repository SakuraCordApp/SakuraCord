import AppKit
import SakuraCordModels

extension NativeMessageTimelineCoordinator {
    func makeItems(
        from parent: NativeMessageTimelineView,
        rows: [MessageRowPresentation]
    ) -> [NativeMessageTimelineItem] {
        if parent.conversation == .inbox(.unread) {
            let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            var result: [NativeMessageTimelineItem] = []
            for group in parent.model.inbox.groups {
                result.append(.inboxGroup(InboxGroupHeaderPresentation(group, model: parent.model)))
                if !group.isCollapsed {
                    result.append(contentsOf: group.events.map(NativeMessageTimelineItem.inboxEvent))
                    result.append(contentsOf: group.forumPosts.map(NativeMessageTimelineItem.inboxForumPost))
                    result.append(contentsOf: messageItems(group.messages.compactMap { rowsByID[$0.id] }, from: parent))
                    if !group.isLoaded { break }
                } else if let canvas {
                    result.append(contentsOf: canvas.heldInboxItems(for: group.id))
                }
            }
            return result
        }
        var result = makeLeadingItems(from: parent)
        result.reserveCapacity(rows.count + 2)
        result.append(contentsOf: messageItems(rows, from: parent))
        return result
    }

    func makeLeadingItems(
        from parent: NativeMessageTimelineView
    ) -> [NativeMessageTimelineItem] {
        var result: [NativeMessageTimelineItem] = []
        result.reserveCapacity(2)
        if let beginning = parent.beginning {
            result.append(.beginning(beginning))
        }
        if NativeTimelineEarlierLoaderPolicy.includesLoader(
            hasMoreMessages: parent.hasMoreMessages,
            isLoadingEarlier: parent.isLoadingEarlier
        ) {
            result.append(
                .loader(
                    // Automatic pagination stays silent while idle, but a
                    // slow in-flight page must remain visible. The loader
                    // layout is zero-height when idle, preserving document
                    // geometry between requests.
                    isLoading: parent.isLoadingEarlier,
                    kind: parent.conversation.loaderKind
                )
            )
        }
        return result
    }

    func messageItem(
        _ row: MessageRowPresentation,
        from parent: NativeMessageTimelineView
    ) -> NativeMessageTimelineItem {
        let resolvedRow: MessageRowPresentation
        if let startsDay = parent.firstMessageStartsDayOverride,
           parent.conversation.rows(in: parent.model).first?.id == row.id,
           startsDay != row.startsDay
        {
            resolvedRow = MessageRowPresentation(
                message: row.message,
                startsGroup: row.startsGroup,
                endsGroup: row.endsGroup,
                startsDay: startsDay,
                replyPreview: row.replyPreview,
                isReplyAvailable: row.isReplyAvailable,
                textPlan: row.textPlan
            )
        } else {
            resolvedRow = row
        }
        let isUnreadBoundary = parent.unreadMessageID == row.id
        return .message(
            isUnreadBoundary ? resolvedRow.startingGroup() : resolvedRow,
            isUnreadBoundary: isUnreadBoundary,
            isHighlighted: parent.selectedMessageID == row.id
        )
    }
}
