import DiscordProtocol
import Foundation
import SakuraCordModels

/// What the forum post composer keeps between openings. Files aren't kept:
/// their access ends when the composer closes.
struct ForumPostComposerDraft: Equatable {
    var title = ""
    var content = ""
    var tagIDs: Set<ForumTagID> = []
    var attachments: [ForumPostAttachment] = []
    /// Attachments still being size-checked, which hold Post back.
    var checkingAttachmentIDs: Set<UUID> = []

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tagIDs.isEmpty
            && attachments.isEmpty
    }
}

extension ForumTag {
    /// Discord allows at most five tags on a post.
    static let maximumAppliedCount = 5
}

extension AppModel {
    func canToggleForumTag(_ tag: ForumTag, on post: ForumPost) -> Bool {
        let policy = threadActionPolicy(post.thread)
        guard policy.canEditTags, policy.canManage || !tag.isModerated else {
            return false
        }
        if selectedChannel?.requiresForumTag == true,
           post.thread.appliedTagIDs.count == 1,
           post.thread.appliedTagIDs.contains(tag.id)
        {
            return false
        }
        return true
    }

    /// Adds or removes a tag from a post.
    func toggleForumTag(_ tagID: ForumTagID, on post: ForumPost, in channel: Channel) {
        guard let tag = channel.availableTags.first(where: { $0.id == tagID }),
              canToggleForumTag(tag, on: post)
        else { return }
        var tags = Set(post.thread.appliedTagIDs)
        if tags.contains(tagID) {
            tags.remove(tagID)
        } else if tags.count < ForumTag.maximumAppliedCount {
            tags.insert(tagID)
        }
        Task { await updateForumPostTags(post, tagIDs: Array(tags)) }
    }

    func resetForumLoadAndPresentationState() {
        forumLoadTask?.cancel()
        forumLoadTask = nil
        forumLoadGeneration &+= 1
        forumCreateGeneration &+= 1
        forumNextOffset = nil
        forumPosts = []
        forumCataloguePosts = []
        forumCatalogueIndexByID = [:]
        forumRecentPostCount = 0
        isLoadingForumPosts = false
        isSearchingForumPosts = false
        hasLoadedForumPosts = false
        isLoadingMoreForumPosts = false
        hasMoreForumPosts = false
        forumPostError = nil
        forumActionError = nil
        forumPaginationError = nil
        forumCreateProgress = nil
        forumSearchText = ""
        forumSelectedTagIDs = []
        forumSortOrder = .latestActivity
        forumLayout = .list
        forumTagMatch = .matchSome
    }

    func beginForumLoad() {
        channelLoadTask?.cancel()
        resetForumLoadAndPresentationState()
        replaceSelectedMessages(with: [])
        draft = ""
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        messageLoadErrorIsLaterPage = false
        isLoadingMessages = false
        isLoadingEarlier = false
        isLoadingLater = false
        hasMoreMessages = false
        hasMoreLaterMessages = false
        if let channel = selectedChannel {
            // Returning to a forum shows it as it was left.
            forumViewMemory.beginVisit(channel.id)
            let saved = forumViewMemory.preferences(for: channel.id)
            let defaults = forumDefaults(for: channel)
            forumSortOrder = saved?.sortOrder ?? defaults.sortOrder
            forumLayout = saved?.layout ?? defaults.layout
            forumTagMatch = saved?.tagMatch ?? defaults.tagMatch
        }
        guard selectedConversationAccess.isReadable else { return }
        forumLoadTask = Task { [weak self] in
            await self?.loadForumPosts(reset: true)
        }
    }

    // MARK: Sort & view

    func setForumSortOrder(_ value: ForumSortOrder) {
        guard forumSortOrder != value else { return }
        forumSortOrder = value
        forumViewMemory.cancelPendingRestore()
        rememberForumView()
        reloadForumPosts()
    }

    func setForumLayout(_ value: ForumLayout) {
        guard forumLayout != value else { return }
        forumLayout = value
        rememberForumView()
    }

    func setForumTagMatch(_ value: ForumTagMatch) {
        guard forumTagMatch != value else { return }
        forumTagMatch = value
        forumViewMemory.cancelPendingRestore()
        rememberForumView()
        reloadForumPosts()
    }

