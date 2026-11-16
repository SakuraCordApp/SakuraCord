import Foundation

public extension ParitySuite {
    /// The voice, Go Live, soundboard, call and Activity flows on a generated world's servers.
    static func runVoice(scenario: String, seed: UInt64 = 7) async -> Report {
        await run(scenario: scenario, seed: seed, mutate: nil) { try await $0.executeVoice() }
    }
}

extension ParityRun {
    mutating func executeVoice() async throws {
        // The flows check exact event order; generated worlds' live chatter would interleave.
        simulator.scripts.cancelAll()
        let world = simulator.world
        guard let me = await world.primaryUserID, let token = await world.tokens.first(where: { $0.value == me })?.key else {
            throw WorldError.invalidBody("scenario has no primary account")
        }
        self.token = token
        let probe = try GatewayProbe(url: URL(string: "ws://127.0.0.1:\(simulator.port(.gateway))/?v=9&encoding=etf&compress=zstd-stream")!)
        gateway = probe
        try await probe.identify(token: token)
        _ = try await probe.waitFor("READY_SUPPLEMENTAL", timeout: .seconds(60))
        let target = try await voiceTargets(me: me)
        try await voice(target, me: me)
        try await activities(target)
        report.sequenceFailures += probe.sequenceErrors.map { "gateway sequence: \($0)" }
        probe.close()
    }

    /// The biggest server with a voice channel, a text channel and someone else in it.
    private func voiceTargets(me: Snowflake) async throws -> Targets {
        let world = simulator.world
        for guild in await world.guilds(of: me).sorted(by: { $0.members.count > $1.members.count }) {
            let channels = await world.visibleChannels(in: guild, for: me)
            guard channels.contains(where: { $0.type == .voice }), let text = channels.first(where: { $0.type == .text }),
                  let other = guild.memberOrder.first(where: { $0 != me }) else { continue }
            return Targets(guild: guild.id, channel: text.id, forum: nil, otherUser: other)
        }
        throw WorldError.invalidBody("scenario has no server with a voice channel")
    }
}
