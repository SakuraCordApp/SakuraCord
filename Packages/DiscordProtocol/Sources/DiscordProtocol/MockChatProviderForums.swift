import Foundation
import SakuraCordModels

public extension MockChatProvider {
    func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        let page = try forumPage(in: channelID, query: query)
        return forumPreviewsHydrateLate ? hydratingPreviewsLater(page, in: channelID) : page
    }

    private func forumPage(in channelID: ChannelID, query: ForumPostQuery) throws -> ForumPostPage {
        forumQueriesByChannel[channelID, default: []].append(query)
        guard snapshot.channels.contains(where: { $0.id == channelID && $0.kind == .forum }) else {
            throw ChatProviderError.channelNotFound
        }
        var posts = forumPostsByChannel[channelID] ?? []
        switch query.scope {
        case .active:
            let active = query.offset == 0 ? posts.filter { !$0.thread.isArchived } : []
            var older = posts.filter(\.thread.isArchived)
            older.sort {
                ($0.thread.archiveTimestamp ?? .distantPast)
                    > ($1.thread.archiveTimestamp ?? .distantPast)
            }
            let pageStart = min(query.offset, older.count)
            let pageEnd = min(pageStart + query.limit, older.count)
            let olderPage = Array(older[pageStart ..< pageEnd])
            posts = active + olderPage
            posts = filterAndSortForumPosts(posts, query: query)
            return ForumPostPage(
                posts: posts,
                hasMore: pageEnd < older.count,
                nextOffset: pageEnd < older.count ? pageEnd : nil
            )
        case .search(let text):
            posts.removeAll {
                !$0.thread.name.localizedCaseInsensitiveContains(text)
            }
        }
        posts = ForumPostQueryPolicy.filteredAndSorted(
            posts,
            selectedTagIDs: query.selectedTagIDs,
            tagMatch: query.tagMatch,
            sortOrder: query.sortOrder
        )
        return ForumPostPage(posts: posts, hasMore: false, nextOffset: nil)
    }

    /// Strips a page's previews and republishes them later, like the live
    /// provider's post-data hydration, so cards first lay out without them.
    /// The delay outlasts the first paint, so previews land on visible cards.
    private func hydratingPreviewsLater(_ page: ForumPostPage, in channelID: ChannelID) -> ForumPostPage {
        var stripped = page
        for index in stripped.posts.indices {
            // Like a live catalogue entry, the stripped post keeps its
            // activity order through its last message ID.
            if let latest = stripped.posts[index].mostRecentMessage {
                stripped.posts[index].thread.lastMessageID = .messageSearchBoundary(at: latest.timestamp)
            }
            stripped.posts[index].firstMessage = nil
            stripped.posts[index].mostRecentMessage = nil
        }
        let postIDs = Set(page.posts.map(\.id))
        Task {
            do {
                try await Task.sleep(for: .milliseconds(1_200))
            } catch {
                return
            }
            // Republish current records, so a post edited or deleted during
            // the delay is not restored.
            let current = (forumPostsByChannel[channelID] ?? []).filter { postIDs.contains($0.id) }
            guard !current.isEmpty else { return }
            continuation?.yield(.forumPostPreviewsChanged(channelID: channelID, posts: current))
        }
        return stripped
    }

    func forumQueries(in channelID: ChannelID) -> [ForumPostQuery] {
        forumQueriesByChannel[channelID] ?? []
    }

    func forumPost(threadID: ChannelID) async throws -> ForumPost {
        guard let post = forumPostsByChannel.values.lazy.flatMap(\.self).first(where: {
            $0.id == threadID
        }) else {
            throw ChatProviderError.channelNotFound
        }
        return post
    }

    private func filterAndSortForumPosts(
        _ incomingPosts: [ForumPost], query: ForumPostQuery
    ) -> [ForumPost] {
        ForumPostQueryPolicy.filteredAndSorted(
            incomingPosts,
            selectedTagIDs: query.selectedTagIDs,
            tagMatch: query.tagMatch,
            sortOrder: query.sortOrder
        )
    }

    func createForumPost(
        _ draft: CreateForumPostDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> ForumPost {
        guard
            let channel = snapshot.channels.first(where: {
                $0.id == draft.channelID && $0.kind == .forum
            })
        else { throw ChatProviderError.channelNotFound }
        let selectedTags = DiscordRESTProvider.orderedUniqueForumTagIDs(
            draft.appliedTagIDs,
            availableTags: channel.availableTags
        )
        guard let title = ThreadNamePolicy.validatedName(draft.title), draft.content.count <= 2_000,
              !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !draft.attachments.isEmpty,
              !channel.requiresForumTag || !selectedTags.isEmpty,
              selectedTags.count <= 5,
              Set(selectedTags) == Set(draft.appliedTagIDs),
              draft.attachments.count <= 10,
              DiscordRESTProvider.validForumAutoArchiveDurations.contains(
                  draft.autoArchiveDuration
              )
        else {
            throw ChatProviderError.invalidRequest(
                "The forum post does not meet this channel's requirements.")
        }
        progress(.preparing)
        nextMessageID += 1
        let threadID = ChannelID(rawValue: nextMessageID)
        let attachments = try draft.attachments.enumerated().map { index, item in
            var value = try MockChatMediaFixtures.stageAttachment(
                item.url,
                messageID: nextMessageID,
                index: index
            )
            value.filename = item.filename
            value.description = item.description.isEmpty ? nil : item.description
            value.isSpoiler = item.isSpoiler
            if item.isSpoiler, !value.filename.hasPrefix("SPOILER_") {
                value.filename = "SPOILER_\(value.filename)"
            }
            return value
        }
        progress(.submitting)
        let message = Message(
            id: MessageID(rawValue: nextMessageID), channelID: threadID, author: currentUser,
            content: draft.content, timestamp: .now, attachments: attachments
        )
        let post = ForumPost(
            thread: MessageThreadSummary(
                id: threadID, guildID: channel.guildID, parentID: channel.id, name: title,
                messageCount: 1, memberCount: 1, lastMessageID: message.id,
                ownerID: currentUser.id, appliedTagIDs: selectedTags,
                createdAt: message.timestamp, autoArchiveDuration: draft.autoArchiveDuration,
                totalMessageSent: 1,
                notificationSettings: ThreadNotificationSettings()
            ),
            owner: currentUser, firstMessage: message, mostRecentMessage: message
        )
        forumPostsByChannel[channel.id, default: []].insert(post, at: 0)
        messagesByChannel[threadID] = [message]
        continuation?.yield(
            .forumPostsChanged(channelID: channel.id, posts: forumPostsByChannel[channel.id] ?? []))
        progress(.completed(messageID: message.id))
        return post
    }

    func createThread(_ draft: CreateThreadDraft) async throws -> MessageThreadSummary {
        guard let name = ThreadNamePolicy.validatedName(draft.name),
              let channel = snapshot.channels.first(where: { $0.id == draft.channelID }),
              channel.kind == .text || (channel.kind == .announcement && !draft.isPrivate),
              draft.starterMessageID == nil || !draft.isPrivate,
              DiscordRESTProvider.validForumAutoArchiveDurations.contains(draft.autoArchiveDuration)
        else { throw ChatProviderError.invalidRequest("The thread does not meet this channel's requirements.") }
        let threadID: ChannelID
        var starterIndex: Int?
        if let starterID = draft.starterMessageID {
            guard let index = messagesByChannel[channel.id]?.firstIndex(where: { $0.id == starterID }),
                  messagesByChannel[channel.id]?[index].referencedThreadID == nil
            else { throw ChatProviderError.invalidRequest("This message cannot start a thread.") }
            threadID = ChannelID(rawValue: starterID.rawValue)
            starterIndex = index
        } else {
            nextMessageID += 1
            threadID = ChannelID(rawValue: nextMessageID)
        }
        let thread = MessageThreadSummary(id: threadID, guildID: channel.guildID, parentID: channel.id, name: name,
            memberCount: 1, ownerID: currentUser.id, createdAt: .now,
            autoArchiveDuration: draft.autoArchiveDuration,
            notificationSettings: ThreadNotificationSettings(joinedAt: .now), isPrivate: draft.isPrivate
        )
        messagesByChannel[thread.id] = []
        if let starterIndex, var starter = messagesByChannel[channel.id]?[starterIndex] {
            starter.thread = thread
            starter.flags.insert(.hasThread)
            messagesByChannel[channel.id]?[starterIndex] = starter
            continuation?.yield(.messageUpdated(starter))
        }
        forumPostsByChannel[channel.id, default: []].insert(ForumPost(thread: thread, owner: currentUser), at: 0)
        publishMockThreads(parentID: channel.id, joinedThreadsChanged: true)
        return thread
    }

    func setThreadMembership(
        threadID: ChannelID,
        isJoined: Bool,
        location: ThreadMembershipLocation
    ) async throws {
        guard let (parentID, index) = mockThreadIndex(threadID) else { throw ChatProviderError.channelNotFound }
        forumPostsByChannel[parentID]?[index].thread.notificationSettings =
            isJoined ? ThreadNotificationSettings(joinedAt: .now) : nil
        publishMockThreads(parentID: parentID, joinedThreadsChanged: true)
    }

    func threadBrowserPage(in parentID: ChannelID, query: ThreadBrowserQuery) async throws
        -> ForumPostPage
    {
        guard snapshot.channels.contains(where: {
            $0.id == parentID && [.text, .announcement, .forum].contains($0.kind)
        }) else { throw ChatProviderError.channelNotFound }
        let posts = (forumPostsByChannel[parentID] ?? []).filter {
            ForumPostQueryPolicy.matchesTags($0, selectedTagIDs: query.selectedTagIDs, tagMatch: query.tagMatch)
        }
        switch query.scope {
        case .archived(let offset):
            let archived = posts.filter(\.thread.isArchived).sorted { $0.lastActivityAt > $1.lastActivityAt }
            let start = min(max(0, offset), archived.count)
            let end = min(start + ThreadBrowserQuery.pageSize, archived.count)
            return ForumPostPage(
                posts: Array(archived[start ..< end]), hasMore: end < archived.count,
                nextOffset: end < archived.count ? end : nil, totalResults: archived.count
            )
        case .search(let text):
            let matches = posts.filter { $0.thread.name.localizedCaseInsensitiveContains(text) }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
            return ForumPostPage(posts: matches, hasMore: false, nextOffset: nil, totalResults: matches.count)
        }
    }

    func activeThreads(in parentID: ChannelID) async -> [ForumPost] {
        (forumPostsByChannel[parentID] ?? []).filter { !$0.thread.isArchived }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private func mockThreadIndex(_ threadID: ChannelID) -> (ChannelID, Int)? {
        for (parentID, posts) in forumPostsByChannel {
            if let index = posts.firstIndex(where: { $0.id == threadID }) { return (parentID, index) }
        }
        return nil
    }

    /// Publishes a parent's threads like Discord's thread events, keeping the
    /// joined-thread snapshot and message thread cards in step.
    private func publishMockThreads(parentID: ChannelID, joinedThreadsChanged: Bool = false) {
        let posts = forumPostsByChannel[parentID] ?? []
        if joinedThreadsChanged {
            let joined = posts.filter { !$0.thread.isArchived && $0.thread.notificationSettings != nil }
            snapshot.activeJoinedThreads.removeAll { $0.parentID == parentID }
            snapshot.activeJoinedThreads += joined.map(\.thread)
            continuation?.yield(.activeJoinedThreadsChanged(snapshot.activeJoinedThreads))
        }
        continuation?.yield(.forumPostsChanged(channelID: parentID, posts: posts))
    }

    func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async throws
        -> ForumPost
    {
        guard let parentID = post.thread.parentID,
              var posts = forumPostsByChannel[parentID],
              let index = posts.firstIndex(where: { $0.id == post.id })
        else { throw ChatProviderError.channelNotFound }
        var updated = posts[index]
        switch mutation {
        case .name(let value):
            guard let name = ThreadNamePolicy.validatedName(value) else {
                throw ChatProviderError.invalidRequest("Names must be between 1 and 100 characters.")
            }
            updated.thread.name = name
            updated.thread.isArchived = false
        case .tags(let tags):
            guard let channel = snapshot.channels.first(where: { $0.id == parentID }) else {
                throw ChatProviderError.channelNotFound
            }
            let selectedTags = DiscordRESTProvider.orderedUniqueForumTagIDs(
                tags,
                availableTags: channel.availableTags
            )
            guard selectedTags.count <= 5, Set(selectedTags) == Set(tags) else {
                throw ChatProviderError.invalidRequest("One or more selected tags are unavailable.")
            }
            guard !channel.requiresForumTag || !selectedTags.isEmpty else {
                throw ChatProviderError.invalidRequest(
                    "This forum requires every post to have at least one tag."
                )
            }
            updated.thread.appliedTagIDs = selectedTags
        case .archived(let value): updated.thread.isArchived = value
        case .locked(let value): updated.thread.isLocked = value
        case .pinned(let value):
            if value { updated.thread.flags |= 1 << 1 } else { updated.thread.flags &= ~(1 << 1) }
        }
        posts[index] = updated
        forumPostsByChannel[parentID] = posts
        publishMockThreads(parentID: parentID, joinedThreadsChanged: true)
        return updated
    }

    func deleteForumPost(_ post: ForumPost) async throws {
        guard let parentID = post.thread.parentID,
              var posts = forumPostsByChannel[parentID],
              let index = posts.firstIndex(where: { $0.id == post.id })
        else { throw ChatProviderError.channelNotFound }
        posts.remove(at: index)
        forumPostsByChannel[parentID] = posts
        messagesByChannel[post.id] = nil
        continuation?.yield(
            .forumPostsChanged(channelID: parentID, posts: forumPostsByChannel[parentID] ?? []))
    }

    func updateForumPostNotificationLevel(
        _ post: ForumPost,
        level: MessageNotificationLevel
    ) async throws {
        threadNotificationRequests.append(
            ThreadNotificationRequest(threadID: post.id, level: level)
        )
        try updateForumPostNotificationSettings(post) {
            $0.flags = $0.flags(setting: level)
        }
    }

    func updateForumPostMute(
        _ post: ForumPost,
        isMuted: Bool,
        until: Date?
    ) async throws {
        threadNotificationRequests.append(
            ThreadNotificationRequest(
                threadID: post.id,
                isMuted: isMuted,
                muteEndTime: until
            )
        )
        try updateForumPostNotificationSettings(post) {
            $0.isMuted = isMuted
            $0.muteConfiguration =
                isMuted ? DiscordMuteConfiguration(endTime: until) : nil
        }
    }

    private func updateForumPostNotificationSettings(
        _ post: ForumPost,
        mutation: (inout ThreadNotificationSettings) -> Void
    ) throws {
        guard let parentID = post.thread.parentID,
              var posts = forumPostsByChannel[parentID],
              let index = posts.firstIndex(where: { $0.id == post.id })
        else { throw ChatProviderError.channelNotFound }
        var settings =
            posts[index].thread.notificationSettings
            ?? ThreadNotificationSettings()
        mutation(&settings)
        posts[index].thread.notificationSettings = settings
        forumPostsByChannel[parentID] = posts
        continuation?.yield(
            .forumPostsChanged(channelID: parentID, posts: posts)
        )
    }

    /// Like Discord's channel store, known message threads also form their
    /// parent's thread list; one archived thread exercises the thread browser.
    internal static func seedThreadCatalogue(
        forumPosts: inout [ChannelID: [ForumPost]],
        messages: inout [ChannelID: [Message]],
        channels: [Channel],
        owner: User
    ) {
        for (channelID, channelMessages) in messages {
            for thread in channelMessages.compactMap(\.thread) where thread.parentID == channelID {
                forumPosts[channelID, default: []].append(ForumPost(thread: thread))
            }
        }
        let parentID = ChannelID(rawValue: 216)
        let archived = MessageThreadSummary(
            id: ChannelID(rawValue: 903), guildID: channels.first { $0.id == parentID }?.guildID,
            parentID: parentID, name: "Archived showcase notes", messageCount: 1, memberCount: 1,
            isArchived: true, ownerID: owner.id, archiveTimestamp: .now.addingTimeInterval(-3 * 86_400),
            createdAt: .now.addingTimeInterval(-10 * 86_400), autoArchiveDuration: 4_320
        )
        forumPosts[parentID, default: []].append(ForumPost(thread: archived, owner: owner))
        messages[archived.id] = [
            Message(
                id: MessageID(rawValue: 609_101), channelID: archived.id, author: owner,
                content: "Notes from an earlier showcase review.",
                timestamp: .now.addingTimeInterval(-6 * 86_400), guildID: archived.guildID
            )
        ]
    }

    internal static func makeForumPosts(
        channelID: ChannelID,
        authors: [User],
        count: Int = 6
    ) -> [ForumPost] {
        let authors =
            authors.isEmpty
                ? [User(id: UserID(rawValue: 1), username: "offline", displayName: "Offline User")]
                : authors
        let titles = [
            "Media viewer should use a native presentation",
            "Reaction state should update without reloading",
            "Channel links should open inside SakuraCord",
            "Markdown custom emoji are not rendered",
            "Forum channels need a dedicated browser",
            "Keyboard navigation for long post lists",
        ]
        let bodies = [
            "Replace the temporary viewer with Quick Look or a polished native gallery.",
            "Gateway reaction events should reconcile the visible post card immediately.",
            "Keep the user in context and reveal the target channel and message.",
            "Custom emoji tokens in markdown should resolve through the guild catalog.",
            "The normal text timeline is not the right information hierarchy for posts.",
            "Arrow keys and VoiceOver should move through stable post identities.",
        ]
        let tagSets: [[ForumTagID]] = [
            [.init(rawValue: 8_001), .init(rawValue: 8_005)],
            [.init(rawValue: 8_002), .init(rawValue: 8_003)],
            [.init(rawValue: 8_002)],
            [.init(rawValue: 8_001)],
            [.init(rawValue: 8_001), .init(rawValue: 8_004)],
            [.init(rawValue: 8_002), .init(rawValue: 8_005)],
        ]
        let now = Date.now
        return (0 ..< max(0, count)).map { index in
            let rawID = channelID.rawValue * 100 + UInt64(index + 1)
            let threadID = ChannelID(rawValue: rawID)
            let timestamp = now.addingTimeInterval(Double(-index * 7_200 - 900))
            let author = authors[index % authors.count]
            let templateIndex = index % titles.count
            let title = index < titles.count
                ? titles[templateIndex]
                : "\(titles[templateIndex]) \(index + 1)"
            let attachments: [Attachment]
            if count > titles.count, index.isMultiple(of: 5), let imageURL = author.avatarURL {
                attachments = [
                    Attachment(
                        id: "\(rawID)-preview",
                        filename: "forum-preview.png",
                        url: imageURL,
                        mediaType: "image/png",
                        width: 256,
                        height: 256
                    )
                ]
            } else {
                attachments = []
            }
            let message = Message(
                id: MessageID(rawValue: rawID), channelID: threadID, author: author,
                content: bodies[templateIndex], timestamp: timestamp,
                attachments: attachments,
                reactions: [
                    Reaction(
                        emoji: "👍",
                        count: max(1, 6 - index),
                        reactors: [ReactionReactor(user: author)]
                    )
                ]
            )
            return ForumPost(
                thread: MessageThreadSummary(
                    id: threadID, guildID: GuildID(rawValue: 100), parentID: channelID,
                    name: title, messageCount: index + 2, memberCount: index + 1,
                    lastMessageID: message.id, isArchived: index >= count / 2,
                    isLocked: index.isMultiple(of: 17),
                    ownerID: author.id, appliedTagIDs: tagSets[templateIndex],
                    flags: index == 0 ? 1 << 1 : 0,
                    archiveTimestamp: index >= count / 2 ? timestamp : nil,
                    createdAt: timestamp.addingTimeInterval(-1_800), totalMessageSent: index + 2
                ),
                owner: author, firstMessage: message, mostRecentMessage: message,
                isUnread: index % 7 == 1 || index % 7 == 3
            )
        }
    }

    struct ThreadNotificationRequest: Equatable, Sendable {
        public var threadID: ChannelID
        public var level: MessageNotificationLevel?
        public var isMuted: Bool?
        public var muteEndTime: Date?
    }
}
