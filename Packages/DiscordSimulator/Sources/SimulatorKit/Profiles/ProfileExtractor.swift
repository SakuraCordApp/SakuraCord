import Foundation

/// Reads dcap captures of one account and writes its `AccountProfile`: the
/// structure from the first READY, activity rates from every capture of the
/// same account. dcap pseudonymizes IDs per capture, so records are joined
/// across captures by name, in memory only; every count is jittered and the
/// servers shuffled, so the profile can't be traced back.
public struct ProfileExtractor {
    private typealias Object = [String: Any]

    private var random: SeededRandom
    /// The dcap mark whose READY picks the account; nil takes the first READY.
    private let mark: String?
    private var account: String?
    private var ready: Object?
    private var supplemental: Object?
    /// Traffic per server name.
    private var traffic: [String: Traffic] = [:]
    /// Hours of live traffic the activity rates come from.
    public private(set) var hours = 0.0
    /// Typing and messages in channels where typing arrived, across every account's captures.
    /// Discord sends typing only for channels a client has open, so this ratio, not the raw
    /// typing count, says how much people type.
    private var typingSeen = 0, messagesWhereTyping = 0

    private struct Traffic {
        var messages = 0, typing = 0, reactions = 0, presence = 0, edits = 0, deletes = 0
        /// Messages per channel name.
        var perChannel: [String: Int] = [:]
    }

    /// One capture's pseudonymous IDs resolved against its own READY.
    private struct Names {
        var guilds: [String: String] = [:]
        var channels: [String: String] = [:]
    }

    public init(seed: UInt64, mark: String? = nil) {
        random = SeededRandom(seed: seed).fork("profile")
        self.mark = mark
    }

    private static let events: [String] = ["READY", "READY_SUPPLEMENTAL", "MESSAGE_CREATE", "TYPING_START", "MESSAGE_REACTION_ADD",
                                           "PRESENCE_UPDATE", "MESSAGE_UPDATE", "MESSAGE_DELETE"]
    private static let markers = events.map { Data("\"event\":\"\($0)\"".utf8) }