    func toggleForumFilterTag(_ tagID: ForumTagID) {
        if forumSelectedTagIDs.contains(tagID) {
            forumSelectedTagIDs.remove(tagID)
        } else {
            forumSelectedTagIDs.insert(tagID)
        }
        forumViewMemory.cancelPendingRestore()
        reloadForumPosts()
    }

    /// Returns to the forum's own defaults and forgets what was remembered.
    func resetForumView() {
        let channel = selectedChannel
        let defaults = forumDefaults(for: channel)
        forumSortOrder = defaults.sortOrder
        forumLayout = defaults.layout
        forumTagMatch = defaults.tagMatch
        forumSelectedTagIDs = []
        if let channel { forumViewMemory.forget(channel.id) }
        reloadForumPosts()
    }

    private struct ForumSortAndView {
        let sortOrder: ForumSortOrder
        let layout: ForumLayout
        let tagMatch: ForumTagMatch
    }

    /// The forum's own Sort & view choices, before anything remembered.
    private func forumDefaults(for channel: Channel?) -> ForumSortAndView {
        let layout = channel?.defaultForumLayout ?? .list
        return ForumSortAndView(
            sortOrder: channel?.defaultSortOrder ?? .latestActivity,
            layout: layout == .defaultLayout ? .list : layout,
            tagMatch: channel?.defaultTagMatch ?? .matchSome
        )
    }

    private func rememberForumView() {
        guard let channel = selectedChannel, channel.kind == .forum else { return }
        forumViewMemory.remember(sortOrder: forumSortOrder, layout: forumLayout, tagMatch: forumTagMatch, for: channel.id)
    }

    func reloadForumPosts() {
        guard selectedChannel?.kind == .forum else { return }
        forumLoadTask?.cancel()
        forumLoadTask = Task { [weak self] in
            await self?.loadForumPosts(reset: true)
        }
    }

    func loadMoreForumPosts() async {
        guard hasMoreForumPosts, !isLoadingMoreForumPosts else { return }
        await loadForumPosts(reset: false)
    }

    var trimmedForumSearchText: String {
        forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateForumSearch(_ text: String) {
        if text != forumSearchText { forumViewMemory.cancelPendingRestore() }
        let previousSearch = trimmedForumSearchText
        let nextSearch = text.trimmingCharacters(in: .whitespacesAndNewlines)
        forumSearchText = text
        forumPostError = nil
        forumPaginationError = nil
        forumLoadGeneration &+= 1
        if nextSearch.lowercased().hasPrefix(previousSearch.lowercased()) {
            let presentation = ForumPostPresentation(
                posts: forumPosts,
                recentCount: forumRecentPostCount
            ).filtering(
                searchText: nextSearch,
                selectedTagIDs: forumSelectedTagIDs,
                tagMatch: forumTagMatch
            )
            forumPosts = presentation.posts
            forumRecentPostCount = presentation.recentCount
        } else {
            applyForumPresentation()
        }
        forumLoadTask?.cancel()
        guard !nextSearch.isEmpty else {
            isSearchingForumPosts = false
            hasMoreForumPosts = forumNextOffset != nil
            return
        }
        hasMoreForumPosts = false
        isSearchingForumPosts = true
        forumLoadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  trimmedForumSearchText == nextSearch
            else { return }
            await loadForumPosts(reset: true)
        }
    }

