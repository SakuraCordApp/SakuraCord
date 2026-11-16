import Foundation

/// A guild's scheduled event.
public struct ScheduledEvent: Sendable {
    /// 1 stage instance, 2 voice, 3 somewhere else.
    public enum EntityType: Int, Sendable { case stage = 1, voice = 2, external = 3 }

    public var id: Snowflake
    public var guildID: Snowflake
    public var name: String
    public var description = ""
    public var channelID: Snowflake?
    public var creatorID: Snowflake
    public var image: String?
    public var start: Date
    public var end: Date?
    /// 1 scheduled, 2 active, 3 completed, 4 canceled.
    public var status = 1
    public var entityType: EntityType
    public var location: String?
    public var interested: [Snowflake] = []
}

public extension Permissions {
    static let manageEvents = Permissions(rawValue: 1 << 33)
    static let createEvents = Permissions(rawValue: 1 << 44)
}

extension World {
    func scheduledEvent(_ id: Snowflake, in guildID: Snowflake) throws -> ScheduledEvent {
        guard let event = servers.scheduledEvents[id], event.guildID == guildID else {
            throw WorldError.unknown("Guild Scheduled Event", code: 10070)
        }
        return event
    }

    func scheduledEvents(in guildID: Snowflake) -> [ScheduledEvent] {
        servers.scheduledEvents.values.filter { $0.guildID == guildID && $0.status <= 2 }.sorted { $0.id < $1.id }
    }

    private func eventAudience(_ event: ScheduledEvent) -> WorldEvent.Audience { .guild(event.guildID, channel: event.channelID) }

    /// `POST /guilds/{id}/scheduled-events`. The creator is marked interested, as on Discord.
    func createScheduledEvent(in guildID: Snowflake, by userID: Snowflake, body: JSON) async throws -> ScheduledEvent {
        let guild = try guild(guildID)
        guard guild.members[userID] != nil else { throw WorldError.missingAccess }
        guard !guild.permissions(of: userID).isDisjoint(with: [.manageEvents, .createEvents]) else { throw WorldError.missingPermissions }
        guard let name = body["name"]?.stringValue, (1 ... 100).contains(name.count) else { throw WorldError.invalidBody("name: required") }
        guard let type = body["entity_type"]?.intValue.flatMap({ ScheduledEvent.EntityType(rawValue: Int($0)) }) else {
            throw WorldError.invalidBody("entity_type: required")
        }
        guard let start = body["scheduled_start_time"]?.stringValue.flatMap(World.parseTimestamp) else {
            throw WorldError.invalidBody("scheduled_start_time: required")
        }
        var event = ScheduledEvent(id: nextID(), guildID: guildID, name: name, creatorID: userID, start: start, entityType: type)
        event.description = body["description"]?.stringValue ?? ""
        event.end = body["scheduled_end_time"]?.stringValue.flatMap(World.parseTimestamp)
        if type == .external {
            event.location = body["entity_metadata"]?["location"]?.stringValue
            guard event.location?.isEmpty == false, event.end != nil else {
                throw WorldError.invalidBody("entity_metadata.location and scheduled_end_time are required for events elsewhere")
            }
        } else {
            guard let channelID = body["channel_id"]?.stringValue.flatMap(Snowflake.init), try channel(channelID).guildID == guildID else {
                throw WorldError.invalidBody("channel_id: required for voice and stage events")
            }
            event.channelID = channelID
        }
        event.interested = [userID]
        servers.scheduledEvents[event.id] = event
        await emit("GUILD_SCHEDULED_EVENT_CREATE", renderScheduledEvent(event), to: eventAudience(event))
        await emitAuditLog(guildID, action: 100, target: event.id, by: userID, changes: eventAuditChanges(event, created: true))
        await emit("GUILD_SCHEDULED_EVENT_USER_ADD", renderEventRSVP(event, userID: userID), to: eventAudience(event))
        return event
    }

    /// The creator, or anyone with Manage Events, may delete an event.
    func deleteScheduledEvent(_ id: Snowflake, in guildID: Snowflake, by userID: Snowflake) async throws {
        let event = try scheduledEvent(id, in: guildID)
        let permissions = try guild(guildID).permissions(of: userID)
        guard permissions.contains(.manageEvents) || event.creatorID == userID && permissions.contains(.createEvents) else {
            throw WorldError.missingPermissions
        }
        servers.scheduledEvents[id] = nil
        await emit("GUILD_SCHEDULED_EVENT_DELETE", renderScheduledEvent(event), to: eventAudience(event))
        await emitAuditLog(guildID, action: 102, target: event.id, by: userID, changes: eventAuditChanges(event, created: false))
    }

