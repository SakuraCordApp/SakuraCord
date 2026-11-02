import Foundation
import SakuraCordModels

extension AccountReadStateModel {
    func unacknowledgedDirectMessageChannelIDs() -> Set<ChannelID> {
        Set(entries.values.compactMap { entry in
            guard entry.isAccessible,
                  entry.isUnread,
                  entry.kind == .directMessage || entry.kind == .groupDirectMessage
            else { return nil }
            return entry.channelID
        })
    }

    struct UnreadPresentationProjection: Equatable, Sendable {
        var unreadConversationCount: Int
        var unreadByChannelID: [ChannelID: Bool]
        var mentionsByChannelID: [ChannelID: Int]
        var newForumPostsByChannelID: [ChannelID: Int]
        var unreadByGuildID: [GuildID: Bool]
        var mentionsByGuildID: [GuildID: Int]
        var unreadCategoryIDsByGuild: [GuildID: Set<ChannelID>]
        var directMessageUnread: Bool
        var directMessageMentions: Int
        var totalMentions: Int
    }

    nonisolated struct UnreadPresentationSource: Sendable {
        let entries: [ChannelID: Entry]
        let activeJoinedThreadIDs: Set<ChannelID>
        let policy: UnreadPolicySource
        let forumPostArchivedByID: [ChannelID: Bool]
        let forumVisitBoundaryByID: [ChannelID: MessageID]
        let guildJoinedAtByID: [GuildID: Date]

        /// Aggregate indicators must point to a current channel or a thread
        /// the sidebar can surface. Retained read history is not membership.
        func isAggregateConversation(_ entry: Entry) -> Bool {
            policy.channelByID[entry.channelID] != nil
                || (forumPostArchivedByID[entry.channelID] != true && isListedThread(entry))
        }

        /// Whether the entry's mention count is presented. Discord's
        /// `ReadState.canHaveMentions` keeps a thread's count hidden until the
        /// account is a member of the active thread, so a ping in a post the
        /// user has not joined must not reach the server badge or any row.
        /// Membership comes only from the joined catalogue, so a stale archive
        /// flag cannot hide a joined thread.
        func countsMentions(_ entry: Entry) -> Bool {
            policy.channelByID[entry.channelID] != nil
                || entry.guildID == nil
                || isListedThread(entry)
        }

        func presentedMentionCount(_ entry: Entry) -> Int {
            entry.mentionCount > 0 && countsMentions(entry) ? entry.mentionCount : 0
        }

        private func isListedThread(_ entry: Entry) -> Bool {
            AccountReadStateModel.isListedThread(
                entry,
                parentChannel: entry.parentID.flatMap { policy.channelByID[$0] },
                parentEntry: entry.parentID.flatMap { entries[$0] },
                isActiveJoined: activeJoinedThreadIDs.contains(entry.channelID)
            )
        }

        func unreadGuildID(for entry: Entry) -> GuildID? {
            isAggregateConversation(entry) ? entry.guildID : nil
        }

        /// The forum a new post counts toward. Like Discord's sidebar count,
        /// only active posts the user has neither joined nor opened count.
        func newForumPostParentID(of entry: Entry) -> ChannelID? {
            guard let parentID = entry.parentID,
                  forumPostArchivedByID[entry.channelID] != true,
                  !activeJoinedThreadIDs.contains(entry.channelID),
                  !entry.hasAuthoritativeReadState,
                  let parent = entries[parentID],
                  parent.kind == .forum,
                  AccountReadStateModel.isNewForumPost(
                      entry.channelID,
                      in: parent,
                      visitBoundary: forumVisitBoundaryByID[parentID],
                      guildJoinedAt: parent.guildID.flatMap { guildJoinedAtByID[$0] }
                  )
            else { return nil }
            return parentID
        }

        /// Forums whose sidebar count includes a post. A never-read forum's
        /// seeded boundary hides those posts from its own unread state, so
        /// acknowledgement eligibility checks both.
        func forumsWithNewPosts() -> Set<ChannelID> {
            Set(entries.values.lazy
                .filter { $0.isAccessible && !policy.isGuildResourceChannel($0) }
                .compactMap(newForumPostParentID(of:)))
        }

        /// The server a forum's unseen posts light, honouring its mutes.
        func guildLitByNewPosts(inForum forumID: ChannelID, now: Date) -> GuildID? {
            guard let forum = entries[forumID],
                  forum.isAccessible,
                  let guildID = policy.channelByID[forumID]?.guildID
            else { return nil }
            let effectivePolicy = policy.effectivePolicy(for: forum, now: now)
            guard !effectivePolicy.categoryMuted,
                  !effectivePolicy.guildMuted,
                  !effectivePolicy.channelMuted,
                  effectivePolicy.showsUnread
            else { return nil }
            return guildID
        }

        /// Scalar form of `projection().unreadByGuildID[guildID]`.
        func guildUnread(_ guildID: GuildID, now: Date) -> Bool {
            var checkedForumIDs: Set<ChannelID> = []
            for entry in entries.values {
                guard entry.isAccessible,
                      !policy.isGuildResourceChannel(entry)
                else { continue }
                if entry.countsAsUnreadConversation,
                   unreadGuildID(for: entry) == guildID,
                   policy.contributesOwnGuildUnread(
                       entry,
                       effectivePolicy: policy.effectivePolicy(for: entry, now: now)
                   )
                {
                    return true
                }
                if let forumID = newForumPostParentID(of: entry),
                   checkedForumIDs.insert(forumID).inserted,
                   guildLitByNewPosts(inForum: forumID, now: now) == guildID
                {
                    return true
                }
            }
            return false
        }

        func projection(
            now: Date = .now,
            cancelsCooperatively: Bool = false,
            cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
        ) -> UnreadPresentationProjection? {
            projection(
                of: entries.values,
                now: now,
                cancelsCooperatively: cancelsCooperatively,
                cancellationCheck: cancellationCheck
            )
        }

        /// The projection of one server's conversations, or of direct
        /// messages for `nil`. Every value it holds for that scope equals the
        /// full projection's; account-wide totals cover only the scope.
        func projection(
            scope guildID: GuildID?,
            now: Date = .now
        ) -> UnreadPresentationProjection? {
            projection(
                of: entries.values.lazy.filter { $0.guildID == guildID },
                now: now
            )
        }

        private func projection(
            of scope: some Sequence<Entry>,
            now: Date,
            cancelsCooperatively: Bool = false,
            cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
        ) -> UnreadPresentationProjection? {
            var unreadConversationIDs: Set<ChannelID> = []
            var unreadByChannelID: [ChannelID: Bool] = [:]
            var mentionsByChannelID: [ChannelID: Int] = [:]
            var newForumPostsByChannelID: [ChannelID: Int] = [:]
            var unreadByGuildID: [GuildID: Bool] = [:]
            var mentionsByGuildID: [GuildID: Int] = [:]
            var unreadCategoryIDsByGuild: [GuildID: Set<ChannelID>] = [:]
            var directMessageUnread = false
            var directMessageMentions = 0
            var totalMentions = 0
            unreadByChannelID.reserveCapacity(scope.underestimatedCount)
            mentionsByChannelID.reserveCapacity(scope.underestimatedCount)

            for (offset, entry) in scope.enumerated() {
                if cancelsCooperatively,
                   offset.isMultiple(of: 64),
                   cancellationCheck()
                {
                    return nil
                }
                let channelID = entry.channelID
                let isEligible = entry.isAccessible
                    && !policy.isGuildResourceChannel(entry)
                let channelMentions = isEligible ? presentedMentionCount(entry) : 0
                var channelUnread = false
                var contributesToGuildUnread = false
                if isEligible,
                   entry.isUnread,
                   entry.kind != .voice || channelMentions > 0
                {
                    // Both row and guild presentation use the same
                    // notification hierarchy. Resolve it once per entry.
                    let effectivePolicy = policy.effectivePolicy(
                        for: entry,
                        now: now
                    )
                    channelUnread = policy.presentsUnread(
                        entry,
                        mentionCount: channelMentions,
                        effectivePolicy: effectivePolicy
                    )
                    contributesToGuildUnread = policy.contributesOwnGuildUnread(
                        entry,
                        effectivePolicy: effectivePolicy
                    )
                }
                mentionsByChannelID[channelID] = channelMentions
                unreadByChannelID[channelID] = channelUnread
                if channelUnread,
                   entry.kind != .forum || channelMentions > 0,
                   isAggregateConversation(entry)
                {
                    unreadConversationIDs.insert(channelID)
                }
                totalMentions += channelMentions
                if entry.kind == .directMessage
                    || entry.kind == .groupDirectMessage
                {
                    directMessageUnread = directMessageUnread || channelUnread
                    directMessageMentions += channelMentions
                }

                if let guildID = entry.guildID {
                    mentionsByGuildID[guildID, default: 0] += channelMentions
                }
                if contributesToGuildUnread,
                   let guildID = unreadGuildID(for: entry)
                {
                    unreadByGuildID[guildID] = true
                }
                if isEligible,
                   entry.countsAsUnreadConversation && isAggregateConversation(entry)
                    || newForumPostParentID(of: entry) != nil,
                   let guildID = entry.guildID,
                   let parentID = entry.parentID
                {
                    let categoryID = policy.channelByID[parentID]?.categoryID
                        ?? parentID
                    unreadCategoryIDsByGuild[guildID, default: []].insert(
                        categoryID
                    )
                }

                if isEligible, let forumID = newForumPostParentID(of: entry) {
                    newForumPostsByChannelID[forumID, default: 0] += 1
                }
            }

            for forumID in newForumPostsByChannelID.keys {
                if let guildID = guildLitByNewPosts(inForum: forumID, now: now) {
                    unreadByGuildID[guildID] = true
                    unreadConversationIDs.insert(forumID)
                }
            }

            return UnreadPresentationProjection(
                unreadConversationCount: unreadConversationIDs.count,
                unreadByChannelID: unreadByChannelID,
                mentionsByChannelID: mentionsByChannelID,
                newForumPostsByChannelID: newForumPostsByChannelID,
                unreadByGuildID: unreadByGuildID,
                mentionsByGuildID: mentionsByGuildID,
                unreadCategoryIDsByGuild: unreadCategoryIDsByGuild,
                directMessageUnread: directMessageUnread,
                directMessageMentions: directMessageMentions,
                totalMentions: totalMentions
            )
        }
    }

