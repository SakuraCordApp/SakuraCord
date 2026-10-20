import DiscordProtocol
import Foundation
import SakuraCordModels

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
            forumSortOrder = channel.defaultSortOrder ?? .latestActivity
            forumLayout =
                channel.defaultForumLayout == .defaultLayout ? .list : channel.defaultForumLayout
            forumTagMatch = channel.defaultTagMatch
        }
        guard selectedConversationAccess.isReadable else { return }
        forumLoadTask = Task { [weak self] in
            await self?.loadForumPosts(reset: true)
        }
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

    func updateForumSearch(_ text: String) {
        let previousSearch = forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
                  forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == nextSearch
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
        let loadSignpost = Self.forumPerformanceSignposter.beginInterval("ForumPostsLoad")
        defer {
            Self.forumPerformanceSignposter.endInterval("ForumPostsLoad", loadSignpost)
        }
        let trimmedSearch = forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if isCurrentAccountSession(session),
               selectedChannelID == channelID,
               forumLoadGeneration == requestGeneration
            {
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
            let page = try await requestForumPosts(
                provider: session.provider,
                channelID: channelID,
                scope: scope,
                reset: reset
            )
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  selectedChannelID == channelID,
                  forumLoadGeneration == requestGeneration
            else { return }
            applyForumPage(page, isSearch: isSearch, reset: reset, channelID: channelID)
        } catch {
            guard !Self.isForumLoadCancellation(error) else { return }
            guard isCurrentAccountSession(session),
                  selectedChannelID == channelID,
                  forumLoadGeneration == requestGeneration
            else {
                return
            }
            applyForumLoadError(error, isSearch: isSearch, reset: reset)
        }
    }

    func requestForumPosts(
        provider: any ChatProvider,
        channelID: ChannelID,
        scope: ForumPostScope,
        reset: Bool
    ) async throws -> ForumPostPage {
        let providerSignpost = Self.forumPerformanceSignposter.beginInterval("ForumProviderLoad")
        defer {
            Self.forumPerformanceSignposter.endInterval(
                "ForumProviderLoad",
                providerSignpost
            )
        }
        return try await provider.forumPosts(
            in: channelID,
            query: ForumPostQuery(
                scope: scope,
                sortOrder: forumSortOrder,
                selectedTagIDs: forumSelectedTagIDs,
                tagMatch: forumTagMatch,
                offset: reset ? 0 : (forumNextOffset ?? 0),
                limit: 25
            )
        )
    }

    func applyForumPage(
        _ page: ForumPostPage,
        isSearch: Bool,
        reset: Bool,
        channelID: ChannelID
    ) {
        let catalogueSignpost = Self.forumPerformanceSignposter.beginInterval(
            "ForumCatalogueUpdate"
        )
        if isSearch {
            mergeForumCatalogue(page.posts)
        } else if reset {
            replaceForumCatalogue(with: page.posts)
        } else {
            mergeForumCatalogue(page.posts)
        }
        Self.forumPerformanceSignposter.endInterval(
            "ForumCatalogueUpdate",
            catalogueSignpost
        )
        let presentationSignpost = Self.forumPerformanceSignposter.beginInterval(
            "ForumPresentation"
        )
        applyForumPresentation()
        Self.forumPerformanceSignposter.endInterval(
            "ForumPresentation",
            presentationSignpost
        )
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
                post = forumPostPreservingReactionPresentation(
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
            return forumPostPreservingReactionPresentation(incoming, previous: previous, preservesMembership: false)
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

    func forumPostPreservingReactionPresentation(
        _ incoming: ForumPost,
        previous: ForumPost,
        preservesMembership: Bool = true
    ) -> ForumPost {
        var result = incoming
        if let firstMessage = incoming.firstMessage {
            result.firstMessage = firstMessage.preservingReactionReactors(
                from: previous.firstMessage ?? firstMessage
            )
        } else {
            result.firstMessage = previous.firstMessage
        }
        if let mostRecentMessage = incoming.mostRecentMessage {
            result.mostRecentMessage = mostRecentMessage.preservingReactionReactors(
                from: previous.mostRecentMessage ?? mostRecentMessage
            )
        } else {
            result.mostRecentMessage = previous.mostRecentMessage
        }
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
            mergeForumCatalogue([post])
            applyForumPresentation()
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

    func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async {
        let policy = threadActionPolicy(post.thread)
        switch mutation {
        case .tags(let tagIDs):
            guard validateForumTagMutation(tagIDs, for: post) else { return }
        case .archived:
            guard policy.canChangeArchive else {
                forumActionError = "You do not have permission to close or reopen this post."
                return
            }
        case .name:
            guard policy.canRename else {
                forumActionError = "You do not have permission to rename this post."
                return
            }
        case .locked, .pinned:
            guard policy.canManage else {
                forumActionError = "Only moderators can change this post."
                return
            }
        }

        forumActionError = nil
        let session = accountSession()
        do {
            let updated = try await session.provider.updateForumPost(
                post,
                mutation: mutation
            )
            guard isCurrentAccountSession(session) else { return }
            mergeForumCatalogue([updated])
            applyForumPresentation()
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
        let policy = threadActionPolicy(post.thread)
        guard policy.canEditTags else {
            forumActionError = "You do not have permission to edit this post’s tags."
            return false
        }
        let uniqueTagIDs = Set(tagIDs)
        guard uniqueTagIDs.count <= 5,
              let channel = selectedChannel,
              channel.id == post.thread.parentID
        else {
            forumActionError = "The selected tags are invalid for this forum."
            return false
        }
        let availableTagsByID = Dictionary(
            uniqueKeysWithValues: channel.availableTags.map { ($0.id, $0) }
        )
        guard uniqueTagIDs.allSatisfy({ availableTagsByID[$0] != nil }) else {
            forumActionError = "One or more selected tags are no longer available."
            return false
        }
        guard !channel.requiresForumTag || !uniqueTagIDs.isEmpty else {
            forumActionError = "This forum requires every post to have at least one tag."
            return false
        }
        if !policy.canManage {
            let changedTagIDs = uniqueTagIDs.symmetricDifference(post.thread.appliedTagIDs)
            guard changedTagIDs.allSatisfy({
                availableTagsByID[$0]?.isModerated == false
            }) else {
                forumActionError = "Only moderators can change moderated tags."
                return false
            }
        }
        return true
    }

    func deleteForumPost(_ post: ForumPost) async {
        guard threadActionPolicy(post.thread).canDelete else {
            forumActionError = "You do not have permission to delete this post."
            return
        }
        forumActionError = nil
        let session = accountSession()
        do {
            try await session.provider.deleteForumPost(post)
            guard isCurrentAccountSession(session) else { return }
            removeForumPost(post.id)
            if openThread?.id == post.id {
                closeThread()
            }
            forumActionError = nil
        } catch {
            guard isCurrentAccountSession(session) else { return }
            forumActionError = error.localizedDescription
        }
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