    /// `PUT`/`DELETE .../users/@me`: marks or clears interest. Repeating either changes nothing.
    func setEventInterest(_ id: Snowflake, in guildID: Snowflake, userID: Snowflake, interested: Bool) async throws {
        var event = try scheduledEvent(id, in: guildID)
        guard try guild(guildID).members[userID] != nil else { throw WorldError.missingAccess }
        guard event.interested.contains(userID) != interested else { return }
        if interested { event.interested.append(userID) } else { event.interested.removeAll { $0 == userID } }
        servers.scheduledEvents[id] = event
        await emit(interested ? "GUILD_SCHEDULED_EVENT_USER_ADD" : "GUILD_SCHEDULED_EVENT_USER_REMOVE",
                   renderEventRSVP(event, userID: userID), to: eventAudience(event))
    }

    /// `POST /guilds/{id}/ack/1/{event}`: marks the guild's events read through `eventID`.
    func acknowledgeEvents(in guildID: Snowflake, through eventID: Snowflake, userID: Snowflake) async throws {
        _ = try scheduledEvent(eventID, in: guildID)
        servers.eventAcks[userID, default: [:]][guildID] = eventID
        servers.eventAckVersion += 1
        await emit("GUILD_FEATURE_ACK", .object(JSONObject([
            ("ack_type", 1), ("entity_id", eventID.json), ("resource_id", guildID.json), ("version", .int(servers.eventAckVersion)),
        ])), to: .users([userID]))
    }

    /// `GET /users/@me/scheduled-events?guild_ids=…`: the user's RSVPs.
    func eventRSVPs(_ userID: Snowflake, guildIDs: [Snowflake]) -> JSON {
        .array(guildIDs.flatMap { scheduledEvents(in: $0) }.filter { $0.interested.contains(userID) }.map { event in
            .object(JSONObject([("response", 1), ("user_id", userID.json), ("guild_scheduled_event_id", event.id.json)]))
        })
    }

    private func eventAuditChanges(_ event: ScheduledEvent, created: Bool) -> [JSON] {
        let rendered = renderScheduledEvent(event)
        var fields = ["name", "description", "privacy_level", "status", "entity_type", "channel_id", "scheduled_start_time", "scheduled_end_time"]
            .compactMap { key in rendered[key].flatMap { $0 == .null ? nil : (key, $0) } }
        if let location = event.location { fields.append(("location", .string(location))) }
        return fields.map { auditChange($0.0, old: created ? JSON?.none : $0.1, new: created ? $0.1 : JSON?.none) }
    }

    func renderEventRSVP(_ event: ScheduledEvent, userID: Snowflake) -> JSON {
        .object(JSONObject([("guild_id", event.guildID.json), ("guild_scheduled_event_id", event.id.json), ("response", 1),
                            ("user_id", userID.json)]))
    }

    func renderScheduledEvent(_ event: ScheduledEvent) -> JSON {
        .object(JSONObject([
            ("id", event.id.json), ("guild_id", event.guildID.json), ("name", .string(event.name)),
            ("description", .string(event.description)), ("channel_id", event.channelID?.json ?? .null),
            ("creator_id", event.creatorID.json), ("image", .optional(event.image)),
            ("scheduled_start_time", World.timestamp(event.start)), ("scheduled_end_time", World.optionalTimestamp(event.end)),
            ("status", .int(event.status)), ("entity_type", .int(event.entityType.rawValue)), ("entity_id", .null),
            ("recurrence_rule", .null), ("privacy_level", 2), ("sku_ids", []), ("guild_scheduled_event_exceptions", []),
            ("entity_metadata", event.location.map { .object(JSONObject([("location", .string($0))])) } ?? .null),
            ("auto_start", .bool(event.entityType == .external)),
        ]))
    }

    /// READY's per-guild event read states (`read_state_type` 1), with a badge for unread events.
    func eventReadStates(_ userID: Snowflake) -> [JSON] {
        guilds(of: userID).compactMap { guild -> JSON? in
            let events = scheduledEvents(in: guild.id)
            guard !events.isEmpty else { return nil }
            let acked = servers.eventAcks[userID]?[guild.id]
            let unread = events.filter { $0.id > (acked ?? Snowflake(0)) && $0.creatorID != userID }.count
            var entry = JSONObject([("badge_count", .int(unread)), ("id", guild.id.json), ("read_state_type", 1)])
            if let acked { entry["last_acked_id"] = acked.json }
            return .object(entry)
        }
    }

    nonisolated static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
