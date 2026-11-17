import Foundation
import SimulatorKit

/// `discord-simulator [--port 47100] [--seed 1] [--scenario demo] [--param key=value]...
///   [--network realistic|standard|lan|mobile|instant] [--freeze-clock] [--no-rate-limits] [--verbose]`
var configuration = DiscordSimulator.Configuration()
var arguments = CommandLine.arguments.dropFirst().makeIterator()

func usage() -> Never {
    print("""
    usage: discord-simulator [--port N] [--seed N] [--scenario NAME] [--param key=value]...
                             [--network realistic|standard|lan|mobile|instant] [--freeze-clock] [--no-rate-limits] [--verbose]
           discord-simulator --list-scenarios
    """)
    exit(2)
}

@MainActor
func value<T>(_ parse: (String) -> T?) -> T {
    guard let text = arguments.next(), let parsed = parse(text) else { usage() }
    return parsed
}

while let argument = arguments.next() {
    switch argument {
    case "--port": configuration.basePort = value { UInt16($0) }
    case "--seed": configuration.seed = value { UInt64($0) }
    case "--scenario": configuration.scenario = value { $0 }
    case "--param":
        let pair = value { $0 }.split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { usage() }
        configuration.parameters[pair[0]] = pair[1]
    case "--network": configuration.network = value { SimulatedNetwork.named($0) }
    case "--freeze-clock": configuration.freezeClock = true
    case "--epoch": configuration.epoch = value { ISO8601DateFormatter().date(from: $0) }
    case "--no-rate-limits": configuration.enforcesRateLimits = false
    case "--verbose": configuration.verbose = true
    case "--list-scenarios":
        for scenario in ScenarioRegistry.all { print("\(scenario.name)\t\(scenario.summary)") }
        exit(0)
    default: usage()
    }
}

do {
    let simulator = try await DiscordSimulator.make(configuration: configuration)
    try await simulator.start()
    let summary = await simulator.world.summary()
    let account = summary["accounts"]?.arrayValue?.first
    print("discord-simulator ready")
    print("scenario: \(configuration.scenario) seed: \(configuration.seed)")
    print("api: http://127.0.0.1:\(simulator.port(.api))  gateway: ws://127.0.0.1:\(simulator.port(.gateway))  control: http://127.0.0.1:\(simulator.port(.control))/control")
    if let account { print("account: \(account["username"]?.stringValue ?? "") token: \(account["token"]?.stringValue ?? "")") }
    fflush(stdout)
    // Run until terminated.
    while true { try await Task.sleep(for: .seconds(3600)) }
} catch {
    FileHandle.standardError.write(Data("discord-simulator: \(error)\n".utf8))
    exit(1)
}
