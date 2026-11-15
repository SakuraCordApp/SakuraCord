import Foundation
import SakuraCordModels

/// The account's experiment assignments from READY's `experiments`,
/// `guild_experiments` and `apex_experiments`, evaluated as the official client
/// does. Discord identifies experiments only by the MurmurHash3 of their name.
/// Every lookup answers nil, meaning off, for an experiment READY did not
/// assign. Entries are read by position and an unreadable one is dropped, so
/// no shape here can fail READY. See docs/protocol/SESSION.md#experiments.
struct DiscordExperiments: Sendable {
    struct ApexAssignment: Equatable, Sendable {
        var variant: Int
        var flags: Int

        /// Discord evaluated this only to test eligibility; it does not enable
        /// the variant.
        static let useAsEligibility = 8
    }

    /// What a guild experiment's filters test.
    struct GuildFacts: Sendable {
        var id: GuildID
        var features: Set<String> = []
        var memberCount: Int?
        var hubType: Int?
        var hasVanityURL = false
    }

    struct GuildExperiment: Sendable {
        var hashKey: String?
        var populations: [Population]
        var overrides: [UInt64: Int]
        var overridesFormatted: [[Population]]
        var holdoutName: String?
        var holdoutBucket: Int?
    }

    struct Population: Sendable {
        var buckets: [(bucket: Int, ranges: [Range<Int>])]
        var filters: [Filter]
    }

    enum Filter: Sendable {
        case guildIDs(Set<UInt64>)
        case guildIDRange(min: UInt64?, max: UInt64?)
        case guildAgeRangeDays(min: Int?, max: Int?)
        case memberCountRange(min: Int?, max: Int?)
        case hasFeature(Set<String>)
        case hubTypes(Set<Int>)
        case hasVanityURL(Bool)
        case inRangeByHash(hashKey: String, target: Int)
        /// A filter this build does not know. Like the official client, it passes.
        case unknown
    }

    static let notEligible = -1
    static let control = 0

    var userBuckets: [UInt32: Int] = [:]
    var apexAssignments: [UInt32: ApexAssignment] = [:]
    var guildExperiments: [UInt32: GuildExperiment] = [:]

    /// The account's bucket in a user experiment, which Discord evaluates
    /// server-side.
    func userBucket(_ name: String) -> Int? {
        userBuckets[MurmurHash3.hash(name)].flatMap { $0 == Self.notEligible ? nil : $0 }
    }

    /// The account's apex assignment, including its override and eligibility flags.
    func apexAssignment(_ name: String) -> ApexAssignment? {
        apexAssignments[MurmurHash3.hash(name)]
    }

    /// The account's apex variant; nil for an eligibility-only assignment.
    func apexVariant(_ name: String) -> Int? {
        apexAssignment(name).flatMap { $0.flags & ApexAssignment.useAsEligibility == 0 ? $0.variant : nil }
    }

    /// A guild's bucket in a guild experiment; nil where it is not eligible.
    func guildBucket(_ name: String, guild: GuildFacts, now: Date = .now) -> Int? {
        guard let experiment = guildExperiments[MurmurHash3.hash(name)] else { return nil }
        if let bucket = experiment.overrides[guild.id.rawValue] {
            return bucket == Self.notEligible ? nil : bucket
        }
        let position = Int(MurmurHash3.hash("\(experiment.hashKey ?? name):\(guild.id.rawValue)") % 10_000)
        // An override group that places the guild wins outright, without the holdout.
        for populations in experiment.overridesFormatted {
            if let bucket = Self.bucket(in: populations, guild: guild, position: position, now: now) { return bucket }
        }
        guard let bucket = Self.bucket(in: experiment.populations, guild: guild, position: position, now: now) else {
            return nil
        }
        if let holdoutName = experiment.holdoutName, let holdoutBucket = experiment.holdoutBucket,
           holdoutName != name, guildBucket(holdoutName, guild: guild, now: now) == holdoutBucket {
            return nil
        }
        return bucket
    }

    /// The first population whose filters all pass decides: the bucket whose
    /// range holds the position, else control. Not eligible there, or no
    /// matching population, is nil.
    private static func bucket(in populations: [Population], guild: GuildFacts, position: Int, now: Date) -> Int? {
        guard let population = populations.first(where: { $0.filters.allSatisfy { $0.passes(guild, now: now) } }) else {
            return nil
        }
        let bucket = population.buckets.first { $0.ranges.contains { $0.contains(position) } }?.bucket ?? control
        return bucket == notEligible ? nil : bucket
    }
}

