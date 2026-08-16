import SakuraCordModels

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
        var immediateAccessProjection: UnreadAccessProjection?
        if appliesAccessImmediately, let channels = snapshot?.channels {
            immediateAccessProjection = AppPerformanceSignposts.measureSync(
                "UnreadImmediateAccessProjection"
            ) {
                applyImmediateUnreadAccessProjection(
                    for: channels,
                    affectedGuildIDs: accessAffectedGuildIDs
                )
            }
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
        let accessByChannelID = immediateAccessProjection?.accessByChannelID ?? [:]
        let unreadProjection = AppPerformanceSignposts.measureSync(
            "UnreadStateProjection"
        ) {
            readState.unreadPresentationProjection()
        }
        let projectedChannels = AppPerformanceSignposts.measureSync(
            "UnreadChannelProjection"
        ) {
            value.channels.map { channel in
                var channel = channel
                channel.unreadCount =
                    channel.kind == .forum
                    ? unreadProjection.newForumPostsByChannelID[
                        channel.id,
                        default: 0
                    ]
                    : (unreadProjection.unreadByChannelID[channel.id] == true ? 1 : 0)
                channel.mentionCount = unreadProjection.mentionsByChannelID[
                    channel.id,
                    default: 0
                ]
                return channel
            }
        }
        let projectedGuilds = AppPerformanceSignposts.measureSync(
            "UnreadGuildProjection"
        ) {
            value.guilds.map { guild in
                var guild = guild
                guild.unreadCount =
                    unreadProjection.unreadByGuildID[guild.id] == true ? 1 : 0
                guild.mentionCount = unreadProjection.mentionsByGuildID[
                    guild.id,
                    default: 0
                ]
                return guild
            }
        }
        publishUnreadPresentation(
            snapshotValue: value,
            projectedChannels: projectedChannels,
            projectedGuilds: projectedGuilds,
            accessByChannelID: accessByChannelID,
            totalMentions: unreadProjection.totalMentions
        )
    }

    private func publishUnreadPresentation(
        snapshotValue: BootstrapSnapshot,
        projectedChannels: [Channel],
        projectedGuilds: [Guild],
        accessByChannelID: [ChannelID: ConversationAccess],
        totalMentions: Int
    ) {
        var value = snapshotValue
        AppPerformanceSignposts.measureSync(
            "UnreadPresentationPublication"
        ) {
            if UnreadPresentationPublicationPolicy.shouldPublish(
                snapshot: value,
                channels: projectedChannels,
                guilds: projectedGuilds
            ) {
                value.channels = projectedChannels
                value.guilds = projectedGuilds
                snapshot = value
            }
            let projectedGuildsByID = Dictionary(
                uniqueKeysWithValues: projectedGuilds.map { ($0.id, $0) }
            )
            if projectedGuildsByID != serverRailGuildsByID {
                serverRailGuildsByID = projectedGuildsByID
            }
        }
        let selectedGuildChannels = AppPerformanceSignposts.measureSync(
            "UnreadVisibleChannelProjection"
        ) {
            if let selectedGuildID {
                projectedChannels.filter { $0.guildID == selectedGuildID }
            } else {
                projectedChannels.filter { $0.guildID == nil }
            }
        }
        if selectedGuildChannels != visibleChannels {
            visibleChannels = selectedGuildChannels
        }
        if let selectedChannelID,
           !selectedGuildChannels.contains(where: { $0.id == selectedChannelID })
        {
            self.selectedChannelID = Self.preferredInitialChannelID(
                in: selectedGuildChannels.filter {
                    (accessByChannelID[$0.id] ?? conversationAccess(for: $0))
                        != .hidden
                }
            )
        }
        let projectedSelectedChannel =
            selectedChannelID.flatMap { id in
                projectedChannels.first { $0.id == id }
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
