import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func acknowledgeInboxEvents(in guildID: GuildID, through eventID: ScheduledEventID) async throws {
        let generation = profileEditingGeneration
        let prior = inboxScheduledEvents.readStates[guildID]
        try await requestEmpty("/guilds/\(guildID)/ack/1/\(eventID)", method: "POST", body: [:])
        guard generation == profileEditingGeneration else { throw CancellationError() }
        if inboxScheduledEvents.readStates[guildID] == prior {
            applyInboxEventAcknowledgement(guildID: guildID, eventID: eventID, version: prior?.version)
        }
    }

    func inboxEventInterests(in guildID: GuildID) async throws -> Set<ScheduledEventID> {
        let generation = profileEditingGeneration
        let values: [InboxEventRSVPDTO] = try await request(
            "/users/@me/scheduled-events", query: [URLQueryItem(name: "guild_ids", value: guildID.description)]
        )
        guard generation == profileEditingGeneration else { throw CancellationError() }
        let interests = Set(values.filter { $0.response == 1 && $0.guildScheduledEventExceptionID == nil }.map(\.guildScheduledEventID))
        for index in inboxScheduledEvents.events.indices where inboxScheduledEvents.events[index].guildID == guildID {
            inboxScheduledEvents.events[index].isInterested = interests.contains(inboxScheduledEvents.events[index].id)
        }
        return interests
    }

    func setInboxEventInterested(_ interested: Bool, event: InboxScheduledEvent) async throws {
        let generation = profileEditingGeneration
        try await requestEmpty(
            "/guilds/\(event.guildID)/scheduled-events/\(event.id)/users/@me",
            method: interested ? "PUT" : "DELETE", body: interested ? ["response": .number(1)] : nil
        )
        guard generation == profileEditingGeneration else { throw CancellationError() }
        if let index = inboxScheduledEvents.events.firstIndex(where: { $0.id == event.id }) {
            inboxScheduledEvents.events[index].isInterested = interested
            publishInboxEvents()
        }
    }
}

extension DiscordRESTProvider {
    func applyReadyInboxEvents(_ body: JSONValue) {
        guard let ready = try? JSONValueDecoder().decode(InboxEventsReadyDTO.self, from: body) else { return }
        let events = ready.guilds.flatMap(\.events).compactMap(\.domain)
        var states: [GuildID: InboxEventReadState] = [:]
        for entry in ready.readState.entries where entry.readStateType == 1 {
            guard let guildID = GuildID(entry.id) else { continue }
            states[guildID] = InboxEventReadState(
                lastAcknowledgedID: entry.lastAcknowledgedID,
                mentionCount: entry.badgeCount ?? 0, version: ready.readState.version
            )
        }
        for event in events {
            var state = states[event.guildID] ?? InboxEventReadState()
            state.latestID = max(state.latestID ?? event.id, event.id)
            states[event.guildID] = state
        }
        inboxScheduledEvents = InboxScheduledEvents(events: events, readStates: states)
        publishInboxEvents()
    }

    func handleInboxEventDispatch(name: String, body: JSONValue) -> Bool {
        switch name {
        case "GUILD_FEATURE_ACK":
            guard let ack = try? JSONValueDecoder().decode(InboxEventAckDTO.self, from: body), ack.ackType == 1 else { return true }
            applyInboxEventAcknowledgement(guildID: ack.resourceID, eventID: ack.entityID, version: ack.version)
        case "GUILD_SCHEDULED_EVENT_CREATE", "GUILD_SCHEDULED_EVENT_UPDATE", "GUILD_SCHEDULED_EVENT_DELETE":
            guard let dto = try? JSONValueDecoder().decode(InboxScheduledEventDTO.self, from: body), var event = dto.domain else { return true }
            event.isInterested = inboxScheduledEvents.events.first { $0.id == event.id }?.isInterested ?? false
            inboxScheduledEvents.events.removeAll { $0.id == event.id }
            if name != "GUILD_SCHEDULED_EVENT_DELETE", event.isScheduledOrActive {
                inboxScheduledEvents.events.append(event)
            }
            if name == "GUILD_SCHEDULED_EVENT_CREATE" {
                var state = inboxScheduledEvents.readStates[event.guildID] ?? InboxEventReadState()
                state.latestID = max(state.latestID ?? event.id, event.id)
                if event.creatorID == currentUser?.id {
                    state.lastAcknowledgedID = event.id
                    state.mentionCount = 0
                } else if cachedGuildNotificationSettings[event.guildID]?.muteScheduledEvents != true {
                    state.mentionCount += 1
                }
                inboxScheduledEvents.readStates[event.guildID] = state
            }
            publishInboxEvents()
        case "GUILD_SCHEDULED_EVENT_USER_ADD", "GUILD_SCHEDULED_EVENT_USER_REMOVE":
            guard let rsvp = try? JSONValueDecoder().decode(InboxEventRSVPDTO.self, from: body),
                  rsvp.userID == currentUser?.id, rsvp.guildScheduledEventExceptionID == nil,
                  let index = inboxScheduledEvents.events.firstIndex(where: { $0.id == rsvp.guildScheduledEventID }) else { return true }
            inboxScheduledEvents.events[index].isInterested = name == "GUILD_SCHEDULED_EVENT_USER_ADD" && rsvp.response == 1
            publishInboxEvents()
        default: return false
        }
        return true
    }

