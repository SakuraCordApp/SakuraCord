import Foundation
import OSLog
import SakuraCordModels

private nonisolated struct UnreadChannelPresentationProjection: Sendable {
    var channels: [Channel]
    var visibleChannels: [Channel]
    var changed: Bool
}

private nonisolated struct UnreadGuildPresentationProjection: Sendable {
    var guilds: [Guild]
    var changed: Bool
}

private nonisolated struct PreparedUnreadPresentation: Sendable {
    var unread: AccountReadStateModel.UnreadPresentationProjection
    var channels: UnreadChannelPresentationProjection
    var guilds: UnreadGuildPresentationProjection
    var serverRailGuildsByID: [GuildID: Guild]
}

private nonisolated struct UnreadPresentationPreparationSource: Sendable {
    var readState: AccountReadStateModel.UnreadPresentationSource
    var channels: [Channel]
    var guilds: [Guild]
    var selectedGuildID: GuildID?
    var visibleChannelCapacity: Int
    var observesAppScrollWorkGate: Bool

    func prepare() -> PreparedUnreadPresentation? {
        let signposter = OSSignposter(
            subsystem: "dev.sakuracord.SakuraCord",
            category: "PointsOfInterest"
        )
        let preparation = signposter.beginInterval(
            "UnreadPresentationPreparation"
        )
        defer {
            signposter.endInterval(
                "UnreadPresentationPreparation",
                preparation
            )
        }
        let readInterval = signposter.beginInterval("UnreadStateProjection")
        guard let unread = readState.projection(
            cancelsCooperatively: true,
            cancellationCheck: {
                Task.isCancelled
                    || (observesAppScrollWorkGate
                        && AppScrollWorkGate.isActive)
            }
        ) else {
            signposter.endInterval("UnreadStateProjection", readInterval)
            return nil
        }
        signposter.endInterval("UnreadStateProjection", readInterval)

        let channelInterval = signposter.beginInterval(
            "UnreadChannelProjection"
        )
        guard let channelProjection = prepareChannels(unread: unread) else {
            signposter.endInterval(
                "UnreadChannelProjection",
                channelInterval
            )
            return nil
        }
        signposter.endInterval("UnreadChannelProjection", channelInterval)

        let guildInterval = signposter.beginInterval("UnreadGuildProjection")
        guard let guildProjection = prepareGuilds(unread: unread) else {
            signposter.endInterval("UnreadGuildProjection", guildInterval)
            return nil
        }
        signposter.endInterval("UnreadGuildProjection", guildInterval)
        guard !Task.isCancelled,
              !observesAppScrollWorkGate || !AppScrollWorkGate.isActive
        else {
            return nil
        }
        let railInterval = signposter.beginInterval(
            "UnreadServerRailProjection"
        )
        let serverRailGuildsByID = Dictionary(
            uniqueKeysWithValues: guildProjection.guilds.map { ($0.id, $0) }
        )
        signposter.endInterval("UnreadServerRailProjection", railInterval)
        return PreparedUnreadPresentation(
            unread: unread,
            channels: channelProjection,
            guilds: guildProjection,
            serverRailGuildsByID: serverRailGuildsByID
        )
    }

    private func prepareChannels(
        unread: AccountReadStateModel.UnreadPresentationProjection
    ) -> UnreadChannelPresentationProjection? {
        var projected = channels
        var visibleChannels: [Channel] = []
        visibleChannels.reserveCapacity(visibleChannelCapacity)
        var changed = false
        for index in projected.indices {
            if index.isMultiple(of: 64),
               Task.isCancelled
                   || (observesAppScrollWorkGate
                       && AppScrollWorkGate.isActive)
            {
                return nil
            }
            let unreadCount = projected[index].kind == .forum
                ? unread.newForumPostsByChannelID[projected[index].id, default: 0]
                : (unread.unreadByChannelID[projected[index].id] == true ? 1 : 0)
            let mentionCount = unread.mentionsByChannelID[
                projected[index].id,
                default: 0
            ]
            if projected[index].unreadCount != unreadCount
                || projected[index].mentionCount != mentionCount
            {
                projected[index].unreadCount = unreadCount
                projected[index].mentionCount = mentionCount
                changed = true
            }
            let channel = projected[index]
            if let selectedGuildID {
                if channel.guildID == selectedGuildID {
                    visibleChannels.append(channel)
                }
            } else if channel.guildID == nil {
                visibleChannels.append(channel)
            }
        }
        return UnreadChannelPresentationProjection(
            channels: projected,
            visibleChannels: visibleChannels,
            changed: changed
        )
    }

    private func prepareGuilds(
        unread: AccountReadStateModel.UnreadPresentationProjection
    ) -> UnreadGuildPresentationProjection? {
        var projected = guilds
        var changed = false
        for index in projected.indices {
            if index.isMultiple(of: 64),
               Task.isCancelled
                   || (observesAppScrollWorkGate
                       && AppScrollWorkGate.isActive)
            {
                return nil
            }
            let unreadCount = unread.unreadByGuildID[projected[index].id] == true
                ? 1
                : 0
            let mentionCount = unread.mentionsByGuildID[
                projected[index].id,
                default: 0
            ]
            if projected[index].unreadCount != unreadCount
                || projected[index].mentionCount != mentionCount
            {
                projected[index].unreadCount = unreadCount
                projected[index].mentionCount = mentionCount
                changed = true
            }
        }
        return UnreadGuildPresentationProjection(
            guilds: projected,
            changed: changed
        )
    }
}

