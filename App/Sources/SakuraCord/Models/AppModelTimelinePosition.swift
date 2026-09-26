import DiscordProtocol
import SakuraCordModels

extension AppModel {
    func reportTimelineLiveScrolling(
        _ isScrolling: Bool,
        conversationID: ChannelID
    ) {
        let wasScrolling = !liveScrollingConversationIDs.isEmpty
        if isScrolling {
            liveScrollingConversationIDs.insert(conversationID)
        } else {
            liveScrollingConversationIDs.remove(conversationID)
        }
        let isScrollingNow = !liveScrollingConversationIDs.isEmpty
        guard wasScrolling != isScrollingNow else { return }
        timelineScrollActivityRevision &+= 1
        let revision = timelineScrollActivityRevision
        Task {
            await SharedAnimatedImageDecodeScheduler.shared
                .setInteractiveScrolling(
                    isScrollingNow,
                    source: .timeline,
                    revision: revision
                )
        }
        if !isScrollingNow {
            flushUnreadPresentationRefresh()
        }
    }

    func waitForTimelineScrollingToEnd() async -> Bool {
        while !liveScrollingConversationIDs.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    func resetTimelineLiveScrolling() {
        liveScrollingConversationIDs.removeAll(keepingCapacity: true)
        timelineScrollActivityRevision &+= 1
        let revision = timelineScrollActivityRevision
        Task {
            await SharedAnimatedImageDecodeScheduler.shared
                .setInteractiveScrolling(
                    false,
                    source: .timeline,
                    revision: revision
                )
        }
        flushUnreadPresentationRefresh()
    }

    func reportMainWindowActive(_ isActive: Bool) {
        let becameActive = isActive && !mainWindowIsActive
        mainWindowIsActive = isActive
        if becameActive, let guildID = selectedGuildID {
            if guildWorkspacePage == .channelsAndRoles {
                startAccountChildTask(account: accountSession()) { model, _ in
                    await model.synchronizeGuildCustomization(in: guildID)
                }
            } else if guildWorkspacePage == .guide {
                refreshGuildGuide(in: guildID)
            }
        }
        updateApplicationStreamWindowActivity(isActive)
        if let selectedChannelID {
            preserveUnreadDividerIfNeeded(channelID: selectedChannelID)
            if let target = readState.updatePresentation(
                channelID: selectedChannelID,
                windowIsActive: isActive
            ) {
                scheduleAcknowledgement(
                    channelID: selectedChannelID,
                    messageID: target
                )
            }
        }
        if let threadID = openThread?.id {
            preserveUnreadDividerIfNeeded(channelID: threadID)
            if let target = readState.updatePresentation(
                channelID: threadID,
                windowIsActive: isActive
            ) {
                scheduleAcknowledgement(channelID: threadID, messageID: target)
            }
        }
    }

    func reportApplicationActive(_ isActive: Bool) {
        applicationIsActive = isActive
        reconcilePrivateCallSounds()
        let session = accountSession()
        let precedingUpdate = clientAppStateUpdateTask
        clientAppStateUpdateTask = Task {
            await precedingUpdate?.value
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            await session.provider.updateClientAppState(isFocused: isActive)
        }
    }

    func reportTimelinePosition(
        channelID: ChannelID,
        hasReachedReadBoundary: Bool
    ) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        let previousBoundary =
            readState.presentations[channelID]?.hasReachedReadBoundary
        let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            hasReachedReadBoundary: hasReachedReadBoundary
        )
        if previousBoundary != hasReachedReadBoundary {
            let eligible = readState.presentations[channelID]?.canAcknowledge == true
            let channel = channelID.rawValue
            let reached = hasReachedReadBoundary
            let targetID = target?.rawValue ?? 0
            Self.unreadDiagnosticsLogger.debug(
                "Timeline bound c=\(channel, privacy: .public) r=\(reached, privacy: .public) e=\(eligible, privacy: .public) m=\(targetID, privacy: .public)"
            )
        }
        if let target {
            scheduleAcknowledgement(channelID: channelID, messageID: target)
        }
    }

    func reportTimelineInitialPosition(
        channelID: ChannelID,
        hasReachedReadBoundary: Bool
    ) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            initialPositionEstablished: true,
            hasReachedReadBoundary: hasReachedReadBoundary
        )
        let eligible = readState.presentations[channelID]?.canAcknowledge == true
        let channel = channelID.rawValue
        let reached = hasReachedReadBoundary
        let targetID = target?.rawValue ?? 0
        Self.unreadDiagnosticsLogger.debug(
            "Timeline initial c=\(channel, privacy: .public) r=\(reached, privacy: .public) e=\(eligible, privacy: .public) m=\(targetID, privacy: .public)"
        )
        if let target {
            scheduleAcknowledgement(channelID: channelID, messageID: target)
        }
    }

    func reportTimelineUserInteraction(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        readState.unblockAutomaticAcknowledgement(channelID: channelID)
    }

    func reportConversationHistoryLoaded(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        AppPerformanceSignposts.reportConversationHistoryReady(
            channelID: channelID
        )
        AppPerformanceSignposts.reportStartupConversationHistoryReady(
            channelID: channelID
        )
        preserveUnreadDividerIfNeeded(channelID: channelID)
        if let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            initialHistoryLoaded: true
        ) {
            scheduleAcknowledgement(channelID: channelID, messageID: target)
        }
    }

    func timelineUnreadSummary(
        channelID: ChannelID,
        messages: [Message],
        hasMoreBefore: Bool
    ) -> AccountReadStateModel.TimelineUnreadSummary? {
        readState.timelineUnreadSummary(
            channelID: channelID,
            messages: messages,
            hasMoreBefore: hasMoreBefore
        )
    }

}
