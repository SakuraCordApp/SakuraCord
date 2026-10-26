import Foundation
import SakuraCordModels

#if DEBUG
    extension DiscordRESTProvider {
        func seedForumChannelForTesting(
            _ channel: Channel,
            posts: [ForumPost] = [],
            currentUser: User? = nil
        ) {
            cachedChannels[channel.guildID, default: []].removeAll { $0.id == channel.id }
            cachedChannels[channel.guildID, default: []].append(channel)
            cachedForumPosts[channel.id] = Dictionary(
                uniqueKeysWithValues: posts.map { ($0.id, $0) }
            )
            for post in posts {
                cacheForumPreviewMessages(post)
            }
            if let currentUser {
                self.currentUser = currentUser
            }
        }

        func seedPrivateChannelsForTesting(
            _ channels: [Channel],
            currentUser: User? = nil
        ) {
            cachedChannels[nil] = channels
            if let currentUser {
                self.currentUser = currentUser
            }
        }

        func waitForNextGuildSubscriptionForTesting(guildID: GuildID, after taskID: UUID) async {
            guard guildSubscriptionTaskIDs[guildID] == taskID else { return }
            await withCheckedContinuation {
                guildSubscriptionQueueWaitersForTesting[guildID, default: []].append($0)
            }
        }

        func runScheduledMemberListRefreshForTesting(guildID: GuildID) async -> Bool {
            if let task = memberListViewportRestoreTasks.removeValue(forKey: guildID),
               let generation = guildSubscriptionGenerations[guildID] {
                task.cancel()
                gatewayOpcodeRateLimitDates[37] = nil
                await restoreSelectedMemberListViewport(guildID: guildID, generation: generation)
                return true
            }
            guard let task = memberListRefreshRetryTasks.removeValue(forKey: guildID),
                  let memberListID = selectedMemberListID[guildID],
                  let refresh = memberListsNeedingRefresh[guildID]?[memberListID]
            else { return false }
            task.cancel()
            gatewayOpcodeRateLimitDates[37] = nil
            await retryMemberListRefresh(guildID: guildID, memberListID: memberListID, refresh: refresh)
            return true
        }

        func setPendingMemberGuildForTesting(_ guildID: GuildID) {
            pendingMemberGuildID = guildID
        }

        func seedGuildChannelForTesting(_ channel: Channel) {
            guard let guildID = channel.guildID else { return }
            cachedChannels[guildID, default: []].removeAll {
                $0.id == channel.id
            }
            cachedChannels[guildID, default: []].append(channel)
        }

        func rateLimitDiscoveryWaiterCountForTesting(
            routeKey: String
        ) -> Int {
            rateLimitDiscoveryWaitersByRoute[routeKey]?.count ?? 0
        }

        func activeForumCatalogueQueriesForTesting(channelID: ChannelID) -> [ForumPostQuery] {
            forumCatalogueTasks.keys.compactMap {
                $0.channelID == channelID ? $0.query : nil
            }
        }

        func suspendForumCatalogueRefreshForTesting() {
            suspendsForumCatalogueRefreshForTesting = true
        }

        func receiveForumMessageForTesting(_ message: Message, marksUnread: Bool = true) {
            updateForumPostForMessage(message, marksUnread: marksUnread)
        }

        func receiveGatewayReactionForTesting(_ update: MessageReactionUpdate) {
            applyGatewayReactionUpdate(update)
        }

        func receiveGatewayDispatchForTesting(name: String, data: JSONValue) async {
            await handleGatewayDispatch(name: name, body: data)
        }

        /// Occupies the single StatusSettings save slot so later writers queue.
        func holdStatusSettingsSaveForTesting() {
            profileStatusSaveID = UUID()
        }

        func releaseStatusSettingsSaveForTesting() {
            finishStatusSettingsSave()
        }

        func statusSettingsSaveWaiterCountForTesting() -> Int {
            statusSettingsSaveWaiters.count
        }

        func pendingStatusEditForTesting() -> PendingStatusEdit? {
            pendingStatusEdit
        }

        /// Runs a scheduled status-edit save now; false when none is scheduled.
        func runScheduledStatusEditSaveForTesting() async -> Bool {
            guard statusEditSaveTask != nil else { return false }
            cancelStatusEditSave()
            await runStatusEditSave(statusEditSaveToken)
            return true
        }

        /// Ends the presence rate-limit window without waiting 20 seconds.
        func reopenPresenceSendWindowForTesting() async {
            presenceSendWindowEnds = []
            await sendPresenceIfChanged()
        }

        func hasDeferredPresenceForTesting() -> Bool {
            deferredPresenceTask != nil
        }

        func cachedChannelForTesting(channelID: ChannelID) -> Channel? {
            cachedChannels.values.lazy.flatMap { $0 }.first { $0.id == channelID }
        }

        func cachedPrivateChannelsForTesting() -> [Channel] {
            cachedChannels[nil] ?? []
        }

        func cachedForumPostForTesting(threadID: ChannelID) -> ForumPost? {
            cachedForumPosts.values.lazy.compactMap { $0[threadID] }.first
        }

        func activeJoinedThreadsForTesting() -> [MessageThreadSummary] {
            currentActiveJoinedThreads()
        }

        func cachedMessageForTesting(messageID: MessageID) -> Message? {
            cachedMessages[messageID]
        }

        func seedMessageForTesting(_ message: Message) {
            cachedMessages[message.id] = message
        }

        func cachedGuildForTesting(guildID: GuildID) -> Guild? {
            cachedGuilds[guildID]
        }

        func cachedGuildRailItemsForTesting() -> [GuildRailItem] {
            cachedGuildRailItems
        }

        func cachedMembersForTesting(guildID: GuildID) -> [Member] {
            cachedMembers[guildID] ?? []
        }
    }
#endif
