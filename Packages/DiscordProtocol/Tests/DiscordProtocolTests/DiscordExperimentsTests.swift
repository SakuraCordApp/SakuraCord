@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

private let experimentName = "2026-01_test_guild_experiment"
private let guildID = GuildID(rawValue: 1_300_000_000_000_000_001)
private var position: Int { Int(MurmurHash3.hash("\(experimentName):\(guildID.rawValue)") % 10_000) }

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// One guild experiment with `populations`, a population being `[buckets, filters]`.
private func guildExperiments(
    _ populations: String, overrides: String = "[]", formatted: String = "[]", holdout: String = "null,null",
    extra: String = ""
) throws -> DiscordExperiments {
    try DiscordExperiments(user: nil, guild: json("""
    [[\(MurmurHash3.hash(experimentName)),null,1,\(populations),\(overrides),\(formatted),\(holdout),0,0]\(extra)]
    """), apex: nil, userID: nil)
}

private extension DiscordExperiments {
    func bucket(in guild: GuildID = guildID) -> Int? {
        guildBucket(experimentName, guild: .init(id: guild))
    }
}

private func everyone(_ bucket: Int, filters: String = "[]") -> String {
    #"[[[\#(bucket),[{"s":0,"e":10000}]]],\#(filters)]"#
}

private func filter(_ name: String, _ values: [(String, String)]) -> String {
    let pairs = values.map { "[\(MurmurHash3.hash($0.0)),\($0.1)]" }.joined(separator: ",")
    return "[\(MurmurHash3.hash(name)),[\(pairs)]]"
}

// Experiment names, positions and filters are all matched by this hash; a wrong
// one silently turns every experiment off.
@Test(arguments: [
    ("", UInt32(0)),
    ("test", 0xba6bd213),
    ("Hello, world!", 0xc0363e43),
    ("The quick brown fox jumps over the lazy dog", 0x2e4ff723),
    ("€uro", 0x30d83d41),
    ("2026-07-personal-widget", 2_369_760_879),
])
func `murmurhash3 matches reference vectors`(input: String, expected: UInt32) {
    #expect(MurmurHash3.hash(input) == expected)
}

@Test func `user and apex assignments are read by position and malformed entries dropped`() throws {
    let experiments = try DiscordExperiments(
        user: json("""
        [[\(MurmurHash3.hash("2026-01_user")),3,2,-1,0,4321,0],["x"],[1],null,{"a":1},[\(MurmurHash3.hash("bad")),1,"two"]]
        """),
        guild: json(#"[[1,null,0,"nope"],"x",[2,null,0,[["bad"],[[[1,[{"s":"0","e":5}]]],"filters"]]]]"#),
        apex: json("""
        {"assignments":{"1":{"7":{"assignments":[[\(MurmurHash3.hash("2026-01_apex")),2,1,4,2,null],"x",[3],
         [\(MurmurHash3.hash("2026-01_bad_flags")),1,"8"]]}},
         "2":{"7":{"assignments":[[\(MurmurHash3.hash("2026-01_other_unit")),1,0,1]]}}}}
        """),
        userID: "7"
    )
    #expect(experiments.userBucket("2026-01_user") == 2)
    #expect(experiments.userBucket("bad") == nil)
    #expect(experiments.apexAssignment("2026-01_apex") == .init(variant: 2, flags: 1))
    #expect(experiments.apexVariant("2026-01_other_unit") == nil)
    // Unreadable flags could hide UseAsEligibility, so the assignment is dropped.
    #expect(experiments.apexAssignment("2026-01_bad_flags") == nil)
    #expect(experiments.guildExperiments.keys.sorted() == [2])
    #expect(experiments.guildBucket("missing", guild: .init(id: guildID)) == nil)

    let weird = DiscordExperiments(user: .string("weird"), guild: .object([:]), apex: .array([]), userID: "7")
    #expect(weird.userBuckets.isEmpty && weird.guildExperiments.isEmpty && weird.apexAssignments.isEmpty)
}

@Test func `a malformed experiment payload never fails READY`() throws {
    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: Data("""
    {"user":{"id":"7","username":"maya"},"guilds":[],
     "experiments":"bad","guild_experiments":{"a":1},"apex_experiments":[1,2,3]}
    """.utf8))
    #expect(ready.currentUser?.id == "7")
    #expect(ready.experiments.userBuckets.isEmpty)
}

