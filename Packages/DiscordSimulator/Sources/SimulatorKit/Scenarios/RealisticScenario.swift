import Foundation

/// The default world, a medium account: the hand-written demo (`demo-lite`) as
/// the account's close servers and friends, inside ~60–80 generated servers.
public enum RealisticScenario: Scenario {
    public static let name = "demo"
    public static let summary = "A medium account: the demo's servers and friends inside ~60–80 generated servers, DMs and friends."

    public static func build(into world: World, parameters: [String: String]) async throws {
        try await AccountMode.medium.build(into: world, parameters: parameters)
    }

    public static func liveScripts(parameters: [String: String]) -> [String: JSON] { AccountMode.liveScripts(parameters) }
}

/// A small account: ~15–25 mostly small and medium communities, few DMs and friends.
public enum SmallAccountScenario: Scenario {
    public static let name = "demo-small"
    public static let summary = "A small account: the demo's servers inside ~15–25 generated communities, few DMs and friends."

    public static func build(into world: World, parameters: [String: String]) async throws {
        try await AccountMode.small.build(into: world, parameters: parameters)
    }

    public static func liveScripts(parameters: [String: String]) -> [String: JSON] { AccountMode.liveScripts(parameters) }
}

/// A large Nitro account in 100–200 servers, many of them huge, at peak activity.
public enum LargeAccountScenario: Scenario {
    public static let name = "demo-large"
    public static let summary = "A large Nitro account: 100–200 servers, many huge, with peak activity rates."

    public static func build(into world: World, parameters: [String: String]) async throws {
        try await AccountMode.large.build(into: world, parameters: parameters)
    }

    public static func liveScripts(parameters: [String: String]) -> [String: JSON] { AccountMode.liveScripts(parameters) }
}

/// A size of account. Real captures are ballpark inputs only: a mode draws its
/// server count and account-level numbers from ranges, and its servers from the
/// pooled server profiles of `profiles`, re-jittered.
struct AccountMode: Sendable {
    var servers: ClosedRange<Int>
    var profiles: [String]
    var directMessages: ClosedRange<Int>
    var groupDMs: ClosedRange<Int>
    var friends: ClosedRange<Int>
    var blocked: ClosedRange<Int>
    /// How much more often servers over 10,000 members are drawn.
    var bigServerWeight: Double
    /// Scales every activity rate; the large mode runs at peak.
    var activityScale: Double

    static let small = AccountMode(servers: 15 ... 25, profiles: ["small"], directMessages: 20 ... 40, groupDMs: 3 ... 8,
                                   friends: 8 ... 20, blocked: 0 ... 2, bigServerWeight: 1, activityScale: 1)
    static let medium = AccountMode(servers: 60 ... 80, profiles: ["medium", "medium-big-servers"], directMessages: 90 ... 130,
                                    groupDMs: 8 ... 16, friends: 40 ... 140, blocked: 2 ... 6, bigServerWeight: 1, activityScale: 1)
    static let large = AccountMode(servers: 100 ... 200, profiles: ["medium", "medium-big-servers", "small"], directMessages: 120 ... 200,
                                   groupDMs: 12 ... 25, friends: 100 ... 250, blocked: 3 ... 10, bigServerWeight: 3, activityScale: 2.5)

    func build(into world: World, parameters: [String: String]) async throws {
        try await DemoScenario.build(into: world, parameters: parameters)
        var random = SeededRandom(seed: world.seed).fork("account-mode")
        // The demo's own servers count toward the account's total.
        let profile = try compose(profiles.map(AccountProfile.bundled), existingServers: await world.guildOrder.count, &random)
        var generator = await RealisticWorld(world: world, profile: profile)
        try await generator.build()
        if let me = await world.primaryUserID {
            try await world.updateUserQuietly(me) { if $0.premiumType == .none { $0.premiumType = .nitro } }
        }
    }

    /// The demo modes' background life, on unless `--param activity=off`; `activity_scale` multiplies its rates.
    static func liveScripts(_ parameters: [String: String]) -> [String: JSON] {
        guard parameters["activity"] != "off" else { return [:] }
        return [LiveActivity.name: .object(JSONObject([("scale", .double(parameters["activity_scale"].flatMap(Double.init) ?? 1))]))]
    }

