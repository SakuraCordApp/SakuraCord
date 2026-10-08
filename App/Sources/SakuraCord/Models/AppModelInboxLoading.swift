import DiscordProtocol
import SakuraCordModels

extension AppModel {
    private func inboxMessagesPreservingRefreshMutations(_ messages: [Message]) -> [Message] {
        let ids = Set(messages.map(\.id))
        let journal = inbox.refreshJournal
        // Inbox membership comes from its endpoint/captured unread boundary.
        // Replay changes to those messages without inserting unrelated upserts.
        let mutations = ConversationRefreshMutations(
            messages: journal?.mutationsByMessageID.filter { ids.contains($0.key) } ?? [:],
            updatedUsers: journal?.updatedUsers ?? [:]
        )
        return Self.applyingConversationRefreshMutations(mutations, to: messages).map {
            pollVotePresentationPreserving(reactionPresentationPreserving($0))
        }
    }

    func loadInboxMentionPage(query: InboxMentionQuery, before: MessageID?, session: AppModelAccountSession, generation: UInt64) async throws {
        let page = try await session.provider.inboxMentions(query, before: before)
        guard !Task.isCancelled, isCurrentAccountSession(session), inbox.generation == generation else { return }
        for thread in page.threads { inbox.threads[thread.id] = thread }
        var combined = Dictionary(uniqueKeysWithValues: inbox.mentions.map { ($0.id, $0) })
        for message in inboxMessagesPreservingRefreshMutations(page.messages) where !inbox.removedIDs.contains(message.id) {
            combined[message.id] = message
        }
        inbox.mentions = combined.values.filter { snapshot?.blockedOrIgnoredUserIDs.contains($0.author.id) != true }
            .sorted { $0.id > $1.id }
        inbox.nextBefore = page.nextBefore
        inbox.hasMoreMentions = page.hasMore && page.nextBefore != nil && page.nextBefore != before
    }

    /// Replaces the retained head with Discord's newest page, keeping older pages already loaded.
    func revalidateInboxMentions(query: InboxMentionQuery, session: AppModelAccountSession, generation: UInt64) async throws {
        let page = try await session.provider.inboxMentions(query, before: nil)
        guard !Task.isCancelled, isCurrentAccountSession(session), inbox.generation == generation else { return }
        inbox.needsMentionRevalidation = false
        for thread in page.threads { inbox.threads[thread.id] = thread }
        let fresh = inboxMessagesPreservingRefreshMutations(page.messages).filter { !inbox.removedIDs.contains($0.id) }
        // Retained mentions inside the fresh page's range that it omits were dismissed or deleted elsewhere.
        let floor = page.hasMore ? page.nextBefore : nil
        var combined = Dictionary(uniqueKeysWithValues: inbox.mentions.filter { message in
            floor.map { message.id < $0 } ?? false
        }.map { ($0.id, $0) })
        for message in fresh { combined[message.id] = message }
        let retainsOlderPages = combined.count > fresh.count
        inbox.mentions = combined.values.filter { snapshot?.blockedOrIgnoredUserIDs.contains($0.author.id) != true }
            .sorted { $0.id > $1.id }
        if !retainsOlderPages {
            inbox.nextBefore = page.nextBefore
            inbox.hasMoreMentions = page.hasMore && page.nextBefore != nil
        }
        for message in fresh { resolveInboxThreadContext(for: message) }
    }

    func loadInboxGroup(_ group: InboxUnreadGroup, session: AppModelAccountSession, generation: UInt64) async throws {
        if group.isEvents {
            try await loadInboxEvents(group, session: session, generation: generation)
        } else if group.isForum {
            try await loadInboxForum(group, session: session, generation: generation)
        } else {
            try await loadInboxMessages(group, session: session, generation: generation)
        }
    }

    func loadInboxMessages(_ group: InboxUnreadGroup, session: AppModelAccountSession, generation: UInt64) async throws {
        var anchor = group.oldestReadMessageID.map(MessageHistoryAnchor.around) ?? .newest
        var collected: [MessageID: Message] = [:]
        var previousCursor: MessageID?
        while true {
            let page = try await session.provider.messagesForImmediatePresentation(
                in: group.channelID, anchoredAt: anchor, limit: 30
            )
            guard !Task.isCancelled, isCurrentAccountSession(session), inbox.generation == generation else { return }
            for message in page.messages where message.id > (group.oldestReadMessageID ?? MessageID(rawValue: 0))
                && message.id <= group.newestUnreadMessageID {
                collected[message.id] = message
            }
            guard collected.count < 25, page.hasMoreAfter,
                  let cursor = page.messages.map(\.id).max(), cursor < group.newestUnreadMessageID,
                  cursor != previousCursor else { break }
            previousCursor = cursor
            anchor = .after(cursor)
        }
        guard let index = inbox.groups.firstIndex(where: { $0.id == group.id }) else { return }
        inbox.groups[index].messages = Array(inboxMessagesPreservingRefreshMutations(Array(collected.values)).filter {
            !inbox.deletedIDs.contains($0.id)
        }.sorted { $0.id < $1.id }.prefix(25))
        inbox.groups[index].isLoaded = true
        inbox.groups[index].needsRevalidation = false
        inbox.groups[index].errorMessage = nil
    }
}
