#if DEBUG
import AppKit
import Foundation
import OSLog
import SakuraCordModels

/// Channel-open benchmark: opens the simulator scenario's long `#general`
/// from its short `#welcome`, timing each open from selection to the
/// timeline's first drawn frame of loaded history. The first open is cold;
/// later ones reuse cached rows. Read-only.
@MainActor
enum ChannelOpenBenchmark {
    private static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "ChannelOpenBenchmark")

    static func run(model: AppModel) async {
        guard let welcome = SimulatorBenchmarkControl.channel(named: "welcome", in: model),
              let channelID = SimulatorBenchmarkControl.channel(named: "general", in: model)?.id,
              await SimulatorBenchmarkControl.open(welcome, in: model)
        else {
            logger.error("Channel-open benchmark could not find #welcome and #general")
            return
        }
        let start = welcome.id
        let clock = ContinuousClock()
        var opens: [Double] = []
        for _ in 0 ..< 11 {
            model.selectedChannelID = start
            await AppPerformanceSignposts.waitForConversationFirstFrame(channelID: start)
            try? await Task.sleep(for: .seconds(1))
            let began = clock.now
            model.selectedChannelID = channelID
            await AppPerformanceSignposts.waitForConversationFirstFrame(channelID: channelID)
            let elapsed = began.duration(to: clock.now)
            opens.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
            try? await Task.sleep(for: .seconds(1))
        }
        PerformanceBenchmarkHarness.writeResult(
            ["opensMS": opens], fileName: "sakuracord-channel-open-benchmark.json",
            logPrefix: "CHANNEL_OPEN_BENCHMARK", logger: logger
        )
    }
}
#endif
