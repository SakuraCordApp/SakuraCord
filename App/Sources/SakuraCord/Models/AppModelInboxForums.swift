import DiscordProtocol
import SakuraCordModels

extension AppModel {
    func loadInboxForum(_ group: InboxUnreadGroup, session: AppModelAccountSession, generation: UInt64) async throws {
        var query = ForumPostQuery(sortOrder: .creationDate, limit: 100, requiresFreshPage: true)
        var posts: [ChannelID: ForumPost] = [:]
        while true {
            let page = try await session.provider.forumPosts(in: group.channelID, query: query)
            guard !Task.isCancelled, isCurrentInboxLoad(session, generation: generation) else { return }
            for post in page.posts where !post.thread.isArchived && post.id.rawValue > (group.oldestReadMessageID?.rawValue ?? 0) {
                posts[post.id] = post
            }
            guard page.hasMore, let offset = page.nextOffset, offset > query.offset else { break }
            query.offset = offset
        }
        let visiblePosts = posts.values.sorted { $0.id < $1.id }
        for post in visiblePosts { inbox.threads[post.id] = post.thread }
        guard let index = inbox.groups.firstIndex(where: { $0.id == group.id }) else { return }
        inbox.groups[index].forumPosts = visiblePosts
        inbox.groups[index].isLoaded = true
        inbox.groups[index].needsRevalidation = false
    }
}

extension AppModel {
    func openInboxForumPost(_ post: ForumPost) {
        dismissInbox()
        navigate(to: post.thread.guildID, linkedChannelID: post.id)
    }
}

extension AppModel {
    func reconcileInboxForumPosts(channelID: ChannelID, posts: [ForumPost], replacesAll: Bool) {
        guard inbox.isPresented,
              let index = inbox.groups.firstIndex(where: { $0.id == channelID && $0.isForum && $0.isLoaded }) else { return }
        let boundary = inbox.groups[index].oldestReadMessageID?.rawValue ?? 0
        var values = replacesAll ? [:] : Dictionary(uniqueKeysWithValues: inbox.groups[index].forumPosts.map { ($0.id, $0) })
        for post in posts {
            values[post.id] = !post.thread.isArchived && post.id.rawValue > boundary ? post : nil
            inbox.threads[post.id] = post.thread
        }
        inbox.groups[index].forumPosts = values.values.sorted { $0.id < $1.id }
        publishInbox()
        dismissEmptyInboxGroups()
    }
}

extension AppModel {
    func resolveInboxThreadContext(for message: Message) {
        let channelID = message.channelID
        guard message.guildID != nil, inbox.threads[channelID] == nil,
              snapshot?.channels.contains(where: { $0.id == channelID }) != true,
              inbox.metadataTasks[channelID] == nil else { return }
        let session = accountSession()
        inbox.metadataTasks[channelID] = Task { [weak self] in
            guard let self else { return }
            defer { if isCurrentAccountSession(session) { inbox.metadataTasks[channelID] = nil } }
            guard let post = try? await session.provider.forumPost(threadID: channelID),
                  !Task.isCancelled, isCurrentAccountSession(session) else { return }
            inbox.threads[channelID] = post.thread
            if inbox.isPresented { publishInbox() }
        }
    }
}
