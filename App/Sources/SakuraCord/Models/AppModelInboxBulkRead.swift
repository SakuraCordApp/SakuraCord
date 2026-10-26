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
        let now = Date.now
        let targets = readState.entries.values.compactMap { entry -> BulkReadStateAcknowledgement? in
            guard channelIDs.contains(entry.channelID), entry.isAccessible, entry.latestKnownMessageID != nil,
                  let target = AccountReadStateModel.acknowledgementTarget(for: entry, now: now) else { return nil }
            return BulkReadStateAcknowledgement(channelID: entry.channelID, messageID: target)
        }.sorted { $0.channelID < $1.channelID }
        markInboxGroupsRead(groups, additionalTargets: targets)
    }

    private func markInboxGroupsRead(_ groups: [InboxUnreadGroup], additionalTargets: [BulkReadStateAcknowledgement] = []) {
        guard inbox.bulkTask == nil else { return }
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
            // As in Discord, a failed batch is dropped silently.
            try? await session.provider.acknowledgeBulk(targets)
            guard isCurrentAccountSession(session) else { return }
            for target in targets where target.readStateType == 0 && readState[target.channelID]?.isUnread != true {
                cancelNativeNotifications(channelID: target.channelID)
            }
            for group in groups where group.isEvents {
                if let guildID = group.guildID,
                   inbox.pendingEventAcknowledgements[guildID]?.rawValue == group.newestUnreadMessageID.rawValue {
                    inbox.pendingEventAcknowledgements[guildID] = nil
                }
            }
            refreshUnreadPresentation()
            inbox.bulkTask = nil
        }
    }
}

extension AppModel {
    /// A forum group acknowledges up to now, like every forum acknowledgement;
    /// any other group acknowledges its captured newest message.
    nonisolated static func inboxAcknowledgementTarget(for group: InboxUnreadGroup, now: Date) -> MessageID {
        group.isForum ? MessageID(timestamp: now) : group.newestUnreadMessageID
    }

    private func inboxBulkTargets(_ groups: [InboxUnreadGroup], additionalTargets: [BulkReadStateAcknowledgement]) -> [BulkReadStateAcknowledgement] {
        let now = Date.now
        var targets = groups.map {
            BulkReadStateAcknowledgement(
                channelID: $0.id, messageID: Self.inboxAcknowledgementTarget(for: $0, now: now), readStateType: $0.isEvents ? 1 : 0
            )
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
            readState.acknowledge(channelID: target.channelID, messageID: target.messageID)
        }
    }

    private func stageInboxBulkRead(_ groups: [InboxUnreadGroup]) {
        for group in groups where group.isEvents {
            guard let guildID = group.guildID else { continue }
            let boundary = ScheduledEventID(rawValue: group.newestUnreadMessageID.rawValue)
            inbox.pendingEventAcknowledgements[guildID] = boundary
            inbox.scheduledEvents.readStates[guildID]?.lastAcknowledgedID = boundary
            inbox.scheduledEvents.readStates[guildID]?.mentionCount = 0
        }
    }
}
