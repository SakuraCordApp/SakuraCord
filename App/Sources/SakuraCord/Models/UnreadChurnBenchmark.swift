import AppKit
import DiscordProtocol
import Foundation
import OSLog
import SakuraCordModels

/// Offline unread benchmark: mentions of the current user arrive in other
/// servers' channels through the provider, as a busy account receives them,
/// while the main thread's CPU time and late frames are recorded. A quiet
/// phase first gives the baseline the per-mention cost is measured against.
/// Read-only against the offline fixture.
@MainActor
enum UnreadChurnBenchmark {
    static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "UnreadChurnBenchmark")

    struct Phase: Codable {
        var frames = 0
        var delayedFrames = 0
        var frameIntervalsMS: FriendsPerformanceBenchmark.Summary?
        var mainThreadCPUMS: Double = 0
        var mentions = 0
    }

    struct Result: Codable {
        var quiet = Phase()
        var mentions = Phase()
        /// Main-thread milliseconds each mention adds over the quiet phase.
        var mainThreadMSPerMention: Double = 0
    }

    static func run(model: AppModel, provider: MockChatProvider?) async {
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(4))
        guard let provider, let currentUser = model.currentUser,
              let view = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.contentView
        else {
            logger.error("Unread benchmark could not start")
            return
        }
        let channels = (model.snapshot?.channels ?? []).filter {
            $0.guildID != nil && $0.guildID != model.selectedGuildID && $0.kind == .text
        }
        let author = model.snapshot?.members.first { $0.user.id != currentUser.id }?.user ?? currentUser
        var result = Result()
        result.quiet = await measure(view, seconds: 10) { _ in }
        var sent = 0
        var lastSend: TimeInterval = 0
        result.mentions = await measure(view, seconds: 10) { now in
            // Five mentions a second, each in the next server's channel.
            guard !channels.isEmpty, now - lastSend >= 0.2 else { return }
            lastSend = now
            let channel = channels[sent % channels.count]
            sent += 1
            let message = Message(
                id: MessageID(rawValue: 9_000_000_000 + UInt64(sent)),
                channelID: channel.id,
                author: author,
                content: "<@\(currentUser.id)> benchmark mention \(sent)",
                timestamp: .now,
                guildID: channel.guildID,
                mentionedUsers: [currentUser]
            )
            Task { await provider.emit(.messageCreated(message)) }
        }
        result.mentions.mentions = sent
        let quietRate = result.quiet.mainThreadCPUMS / 10
        result.mainThreadMSPerMention = sent == 0 ? 0 : (result.mentions.mainThreadCPUMS - quietRate * 10) / Double(sent)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(result)) ?? Data()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sakuracord-unread-benchmark.json")
        try? data.write(to: url, options: .atomic)
        logger.notice("UNREAD_BENCHMARK \(String(bytes: data, encoding: .utf8) ?? "", privacy: .public)")
    }

    /// Runs `tick` with the current uptime on every display-link frame for
    /// `seconds`, recording frame intervals and the main thread's CPU time.
    private static func measure(
        _ view: NSView,
        seconds: Double,
        tick: @escaping (TimeInterval) -> Void
    ) async -> Phase {
        let ticker = NativeTimelineDisplayLinkTicker()
        var intervals: [Double] = []
        var previous = ProcessInfo.processInfo.systemUptime
        let start = previous
        let cpuStart = NativeTimelineBenchmarkArtifact.currentThreadCPUTime()
        let completion = ForumBenchmarkCompletion()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completion.continuation = continuation
            // The display link stops firing if the window closes, so a
            // wall-clock deadline also ends the phase.
            completion.deadline = Task { @MainActor in
                guard (try? await Task.sleep(for: .seconds(seconds + 5))) != nil else { return }
                ticker.stop()
                completion.finish()
            }
            ticker.start(on: view) {
                let now = ProcessInfo.processInfo.systemUptime
                intervals.append((now - previous) * 1_000)
                previous = now
                tick(now)
                if now - start >= seconds {
                    ticker.stop()
                    completion.finish()
                }
            }
        }
        var phase = Phase()
        phase.frames = intervals.count
        phase.frameIntervalsMS = FriendsPerformanceBenchmark.Summary(intervals)
        phase.delayedFrames = intervals.count { $0 > 25 }
        phase.mainThreadCPUMS = (NativeTimelineBenchmarkArtifact.currentThreadCPUTime() - cpuStart) * 1_000
        return phase
    }
}
