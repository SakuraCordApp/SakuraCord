#if DEBUG
import Foundation
import OSLog
import SakuraCordModels

/// What benchmarks need from the Discord simulator beyond Discord's own
/// API: live traffic started through its control API, and the benchmark
/// scenarios' targets, which are found by name.
@MainActor
enum SimulatorBenchmarkControl {
    private static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "SimulatorBenchmarkControl")

    /// Starts the simulator script `name`, which runs on its own until its
    /// parameters say it is done. False, after logging why, when this launch
    /// is not connected to a simulator or the simulator refused the script.
    @discardableResult
    static func startScript(_ name: String, params: [String: Any]) async -> Bool {
        guard let basePort = DiscordNetworkRedirect.simulatorBasePort,
              let url = URL(string: "http://127.0.0.1:\(Int(basePort) + 9)/control/scripts"),
              let body = try? JSONSerialization.data(withJSONObject: ["name": name, "params": params])
        else {
            logger.error("Simulator script \(name, privacy: .public) needs a --discord-simulator launch")
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logger.error(
                    "Simulator refused script \(name, privacy: .public): \(String(bytes: data, encoding: .utf8) ?? "", privacy: .public)"
                )
                return false
            }
            return true
        } catch {
            logger.error("Simulator script \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The simulator benchmark scenario's channel `name` of `kind`. Every
    /// such scenario names its targets uniquely; a real account has no
    /// targets, so its benchmarks keep choosing from its own conversations.
    static func channel(named name: String, kind: ChannelKindValue = .text, in model: AppModel) -> Channel? {
        guard DiscordNetworkRedirect.isActive else { return nil }
        return model.snapshot?.channels.first { $0.name == name && $0.kind == kind }
    }

    /// Opens `channel`, switching servers if needed, and waits until it is
    /// the selected conversation.
    static func open(_ channel: Channel, in model: AppModel) async -> Bool {
        model.navigate(to: channel.id)
        return await PerformanceBenchmarkHarness.waitUntil({ model.selectedChannelID == channel.id }, seconds: 15)
    }
}
#endif