    nonisolated struct EffectivePolicy: Sendable {
        var level: MessageNotificationLevel
        var guildMuted: Bool
        var channelMuted: Bool
        var presentationChannelMuted: Bool
        var categoryMuted: Bool
        var showsUnread: Bool
        var notifiesNewForumThreads: Bool
    }

    nonisolated struct UnreadPolicySource: Sendable {
        let settingsByGuild: [GuildID?: GuildNotificationSettings]
        let overridesByGuildAndChannelID:
            [GuildID?: [ChannelID: ChannelNotificationOverride]]
        let channelByID: [ChannelID: Channel]
        let defaultNotificationLevelByGuild:
            [GuildID: MessageNotificationLevel]
        let usesNewNotifications: Bool

        func effectivePolicy(for entry: Entry, now: Date) -> EffectivePolicy {
            let isDirectMessage = entry.kind == .directMessage
                || entry.kind == .groupDirectMessage
            let guildSettings = settingsByGuild[entry.guildID]
            let overrides = overridesByGuildAndChannelID[entry.guildID]
            let directOverride = overrides?[entry.channelID]
            let parentOverride = entry.parentID.flatMap { overrides?[$0] }
            let parentChannel = entry.parentID.flatMap { channelByID[$0] }
            let ancestorOverride = parentChannel?.categoryID.flatMap {
                overrides?[$0]
            }
            let parentIsConversation = parentChannel != nil
            let categoryOverride = parentIsConversation
                ? ancestorOverride
                : parentOverride
            let guildMuted = guildSettings?.isMuted == true
                && (guildSettings?.muteConfiguration?.isActive(at: now) ?? true)
            let directMuted = activeMute(directOverride, now: now)
            let parentMuted = activeMute(parentOverride, now: now)
            let inheritedChannelMuted = directMuted
                || parentMuted
                || activeMute(ancestorOverride, now: now)
            let categoryMuted = activeMute(categoryOverride, now: now)
            let guildDefault = isDirectMessage
                ? .allMessages
                : (entry.guildID.flatMap {
                    defaultNotificationLevelByGuild[$0]
                } ?? .onlyMentions)
            let configuredGuildLevel = guildSettings?.messageNotifications
                ?? .inherit
            let inherited = configuredGuildLevel == .inherit
                ? guildDefault
                : configuredGuildLevel
            let inheritedLevel = if let level = directOverride?
                .messageNotifications, level != .inherit
            {
                level
            } else if let level = parentOverride?.messageNotifications,
                      level != .inherit
            {
                level
            } else if let level = ancestorOverride?.messageNotifications,
                      level != .inherit
            {
                level
            } else {
                inherited
            }
            let threadLevel = entry.threadNotificationSettings?
                .notificationLevel ?? .inherit
            let level = threadLevel == .inherit ? inheritedLevel : threadLevel
            let threadMuted = entry.threadNotificationSettings?.isMuted == true
                && (entry.threadNotificationSettings?.muteConfiguration?
                    .isActive(at: now) ?? true)
            let channelMuted = inheritedChannelMuted
                || threadMuted
                || threadLevel == .nothing
            // A joined thread's unread ignores its parent's mute, as in
            // Discord's thread row and GuildReadStateStore.
            let presentationChannelMuted = directMuted
                || threadMuted
                || threadLevel == .nothing
            let showsUnread = showsUnread(
                isDirectMessage: isDirectMessage,
                level: level,
                guildFlags: guildSettings?.flags ?? 0,
                directFlags: directOverride?.flags,
                parentFlags: parentOverride?.flags,
                ancestorFlags: ancestorOverride?.flags
            )
            let notifiesNewForumThreads = notifiesNewForumThreads(
                parentFlags: parentOverride?.flags ?? 0,
                level: level
            )
            return EffectivePolicy(
                level: level,
                guildMuted: guildMuted,
                channelMuted: channelMuted,
                presentationChannelMuted: presentationChannelMuted,
                categoryMuted: categoryMuted,
                showsUnread: showsUnread,
                notifiesNewForumThreads: notifiesNewForumThreads
            )
        }

        private func showsUnread(
            isDirectMessage: Bool,
            level: MessageNotificationLevel,
            guildFlags: UInt64,
            directFlags: UInt64?,
            parentFlags: UInt64?,
            ancestorFlags: UInt64?
        ) -> Bool {
            let channelFlags = directFlags ?? parentFlags ?? ancestorFlags ?? 0
            let channelIsOptedIn = (directFlags ?? 0) & (1 << 12) != 0
                || (parentFlags ?? 0) & (1 << 12) != 0
            if !isDirectMessage,
               guildFlags & (1 << 14) != 0,
               !channelIsOptedIn
            {
                return false
            }
            if !isDirectMessage, !usesNewNotifications { return true }
            if channelFlags & (1 << 9) != 0 { return false }
            if channelFlags & (1 << 10) != 0 { return true }
            if guildFlags & (1 << 12) != 0 { return false }
            if guildFlags & (1 << 11) != 0 { return true }
            return level == .allMessages
        }

        private func notifiesNewForumThreads(
            parentFlags: UInt64,
            level: MessageNotificationLevel
        ) -> Bool {
            if parentFlags & (1 << 14) != 0 { return true }
            if parentFlags & (1 << 13) != 0 { return false }
            return level == .allMessages
        }

        /// Whether an unread entry presents as unread. Discord shows a joined
        /// thread unread unless the thread or server is muted; its parent's
        /// and server's unread settings do not apply.
        func presentsUnread(
            _ entry: Entry,
            mentionCount: Int,
            effectivePolicy: EffectivePolicy
        ) -> Bool {
            let isThread = channelByID[entry.channelID] == nil && entry.parentID != nil
            return mentionCount > 0
                || (!effectivePolicy.guildMuted
                    && !effectivePolicy.presentationChannelMuted
                    && (isThread || effectivePolicy.showsUnread))
        }

        /// Whether an entry's own unread lights its server. A forum's own
        /// boundary trails its newest post, so a forum lights the server only
        /// through mentions, its unseen posts and its joined threads.
        func contributesOwnGuildUnread(
            _ entry: Entry,
            effectivePolicy: EffectivePolicy
        ) -> Bool {
            if channelByID[entry.channelID] == nil, entry.parentID != nil {
                return presentsUnread(
                    entry,
                    mentionCount: entry.mentionCount,
                    effectivePolicy: effectivePolicy
                )
            }
            return !effectivePolicy.categoryMuted
                && (entry.mentionCount > 0
                    || (entry.kind != .forum
                        && !effectivePolicy.guildMuted
                        && !effectivePolicy.channelMuted
                        && effectivePolicy.showsUnread))
        }

        func isGuildResourceChannel(_ entry: Entry) -> Bool {
            Self.isGuildResourceChannel(entry, channelByID: channelByID)
        }

        static func isGuildResourceChannel(
            _ entry: Entry,
            channelByID: [ChannelID: Channel]
        ) -> Bool {
            let resourceFlag: UInt64 = 1 << 7
            if let channel = channelByID[entry.channelID],
               channel.flags & resourceFlag != 0
            {
                return true
            }
            let parentFlags = entry.parentID.flatMap { channelByID[$0] }?.flags
                ?? 0
            return parentFlags & resourceFlag != 0
        }

        private func activeMute(
            _ override: ChannelNotificationOverride?,
            now: Date
        ) -> Bool {
            override?.isMuted == true
                && (override?.muteConfiguration?.isActive(at: now) ?? true)
        }
    }

