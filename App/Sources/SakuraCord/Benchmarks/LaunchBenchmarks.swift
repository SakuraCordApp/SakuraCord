import AppKit
import DiscordProtocol
import SakuraCordModels

/// Runs the benchmarks and opens the fixtures the launch arguments ask for,
/// once the main window's session has started.
@MainActor
struct LaunchBenchmarks {
    let launch: AppLaunchConfiguration
    let provider: MockChatProvider?

    func run(model: AppModel) async {
#if DEBUG
        await runAuthenticatedBenchmarks(model: model)
#endif
        if activatesOfflineBenchmark {
            NSApp.activate(ignoringOtherApps: true)
        }
        if launch.includesForumPerformanceFixture {
            model.selectedChannelID = MockChatProvider.feedbackForumID
        } else if launch.includesChatPerformanceFixture, !launch.runsChannelOpenBenchmark {
            model.selectedChannelID = MockChatProvider.generalChannelID
        }
#if DEBUG
        if launch.runsForumPerformanceAutoScroll {
            await ForumBoardBenchmark.run(model: model, resizesGallery: launch.runsForumGalleryResize)
        }
#endif
        if launch.runsFriendsPerformanceBenchmark {
            await FriendsPerformanceBenchmark.run(model: model, provider: provider)
        }
        if launch.runsServerRailPerformanceBenchmark {
            await ServerRailPerformanceBenchmark.run(model: model)
        }
        if launch.runsUnreadChurnBenchmark {
            await UnreadChurnBenchmark.run(model: model, provider: provider)
        }
        if launch.runsChannelOpenBenchmark {
            await ChannelOpenBenchmark.run(model: model)
        }
#if SAKURACORD_MOTION_BENCHMARK
        if let sideChatMotionOptions = launch.sideChatMotionOptions {
            await SideChatMotionBenchmark.run(model: model, options: sideChatMotionOptions)
        }
#endif
        if launch.includesPinsPerformanceFixture {
            await model.channelLoadTask?.value
            model.presentPinnedMessages(channelID: MockChatProvider.generalChannelID)
            await model.pinnedMessages.loadTask?.value
            await model.preparePinnedMessagesPerformanceBenchmark()
        }
        if launch.runsChatLiveArrivalStress {
            await runLiveStress()
        }
    }

    /// An offline fixture or benchmark that needs the window frontmost.
    private var activatesOfflineBenchmark: Bool {
        var activates = launch.includesChatPerformanceFixture
            || launch.runsFriendsPerformanceBenchmark
            || launch.runsServerRailPerformanceBenchmark
            || launch.runsUnreadChurnBenchmark
            || launch.runsChannelOpenBenchmark
#if DEBUG
        activates = activates || launch.runsForumPerformanceAutoScroll
#endif
#if SAKURACORD_MOTION_BENCHMARK
        activates = activates || launch.sideChatMotionOptions != nil
#endif
        return activates
    }

#if DEBUG
    private func runAuthenticatedBenchmarks(model: AppModel) async {
        if launch.runsAuthenticatedNavigationBenchmark {
            await model.runAuthenticatedNavigationPerformanceBenchmark()
        }
        if launch.runsAuthenticatedAccountSwitchBenchmark {
            await model.runAuthenticatedAccountSwitchPerformanceBenchmark()
        }
        if launch.runsHistoryPaginationBenchmark {
            await model.runAuthenticatedHistoryPaginationPerformanceBenchmark()
        }
        if launch.runsAuthenticatedGestureScrollBenchmark {
            await model.runAuthenticatedGestureScrollPerformanceBenchmark()
        }
        if launch.runsLoadingScrollOverlapBenchmark {
            await model.runAuthenticatedLoadingScrollOverlapPerformanceBenchmark()
        }
        if launch.activatesAuthenticatedScrollBenchmark {
            // A display-link benchmark is only representative
            // while AppKit is presenting this window normally.
            // Background/occluded windows are intentionally
            // throttled by WindowServer and would report machine
            // scheduling as SakuraCord frame loss.
            NSApp.activate(ignoringOtherApps: true)
        }
        if launch.preparesTimelineScrollBenchmark {
            await model.prepareAuthenticatedTimelineScrollPerformanceBenchmark()
        }
        if launch.preparesMemberListScrollBenchmark {
            await model.prepareAuthenticatedMemberListScrollPerformanceBenchmark()
        }
    }
#endif

    private func runLiveStress() async {
        await NativeTimelinePerformanceBenchmarkGate.shared
            .waitUntilStarted()
        guard !Task.isCancelled,
              let provider
        else { return }
        let runsReactions = launch.liveStressRunsReactions
        let runsArrivals = launch.liveStressRunsArrivals
        let runsMutations = launch.liveStressRunsMutations
        await withTaskGroup(of: Void.self) { group in
            if runsReactions {
                group.addTask {
                    await provider
                        .emitTimelineReactionStress(
                            in: MockChatProvider.generalChannelID,
                            operationCount: 800
                        )
                }
            }
            if runsArrivals {
                group.addTask {
                    await provider
                        .emitTimelineStressMessages(
                            in: MockChatProvider.generalChannelID,
                            count: 2_400,
                            burstSize: 4,
                            burstInterval: .milliseconds(32)
                        )
                }
            }
            if runsMutations {
                group.addTask {
                    await provider
                        .emitTimelineMutationStress(
                            in: MockChatProvider.generalChannelID,
                            operationCount: 1_200,
                            deleteEvery: 5,
                            lookback: 600,
                            initialDelay: .milliseconds(500),
                            operationInterval: .milliseconds(32)
                        )
                }
            }
        }
    }
}
