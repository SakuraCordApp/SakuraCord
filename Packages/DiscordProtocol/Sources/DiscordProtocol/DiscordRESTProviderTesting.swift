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

        func currentUserForTesting() -> User? {
            currentUser
        }

        func cachedGuildsForTesting() -> [Guild] {
            guildsInCurrentRailOrder()
        }

        func cachedGuildRailItemsForTesting() -> [GuildRailItem] {
            cachedGuildRailItems
        }

        func cachedGuildRolesForTesting(guildID: GuildID) -> [GuildRole] {
            (cachedGuildRoles[guildID] ?? []).compactMap(\.domain)
        }

        func cachedMembersForTesting(guildID: GuildID) -> [Member] {
            cachedMembers[guildID] ?? []
        }

        func gatewayOpcodeIsRateLimitedForTesting(_ opcode: Int) -> Bool {
            gatewayOpcodeRateLimitDates[opcode].map { $0 > Date() } ?? false
        }

        func seedPrivateCallSubscriptionForTesting(channelID: ChannelID) {
            subscribedPrivateCallChannelIDs.insert(channelID)
        }

        func hasPrivateCallSubscriptionForTesting(channelID: ChannelID) -> Bool {
            subscribedPrivateCallChannelIDs.contains(channelID)
        }
    }
#endif