    /// An account profile for this mode: counts from the ranges, servers drawn from the pool.
    func compose(_ sources: [AccountProfile], existingServers: Int, _ random: inout SeededRandom) throws -> AccountProfile {
        guard let first = sources.first else { throw WorldError.invalidBody("account mode has no profiles") }
        func draw(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(random.next() % UInt64(range.count)) }
        var pool = sources.flatMap(\.servers)
        var servers: [ServerProfile] = []
        for _ in 0 ..< max(0, draw(self.servers) - existingServers) {
            if pool.isEmpty { pool = sources.flatMap(\.servers) }
            let weights = pool.map { $0.memberCount > 10_000 ? bigServerWeight : 1 }
            var pick = random.unit() * weights.reduce(0, +)
            let index = weights.firstIndex { pick -= $0; return pick < 0 } ?? pool.count - 1
            var server = pool.remove(at: index)
            server.memberCount = max(2, Int(Double(server.memberCount) * (0.85 + random.unit() * 0.3)))
            for path in [\ActivityProfile.messages, \.typing, \.reactions, \.presence, \.edits, \.deletes] {
                server.activity[keyPath: path] *= activityScale * (0.85 + random.unit() * 0.3)
            }
            servers.append(server)
        }
        let friends = draw(self.friends)
        let statuses = first.relationships.friendStatuses
        let seen = max(1, first.relationships.friends)
        let groupSizes = sources.flatMap(\.directMessages.groupSizes)
        return AccountProfile(
            servers: servers,
            // The source's rail pattern, repeated until every server has a place.
            folders: Array(repeating: first.folders, count: max(1, servers.count / max(1, first.folders.count) + 1)).flatMap { $0 },
            directMessages: DirectMessageProfile(dms: draw(directMessages), groupDMs: draw(groupDMs),
                                                 groupSizes: (0 ..< 30).map { groupSizes.isEmpty ? 2 : groupSizes[$0 % groupSizes.count] }),
            relationships: RelationshipProfile(friends: friends, blocked: draw(blocked), friendStatuses: statuses.mapValues { $0 * friends / seen })
        )
    }
}

/// Builds a world from an `AccountProfile`. Everything readable is generated
/// from the seed; the profile supplies only sizes, states and rates.
struct RealisticWorld {
    let world: World
    let profile: AccountProfile
    var bench: BenchWorld
    var random: SeededRandom
    let me: Snowflake
    /// Generated servers in rail order.
    var servers: [Snowflake] = []

    init(world: World, profile: AccountProfile) async {
        self.world = world
        self.profile = profile
        bench = await BenchWorld(world: world, label: "realistic")
        random = SeededRandom(seed: world.seed).fork("realistic")
        me = bench.me
    }

    /// People shared by the generated servers, DMs and friends.
    var people: [Snowflake] { bench.people }

    mutating func build() async throws {
        let relationships = profile.relationships
        await bench.ensurePeople(max(250, relationships.friends + relationships.blocked + profile.directMessages.dms + 60))
        for (index, server) in profile.servers.enumerated() { try await addServer(server, index: index) }
        await addFolders()
        try await addDirectMessages()
        await addRelationships()
    }

    // MARK: Account

    /// The rail as the settings proto's guild_folders: the demo's servers first, then the profile's folders.
    private mutating func addFolders() async {
        let demoServers = await world.guildOrder.filter { !servers.contains($0) }
        var remaining = servers[...]
        var entries: [(ids: [Snowflake], folder: FolderProfile?)] = demoServers.map { ([$0], nil) }
        for folder in profile.folders where !remaining.isEmpty {
            let ids = Array(remaining.prefix(folder.servers))
            remaining = remaining.dropFirst(ids.count)
            entries.append((ids, folder.servers > 1 ? folder : nil))
        }
        entries += remaining.map { ([$0], nil) }
        var folders = Data()
        for (index, entry) in entries.enumerated() {
            var folder = Protobuf.field(1, Data(entry.ids.flatMap { id in (0 ..< 8).map { UInt8(truncatingIfNeeded: id.rawValue >> (8 * UInt64($0))) } }))
            if let profile = entry.folder {
                folder += Protobuf.field(2, Protobuf.varint(1, UInt64(index + 1)))
                if profile.named { folder += Protobuf.field(3, Protobuf.field(1, Data(DemoText.folderName(&random).utf8))) }
                if profile.colored { folder += Protobuf.field(4, Protobuf.varint(1, UInt64(random.pick(Self.folderColors)))) }
            }
            folders += Protobuf.field(1, folder)
        }
        await world.mergeSettingsProto(me, type: 1, Protobuf.field(14, folders))
    }

