import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    public func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        guard
            let channel = cachedChannels.values.lazy.flatMap(\.self).first(where: {
                $0.id == channelID && $0.kind == .forum
            })
        else { throw ChatProviderError.channelNotFound }

        switch query.scope {
        case .active:
            let cachedPosts = Array(cachedForumPosts[channelID, default: [:]].values)
            if !query.requiresFreshPage, query.offset == 0, !cachedPosts.isEmpty {
                let immediatePosts = Self.filteredAndSortedForumPosts(
                    cachedPosts,
                    query: query
                )
                scheduleForumCatalogueRefresh(
                    channel: channel,
                    query: query
                )
                scheduleForumPostPreviewHydration(
                    parentID: channelID,
                    postIDs: immediatePosts.map(\.id)
                )
                return ForumPostPage(posts: immediatePosts, hasMore: false, nextOffset: nil)
            }
            do {
                let remotePage = try await olderForumPosts(channel: channel, query: query)
                // Re-read the cache: Gateway events may have changed it meanwhile.
                let page = Self.mergedForumCataloguePage(
                    cachedPosts: Array(cachedForumPosts[channelID, default: [:]].values),
                    olderPage: remotePage,
                    query: query
                )
                scheduleForumPostPreviewHydration(
                    parentID: channelID,
                    postIDs: page.posts.map(\.id)
                )
                return page
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard !query.requiresFreshPage, !cachedPosts.isEmpty else { throw error }
                gatewayLogger.warning(
                    "Older forum-post pagination failed; retaining cached posts for channel \(channelID)"
                )
                guard query.offset == 0 else { throw error }
                let posts = Self.filteredAndSortedForumPosts(cachedPosts, query: query)
                return ForumPostPage(posts: posts, hasMore: false, nextOffset: nil)
            }
        case .search(let text):
            return try await searchedForumPosts(
                channel: channel, query: query, searchText: text
            )
        }
    }

    func scheduleForumCatalogueRefresh(
        channel: Channel,
        query: ForumPostQuery
    ) {
        let key = ForumCatalogueLoadKey(channelID: channel.id, query: query)
        guard forumCatalogueTasks[key] == nil else { return }

        let supersededKeys = forumCatalogueTasks.keys.filter { $0 != key }
        for supersededKey in supersededKeys {
            forumCatalogueTasks.removeValue(forKey: supersededKey)?.cancel()
            forumCatalogueTaskIDs[supersededKey] = nil
        }

        let taskID = UUID()
        forumCatalogueTaskIDs[key] = taskID
        forumCatalogueTasks[key] = Task { [weak self] in
            await self?.refreshForumCatalogue(
                channel: channel,
                query: query,
                key: key,
                taskID: taskID
            )
        }
    }

    func refreshForumCatalogue(
        channel: Channel,
        query: ForumPostQuery,
        key: ForumCatalogueLoadKey,
        taskID: UUID
    ) async {
        let previouslyKnownPostIDs = Set(cachedForumPosts[channel.id, default: [:]].keys)
        defer {
            if forumCatalogueTaskIDs[key] == taskID {
                forumCatalogueTasks[key] = nil
                forumCatalogueTaskIDs[key] = nil
            }
        }
        #if DEBUG
            if suspendsForumCatalogueRefreshForTesting {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        #endif
        do {
            let remotePage = try await olderForumPosts(channel: channel, query: query)
            let page = Self.mergedForumCataloguePage(
                cachedPosts: Array(cachedForumPosts[channel.id, default: [:]].values),
                olderPage: remotePage,
                query: query
            )
            continuation?.yield(
                .forumPageLoaded(channelID: channel.id, query: query, page: page)
            )
            scheduleForumPostPreviewHydration(
                parentID: channel.id,
                postIDs: page.posts.lazy.map(\.id).filter {
                    !previouslyKnownPostIDs.contains($0)
                }
            )
        } catch {
            if !Task.isCancelled {
                gatewayLogger.warning(
                    "Background forum catalogue refresh failed for channel \(channel.id)"
                )
            }
        }
    }

    /// A known thread is answered from the cache. An unknown one costs one
    /// Get Channel, whose thread `member` states the current membership; a
    /// membership event during that read makes it ask once more.
    public func forumPost(threadID: ChannelID) async throws -> ForumPost {
        try await lookUpThread(threadID: threadID, refreshesCachedRecord: false)
    }

    /// A cached record may come from a member-less Gateway record, which
    /// settles no membership, so private-thread access resolution always asks.
    public func resolveThreadAccess(threadID: ChannelID) async throws -> ForumPost {
        try await lookUpThread(threadID: threadID, refreshesCachedRecord: true)
    }

    private func lookUpThread(
        threadID: ChannelID,
        refreshesCachedRecord: Bool
    ) async throws -> ForumPost {
        for attempt in 0 ..< 2 {
            if !refreshesCachedRecord, let cached = cachedForumPost(threadID: threadID) {
                return cached
            }
            let recordRevision = threadRecordRevisions[threadID]
            let membershipRevision = threadMembershipRevisions[threadID]
            let payload: ChannelDTO = try await request("/channels/\(threadID)")
            guard payload.isThread else {
                throw ChatProviderError.invalidRequest("That link does not point to a thread.")
            }
            var post = try payload.forumPost(fallbackGuildID: nil)
            let membershipIsCurrent = threadMembershipRevisions[threadID] == membershipRevision
            if let current = cachedForumPost(threadID: threadID) {
                return reconcileLookedUpThread(
                    post,
                    with: current,
                    recordIsCurrent: threadRecordRevisions[threadID] == recordRevision,
                    membershipIsCurrent: membershipIsCurrent
                )
            }
            // The record was deleted while the request was pending.
            guard threadRecordRevisions[threadID] == recordRevision else {
                throw ChatProviderError.channelNotFound
            }
            if !membershipIsCurrent {
                guard attempt == 1 else { continue }
                // Still moving: keep only what the provider itself knows.
                post.thread.notificationSettings = cachedJoinedThreads[threadID]?.notificationSettings
            }
            if let parentID = post.thread.parentID {
                cachedForumPosts[parentID, default: [:]][post.id] = post
            }
            cacheForumPreviewMessages(post)
            return post
        }
        throw ChatProviderError.channelNotFound
    }

    /// Metadata and membership are reconciled separately. The response's
    /// metadata applies unless a thread record superseded the read, keeping
    /// the cache's previews and owner; its member applies unless a membership
    /// event did, since a member-less record is no evidence of leaving.
    private func reconcileLookedUpThread(
        _ response: ForumPost,
        with current: ForumPost,
        recordIsCurrent: Bool,
        membershipIsCurrent: Bool
    ) -> ForumPost {
        var updated = recordIsCurrent
            ? Self.mergingForumPostCatalogueMetadata(incoming: response, existing: current)
            : current
        updated.thread.notificationSettings = membershipIsCurrent
            ? response.thread.notificationSettings
            : current.thread.notificationSettings
        guard updated != current, let parentID = current.thread.parentID else { return current }
        // A read that changes state invalidates older reads, never a pending mutation.
        advanceThreadRecordRevision(
            updated.id,
            includesMembership: updated.thread.notificationSettings != current.thread.notificationSettings,
            authoritative: false
        )
        cachedForumPosts[parentID]?[updated.id] = updated
        let settings = updated.thread.notificationSettings
        if settings == nil {
            cachedJoinedThreads[updated.id] = nil
            cachedJoinedThreadOrder.removeAll { $0 == updated.id }
        } else {
            reconcileJoinedThread(updated.thread)
        }
        publishForumPosts(parentID: parentID)
        publishActiveJoinedThreads()
        return updated
    }

    func cachedForumPost(threadID: ChannelID) -> ForumPost? {
        cachedForumPosts.values.lazy.compactMap { $0[threadID] }.first
    }

    /// Every accepted membership change advances the revision that
    /// invalidates reads in flight. An `authoritative` change, a Gateway
    /// event or a local join/leave, also supersedes a pending one.
    @discardableResult
    func advanceThreadMembershipRevision(_ threadID: ChannelID, authoritative: Bool = true) -> UInt64 {
        let revision = (threadMembershipRevisions[threadID] ?? 0) &+ 1
        threadMembershipRevisions[threadID] = revision
        if authoritative { threadMembershipEpochs[threadID] = (threadMembershipEpochs[threadID] ?? 0) &+ 1 }
        return revision
    }

    func advanceThreadRecordRevision(_ threadID: ChannelID, includesMembership: Bool, authoritative: Bool = true) {
        threadRecordRevisions[threadID] = (threadRecordRevisions[threadID] ?? 0) &+ 1
        if authoritative { threadRecordEpochs[threadID] = (threadRecordEpochs[threadID] ?? 0) &+ 1 }
        if includesMembership { advanceThreadMembershipRevision(threadID, authoritative: authoritative) }
    }

    public func createForumPost(
        _ draft: CreateForumPostDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> ForumPost {
        try requireGuildCommunication(in: draft.channelID)
        guard
            let channel = cachedChannels.values.lazy.flatMap(\.self).first(where: {
                $0.id == draft.channelID && $0.kind == .forum
            })
        else { throw ChatProviderError.channelNotFound }
        guard let title = ThreadNamePolicy.validatedName(draft.title) else {
            throw ChatProviderError.invalidRequest(
                "Post titles must be between 1 and 100 characters.")
        }
        guard draft.content.count <= 2_000 else {
            throw ChatProviderError.invalidRequest("Post messages cannot exceed 2,000 characters.")
        }
        guard
            !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.attachments.isEmpty
        else {
            throw ChatProviderError.invalidRequest("Add a message or attachment before posting.")
        }
        guard draft.attachments.count <= 10 else {
            throw ChatProviderError.invalidRequest("A post can contain at most 10 attachments.")
        }
        guard draft.attachments.allSatisfy({
            !$0.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ChatProviderError.invalidRequest("Attachment filenames cannot be empty.")
        }
        guard draft.attachments.allSatisfy({ $0.description.count <= 1_024 }) else {
            throw ChatProviderError.invalidRequest(
                "Attachment descriptions cannot exceed 1,024 characters.")
        }
        guard Self.validForumAutoArchiveDurations.contains(draft.autoArchiveDuration) else {
            throw ChatProviderError.invalidRequest("The selected auto-archive duration is invalid.")
        }
        let selectedTags = Self.orderedUniqueForumTagIDs(
            draft.appliedTagIDs,
            availableTags: channel.availableTags
        )
        guard selectedTags.count <= 5 else {
            throw ChatProviderError.invalidRequest("A forum post can use at most 5 tags.")
        }
        guard Set(selectedTags) == Set(draft.appliedTagIDs) else {
            throw ChatProviderError.invalidRequest("One or more selected tags are unavailable.")
        }
        guard !channel.requiresForumTag || !selectedTags.isEmpty else {
            throw ChatProviderError.invalidRequest("Select at least one tag before posting.")
        }
        progress(.preparing)
        // Build 649389 omits `sticker_ids`, and SakuraCord does not expose
        // forum sticker sending.
        var message: [String: JSONValue] = ["content": .string(draft.content)]
        if !draft.attachments.isEmpty {
            message["attachments"] = try await .array(
                uploadForumAttachments(
                    draft.attachments, channelID: draft.channelID, progress: progress
                )
            )
        }
        let body: [String: JSONValue] = [
            "name": .string(title),
            "auto_archive_duration": .number(Double(draft.autoArchiveDuration)),
            "applied_tags": .array(selectedTags.map { .string($0.description) }),
            "message": .object(message),
        ]
        progress(.submitting)
        let baseline = threadRevisionBaseline()
        let dto: ChannelDTO = try await request(
            "/channels/\(draft.channelID)/threads",
            method: "POST",
            query: [URLQueryItem(name: "use_nested_fields", value: "true")],
            body: body
        )
        var post = try dto.forumPost(fallbackGuildID: channel.guildID)
        if post.owner == nil { post.owner = currentUser }
        post.thread = try commitCreatedThread(post, respondedMember: dto.member != nil, since: baseline)
        post = cachedForumPosts[draft.channelID]?[post.id] ?? post
        progress(.completed(messageID: MessageID(rawValue: post.id.rawValue)))
        return post
    }

    /// Mirrors the first-party composer Plus Button and message Create Thread
    /// actions. The starter message is an ordinary send to the returned thread.
    public func createThread(_ draft: CreateThreadDraft) async throws -> MessageThreadSummary {
        try requireGuildCommunication(in: draft.channelID)
        guard
            let channel = cachedChannels.values.lazy.flatMap(\.self).first(where: {
                $0.id == draft.channelID && ($0.kind == .text || $0.kind == .announcement)
            })
        else { throw ChatProviderError.channelNotFound }
        guard let name = ThreadNamePolicy.validatedName(draft.name) else {
            throw ChatProviderError.invalidRequest("Thread names must be between 1 and 100 characters.")
        }
        guard !draft.isPrivate || channel.kind == .text else {
            throw ChatProviderError.invalidRequest("Announcement channels cannot have private threads.")
        }
        guard !draft.isPrivate || draft.starterMessageID == nil else {
            throw ChatProviderError.invalidRequest("Threads started from a message are public.")
        }
        guard Self.validForumAutoArchiveDurations.contains(draft.autoArchiveDuration) else {
            throw ChatProviderError.invalidRequest("The selected auto-archive duration is invalid.")
        }
        let type = draft.isPrivate ? 12 : (channel.kind == .announcement ? 10 : 11)
        let location = if draft.starterMessageID != nil {
            "Message"
        } else if draft.isFromThreadBrowser {
            "Thread Browser Toolbar"
        } else {
            "Plus Button"
        }
        let baseline = threadRevisionBaseline()
        let dto: ChannelDTO = try await request(
            Self.threadCreationPath(parentID: draft.channelID, starterMessageID: draft.starterMessageID),
            method: "POST",
            body: [
                "name": .string(name),
                "type": .number(Double(type)),
                "auto_archive_duration": .number(Double(draft.autoArchiveDuration)),
                "location": .string(location),
            ]
        )
        let thread = try commitCreatedThread(
            dto.forumPost(fallbackGuildID: channel.guildID), respondedMember: dto.member != nil, since: baseline
        )
        attachStartedThreadToCachedStarter(thread.id)
        return thread
    }

    nonisolated static func threadCreationPath(parentID: ChannelID, starterMessageID: MessageID?) -> String {
        starterMessageID.map { "/channels/\(parentID)/messages/\($0)/threads" }
            ?? "/channels/\(parentID)/threads"
    }

    public func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async throws
        -> ForumPost
    {
        guard let parentID = post.thread.parentID else {
            throw ChatProviderError.invalidRequest("The forum post has no parent channel.")
        }
        // Edits to one thread run one at a time, so each starts from the
        // previous one's committed record instead of being discarded as stale.
        let previous = threadMutationTails[post.id]
        let (done, finish) = AsyncStream<Never>.makeStream()
        let tail = Task { for await _ in done {} }
        threadMutationTails[post.id] = tail
        defer {
            finish.finish()
            if threadMutationTails[post.id] == tail { threadMutationTails[post.id] = nil }
        }
        await previous?.value
        // Each completed PATCH is committed as it returns, so a completed
        // unarchive stays applied when a following change fails.
        var working = cachedForumPosts[parentID]?[post.id] ?? post
        try await applyForumPostMutation(mutation, parentID: parentID, to: &working)
        return working
    }

    private func applyForumPostMutation(
        _ mutation: ForumPostMutation,
        parentID: ChannelID,
        to working: inout ForumPost
    ) async throws {
        switch mutation {
        case .name(let value):
            // The first-party settings save sends its whole form; only the name
            // changes here, so other settings cannot be overwritten with stale values.
            guard let name = ThreadNamePolicy.validatedName(value) else {
                throw ChatProviderError.invalidRequest("Names must be between 1 and 100 characters.")
            }
            if working.thread.isArchived {
                working = try await patchForumPost(working, body: ["archived": .bool(false)])
            }
            working = try await patchForumPost(working, body: ["name": .string(name)])
        case .tags(let tags):
            guard
                let channel = cachedChannels.values.lazy.flatMap(\.self).first(where: {
                    $0.id == parentID && $0.kind == .forum
                })
            else { throw ChatProviderError.channelNotFound }
            let selectedTags = Self.orderedUniqueForumTagIDs(
                tags,
                availableTags: channel.availableTags
            )
            guard selectedTags.count <= 5 else {
                throw ChatProviderError.invalidRequest("A forum post can use at most 5 tags.")
            }
            guard Set(selectedTags) == Set(tags) else {
                throw ChatProviderError.invalidRequest("One or more selected tags are unavailable.")
            }
            guard !channel.requiresForumTag || !selectedTags.isEmpty else {
                throw ChatProviderError.invalidRequest(
                    "This forum requires every post to have at least one tag."
                )
            }
            if working.thread.isArchived {
                working = try await patchForumPost(working, body: ["archived": .bool(false)])
            }
            working = try await patchForumPost(
                working,
                body: ["applied_tags": .array(selectedTags.map { .string($0.description) })]
            )
        case .archived(let value):
            working = try await patchForumPost(working, body: ["archived": .bool(value)])
        case .locked(let value):
            let wasArchived = working.thread.isArchived
            if wasArchived {
                working = try await patchForumPost(working, body: ["archived": .bool(false)])
            }
            working = try await patchForumPost(
                working,
                body: ["locked": .bool(value), "archived": .bool(wasArchived)]
            )
        case .pinned(let value):
            var body: [String: JSONValue] = [
                "flags": .number(
                    Double(
                        value ? working.thread.flags | (1 << 1) : working.thread.flags & ~(1 << 1)))
            ]
            if value, working.thread.isArchived { body["archived"] = .bool(false) }
            working = try await patchForumPost(working, body: body)
        }
    }

    nonisolated static func orderedUniqueForumTagIDs(
        _ selectedTagIDs: [ForumTagID],
        availableTags: [ForumTag]
    ) -> [ForumTagID] {
        let selected = Set(selectedTagIDs)
        return availableTags.lazy.map(\.id).filter(selected.contains)
    }

    nonisolated static let validForumAutoArchiveDurations: Set<Int> = [
        60, 1_440, 4_320, 10_080,
    ]

    public func deleteForumPost(_ post: ForumPost) async throws {
        guard let parentID = post.thread.parentID else {
            throw ChatProviderError.invalidRequest("The forum post has no parent channel.")
        }
        try await requestEmpty(Self.forumPostDeletionPath(postID: post.id), method: "DELETE")
        advanceThreadRecordRevision(post.id, includesMembership: true)
        cachedForumPosts[parentID]?[post.id] = nil
        let messageIDs = cachedMessages.values
            .filter { $0.channelID == post.id }
            .map(\.id)
        for messageID in messageIDs {
            cachedMessages[messageID] = nil
        }
        publishForumPosts(parentID: parentID)
    }

    public func updateForumPostNotificationLevel(
        _ post: ForumPost,
        level: MessageNotificationLevel
    ) async throws {
        var settings = try await joinedThreadNotificationSettings(for: post)
        settings.flags = settings.flags(setting: level)
        try await patchThreadNotificationSettings(
            threadID: post.id,
            body: ["flags": .number(Double(settings.flags))]
        )
        updateCachedThreadNotificationSettings(settings, for: post)
    }

    public func updateForumPostMute(
        _ post: ForumPost,
        isMuted: Bool,
        until: Date?
    ) async throws {
        var settings = try await joinedThreadNotificationSettings(for: post)
        var body: [String: JSONValue] = ["muted": .bool(isMuted)]
        if isMuted, let until {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            body["mute_config"] = .object([
                "end_time": .string(formatter.string(from: until)),
            ])
        } else {
            body["mute_config"] = .null
        }
        try await patchThreadNotificationSettings(threadID: post.id, body: body)
        settings.isMuted = isMuted
        settings.muteConfiguration =
            isMuted ? DiscordMuteConfiguration(endTime: until) : nil
        updateCachedThreadNotificationSettings(settings, for: post)
    }

    func joinedThreadNotificationSettings(
        for post: ForumPost
    ) async throws -> ThreadNotificationSettings {
        if let cached = post.thread.parentID.flatMap({
            cachedForumPosts[$0]?[post.id]?.thread.notificationSettings
        }) ?? post.thread.notificationSettings {
            return cached
        }
        // The current Discord client joins an unjoined thread once before it
        // applies member-scoped notification settings.
        try await requestEmpty(
            "/channels/\(post.id)/thread-members/@me",
            method: "POST",
            query: [
                URLQueryItem(
                    name: "location",
                    value: "Change Notification Settings"
                )
            ]
        )
        let joined = ThreadNotificationSettings()
        updateCachedThreadNotificationSettings(joined, for: post)
        return joined
    }

    /// Join/Follow or Leave/Unfollow. Discord's THREAD_MEMBERS_UPDATE carries
    /// the authoritative member; the confirmed response updates the catalogue first.
    public func setThreadMembership(
        threadID: ChannelID,
        isJoined: Bool,
        location: ThreadMembershipLocation
    ) async throws {
        advanceThreadMembershipRevision(threadID)
        let epoch = threadMembershipEpochs[threadID]
        let (data, response) = try await perform(
            "/channels/\(threadID)/thread-members/@me",
            method: isJoined ? "POST" : "DELETE",
            query: [URLQueryItem(name: "location", value: location.rawValue)],
            body: nil
        )
        if Self.discordErrorCode(from: data) == 30033 { throw ChatProviderError.threadMemberLimitReached }
        try validateEmptyResponse(data, response)
        // A Gateway membership event or a newer join/leave supersedes this
        // answer; an overlapping read does not.
        guard threadMembershipEpochs[threadID] == epoch else { return }
        reconcileConfirmedThreadMembership(threadID: threadID, isJoined: isJoined)
    }

    func patchThreadNotificationSettings(
        threadID: ChannelID,
        body: [String: JSONValue]
    ) async throws {
        try await requestEmpty(
            "/channels/\(threadID)/thread-members/@me/settings",
            method: "PATCH",
            body: body
        )
    }

    func updateCachedThreadNotificationSettings(
        _ settings: ThreadNotificationSettings,
        for post: ForumPost
    ) {
        guard let parentID = post.thread.parentID else { return }
        var cached = cachedForumPosts[parentID]?[post.id] ?? post
        cached.thread.notificationSettings = settings
        advanceThreadMembershipRevision(post.id)
        cachedForumPosts[parentID, default: [:]][post.id] = cached
        reconcileJoinedThread(cached.thread)
        publishForumPosts(parentID: parentID)
        publishActiveJoinedThreads()
    }

    nonisolated static func forumPostDeletionPath(postID: ChannelID) -> String {
        "/channels/\(postID)"
    }

    func olderForumPosts(channel: Channel, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        let items = Self.forumCatalogueQueryItems(query: query)
        let baseline = threadRevisionBaseline()
        let result: ForumThreadCatalogueResponseDTO = try await request(
            Self.forumThreadSearchPath(channelID: channel.id), query: items
        )
        let decodedPosts = result.posts(fallbackGuildID: channel.guildID)
        gatewayLogger.debug(
            """
            Forum catalogue decoded threads=\(result.threads.count) skipped=\(result.skippedThreadCount) \
            posts=\(decodedPosts.count) archived=\(decodedPosts.count(where: { $0.thread.isArchived })) \
            hasMore=\(result.hasMore) total=\(result.totalResults ?? -1)
            """
        )
        let posts = ingestForumPosts(decodedPosts, channel: channel, since: baseline)
        // Offsets count Discord's records, including ones that failed to decode.
        let rawCount = result.threads.count + result.skippedThreadCount
        let nextOffset = result.hasMore && rawCount > 0 ? query.offset + rawCount : nil
        // Ingestion drops threads deleted since the request began and takes
        // newer records for reopened ones; both left Discord's archive.
        let archivedAfterIngest = Set(posts.filter(\.thread.isArchived).map(\.id))
        return ForumPostPage(
            posts: posts,
            hasMore: result.hasMore && nextOffset != nil,
            nextOffset: nextOffset,
            totalResults: result.totalResults,
            departedCount: decodedPosts.count { $0.thread.isArchived && !archivedAfterIngest.contains($0.id) }
        )
    }

    func searchedForumPosts(
        channel: Channel,
        query: ForumPostQuery,
        searchText: String
    ) async throws -> ForumPostPage {
        let items = Self.forumNameSearchQueryItems(searchText: searchText, query: query)
        let baseline = threadRevisionBaseline()
        let result: ForumThreadSearchResponseDTO = try await request(
            "/channels/\(channel.id)/threads/search", query: items
        )
        var posts = ingestForumPosts(
            result.posts(fallbackGuildID: channel.guildID), channel: channel, since: baseline
        )
        posts = Self.filteredAndSortedForumPosts(posts, query: query)
        return ForumPostPage(
            posts: posts, hasMore: false, nextOffset: nil, totalResults: result.totalResults
        )
    }

    /// Catalogue and browser records answer the request that started at
    /// `baseline`. A thread record or deletion that arrived meanwhile wins, so
    /// a deleted thread is omitted and a newer record is kept; a membership
    /// event that arrived meanwhile keeps the provider's membership.
    func ingestForumPosts(
        _ incomingPosts: [ForumPost],
        channel: Channel,
        since baseline: ThreadRevisionBaseline
    ) -> [ForumPost] {
        var posts: [ForumPost] = []
        posts.reserveCapacity(incomingPosts.count)
        var joinedThreadsChanged = false
        for var post in incomingPosts {
            let existing = cachedForumPosts[channel.id]?[post.id]
            if threadRecordRevisions[post.id] != baseline.records[post.id] {
                if let existing { posts.append(existing) }
                continue
            }
            let respondedMembership = post.thread.notificationSettings
            if let existing {
                post = Self.mergingForumPostCatalogueMetadata(incoming: post, existing: existing)
            }
            if threadMembershipRevisions[post.id] != baseline.memberships[post.id] {
                post.thread.notificationSettings = existing?.thread.notificationSettings
                    ?? cachedJoinedThreads[post.id]?.notificationSettings
            } else if let respondedMembership,
                      respondedMembership != existing?.thread.notificationSettings
            {
                // A returned member is the server's current membership; record
                // it as a transition so older pending reads cannot undo it.
                advanceThreadMembershipRevision(post.id, authoritative: false)
                reconcileJoinedThread(post.thread)
                joinedThreadsChanged = true
            }
            if post.owner == nil, let ownerID = post.thread.ownerID,
               let ownerDTO = cachedGatewayUsersByID[ownerID.description]
            {
                post.owner = try? ownerDTO.domain()
            }
            cachedForumPosts[channel.id, default: [:]][post.id] = post
            cacheForumPreviewMessages(post)
            posts.append(post)
        }
        if joinedThreadsChanged { publishActiveJoinedThreads() }
        return posts
    }

    nonisolated static func mergingForumPostCatalogueMetadata(
        incoming: ForumPost,
        existing: ForumPost
    ) -> ForumPost {
        var merged = incoming
        if incoming.firstMessage == nil, !incoming.isFirstMessageLoaded {
            merged.firstMessage = existing.firstMessage
            merged.isFirstMessageLoaded = existing.isFirstMessageLoaded
        }
        merged.mostRecentMessage = incoming.mostRecentMessage ?? existing.mostRecentMessage
        merged.thread.lastNonMessageActivityAt = incoming.thread.lastNonMessageActivityAt
            ?? existing.thread.lastNonMessageActivityAt
        merged.owner = incoming.owner ?? existing.owner
        merged.isUnread = existing.isUnread
        if merged.thread.notificationSettings == nil {
            merged.thread.notificationSettings = existing.thread.notificationSettings
        }
        return merged
    }

    nonisolated static func forumCatalogueQueryItems(query: ForumPostQuery)
        -> [URLQueryItem]
    {
        var items = [
            URLQueryItem(name: "archived", value: "true"),
            URLQueryItem(
                name: "sort_by",
                value: query.sortOrder == .latestActivity ? "last_message_time" : "creation_time"
            ),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "limit", value: String(min(query.limit, 25))),
        ]
        appendForumTagQueryItems(to: &items, query: query)
        items.append(URLQueryItem(name: "offset", value: String(query.offset)))
        return items
    }

    nonisolated static func forumThreadSearchPath(channelID: ChannelID) -> String {
        "/channels/\(channelID)/threads/search"
    }

    nonisolated static func forumNameSearchQueryItems(
        searchText: String,
        query: ForumPostQuery
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(
                name: "name",
                value: searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        ]
        appendForumTagQueryItems(to: &items, query: query)
        return items
    }

    nonisolated static func appendForumTagQueryItems(
        to items: inout [URLQueryItem],
        query: ForumPostQuery
    ) {
        if !query.selectedTagIDs.isEmpty {
            let value = query.selectedTagIDs.map(\.description).sorted().joined(separator: ",")
            items.append(URLQueryItem(name: "tag", value: value))
        }
        items.append(URLQueryItem(name: "tag_setting", value: query.tagMatch.rawValue))
    }

    func scheduleForumPostPreviewHydration(
        parentID: ChannelID,
        postIDs: [ChannelID]
    ) {
        let supersededParentIDs = forumPreviewHydrationTasks.keys.filter { $0 != parentID }
        for supersededParentID in supersededParentIDs {
            forumPreviewHydrationTasks.removeValue(forKey: supersededParentID)?.cancel()
            forumPreviewHydrationTaskIDs[supersededParentID] = nil
            forumPreviewHydrationQueues[supersededParentID] = nil
        }
        let missingIDs = postIDs.lazy.filter {
            self.cachedForumPosts[parentID]?[$0].map { $0.firstMessage == nil && !$0.isFirstMessageLoaded } ?? false
        }
        forumPreviewHydrationQueues[parentID, default: ForumPreviewHydrationQueue()]
            .enqueue(missingIDs)
        guard forumPreviewHydrationQueues[parentID]?.isEmpty == false else { return }
        guard forumPreviewHydrationTasks[parentID] == nil else { return }
        let taskID = UUID()
        forumPreviewHydrationTaskIDs[parentID] = taskID
        forumPreviewHydrationTasks[parentID] = Task { [weak self] in
            await self?.hydratePendingForumPostMessages(parentID: parentID, taskID: taskID)
        }
    }

    func hydratePendingForumPostMessages(parentID: ChannelID, taskID: UUID) async {
        defer {
            if forumPreviewHydrationTaskIDs[parentID] == taskID {
                forumPreviewHydrationTasks[parentID] = nil
                forumPreviewHydrationTaskIDs[parentID] = nil
                forumPreviewHydrationQueues[parentID] = nil
            }
        }
        while !Task.isCancelled {
            guard forumPreviewHydrationQueues[parentID]?.isEmpty == false else {
                return
            }
            let batch = forumPreviewHydrationQueues[parentID]?.nextBatch(limit: 10) ?? []
            guard !batch.isEmpty else { return }
            let response: ForumPostDataResponseDTO
            do {
                response = try await request(
                    "/channels/\(parentID)/post-data",
                    method: "POST",
                    body: ["thread_ids": .array(batch.map { .string($0.description) })]
                )
            } catch {
                if Task.isCancelled { return }
                forumPreviewHydrationQueues[parentID]?.complete(batch)
                gatewayLogger.warning(
                    "Forum post preview hydration failed for channel \(parentID); retaining catalogue records"
                )
                continue
            }
            var changed: [ForumPost] = []
            changed.reserveCapacity(response.threads.count)
            for (id, data) in response.threads {
                guard let channelID = ChannelID(id),
                      var post = cachedForumPosts[parentID]?[channelID]
                else { continue }
                if let message = try? data.firstMessage?.domain() {
                    post.firstMessage = message
                    post.isFirstMessageLoaded = true
                } else if data.firstMessage == nil {
                    post.firstMessage = nil
                    post.isFirstMessageLoaded = true
                }
                if let message = try? data.mostRecentMessage?.domain() {
                    post.mostRecentMessage = message
                }
                cachedForumPosts[parentID, default: [:]][channelID] = post
                cacheForumPreviewMessages(post)
                changed.append(post)
            }
            forumPreviewHydrationQueues[parentID]?.complete(batch)
            if !changed.isEmpty {
                continuation?.yield(
                    .forumPostPreviewsChanged(channelID: parentID, posts: changed)
                )
            }
        }
    }

    func patchForumPost(_ post: ForumPost, body: [String: JSONValue]) async throws
        -> ForumPost
    {
        let epoch = threadRecordEpochs[post.id]
        let membershipRevision = threadMembershipRevisions[post.id]
        let dto: ChannelDTO = try await request(
            "/channels/\(post.id)", method: "PATCH", body: body
        )
        var updated = try dto.forumPost(fallbackGuildID: post.thread.guildID)
        updated.firstMessage = post.firstMessage
        updated.mostRecentMessage = post.mostRecentMessage
        updated.owner = post.owner
        updated.isUnread = post.isUnread
        guard let parentID = updated.thread.parentID ?? post.thread.parentID else { return updated }
        let cached = cachedForumPosts[parentID]?[post.id]
        // A Gateway record or deletion that arrived meanwhile is authoritative.
        // Discord sends THREAD_UPDATE before answering, so it usually holds this
        // change; a record that is gone was deleted while the request was pending.
        guard threadRecordEpochs[post.id] == epoch else {
            guard let cached else { throw ChatProviderError.channelNotFound }
            return cached
        }
        // The provider's latest membership, including a removal; the caller's
        // copy only for a thread the provider has never known.
        let latestMembership = cached.map(\.thread.notificationSettings)
            ?? cachedJoinedThreads[post.id]?.notificationSettings
        let respondedMembership = dto.member == nil ? nil : updated.thread.notificationSettings
        if let cached {
            updated = Self.mergingForumPostCatalogueMetadata(incoming: updated, existing: cached)
        }
        if threadMembershipRevisions[post.id] != membershipRevision {
            // A membership event arrived meanwhile; whatever this response
            // carries is older.
            updated.thread.notificationSettings = latestMembership
        } else if let respondedMembership {
            updated.thread.notificationSettings = respondedMembership
            if respondedMembership != latestMembership {
                advanceThreadMembershipRevision(post.id, authoritative: false)
            }
        } else {
            // A response without `member` carries no membership.
            updated.thread.notificationSettings = cached == nil
                ? post.thread.notificationSettings : latestMembership
        }
        // An accepted mutation invalidates older reads before it is published.
        advanceThreadRecordRevision(post.id, includesMembership: false)
        cachedForumPosts[parentID, default: [:]][post.id] = updated
        reconcileJoinedThread(updated.thread)
        publishForumPosts(parentID: parentID)
        publishActiveJoinedThreads()
        return updated
    }

    func publishForumPosts(parentID: ChannelID) {
        var remaining = cachedForumPosts[parentID, default: [:]]
        let posts = cachedForumThreadOrder.compactMap {
            remaining.removeValue(forKey: $0)
        } + remaining.values.sorted { $0.id < $1.id }
        continuation?.yield(.forumPostsChanged(channelID: parentID, posts: posts))
    }

    func reconcileJoinedThread(_ thread: MessageThreadSummary) {
        if thread.notificationSettings != nil {
            if cachedJoinedThreads[thread.id] == nil {
                cachedJoinedThreadOrder.append(thread.id)
            }
            cachedJoinedThreads[thread.id] = thread
        } else if let existing = cachedJoinedThreads[thread.id] {
            var updated = thread
            updated.notificationSettings = existing.notificationSettings
            cachedJoinedThreads[thread.id] = updated
        }
    }

    func publishActiveJoinedThreads() {
        continuation?.yield(.activeJoinedThreadsChanged(currentActiveJoinedThreads()))
    }

    /// Thread payloads only add or update known threads. Like the official
    /// client's channel and active-thread stores, absence from a Gateway thread
    /// list never removes a thread; THREAD_DELETE, parent or guild removal,
    /// and a fresh READY's reconciliation are the removal authorities.
    func ingestForumThreads(
        _ threadDTOs: [ChannelDTO], fallbackGuildID: GuildID?,
        advancesParentLatestThreadID: Bool = false
    ) {
        if advancesParentLatestThreadID {
            advanceForumParentLatestThreadIDs(
                threadDTOs,
                fallbackGuildID: fallbackGuildID
            )
        }
        var changed = Set<ChannelID>()
        for dto in threadDTOs {
            guard var post = try? dto.forumPost(fallbackGuildID: fallbackGuildID),
                  let parentID = post.thread.parentID
            else { continue }
            if !cachedForumThreadOrder.contains(post.id) {
                cachedForumThreadOrder.append(post.id)
            }
            if post.owner == nil, let ownerID = post.thread.ownerID,
               let ownerDTO = cachedGatewayUsersByID[ownerID.description]
            {
                post.owner = try? ownerDTO.domain()
            }
            if let existing = cachedForumPosts[parentID]?[post.id] {
                post = Self.mergingForumPostCatalogueMetadata(
                    incoming: post,
                    existing: existing
                )
                post.isUnread = existing.isUnread
            } else if let isUnread = forumPostReadStateUnread(post) {
                post.isUnread = isUnread
            }
            advanceThreadRecordRevision(post.id, includesMembership: dto.member != nil)
            cachedForumPosts[parentID, default: [:]][post.id] = post
            reconcileJoinedThread(post.thread)
            cacheForumPreviewMessages(post)
            changed.insert(parentID)
        }
        for parentID in changed {
            publishForumPosts(parentID: parentID)
        }
        publishActiveJoinedThreads()
    }

    func forumPostReadStateUnread(_ post: ForumPost) -> Bool? {
        guard let state = forumReadStates[post.id] else { return nil }
        return state.mentionCount > 0
            || post.thread.lastMessageID.map { lastMessageID in
                state.lastReadMessageID.map { lastMessageID > $0 } ?? true
            } ?? false
    }

    /// A fresh READY lists only the active threads the account has joined.
    /// Threads learned through catalogue pages or linked-thread lookups are
    /// not invalidated by a new session, so they survive while their parent
    /// is still listed in the guild; a removed parent or guild drops them.
    /// READY is authoritative for active membership, so a retained active
    /// thread is unjoined until READY's own thread record restores it.
    /// Private threads are dropped as before: their access follows membership,
    /// which READY's silence cannot settle (the thread may have been left, or
    /// archived while disconnected). A public thread's content follows its
    /// parent, so only its Follow state can be stale, shown as unjoined.
    func restoreForumPostsAfterReady(
        _ previous: (posts: [ChannelID: [ChannelID: ForumPost]], order: [ChannelID]),
        guildID: GuildID
    ) {
        var restoredIDs = Set<ChannelID>()
        for channel in cachedChannels[guildID] ?? [] {
            guard let posts = previous.posts[channel.id], !posts.isEmpty else { continue }
            let publicPosts = posts.filter { !$0.value.thread.isPrivate }
            guard !publicPosts.isEmpty else { continue }
            cachedForumPosts[channel.id] = publicPosts.mapValues { post in
                var post = post
                post.thread.notificationSettings = nil
                if let isUnread = forumPostReadStateUnread(post) {
                    post.isUnread = isUnread
                }
                restoredIDs.insert(post.id)
                return post
            }
        }
        cachedForumThreadOrder.append(contentsOf: previous.order.filter(restoredIDs.contains))
        // Replace projections that still carry the previous session's
        // membership or a dropped private thread.
        for channel in cachedChannels[guildID] ?? [] where previous.posts[channel.id] != nil {
            publishForumPosts(parentID: channel.id)
        }
    }

    func advanceForumParentLatestThreadIDs(
        _ threadDTOs: [ChannelDTO],
        fallbackGuildID: GuildID?
    ) {
        var changedGuildIDs = Set<GuildID>()
        for dto in threadDTOs {
            guard let parentID = dto.parentID.flatMap(ChannelID.init),
                  let threadID = MessageID(dto.id),
                  let guildID = dto.guildID.flatMap(GuildID.init) ?? fallbackGuildID,
                  var channels = cachedChannels[guildID],
                  let index = channels.firstIndex(where: { $0.id == parentID }),
                  channels[index].kind == .forum,
                  channels[index].lastMessageID.map({ $0 < threadID }) ?? true
            else { continue }
            channels[index].lastMessageID = threadID
            cachedChannels[guildID] = channels
            changedGuildIDs.insert(guildID)
        }
        for guildID in changedGuildIDs {
            continuation?.yield(
                .channelsChanged(
                    guildID: guildID,
                    channels: cachedChannels[guildID] ?? []
                )
            )
        }
    }

    /// A thread's starter reference (type 21) arrives from the Gateway
    /// without the message it quotes; use the parent message when known.
    func attachKnownStarterPreview(to message: inout Message) {
        guard message.type == .threadStarter, message.replyPreview == nil,
              let starterID = message.messageReference?.messageID,
              let starter = cachedMessages[starterID]
        else { return }
        message.replyPreview = MessageReplyPreview(message: starter)
    }

    /// A thread-created system message names its thread only through its
    /// reference; attach the known thread so the timeline can draw its card.
    func attachKnownThread(to message: inout Message) {
        guard message.thread == nil,
              let threadID = message.referencedThreadID,
              let thread = cachedForumPosts[message.channelID]?[threadID]?.thread
        else { return }
        message.thread = thread
    }

    /// A thread's newest history page supplies its card preview, as in
    /// Discord's client. Only a newer message republishes the catalogue.
    func recordLoadedThreadLatestMessage(_ message: Message) {
        for (parentID, posts) in cachedForumPosts {
            guard var post = posts[message.channelID] else { continue }
            guard post.mostRecentMessage.map({ message.id > $0.id }) ?? true else { return }
            post.mostRecentMessage = message
            cachedForumPosts[parentID]?[post.id] = post
            publishForumPosts(parentID: parentID)
            return
        }
    }

    func updateForumPostForMessage(
        _ message: Message,
        marksUnread: Bool = false,
        publishesChange: Bool = true
    ) {
        for (parentID, posts) in cachedForumPosts {
            guard var post = posts[message.channelID] else { continue }
            // The type-21 starter reference is not a reply Discord counts.
            let isNewerReply =
                marksUnread
                && message.type != .threadStarter
                && message.id.rawValue != post.id.rawValue
                && (post.thread.lastMessageID.map { message.id > $0 } ?? true)
            if message.id.rawValue == post.id.rawValue || post.firstMessage?.id == message.id {
                post.firstMessage = message
            }
            if post.mostRecentMessage == nil || message.timestamp >= post.lastActivityAt {
                post.mostRecentMessage = message
                post.thread.lastMessageID = message.id
            }
            if isNewerReply {
                post.thread.messageCount += 1
                post.thread.totalMessageSent += 1
            }
            if marksUnread,
               message.author.id != currentUser?.id,
               forumReadStates[post.id]?.lastReadMessageID.map({ message.id > $0 }) ?? true
            {
                post.isUnread = true
            }
            cachedForumPosts[parentID]?[post.id] = post
            if publishesChange {
                publishForumPosts(parentID: parentID)
            }
            return
        }
    }

    func applyGatewayReactionUpdate(_ update: MessageReactionUpdate) {
        invalidateReactionReactors(channelID: update.channelID, messageID: update.messageID, reactionID: update.reactionID)
        if var message = cachedMessages[update.messageID] {
            if message.applyReactionUpdate(update, currentUserID: currentUser?.id) {
                cachedMessages[message.id] = message
                updateForumPostForMessage(message, publishesChange: false)
            }
        } else {
            // Forum previews outlive the working set. Update each retained value
            // once, without replaying a delta already applied through that set.
            for (parentID, posts) in cachedForumPosts {
                guard var post = posts[update.channelID] else { continue }
                if var message = post.firstMessage, message.id == update.messageID {
                    _ = message.applyReactionUpdate(update, currentUserID: currentUser?.id)
                    post.firstMessage = message
                }
                if var message = post.mostRecentMessage, message.id == update.messageID {
                    _ = message.applyReactionUpdate(update, currentUserID: currentUser?.id)
                    post.mostRecentMessage = message
                }
                cachedForumPosts[parentID]?[post.id] = post
            }
        }
        continuation?.yield(.messageReactionUpdated(update))
    }

    func cacheForumPreviewMessages(_ post: ForumPost) {
        if let firstMessage = post.firstMessage {
            cachedMessages[firstMessage.id] = firstMessage
        }
        if let mostRecentMessage = post.mostRecentMessage {
            cachedMessages[mostRecentMessage.id] = mostRecentMessage
        }
    }

    static func filteredAndSortedForumPosts(
        _ posts: [ForumPost], query: ForumPostQuery
    ) -> [ForumPost] {
        ForumPostQueryPolicy.filteredAndSorted(
            posts,
            selectedTagIDs: query.selectedTagIDs,
            tagMatch: query.tagMatch,
            sortOrder: query.sortOrder
        )
    }

    nonisolated static func mergedForumCataloguePage(
        cachedPosts: [ForumPost],
        olderPage: ForumPostPage,
        query: ForumPostQuery
    ) -> ForumPostPage {
        var posts = olderPage.posts
        if query.offset == 0 {
            let activePosts = cachedPosts.filter { !$0.thread.isArchived }
            var byID = Dictionary(uniqueKeysWithValues: activePosts.map { ($0.id, $0) })
            for post in olderPage.posts {
                byID[post.id] = post
            }
            posts = Array(byID.values)
        }
        return ForumPostPage(
            posts: filteredAndSortedForumPosts(posts, query: query),
            hasMore: olderPage.hasMore,
            nextOffset: olderPage.nextOffset
        )
    }

    public func sendTyping(in channelID: ChannelID) async throws {
        try requireGuildCommunication(in: channelID)
        let channel = cachedChannels.values.lazy.flatMap(\.self).first { $0.id == channelID }
        guard let channel else { throw ChatProviderError.channelNotFound }
        guard channel.kind != .voice, channel.kind != .forum, channel.kind != .unknown else {
            throw ChatProviderError.invalidRequest("Typing is unavailable in this channel.")
        }
        // Discord documents this mutation as an empty POST returning 204. It goes
        // through the shared scheduler and, like every mutation, is attempted once.
        try await requestEmpty("/channels/\(channelID)/typing", method: "POST")
    }

    public func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?
    ) async throws -> ReadAcknowledgementResponse {
        try await acknowledge(
            channelID: channelID,
            messageID: messageID,
            token: token,
            manual: false,
            mentionCount: nil,
            flags: nil,
            lastViewed: nil
        )
    }

    public func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?,
        manual: Bool,
        mentionCount: Int?,
        flags: UInt64?,
        lastViewed: Int?
    ) async throws -> ReadAcknowledgementResponse {
        // Mark Unread posts exactly `manual` and the mention count
        // (module 439147, build 649389); a read posts the token and metadata.
        var body: [String: JSONValue]
        if manual {
            body = ["manual": .bool(true), "mention_count": .number(Double(max(0, mentionCount ?? 0)))]
        } else {
            body = ["token": token.map(JSONValue.string) ?? .null]
            if let flags {
                body["flags"] = .number(Double(flags))
            }
            if let lastViewed {
                body["last_viewed"] = .number(Double(lastViewed))
            }
        }
        let (data, response) = try await perform(
            "/channels/\(channelID)/messages/\(messageID)/ack",
            method: "POST",
            query: [],
            body: body,
            maximumAttempts: 1
        )
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                authorizationValue = nil
                throw apiDiagnostics.coalescing(ChatProviderError.unauthenticated, with: response)
            }
            throw unexplainedFailure(data, response)
        }
        guard !data.isEmpty else { return ReadAcknowledgementResponse(token: token) }
        return try JSONDecoder().decode(ReadAcknowledgementResponse.self, from: data)
    }

    public func updateChannelNotificationLevel(
        guildID: GuildID?,
        channelID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {
        try await updateChannelNotificationSettings(
            guildID: guildID,
            channelID: channelID,
            override: [
                "message_notifications": .number(Double(level.rawValue))
            ]
        )
    }

    public func acknowledgeBulk(
        _ readStates: [BulkReadStateAcknowledgement]
    ) async throws {
        for (index, batch) in readStates.chunked(maximumCount: 100).enumerated() {
            if index > 0 {
                // Discord's BULK_ACK queue spaces successful batches by one second.
                try await Task.sleep(for: .seconds(1))
            }
            try await requestEmpty(
                "/read-states/ack-bulk",
                method: "POST",
                body: [
                    "read_states": .array(
                        batch.map { readState in
                            .object([
                                "channel_id": .string(readState.channelID.description),
                                "message_id": .string(readState.messageID.description),
                                "read_state_type": .number(Double(readState.readStateType)),
                            ])
                        }
                    )
                ]
            )
        }
    }

    public func updateGuildNotificationLevel(
        guildID: GuildID,
        level: MessageNotificationLevel
    ) async throws {
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: [
                "message_notifications": .number(Double(level.rawValue))
            ]
        )
    }

    public func updateGuildMute(
        guildID: GuildID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        var settings: [String: JSONValue] = ["muted": .bool(isMuted)]
        if isMuted, let until {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            settings["mute_config"] = .object([
                "end_time": .string(formatter.string(from: until)),
            ])
        } else {
            settings["mute_config"] = .null
        }
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: settings
        )
    }

    public func updateGuildNotificationToggle(
        guildID: GuildID,
        toggle: GuildNotificationToggle,
        isEnabled: Bool
    ) async throws {
        let setting: (key: String, value: JSONValue) = switch toggle {
        case .suppressEveryone:
            ("suppress_everyone", .bool(isEnabled))
        case .suppressRoles:
            ("suppress_roles", .bool(isEnabled))
        case .suppressHighlights:
            (
                "notify_highlights",
                .number(Double(
                    isEnabled
                        ? GuildHighlightNotificationLevel.disabled.rawValue
                        : GuildHighlightNotificationLevel.inherit.rawValue
                ))
            )
        case .muteScheduledEvents:
            ("mute_scheduled_events", .bool(isEnabled))
        case .mobilePush:
            ("mobile_push", .bool(isEnabled))
        case .hideMutedChannels:
            ("hide_muted_channels", .bool(isEnabled))
        }
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: [setting.key: setting.value]
        )
    }
}

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map { start in
            Array(self[start ..< Swift.min(start + maximumCount, count)])
        }
    }
}
