import DiscordProtocol
import SakuraCordModels

extension AppModel {
    // Guild pages retain sidebar selection while replacing its conversation.
    func isConversationPresented(_ channelID: ChannelID) -> Bool {
        guard onboardingEntryGuildID == nil else { return false }
        if openThread?.id == channelID { return true }
        guard !isThreadFullWidth, selectedChannelID == channelID else { return false }
        guard guildWorkspacePage != nil else { return true }
        return !hasThreadPane && customizationPreviewChannel?.id == channelID
    }

    func suspendSelectedConversationPresentation() {
        guard let selectedChannelID else { return }
        _ = readState.updatePresentation(
            channelID: selectedChannelID,
            isPresented: false,
            initialPositionEstablished: false,
            hasReachedReadBoundary: false
        )
    }

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
                isPresented: isConversationPresented(selectedChannelID),
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
                isPresented: isConversationPresented(threadID),
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
        guard isConversationPresented(channelID) else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        let previousBoundary =
            readState.presentations[channelID]?.hasReachedReadBoundary
        let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            hasReachedReadBoundary: hasReachedReadBoundary
        )
        if previousBoundary != hasReachedReadBoundary {
            let eligible = readState.canAcknowledge(channelID)
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
        guard isConversationPresented(channelID) else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        // Opening a long backlog at its newest message shows only its tail.
        // Like Discord, that visit stays unread until the reader scrolls
        // toward the newest message again or chooses Mark as Read.
        let holdsBacklog = hasReachedReadBoundary
            && hasUnresolvedUnreadBoundary(channelID: channelID)
        let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            initialPositionEstablished: true,
            hasReachedReadBoundary: hasReachedReadBoundary,
            blocksAutomaticAcknowledgement: holdsBacklog ? true : nil
        )
        let eligible = readState.canAcknowledge(channelID)
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

    /// Releases a held visit. A scroll clamped at the newest edge reports no
    /// new position, so an already visible newest message is acknowledged here.
    func reportTimelineScrollTowardNewest(channelID: ChannelID) {
        guard readState.holdsAutomaticAcknowledgement(channelID),
              isConversationPresented(channelID),
              let target = readState.unblockAutomaticAcknowledgement(channelID: channelID)
        else { return }
        scheduleAcknowledgement(channelID: channelID, messageID: target)
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
            isPresented: isConversationPresented(channelID),
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
