import DiscordProtocol
import Foundation
import OSLog
import SakuraCordModels
import UserNotifications

extension AppModel {
    func completeConversationReadingAndAdvance(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        markConversationRead(channelID: channelID)
        unreadDividerMessageIDs[channelID] = nil
        conversationNewestRequestID &+= 1
        conversationNewestRequest = ConversationNewestRequest(
            requestID: conversationNewestRequestID,
            channelID: channelID
        )
    }

    func preserveUnreadDividerIfNeeded(channelID: ChannelID) {
        guard unreadDividerMessageIDs[channelID] == nil else { return }
        let conversationMessages: [Message]
        let hasMoreBefore: Bool
        if channelID == openThread?.id {
            conversationMessages = threadMessages
            hasMoreBefore = hasMoreThreadMessages
                || (isLoadingThread && !threadMessages.isEmpty)
        } else if channelID == selectedChannelID {
            conversationMessages = messages
            hasMoreBefore = hasMoreMessages
                || (isLoadingMessages && !messages.isEmpty)
        } else {
            return
        }
        guard let summary = readState.timelineUnreadSummary(
            channelID: channelID,
            messages: conversationMessages,
            hasMoreBefore: hasMoreBefore
        ), !summary.isLowerBound
        else { return }
        unreadDividerMessageIDs[channelID] = summary.firstUnreadMessageID
    }

    func markMessageAndFollowingUnread(_ message: Message) {
        let channelID = message.channelID
        guard channelID == selectedChannelID || channelID == openThread?.id,
              message.id.rawValue > 0,
              let currentUserID = snapshot?.currentUser.id
        else { return }
        let conversationMessages =
            channelID == openThread?.id ? threadMessages : messages
        let mentionCount = readState.mentionCountForManualUnread(
            channelID: channelID,
            messages: conversationMessages,
            startingAt: message.id,
            currentUserID: currentUserID
        )
        let target = MessageID(rawValue: message.id.rawValue - 1)
        acknowledgementTasks[channelID]?.cancel()
        acknowledgementTasks[channelID] = nil
        queuedAcknowledgements[channelID] = nil
        acknowledgementQueueOrder.removeAll { $0 == channelID }
        readState.markUnread(
            channelID: channelID,
            after: target,
            mentionCount: mentionCount
        )
        // "Mark Unread" identifies the exact first-new row. Publish that
        // anchor in the same transaction instead of waiting for a later
        // timeline geometry callback to infer it from read state.
        unreadDividerMessageIDs[channelID] = message.id
        refreshUnreadPresentation()
        enqueueAcknowledgement(
            channelID: channelID,
            mutation: readStateMutation(
                channelID: channelID,
                messageID: target,
                manual: true,
                mentionCount: mentionCount
            )
        )
    }

    func requestNotificationPermission() async -> Bool {
        (try? await notificationService.requestAuthorization()) ?? false
    }

