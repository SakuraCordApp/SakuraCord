import AppKit
import Foundation
import SakuraCordModels

/// Offline channel-open benchmark: opens a long channel from a short one,
/// timing each open from selection to the timeline's first drawn frame of
/// loaded history. The first open is cold; later ones reuse cached rows.
/// Read-only against the offline fixture.
@MainActor
enum ChannelOpenBenchmark {
    static func run(model: AppModel, channelID: ChannelID) async {
        NSApp.activate(ignoringOtherApps: true)
        let start = ChannelID(rawValue: 200)
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
        if let path = ProcessInfo.processInfo.environment["SAKURACORD_PERFORMANCE_RESULT_PATH"],
           let data = try? JSONEncoder().encode(["opensMS": opens]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
