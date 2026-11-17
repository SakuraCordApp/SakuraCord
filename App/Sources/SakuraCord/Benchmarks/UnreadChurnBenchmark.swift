#if DEBUG
import AppKit
import Foundation
import OSLog
import SakuraCordModels

/// Unread benchmark: the simulator's `unread-churn` script sends mentions of
/// the current user to other servers' channels, as a busy account receives
/// them, while the main thread's CPU time and late frames are recorded. A
/// quiet phase first gives the baseline the per-mention cost is measured
/// against. Read-only; run on the simulator's `long-server-list` scenario.
@MainActor
enum UnreadChurnBenchmark {
    static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "UnreadChurnBenchmark")

    struct Phase: Codable {
        var frames = 0
        var delayedFrames = 0
        var frameIntervalsMS: PerformanceBenchmarkHarness.Summary?
        var mainThreadCPUMS: Double = 0
        var mentions = 0
    }

    struct Result: Codable {
        var quiet = Phase()
        var mentions = Phase()
        /// Main-thread milliseconds each mention adds over the quiet phase.
        var mainThreadMSPerMention: Double = 0
    }

    static func run(model: AppModel) async {
        try? await Task.sleep(for: .seconds(4))
        guard let view = PerformanceBenchmarkHarness.mainWindow?.contentView else {
            logger.error("Unread benchmark could not start")
            return
        }
        var result = Result()
        result.quiet = await measure(view, seconds: 10)
        let mentionsBefore = mentionCount(model)
        // Five mentions a second, each in the next server's channel.
        guard await SimulatorBenchmarkControl.startScript("unread-churn", params: [
            "rate": 5,
            "duration_s": 10,
            "exclude_guild_id": model.selectedGuildID?.description ?? "",
        ]) else { return }
        result.mentions = await measure(view, seconds: 10)
        let sent = max(0, mentionCount(model) - mentionsBefore)
        result.mentions.mentions = sent
        let quietRate = result.quiet.mainThreadCPUMS / 10
        result.mainThreadMSPerMention = sent == 0 ? 0 : (result.mentions.mainThreadCPUMS - quietRate * 10) / Double(sent)

        PerformanceBenchmarkHarness.writeResult(
            result, fileName: "sakuracord-unread-benchmark.json", logPrefix: "UNREAD_BENCHMARK", logger: logger
        )
    }

    /// Mentions the server rail counts, which each arrival raises by one.
    private static func mentionCount(_ model: AppModel) -> Int {
        model.serverRailGuildsByID.values.reduce(0) { $0 + $1.mentionCount }
    }

    /// Records every frame for `seconds`; the display link stops firing if
    /// the window closes, so a wall-clock deadline also ends the phase.
    private static func measure(_ view: NSView, seconds: Double) async -> Phase {
        let measured = await PerformanceBenchmarkHarness.measure(
            view, seconds: seconds, settles: false, endsByDeadline: true
        ) { _ in }
        return Phase(
            frames: measured.frames,
            delayedFrames: measured.delayedFrames,
            frameIntervalsMS: measured.frameIntervalsMS,
            mainThreadCPUMS: measured.mainThreadCPUMS
        )
    }
}
#endif
