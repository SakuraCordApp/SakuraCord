import SakuraCordModels

private struct UnreadChannelPresentationProjection {
    var channels: [Channel]
    var visibleChannels: [Channel]
    var changed: Bool
}

private struct UnreadGuildPresentationProjection {
    var guilds: [Guild]
    var changed: Bool
}

extension AppModel {
    func refreshUnreadPresentation(
        appliesAccessImmediately: Bool = false,
        accessAffectedGuildIDs: Set<GuildID>? = nil
    ) {
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "UnreadPresentationRefresh"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "UnreadPresentationRefresh",
                interval
            )
        }
        // Permission and unread projection walks every channel, role, guild,
        // and sidebar row. Gateway bursts can request it repeatedly while the
        // user is scrolling; doing that work mid-gesture caused hundreds of
        // milliseconds of main-thread starvation. Access-affecting events are
        // the exception: apply their security projection immediately, while
        // retaining the broader sidebar/unread publication until scrolling
        // ends.
        if appliesAccessImmediately, let channels = snapshot?.channels {
            _ = AppPerformanceSignposts.measureSync(
                "UnreadImmediateAccessProjection"
            ) {
                applyImmediateUnreadAccessProjection(
                    for: channels,
                    affectedGuildIDs: accessAffectedGuildIDs
                )
            }
            // Access revocation and checking/readable transitions are applied
            // synchronously above. Publish the broader unread/sidebar
            // projection on a separate bounded turn so two independently
            // sub-frame operations never become one full-frame main-actor
            // stall during a gateway burst.
            requestCoalescedUnreadPresentationRefresh()
            return
        }
        guard liveScrollingConversationIDs.isEmpty else {
            hasDeferredUnreadPresentationRefresh = true
            return
        }
        hasDeferredUnreadPresentationRefresh = false
        guard let value = snapshot else {
            notificationService.setDockBadge(
                readState.totalMentions,
                enabled: notificationPreferences.showsDockBadge
            )
            return
        }
        // Ordinary read-state changes do not alter channel permissions. Access
        // events already applied their projection above, so avoid rebuilding
        // every guild's permission masks for message and acknowledgement churn.
        let unreadProjection = AppPerformanceSignposts.measureSync(
            "UnreadStateProjection"
        ) {
            readState.unreadPresentationProjection()
        }
        if unreadProjection.unreadCategoryIDsByGuild
            != unreadCategoryIDsByGuild
        {
            unreadCategoryIDsByGuild = unreadProjection.unreadCategoryIDsByGuild
        }
        let channelProjection = AppPerformanceSignposts.measureSync(
            "UnreadChannelProjection"
        ) {
            unreadChannelPresentationProjection(
                channels: value.channels,
                unread: unreadProjection
            )
        }
        let guildProjection = AppPerformanceSignposts.measureSync(
            "UnreadGuildProjection"
        ) {
            unreadGuildPresentationProjection(
                guilds: value.guilds,
                unread: unreadProjection
            )
        }
        publishUnreadPresentation(
            snapshotValue: value,
            channelProjection: channelProjection,
            guildProjection: guildProjection,
            totalMentions: unreadProjection.totalMentions
        )
    }

    private func unreadChannelPresentationProjection(
        channels source: [Channel],
        unread: AccountReadStateModel.UnreadPresentationProjection
    ) -> UnreadChannelPresentationProjection {
        var channels = source
        var visibleChannels: [Channel] = []
        visibleChannels.reserveCapacity(self.visibleChannels.count)
        var changed = false
        for index in channels.indices {
            let unreadCount =
                channels[index].kind == .forum
                ? unread.newForumPostsByChannelID[channels[index].id, default: 0]
                : (unread.unreadByChannelID[channels[index].id] == true ? 1 : 0)
            let mentionCount = unread.mentionsByChannelID[
                channels[index].id,
                default: 0
            ]
            if channels[index].unreadCount != unreadCount
                || channels[index].mentionCount != mentionCount
            {
                channels[index].unreadCount = unreadCount
                channels[index].mentionCount = mentionCount
                changed = true
            }
            let channel = channels[index]
            if let selectedGuildID {
                if channel.guildID == selectedGuildID {
                    visibleChannels.append(channel)
                }
            } else if channel.guildID == nil {
                visibleChannels.append(channel)
            }
        }
        return UnreadChannelPresentationProjection(
            channels: channels,
            visibleChannels: visibleChannels,
            changed: changed
        )
    }

    private func unreadGuildPresentationProjection(
        guilds source: [Guild],
        unread: AccountReadStateModel.UnreadPresentationProjection
    ) -> UnreadGuildPresentationProjection {
        var guilds = source
        var changed = false
        for index in guilds.indices {
            let unreadCount =
                unread.unreadByGuildID[guilds[index].id] == true ? 1 : 0
            let mentionCount = unread.mentionsByGuildID[
                guilds[index].id,
                default: 0
            ]
            if guilds[index].unreadCount != unreadCount
                || guilds[index].mentionCount != mentionCount
            {
                guilds[index].unreadCount = unreadCount
                guilds[index].mentionCount = mentionCount
                changed = true
            }
        }
        return UnreadGuildPresentationProjection(
            guilds: guilds,
            changed: changed
        )
    }

    private func publishUnreadPresentation(
        snapshotValue: BootstrapSnapshot,
        channelProjection: UnreadChannelPresentationProjection,
        guildProjection: UnreadGuildPresentationProjection,
        totalMentions: Int
    ) {
        var value = snapshotValue
        AppPerformanceSignposts.measureSync(
            "UnreadPresentationPublication"
        ) {
            if channelProjection.changed || guildProjection.changed {
                value.channels = channelProjection.channels
                value.guilds = guildProjection.guilds
                snapshot = value
            }
            let projectedGuildsByID = Dictionary(
                uniqueKeysWithValues: guildProjection.guilds.map { ($0.id, $0) }
            )
            if projectedGuildsByID != serverRailGuildsByID {
                serverRailGuildsByID = projectedGuildsByID
            }
        }
        let selectedGuildChannels = channelProjection.visibleChannels
        if selectedGuildChannels != visibleChannels {
            visibleChannels = selectedGuildChannels
        }
        if let selectedChannelID,
           !selectedGuildChannels.contains(where: { $0.id == selectedChannelID })
        {
            self.selectedChannelID = Self.preferredInitialChannelID(
                in: selectedGuildChannels.filter {
                    conversationAccess(for: $0) != .hidden
                }
            )
        }
        let projectedSelectedChannel =
            selectedChannelID.flatMap { id in
                channelProjection.channels.first { $0.id == id }
            }
                ?? selectedChannel
        if projectedSelectedChannel != selectedChannel {
            selectedChannel = projectedSelectedChannel
        }
        notificationService.setDockBadge(
            totalMentions,
            enabled: notificationPreferences.showsDockBadge
        )
    }
}
