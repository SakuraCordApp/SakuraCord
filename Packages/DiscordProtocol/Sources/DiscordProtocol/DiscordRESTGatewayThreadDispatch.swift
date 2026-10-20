import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func handleGatewayThreadEvent(
        name: String,
        body: JSONValue
    ) async -> Bool {
        switch name {
        case "THREAD_CREATE":
            await handleThreadCreateDispatch(name: name, body: body)
        case "THREAD_UPDATE":
            await handleThreadUpdateDispatch(name: name, body: body)
        case "THREAD_DELETE":
            await handleThreadDeleteDispatch(name: name, body: body)
        case "THREAD_MEMBER_LIST_UPDATE":
            handleThreadMemberListUpdate(body: body)
        case "THREAD_MEMBER_UPDATE":
            await handleThreadMemberUpdateDispatch(name: name, body: body)
        case "THREAD_MEMBERS_UPDATE":
            await handleThreadMembersUpdateDispatch(name: name, body: body)
        case "THREAD_LIST_SYNC":
            await handleThreadListSyncDispatch(name: name, body: body)
        default:
            return false
        }
        return true
    }

    func handleThreadCreateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let dto = try? JSONValueDecoder().decode(ChannelDTO.self, from: body) else { return }
        ingestForumThreads(
            [dto],
            fallbackGuildID: dto.guildID.flatMap(GuildID.init),
            advancesParentLatestThreadID: true
        )
    }

    func handleThreadUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let dto = try? JSONValueDecoder().decode(ChannelDTO.self, from: body) else { return }
        ingestForumThreads([dto], fallbackGuildID: dto.guildID.flatMap(GuildID.init))
        if dto.threadMetadata?.archived == true, let threadID = ChannelID(dto.id) {
            await removeThreadMemberSubscription(threadID)
        }
    }

    func handleThreadDeleteDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let deleted = try? JSONValueDecoder().decode(GatewayThreadDeleteDTO.self, from: body),
              let threadID = ChannelID(deleted.id),
              let parentID = deleted.parentID.flatMap(ChannelID.init)
        else { return }
        await removeThreadMemberSubscription(threadID)
        cachedForumPosts[parentID]?[threadID] = nil
        cachedForumThreadOrder.removeAll { $0 == threadID }
        cachedJoinedThreads[threadID] = nil
        cachedJoinedThreadOrder.removeAll { $0 == threadID }
        advanceThreadRecordRevision(threadID, includesMembership: true)
        cachedMessages.removeAll { $0.channelID == threadID }
        for var message in cachedMessages.values where message.thread?.id == threadID {
            message.thread = nil
            cachedMessages[message.id] = message
        }
        continuation?.yield(.threadDeleted(channelID: threadID))
        publishForumPosts(parentID: parentID)
        publishActiveJoinedThreads()
    }

    func handleThreadMemberUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let member = try? JSONValueDecoder().decode(ThreadMemberDTO.self, from: body),
            member.userID == nil || member.userID.flatMap(UserID.init) == currentUser?.id,
            let rawThreadID = member.id,
            let threadID = ChannelID(rawThreadID)
        else { return }
        advanceThreadMembershipRevision(threadID)
        var changedParentIDs = Set<ChannelID>()
        guard applyCurrentUserThreadMembership(
            member.domain,
            threadID: threadID,
            changedParentIDs: &changedParentIDs
        ) else { return }
        for parentID in changedParentIDs {
            publishForumPosts(parentID: parentID)
        }
        publishActiveJoinedThreads()
    }

    func handleThreadMembersUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let update = try? JSONValueDecoder().decode(
                GatewayThreadMembersUpdateDTO.self, from: body
            ), let threadID = ChannelID(update.id)
        else { return }
        if let guildID = GuildID(update.guildID), cachedThreadMemberIDs[threadID] != nil {
            ingestThreadMembers(update.addedMembers ?? [], guildID: guildID)
            var ids = cachedThreadMemberIDs[threadID] ?? []
            for member in update.addedMembers ?? [] {
                if let id = member.userID.flatMap(UserID.init), !ids.contains(id) { ids.append(id) }
            }
            let removed = Set((update.removedMemberIDs ?? []).compactMap(UserID.init))
            cachedThreadMemberIDs[threadID] = ids.filter { !removed.contains($0) }
            publishThreadMembers(guildID: guildID)
        }
        var changedParentIDs = Set<ChannelID>()
        if let parentID = cachedForumPostParentID(threadID: threadID) {
            cachedForumPosts[parentID]?[threadID]?.thread.memberCount = update.memberCount
            changedParentIDs.insert(parentID)
        }
        let isJoinedThread = cachedJoinedThreads[threadID] != nil
        cachedJoinedThreads[threadID]?.memberCount = update.memberCount
        var membershipChanged = false
        if let currentUserID = currentUser?.id {
            if let ownMember = update.addedMembers?.first(where: {
                $0.userID.flatMap(UserID.init) == currentUserID
            }) {
                advanceThreadMembershipRevision(threadID)
                membershipChanged = applyCurrentUserThreadMembership(
                    ownMember.domain,
                    threadID: threadID,
                    changedParentIDs: &changedParentIDs
                )
            } else if update.removedMemberIDs?.contains(currentUserID.description) == true {
                advanceThreadMembershipRevision(threadID)
                membershipChanged = applyCurrentUserThreadMembership(
                    nil,
                    threadID: threadID,
                    changedParentIDs: &changedParentIDs
                )
            }
        }
        for parentID in changedParentIDs {
            publishForumPosts(parentID: parentID)
        }
        if membershipChanged || isJoinedThread || !changedParentIDs.isEmpty {
            publishActiveJoinedThreads()
        }
    }

    func cachedForumPostParentID(threadID: ChannelID) -> ChannelID? {
        cachedForumPosts.first { $0.value[threadID] != nil }?.key
    }

    /// Applies the current user's membership to a thread known through the
    /// post cache or only through the joined-thread catalogue, so an open or
    /// sidebar thread follows Gateway joins and leaves. Returns false when
    /// neither cache knows the thread; Discord then follows a join with a
    /// THREAD_CREATE carrying the member.
    func applyCurrentUserThreadMembership(
        _ settings: ThreadNotificationSettings?,
        threadID: ChannelID,
        changedParentIDs: inout Set<ChannelID>
    ) -> Bool {
        var thread: MessageThreadSummary?
        if let parentID = cachedForumPostParentID(threadID: threadID) {
            cachedForumPosts[parentID]?[threadID]?.thread.notificationSettings = settings
            thread = cachedForumPosts[parentID]?[threadID]?.thread
            changedParentIDs.insert(parentID)
        } else if var joined = cachedJoinedThreads[threadID] {
            joined.notificationSettings = settings
            thread = joined
        }
        guard let thread else { return false }
        if settings == nil {
            cachedJoinedThreads[threadID] = nil
            cachedJoinedThreadOrder.removeAll { $0 == threadID }
        } else {
            reconcileJoinedThread(thread)
        }
        return true
    }

    func handleThreadListSyncDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let sync = try? JSONValueDecoder().decode(GatewayThreadListSyncDTO.self, from: body),
              let guildID = GuildID(sync.guildID)
        else { return }
        let membersByThreadID = Dictionary(
            sync.members.compactMap { member in
                member.id.map { ($0, member) }
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let recentByThreadID = Dictionary(
            sync.mostRecentMessages.map { ($0.channelID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let hydratedThreads = sync.threads.map { thread in
            var thread = thread
            if thread.member == nil {
                thread.member = membersByThreadID[thread.id]
            }
            if thread.mostRecentMessage == nil {
                thread.mostRecentMessage = recentByThreadID[thread.id]
            }
            return thread
        }
        // Add-or-update only. The desktop op-37 sync covers every active thread
        // the user can view, joined or not, without `channel_ids` or members;
        // absence is not deletion, archive or leaving.
        ingestForumThreads(
            hydratedThreads, fallbackGuildID: guildID,
            advancesParentLatestThreadID: true
        )
    }
}