    private static let folderColors = [0x5865f2, 0x57f287, 0xfee75c, 0xeb459e, 0xed4245, 0x9b59b6, 0x1abc9c, 0xe67e22]

    private mutating func addDirectMessages() async throws {
        let existing = await world.openPrivateChannels[me]?.count ?? 0
        let dms = profile.directMessages
        let partners = people.shuffledPrefix(max(0, dms.dms - existing), using: &random)
        for (index, partner) in partners.enumerated() {
            try await addPrivateChannel(recipients: [partner], index: index, group: false)
        }
        for (index, size) in dms.groupSizes.prefix(dms.groupDMs).enumerated() {
            try await addPrivateChannel(recipients: Array(people.shuffledPrefix(max(2, size), using: &random)), index: index, group: true)
        }
    }

    private mutating func addPrivateChannel(recipients: [Snowflake], index: Int, group: Bool) async throws {
        // Most DMs went quiet long ago; the list is sorted by last message.
        let last = world.epoch.addingTimeInterval(-Double(3_600 + index * index * 2_400) - random.unit() * 86_400)
        var channel = Channel(id: await world.nextID(at: last.addingTimeInterval(-200 * 86_400)), type: group ? .groupDM : .dm)
        channel.recipients = (recipients + [me]).sorted()
        if group {
            channel.ownerID = random.pick(channel.recipients)
            channel.name = random.chance(0.6) ? DemoText.folderName(&random) : nil
        }
        await world.addChannel(channel)
        let message = try await bench.seed(MessageDraft(content: DemoText.message(&random)), author: random.pick(channel.recipients),
                                           channel: channel.id, at: last)
        await world.setReadState(me, channel: channel.id, ReadState(lastAckedID: message.id))
        await world.planHistory(channel.id, HistoryPlan(count: 20 + Int(random.next() % 120), seed: random.next(), authors: channel.recipients,
                                                        kind: .friends, start: last.addingTimeInterval(-120 * 86_400),
                                                        end: last.addingTimeInterval(-60)))
    }

    private mutating func addRelationships() async {
        let relationships = profile.relationships
        let existing = await world.relationships[me]?.values.count { $0.type == .friend } ?? 0
        let friends = Array(people.prefix(max(0, relationships.friends - existing)))
        var statuses = relationships.friendStatuses.sorted { $0.key < $1.key }.flatMap { Array(repeating: $0.key, count: $0.value) }
        statuses.shuffle(using: &random)
        for (index, friend) in friends.enumerated() {
            let since = world.epoch.addingTimeInterval(-Double(30 + index * 13) * 86_400)
            await world.setRelationship(me, Relationship(userID: friend, type: .friend, since: since))
            await world.setRelationship(friend, Relationship(userID: me, type: .friend, since: since))
            let status = index < statuses.count ? PresenceStatus(rawValue: statuses[index]) ?? .offline : .offline
            var presence = await world.presences[friend] ?? Presence()
            presence.status = status
            await world.setPresence(friend, presence)
        }
        for blocked in people.suffix(relationships.blocked) {
            await world.setRelationship(me, Relationship(userID: blocked, type: .blocked, since: world.epoch.addingTimeInterval(-90 * 86_400)))
        }
    }
}

/// The few protobuf wire pieces the settings proto needs.
enum Protobuf {
    static func field(_ number: UInt64, _ payload: Data) -> Data {
        varintBytes(number << 3 | 2) + varintBytes(UInt64(payload.count)) + payload
    }

    static func varint(_ number: UInt64, _ value: UInt64) -> Data {
        varintBytes(number << 3) + varintBytes(value)
    }

    private static func varintBytes(_ value: UInt64) -> Data {
        var value = value, bytes = Data()
        repeat {
            bytes.append(UInt8(value & 0x7f) | (value > 0x7f ? 0x80 : 0))
            value >>= 7
        } while value > 0
        return bytes
    }
}

extension World {
    /// Replaces the settings sections `patch` carries, keeping the rest (building only; no event).
    func mergeSettingsProto(_ userID: Snowflake, type: Int, _ patch: Data) {
        settingsProto[userID, default: [:]][type] = ProtobufMerge.merge(settingsProto[userID]?[type] ?? Data(), patch) ?? patch
    }
}

extension DemoText {
    static func folderName(_ rng: inout SeededRandom) -> String {
        rng.pick(["games", "art stuff", "friends", "school", "music", "big servers", "local", "work-ish", "archive", "🌙", "✨ faves", "creators"])
    }
}