    func loadForumPosts(reset: Bool) async {
        guard !Task.isCancelled,
              let channelID = selectedChannelID,
              selectedChannel?.kind == .forum,
              selectedConversationAccess.isReadable
        else { return }
        let session = accountSession()
        await AppPerformanceSignposts.measure("ForumPostsLoad") {
            let trimmedSearch = trimmedForumSearchText
            let isSearch = !trimmedSearch.isEmpty
            if isSearch { isSearchingForumPosts = true }
            if reset {
                forumLoadGeneration &+= 1
                forumPaginationError = nil
                if !isSearch { forumNextOffset = nil }
            } else {
                isLoadingMoreForumPosts = true
                forumPaginationError = nil
            }
            let requestGeneration = forumLoadGeneration
            @MainActor func isCurrentRequest() -> Bool {
                isCurrentAccountSession(session)
                    && selectedChannelID == channelID
                    && forumLoadGeneration == requestGeneration
            }
            let loadingIndicatorTask: Task<Void, Never>? =
                reset && !hasLoadedForumPosts
                    ? Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(150))
                        guard let self, !Task.isCancelled,
                              selectedChannelID == channelID,
                              forumLoadGeneration == requestGeneration,
                              !hasLoadedForumPosts
                        else { return }
                        isLoadingForumPosts = true
                    }
                    : nil
            defer {
                loadingIndicatorTask?.cancel()
                if isCurrentRequest() {
                    isLoadingForumPosts = false
                    isLoadingMoreForumPosts = false
                    if isSearch { isSearchingForumPosts = false }
                }
            }
            let scope: ForumPostScope =
                !trimmedSearch.isEmpty
                    ? .search(trimmedSearch)
                    : .active
            do {
                let page = try await AppPerformanceSignposts.measure("ForumProviderLoad") {
                    try await session.provider.forumPosts(
                        in: channelID,
                        query: currentForumQuery(scope: scope, offset: reset ? 0 : (forumNextOffset ?? 0))
                    )
                }
                guard !Task.isCancelled, isCurrentRequest() else { return }
                applyForumPage(page, isSearch: isSearch, reset: reset, channelID: channelID)
            } catch {
                guard !Self.isForumLoadCancellation(error) else { return }
                guard isCurrentRequest() else { return }
                applyForumLoadError(error, isSearch: isSearch, reset: reset)
            }
        }
    }

    /// A page of the selected forum under its current sort and tag filter.
    func currentForumQuery(scope: ForumPostScope, offset: Int) -> ForumPostQuery {
        ForumPostQuery(
            scope: scope,
            sortOrder: forumSortOrder,
            selectedTagIDs: forumSelectedTagIDs,
            tagMatch: forumTagMatch,
            offset: offset,
            limit: 25
        )
    }

    /// Whether the selected conversation is this forum's board.
    func presentsForum(_ channelID: ChannelID?) -> Bool {
        channelID == selectedChannelID && selectedChannel?.kind == .forum
    }

    func mergeAndPresentForumPosts(_ posts: [ForumPost]) {
        mergeForumCatalogue(posts)
        applyForumPresentation()
    }

    func consumeForumPostsChanged(channelID: ChannelID, posts: [ForumPost]) {
        threadBrowser.receive(parentID: channelID, records: posts)
        reconcileInboxForumPosts(channelID: channelID, posts: posts, replacesAll: true)
        AppPerformanceSignposts.measureSync("ForumPostsChanged") {
            let threads = posts.map(\.thread)
            AppPerformanceSignposts.measureSync(
                "ForumForwardDestinationReplacement"
            ) {
                replaceSnapshotThreads(
                    parentID: channelID,
                    with: threads
                )
            }
            AppPerformanceSignposts.measureSync(
                "ForumReadStateReplacement"
            ) {
                readState.replaceThreads(parentID: channelID, with: threads)
            }
            AppPerformanceSignposts.measureSync("ForumUnreadRefreshRequest") {
                requestCoalescedUnreadPresentationRefresh()
            }
            refreshTimelineThreadCards(parentID: channelID, posts: posts)
            guard presentsForum(channelID) else { return }
            // Omission from the provider's catalogue is not deletion; the open post
            // closes only through `.threadDeleted`, lost access or the user.
            replaceForumCatalogue(with: posts)
            applyForumPresentation()
        }
    }

    func consumeForumPostPreviewsChanged(channelID: ChannelID, posts: [ForumPost]) {
        refreshTimelineThreadCards(parentID: channelID, posts: posts, replacesAll: false)
        reconcileInboxForumPosts(channelID: channelID, posts: posts, replacesAll: false)
        mergeSnapshotThreads(posts.map(\.thread))
        for post in posts { readState.merge(thread: post.thread) }
        requestCoalescedUnreadPresentationRefresh()
        guard presentsForum(channelID) else { return }
        mergeAndPresentForumPosts(posts)
    }

    func consumeForumPageLoaded(
        channelID: ChannelID,
        query: ForumPostQuery,
        page: ForumPostPage
    ) {
        for post in page.posts { readState.merge(thread: post.thread) }
        requestCoalescedUnreadPresentationRefresh()
        guard presentsForum(channelID),
              trimmedForumSearchText.isEmpty,
              query == currentForumQuery(scope: .active, offset: 0)
        else { return }
        replaceForumCatalogue(with: page.posts)
        applyForumPresentation()
        forumNextOffset = page.nextOffset
        hasMoreForumPosts = page.hasMore
    }

    func applyForumPage(
        _ page: ForumPostPage,
        isSearch: Bool,
        reset: Bool,
        channelID: ChannelID
    ) {
        AppPerformanceSignposts.measureSync("ForumCatalogueUpdate") {
            if reset, !isSearch {
                replaceForumCatalogue(with: page.posts)
            } else {
                mergeForumCatalogue(page.posts)
            }
        }
        AppPerformanceSignposts.measureSync("ForumPresentation", operation: applyForumPresentation)
        if !isSearch {
            forumNextOffset = page.nextOffset
            hasMoreForumPosts = page.hasMore
        } else {
            hasMoreForumPosts = false
        }
        forumPostError = nil
        forumPaginationError = nil
        hasLoadedForumPosts = true
        if !isSearch, reset {
            acknowledgeForumVisitIfNeeded(channelID: channelID)
        }
    }

    func applyForumLoadError(_ error: Error, isSearch: Bool, reset: Bool) {
        DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
        if reset {
            forumPostError =
                isSearch && !forumCataloguePosts.isEmpty
                    ? nil
                    : error.localizedDescription
        } else {
            forumPaginationError = error.localizedDescription
        }
        hasLoadedForumPosts = true
    }

    func mergeForumCatalogue(_ posts: [ForumPost]) {
        for incoming in posts {
            readState.merge(forumPost: incoming)
            let post: ForumPost
            if let index = forumCatalogueIndexByID[incoming.id] {
                post = forumPostMergingPrevious(
                    incoming,
                    previous: forumCataloguePosts[index]
                )
            } else {
                post = incoming
            }
            if let index = forumCatalogueIndexByID[post.id] {
                forumCataloguePosts[index] = post
            } else {
                forumCatalogueIndexByID[post.id] = forumCataloguePosts.endIndex
                forumCataloguePosts.append(post)
            }
        }
    }

    func replaceForumCatalogue(with posts: [ForumPost]) {
        let previousByID = Dictionary(
            uniqueKeysWithValues: forumCataloguePosts.map { ($0.id, $0) }
        )
        forumCataloguePosts = posts.map { incoming in
            readState.merge(forumPost: incoming)
            guard let previous = previousByID[incoming.id] else { return incoming }
            // The provider's catalogue carries authoritative membership, so a
            // confirmed leave is not undone by the previous card's settings.
            return forumPostMergingPrevious(incoming, previous: previous, preservesMembership: false)
        }
        // A page or provider list that omits the open post does not delete it.
        // Deletion closes the post before its catalogue is republished.
        if let openThreadID = openThread?.id,
           let openPost = previousByID[openThreadID],
           !posts.contains(where: { $0.id == openThreadID })
        {
            forumCataloguePosts.append(openPost)
        }
        forumCatalogueIndexByID = Dictionary(
            uniqueKeysWithValues: forumCataloguePosts.indices.map {
                (forumCataloguePosts[$0].id, $0)
            }
        )
    }

    func forumPostMergingPrevious(
        _ incoming: ForumPost,
        previous: ForumPost,
        preservesMembership: Bool = true
    ) -> ForumPost {
        var result = incoming
        if incoming.firstMessage == nil, !incoming.isFirstMessageLoaded {
            result.firstMessage = previous.firstMessage
            result.isFirstMessageLoaded = previous.isFirstMessageLoaded
        }
        result.keepNewerLatestMessage(from: previous)
        result.owner = incoming.owner ?? previous.owner
        if preservesMembership, result.thread.notificationSettings == nil {
            result.thread.notificationSettings = previous.thread.notificationSettings
        }
        return result
    }

    func reconcileForumMessage(_ message: Message) {
        guard let index = forumCatalogueIndexByID[message.channelID] else { return }
        var updated = forumCataloguePosts[index]
        let isNewerReply =
            updated.thread.lastMessageID.map { message.id > $0 }
            ?? (message.id.rawValue != updated.id.rawValue)
        if message.id.rawValue == updated.id.rawValue || updated.firstMessage?.id == message.id {
            updated.firstMessage = message
        }
        if updated.mostRecentMessage == nil || message.timestamp >= updated.lastActivityAt {
            updated.mostRecentMessage = message
            updated.thread.lastMessageID = message.id
        }
        if isNewerReply {
            updated.thread.messageCount += 1
            updated.thread.totalMessageSent += 1
        }
        guard updated != forumCataloguePosts[index] else { return }
        forumCataloguePosts[index] = updated
        updateForumPresentation(with: updated)
    }

    func applyForumPresentation() {
        let presentation = ForumPostPresentation.make(
            catalogue: forumCataloguePosts,
            searchText: forumSearchText,
            selectedTagIDs: forumSelectedTagIDs,
            tagMatch: forumTagMatch,
            sortOrder: forumSortOrder
        )
        forumPosts = presentation.posts
        forumRecentPostCount = presentation.recentCount
    }

    func updateForumPresentation(with post: ForumPost) {
        let presentation = ForumPostPresentation(
            posts: forumPosts,
            recentCount: forumRecentPostCount
        ).updating(
            post,
            searchText: forumSearchText,
            selectedTagIDs: forumSelectedTagIDs,
            tagMatch: forumTagMatch,
            sortOrder: forumSortOrder
        )
        forumPosts = presentation.posts
        forumRecentPostCount = presentation.recentCount
    }

    nonisolated static func isForumLoadCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled
    }

    @discardableResult
    func createForumPost(_ draft: CreateForumPostDraft) async -> Bool {
        guard canCreateForumPosts else {
            forumActionError = "You do not have permission to create posts in this forum."
            return false
        }
        let uploadsAttachments = !draft.attachments.isEmpty
        if uploadsAttachments { activeAttachmentUploadCount += 1 }
        defer { if uploadsAttachments { activeAttachmentUploadCount -= 1 } }
        forumActionError = nil
        forumCreateGeneration &+= 1
        let generation = forumCreateGeneration
        let session = accountSession()
        defer {
            if forumCreateGeneration == generation {
                forumCreateProgress = nil
                forumCreateGeneration &+= 1
            }
        }
        do {
            let post = try await session.provider.createForumPost(draft) { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                          self.isCurrentAccountSession(session),
                          self.forumCreateGeneration == generation
                    else { return }
                    self.forumCreateProgress = progress
                }
            }
            guard isCurrentAccountSession(session) else { return false }
            recordMessageEmojiUsage(draft.content)
            mergeAndPresentForumPosts([post])
            open(post)
            return true
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            if Self.isForumLoadCancellation(error) {
                return false
            }
            forumActionError = error.localizedDescription
            return false
        }
    }

    func updateForumPostTags(_ post: ForumPost, tagIDs: [ForumTagID]) async {
        guard validateForumTagMutation(tagIDs, for: post) else { return }

        forumActionError = nil
        let session = accountSession()
        do {
            let updated = try await session.provider.updateForumPost(
                post,
                mutation: .tags(tagIDs)
            )
            guard isCurrentAccountSession(session) else { return }
            mergeAndPresentForumPosts([updated])
            if openThread?.id == updated.id { openThread = updated.thread }
        } catch {
            guard isCurrentAccountSession(session) else { return }
            forumActionError = error.localizedDescription
        }
    }

    func validateForumTagMutation(
        _ tagIDs: [ForumTagID],
        for post: ForumPost
    ) -> Bool {
        // `toggleForumTag` already allowed the change: permission, the tag
        // limit, moderated tags and a required tag.
        guard let channel = selectedChannel, channel.id == post.thread.parentID else {
            forumActionError = "The selected tags are invalid for this forum."
            return false
        }
        let availableTagIDs = Set(channel.availableTags.map(\.id))
        guard Set(tagIDs).isSubset(of: availableTagIDs) else {
            forumActionError = "One or more selected tags are no longer available."
            return false
        }
        return true
    }

    func dismissForumActionError() {
        forumActionError = nil
    }

    func removeForumPost(_ postID: ChannelID) {
        guard let index = forumCatalogueIndexByID.removeValue(forKey: postID) else { return }
        forumCataloguePosts.remove(at: index)
        if index < forumCataloguePosts.endIndex {
            for updatedIndex in index ..< forumCataloguePosts.endIndex {
                forumCatalogueIndexByID[forumCataloguePosts[updatedIndex].id] = updatedIndex
            }
        }
        applyForumPresentation()
    }

}
