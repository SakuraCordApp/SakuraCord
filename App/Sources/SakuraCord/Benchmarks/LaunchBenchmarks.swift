import AppKit
import OSLog
import SakuraCordModels

/// Runs the benchmarks the launch arguments ask for once the main window's
/// session has reached the workspace.
@MainActor
struct LaunchBenchmarks {
    private static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "LaunchBenchmarks")
    let launch: AppLaunchConfiguration

    func run(model: AppModel) async {
#if DEBUG
        guard !launch.benchmarks.isEmpty else { return }
        // A simulator launch signs in after the session start returns.
        guard await PerformanceBenchmarkHarness.waitUntil({ model.sessionState == .workspace }, seconds: 60) else {
            Self.logger.error("Benchmarks need a signed-in workspace")
            return
        }
        await runAccountBenchmarks(model: model)
        // A display-link benchmark is only representative while AppKit is
        // presenting this window normally. Background or occluded windows
        // are throttled by WindowServer and would report machine scheduling
        // as SakuraCord frame loss.
        NSApp.activate(ignoringOtherApps: true)
        if launch.runsChatPerformanceAutoScroll || launch.runsPinsPerformanceAutoScroll {
            await model.prepareTimelineScrollPerformanceBenchmark()
        }
        if launch.runsMemberListPerformanceAutoScroll {
            await model.prepareAuthenticatedMemberListScrollPerformanceBenchmark()
        }
        if launch.runsForumPerformanceAutoScroll {
            if await SimulatorBenchmarkControl.open(named: "feedback", kind: .forum, in: model) == nil {
                Self.logger.error("Forum benchmark could not open #feedback")
            }
            await ForumBoardBenchmark.run(model: model, resizesGallery: launch.runsForumGalleryResize)
        }
        if launch.runsFriendsPerformanceBenchmark {
            await FriendsPerformanceBenchmark.run(model: model)
        }
        if launch.runsServerRailPerformanceBenchmark {
            await ServerRailPerformanceBenchmark.run(model: model)
        }
        if launch.runsUnreadChurnBenchmark {
            await UnreadChurnBenchmark.run(model: model)
        }
        if launch.runsChannelOpenBenchmark {
            await ChannelOpenBenchmark.run(model: model)
        }
#if SAKURACORD_MOTION_BENCHMARK
        if let sideChatMotionOptions = launch.sideChatMotionOptions {
            await SideChatMotionBenchmark.run(model: model, options: sideChatMotionOptions)
        }
#endif
        if launch.runsPinsPerformanceAutoScroll, let channelID = model.selectedChannelID {
            model.presentPinnedMessages(channelID: channelID)
            await model.pinnedMessages.loadTask?.value
            await model.preparePinnedMessagesPerformanceBenchmark()
        }
        if launch.runsChatLiveStress {
            await runLiveStress(model: model)
        }
#endif
    }

#if DEBUG
    /// Benchmarks of the signed-in account's own scale and history.
    private func runAccountBenchmarks(model: AppModel) async {
        if launch.runsNavigationBenchmark {
            await model.runAuthenticatedNavigationPerformanceBenchmark()
        }
        if launch.runsAccountSwitchBenchmark {
            await model.runAuthenticatedAccountSwitchPerformanceBenchmark()
        }
        if launch.runsHistoryPaginationBenchmark {
            await model.runAuthenticatedHistoryPaginationPerformanceBenchmark()
        }
        if launch.runsGestureScrollBenchmark {
            await model.runAuthenticatedGestureScrollPerformanceBenchmark()
        }
        if launch.runsLoadingScrollOverlapBenchmark {
            await model.runAuthenticatedLoadingScrollOverlapPerformanceBenchmark()
        }
    }

    /// Streams reactions, arrivals, edits and deletions into the scrolling
    /// channel from the simulator once the scroll has started; a count of
    /// zero leaves that kind of traffic out.
    private func runLiveStress(model: AppModel) async {
        await NativeTimelinePerformanceBenchmarkGate.shared.waitUntilStarted()
        guard !Task.isCancelled, let channelID = model.selectedChannelID else { return }
        await SimulatorBenchmarkControl.startScript("timeline-stress", params: [
            "channel_id": channelID.description,
            "reactions": launch.liveStressRunsReactions ? 800 : 0,
            "arrivals": launch.liveStressRunsArrivals ? 2_400 : 0,
            "mutations": launch.liveStressRunsMutations ? 1_200 : 0,
            "burst": 4,
            "interval_ms": 32,
        ])
    }
#endif
}
