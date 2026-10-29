import Foundation
import SakuraCordModels

extension AccountReadStateModel {
    func allowsNativeNotification(
        for mentionKind: MentionKind,
        policy: EffectivePolicy
    ) -> Bool {
        guard !policy.channelMuted, policy.level != .nothing else { return false }
        switch mentionKind {
        case .none:
            return false
        case .directMessage:
            return !policy.guildMuted
        case .direct, .role:
            return !policy.guildMuted
        case .everyone:
            // Discord's server mute preserves @everyone/@here unless the
            // dedicated suppress-everyone setting removes the mention first.
            return true
        }
    }

    func effectivePolicy(for entry: Entry, now: Date) -> EffectivePolicy {
        unreadPolicySource.effectivePolicy(for: entry, now: now)
    }

    func isGuildResourceChannel(_ entry: Entry) -> Bool {
        UnreadPolicySource.isGuildResourceChannel(
            entry,
            channelByID: unreadPolicySource.channelByID
        )
    }
}

extension AccountReadStateModel {
    /// Discord's account read-state snapshot is authoritative evidence that
    /// the account can see that conversation. Include the parent so joined
    /// thread read states keep their server unread marker while the parent
    /// guild's roles and overwrites are still loading.
    func authoritativeAccessEvidenceChannelIDs() -> Set<ChannelID> {
        var channelIDs = Set<ChannelID>()
        channelIDs.reserveCapacity(entries.count)
        for entry in entries.values where entry.hasAuthoritativeReadState {
            channelIDs.insert(entry.channelID)
            if let parentID = entry.parentID {
                channelIDs.insert(parentID)
            }
        }
        return channelIDs
    }

    func isCategoryMuted(
        categoryID: ChannelID,
        guildID: GuildID,
        at date: Date = .now
    ) -> Bool {
        guard let override = notificationOverride(
            channelID: categoryID,
            guildID: guildID
        ) else { return false }
        return override.isMuted
            && (override.muteConfiguration?.isActive(at: date) ?? true)
    }

    func isCategoryCollapsed(categoryID: ChannelID, guildID: GuildID) -> Bool {
        notificationOverride(
            channelID: categoryID,
            guildID: guildID
        )?.isCollapsed == true
    }

    func inheritedNotificationLevel(
        forCategoryIn guildID: GuildID
    ) -> MessageNotificationLevel {
        let configured = settingsByGuild[guildID]?.messageNotifications ?? .inherit
        if configured != .inherit {
            return configured
        }
        return unreadPolicySource.defaultNotificationLevelByGuild[guildID] ?? .onlyMentions
    }

    /// Discord acknowledges a forum up to the current time, so its boundary
    /// covers every post and reply so far, and any other conversation up to
    /// its newest message.
    nonisolated static func acknowledgementTarget(for entry: Entry, now: Date) -> MessageID? {
        entry.kind == .forum ? MessageID(timestamp: now) : entry.latestKnownMessageID
    }

    /// Discord's server Mark as Read and the server-list Read All scope:
    /// current server channels and active joined threads, including muted
    /// conversations, without DMs. Discord's bulk acknowledgement keeps every
    /// forum, read or not, and moves it to the current time.
    func allServerAcknowledgements(in guildIDs: Set<GuildID>) -> [BulkReadStateAcknowledgement] {
        let source = unreadPresentationSource()
        return entries.values.compactMap {
            serverAcknowledgement(for: $0, guildIDs: guildIDs, source: source)
        }.sorted { $0.channelID < $1.channelID }
    }

    func serverAcknowledgement(
        for entry: Entry,
        guildIDs: Set<GuildID>,
        source: UnreadPresentationSource
    ) -> BulkReadStateAcknowledgement? {
        guard let guildID = entry.guildID, guildIDs.contains(guildID),
              entry.isAccessible,
              entry.isUnread || entry.kind == .forum,
              source.isAggregateConversation(entry),
              !isGuildResourceChannel(entry),
              [.text, .announcement, .forum, .voice].contains(entry.kind),
              let messageID = Self.acknowledgementTarget(for: entry, now: .now)
        else { return nil }
        return BulkReadStateAcknowledgement(channelID: entry.channelID, messageID: messageID)
    }

    /// Discord's category Mark as Read (module 334738, build 649389) forces an
    /// acknowledgement of every readable child and its active joined threads,
    /// read or muted alike, at its newest message: a forum's latest post,
    /// not the current time.
    func categoryAcknowledgements(
        for categoryID: ChannelID,
        guildID: GuildID
    ) -> [BulkReadStateAcknowledgement] {
        let source = unreadPresentationSource()
        return entries.values.compactMap { entry in
            let belongsToCategory = entry.parentID == categoryID
                || entry.parentID.flatMap {
                    unreadPolicySource.channelByID[$0]?.categoryID
                } == categoryID
            guard entry.guildID == guildID,
                  belongsToCategory,
                  entry.isAccessible,
                  source.isAggregateConversation(entry),
                  !isGuildResourceChannel(entry),
                  [.text, .announcement, .forum, .voice].contains(entry.kind),
                  let messageID = entry.latestKnownMessageID
            else { return nil }
            return BulkReadStateAcknowledgement(
                channelID: entry.channelID,
                messageID: messageID
            )
        }
        .sorted { $0.channelID.rawValue < $1.channelID.rawValue }
    }

    /// Resolves every category carrying an acknowledgement-eligible unread
    /// conversation in one account-store pass. The sidebar renders all
    /// categories together, so a scan per header would multiply the same
    /// account-wide pass during startup updates.
    func unreadCategoryIDs(
        in guildID: GuildID
    ) -> Set<ChannelID> {
        var result: Set<ChannelID> = []
        let source = unreadPresentationSource()
        for entry in entries.values {
            guard entry.guildID == guildID,
                  entry.isAccessible,
                  entry.countsAsUnreadConversation && source.isAggregateConversation(entry)
                    || source.newForumPostParentID(of: entry) != nil,
                  !isGuildResourceChannel(entry),
                  let parentID = entry.parentID
            else { continue }
            let categoryID = unreadPolicySource.channelByID[parentID]?.categoryID ?? parentID
            result.insert(categoryID)
        }
        return result
    }
}
