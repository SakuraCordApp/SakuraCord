import Foundation

/// An Activity (an embedded app) on the launcher shelf. Its bot user is the
/// application; the simulator serves its page as `{id}.discordsays.com`.
public struct ActivityApp: Sendable {
    public var id: Snowflake
    public var summary: String
    public var tags: [String]
    public var maxParticipants: Int?
    public var cover: String
}

/// A running Activity in a channel.
public struct ActivityInstance: Sendable {
    public struct Participant: Sendable {
        public var userID: Snowflake
        public var sessionID: String
        public var nonce: String
    }

    public var applicationID: Snowflake
    public var instanceID: Snowflake
    public var launchID: String
    public var channelID: Snowflake
    public var guildID: Snowflake?
    public var participants: [Participant] = []

    /// `gc-{guild}-{channel}` in a server, `pc-{channel}` in a DM or group DM.
    public var locationID: String { guildID.map { "gc-\($0)-\(channelID)" } ?? "pc-\(channelID)" }
}

/// Activities: the shelf, application details, launching and joining an
/// instance in a channel, leaving it, proxy tickets and data-sharing
/// disclosures. Payloads and event order follow captures of the official
/// client: a launch answers with EMBEDDED_ACTIVITY_UPDATE_V2 listing the
/// participants; the last one leaving sends it twice with nobody left.
public extension World {
    /// Disclosures every Activity shows before it first reads account data (the IDs Discord uses).
    static let activityDisclosures = [1]

    func addActivityApp(_ app: ActivityApp) {
        voice.activityApps[app.id] = app
        servers.oauthRedirects[app.id, default: []].append("https://127.0.0.1")
    }

    func activityApp(_ id: Snowflake) throws -> (app: ActivityApp, bot: User) {
        guard let app = voice.activityApps[id], let bot = users[id] else { throw WorldError.unknown("Application", code: 10002) }
        return (app, bot)
    }

    /// `GET /activities/shelf`.
    func activityShelf() -> JSON {
        let apps = voice.activityApps.values.sorted { $0.id < $1.id }
        return .object(JSONObject([
            ("activities", .array(apps.enumerated().map { rank, app in renderActivityConfig(app, rank: rank).merging(["application_id": app.id.json]) })),
            ("applications", .array(apps.compactMap { try? renderActivityApplication($0.id) })),
            ("assets", .object(JSONObject())),
        ]))
    }

    /// `GET /applications/{id}/public` for an Activity, or any other application.
    func renderActivityApplication(_ id: Snowflake) throws -> JSON {
        guard let app = voice.activityApps[id], let bot = users[id] else {
            guard let bot = users[id], bot.bot else { throw WorldError.unknown("Application", code: 10002) }
            return renderOAuthApplication(bot)
        }
        let rank = voice.activityApps.keys.sorted().firstIndex(of: id) ?? 0
        return renderOAuthApplication(bot).merging([
            "summary": .string(app.summary), "cover_image": .string(app.cover), "flags": .int(131_072), "flags_new": "131072",
            "embedded_surfaces": [0], "max_participants": app.maxParticipants.map { .int($0) } ?? .null,
            "embedded_activity_config": renderActivityConfig(app, rank: rank), "tags": .array(app.tags.map(JSON.string)),
        ])
    }

    /// Starts the Activity in a channel, or joins the instance already running there.
    @discardableResult
    func launchActivity(_ applicationID: Snowflake, in channelID: Snowflake, by userID: Snowflake, sessionID: String,
                        nonce: String? = nil, instanceID: Snowflake? = nil) throws -> ActivityInstance {
        _ = try activityApp(applicationID)
        let channel = try channel(channelID)
        guard canView(userID, channel) else { throw WorldError.missingAccess }
        let key = activityKey(applicationID, channelID)
        var instance = voice.activities[key]
            ?? ActivityInstance(applicationID: applicationID, instanceID: instanceID ?? nextID(), launchID: UUID(uuid: uuid()).uuidString.lowercased(),
                                channelID: channelID, guildID: channel.guildID)
        instance.participants.removeAll { $0.userID == userID }
        instance.participants.append(.init(userID: userID, sessionID: sessionID, nonce: nonce ?? nextID().description))
        voice.activities[key] = instance
        return instance
    }

