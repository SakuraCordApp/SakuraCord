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

    func bulkAcknowledgements(
        for guildID: GuildID,
        now: Date = .now
    ) -> [BulkReadStateAcknowledgement] {
        entries.values.compactMap { entry in
            guard entry.guildID == guildID,
                  unread(channelID: entry.channelID, now: now),
                  let messageID = entry.latestKnownMessageID
            else { return nil }
            return BulkReadStateAcknowledgement(
                channelID: entry.channelID,
                messageID: messageID
            )
        }
        .sorted { $0.channelID.rawValue < $1.channelID.rawValue }
    }

    func bulkAcknowledgements(
        for categoryID: ChannelID,
        guildID: GuildID,
        now: Date = .now
    ) -> [BulkReadStateAcknowledgement] {
        entries.values.compactMap { entry in
            let belongsToCategory = entry.parentID == categoryID
                || entry.parentID.flatMap {
                    unreadPolicySource.channelByID[$0]?.categoryID
                } == categoryID
            guard entry.guildID == guildID,
                  belongsToCategory,
                  entry.isAccessible,
                  entry.isUnread,
                  !isGuildResourceChannel(entry),
                  entry.kind != .voice || entry.mentionCount > 0,
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
    /// categories together, so asking `bulkAcknowledgements` once per header
    /// multiplied the same account-wide scan during startup updates.
    func unreadCategoryIDs(
        in guildID: GuildID
    ) -> Set<ChannelID> {
        var result: Set<ChannelID> = []
        for entry in entries.values {
            guard entry.guildID == guildID,
                  entry.isAccessible,
                  entry.countsAsUnreadConversation,
                  !isGuildResourceChannel(entry),
                  let parentID = entry.parentID
            else { continue }
            let categoryID = unreadPolicySource.channelByID[parentID]?.categoryID ?? parentID
            result.insert(categoryID)
        }
        return result
    }
}
