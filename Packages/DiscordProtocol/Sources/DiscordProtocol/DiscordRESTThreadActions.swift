import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    /// The first-party thread browser's REST reads, through the same
    /// `threads/search` builders and caches as the forum catalogue. Archived
    /// pages hold 25 records; a name search returns active and archived matches.
    public func threadBrowserPage(in parentID: ChannelID, query: ThreadBrowserQuery) async throws
        -> ForumPostPage
    {
        guard
            let channel = cachedChannels.values.lazy.flatMap(\.self).first(where: {
                $0.id == parentID && [.text, .announcement, .forum].contains($0.kind)
            })
        else { throw ChatProviderError.channelNotFound }
        var catalogueQuery = ForumPostQuery(
            sortOrder: .latestActivity,
            selectedTagIDs: query.selectedTagIDs,
            tagMatch: query.tagMatch,
            limit: ThreadBrowserQuery.pageSize,
            requiresFreshPage: true
        )
        switch query.scope {
        case .archived(let offset):
            catalogueQuery.offset = max(0, offset)
            return try await olderForumPosts(channel: channel, query: catalogueQuery)
        case .search(let text):
            catalogueQuery.scope = .search(text)
            return try await searchedForumPosts(channel: channel, query: catalogueQuery, searchText: text)
        }
    }

    /// Active threads from READY, THREAD_LIST_SYNC, THREAD_CREATE and earlier
    /// reads. Joined threads carry their member's notification settings.
    public func activeThreads(in parentID: ChannelID) async -> [ForumPost] {
        cachedForumPosts[parentID, default: [:]].values
            .filter { !$0.thread.isArchived }
            .sorted {
                $0.lastActivityAt != $1.lastActivityAt
                    ? $0.lastActivityAt > $1.lastActivityAt
                    : $0.id > $1.id
            }
    }

    /// The thread revisions when a REST read starts. Capturing the whole maps
    /// also covers threads unknown at that moment: a later record or deletion
    /// gives them a revision the baseline lacks.
    func threadRevisionBaseline() -> ThreadRevisionBaseline {
        ThreadRevisionBaseline(records: threadRecordRevisions, memberships: threadMembershipRevisions)
    }

    /// A confirmed join or leave updates known threads at once, through the
    /// same path as a Gateway membership change. A member the Gateway already
    /// delivered is kept; it carries Discord's join timestamp. Every accepted
    /// confirmation advances the membership revision, even when the cache
    /// already holds its state, so a read that started while the request was
    /// pending cannot restore the old membership.
    func reconcileConfirmedThreadMembership(threadID: ChannelID, isJoined: Bool) {
        advanceThreadMembershipRevision(threadID, authoritative: false)
        let current = cachedForumPost(threadID: threadID).map { $0.thread.notificationSettings }
            ?? cachedJoinedThreads[threadID]?.notificationSettings
        guard isJoined != (current != nil) else { return }
        var changedParentIDs = Set<ChannelID>()
        guard applyCurrentUserThreadMembership(
            isJoined ? ThreadNotificationSettings(joinedAt: .now) : nil,
            threadID: threadID,
            changedParentIDs: &changedParentIDs
        ) else { return }
        for parentID in changedParentIDs {
            publishForumPosts(parentID: parentID)
        }
        publishActiveJoinedThreads()
    }

    /// A created thread's 201 answers the request that started at `baseline`.
    /// A deletion meanwhile fails the operation instead of restoring the
    /// thread; a newer record and a membership event meanwhile are kept. An
    /// accepted response advances the revisions before it is published.
    func commitCreatedThread(
        _ response: ForumPost,
        respondedMember: Bool,
        since baseline: ThreadRevisionBaseline
    ) throws -> MessageThreadSummary {
        guard let parentID = response.thread.parentID else { return response.thread }
        let id = response.id
        let cached = cachedForumPosts[parentID]?[id]
        let membershipIsCurrent = threadMembershipRevisions[id] == baseline.memberships[id]
        var committed: ForumPost
        if threadRecordRevisions[id] != baseline.records[id] {
            // THREAD_CREATE usually precedes the response and holds its record.
            guard let cached else { throw ChatProviderError.channelNotFound }
            committed = cached
        } else {
            committed = cached.map { Self.mergingForumPostCatalogueMetadata(incoming: response, existing: $0) }
                ?? response
            if committed.owner == nil, let ownerID = committed.thread.ownerID,
               let ownerDTO = cachedGatewayUsersByID[ownerID.description]
            {
                committed.owner = try? ownerDTO.domain()
            }
            advanceThreadRecordRevision(id, includesMembership: false)
        }
        if membershipIsCurrent, respondedMember,
           committed.thread.notificationSettings == nil || cached?.thread.notificationSettings == nil
        {
            committed.thread.notificationSettings = response.thread.notificationSettings
            advanceThreadMembershipRevision(id, authoritative: false)
        } else if !membershipIsCurrent {
            committed.thread.notificationSettings = cached?.thread.notificationSettings
                ?? cachedJoinedThreads[id]?.notificationSettings
        }
        if committed != cached {
            if !cachedForumThreadOrder.contains(id) { cachedForumThreadOrder.append(id) }
            cachedForumPosts[parentID, default: [:]][id] = committed
            reconcileJoinedThread(committed.thread)
            cacheForumPreviewMessages(committed)
            publishForumPosts(parentID: parentID)
            publishActiveJoinedThreads()
        }
        return committed.thread
    }

    /// A thread started from a message shares that message's ID. Discord's
    /// starter `MESSAGE_UPDATE` carries only the has-thread flag, so attach the
    /// known thread to a cached starter that lacks it.
    func attachStartedThreadToCachedStarter(_ threadID: ChannelID) {
        let messageID = MessageID(rawValue: threadID.rawValue)
        guard var message = cachedMessages[messageID], message.thread == nil,
              let thread = cachedForumPosts[message.channelID]?[threadID]?.thread
        else { return }
        message.thread = thread
        message.flags.insert(.hasThread)
        cachedMessages[messageID] = message
        continuation?.yield(.messageUpdated(message))
    }

    /// The same reconciliation for a starter update that arrives after the
    /// thread is known, including for an uncached starter.
    func attachKnownStartedThread(to update: inout MessageUpdate) {
        guard update.thread == nil, update.flags?.contains(.hasThread) == true,
              let thread = cachedForumPosts[update.channelID]?[
                  ChannelID(rawValue: update.messageID.rawValue)
              ]?.thread
        else { return }
        update.thread = .some(thread)
    }
}

struct ThreadRevisionBaseline {
    let records: [ChannelID: UInt64]
    let memberships: [ChannelID: UInt64]
}