    func requestNotificationPermissionIfNeeded() async {
        guard notificationPreferences.isEnabled,
              await notificationService.authorizationStatus() == .notDetermined
        else { return }
        _ = try? await notificationService.requestAuthorization()
    }

    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await notificationService.authorizationStatus()
    }

    func refreshDockBadge() {
        notificationService.setDockBadge(
            readState.totalMentions,
            enabled: notificationPreferences.showsDockBadge
        )
    }

    func acknowledgeIfEligible(channelID: ChannelID) {
        guard let target = readState.updatePresentation(channelID: channelID) else { return }
        scheduleAcknowledgement(channelID: channelID, messageID: target)
    }

    func acknowledgeForumVisitIfNeeded(channelID: ChannelID, now: Date = .now) {
        guard selectedChannelID == channelID,
              selectedChannel?.kind == .forum,
              readState.shouldAcknowledgeForumVisit(channelID: channelID),
              let target = Self.forumAcknowledgementBoundary(at: now)
        else { return }
        readState.markAcknowledgementPending(channelID: channelID, messageID: target)
        refreshUnreadPresentation()
        cancelNativeNotifications(channelID: channelID)
        enqueueAcknowledgement(
            channelID: channelID,
            mutation: readStateMutation(
                channelID: channelID,
                messageID: target,
                manual: false,
                mentionCount: nil
            )
        )
    }

    nonisolated static func forumAcknowledgementBoundary(at date: Date) -> MessageID? {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1_000))
        guard milliseconds >= ClientNonce.discordEpochMilliseconds else { return nil }
        return MessageID(
            rawValue: (milliseconds - ClientNonce.discordEpochMilliseconds) << 22
        )
    }

    func scheduleAcknowledgement(channelID: ChannelID, messageID: MessageID) {
        if let pending = readState.entries[channelID]?.pendingAcknowledgementID,
           pending >= messageID
        {
            return
        }
        acknowledgementTasks[channelID]?.cancel()
        readState.markAcknowledgementPending(channelID: channelID, messageID: messageID)
        Self.unreadDiagnosticsLogger.info(
            "Read acknowledgement scheduled; channel=\(channelID.rawValue, privacy: .public), target=\(messageID.rawValue, privacy: .public)"
        )
        refreshUnreadPresentation()
        cancelNativeNotifications(channelID: channelID)
        let debounce = readAcknowledgementTiming.debounce
        acknowledgementTasks[channelID] = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                guard let self, !Task.isCancelled else { return }
                self.enqueueAcknowledgement(
                    channelID: channelID,
                    mutation: self.readStateMutation(
                        channelID: channelID,
                        messageID: messageID,
                        manual: false,
                        mentionCount: nil
                    )
                )
                self.acknowledgementTasks[channelID] = nil
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func enqueueAcknowledgement(
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        if let queued = queuedAcknowledgements[channelID] {
            if mutation.manual || !queued.manual {
                queuedAcknowledgements[channelID] =
                    mutation.manual
                    ? mutation
                    : ReadStateMutation(
                        messageID: max(queued.messageID, mutation.messageID),
                        manual: false,
                        mentionCount: nil,
                        flags: mutation.flags,
                        lastViewed: mutation.lastViewed
                    )
            }
        } else {
            queuedAcknowledgements[channelID] = mutation
            acknowledgementQueueOrder.append(channelID)
        }
        guard acknowledgementProcessorTask == nil else { return }
        let generation = acknowledgementGeneration
        acknowledgementProcessorTask = Task { [weak self] in
            await self?.drainAcknowledgementQueue(generation: generation)
        }
    }

    func drainAcknowledgementQueue(generation: Int) async {
        while !Task.isCancelled,
              generation == acknowledgementGeneration,
              let channelID = acknowledgementQueueOrder.first
        {
            acknowledgementQueueOrder.removeFirst()
            guard let mutation = queuedAcknowledgements.removeValue(forKey: channelID) else {
                continue
            }
            do {
                logReadAcknowledgementSending(channelID: channelID, mutation: mutation)
                let response = try await provider.acknowledge(
                    channelID: channelID,
                    messageID: mutation.messageID,
                    token: readState.acknowledgementToken,
                    manual: mutation.manual,
                    mentionCount: mutation.mentionCount,
                    flags: mutation.flags,
                    lastViewed: mutation.lastViewed
                )
                guard !Task.isCancelled, generation == acknowledgementGeneration else { return }
                readState.completeAcknowledgement(
                    channelID: channelID,
                    messageID: mutation.messageID,
                    token: response.token
                )
                logReadAcknowledgementAccepted(channelID: channelID, mutation: mutation)
            } catch is CancellationError {
                return
            } catch {
                guard generation == acknowledgementGeneration else { return }
                readState.failAcknowledgement(
                    channelID: channelID,
                    messageID: mutation.messageID
                )
                logReadAcknowledgementFailed(channelID: channelID, mutation: mutation)
                refreshUnreadPresentation()
                if mutation.manual {
                    errorMessage = "Discord did not accept the read-state update."
                }
            }
        }
        if generation == acknowledgementGeneration {
            acknowledgementProcessorTask = nil
        }
    }
}