    /// Running an Activity's entry-point command (`POST /interactions`): the
    /// interaction succeeds, then the instance, whose ID is the interaction's, starts.
    internal func launchActivityCommand(_ applicationID: Snowflake, in channelID: Snowflake, by userID: Snowflake,
                                        sessionID: String, nonce: String) async throws {
        let id = nextID()
        let instance = try launchActivity(applicationID, in: channelID, by: userID, sessionID: sessionID, nonce: nonce, instanceID: id)
        let ids = JSON.object(JSONObject([("id", id.json), ("nonce", .string(nonce))]))
        await emit("INTERACTION_CREATE", ids, to: .users([userID]))
        await emit("INTERACTION_SUCCESS", ids, to: .users([userID]))
        await announceActivity(instance)
    }

    /// The entry-point command (type 4) Discord launches the Activity with (handler 2).
    internal func renderEntryPointCommand(_ applicationID: Snowflake) -> JSON {
        .object(JSONObject([
            ("id", Snowflake(applicationID.rawValue + 1).json), ("type", 4), ("application_id", applicationID.json),
            ("version", Snowflake(applicationID.rawValue + 100).json), ("default_member_permissions", .null), ("nsfw", false),
            ("name", "launch"), ("description", "Start the Activity"), ("dm_permission", true), ("contexts", [0, 1, 2]),
            ("integration_types", [0, 1]), ("handler", 2), ("options", []),
        ]))
    }

    /// Emits the instance as it now stands.
    func announceActivity(_ instance: ActivityInstance) async {
        await emit("EMBEDDED_ACTIVITY_UPDATE_V2", renderActivityInstance(instance), to: audience(forActivity: instance))
    }

    /// `POST /applications/{id}/activities/{location}/instances/{instance}/leave`.
    func leaveActivity(_ applicationID: Snowflake, locationID: String, instanceID: Snowflake, by userID: Snowflake) async throws {
        guard let (key, instance) = voice.activities.first(where: {
            $0.value.applicationID == applicationID && $0.value.locationID == locationID && $0.value.instanceID == instanceID
        }) else { throw WorldError.notFound }
        await removeParticipant(userID, from: key, instance)
    }

    /// Leaving voice leaves the Activities running in that channel.
    internal func leaveActivities(_ userID: Snowflake, in channelID: Snowflake) async {
        for (key, instance) in voice.activities where instance.channelID == channelID && instance.participants.contains(where: { $0.userID == userID }) {
            await removeParticipant(userID, from: key, instance)
        }
    }

    /// `POST /applications/{id}/proxy-tickets`: what the Activity's page presents to Discord's proxy.
    func activityProxyTicket(_ applicationID: Snowflake, for userID: Snowflake) throws -> JSON {
        _ = try activityApp(applicationID)
        let ticket = random.urlSafeString(48)
        voice.activityTickets[ticket] = applicationID
        return .object(JSONObject([
            ("ticket", .string(ticket)), ("expires_at", World.timestamp(clock.now.addingTimeInterval(3_600))),
            ("application_id", applicationID.json), ("user_id", userID.json),
        ]))
    }

    /// The Activity a proxy ticket was issued for (the `{id}.discordsays.com` host the page is served as).
    func activityApplication(forTicket ticket: String) -> Snowflake? { voice.activityTickets[ticket] }

    /// `GET /applications/{id}/disclosures`.
    func activityDisclosures(_ applicationID: Snowflake, for userID: Snowflake) throws -> JSON {
        _ = try activityApp(applicationID)
        let acked = voice.ackedDisclosures[userID]?[applicationID] ?? []
        return .object(JSONObject([
            ("disclosures", .array(Self.activityDisclosures.map { .int($0) })), ("acked_disclosures", .array(acked.map { .int($0) })),
            ("all_acked", .bool(Set(Self.activityDisclosures).isSubset(of: acked))),
        ]))
    }