extension DiscordExperiments.Filter {
    func passes(_ guild: DiscordExperiments.GuildFacts, now: Date) -> Bool {
        func within<T: Comparable>(_ value: T, _ min: T?, _ max: T?) -> Bool {
            min.map { value >= $0 } ?? true && max.map { value <= $0 } ?? true
        }
        switch self {
        case let .guildIDs(ids): return ids.contains(guild.id.rawValue)
        case let .guildIDRange(min, max): return within(guild.id.rawValue, min, max)
        case let .guildAgeRangeDays(min, max):
            let created = Date(timeIntervalSince1970: Double((guild.id.rawValue >> 22) + 1_420_070_400_000) / 1000)
            return within(Int(now.timeIntervalSince(created) / 86400), min, max)
        case let .memberCountRange(min, max): return guild.memberCount.map { within($0, min, max) } ?? false
        case let .hasFeature(features): return !features.isDisjoint(with: guild.features)
        case let .hubTypes(types): return guild.hubType.map(types.contains) ?? false
        case let .hasVanityURL(wanted): return guild.hasVanityURL == wanted
        case let .inRangeByHash(hashKey, target):
            // The official client doubles the unsigned hash before the modulo.
            return Int(UInt64(MurmurHash3.hash("\(hashKey):\(guild.id.rawValue)")) * 2 % 10_000) < target
        case .unknown: return true
        }
    }
}

// MARK: - READY decoding

extension DiscordExperiments {
    /// - Parameter userID: the READY user, whose apex unit is read.
    init(user: JSONValue?, guild: JSONValue?, apex: JSONValue?, userID: String?) {
        // `[hash, revision, bucket, override, population, hash_result, aa_mode, …]`
        for entry in user?.arrayValue ?? [] {
            guard let fields = entry.arrayValue, fields.count > 2,
                  let hash = fields[0].experimentHash, let bucket = fields[2].intValue else { continue }
            userBuckets[hash] = bucket
        }
        // `{assignments: {"1": {<user id>: {assignments: [[hash, variant, flags, revision, …]]}}}}`
        let apexEntries = apex?["assignments"]?["1"]?[userID ?? ""]?["assignments"]?.arrayValue ?? []
        for entry in apexEntries {
            guard let fields = entry.arrayValue, fields.count > 1,
                  let hash = fields[0].experimentHash, let variant = fields[1].intValue else { continue }
            // Absent flags are none; unreadable ones could hide UseAsEligibility, so drop the entry.
            let flags = fields.count > 2 && fields[2] != .null ? fields[2].intValue : 0
            guard let flags else { continue }
            apexAssignments[hash] = ApexAssignment(variant: variant, flags: flags)
        }
        // `[hash, hash_key, revision, populations, overrides, overrides_formatted, holdout_name, holdout_bucket, …]`
        for entry in guild?.arrayValue ?? [] {
            guard let fields = entry.arrayValue, fields.count > 3, let hash = fields[0].experimentHash,
                  let populations = fields[3].arrayValue else { continue }
            func field(_ index: Int) -> JSONValue? { index < fields.count ? fields[index] : nil }
            var overrides: [UInt64: Int] = [:]
            for override in field(4)?.arrayValue ?? [] {
                guard let bucket = override["b"]?.intValue else { continue }
                for id in override["k"]?.arrayValue ?? [] {
                    if let id = id.snowflakeValue { overrides[id] = bucket }
                }
            }
            guildExperiments[hash] = GuildExperiment(
                hashKey: field(1)?.stringValue,
                populations: populations.compactMap(Population.init),
                overrides: overrides,
                overridesFormatted: (field(5)?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(Population.init) },
                holdoutName: field(6)?.stringValue,
                holdoutBucket: field(7)?.intValue
            )
        }
    }
}

// A population or filter the official client could not build never matches
// there, so one this cannot read is dropped rather than treated as unfiltered.
private extension DiscordExperiments.Population {
    /// `[[[bucket, [{s, e}, …]], …], [[filter hash, [[key hash, value], …]], …]]`
    init?(_ value: JSONValue) {
        guard let parts = value.arrayValue, parts.count > 1, let buckets = parts[0].arrayValue,
              let rawFilters = parts[1].arrayValue else { return nil }
        filters = rawFilters.compactMap(DiscordExperiments.Filter.init)
        guard filters.count == rawFilters.count else { return nil }
        self.buckets = buckets.compactMap { entry in
            guard let pair = entry.arrayValue, pair.count > 1, let bucket = pair[0].intValue else { return nil }
            let ranges = (pair[1].arrayValue ?? []).compactMap { range -> Range<Int>? in
                guard let start = range["s"]?.intValue, let end = range["e"]?.intValue, start <= end else { return nil }
                return start ..< end
            }
            return (bucket, ranges)
        }
    }
}

