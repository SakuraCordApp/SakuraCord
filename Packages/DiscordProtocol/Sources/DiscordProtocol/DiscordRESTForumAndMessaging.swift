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
            if query.offset == 0, !cachedPosts.isEmpty {
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
                let page = Self.mergedForumCataloguePage(
                    cachedPosts: cachedPosts,
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
                guard !cachedPosts.isEmpty else { throw error }
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

    public func forumPost(threadID: ChannelID) async throws -> ForumPost {
        for posts in cachedForumPosts.values {
            if let post = posts[threadID] {
                return post
            }
        }
        let payload: ChannelDTO = try await request("/channels/\(threadID)")
        guard payload.isThread else {
            throw ChatProviderError.invalidRequest("That link does not point to a thread.")
        }
        let post = try payload.forumPost(fallbackGuildID: nil)
        if let parentID = post.thread.parentID {
            cachedForumPosts[parentID, default: [:]][post.id] = post
        }
        cacheForumPreviewMessages(post)
        return post
    }

    public func createForumPost(
        _ draft: CreateForumPostDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> ForumPost {
        guard
            let channel = cachedChannels.values.lazy.flatMap(\.self).first(where: {
                $0.id == draft.channelID && $0.kind == .forum
            })
        else { throw ChatProviderError.channelNotFound }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 100).contains(title.count) else {
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
        var message: [String: JSONValue] = [
            "content": .string(draft.content),
            // The current first-party nested forum-post action always includes
            // the selected sticker list. SakuraCord does not expose forum
            // sticker sending, so the exact supported shape is an empty list.
            "sticker_ids": .array([]),
        ]
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
        let dto: ChannelDTO = try await request(
            "/channels/\(draft.channelID)/threads",
            method: "POST",
            query: [URLQueryItem(name: "use_nested_fields", value: "true")],
            body: body
        )
        var post = try dto.forumPost(fallbackGuildID: channel.guildID)
        if post.owner == nil { post.owner = currentUser }
        cachedForumPosts[draft.channelID, default: [:]][post.id] = post
        cacheForumPreviewMessages(post)
        publishForumPosts(parentID: draft.channelID)
        progress(.completed(messageID: MessageID(rawValue: post.id.rawValue)))
        return post
    }

    public func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async throws
        -> ForumPost
    {
        guard let parentID = post.thread.parentID else {
            throw ChatProviderError.invalidRequest("The forum post has no parent channel.")
        }
        var working = post
        switch mutation {
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
        cachedForumPosts[parentID, default: [:]][working.id] = working
        publishForumPosts(parentID: parentID)
        return working
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
        cachedForumPosts[parentID, default: [:]][post.id] = cached
        publishForumPosts(parentID: parentID)
    }

    nonisolated static func forumPostDeletionPath(postID: ChannelID) -> String {
        "/channels/\(postID)"
    }

    func olderForumPosts(channel: Channel, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        let items = Self.forumCatalogueQueryItems(query: query)
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
        let posts = ingestForumPosts(decodedPosts, channel: channel)
        let nextOffset = result.hasMore && !result.threads.isEmpty
            ? query.offset + result.threads.count
            : nil
        return ForumPostPage(
            posts: posts,
            hasMore: result.hasMore && nextOffset != nil,
            nextOffset: nextOffset
        )
    }

    func searchedForumPosts(
        channel: Channel,
        query: ForumPostQuery,
        searchText: String
    ) async throws -> ForumPostPage {
        let items = Self.forumNameSearchQueryItems(searchText: searchText, query: query)
        let result: ForumThreadSearchResponseDTO = try await request(
            "/channels/\(channel.id)/threads/search", query: items
        )
        var posts = ingestForumPosts(
            result.posts(fallbackGuildID: channel.guildID), channel: channel
        )
        posts = Self.filteredAndSortedForumPosts(posts, query: query)
        return ForumPostPage(posts: posts, hasMore: false, nextOffset: nil)
    }

    func ingestForumPosts(
        _ incomingPosts: [ForumPost],
        channel: Channel
    ) -> [ForumPost] {
        var posts = incomingPosts
        for index in posts.indices {
            if let existing = cachedForumPosts[channel.id]?[posts[index].id] {
                posts[index] = Self.mergingForumPostCatalogueMetadata(
                    incoming: posts[index],
                    existing: existing
                )
            }
            if posts[index].owner == nil, let ownerID = posts[index].thread.ownerID,
               let ownerDTO = cachedGatewayUsersByID[ownerID.description]
            {
                posts[index].owner = try? ownerDTO.domain()
            }
            cachedForumPosts[channel.id, default: [:]][posts[index].id] = posts[index]
            cacheForumPreviewMessages(posts[index])
        }
        return posts
    }

    nonisolated static func mergingForumPostCatalogueMetadata(
        incoming: ForumPost,
        existing: ForumPost
    ) -> ForumPost {
        var merged = incoming
        if let firstMessage = incoming.firstMessage {
            merged.firstMessage = firstMessage.preservingReactionReactors(
                from: existing.firstMessage ?? firstMessage
            )
        } else {
            merged.firstMessage = existing.firstMessage
        }
        if let mostRecentMessage = incoming.mostRecentMessage {
            merged.mostRecentMessage = mostRecentMessage.preservingReactionReactors(
                from: existing.mostRecentMessage ?? mostRecentMessage
            )
        } else {
            merged.mostRecentMessage = existing.mostRecentMessage
        }
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
            self.cachedForumPosts[parentID]?[$0]?.firstMessage == nil
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
                    post.firstMessage = message.preservingReactionReactors(
                        from: post.firstMessage ?? message
                    )
                }
                if let message = try? data.mostRecentMessage?.domain() {
                    post.mostRecentMessage = message.preservingReactionReactors(
                        from: post.mostRecentMessage ?? message
                    )
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
        let dto: ChannelDTO = try await request(
            "/channels/\(post.id)", method: "PATCH", body: body
        )
        var updated = try dto.forumPost(fallbackGuildID: post.thread.guildID)
        updated.firstMessage = post.firstMessage
        updated.mostRecentMessage = post.mostRecentMessage
        updated.owner = post.owner
        updated.isUnread = post.isUnread
        return updated
    }

    func publishForumPosts(parentID: ChannelID) {
        let posts = Array(cachedForumPosts[parentID, default: [:]].values)
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

    func ingestForumThreads(
        _ threadDTOs: [ChannelDTO], fallbackGuildID: GuildID?,
        replacingParents: Set<ChannelID>? = nil,
        advancesParentLatestThreadID: Bool = false
    ) {
        if advancesParentLatestThreadID {
            advanceForumParentLatestThreadIDs(
                threadDTOs,
                fallbackGuildID: fallbackGuildID
            )
        }
        if let replacingParents {
            for parentID in replacingParents {
                cachedForumPosts[parentID] = cachedForumPosts[parentID, default: [:]].filter {
                    Self.shouldPreserveForumPostDuringThreadListReplacement($0.value)
                }
            }
        }
        var changed = Set<ChannelID>()
        for dto in threadDTOs {
            guard var post = try? dto.forumPost(fallbackGuildID: fallbackGuildID),
                  let parentID = post.thread.parentID
            else { continue }
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
            } else if let state = forumReadStates[post.id] {
                post.isUnread =
                    state.mentionCount > 0
                        || post.thread.lastMessageID.map { lastMessageID in
                            state.lastReadMessageID.map { lastMessageID > $0 } ?? true
                        } ?? false
            }
            cachedForumPosts[parentID, default: [:]][post.id] = post
            reconcileJoinedThread(post.thread)
            cacheForumPreviewMessages(post)
            changed.insert(parentID)
        }
        for parentID in changed.union(replacingParents ?? []) {
            publishForumPosts(parentID: parentID)
        }
        publishActiveJoinedThreads()
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

    nonisolated static func shouldPreserveForumPostDuringThreadListReplacement(
        _ post: ForumPost
    ) -> Bool {
        post.thread.isArchived || post.thread.isLocked
    }

    func updateForumPostForMessage(
        _ message: Message,
        marksUnread: Bool = false,
        publishesChange: Bool = true
    ) {
        for (parentID, posts) in cachedForumPosts {
            guard var post = posts[message.channelID] else { continue }
            let isNewerReply =
                marksUnread
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
        if var message = cachedMessages[update.messageID],
           message.applyReactionUpdate(update, currentUserID: currentUser?.id)
        {
            cachedMessages[message.id] = message
            updateForumPostForMessage(message, publishesChange: false)
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
        var body: [String: JSONValue] = ["token": .null]
        if let token {
            body["token"] = .string(token)
        }
        if manual {
            body["manual"] = .bool(true)
            body["mention_count"] = .number(Double(max(0, mentionCount ?? 0)))
        }
        if let flags {
            body["flags"] = .number(Double(flags))
        }
        if let lastViewed {
            body["last_viewed"] = .number(Double(lastViewed))
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
                throw ChatProviderError.unauthenticated
            }
            throw ChatProviderError.transport(
                status: response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            )
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
        var acceptedReadStates: [BulkReadStateAcknowledgement] = []
        for batch in readStates.chunked(maximumCount: 100) {
            do {
                try await requestEmpty(
                    "/read-states/ack-bulk",
                    method: "POST",
                    body: [
                        "read_states": .array(
                            batch.map { readState in
                                .object([
                                    "channel_id": .string(readState.channelID.description),
                                    "message_id": .string(readState.messageID.description),
                                    "read_state_type": .number(0),
                                ])
                            }
                        )
                    ]
                )
                acceptedReadStates.append(contentsOf: batch)
            } catch {
                guard !acceptedReadStates.isEmpty else { throw error }
                throw PartialBulkReadAcknowledgementError(
                    acceptedReadStates: acceptedReadStates,
                    failureDescription: error.localizedDescription
                )
            }
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

    func updateGuildNotificationSettings(
        guildID: GuildID,
        settings: [String: JSONValue]
    ) async throws {
        // The current first-party client sends one partial guild entry through
        // the bulk user-guild settings route and reconciles the accepted value
        // through USER_GUILD_SETTINGS_UPDATE.
        try await requestEmpty(
            "/users/@me/guilds/settings",
            method: "PATCH",
            body: [
                "guilds": .object([
                    guildID.description: .object(settings),
                ])
            ]
        )
    }

    public func updateChannelMute(
        guildID: GuildID?,
        channelID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        var override: [String: JSONValue] = [
            "muted": .bool(isMuted)
        ]
        if isMuted {
            let muteConfiguration: JSONValue
            if let until {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                muteConfiguration = .object([
                    "end_time": .string(formatter.string(from: until)),
                ])
            } else {
                muteConfiguration = .null
            }
            override["mute_config"] = muteConfiguration
        } else {
            override["mute_config"] = .null
        }
        try await updateChannelNotificationSettings(
            guildID: guildID,
            channelID: channelID,
            override: override
        )
    }

    func updateChannelNotificationSettings(
        guildID: GuildID?,
        channelID: ChannelID,
        override: [String: JSONValue]
    ) async throws {
        // Discord's current client PATCHes a partial channel override keyed by
        // channel ID. Keep this as a single, centrally scheduled mutation and
        // rely on USER_GUILD_SETTINGS_UPDATE for authoritative reconciliation.
        try await requestEmpty(
            "/users/@me/guilds/\(guildID?.description ?? "@me")/settings",
            method: "PATCH",
            body: [
                "channel_overrides": .object([
                    channelID.description: .object(override)
                ])
            ]
        )
    }

    public func updateCategoryNotificationLevel(
        guildID: GuildID,
        categoryID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {
        try await updateCategoryNotificationSettings(
            guildID: guildID,
            categoryID: categoryID,
            override: [
                "message_notifications": .number(Double(level.rawValue))
            ]
        )
    }

    public func updateCategoryMute(
        guildID: GuildID,
        categoryID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        var override: [String: JSONValue] = [
            "muted": .bool(isMuted),
            "mute_config": .null,
        ]
        if isMuted, let until {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            override["mute_config"] = .object([
                "end_time": .string(formatter.string(from: until)),
            ])
        }
        try await updateCategoryNotificationSettings(
            guildID: guildID,
            categoryID: categoryID,
            override: override
        )
    }

    public func updateCategoryCollapsed(
        guildID: GuildID,
        categoryID: ChannelID,
        isCollapsed: Bool
    ) async throws {
        try await updateCategoryNotificationSettings(
            guildID: guildID,
            categoryID: categoryID,
            override: ["collapsed": .bool(isCollapsed)]
        )
    }

    func updateCategoryNotificationSettings(
        guildID: GuildID,
        categoryID: ChannelID,
        override: [String: JSONValue]
    ) async throws {
        // Category overrides and their collapsed state use the current bulk
        // user-guild settings route, scoped to exactly one guild/category.
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: [
                "channel_overrides": .object([
                    categoryID.description: .object(override)
                ])
            ]
        )
    }

    public func supports(_ capability: ChatCapability) async -> Bool {
        capability == .slashCommands || capability == .forums || capability == .gifs
            || capability == .messageForwarding
    }

    public func applicationCommandCatalog(for target: ApplicationCommandIndexTarget) async throws
        -> ApplicationCommandCatalog
    {
        if let cached = cachedApplicationCommandCatalogs[target] {
            return cached
        }
        if let task = applicationCommandCatalogTasks[target] {
            return try await task.value
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.fetchApplicationCommandCatalog(for: target)
        }
        applicationCommandCatalogTasks[target] = task
        do {
            let catalog = try await task.value
            applicationCommandCatalogTasks[target] = nil
            cachedApplicationCommandCatalogs[target] = catalog
            return catalog
        } catch {
            applicationCommandCatalogTasks[target] = nil
            throw error
        }
    }

    public func requestApplicationCommandAutocomplete(
        _ request: ApplicationCommandAutocompleteRequest
    ) async throws {
        let payload = try ApplicationCommandPayloadBuilder.autocomplete(request)
        guard
            let focused = request.invocation.command.options.first(where: {
                $0.id == request.focusedOptionID
            })
        else {
            throw ChatProviderError.invalidRequest(
                "The focused autocomplete option is unavailable.")
        }
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for command autocomplete."
            )
        }
        var body: [String: JSONValue] = [
            "type": .number(4),
            "application_id": .string(request.invocation.command.applicationID),
            "channel_id": .string(request.invocation.channelID.description),
            "session_id": .string(sessionID),
            "data": .object(payload.data),
            "nonce": .string(request.nonce),
        ]
        if let guildID = request.invocation.guildID {
            body["guild_id"] = .string(guildID.description)
        }
        pendingAutocompleteTypes[request.nonce] = focused.type
        autocompleteTimeoutTasks[request.nonce]?.cancel()
        do {
            let (_, response) = try await perform(
                "/interactions", method: "POST", query: [], body: body
            )
            guard response.statusCode == 204 else {
                pendingAutocompleteTypes[request.nonce] = nil
                throw interactionTransportError(response)
            }
        } catch {
            pendingAutocompleteTypes[request.nonce] = nil
            throw error
        }
        autocompleteTimeoutTasks[request.nonce] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.expireAutocomplete(nonce: request.nonce)
        }
    }

    public func executeApplicationCommand(
        _ invocation: ApplicationCommandInvocation,
        progress: @escaping @Sendable (ApplicationCommandProgress) -> Void
    ) async throws {
        progress(.preparing)
        var payload = try ApplicationCommandPayloadBuilder.execution(invocation)
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for application commands.")
        }
        if !payload.attachmentURLs.isEmpty {
            let descriptors = try await uploadAttachments(
                payload.attachmentURLs,
                channelID: invocation.channelID
            ) { state in
                switch state {
                case .reserving(let files): progress(.reserving(files: files))
                case .uploading(let fileName, let completed, let total):
                    progress(.uploading(fileName: fileName, completed: completed, total: total))
                default: break
                }
            }
            payload.data["attachments"] = .array(descriptors)
        }
        var body: [String: JSONValue] = [
            "type": .number(2),
            "application_id": .string(invocation.command.applicationID),
            "channel_id": .string(invocation.channelID.description),
            "session_id": .string(sessionID),
            "data": .object(payload.data),
            "nonce": .string(invocation.nonce),
            "analytics_location": .string("slash_ui"),
        ]
        if let guildID = invocation.guildID {
            body["guild_id"] = .string(guildID.description)
        }
        progress(.submitting(nonce: invocation.nonce))
        let (_, response) = try await perform(
            "/interactions", method: "POST", query: [], body: body
        )
        guard response.statusCode == 204 else {
            throw interactionTransportError(response)
        }
        progress(.awaitingResponse(nonce: invocation.nonce))
    }

    public func submitModal(_ submission: ModalSubmission, nonce: String) async throws {
        guard let context = pendingModalContexts[nonce] else {
            throw ChatProviderError.invalidRequest("The interaction form is no longer active.")
        }
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for interaction forms.")
        }
        let orderedFileKeys = submission.fileURLs.keys.sorted()
        var attachmentIDsByCustomID: [String: [String]] = [:]
        var allFiles: [URL] = []
        for key in orderedFileKeys {
            let urls = submission.fileURLs[key] ?? []
            attachmentIDsByCustomID[key] = (allFiles.count ..< allFiles.count + urls.count).map(
                String.init)
            allFiles.append(contentsOf: urls)
        }
        var descriptors: [JSONValue] = []
        if !allFiles.isEmpty {
            guard let channelID = ChannelID(context.channelID) else {
                throw ChatProviderError.invalidRequest("The interaction form has no valid channel.")
            }
            descriptors = try await uploadAttachments(
                allFiles, channelID: channelID, progress: { _ in }
            )
        }
        var data: [String: JSONValue] = [
            "custom_id": .string(submission.customID),
            "components": .array(
                context.modal.controls.map {
                    modalResponse(
                        $0, values: submission.values, attachmentIDs: attachmentIDsByCustomID)
                }),
        ]
        if !descriptors.isEmpty {
            data["resolved"] = .object([
                "attachments": .object(
                    Dictionary(
                        uniqueKeysWithValues: descriptors.enumerated().map {
                            (String($0.offset), $0.element)
                        })
                )
            ])
        }
        var body: [String: JSONValue] = [
            "type": .number(5),
            "application_id": .string(context.applicationID),
            "channel_id": .string(context.channelID),
            "session_id": .string(sessionID),
            "data": .object(data),
            "nonce": .string(nonce),
        ]
        if let guildID = context.guildID { body["guild_id"] = .string(guildID) }
        let (_, response) = try await perform(
            "/interactions", method: "POST", query: [], body: body
        )
        guard response.statusCode == 204 else { throw interactionTransportError(response) }
        pendingModalContexts[nonce] = nil
    }

    func fetchApplicationCommandCatalog(for target: ApplicationCommandIndexTarget)
        async throws
        -> ApplicationCommandCatalog
    {
        let path: String =
            switch target {
            case .guild(let id): "/guilds/\(id)/application-command-index"
            case .channel(let id): "/channels/\(id)/application-command-index"
            case .user: "/users/@me/application-command-index"
            case .application(let id): "/applications/\(id)/application-command-index"
            }
        for attempt in 0 ..< 3 {
            let (data, response) = try await perform(
                path, method: "GET", query: [], body: nil, maximumAttempts: 1
            )
            if response.statusCode == 202 {
                guard attempt < 2 else {
                    throw ChatProviderError.transport(
                        status: 202,
                        requestID: response.value(forHTTPHeaderField: "x-request-id")
                    )
                }
                try await Task.sleep(for: .seconds(5))
                continue
            }
            if response.statusCode == 429 {
                guard attempt < 2 else { throw interactionTransportError(response) }
                let delay = Self.retryAfter(from: data, response: response)
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                throw interactionTransportError(response)
            }
            return try ApplicationCommandIndexDecoder.decode(data, target: target)
        }
        throw ChatProviderError.invalidRequest(
            "Discord's application command index did not become ready.")
    }

    func expireAutocomplete(nonce: String) {
        guard pendingAutocompleteTypes.removeValue(forKey: nonce) != nil else { return }
        autocompleteTimeoutTasks[nonce] = nil
        continuation?.yield(
            .interaction(.failed(nonce: nonce, message: "Command autocomplete timed out."))
        )
    }

    func interactionTransportError(_ response: HTTPURLResponse) -> ChatProviderError {
        if response.statusCode == 401 {
            return .unauthenticated
        }
        return .transport(
            status: response.statusCode,
            requestID: response.value(forHTTPHeaderField: "x-request-id")
        )
    }

    func modalResponse(
        _ control: ModalControl,
        values: [String: [String]],
        attachmentIDs: [String: [String]]
    ) -> JSONValue {
        switch control {
        case .label(_, _, _, let child):
            return .object([
                "type": .number(18),
                "component": modalResponse(
                    child, values: values, attachmentIDs: attachmentIDs
                ),
            ])
        case .textInput(_, let customID, _, _, _, _, _, _, _):
            return .object([
                "type": .number(4), "custom_id": .string(customID),
                "value": .string(values[customID]?.first ?? ""),
            ])
        case .select(_, let customID, let kind, _, _, _, _):
            return .object([
                "type": .number(Double(kind.rawValue)), "custom_id": .string(customID),
                "values": .array((values[customID] ?? []).map(JSONValue.string)),
            ])
        case .fileUpload(_, let customID, _, _, _):
            return .object([
                "type": .number(19), "custom_id": .string(customID),
                "values": .array((attachmentIDs[customID] ?? []).map(JSONValue.string)),
            ])
        case .radioGroup(_, let customID, _, _):
            return .object([
                "type": .number(21), "custom_id": .string(customID),
                "value": values[customID]?.first.map(JSONValue.string) ?? .null,
            ])
        case .checkboxGroup(_, let customID, _, _, _):
            return .object([
                "type": .number(22), "custom_id": .string(customID),
                "values": .array((values[customID] ?? []).map(JSONValue.string)),
            ])
        case .checkbox(_, let customID, _, _):
            return .object([
                "type": .number(23), "custom_id": .string(customID),
                "value": .bool(values[customID]?.first == "true"),
            ])
        case .unsupported(_, let type):
            return .object(["type": .number(Double(type))])
        }
    }

    public func send(_ draft: SendMessageDraft) async throws -> Message {
        try await send(draft, progress: { _ in })
    }

    public func ensurePrivateChannel(for userID: UserID) async throws -> Channel {
        if let existing = (cachedChannels[nil] ?? []).first(where: {
            $0.kind == .directMessage && $0.recipients.contains { $0.id == userID }
        }) {
            return existing
        }
        if let task = privateChannelTasks[userID] {
            return try await task.value
        }
        let task = Task { [self] in
            try await createPrivateChannel(for: userID)
        }
        privateChannelTasks[userID] = task
        defer { privateChannelTasks[userID] = nil }
        return try await task.value
    }

    private func createPrivateChannel(for userID: UserID) async throws -> Channel {
        let dto: ChannelDTO = try await request(
            "/users/@me/channels",
            method: "POST",
            body: ["recipients": .array([.string(userID.description)])]
        )
        let channel = try dto.domain(
            guildID: nil,
            knownUsersByID: cachedGatewayUsersByID
        )
        upsertPrivateChannel(channel)
        continuation?.yield(.channelsChanged(
            guildID: nil,
            channels: cachedChannels[nil] ?? []
        ))
        return channel
    }

    public func forward(_ draft: ForwardMessageDraft) async throws -> Message {
        let key = "forward:\(draft.destinationChannelID):\(draft.nonce)"
        if let task = messageSendTasks[key] {
            return try await task.value
        }
        let task = Task { [self] in
            try await performForward(draft)
        }
        messageSendTasks[key] = task
        defer { messageSendTasks[key] = nil }
        return try await task.value
    }

    func performForward(_ draft: ForwardMessageDraft) async throws -> Message {
        let isKnownChannel = cachedChannels.values.lazy.flatMap(\.self).contains(where: {
            $0.id == draft.destinationChannelID
        })
        let isKnownThread = cachedForumPosts.values.contains { posts in
            posts[draft.destinationChannelID] != nil
        }
        guard isKnownChannel || isKnownThread else {
            throw ChatProviderError.channelNotFound
        }
        var reference: [String: JSONValue] = [
            "type": .number(1),
            "message_id": .string(draft.sourceMessageID.description),
            "channel_id": .string(draft.sourceChannelID.description),
        ]
        if let sourceGuildID = draft.sourceGuildID {
            reference["guild_id"] = .string(sourceGuildID.description)
        }
        let body: [String: JSONValue] = [
            "content": .string(""),
            "nonce": .string(draft.nonce),
            "tts": .bool(false),
            "flags": .number(0),
            "mobile_network_type": .string("unknown"),
            "message_reference": .object(reference),
        ]
        let dto: MessageDTO = try await request(
            "/channels/\(draft.destinationChannelID)/messages",
            method: "POST",
            body: body,
            headers: ["X-Context-Properties": DiscordClientMetadata.forwardingContextHeader]
        )
        var message = try dto.domain()
        message.nonce = draft.nonce
        cachedMessages[message.id] = message
        continuation?.yield(.messageCreated(message))
        return message
    }

    public func send(
        _ draft: SendMessageDraft, progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> Message {
        guard draft.attachmentURLs.count <= SendMessageDraft.maximumAttachmentCount else {
            throw ChatProviderError.invalidRequest(
                "A message can include at most \(SendMessageDraft.maximumAttachmentCount) attachments."
            )
        }
        let key = "\(draft.channelID):\(draft.nonce)"
        if let task = messageSendTasks[key] {
            let message = try await task.value
            progress(.completed(messageID: message.id))
            return message
        }
        let task = Task { [self] in
            try await performSend(draft, progress: progress)
        }
        messageSendTasks[key] = task
        do {
            let message = try await task.value
            messageSendTasks[key] = nil
            return message
        } catch {
            messageSendTasks[key] = nil
            throw error
        }
    }

    func performSend(
        _ draft: SendMessageDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> Message {
        progress(.preparing)
        var body: [String: JSONValue] = [
            "content": .string(draft.content),
            "nonce": .string(draft.nonce),
            "enforce_nonce": .bool(true),
            "tts": .bool(false),
            "flags": .number(0),
            // Chromium reports an unknown Network Information API connection
            // type on the current macOS desktop host. The first-party send
            // action forwards that value on every ordinary message POST.
            "mobile_network_type": .string("unknown"),
        ]
        if let replyTo = draft.replyTo {
            body["message_reference"] = .object([
                "type": .number(0),
                "message_id": .string(replyTo.description),
                "channel_id": .string(draft.channelID.description),
            ])
        }
        if !draft.attachmentURLs.isEmpty {
            body["attachments"] = try await .array(
                uploadForumAttachments(
                    draft.attachments, channelID: draft.channelID, progress: progress)
            )
        }
        progress(.submitting)
        let dto: MessageDTO = try await request(
            "/channels/\(draft.channelID)/messages",
            method: "POST",
            body: body,
            headers: ["X-Context-Properties": DiscordClientMetadata.messageContextHeader]
        )
        var message = try dto.domain()
        message.nonce = draft.nonce
        cachedMessages[message.id] = message
        continuation?.yield(.messageCreated(message))
        progress(.completed(messageID: message.id))
        return message
    }

    func uploadAttachments(
        _ urls: [URL], channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [JSONValue] {
        try await uploadAttachmentFiles(
            urls.map { AttachmentUploadFile(url: $0, name: $0.lastPathComponent) },
            channelID: channelID,
            progress: progress
        )
    }

    func uploadForumAttachments(
        _ attachments: [ForumPostAttachment],
        channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [JSONValue] {
        try await uploadAttachmentFiles(
            attachments.map(Self.forumUploadFile),
            channelID: channelID,
            progress: progress
        )
    }

    nonisolated static func forumUploadFile(
        _ attachment: ForumPostAttachment
    ) -> AttachmentUploadFile {
        let chosenName = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = chosenName.isEmpty ? attachment.url.lastPathComponent : chosenName
        let name =
            attachment.isSpoiler && !original.hasPrefix("SPOILER_")
                ? "SPOILER_\(original)" : original
        let description = attachment.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return AttachmentUploadFile(
            url: attachment.url,
            name: name,
            description: description.isEmpty ? nil : description
        )
    }

    nonisolated static func uploadedAttachmentPayload(
        id: Int,
        file: AttachmentUploadFile,
        uploadFilename: String
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "id": .string(String(id)),
            "filename": .string(file.name),
            "uploaded_filename": .string(uploadFilename),
        ]
        if let description = file.description {
            payload["description"] = .string(description)
        }
        return .object(payload)
    }

    var attachmentFileUploadOperation:
        @isolated(any) (
            [AttachmentUploadFile],
            ChannelID,
            @Sendable (MessageSendProgress) -> Void
        ) async throws -> [JSONValue]
    {
        { [self] files, channelID, progress in
        var descriptors: [JSONValue] = []
        let maximumFileSize = DiscordAttachmentUploadPolicy.maximumFileSize(
            premiumType: currentUser?.premiumType ?? 0
        )
        for (index, file) in files.enumerated() {
            let url = file.url
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard Int64(size) <= maximumFileSize else {
                throw ChatProviderError.invalidRequest(
                    "\(file.name) exceeds the account's Discord upload limit."
                )
            }
            descriptors.append(
                .object([
                    "filename": .string(file.name),
                    "file_size": .number(Double(size)),
                    "id": .string(String(index)),
                    "is_clip": .bool(false),
                ])
            )
        }

        progress(.reserving(files: files.count))
        let reservation: AttachmentReservationDTO = try await request(
            "/channels/\(channelID)/attachments",
            method: "POST",
            body: ["files": .array(descriptors)]
        )
        guard reservation.attachments.count == files.count else {
            throw ChatProviderError.invalidRequest(
                "Discord did not reserve every selected attachment.")
        }

        var uploaded: [JSONValue] = []
        for pair in zip(files, reservation.attachments) {
            let (file, slot) = pair
            let fileURL = file.url
            guard let uploadURL = Self.validatedAttachmentUploadURL(
                from: slot.uploadURL
            ) else {
                throw ChatProviderError.invalidRequest(
                    "Discord returned an invalid attachment upload URL.")
            }
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            var uploadRequest = URLRequest(url: uploadURL)
            uploadRequest.httpMethod = "PUT"
            uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let total =
                ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size])
                        as? NSNumber)?
                    .int64Value ?? 0
            progress(.uploading(fileName: file.name, completed: 0, total: total))
            apiDiagnostics.recordHTTPRequest(
                transport: "attachment_storage",
                method: "PUT",
                path: "/attachments/\(slot.id)",
                body: nil,
                attempt: 1
            )
            let uploadStarted = ContinuousClock.now
            let rawResponse: URLResponse
            do {
                (_, rawResponse) = try await session.upload(
                    for: uploadRequest,
                    fromFile: fileURL
                )
            } catch {
                apiDiagnostics.recordHTTPFailure(
                    transport: "attachment_storage",
                    method: "PUT",
                    path: "/attachments/\(slot.id)",
                    attempt: 1,
                    duration: uploadStarted.duration(to: .now),
                    error: error
                )
                throw error
            }
            guard let response = rawResponse as? HTTPURLResponse else {
                let error = ChatProviderError.invalidRequest(
                    "Discord's attachment storage returned an invalid HTTP response."
                )
                apiDiagnostics.recordHTTPFailure(
                    transport: "attachment_storage",
                    method: "PUT",
                    path: "/attachments/\(slot.id)",
                    attempt: 1,
                    duration: uploadStarted.duration(to: .now),
                    error: error
                )
                throw error
            }
            apiDiagnostics.recordHTTPResponse(
                transport: "attachment_storage",
                method: "PUT",
                path: "/attachments/\(slot.id)",
                attempt: 1,
                response: response,
                body: Data(),
                duration: uploadStarted.duration(to: .now)
            )
            guard (200 ..< 300).contains(response.statusCode) else {
                throw ChatProviderError.invalidRequest(
                    "Discord's attachment storage rejected \(file.name)."
                )
            }
            progress(.uploading(fileName: file.name, completed: total, total: total))
            uploaded.append(
                Self.uploadedAttachmentPayload(
                    id: slot.id,
                    file: file,
                    uploadFilename: slot.uploadFilename
                )
            )
        }
        return uploaded
        }
    }

    nonisolated static func validatedAttachmentUploadURL(
        from value: String
    ) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    func uploadAttachmentFiles(
        _ files: [AttachmentUploadFile],
        channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [JSONValue] {
        try await attachmentFileUploadOperation(files, channelID, progress)
    }
    public func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws
        -> Message
    {
        let dto: MessageDTO = try await request(
            "/channels/\(channelID)/messages/\(messageID)", method: "PATCH",
            body: ["content": .string(content)]
        )
        let message = try dto.domain()
        cachedMessages[message.id] = message
        continuation?.yield(.messageUpdated(message))
        return message
    }

    public func delete(messageID: MessageID, channelID: ChannelID) async throws {
        try await requestEmpty("/channels/\(channelID)/messages/\(messageID)", method: "DELETE")
        cachedMessages[messageID] = nil
        continuation?.yield(.messageDeleted(channelID: channelID, messageID: messageID))
    }

    public func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID)
        async throws
    {
        guard let message = cachedMessages[messageID] else {
            throw ChatProviderError.messageNotFound
        }
        let apiEmoji = Self.reactionAPIValue(emoji)
        let existing = message.reactions.firstIndex { Self.reactionAPIValue($0.emoji) == apiEmoji }
        let reacted = existing.map { message.reactions[$0].didCurrentUserReact } ?? false
        try await setReaction(
            emoji,
            reacted: !reacted,
            messageID: messageID,
            channelID: channelID
        )
    }

    public func setReaction(
        _ emoji: String,
        reacted: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        guard let message = cachedMessages[messageID] else {
            throw ChatProviderError.messageNotFound
        }
        let apiEmoji = Self.reactionAPIValue(emoji)
        let currentReaction = message.reactions.first {
            Self.reactionAPIValue($0.emoji) == apiEmoji
        }
        guard currentReaction?.didCurrentUserReact != reacted else { return }
        let encoded =
            apiEmoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiEmoji
        let method = reacted ? "PUT" : "DELETE"
        try await requestEmpty(
            "/channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)/@me", method: method
        )
        guard let currentUserID = currentUser?.id,
              var updated = cachedMessages[messageID]
        else { return }
        let reactionUpdate: MessageReactionUpdate =
            reacted
            ? .add(
                channelID: channelID,
                messageID: messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
            : .remove(
                channelID: channelID,
                messageID: messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
        guard updated.applyReactionUpdate(reactionUpdate, currentUserID: currentUserID) else {
            return
        }
        cachedMessages[messageID] = updated
        continuation?.yield(.messageUpdated(updated))
        updateForumPostForMessage(updated)
    }

    public func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        guard reactionCount > 0 else { return [] }
        let apiEmoji = Self.reactionAPIValue(emoji)
        let key = ReactionReactorCacheKey(
            channelID: channelID,
            messageID: messageID,
            emojiIdentity: Reaction(emoji: emoji, count: reactionCount).id,
            reactionCount: reactionCount
        )
        if let cached = cachedReactionReactors[key] {
            return cached
        }
        if let task = reactionReactorTasks[key] {
            return try await task.value
        }
        guard reactionReactorTasks.count < Self.maximumConcurrentReactionReactorReads else {
            throw ChatProviderError.invalidRequest(
                "Too many reaction details are already loading. Hover this reaction again shortly."
            )
        }

        let encoded =
            apiEmoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiEmoji
        let task = Task { [self] in
            let users: [UserDTO] = try await request(
                "/channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)",
                query: [
                    URLQueryItem(name: "type", value: "0"),
                    URLQueryItem(
                        name: "limit",
                        value: String(Self.reactionReactorFetchLimit)
                    ),
                ]
            )
            return try users.map { ReactionReactor(user: try $0.domain()) }
        }
        reactionReactorTasks[key] = task
        do {
            let reactors = try await task.value
            reactionReactorTasks[key] = nil
            cacheReactionReactors(reactors, for: key)
            return reactors
        } catch {
            reactionReactorTasks[key] = nil
            throw error
        }
    }

    func cacheReactionReactors(
        _ reactors: [ReactionReactor],
        for key: ReactionReactorCacheKey
    ) {
        cachedReactionReactors[key] = reactors
        reactionReactorCacheOrder.removeAll { $0 == key }
        reactionReactorCacheOrder.append(key)
        while reactionReactorCacheOrder.count > Self.maximumReactionReactorCacheEntries {
            let evicted = reactionReactorCacheOrder.removeFirst()
            cachedReactionReactors[evicted] = nil
        }
    }

    static func reactionAPIValue(_ emoji: String) -> String {
        guard emoji.hasPrefix("<"), emoji.hasSuffix(">") else { return emoji }
        let value = emoji.dropFirst().dropLast()
        let withoutAnimationPrefix = value.hasPrefix("a:") ? value.dropFirst(2) : value.dropFirst(1)
        return String(withoutAnimationPrefix)
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