extension AppModel {
    var isAppScrollDeferringUnread: Bool {
        launchMode == .normal && AppScrollActivity.isActive
    }

    /// Bootstrap may expose the workspace before this finishes, but its async
    /// API must not return while the initial sidebar unread projection is
    /// still pending. This preserves the atomic startup contract without
    /// putting the projection back on the main actor.
    func waitForUnreadPresentationPreparation() async {
        if unreadPresentationRefreshTask != nil {
            unreadPresentationRefreshTask?.cancel()
            unreadPresentationRefreshTask = nil
        }
        if hasDeferredUnreadPresentationRefresh,
           liveScrollingConversationIDs.isEmpty
        {
            flushUnreadPresentationRefresh()
        }
        while let task = unreadPresentationPreparationTask {
            await task.value
            guard !Task.isCancelled else { return }
        }
    }

    func refreshUnreadPresentation(
        appliesAccessImmediately: Bool = false,
        accessAffectedGuildIDs: Set<GuildID>? = nil,
        accessAffectedChannelIDs: Set<ChannelID> = [],
        accessReplacingChannelIDs: Set<ChannelID>? = nil,
        accessAffectedChannels: [Channel]? = nil
    ) {
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "UnreadPresentationRefreshRequest"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "UnreadPresentationRefreshRequest",
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
                    affectedGuildIDs: accessAffectedGuildIDs,
                    affectedChannelIDs: accessAffectedChannelIDs,
                    replacingChannelIDs: accessReplacingChannelIDs,
                    affectedChannels: accessAffectedChannels
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
        guard liveScrollingConversationIDs.isEmpty,
              !isAppScrollDeferringUnread
        else {
            hasDeferredUnreadPresentationRefresh = true
            requestCoalescedUnreadPresentationRefresh()
            return
        }
        hasDeferredUnreadPresentationRefresh = false
        // Notification delivery/cancellation and its Dock badge remain one
        // observable transaction. The wider sidebar projection is allowed to
        // finish asynchronously, but a delivered mention must never briefly
        // expose the previous badge count.
        let totalMentions = AppPerformanceSignposts.measureSync(
            "UnreadDockBadgeProjection"
        ) {
            readState.totalMentions
        }
        let badgeCount: Int? = switch notificationPreferences.dockBadgeStyle {
        case .mentions: totalMentions
        case .unreadConversations:
            readState.unreadPresentationProjection().unreadByChannelID.values.count { $0 }
        case .off: nil
        }
        notificationService.setDockBadge(
            badgeCount ?? 0,
            enabled: badgeCount != nil
        )
        unreadPresentationPreparationGeneration &+= 1
        guard snapshot != nil else {
            return
        }
        beginUnreadPresentationPreparationIfNeeded()
    }