@Test func `guild buckets follow overrides then formatted overrides then the rollout`() throws {
    let all = try guildExperiments("[\(everyone(1))]")
    #expect(all.bucket() == 1)

    let elsewhere = try guildExperiments(#"[[[[1,[{"s":\#(position + 1),"e":\#(position + 2)}]]],[]]]"#)
    #expect(elsewhere.bucket() == DiscordExperiments.control)

    let edges = try guildExperiments(#"[[[[1,[{"s":0,"e":\#(position)}]],[2,[{"s":\#(position),"e":10000}]]],[]]]"#)
    #expect(edges.bucket() == 2)

    let byID = try guildExperiments(
        "[\(everyone(1))]",
        overrides: #"[{"b":3,"k":["\#(guildID.rawValue)"]},{"b":-1,"k":["5"]}]"#
    )
    #expect(byID.bucket() == 3)
    #expect(byID.bucket(in: GuildID(rawValue: 5)) == nil)

    // A group that places the guild wins; a not-eligible group falls through to the next.
    let formatted = try guildExperiments("[\(everyone(1))]", formatted: "[[\(everyone(-1))],[\(everyone(4))]]")
    #expect(formatted.bucket() == 4)
    let fallsThrough = try guildExperiments("[\(everyone(1))]", formatted: "[[\(everyone(-1))]]")
    #expect(fallsThrough.bucket() == 1)

    // A population whose filters or buckets cannot be read never matches, rather than matching every guild.
    let badFilters = everyone(1, filters: #""garbage""#)
    let badGuildIDs = everyone(1, filters: #"[[\#(MurmurHash3.hash("guild_ids")),"x"]]"#)
    let badRanges = #"[[[1,"bad"]],[]]"#
    let unreadable = try guildExperiments("[\(badFilters),\(badGuildIDs),\(badRanges),\(everyone(2))]")
    #expect(unreadable.bucket() == 2)

    let notEligible = try guildExperiments("[\(everyone(-1))]")
    #expect(notEligible.bucket() == nil)
}

@Test func `guild filters gate populations and unknown filters pass`() throws {
    let rollout = try guildExperiments("""
    [\(everyone(2, filters: "[\(filter("guild_has_feature", [("guild_features", #"["PARTNERED"]"#)]))]")),
     \(everyone(1, filters: "[\(filter("guild_member_count_range", [("min_id", "100"), ("max_id", "500")])),[12345,[[1,2]]]]"))]
    """)
    var guild = DiscordExperiments.GuildFacts(id: guildID, features: ["COMMUNITY"], memberCount: 120)
    #expect(rollout.guildBucket(experimentName, guild: guild) == 1)
    guild.features.insert("PARTNERED")
    #expect(rollout.guildBucket(experimentName, guild: guild) == 2)
    guild.features = []
    guild.memberCount = 3
    #expect(rollout.guildBucket(experimentName, guild: guild) == nil)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ageDays = Int(now.timeIntervalSince(guildID.createdAt) / 86400)
    let passing: [(String, DiscordExperiments.GuildFacts)] = [
        (filter("guild_ids", [("guild_ids", #"["\#(guildID.rawValue)"]"#)]), .init(id: guildID)),
        (filter("guild_age_range_days", [("min_id", "\(ageDays)"), ("max_id", "\(ageDays)")]), .init(id: guildID)),
        (filter("guild_hub_types", [("guild_hub_types", "[1,2]")]), .init(id: guildID, hubType: 2)),
        (filter("guild_has_vanity_url", [("guild_has_vanity_url", "true")]), .init(id: guildID, hasVanityURL: true)),
    ]
    let failing: [(String, DiscordExperiments.GuildFacts)] = [
        (filter("guild_ids", [("guild_ids", #"["1"]"#)]), .init(id: guildID)),
        (filter("guild_id_range", [("min_id", #""\#(guildID.rawValue + 1)""#)]), .init(id: guildID)),
        (filter("guild_age_range_days", [("min_id", "\(ageDays + 1)")]), .init(id: guildID)),
        (filter("guild_hub_types", [("guild_hub_types", "[1]")]), .init(id: guildID)),
        (filter("guild_has_vanity_url", [("guild_has_vanity_url", "true")]), .init(id: guildID)),
    ]
    for (filters, passes) in [(passing, true), (failing, false)] {
        for (filter, guild) in filters {
            let experiments = try guildExperiments("[\(everyone(1, filters: "[\(filter)]"))]")
            #expect((experiments.guildBucket(experimentName, guild: guild, now: now) == 1) == passes, "\(filter)")
        }
    }
}

@Test func `hash range filter and holdout`() throws {
    // The official client doubles the hash: `(i > 0 ? i + i : i >>> 0) % 1e4 < target`.
    let hashPosition = Int(UInt64(MurmurHash3.hash("key:\(guildID.rawValue)")) * 2 % 10_000)
    for (target, passes) in [(hashPosition + 1, true), (hashPosition, false)] {
        let experiments = try guildExperiments(
            "[\(everyone(1, filters: "[\(filter("guild_in_range_by_hash", [("hash_key", #""key""#), ("target", "\(target)")]))]"))]"
        )
        #expect((experiments.bucket() == 1) == passes)
    }

    // The holdout removes a rollout placement, but not a formatted override's.
    let holdoutName = "2026-01_holdout"
    let holdoutExperiment = ",[\(MurmurHash3.hash(holdoutName)),null,1,[\(everyone(0))],[],[],null,null,0,0]"
    func bucket(holdoutBucket: Int, formatted: String = "[]") throws -> Int? {
        try guildExperiments(
            "[\(everyone(1))]", formatted: formatted, holdout: #""\#(holdoutName)",\#(holdoutBucket)"#, extra: holdoutExperiment
        ).bucket()
    }
    #expect(try bucket(holdoutBucket: 0) == nil)
    #expect(try bucket(holdoutBucket: 1) == 1)
    #expect(try bucket(holdoutBucket: 0, formatted: "[[\(everyone(2))]]") == 2)
}