    /// Feeds one capture. The first READY (under `mark`, if set) picks the account; other accounts,
    /// and traffic before a capture's READY, are skipped.
    public mutating func absorb(captureFile url: URL) throws {
        let data = try Data(contentsOf: url)
        var first: Date?, last: Date?
        var names: Names?
        var sameAccount = false
        var typingChannels: Set<String> = [], channelMessages: [String: Int] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) where Self.markers.contains(where: { line.range(of: $0) != nil }) {
            guard let record = try JSONSerialization.jsonObject(with: line) as? Object, record["kind"] as? String == "gw",
                  record["dir"] as? String == "in", let event = record["event"] as? String, let payload = record["d"] as? Object else { continue }
            if let channelID = payload["channel_id"] as? String {
                if event == "TYPING_START" { typingSeen += 1; typingChannels.insert(channelID) }
                if event == "MESSAGE_CREATE" { channelMessages[channelID, default: 0] += 1 }
            }
            switch event {
            case "READY":
                let user = (payload["user"] as? Object)?["username"] as? String
                if account == nil, mark == nil || record["mark"] as? String == mark { account = user; ready = payload }
                sameAccount = user == account
                names = sameAccount ? Self.names(in: payload) : nil
            case "READY_SUPPLEMENTAL":
                if supplemental == nil, sameAccount { supplemental = payload }
            default:
                guard sameAccount, let names else { continue }
                let stamp = (record["ts"] as? String).flatMap(Self.timestamp)
                if first == nil { first = stamp }
                last = stamp ?? last
                count(event, payload, names: names)
            }
        }
        if let first, let last { hours += last.timeIntervalSince(first) / 3_600 }
        messagesWhereTyping += typingChannels.reduce(0) { $0 + channelMessages[$1, default: 0] }
    }

    private static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private static func names(in ready: Object) -> Names {
        var names = Names()
        for guild in ready["guilds"] as? [Object] ?? [] {
            guard let id = guild["id"] as? String else { continue }
            names.guilds[id] = (guild["properties"] as? Object)?["name"] as? String ?? id
            for channel in (guild["channels"] as? [Object] ?? []) + (guild["threads"] as? [Object] ?? []) {
                guard let channelID = channel["id"] as? String else { continue }
                names.channels[channelID] = channel["name"] as? String ?? channelID
            }
        }
        return names
    }

    private mutating func count(_ event: String, _ payload: Object, names: Names) {
        guard let guildID = payload["guild_id"] as? String, let guild = names.guilds[guildID] else { return }
        var entry = traffic[guild, default: Traffic()]
        switch event {
        case "MESSAGE_CREATE":
            entry.messages += 1
            if let channelID = payload["channel_id"] as? String {
                // Threads opened after startup aren't in READY.
                entry.perChannel[names.channels[channelID] ?? channelID, default: 0] += 1
            }
        case "TYPING_START": entry.typing += 1
        case "MESSAGE_REACTION_ADD": entry.reactions += 1
        case "PRESENCE_UPDATE": entry.presence += 1
        case "MESSAGE_UPDATE": entry.edits += 1
        case "MESSAGE_DELETE": entry.deletes += 1
        default: break
        }
        traffic[guild] = entry
    }

    private static func kind(_ type: Int) -> String? {
        switch type {
        case 0: "text"
        case 2: "voice"
        case 5: "announcement"
        case 13: "stage"
        case 15: "forum"
        case 16: "media"
        default: nil
        }
    }

    // MARK: Profile

    public mutating func profile() throws -> AccountProfile {
        guard let ready else { throw WorldError.invalidBody("no READY in the captures") }
        let readStates = Dictionary((ready["read_state"] as? Object)?["entries"] as? [Object] ?? [], keyedBy: "id")
        let settings = Dictionary((ready["user_guild_settings"] as? Object)?["entries"] as? [Object] ?? [], keyedBy: "guild_id")
        let voice = Dictionary(supplemental?["guilds"] as? [Object] ?? [], keyedBy: "id")
        var servers: [ServerProfile] = []
        for guild in ready["guilds"] as? [Object] ?? [] {
            guard let id = guild["id"] as? String else { continue }
            var server = serverProfile(guild, readStates: readStates, settings: settings[id], voice: voice[id])
            server.activity = activity(traffic[(guild["properties"] as? Object)?["name"] as? String ?? id])
            servers.append(server)
        }
        servers.shuffle(using: &random)
        let folders = Self.folders(in: ready).map { folder in
            FolderProfile(servers: folder.servers > 1 ? max(2, count(folder.servers)) : 1, named: folder.named, colored: folder.colored)
        }
        return AccountProfile(servers: servers, folders: folders, directMessages: directMessages(ready), relationships: relationships(ready))
    }

    private mutating func serverProfile(_ guild: Object, readStates: [String: Object], settings: Object?, voice: Object?) -> ServerProfile {
        let properties = guild["properties"] as? Object ?? [:]
        let channels = guild["channels"] as? [Object] ?? []
        let features = Set(properties["features"] as? [String] ?? [])
        let emojis = guild["emojis"] as? [Object] ?? []
        let threads = guild["threads"] as? [Object] ?? []
        let forums = Set(channels.filter { [15, 16].contains($0["type"] as? Int) }.compactMap { $0["id"] as? String })
        let boosts = guild["premium_subscription_count"] as? Int ?? 0
        return ServerProfile(
            categories: categoryLayout(channels),
            roles: max(1, count((guild["roles"] as? [Any])?.count ?? 1)),
            emojis: count(emojis.count),
            animatedEmojis: count(emojis.count { $0["animated"] as? Bool == true }),
            stickers: count((guild["stickers"] as? [Any])?.count ?? 0),
            memberCount: Self.significant(jitter(Double(guild["member_count"] as? Int ?? 0)), digits: 2),
            boostCount: count(boosts),
            boostTier: properties["premium_tier"] as? Int ?? 0,
            community: features.contains("COMMUNITY"),
            discoverable: features.contains("DISCOVERABLE"),
            restrictedChannels: count(channels.count { ($0["permission_overwrites"] as? [Any])?.isEmpty == false }),
            activeThreads: count(threads.count { !forums.contains($0["parent_id"] as? String ?? "") }),
            forumPosts: count(threads.count { forums.contains($0["parent_id"] as? String ?? "") }),
            scheduledEvents: count((guild["guild_scheduled_events"] as? [Any])?.count ?? 0),
            peopleInVoice: count((voice?["voice_states"] as? [Any])?.count ?? 0),
            settings: serverSettings(settings),
            readState: readState(channels, readStates),
            activity: ActivityProfile()
        )
    }

    /// Per category, channel counts by kind; categories keep their order after the uncategorized top.
    private mutating func categoryLayout(_ channels: [Object]) -> [[String: Int]] {
        let categories = channels.filter { $0["type"] as? Int == 4 }.sorted { ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0) }
        let order = [nil] + categories.map { $0["id"] as? String }
        var layout = order.map { _ in [String: Int]() }
        for channel in channels {
            guard let kind = Self.kind(channel["type"] as? Int ?? -1) else { continue }
            let slot = order.firstIndex { $0 == channel["parent_id"] as? String } ?? 0
            layout[slot][kind, default: 0] += 1
        }
        return layout.map { counts in counts.mapValues { count($0) }.filter { $0.value > 0 } }
    }

    private mutating func serverSettings(_ settings: Object?) -> ServerSettingsProfile {
        guard let settings else { return ServerSettingsProfile() }
        let overrides = settings["channel_overrides"] as? [Object] ?? []
        return ServerSettingsProfile(
            muted: settings["muted"] as? Bool ?? false,
            suppressEveryone: settings["suppress_everyone"] as? Bool ?? false,
            suppressRoles: settings["suppress_roles"] as? Bool ?? false,
            messageNotifications: settings["message_notifications"] as? Int ?? 3,
            hideMutedChannels: settings["hide_muted_channels"] as? Bool ?? false,
            mutedChannels: count(overrides.count { $0["muted"] as? Bool == true }),
            collapsedCategories: count(overrides.count { $0["collapsed"] as? Bool == true }),
            notificationOverrides: count(overrides.count { ($0["message_notifications"] as? Int ?? 3) != 3 })
        )
    }

    private mutating func readState(_ channels: [Object], _ readStates: [String: Object]) -> ServerReadStateProfile {
        var unread = 0
        var mentions: [Int] = []
        for channel in channels {
            guard let id = channel["id"] as? String, let state = readStates[id] else { continue }
            if Self.isUnread(channel, state) { unread += 1 }
            if let mentionCount = state["mention_count"] as? Int, mentionCount > 0 { mentions.append(max(1, count(mentionCount))) }
        }
        return ServerReadStateProfile(unreadChannels: count(unread), mentions: mentions.shuffled(using: &random))
    }

    /// Pseudonymized IDs don't order, but a read state that isn't at the channel's last message is behind it.
    private static func isUnread(_ channel: Object, _ state: Object) -> Bool {
        guard let last = channel["last_message_id"] as? String else { return false }
        return last != state["last_message_id"] as? String
    }

    private mutating func activity(_ traffic: Traffic?) -> ActivityProfile {
        guard let traffic, hours > 0 else { return ActivityProfile() }
        func rate(_ value: Int) -> Double { Self.round(jitter(Double(value) / hours), places: 2) }
        let busiest = traffic.perChannel.values.sorted(by: >).prefix(5)
        let total = Double(traffic.messages)
        let typingPerMessage = messagesWhereTyping > 0 ? Double(typingSeen) / Double(messagesWhereTyping) : 0
        let typing = max(traffic.typing, Int((Double(traffic.messages) * typingPerMessage).rounded()))
        return ActivityProfile(messages: rate(traffic.messages), typing: rate(typing), reactions: rate(traffic.reactions),
                               presence: rate(traffic.presence), edits: rate(traffic.edits), deletes: rate(traffic.deletes),
                               channelShares: busiest.map { Self.round(Double($0) / max(total, 1), places: 1) }.filter { $0 > 0 })
    }

    private mutating func directMessages(_ ready: Object) -> DirectMessageProfile {
        let channels = ready["private_channels"] as? [Object] ?? []
        let groups = channels.filter { $0["type"] as? Int == 3 }
        return DirectMessageProfile(
            dms: count(channels.count { $0["type"] as? Int == 1 }),
            groupDMs: count(groups.count),
            groupSizes: groups.map { min(9, ($0["recipient_ids"] as? [Any])?.count ?? 1) }.shuffled(using: &random)
        )
    }

    private mutating func relationships(_ ready: Object) -> RelationshipProfile {
        let types = (ready["relationships"] as? [Object] ?? []).compactMap { $0["type"] as? Int }
        var statuses: [String: Int] = [:]
        for presence in (supplemental?["merged_presences"] as? Object)?["friends"] as? [Object] ?? [] {
            if let status = presence["status"] as? String { statuses[status, default: 0] += 1 }
        }
        return RelationshipProfile(friends: count(types.count { $0 == 1 }), blocked: count(types.count { $0 == 2 }),
                                   friendStatuses: statuses.mapValues { count($0) })
    }

    /// The rail from the settings proto's guild_folders (field 14): per entry, how many
    /// guild_ids (1) it holds and whether it has a name (3) and colour (4). Single
    /// servers are entries without a folder id (2). The proto keeps real IDs while
    /// READY's are pseudonymized, so servers can't be matched to their folder.
    private static func folders(in ready: Object) -> [FolderProfile] {
        guard let encoded = ready["user_settings_proto"] as? String, let proto = Data(base64Encoded: encoded),
              let section = ProtobufMerge.fields(proto)?.first(where: { $0.number == 14 }),
              let entries = ProtobufMerge.fields(section.payload) else { return [] }
        return entries.filter { $0.number == 1 }.compactMap { entry in
            guard let fields = ProtobufMerge.fields(entry.payload) else { return nil }
            let size = fields.filter { $0.number == 1 }.reduce(0) { $0 + $1.payload.count / 8 }
            guard fields.contains(where: { $0.number == 2 }) else { return FolderProfile(servers: 1, named: false, colored: false) }
            let named = fields.first { $0.number == 3 }.flatMap { ProtobufMerge.fields($0.payload)?.first }.map { !$0.payload.isEmpty } ?? false
            return FolderProfile(servers: size, named: named, colored: fields.contains { $0.number == 4 })
        }
    }

    // MARK: Jitter

    /// ±10–25%, in a random direction.
    private mutating func jitter(_ value: Double) -> Double {
        let amount = 0.1 + random.unit() * 0.15
        return value * (random.chance(0.5) ? 1 + amount : 1 - amount)
    }

    /// A jittered count, rounded up or down at random by its fraction so small
    /// counts vary too; larger counts never come back unchanged.
    private mutating func count(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        let scaled = jitter(Double(value))
        var result = Int(scaled) + (random.chance(scaled - scaled.rounded(.down)) ? 1 : 0)
        if value >= 4, result == value { result += random.chance(0.5) ? 1 : -1 }
        return max(0, result)
    }

    private static func round(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    private static func significant(_ value: Double, digits: Int) -> Int {
        guard value >= 1 else { return 1 }
        let scale = pow(10, floor(log10(value)) - Double(digits - 1))
        return Int(max(1, (value / scale).rounded() * scale))
    }
}

private extension [String: [String: Any]] {
    init(_ objects: [[String: Any]], keyedBy key: String) {
        self = [:]
        for object in objects { if let id = object[key] as? String { self[id] = object } }
    }
}
