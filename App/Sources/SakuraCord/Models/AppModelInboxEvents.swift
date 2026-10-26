import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func consumeInboxEvent(_ event: ClientEvent) -> Bool {
        switch event {
        case .inboxMentionDismissed(let id): removeInboxMessage(id)
        case .inboxScheduledEventsChanged(let events): reconcileInboxEvents(events)
        case .inboxSettingsChanged(let settings): applyInboxSettings(settings)
        default: return false
        }
        return true
    }

    func inboxEventCandidates(guildPositions: [GuildID: Int]) -> [InboxUnreadCandidate] {
        (snapshot?.guilds ?? []).compactMap { guild in
            let settings = snapshot?.notificationSettings.first { $0.guildID == guild.id }
            guard settings?.muteScheduledEvents != true,
                  !(settings?.isMuted == true && (settings?.muteConfiguration?.isActive() ?? true)),
                  let state = inbox.scheduledEvents.readStates[guild.id], let newest = state.latestID else { return nil }
            let boundary = state.lastAcknowledgedID ?? guild.joinedAt.map(ScheduledEventID.init(timestamp:))
            guard let boundary, boundary < newest else { return nil }
            let group = InboxUnreadGroup(
                channelID: ChannelID(rawValue: guild.id.rawValue), guildID: guild.id,
                title: "Events", subtitle: guild.name,
                oldestReadMessageID: MessageID(rawValue: boundary.rawValue),
                newestUnreadMessageID: MessageID(rawValue: newest.rawValue), mentionCount: state.mentionCount,
                isEvents: true,
                isCollapsed: inbox.settings.collapsedEventGuildIDs.contains(guild.id)
            )
            return InboxUnreadCandidate(group: group, rank: 5, guild: guildPositions[guild.id] ?? .max, position: .max)
        }
    }

    func loadInboxEvents(_ group: InboxUnreadGroup, session: AppModelAccountSession, generation: UInt64) async throws {
        guard let guildID = group.guildID else { return }
        let interests = try await session.provider.inboxEventInterests(in: guildID)
        guard !Task.isCancelled, isCurrentAccountSession(session), inbox.generation == generation,
              let index = inbox.groups.firstIndex(where: { $0.id == group.id }) else { return }
        for eventIndex in inbox.scheduledEvents.events.indices where inbox.scheduledEvents.events[eventIndex].guildID == guildID {
            inbox.scheduledEvents.events[eventIndex].isInterested = interests.contains(inbox.scheduledEvents.events[eventIndex].id)
        }
        inbox.groups[index].events = visibleInboxEvents(for: group)
        inbox.groups[index].isLoaded = true
        inbox.groups[index].needsRevalidation = false
    }

    func visibleInboxEvents(for group: InboxUnreadGroup) -> [InboxScheduledEvent] {
        inbox.scheduledEvents.events.filter {
            $0.guildID == group.guildID && ($0.status == 1 || $0.status == 2)
                && $0.id.rawValue > (group.oldestReadMessageID?.rawValue ?? 0)
                && $0.id.rawValue <= group.newestUnreadMessageID.rawValue
        }.sorted { $0.id < $1.id }
    }

    func reconcileInboxEvents(_ state: InboxScheduledEvents) {
        var next = state
        for (guildID, pending) in inbox.pendingEventAcknowledgements {
            guard next.readStates[guildID]?.lastAcknowledgedID != pending,
                  var retained = inbox.scheduledEvents.readStates[guildID] else { continue }
            retained.latestID = next.readStates[guildID]?.latestID ?? retained.latestID
            retained.version = next.readStates[guildID]?.version ?? retained.version
            next.readStates[guildID] = retained
        }
        inbox.scheduledEvents = next
        if let selected = inbox.selectedEvent {
            inbox.selectedEvent = next.events.first { $0.id == selected.id }
        }
        guard inbox.isPresented else { return }
        for index in inbox.groups.indices where inbox.groups[index].isEvents && inbox.groups[index].isLoaded {
            inbox.groups[index].events = visibleInboxEvents(for: inbox.groups[index])
        }
        inbox.groups.removeAll { group in
            guard group.isEvents, let guildID = group.guildID,
                  !inbox.locallyUndoneEventGuilds.contains(guildID),
                  let boundary = next.readStates[guildID]?.lastAcknowledgedID else { return false }
            return boundary.rawValue >= group.newestUnreadMessageID.rawValue
        }
        publishInbox()
        dismissEmptyInboxGroups()
    }

    func markInboxEventGroupRead(_ group: InboxUnreadGroup) {
        guard let guildID = group.guildID else { return }
        inbox.locallyUndoneEventGuilds.remove(guildID)
        enqueueInboxEventAcknowledgement(group, through: ScheduledEventID(rawValue: group.newestUnreadMessageID.rawValue))
        publishInbox()
        loadMoreInbox()
    }

    func undoInboxEventRead(_ group: InboxUnreadGroup) {
        guard let guildID = group.guildID, let boundary = group.oldestReadMessageID else { return }
        let state = inbox.scheduledEvents.readStates[guildID]
        // Discord restores the card locally when the event read state is already
        // fully acknowledged. It only persists Undo while newer events remain.
        if state?.latestID != state?.lastAcknowledgedID {
            enqueueInboxEventAcknowledgement(group, through: ScheduledEventID(rawValue: boundary.rawValue))
        } else {
            inbox.locallyUndoneEventGuilds.insert(guildID)
        }
        restoreInboxGroup(group)
        publishInbox()
    }

    private func enqueueInboxEventAcknowledgement(_ group: InboxUnreadGroup, through boundary: ScheduledEventID) {
        guard let guildID = group.guildID else { return }
        let session = accountSession()
        let previousTask = inbox.eventMutationTasks[guildID]
        let previousState = inbox.scheduledEvents.readStates[guildID]
        var optimistic = previousState ?? InboxEventReadState()
        optimistic.lastAcknowledgedID = boundary
        optimistic.mentionCount = 0
        inbox.scheduledEvents.readStates[guildID] = optimistic
        inbox.pendingEventAcknowledgements[guildID] = boundary
        inbox.eventMutationTasks[guildID] = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled, isCurrentAccountSession(session) else { return }
            do {
                try await session.provider.acknowledgeInboxEvents(in: guildID, through: boundary)
            } catch {
                guard isCurrentAccountSession(session), inbox.pendingEventAcknowledgements[guildID] == boundary else { return }
                inbox.scheduledEvents.readStates[guildID] = previousState
                restoreInboxGroup(group)
                inbox.undoGroups.removeAll { $0.id == group.id }
                inbox.errorMessage = error.localizedDescription
                publishInbox()
            }
            guard isCurrentAccountSession(session), inbox.pendingEventAcknowledgements[guildID] == boundary else { return }
            inbox.pendingEventAcknowledgements[guildID] = nil
            inbox.eventMutationTasks[guildID] = nil
        }
    }

    func setInboxEventInterest(_ interested: Bool, event: InboxScheduledEvent) {
        guard inbox.eventInterestTasks[event.id] == nil else { return }
        let session = accountSession()
        inbox.eventInterestTasks[event.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await session.provider.setInboxEventInterested(interested, event: event)
                guard isCurrentAccountSession(session) else { return }
                if let index = inbox.scheduledEvents.events.firstIndex(where: { $0.id == event.id }) {
                    inbox.scheduledEvents.events[index].isInterested = interested
                }
                reconcileInboxEvents(inbox.scheduledEvents)
            } catch {
                guard isCurrentAccountSession(session) else { return }
                inbox.errorMessage = error.localizedDescription
            }
            inbox.eventInterestTasks[event.id] = nil
        }
    }
}