    /// `POST /applications/{id}/disclosures`: answers with the ones newly acknowledged.
    func acknowledgeDisclosures(_ disclosures: [Int], for applicationID: Snowflake, by userID: Snowflake) throws -> JSON {
        _ = try activityApp(applicationID)
        let known = disclosures.filter(Self.activityDisclosures.contains)
        voice.ackedDisclosures[userID, default: [:]][applicationID, default: []].formUnion(known)
        return .object(JSONObject([("disclosures", .array(known.map { .int($0) }))]))
    }

    private func removeParticipant(_ userID: Snowflake, from key: String, _ instance: ActivityInstance) async {
        var instance = instance
        instance.participants.removeAll { $0.userID == userID }
        voice.activities[key] = instance.participants.isEmpty ? nil : instance
        await announceActivity(instance)
        if instance.participants.isEmpty { await announceActivity(instance) }
    }

    private func activityKey(_ applicationID: Snowflake, _ channelID: Snowflake) -> String { "\(applicationID)/\(channelID)" }

    private func audience(forActivity instance: ActivityInstance) -> WorldEvent.Audience {
        guard let channel = channels[instance.channelID] else { return .users(Set(instance.participants.map(\.userID))) }
        return audience(for: channel)
    }

    private func uuid() -> uuid_t {
        let high = random.next(), low = random.next()
        let bytes = (0 ..< 16).map { UInt8(truncatingIfNeeded: ($0 < 8 ? high : low) >> (8 * ($0 % 8))) }
        return (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6] & 0x0F | 0x40, bytes[7],
                bytes[8] & 0x3F | 0x80, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
    }

    func renderActivityInstance(_ instance: ActivityInstance) -> JSON {
        var location = JSONObject([("channel_id", instance.channelID.json)])
        if let guildID = instance.guildID { location["guild_id"] = guildID.json }
        location["id"] = .string(instance.locationID)
        location["kind"] = instance.guildID == nil ? "pc" : "gc"
        var object = JSONObject([
            ("application_id", instance.applicationID.json),
            ("composite_instance_id", .string("i-\(instance.instanceID)-\(instance.locationID)")),
            ("content_classification", .object(JSONObject([("data", .null), ("loaded", true)]))),
        ])
        if let guildID = instance.guildID { object["guild_id"] = guildID.json }
        object["instance_id"] = .string(instance.instanceID.description)
        object["launch_id"] = .string(instance.launchID)
        object["location"] = .object(location)
        object["participants"] = .array(instance.participants.map { participant in
            .object(JSONObject([("nonce", .string(participant.nonce)), ("session_id", .string(participant.sessionID)),
                                ("user_id", participant.userID.json)]))
        })
        return .object(object)
    }

    private func renderActivityConfig(_ app: ActivityApp, rank: Int) -> JSON {
        let platform = JSON.object(JSONObject([
            ("label_type", 0), ("label_from", .null), ("label_until", .null), ("release_phase", "global_launch"), ("omit_badge_from_surfaces", []),
        ]))
        return .object(JSONObject([
            ("activity_preview_video_asset_id", .null), ("supported_platforms", ["web", "android", "ios"]),
            ("default_orientation_lock_state", 2), ("tablet_default_orientation_lock_state", 1), ("requires_age_gate", false),
            ("legacy_responsive_aspect_ratio", false), ("premium_tier_requirement", .null), ("free_period_starts_at", .null),
            ("free_period_ends_at", .null),
            ("client_platform_config", .object(JSONObject([("web", platform), ("android", platform), ("ios", platform)]))),
            ("shelf_rank", .int(rank + 1)), ("has_csp_exception", false), ("displays_advertisements", false), ("blocked_locales", []),
            ("supported_locales", []), ("has_proxy_request_signing", false),
        ]))
    }
}