private extension DiscordExperiments.Filter {
    private static let kinds = Dictionary(uniqueKeysWithValues: [
        "guild_ids", "guild_id_range", "guild_age_range_days", "guild_member_count_range",
        "guild_has_feature", "guild_hub_types", "guild_has_vanity_url", "guild_in_range_by_hash",
    ].map { (MurmurHash3.hash($0), $0) })

    /// `[filter hash, [[key hash, value], …]]`
    init?(_ filter: JSONValue) {
        guard let pair = filter.arrayValue else { return nil }
        guard let kind = pair.first?.experimentHash.flatMap({ Self.kinds[$0] }) else {
            self = .unknown
            return
        }
        guard pair.count > 1, let rawEntries = pair[1].arrayValue else { return nil }
        let entries = rawEntries.compactMap(\.arrayValue)
        guard entries.count == rawEntries.count else { return nil }
        var values: [UInt32: JSONValue] = [:]
        for entry in entries where entry.count > 1 {
            if let key = entry[0].experimentHash { values[key] = entry[1] }
        }
        // These three read their first value whatever its key.
        let first = entries.first.flatMap { $0.count > 1 ? $0[1] : nil }
        guard let filter = Self.read(kind, values: values, first: first) else { return nil }
        self = filter
    }

    private static func read(_ kind: String, values: [UInt32: JSONValue], first: JSONValue?) -> Self? {
        var isReadable = true
        func value(_ key: String) -> JSONValue? { values[MurmurHash3.hash(key)] }
        /// A missing or null bound is open; an unreadable one fails the filter.
        func bound<T>(_ key: String, _ parse: (JSONValue) -> T?) -> T? {
            guard let raw = value(key), raw != .null else { return nil }
            let parsed = parse(raw)
            if parsed == nil { isReadable = false }
            return parsed
        }
        let filter: Self? = switch kind {
        case "guild_ids": value("guild_ids")?.arrayValue.map { .guildIDs(Set($0.compactMap(\.snowflakeValue))) }
        case "guild_id_range": .guildIDRange(min: bound("min_id", \.snowflakeValue), max: bound("max_id", \.snowflakeValue))
        case "guild_age_range_days": .guildAgeRangeDays(min: bound("min_id", \.integerValue), max: bound("max_id", \.integerValue))
        case "guild_member_count_range": .memberCountRange(min: bound("min_id", \.integerValue), max: bound("max_id", \.integerValue))
        case "guild_has_feature": first?.arrayValue.map { .hasFeature(Set($0.compactMap(\.stringValue))) }
        case "guild_hub_types": first?.arrayValue.map { .hubTypes(Set($0.compactMap(\.intValue))) }
        case "guild_has_vanity_url": if case let .bool(wanted) = first { .hasVanityURL(wanted) } else { nil }
        default:
            // The official client interpolates a missing key as JavaScript's "undefined".
            value("target")?.integerValue.map {
                .inRangeByHash(hashKey: value("hash_key")?.stringValue ?? value("hash_key")?.intValue.map(String.init) ?? "undefined", target: $0)
            }
        }
        return isReadable ? filter : nil
    }
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case let .object(object) = self else { return nil }
        return object[key]
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(array) = self else { return nil }
        return array
    }

    /// A range bound, which Discord may send as a number or a numeric string.
    var integerValue: Int? {
        stringValue.flatMap { Int($0) } ?? intValue
    }

    var stringValue: String? {
        guard case let .string(string) = self else { return nil }
        return string
    }

    var intValue: Int? {
        guard case let .number(number) = self else { return nil }
        return Int(exactly: number)
    }

    var experimentHash: UInt32? {
        guard case let .number(number) = self else { return nil }
        return UInt32(exactly: number)
    }

    /// Discord sends snowflakes as strings; the official client also accepts numbers.
    var snowflakeValue: UInt64? {
        switch self {
        case let .string(string): UInt64(string)
        case let .number(number): UInt64(exactly: number)
        default: nil
        }
    }
}