    struct TimelineUnreadSummary: Equatable, Sendable {
        var firstUnreadMessageID: MessageID
        var loadedUnreadCount: Int
        var isLowerBound: Bool
        var firstUnreadTimestamp: Date
    }

    struct QuickSwitcherProjection: Equatable, Sendable {
        var unreadChannelIDs: Set<ChannelID>
        var mutedChannelIDs: Set<ChannelID>
        var mentionsByChannelID: [ChannelID: Int]
        var mentionedChannelIDs: [ChannelID]
    }

    nonisolated struct UnreadNavigationState: Equatable, Sendable {
        var guildID: GuildID?
        var parentID: ChannelID?
        var kind: ChannelKindValue
        var isAccessible: Bool
        var isUnread: Bool
        var hasMentions: Bool
        var threadNotificationSettings: ThreadNotificationSettings?
    }

    nonisolated struct Entry: Equatable, Sendable {
        var channelID: ChannelID
        var guildID: GuildID?
        var parentID: ChannelID?
        var kind: ChannelKindValue
        var latestKnownMessageID: MessageID?
        var latestUnreadMessageID: MessageID?
        var lastAcknowledgedMessageID: MessageID?
        var mentionCount: Int
        var unreadMessageCount: Int
        var flags: UInt64?
        var lastViewed: Int?
        var threadNotificationSettings: ThreadNotificationSettings?
        var isAccessible: Bool
        var hasAuthoritativeReadState: Bool

        var unreadNavigationState: UnreadNavigationState {
            UnreadNavigationState(
                guildID: guildID,
                parentID: parentID,
                kind: kind,
                isAccessible: isAccessible,
                isUnread: isUnread,
                hasMentions: mentionCount > 0,
                threadNotificationSettings: threadNotificationSettings
            )
        }

        /// Discord's `getTrackedAckMessageId`: a server or local
        /// acknowledgement, never the boundary seeded for an omitted read state.
        var trackedAcknowledgedMessageID: MessageID? {
            hasAuthoritativeReadState ? lastAcknowledgedMessageID : nil
        }

        var isUnread: Bool {
            guard let latestUnreadMessageID else { return false }
            guard let lastAcknowledgedMessageID else { return true }
            return latestUnreadMessageID > lastAcknowledgedMessageID
        }

        /// Unread that marks a server or category. Voice channels and a
        /// forum's own boundary count only through mentions.
        var countsAsUnreadConversation: Bool {
            isUnread
                && ((kind != .voice && kind != .forum) || mentionCount > 0)
        }
    }

    struct Presentation: Equatable, Sendable {
        var isPresented = false
        var initialHistoryLoaded = false
        var initialPositionEstablished = false
        var windowIsActive = false
        var hasReachedReadBoundary = false
        /// Newest message of an unread run that passive viewing must not
        /// acknowledge. The hold lapses once that message is acknowledged by
        /// any path, so it needs no separate release when read elsewhere.
        var heldThroughMessageID: MessageID?
        /// Mark Unread's hold, which, as in Discord, scrolling does not release.
        var isHeldUntilSelectionChange = false

        var meetsViewingConditions: Bool {
            isPresented
                && initialHistoryLoaded
                && initialPositionEstablished
                && windowIsActive
                && hasReachedReadBoundary
        }
    }

    enum MentionKind: Equatable, Sendable {
        case none
        case direct
        case role
        case everyone
        case directMessage
    }

    struct MessageDisposition: Equatable, Sendable {
        var accepted: Bool
        var mentionKind: MentionKind
        var shouldNotify: Bool
        var requiresUnreadPresentationRefresh = false
        var acknowledgesOwnMessage = false
    }

    struct AcknowledgementMetadata: Equatable, Sendable {
        var flags: UInt64?
        var lastViewed: Int
    }

}
