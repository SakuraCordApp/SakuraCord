import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func markAllInboxRead() {
        markInboxGroupsRead(inbox.groups)
    }

    func markInboxGuildRead(_ guildID: GuildID) {
        var groups = inbox.groups.filter { $0.guildID == guildID }
        if !groups.contains(where: \.isEvents), let state = inbox.scheduledEvents.readStates[guildID],
           let newest = state.latestID, newest != state.lastAcknowledgedID {
            groups.append(InboxUnreadGroup(
                channelID: ChannelID(rawValue: guildID.rawValue), guildID: guildID,
                title: "Events", subtitle: nil,
                oldestReadMessageID: state.lastAcknowledgedID.map { MessageID(rawValue: $0.rawValue) },
                newestUnreadMessageID: MessageID(rawValue: newest.rawValue), mentionCount: state.mentionCount,
                isEvents: true
            ))
        }
        let channelIDs = Set((snapshot?.channels.filter { $0.guildID == guildID }.map(\.id) ?? [])
            + (snapshot?.activeJoinedThreads.filter { $0.guildID == guildID }.map(\.id) ?? []))
        let forumBoundary = Self.forumAcknowledgementBoundary(at: .now)
        let targets = readState.entries.values.compactMap { entry -> BulkReadStateAcknowledgement? in
            guard channelIDs.contains(entry.channelID), entry.isAccessible,
                  let newest = entry.latestKnownMessageID else { return nil }
            return BulkReadStateAcknowledgement(
                channelID: entry.channelID, messageID: entry.kind == .forum ? (forumBoundary ?? newest) : newest
            )
        }.sorted { $0.channelID < $1.channelID }
        markInboxGroupsRead(groups, additionalTargets: targets)
    }

    private func markInboxGroupsRead(_ groups: [InboxUnreadGroup], additionalTargets: [BulkReadStateAcknowledgement] = []) {
        guard inbox.bulkTask == nil else { return }
        let previousEventStates = inbox.scheduledEvents.readStates
        let targets = inboxBulkTargets(groups, additionalTargets: additionalTargets)
        guard !targets.isEmpty else { return }
        let previousEventTasks = groups.compactMap { $0.guildID.flatMap { inbox.eventMutationTasks[$0] } }
        stageInboxBulkRead(groups)
        let groupIDs = Set(groups.map(\.id))
        inbox.groups.removeAll { groupIDs.contains($0.id) }
        inbox.undoGroups.removeAll { groupIDs.contains($0.id) }
        publishInbox()
        prepareInboxBulkChannels(targets)
        refreshUnreadPresentation()
        let session = accountSession()
        inbox.bulkTask = Task { [weak self] in
            guard let self else { return }
            for task in previousEventTasks { await task.value }
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            do {
                try await session.provider.acknowledgeBulk(targets)
                guard isCurrentAccountSession(session) else { return }
                for target in targets where target.readStateType == 0 {
                    readState.completeAcknowledgement(channelID: target.channelID, messageID: target.messageID, token: nil)
                    if readState[target.channelID]?.isUnread != true {
                        cancelNativeNotifications(channelID: target.channelID)
                    }
                }
            } catch let partial as PartialBulkReadAcknowledgementError {
                guard isCurrentAccountSession(session) else { return }
                resolvePartialBulkAcknowledgement(partial, targets: targets.filter { $0.readStateType == 0 })
                restoreFailedInboxEventGroups(groups, accepted: partial.acceptedReadStates, previousStates: previousEventStates)
                inbox.errorMessage = partial.failureDescription
            } catch {
                guard isCurrentAccountSession(session) else { return }
                restoreFailedInboxEventGroups(groups, accepted: [], previousStates: previousEventStates)
                for target in targets where target.readStateType == 0 { readState.failAcknowledgement(channelID: target.channelID, messageID: target.messageID) }
                inbox.errorMessage = error.localizedDescription
            }
            for group in groups where group.isEvents {
                if let guildID = group.guildID,
                   inbox.pendingEventAcknowledgements[guildID]?.rawValue == group.newestUnreadMessageID.rawValue {
                    inbox.pendingEventAcknowledgements[guildID] = nil
                }
            }
            refreshUnreadPresentation()
            reconcileInboxReadState()
            inbox.bulkTask = nil
        }
    }
}

extension AppModel {
    private func inboxBulkTargets(_ groups: [InboxUnreadGroup], additionalTargets: [BulkReadStateAcknowledgement]) -> [BulkReadStateAcknowledgement] {
        var targets = groups.map {
            BulkReadStateAcknowledgement(channelID: $0.id, messageID: $0.newestUnreadMessageID, readStateType: $0.isEvents ? 1 : 0)
        }
        for target in additionalTargets {
            if let index = targets.firstIndex(where: { $0.channelID == target.channelID && $0.readStateType == target.readStateType }) {
                targets[index] = target
            } else { targets.append(target) }
        }
        return targets
    }

    private func prepareInboxBulkChannels(_ targets: [BulkReadStateAcknowledgement]) {
        for target in targets where target.readStateType == 0 {
            discardPendingAcknowledgement(for: target.channelID)
            readState.unblockAutomaticAcknowledgement(channelID: target.channelID)
            readState.markAcknowledgementPending(channelID: target.channelID, messageID: target.messageID)
        }
    }

    private func stageInboxBulkRead(_ groups: [InboxUnreadGroup]) {
        for group in groups {
            if group.isEvents, let guildID = group.guildID {
                let boundary = ScheduledEventID(rawValue: group.newestUnreadMessageID.rawValue)
                inbox.pendingEventAcknowledgements[guildID] = boundary
                inbox.scheduledEvents.readStates[guildID]?.lastAcknowledgedID = boundary
                inbox.scheduledEvents.readStates[guildID]?.mentionCount = 0
            } else { inbox.pendingReadGroups[group.id] = group }
        }
    }

    private func restoreFailedInboxEventGroups(
        _ groups: [InboxUnreadGroup], accepted: [BulkReadStateAcknowledgement],
        previousStates: [GuildID: InboxEventReadState]
    ) {
        let acceptedIDs = Set(accepted.filter { $0.readStateType == 1 }.map(\.channelID))
        for group in groups where group.isEvents && !acceptedIDs.contains(group.id) {
            guard let guildID = group.guildID,
                  inbox.pendingEventAcknowledgements[guildID]?.rawValue == group.newestUnreadMessageID.rawValue else { continue }
            inbox.scheduledEvents.readStates[guildID] = previousStates[guildID]
            restoreInboxGroup(group)
        }
    }
}
