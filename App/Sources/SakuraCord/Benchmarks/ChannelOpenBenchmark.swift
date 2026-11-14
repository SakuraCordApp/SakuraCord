import AppKit
import DiscordProtocol
import Foundation
import OSLog
import SakuraCordModels

/// Offline channel-open benchmark: opens a long channel from a short one,
/// timing each open from selection to the timeline's first drawn frame of
/// loaded history. The first open is cold; later ones reuse cached rows.
/// Read-only against the offline fixture.
@MainActor
enum ChannelOpenBenchmark {
    private static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "ChannelOpenBenchmark")
    private static let start = MockChatProvider.welcomeChannelID
    private static let channelID = MockChatProvider.generalChannelID

    static func run(model: AppModel) async {
        NSApp.activate(ignoringOtherApps: true)
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
