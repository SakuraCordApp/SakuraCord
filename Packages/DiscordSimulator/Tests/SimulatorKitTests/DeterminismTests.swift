import Foundation
@testable import SimulatorKit
import Testing

/// Benchmarks rely on a seed fully determining the world and the injected network delays.
@Suite(.serialized)
struct DeterminismTests {
    static let epoch = Date(timeIntervalSince1970: 1_794_778_200)

    func run(port: UInt16) async throws -> (world: JSON, delays: [NetworkConditioner.DelayRecord]) {
        var configuration = DiscordSimulator.Configuration()
        configuration.basePort = port
        configuration.seed = 42
        configuration.epoch = Self.epoch
        configuration.network = NetworkConditioner.Profile(latencyMilliseconds: 40, jitterMilliseconds: 15)
        let simulator = try await DiscordSimulator.make(configuration: configuration)
        try await simulator.start()
        defer { simulator.stop() }
        let world = await simulator.world.summary()
        let token = world["accounts"]?.arrayValue?.first?["token"]?.stringValue ?? ""
        let channels = (world["guilds"]?.arrayValue ?? []).flatMap { $0["channels"]?.arrayValue ?? [] }
            .filter { $0["type"]?.intValue == 0 }.compactMap { $0["id"]?.stringValue }.prefix(6)
        // Requests go out concurrently, so connection reuse differs between runs.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for channel in channels {
                group.addTask {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v9/channels/\(channel)/messages?limit=50")!)
                    request.setValue(token, forHTTPHeaderField: "Authorization")
                    _ = try await URLSession(configuration: .ephemeral).data(for: request)
                }
            }
            try await group.waitForAll()
        }
        let delays = simulator.conditioners[.api]?.delays ?? []
        return (world.removing("now"), delays.sorted { ($0.request, $0.occurrence) < ($1.request, $1.occurrence) })
    }

    @Test func sameSeedGivesSameWorldAndDelays() async throws {
        let first = try await run(port: 48_100)
        let second = try await run(port: 48_200)
        #expect(first.world == second.world)
        #expect(first.delays.count == 6)
        #expect(first.delays == second.delays)
    }
}