    private func applyInboxEventAcknowledgement(guildID: GuildID, eventID: ScheduledEventID, version: Int?) {
        var state = inboxScheduledEvents.readStates[guildID] ?? InboxEventReadState()
        if let version, let previous = state.version, version < previous { return }
        state.lastAcknowledgedID = eventID
        state.mentionCount = 0
        state.version = version ?? state.version
        inboxScheduledEvents.readStates[guildID] = state
        publishInboxEvents()
    }

    func removeInboxEvents(in guildID: GuildID) {
        inboxScheduledEvents.events.removeAll { $0.guildID == guildID }
        inboxScheduledEvents.readStates[guildID] = nil
        publishInboxEvents()
    }

    func applyGuildInboxEvents(_ body: JSONValue) {
        guard let guild = try? JSONValueDecoder().decode(InboxEventsReadyDTO.Guild.self, from: body),
              let id = guild.id else { return }
        let events = guild.events.compactMap(\.domain)
        inboxScheduledEvents.events.removeAll { $0.guildID == id }
        inboxScheduledEvents.events.append(contentsOf: events)
        if let newest = events.map(\.id).max() {
            var state = inboxScheduledEvents.readStates[id] ?? InboxEventReadState()
            state.latestID = max(state.latestID ?? newest, newest)
            inboxScheduledEvents.readStates[id] = state
        }
        publishInboxEvents()
    }

    private func publishInboxEvents() {
        continuation?.yield(.inboxScheduledEventsChanged(inboxScheduledEvents))
    }
}

private struct InboxEventsReadyDTO: Decodable {
    struct Guild: Decodable {
        var id: GuildID?
        var events: [InboxScheduledEventDTO]
        enum CodingKeys: String, CodingKey { case id; case events = "guild_scheduled_events" }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try? values.decode(GuildID.self, forKey: .id)
            events = (try? values.decode(LossyList<InboxScheduledEventDTO>.self, forKey: .events).elements) ?? []
        }
    }
    var guilds: [Guild]
    struct ReadEntry: Decodable {
        var id: String
        var readStateType: Int?
        var lastAcknowledgedID: ScheduledEventID?
        var badgeCount: Int?
        enum CodingKeys: String, CodingKey {
            case id
            case readStateType = "read_state_type"
            case lastAcknowledgedID = "last_acked_id"
            case badgeCount = "badge_count"
        }
    }
    struct ReadState: Decodable {
        var entries: [ReadEntry]
        var version: Int?
    }
    var readState: ReadState
    enum CodingKeys: String, CodingKey { case guilds; case readState = "read_state" }
}

private struct InboxScheduledEventDTO: Decodable {
    var id: ScheduledEventID
    var guildID: GuildID
    var channelID: ChannelID?
    var creatorID: UserID?
    var name: String
    var description: String?
    var entityMetadata: Metadata?
    var scheduledStartTime: String
    var scheduledEndTime: String?
    var status: Int
    struct Metadata: Decodable { var location: String? }
    enum CodingKeys: String, CodingKey {
        case id, name, description, status
        case guildID = "guild_id", channelID = "channel_id", creatorID = "creator_id"
        case entityMetadata = "entity_metadata"
        case scheduledStartTime = "scheduled_start_time", scheduledEndTime = "scheduled_end_time"
    }
    var domain: InboxScheduledEvent? {
        guard let start = DiscordDate.parse(scheduledStartTime) else { return nil }
        return InboxScheduledEvent(id: id, guildID: guildID, channelID: channelID, creatorID: creatorID,
                                   name: name, description: description, location: entityMetadata?.location,
                                   startTime: start, endTime: scheduledEndTime.flatMap(DiscordDate.parse), status: status)
    }
}

private struct InboxEventAckDTO: Decodable {
    var resourceID: GuildID
    var entityID: ScheduledEventID
    var ackType: Int
    var version: Int?
    enum CodingKeys: String, CodingKey {
        case resourceID = "resource_id", entityID = "entity_id", ackType = "ack_type", version
    }
}

private struct InboxEventRSVPDTO: Decodable {
    var guildScheduledEventID: ScheduledEventID
    var guildScheduledEventExceptionID: String?
    var userID: UserID
    var response: Int?
    enum CodingKeys: String, CodingKey {
        case guildScheduledEventID = "guild_scheduled_event_id"
        case guildScheduledEventExceptionID = "guild_scheduled_event_exception_id"
        case userID = "user_id", response
    }
}

public extension ChatProvider {
    func acknowledgeInboxEvents(in guildID: GuildID, through eventID: ScheduledEventID) async throws {
        throw ChatProviderError.invalidRequest("Inbox events are unavailable.")
    }
    func inboxEventInterests(in guildID: GuildID) async throws -> Set<ScheduledEventID> { [] }
    func setInboxEventInterested(_ interested: Bool, event: InboxScheduledEvent) async throws {
        throw ChatProviderError.invalidRequest("Inbox events are unavailable.")
    }
}