    private func beginUnreadPresentationPreparationIfNeeded() {
        guard unreadPresentationPreparationTask == nil,
              snapshot != nil,
              liveScrollingConversationIDs.isEmpty,
              !isAppScrollDeferringUnread
        else { return }
        let account = accountSession()
        unreadPresentationPreparationSequence &+= 1
        let sequence = unreadPresentationPreparationSequence
        unreadPresentationPreparationTask = Task { @MainActor [weak self] in
            do {
                // Own this debounce in the model rather than a view or event
                // task. READY and pagination bursts can then advance the
                // generation freely while one guaranteed preparation starts
                // from their latest value-semantic stores.
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return
            }
            guard let self,
                  self.unreadPresentationPreparationSequence == sequence
            else { return }
            guard !Task.isCancelled,
                  self.isCurrentAccountSession(account),
                  let value = self.snapshot
            else {
                self.unreadPresentationPreparationTask = nil
                return
            }
            guard self.liveScrollingConversationIDs.isEmpty,
                  !self.isAppScrollDeferringUnread
            else {
                self.unreadPresentationPreparationTask = nil
                self.hasDeferredUnreadPresentationRefresh = true
                self.requestCoalescedUnreadPresentationRefresh()
                return
            }
            let generation = self.unreadPresentationPreparationGeneration
            let sourceRevision = self.snapshotSourceRevision
            let sourceSelectedGuildID = self.selectedGuildID
            let source = AppPerformanceSignposts.measureSync(
                "UnreadPresentationSourceSnapshot"
            ) {
                UnreadPresentationPreparationSource(
                    readState: self.readState.unreadPresentationSource(),
                    channels: value.channels,
                    guilds: value.guilds,
                    selectedGuildID: sourceSelectedGuildID,
                    visibleChannelCapacity: self.visibleChannels.count,
                    observesAppScrollWorkGate: self.launchMode == .normal
                )
            }
            self.activeUnreadPreparationGeneration = generation
            let worker = Task.detached(priority: .userInitiated) {
                source.prepare()
            }
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard self.unreadPresentationPreparationSequence == sequence,
                  self.activeUnreadPreparationGeneration == generation
            else { return }
            self.unreadPresentationPreparationTask = nil
            self.activeUnreadPreparationGeneration = nil
            guard !Task.isCancelled,
                  self.isCurrentAccountSession(account)
            else { return }
            guard let prepared else {
                self.hasDeferredUnreadPresentationRefresh = true
                self.requestCoalescedUnreadPresentationRefresh()
                return
            }
            guard self.liveScrollingConversationIDs.isEmpty,
                  !self.isAppScrollDeferringUnread
            else {
                self.hasDeferredUnreadPresentationRefresh = true
                self.requestCoalescedUnreadPresentationRefresh()
                return
            }
            guard self.unreadPresentationPreparationGeneration == generation,
                  self.snapshotSourceRevision == sourceRevision,
                  self.selectedGuildID == sourceSelectedGuildID
            else {
                self.beginUnreadPresentationPreparationIfNeeded()
                return
            }
            self.applyPreparedUnreadPresentation(
                prepared,
                snapshotValue: value
            )
        }
    }

    private func applyPreparedUnreadPresentation(
        _ prepared: PreparedUnreadPresentation,
        snapshotValue: BootstrapSnapshot
    ) {
        let refresh = AppPerformanceSignposts.signposter.beginInterval(
            "UnreadPresentationRefresh"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "UnreadPresentationRefresh",
                refresh
            )
        }
        if prepared.unread.unreadCategoryIDsByGuild
            != unreadCategoryIDsByGuild
        {
            unreadCategoryIDsByGuild = prepared.unread.unreadCategoryIDsByGuild
        }
        if serverRailHomeIsUnread != prepared.unread.directMessageUnread {
            serverRailHomeIsUnread = prepared.unread.directMessageUnread
        }
        if serverRailHomeMentionCount != prepared.unread.directMessageMentions {
            serverRailHomeMentionCount = prepared.unread.directMessageMentions
        }
        publishUnreadPresentation(
            snapshotValue: snapshotValue,
            channelProjection: prepared.channels,
            guildProjection: prepared.guilds,
            projectedGuildsByID: prepared.serverRailGuildsByID
        )
    }

    private func publishUnreadPresentation(
        snapshotValue: BootstrapSnapshot,
        channelProjection: UnreadChannelPresentationProjection,
        guildProjection: UnreadGuildPresentationProjection,
        projectedGuildsByID: [GuildID: Guild]
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
            if projectedGuildsByID != serverRailGuildsByID {
                replaceServerRailGuilds(projectedGuildsByID)
            } else {
                // Notification settings can change without changing the Guild
                // projection. Refreshing the stable entries updates only rows
                // whose projected menu state actually changed.
                refreshServerRailPresentation()
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
    }
}
