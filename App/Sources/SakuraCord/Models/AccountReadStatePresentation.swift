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
        let policy: UnreadPolicySource
        let forumPostArchivedByID: [ChannelID: Bool]

        func projection(
            now: Date = .now,
            cancelsCooperatively: Bool = false,
            cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
        ) -> UnreadPresentationProjection? {
            var unreadByChannelID: [ChannelID: Bool] = [:]
            var mentionsByChannelID: [ChannelID: Int] = [:]
            var newForumPostsByChannelID: [ChannelID: Int] = [:]
            var unreadByGuildID: [GuildID: Bool] = [:]
            var mentionsByGuildID: [GuildID: Int] = [:]
            var unreadCategoryIDsByGuild: [GuildID: Set<ChannelID>] = [:]
            var directMessageUnread = false
            var directMessageMentions = 0
            var totalMentions = 0
            unreadByChannelID.reserveCapacity(entries.count)
            mentionsByChannelID.reserveCapacity(entries.count)

            for (offset, entry) in entries.values.enumerated() {
                if cancelsCooperatively,
                   offset.isMultiple(of: 64),
                   cancellationCheck()
                {
                    return nil
                }
                let channelID = entry.channelID
                let isEligible = entry.isAccessible
                    && !policy.isGuildResourceChannel(entry)
                let channelMentions = isEligible ? entry.mentionCount : 0
                var channelUnread = false
                var contributesToGuildUnread = false
                if isEligible,
                   entry.isUnread,
                   entry.kind != .voice || entry.mentionCount > 0
                {
                    // Both row and guild presentation use the same
                    // notification hierarchy. Resolve it once per entry.
                    let effectivePolicy = policy.effectivePolicy(
                        for: entry,
                        now: now
                    )
                    channelUnread = entry.mentionCount > 0
                        || (!effectivePolicy.guildMuted
                            && !effectivePolicy.presentationChannelMuted
                            && effectivePolicy.showsUnread)
                    contributesToGuildUnread = !effectivePolicy.categoryMuted
                        && (entry.mentionCount > 0
                            || (!effectivePolicy.guildMuted
                                && !effectivePolicy.channelMuted
                                && effectivePolicy.showsUnread))
                }
                mentionsByChannelID[channelID] = channelMentions
                unreadByChannelID[channelID] = channelUnread
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
                   let guildID = policy.channelByID[channelID]?.guildID
                {
                    unreadByGuildID[guildID] = true
                }
                if isEligible,
                   entry.isUnread,
                   entry.kind != .voice || entry.mentionCount > 0,
                   let guildID = entry.guildID,
                   let parentID = entry.parentID
                {
                    let categoryID = policy.channelByID[parentID]?.categoryID
                        ?? parentID
                    unreadCategoryIDsByGuild[guildID, default: []].insert(
                        categoryID
                    )
                }

                guard let parentID = entry.parentID,
                      forumPostArchivedByID[channelID] != true,
                      !entry.hasAuthoritativeReadState,
                      let parent = entries[parentID],
                      parent.kind == .forum,
                      parent.hasAuthoritativeReadState
                else { continue }
                let boundary = parent.lastAcknowledgedMessageID
                    ?? MessageID(rawValue: 0)
                if MessageID(rawValue: channelID.rawValue) > boundary {
                    newForumPostsByChannelID[parentID, default: 0] += 1
                }
            }

            return UnreadPresentationProjection(
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
            let presentationOverrideMuted = directMuted
                || (parentIsConversation && parentMuted)
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
            let presentationChannelMuted = presentationOverrideMuted
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
        var pendingAcknowledgementID: MessageID?
        var flags: UInt64?
        var lastViewed: Int?
        var threadNotificationSettings: ThreadNotificationSettings?
        var isAccessible: Bool
        var hasAuthoritativeReadState: Bool

        var isUnread: Bool {
            guard let latestUnreadMessageID else { return false }
            guard let lastAcknowledgedMessageID else { return true }
            return latestUnreadMessageID > lastAcknowledgedMessageID
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
    }

    struct AcknowledgementMetadata: Equatable, Sendable {
        var flags: UInt64?
        var lastViewed: Int
    }

}
